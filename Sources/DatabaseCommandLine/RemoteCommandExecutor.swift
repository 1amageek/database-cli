import DatabaseClient
import DatabaseKit
import DatabaseTypes
import DatabaseWire
import Foundation

struct RemoteCommandExecutor: Sendable {
    let session: RemoteSession
    let output: OutputWriter
    let continuationSink: (@Sendable (ByteString?) -> Void)?
    private let builder = WireRequestBuilder()

    init(
        session: RemoteSession,
        output: OutputWriter,
        continuationSink: (@Sendable (ByteString?) -> Void)? = nil
    ) {
        self.session = session
        self.output = output
        self.continuationSink = continuationSink
    }

    func execute(_ command: ParsedCommand) async throws {
        let execution = try builder.executionOptions(command)
        let resultOutput = execution.pagination.fetchAll
            ? output.limitingResultBytes(
                to: execution.pagination.maximumTotalBytes
            )
            : output
        let renderer = ResultRenderer(
            output: resultOutput,
            maximumElements: execution.pagination.fetchAll
                ? execution.pagination.maximumTotalRows
                : nil
        )
        let format = renderer.selectedFormat(execution.outputFormat)

        switch command.path {
        case ["capabilities"]:
            try rejectJobOption(command)
            let response = try await databaseClient.execute(
                DatabaseOperationCatalog.capabilitiesDescribe,
                request: EmptyOperationPayload(),
                metadata: execution.metadata
            )
            try renderer.renderCapabilities(response)
        case ["schema", "list"]:
            try rejectJobOption(command)
            let response = try await databaseClient.execute(
                DatabaseOperationCatalog.schemaDescribe,
                request: EmptyOperationPayload(),
                metadata: execution.metadata
            )
            try renderer.renderSchema(response, entity: nil)
        case ["schema", "show"]:
            try rejectJobOption(command)
            let response = try await databaseClient.execute(
                DatabaseOperationCatalog.schemaDescribe,
                request: EmptyOperationPayload(),
                metadata: execution.metadata
            )
            try renderer.renderSchema(
                response,
                entity: command.positionals[0]
            )
        case ["schema", "plan"], ["schema", "apply"]:
            let request = try builder.schemaExecutionRequest(command)
            if try await startJobIfRequested(
                command,
                operation: DatabaseOperationCatalog.schemaExecute,
                request: request,
                metadata: execution.metadata,
                renderer: renderer
            ) { return }
            try renderer.renderSchemaExecution(
                try await databaseClient.execute(
                    DatabaseOperationCatalog.schemaExecute,
                    request: request,
                    metadata: execution.metadata
                )
            )
        case let path where path.first == "base":
            try renderer.renderBaseExecution(
                try await targetedClient(command).execute(
                    DatabaseOperationCatalog.baseExecute,
                    request: builder.baseExecutionRequest(command),
                    metadata: execution.metadata
                )
            )
        case let path where path.first == "composition":
            try renderer.renderCompositionExecution(
                try await targetedClient(command).execute(
                    DatabaseOperationCatalog.compositionExecute,
                    request: builder.compositionExecutionRequest(command),
                    metadata: execution.metadata
                )
            )
        case let path where path.first == "grant":
            try renderer.renderGrantExecution(
                try await targetedClient(command).execute(
                    DatabaseOperationCatalog.grantExecute,
                    request: builder.grantExecutionRequest(command),
                    metadata: execution.metadata
                )
            )
        case ["inspect", "overview"]:
            try rejectJobOption(command)
            async let capabilities = databaseClient.execute(
                DatabaseOperationCatalog.capabilitiesDescribe,
                request: EmptyOperationPayload(),
                metadata: execution.metadata
            )
            async let schema = databaseClient.execute(
                DatabaseOperationCatalog.schemaDescribe,
                request: EmptyOperationPayload(),
                metadata: execution.metadata
            )
            try await renderer.renderInspectionOverview(
                capabilities: capabilities,
                schema: schema
            )
        case ["inspect", "entities"]:
            try rejectJobOption(command)
            let response = try await databaseClient.execute(
                DatabaseOperationCatalog.schemaDescribe,
                request: EmptyOperationPayload(),
                metadata: execution.metadata
            )
            try renderer.renderSchema(
                response,
                entity: command.positionals.first
            )
        case ["inspect", "indexes"]:
            try rejectJobOption(command)
            async let schema = databaseClient.execute(
                DatabaseOperationCatalog.schemaDescribe,
                request: EmptyOperationPayload(),
                metadata: execution.metadata
            )
            async let status = targetedClient(command).execute(
                DatabaseOperationCatalog.maintenanceExecute,
                request: MaintenanceExecuteOperation.Request(
                    invocation: .indexStatus(
                        entity: command.options.value("entity"),
                        index: nil,
                        partitions: FieldObject()
                    ),
                    continuation: execution.continuation,
                    budget: execution.budget
                ),
                metadata: execution.metadata
            )
            try await renderer.renderIndexInspection(
                schema: schema,
                status: status,
                entity: command.options.value("entity")
            )
        case ["inspect", "graph"]:
            try rejectJobOption(command)
            let response = try await databaseClient.execute(
                DatabaseOperationCatalog.schemaDescribe,
                request: EmptyOperationPayload(),
                metadata: execution.metadata
            )
            try renderer.renderGraphInspection(
                response,
                entity: command.options.value("entity")
            )
        case ["inspect", "jobs"]:
            try rejectJobOption(command)
            try renderer.renderAdvertisedJobs(
                try await databaseClient.execute(
                    DatabaseOperationCatalog.capabilitiesDescribe,
                    request: EmptyOperationPayload(),
                    metadata: execution.metadata
                )
            )
        case ["inspect", "ontology"]:
            try await execute(
                ParsedCommand(
                    path: ["ontology", "describe"],
                    positionals: command.positionals,
                    options: command.options
                )
            )
        case ["inspect", "shapes"]:
            try await execute(
                ParsedCommand(
                    path: ["shacl", "describe"],
                    positionals: command.positionals,
                    options: command.options
                )
            )
        case let path where path.count == 2 && path[0] == "query":
            try await executeQuery(
                command,
                execution: execution,
                renderer: renderer,
                format: format
            )
        case let path where path.count == 2 && path[0] == "mutate":
            let request = try builder.statementMutationRequest(
                command,
                execution: execution
            )
            try await executeMutation(
                command,
                request: request,
                execution: execution,
                renderer: renderer
            )
        case let path where path.count == 2 && path[0] == "entity":
            let request = try builder.entityRequest(
                command,
                execution: execution
            )
            try await executeMutation(
                command,
                request: request,
                execution: execution,
                renderer: renderer
            )
        case let path where path.count == 2 && path[0] == "graph":
            try await executeGraph(
                command,
                execution: execution,
                renderer: renderer,
                format: format
            )
        case let path where path.count == 2 && path[0] == "ontology":
            try await executeOntology(
                command,
                execution: execution,
                renderer: renderer,
                format: format
            )
        case let path where path.count == 2 && path[0] == "shacl":
            try await executeSHACL(
                command,
                execution: execution,
                renderer: renderer,
                format: format
            )
        case ["command", "run"]:
            let request = try builder.commandRequest(
                command,
                execution: execution
            )
            if try await startJobIfRequested(
                command,
                operation: DatabaseOperationCatalog.commandExecute,
                request: request,
                metadata: execution.metadata,
                renderer: renderer
            ) { return }
            let response = try await targetedClient(command).execute(
                DatabaseOperationCatalog.commandExecute,
                request: request,
                metadata: execution.metadata
            )
            let page = try renderer.renderCommand(response, format: format)
            continuationSink?(page.continuation)
        case let path where path.count == 2
            && ["migration", "index", "maintenance"].contains(path[0]):
            try await executeMaintenance(
                command,
                execution: execution,
                renderer: renderer,
                format: format
            )
        case ["job", "status"]:
            try rejectJobOption(command)
            try renderer.renderJobStatus(
                try await targetedClient(command).jobStatus(
                    for: try jobIdentity(command),
                    metadata: execution.metadata
                )
            )
        case ["job", "wait"]:
            try rejectJobOption(command)
            try await waitForJob(
                command,
                execution: execution,
                renderer: renderer
            )
        case ["job", "result"]:
            try rejectJobOption(command)
            try await renderJobResult(
                command,
                execution: execution,
                renderer: renderer,
                format: format
            )
        case ["job", "cancel"]:
            try rejectJobOption(command)
            try renderer.renderJobCancellation(
                try await targetedClient(command).cancelJob(
                    try jobIdentity(command),
                    metadata: execution.metadata
                )
            )
        default:
            throw DatabaseCLIError(
                .input,
                "Command is not a remote database operation"
            )
        }
    }
}

