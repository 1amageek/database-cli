import DatabaseClient
import DatabaseEngine
import DatabaseKit
import DatabaseRuntime
@testable import DatabaseServer
import DatabaseServerFoundation
import DatabaseTypes
@_spi(DatabaseServer) import DatabaseWire
import Foundation
import SQLiteStorage
import StorageKit
import StorageKitSystemClock
import Testing
@testable import DatabaseCommandLine

@Persistable
private struct CLIRuntimeEntity {
    #Directory<CLIRuntimeEntity>("tests", "database-cli-runtime")

    var id: String = ""
    var title: String = ""
    var priority: Int64 = 0
}

private enum RuntimeBackend: String, Sendable {
    case inMemory
    case sqlite
}

@Suite("CLI runtime integration", .serialized)
struct RuntimeIntegrationTests {
    @Test("CLI executes every operation family through DatabaseServerRuntime")
    func executesEveryRuntimeOperationFamily() async throws {
        try await withRuntime(backend: .inMemory) { executor, outputURL in
            try await executor.execute(try parse(["capabilities"]))
            try await insertEntity(executor)
            try await queryEntity(executor)
            try await executor.execute(try parse([
                "graph", "page-rank", "--index", "relationships",
            ]))
            try await executor.execute(try parse([
                "ontology", "describe", "world",
            ]))
            try await executor.execute(try parse([
                "shacl", "describe", "urn:shapes",
            ]))
            try await executor.execute(try parse([
                "command", "run", "cli.echo", emptyObject,
            ]))
            try await executor.execute(try parse([
                "maintenance", "compact",
            ]))
            try await executor.execute(try parse([
                "command", "run", "cli.echo", emptyObject,
                "--as-job", RuntimeServices.jobKind,
                "--idempotency-key", "runtime-job-start",
            ]))
            try await executor.execute(try parse([
                "job", "status", RuntimeServices.jobIdentifier,
                "commandExecute", RuntimeServices.jobKind,
            ]))
            try await executor.execute(try parse([
                "job", "result", RuntimeServices.jobIdentifier,
                "commandExecute", RuntimeServices.jobKind,
            ]))
            try await executor.execute(try parse([
                "job", "cancel", RuntimeServices.jobIdentifier,
                "commandExecute", RuntimeServices.jobKind,
            ]))

            let output = try String(contentsOf: outputURL, encoding: .utf8)
            #expect(output.contains("cli-runtime"))
            #expect(output.contains("runtime-title"))
            #expect(output.contains("graph-node"))
            #expect(output.contains("world"))
            #expect(output.contains("urn:shapes"))
            #expect(output.contains("command-result"))
            #expect(output.contains("job-result"))
            #expect(output.contains(RuntimeServices.jobIdentifier))
        }
    }

    @Test("SQLite runtime executes CLI mutation and query through the same path")
    func executesSQLiteRuntimePath() async throws {
        try await withRuntime(backend: .sqlite) { executor, outputURL in
            try await insertEntity(executor)
            try await queryEntity(executor)

            let output = try String(contentsOf: outputURL, encoding: .utf8)
            #expect(output.contains("runtime-entity"))
            #expect(output.contains("runtime-title"))
        }
    }

    private func insertEntity(_ executor: RemoteCommandExecutor) async throws {
        try await executor.execute(try parse([
            "entity", "insert", "CLIRuntimeEntity",
            #"{"$type":"string","value":"runtime-entity"}"#,
            entityFields,
            "--must-not-exist",
            "--idempotency-key", "insert-runtime-entity",
        ]))
    }

    private func queryEntity(_ executor: RemoteCommandExecutor) async throws {
        try await executor.execute(try parse([
            "query", "sql", "SELECT * FROM CLIRuntimeEntity",
        ]))
    }

    private func parse(_ arguments: [String]) throws -> ParsedCommand {
        try CommandParser().parse(arguments + ["--output", "jsonl"])
    }