private extension RemoteCommandExecutor {
    var databaseClient: TargetedDatabaseClient<AnyDatabaseTransport> {
        session.client.database
    }

    func targetedClient(
        _ command: ParsedCommand
    ) throws -> TargetedDatabaseClient<AnyDatabaseTransport> {
        session.client.targeting(try builder.operationTarget(command))
    }

    struct PageTotals {
        var pages: UInt32 = 0
        var elements: UInt64 = 0
        var bytes: UInt64 = 0
        var continuations: Set<ByteString> = []

        mutating func record(
            _ page: RenderedPage,
            limits: PaginationLimits
        ) throws {
            pages += 1
            let nextElements = elements.addingReportingOverflow(
                page.elementCount
            )
            let nextBytes = bytes.addingReportingOverflow(page.byteCount)
            guard !nextElements.overflow,
                  !nextBytes.overflow,
                  nextElements.partialValue <= limits.maximumTotalRows,
                  nextBytes.partialValue <= limits.maximumTotalBytes,
                  pages <= limits.maximumPages else {
                throw DatabaseCLIError(
                    .resourceLimit,
                    "Paginated result exceeded an explicit '--all' limit"
                )
            }
            elements = nextElements.partialValue
            bytes = nextBytes.partialValue
            if let continuation = page.continuation {
                guard continuations.insert(continuation).inserted else {
                    throw DatabaseCLIError(
                        .internalFailure,
                        "Server repeated a continuation token"
                    )
                }
            }
        }

        func executionPage(_ execution: ExecutionOptions) -> ExecutionOptions {
            guard execution.pagination.fetchAll else { return execution }
            return execution.limitingPageSize(
                to: execution.pagination.maximumTotalRows - elements
            )
        }

        func requirePageCapacity(_ limits: PaginationLimits) throws {
            guard pages < limits.maximumPages else {
                throw DatabaseCLIError(
                    .resourceLimit,
                    "Paginated result exceeds '--max-pages'"
                )
            }
        }

        func framing(
            format: OutputFormat,
            hasContinuation: Bool,
            fetchAll: Bool
        ) -> JSONPageFraming {
            guard format == .json, fetchAll else { return .single }
            return JSONPageFraming(
                opensCollection: pages == 0,
                closesCollection: !hasContinuation,
                hasPriorElements: elements > 0
            )
        }
    }

    func executeQuery(
        _ command: ParsedCommand,
        execution: ExecutionOptions,
        renderer: ResultRenderer,
        format: OutputFormat
    ) async throws {
        let firstRequest = try builder.queryRequest(
            command,
            execution: execution,
            continuation: execution.continuation
        )
        if try await startJobIfRequested(
            command,
            operation: DatabaseOperationCatalog.queryExecute,
            request: firstRequest,
            metadata: execution.metadata,
            renderer: renderer
        ) { return }

        var continuation = execution.continuation
        var totals = PageTotals()
        repeat {
            if execution.pagination.fetchAll {
                try totals.requirePageCapacity(execution.pagination)
            }
            let pageExecution = totals.executionPage(execution)
            let response = try await targetedClient(command).execute(
                DatabaseOperationCatalog.queryExecute,
                request: try builder.queryRequest(
                    command,
                    execution: pageExecution,
                    continuation: continuation
                ),
                metadata: execution.metadata
            )
            let next = queryContinuation(response)
            let page = try renderer.renderQuery(
                response,
                format: format,
                jsonFraming: totals.framing(
                    format: format,
                    hasContinuation: next != nil,
                    fetchAll: execution.pagination.fetchAll
                )
            )
            if execution.pagination.fetchAll {
                try totals.record(page, limits: execution.pagination)
            }
            continuation = next?.detached()
        } while execution.pagination.fetchAll && continuation != nil
        continuationSink?(continuation)
    }