    private func withRuntime(
        backend: RuntimeBackend,
        operation: (RemoteCommandExecutor, URL) async throws -> Void
    ) async throws {
        let container = try await makeContainer(backend: backend)
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "database-cli-runtime-\(Foundation.UUID().uuidString).jsonl"
            )
        guard FileManager.default.createFile(
            atPath: outputURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            await container.shutdown()
            throw RuntimeFixtureError.outputCreationFailed
        }
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        let runtime = try await DatabaseServerRuntime(
            container: container,
            configuration: try DatabaseServerRuntimeConfiguration(
                identity: DatabaseRuntimeIdentity(version: "cli-runtime"),
                serviceFactory: AnyDatabaseServerServiceFactory(
                    RuntimeServiceFactory()
                ),
                admissionPolicy: AnyDatabaseOperationAdmissionPolicy(
                    UnrestrictedDatabaseOperationAdmissionPolicy()
                ),
                clock: RealtimeDatabaseWallClock()
            )
        )
        let session = RemoteSession(
            transport: AnyDatabaseTransport(RuntimeTransport(runtime: runtime)) {
                _ in
            }
        )
        let executor = RemoteCommandExecutor(
            session: session,
            output: OutputWriter(
                resultHandle: outputHandle,
                diagnosticHandle: .nullDevice
            )
        )

        do {
            try await operation(executor, outputURL)
            await session.shutdown()
            try outputHandle.close()
            await container.shutdown()
            try FileManager.default.removeItem(at: outputURL)
        } catch {
            await session.shutdown()
            do {
                try outputHandle.close()
            } catch {
                Issue.record("Runtime output close failed: \(error)")
            }
            await container.shutdown()
            do {
                try FileManager.default.removeItem(at: outputURL)
            } catch {
                Issue.record("Runtime output cleanup failed: \(error)")
            }
            throw error
        }
    }

    private func makeContainer(
        backend: RuntimeBackend
    ) async throws -> DBContainer {
        let configuration: DBConfiguration
        switch backend {
        case .inMemory:
            configuration = DBConfiguration(
                storageEngine: InMemoryEngine(),
                monotonicClock: SystemStorageClock(),
                wallClock: RealtimeDatabaseWallClock()
            )
        case .sqlite:
            configuration = DBConfiguration(
                storageEngine: try SQLiteStorageEngine(configuration: .inMemory),
                monotonicClock: SystemStorageClock(),
                wallClock: RealtimeDatabaseWallClock()
            )
        }
        return try await DBContainer.open(
            for: try Schema(
                entities: [try CLIRuntimeEntity.schemaEntity],
                version: Schema.Version(1, 0, 0)
            ),
            configuration: configuration,
            runtimeConfiguration: try DatabaseFrameworkRuntime.configuration(
                entityRuntimes: [
                    try DatabaseFrameworkRuntime.entity(
                        CLIRuntimeEntity.self
                    ),
                ]
            ),
            security: .disabled
        )
    }
}

private let emptyObject = #"{"$type":"object","value":{}}"#
private let entityFields = #"{"$type":"object","value":{"id":{"$type":"string","value":"runtime-entity"},"priority":{"$type":"int64","value":"7"},"title":{"$type":"string","value":"runtime-title"}}}"#

private final class RuntimeTransport: DatabaseTransport, Sendable {
    private let runtime: DatabaseServerRuntime

    init(runtime: DatabaseServerRuntime) {
        self.runtime = runtime
    }

    func send(
        _ request: ByteString
    ) async throws(DatabaseTransportError) -> ByteString {
        do {
            return try await runtime.execute(
                request,
                context: DatabaseRequestExecutionContext(
                    authorization: .anonymous
                )
            )
        } catch is CancellationError {
            throw .cancelled
        } catch {
            throw .unavailable(String(describing: error))
        }
    }
}