    func executeMutation(
        _ command: ParsedCommand,
        request: MutationExecuteOperation.Request,
        execution: ExecutionOptions,
        renderer: ResultRenderer
    ) async throws {
        if try await startJobIfRequested(
            command,
            operation: DatabaseOperationCatalog.mutationExecute,
            request: request,
            metadata: execution.metadata,
            renderer: renderer
        ) { return }
        try renderer.renderMutation(
            try await targetedClient(command).execute(
                DatabaseOperationCatalog.mutationExecute,
                request: request,
                metadata: execution.metadata
            )
        )
        continuationSink?(nil)
    }

    func executeGraph(
        _ command: ParsedCommand,
        execution: ExecutionOptions,
        renderer: ResultRenderer,
        format: OutputFormat
    ) async throws {
        let firstRequest = try builder.graphRequest(
            command,
            execution: execution,
            continuation: execution.continuation
        )
        if try await startJobIfRequested(
            command,
            operation: DatabaseOperationCatalog.graphAlgorithm,
            request: firstRequest,
            metadata: execution.metadata,
            renderer: renderer
        ) { return }
        var continuation = execution.continuation
        var totals = PageTotals()
        repeat {
            if execution.pagination.fetchAll {
                try totals.requirePageCapacity(execution.pagination)
            }
            let response = try await targetedClient(command).execute(
                DatabaseOperationCatalog.graphAlgorithm,
                request: try builder.graphRequest(
                    command,
                    execution: totals.executionPage(execution),
                    continuation: continuation
                ),
                metadata: execution.metadata
            )
            let next = graphContinuation(response)
            let page = try renderer.renderGraph(
                response,
                format: format,
                jsonFraming: totals.framing(
                    format: format,
                    hasContinuation: next != nil,
                    fetchAll: execution.pagination.fetchAll
                )
            )
            if execution.pagination.fetchAll {
                try totals.record(page, limits: execution.pagination)
            }
            continuation = next?.detached()
        } while execution.pagination.fetchAll && continuation != nil
        continuationSink?(continuation)
    }

    func executeOntology(
        _ command: ParsedCommand,
        execution: ExecutionOptions,
        renderer: ResultRenderer,
        format: OutputFormat
    ) async throws {
        let firstRequest = try builder.ontologyRequest(
            command,
            execution: execution,
            continuation: execution.continuation
        )
        if try await startJobIfRequested(
            command,
            operation: DatabaseOperationCatalog.ontologyExecute,
            request: firstRequest,
            metadata: execution.metadata,
            renderer: renderer
        ) { return }
        var continuation = execution.continuation
        var totals = PageTotals()
        repeat {
            if execution.pagination.fetchAll {
                try totals.requirePageCapacity(execution.pagination)
            }
            let response = try await targetedClient(command).execute(
                DatabaseOperationCatalog.ontologyExecute,
                request: try builder.ontologyRequest(
                    command,
                    execution: totals.executionPage(execution),
                    continuation: continuation
                ),
                metadata: execution.metadata
            )
            let next = ontologyContinuation(response)
            let page = try renderer.renderOntology(
                response,
                format: format,
                jsonFraming: totals.framing(
                    format: format,
                    hasContinuation: next != nil,
                    fetchAll: execution.pagination.fetchAll
                )
            )
            if execution.pagination.fetchAll {
                try totals.record(page, limits: execution.pagination)
            }
            continuation = next?.detached()
        } while execution.pagination.fetchAll && continuation != nil
        continuationSink?(continuation)
    }

    func executeSHACL(
        _ command: ParsedCommand,
        execution: ExecutionOptions,
        renderer: ResultRenderer,
        format: OutputFormat
    ) async throws {
        let firstRequest = try builder.shaclRequest(
            command,
            execution: execution,
            continuation: execution.continuation
        )
        if try await startJobIfRequested(
            command,
            operation: DatabaseOperationCatalog.shaclExecute,
            request: firstRequest,
            metadata: execution.metadata,
            renderer: renderer
        ) { return }
        var continuation = execution.continuation
        var totals = PageTotals()
        repeat {
            if execution.pagination.fetchAll {
                try totals.requirePageCapacity(execution.pagination)
            }
            let response = try await targetedClient(command).execute(
                DatabaseOperationCatalog.shaclExecute,
                request: try builder.shaclRequest(
                    command,
                    execution: totals.executionPage(execution),
                    continuation: continuation
                ),
                metadata: execution.metadata
            )
            let next = shaclContinuation(response)
            let page = try renderer.renderSHACL(
                response,
                format: format,
                jsonFraming: totals.framing(
                    format: format,
                    hasContinuation: next != nil,
                    fetchAll: execution.pagination.fetchAll
                )
            )
            if execution.pagination.fetchAll {
                try totals.record(page, limits: execution.pagination)
            }
            continuation = next?.detached()
        } while execution.pagination.fetchAll && continuation != nil
        continuationSink?(continuation)
    }

    func executeMaintenance(
        _ command: ParsedCommand,
        execution: ExecutionOptions,
        renderer: ResultRenderer,
        format: OutputFormat
    ) async throws {
        let firstRequest = try builder.maintenanceRequest(
            command,
            execution: execution,
            continuation: execution.continuation
        )
        if try await startJobIfRequested(
            command,
            operation: DatabaseOperationCatalog.maintenanceExecute,
            request: firstRequest,
            metadata: execution.metadata,
            renderer: renderer
        ) { return }
        var continuation = execution.continuation
        var totals = PageTotals()
        repeat {
            if execution.pagination.fetchAll {
                try totals.requirePageCapacity(execution.pagination)
            }
            let response = try await targetedClient(command).execute(
                DatabaseOperationCatalog.maintenanceExecute,
                request: try builder.maintenanceRequest(
                    command,
                    execution: totals.executionPage(execution),
                    continuation: continuation
                ),
                metadata: execution.metadata
            )
            let next = maintenanceContinuation(response)
            let page = try renderer.renderMaintenance(
                response,
                format: format,
                jsonFraming: totals.framing(
                    format: format,
                    hasContinuation: next != nil,
                    fetchAll: execution.pagination.fetchAll
                )
            )
            if execution.pagination.fetchAll {
                try totals.record(page, limits: execution.pagination)
            }
            continuation = next?.detached()
        } while execution.pagination.fetchAll && continuation != nil
        continuationSink?(continuation)
    }

    func startJobIfRequested<Request: Sendable, Response: Sendable>(
        _ command: ParsedCommand,
        operation: DatabaseOperation<Request, Response>,
        request: Request,
        metadata: OperationRequestMetadata,
        renderer: ResultRenderer
    ) async throws -> Bool {
        guard let kind = command.options.value("as-job") else { return false }
        let descriptor: JobOperation<Request, Response>
        do {
            descriptor = try operation.resumableJob(kind: kind)
        } catch {
            throw DatabaseCLIError(.input, "Invalid job kind: \(error)")
        }
        let capabilities = try await databaseClient.execute(
            DatabaseOperationCatalog.capabilitiesDescribe,
            request: EmptyOperationPayload(),
            metadata: metadata
        )
        guard capabilities.jobOperations.contains(descriptor.identifier) else {
            throw DatabaseCLIError(
                .input,
                "Server does not advertise job '\(familyName(operation.identifier))/\(kind)'"
            )
        }
        try renderer.renderJobStarted(
            try await targetedClient(command).startJob(
                descriptor,
                request: request,
                metadata: metadata
            )
        )
        return true
    }