private final class RuntimeServiceFactory:
    DatabaseServerServiceFactory,
    Sendable {
    func makeServices(
        context: DatabaseServerServiceContext
    ) async throws -> DatabaseServerServices {
        let services = try RuntimeServices()
        return DatabaseServerServices(
            graphOperations: GraphOperationServices(
                statementExecutor: CanonicalDatabaseStatementMutationExecutor(
                    runtimeLimits: context.runtimeLimits
                ),
                algorithm: AnyDatabaseGraphAlgorithmService(services),
                ontology: AnyDatabaseOntologyService(services),
                shacl: AnyDatabaseSHACLService(services)
            ),
            readCommandRegistry: try DatabaseReadCommandRegistry(
                commands: [AnyDatabaseReadCommand(try RuntimeEchoCommand())]
            ),
            writeCommandRegistry: try DatabaseWriteCommandRegistry(commands: []),
            maintenanceService: AnyDatabaseMaintenanceService(services),
            jobService: AnyDatabaseJobService(services)
        )
    }
}

private struct RuntimeEchoCommand: DatabaseReadCommand {
    let declaration: CommandDeclaration

    init() throws {
        self.declaration = CommandDeclaration(
            identifier: try CommandIdentifier("cli.echo"),
            access: .readOnly
        )
    }

    func execute(
        input: FieldObject,
        context: DatabaseReadCommandContext
    ) async throws -> DatabaseCommandResult {
        _ = input
        _ = context
        return DatabaseCommandResult(output: .string("command-result"))
    }
}