    func waitForJob(
        _ command: ParsedCommand,
        execution: ExecutionOptions,
        renderer: ResultRenderer
    ) async throws {
        let job = try jobIdentity(command)
        let interval = try command.options.integer(
            "poll-interval-milliseconds",
            default: UInt64(500)
        )
        let timeout = try command.options.integer(
            "wait-timeout-milliseconds",
            default: UInt64(30_000)
        )
        guard interval > 0, timeout > 0, interval <= 60_000 else {
            throw DatabaseCLIError(.input, "Invalid job polling interval or timeout")
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(Int64(timeout)))
        while true {
            try Task.checkCancellation()
            let response = try await targetedClient(command).jobStatus(
                for: job,
                metadata: execution.metadata
            )
            switch response.state {
            case .succeeded, .failed, .cancelled:
                try renderer.renderJobStatus(response)
                return
            case .pending, .running, .committingUnsuccessfulOutcome:
                guard clock.now < deadline else {
                    throw DatabaseCLIError(
                        .unavailable,
                        "Timed out waiting for job completion"
                    )
                }
                try await clock.sleep(
                    until: min(
                        deadline,
                        clock.now.advanced(by: .milliseconds(Int64(interval)))
                    )
                )
            }
        }
    }

    func renderJobResult(
        _ command: ParsedCommand,
        execution: ExecutionOptions,
        renderer: ResultRenderer,
        format: OutputFormat
    ) async throws {
        let job = try jobIdentity(command)
        let client = try targetedClient(command)
        switch job.operation.family {
        case .baseExecute:
            try renderer.renderBaseExecution(
                try await client.jobResult(
                    for: job,
                    using: try DatabaseOperationCatalog.baseExecute.resumableJob(
                        kind: job.operation.kind
                    ),
                    metadata: execution.metadata
                )
            )
        case .schemaExecute:
            try renderer.renderSchemaExecution(
                try await client.jobResult(
                    for: job,
                    using: try DatabaseOperationCatalog.schemaExecute.resumableJob(
                        kind: job.operation.kind
                    ),
                    metadata: execution.metadata
                )
            )
        case .queryExecute:
            try _ = renderer.renderQuery(
                try await client.jobResult(
                    for: job,
                    using: try DatabaseOperationCatalog.queryExecute.resumableJob(
                        kind: job.operation.kind
                    ),
                    metadata: execution.metadata
                ),
                format: format
            )
        case .mutationExecute:
            try renderer.renderMutation(
                try await client.jobResult(
                    for: job,
                    using: try DatabaseOperationCatalog.mutationExecute.resumableJob(
                        kind: job.operation.kind
                    ),
                    metadata: execution.metadata
                )
            )
        case .graphAlgorithm:
            try _ = renderer.renderGraph(
                try await client.jobResult(
                    for: job,
                    using: try DatabaseOperationCatalog.graphAlgorithm.resumableJob(
                        kind: job.operation.kind
                    ),
                    metadata: execution.metadata
                ),
                format: format
            )
        case .ontologyExecute:
            try _ = renderer.renderOntology(
                try await client.jobResult(
                    for: job,
                    using: try DatabaseOperationCatalog.ontologyExecute.resumableJob(
                        kind: job.operation.kind
                    ),
                    metadata: execution.metadata
                ),
                format: format
            )
        case .shaclExecute:
            try _ = renderer.renderSHACL(
                try await client.jobResult(
                    for: job,
                    using: try DatabaseOperationCatalog.shaclExecute.resumableJob(
                        kind: job.operation.kind
                    ),
                    metadata: execution.metadata
                ),
                format: format
            )
        case .commandExecute:
            try _ = renderer.renderCommand(
                try await client.jobResult(
                    for: job,
                    using: try DatabaseOperationCatalog.commandExecute.resumableJob(
                        kind: job.operation.kind
                    ),
                    metadata: execution.metadata
                ),
                format: format
            )
        case .maintenanceExecute:
            try _ = renderer.renderMaintenance(
                try await client.jobResult(
                    for: job,
                    using: try DatabaseOperationCatalog.maintenanceExecute.resumableJob(
                        kind: job.operation.kind
                    ),
                    metadata: execution.metadata
                ),
                format: format
            )
        case .capabilitiesDescribe, .schemaDescribe, .compositionExecute,
             .grantExecute, .jobStart, .jobStatus, .jobResult, .jobCancel:
            throw DatabaseCLIError(.input, "Operation family does not support jobs")
        }
    }

    func jobIdentity(_ command: ParsedCommand) throws -> JobIdentity {
        guard let identifier = DatabaseTypes.UUID(
            canonicalString: command.positionals[0]
        ) else {
            throw DatabaseCLIError(.input, "Job identifier is not a canonical UUID")
        }
        let family = try operationFamily(command.positionals[1])
        do {
            return JobIdentity(
                jobID: identifier,
                operation: try JobOperationIdentifier(
                    family: family,
                    kind: command.positionals[2]
                ),
                target: try builder.operationTarget(command)
            )
        } catch {
            throw DatabaseCLIError(.input, "Invalid job operation: \(error)")
        }
    }

    func operationFamily(_ value: String) throws -> DatabaseOperationIdentifier {
        for identifier in DatabaseOperationIdentifier.allCases
        where familyName(identifier) == value {
            return identifier
        }
        throw DatabaseCLIError(.input, "Unknown job operation family '\(value)'")
    }

    func familyName(_ value: DatabaseOperationIdentifier) -> String {
        switch value {
        case .capabilitiesDescribe: "capabilitiesDescribe"
        case .schemaDescribe: "schemaDescribe"
        case .schemaExecute: "schemaExecute"
        case .baseExecute: "baseExecute"
        case .compositionExecute: "compositionExecute"
        case .grantExecute: "grantExecute"
        case .queryExecute: "queryExecute"
        case .mutationExecute: "mutationExecute"
        case .graphAlgorithm: "graphAlgorithm"
        case .ontologyExecute: "ontologyExecute"
        case .shaclExecute: "shaclExecute"
        case .commandExecute: "commandExecute"
        case .maintenanceExecute: "maintenanceExecute"
        case .jobStart: "jobStart"
        case .jobStatus: "jobStatus"
        case .jobResult: "jobResult"
        case .jobCancel: "jobCancel"
        }
    }

    func rejectJobOption(_ command: ParsedCommand) throws {
        guard !command.options.contains("as-job") else {
            throw DatabaseCLIError(.input, "This command cannot run as a job")
        }
    }

    func queryContinuation(
        _ response: QueryExecuteOperation.Response
    ) -> ByteString? {
        switch response {
        case .rows(let page): page.continuation
        case .rdfGraph(let page): page.continuation
        case .boolean: nil
        }
    }

    func graphContinuation(
        _ response: GraphAlgorithmOperation.Response
    ) -> ByteString? {
        switch response {
        case .path(let result): result.progress.continuation
        case .ranking(let page): page.progress.continuation
        case .communities(let page): page.progress.continuation
        case .cycles(let page): page.progress.continuation
        case .components(let page): page.progress.continuation
        case .topologicalOrder(let result): result.progress.continuation
        }
    }

    func ontologyContinuation(
        _ response: OntologyExecuteOperation.Response
    ) -> ByteString? {
        switch response {
        case .document(let page): page.continuation
        case .mutation: nil
        case .inference(let page): page.continuation
        case .hierarchy(let page): page.continuation
        case .validation(let report): report.continuation
        }
    }

    func shaclContinuation(
        _ response: SHACLExecuteOperation.Response
    ) -> ByteString? {
        switch response {
        case .shapes(let page): page.continuation
        case .mutation: nil
        case .validation(let report): report.continuation
        }
    }

    func maintenanceContinuation(
        _ response: MaintenanceExecuteOperation.Response
    ) -> ByteString? {
        switch response {
        case .migrationStatus: nil
        case .indexStatus(let page): page.continuation
        case .execution(let result): result.continuation
        }
    }
}