private struct RuntimeServices:
    DatabaseGraphAlgorithmService,
    DatabaseOntologyService,
    DatabaseSHACLService,
    DatabaseMaintenanceService,
    DatabaseJobService {
    static let jobIdentifier = "00000000-0000-0000-0000-000000000042"
    static let jobKind = "cli.echo"

    let jobOperations: [JobOperationIdentifier]
    private let job: JobIdentity

    init() throws {
        guard let identifier = DatabaseTypes.UUID(
            canonicalString: Self.jobIdentifier
        ) else {
            throw RuntimeFixtureError.invalidJobIdentifier
        }
        let operation = try JobOperationIdentifier(
            family: .commandExecute,
            kind: Self.jobKind
        )
        self.jobOperations = [operation]
        self.job = JobIdentity(jobID: identifier, operation: operation)
    }

    func execute(
        _ request: GraphAlgorithmOperation.Request,
        context: DatabaseOperationContext
    ) async throws -> GraphAlgorithmOperation.Response {
        _ = request
        _ = context
        return .ranking(
            GraphAlgorithmOperation.RankingPage(
                scores: [
                    GraphAlgorithmOperation.Score(
                        vertex: .identifier("graph-node"),
                        score: 1
                    ),
                ],
                iterations: 1,
                convergenceDelta: 0,
                progress: .complete
            )
        )
    }

    func execute(
        _ request: OntologyExecuteOperation.Request,
        context: DatabaseOperationContext
    ) async throws -> OntologyExecutionResult {
        _ = request
        _ = context
        return .encoding(
            .document(
                OntologyExecuteOperation.DocumentPage(
                    ontology: "world",
                    revision: 1,
                    imports: [],
                    axioms: [try rdfQuad(subject: "urn:world")]
                )
            )
        )
    }

    func execute(
        _ request: SHACLExecuteOperation.Request,
        context: DatabaseOperationContext
    ) async throws -> SHACLExecutionResult {
        _ = request
        _ = context
        return .encoding(
            .shapes(
                SHACLExecuteOperation.ShapesPage(
                    graph: "urn:shapes",
                    revision: 1,
                    shapes: [try rdfQuad(subject: "urn:shapes")]
                )
            )
        )
    }

    func execute(
        _ request: MaintenanceExecuteOperation.Request,
        context: DatabaseOperationContext
    ) async throws -> MaintenanceExecutionResult {
        _ = request
        _ = context
        return .encoding(
            .execution(
                MaintenanceExecuteOperation.ExecutionResult(
                    kind: .compaction,
                    completedWorkUnits: 1,
                    commitVersion: 1,
                    isComplete: true
                )
            )
        )
    }

    func start(
        _ request: JobStartOperation.Request,
        context: DatabaseOperationContext
    ) async throws -> JobStartExecutionResult {
        guard request.operation == job.operation else {
            throw RuntimeFixtureError.jobOperationMismatch
        }
        return try jobStartResult(
            response: JobStartOperation.Response(job: job),
            requestID: context.requestID
        )
    }

    func status(
        _ request: JobStatusOperation.Request,
        context: DatabaseOperationContext
    ) async throws -> JobStatusOperation.Response {
        _ = context
        guard request.job == job else {
            throw RuntimeFixtureError.jobOperationMismatch
        }
        return try JobStatusOperation.Response(
            state: .succeeded,
            job: job,
            completedWorkUnits: 1,
            totalWorkUnits: 1,
            executionCount: 1,
            currentSliceAttempt: 1,
            updatedAt: Timestamp(secondsSinceUnixEpoch: 1)
        )
    }

    func result(
        _ request: JobResultOperation.Request,
        context: DatabaseOperationContext
    ) async throws -> JobResultOperation.Response {
        _ = context
        guard request.job == job, request.continuation == nil else {
            throw RuntimeFixtureError.jobOperationMismatch
        }
        let operation = try DatabaseOperations.commandExecute.resumableJob(
            kind: Self.jobKind
        )
        let payload = try operation.encodeCompletedResponse(
            .read(output: .string("job-result"), continuation: nil)
        )
        var accumulator = JobResultDigestAccumulator(operation: job.operation)
        accumulator.update(payload)
        return .succeeded(
            job: job,
            responsePayloadPage: payload,
            totalResponseBytes: UInt64(payload.count),
            responseDigest: accumulator.finalize(),
            continuation: nil
        )
    }

    func cancel(
        _ request: JobCancelOperation.Request,
        context: DatabaseOperationContext
    ) async throws -> JobCancellationExecutionResult {
        guard request.job == job else {
            throw RuntimeFixtureError.jobOperationMismatch
        }
        return try jobCancellationResult(
            response: JobCancelOperation.Response(
                job: job,
                state: .succeeded,
                accepted: false
            ),
            requestID: context.requestID
        )
    }

    func runScheduledWork() async throws {}

    private func rdfQuad(subject: String) throws -> RDFQuad {
        RDFQuad(
            subject: .iri(try RDFIRI(subject)),
            predicate: try RDFPredicateIRI("urn:predicate"),
            object: .literal(.string("runtime"))
        )
    }

    private func jobStartResult(
        response: JobStartOperation.Response,
        requestID: UInt64
    ) throws -> JobStartExecutionResult {
        let encoded = try DatabaseOperationResponseEncoder(
            JobStartOperation.self,
            response: response
        ).encode(requestID: requestID, limits: .default)
        let payload = try DatabaseSuccessPayload(
            operation: .jobStart,
            bytes: encoded.payload,
            limits: .default
        )
        return try JobStartExecutionResult(
            coordinated: DatabaseCoordinatedOperationResponse(
                result: DatabaseOperationResult(
                    JobStartOperation.self,
                    response: response
                ),
                successPayload: payload
            ),
            limits: .default
        )
    }

    private func jobCancellationResult(
        response: JobCancelOperation.Response,
        requestID: UInt64
    ) throws -> JobCancellationExecutionResult {
        let encoded = try DatabaseOperationResponseEncoder(
            JobCancelOperation.self,
            response: response
        ).encode(requestID: requestID, limits: .default)
        let payload = try DatabaseSuccessPayload(
            operation: .jobCancel,
            bytes: encoded.payload,
            limits: .default
        )
        return try JobCancellationExecutionResult(
            coordinated: DatabaseCoordinatedOperationResponse(
                result: DatabaseOperationResult(
                    JobCancelOperation.self,
                    response: response
                ),
                successPayload: payload
            ),
            limits: .default
        )
    }
}

private enum RuntimeFixtureError: Error {
    case outputCreationFailed
    case invalidJobIdentifier
    case jobOperationMismatch
}
