import DatabaseKit
import DatabaseTypes
import DatabaseWire

extension ResultRenderer {
    func renderCapabilities(
        _ response: CapabilitiesDescribeOperation.Response
    ) throws {
        _ = try renderJSON(.object([
            ("runtimeVersion", .string(response.runtimeVersion)),
            ("features", .array(response.features.map {
                .object([
                    ("identifier", .string($0.identifier)),
                    ("version", .string(String($0.version))),
                ])
            })),
            ("jobOperations", .array(response.jobOperations.map {
                .object([
                    ("family", .string(operationName($0.family))),
                    ("kind", .string($0.kind)),
                ])
            })),
        ]))
    }

    func renderSchema(
        _ response: SchemaDescribeOperation.Response,
        entity requestedEntity: String?
    ) throws {
        let entities: [SchemaDescribeOperation.Entity]
        if let requestedEntity {
            guard let entity = response.entities.first(where: {
                $0.name == requestedEntity
            }) else {
                throw DatabaseCLIError(
                    .notFound,
                    "Schema entity '\(requestedEntity)' was not found"
                )
            }
            entities = [entity]
        } else {
            entities = response.entities
        }
        _ = try renderJSON(.object([
            ("version", .string(response.version.description)),
            ("entities", .array(try entities.map(schemaEntityNode))),
        ]))
    }

    func renderMutation(
        _ response: MutationExecuteOperation.Response
    ) throws {
        let result: StrictJSONValue
        switch response.result {
        case .entities(let effects):
            result = .object([
                ("kind", .string("entities")),
                ("effects", .array(try effects.map { effect in
                    .object([
                        ("kind", .string(mutationKind(effect.kind))),
                        ("identity", try encodedField(.reference(effect.identity))),
                        ("version", effect.version.map {
                            .string(Base64URL.encode($0))
                        } ?? .null),
                    ])
                })),
            ])
        case .rdf(let effect):
            result = .object([
                ("kind", .string("rdf")),
                ("insertedQuads", .string(String(effect.insertedQuads))),
                ("deletedQuads", .string(String(effect.deletedQuads))),
                ("createdGraphs", .string(String(effect.createdGraphs))),
                ("droppedGraphs", .string(String(effect.droppedGraphs))),
            ])
        }
        _ = try renderJSON(.object([
            ("commitVersion", .string(String(response.commitVersion))),
            ("result", result),
        ]))
    }

    func renderGraph(
        _ response: GraphAlgorithmOperation.Response,
        format: OutputFormat,
        jsonFraming: JSONPageFraming = .single
    ) throws -> RenderedPage {
        var stream = try EventStream(
            output: output,
            elementQuota: elementQuota,
            format: format,
            jsonFraming: jsonFraming
        )
        let continuation: ByteString?
        switch response {
        case .path(let result):
            try stream.write(.object([
                ("type", .string("pathSummary")),
                ("found", .bool(result.found)),
                ("totalWeightBits", result.totalWeight.map {
                    .string(hex($0.bitPattern, digits: 16))
                } ?? .null),
                ("nodesExplored", .string(String(result.nodesExplored))),
                ("durationNanoseconds", .string(String(result.durationNanoseconds))),
            ]))
            var nodes = result.makeNodeIterator()
            var index: UInt64 = 0
            while let node = try nodes.next() {
                try stream.write(.object([
                    ("type", .string("pathNode")),
                    ("index", .string(String(index))),
                    ("node", try graphTermNode(node)),
                ]))
                index += 1
            }
            var labels = result.makeEdgeLabelIterator()
            index = 0
            while let label = try labels.next() {
                try stream.write(.object([
                    ("type", .string("pathEdgeLabel")),
                    ("index", .string(String(index))),
                    ("label", try graphTermNode(label)),
                ]))
                index += 1
            }
            var weights = result.makeWeightIterator()
            index = 0
            while let weight = try weights.next() {
                try stream.write(.object([
                    ("type", .string("pathWeight")),
                    ("index", .string(String(index))),
                    ("bits", .string(hex(weight.bitPattern, digits: 16))),
                ]))
                index += 1
            }
            continuation = result.progress.continuation
        case .ranking(let page):
            var iterator = page.makeScoreIterator()
            while let score = try iterator.next() {
                try stream.write(.object([
                    ("vertex", try graphTermNode(score.vertex)),
                    ("scoreBits", .string(hex(score.score.bitPattern, digits: 16))),
                    ("iterations", .string(String(page.iterations))),
                    ("convergenceDeltaBits", .string(hex(page.convergenceDelta.bitPattern, digits: 16))),
                ]))
            }
            continuation = page.progress.continuation
        case .communities(let page):
            var iterator = page.makeAssignmentIterator()
            while let assignment = try iterator.next() {
                try stream.write(.object([
                    ("vertex", try graphTermNode(assignment.vertex)),
                    ("community", try graphTermNode(assignment.community)),
                    ("iterations", .string(String(page.iterations))),
                    ("modularityBits", page.modularity.map {
                        .string(hex($0.bitPattern, digits: 16))
                    } ?? .null),
                ]))
            }
            continuation = page.progress.continuation
        case .cycles(let page):
            var cycles = page.makeCycleIterator()
            while let cycle = try cycles.next() {
                var terms = cycle.makeTermIterator()
                var values: [StrictJSONValue] = []
                values.reserveCapacity(cycle.termCount)
                while let term = try terms.next() {
                    values.append(try graphTermNode(term))
                }
                try stream.write(.object([
                    ("type", .string("cycle")),
                    ("terms", .array(values)),
                ]))
            }
            var edges = page.makeBackEdgeIterator()
            while let edge = try edges.next() {
                try stream.write(.object([
                    ("type", .string("backEdge")),
                    ("source", try graphTermNode(edge.source)),
                    ("target", try graphTermNode(edge.target)),
                ]))
            }
            continuation = page.progress.continuation
        case .components(let page):
            var components = page.makeComponentIterator()
            while let component = try components.next() {
                var terms = component.makeTermIterator()
                var values: [StrictJSONValue] = []
                values.reserveCapacity(component.termCount)
                while let term = try terms.next() {
                    values.append(try graphTermNode(term))
                }
                try stream.write(.object([("component", .array(values))]))
            }
            continuation = page.progress.continuation
        case .topologicalOrder(let result):
            if var order = result.makeOrderIterator() {
                var index: UInt64 = 0
                while let term = try order.next() {
                    try stream.write(.object([
                        ("type", .string("order")),
                        ("index", .string(String(index))),
                        ("node", try graphTermNode(term)),
                    ]))
                    index += 1
                }
            }
            var cyclic = result.makeCyclicNodeIterator()
            while let term = try cyclic.next() {
                try stream.write(.object([
                    ("type", .string("cyclicNode")),
                    ("node", try graphTermNode(term)),
                ]))
            }
            continuation = result.progress.continuation
        }
        try stream.finish()
        return RenderedPage(
            elementCount: stream.count,
            byteCount: stream.bytes,
            continuation: continuation?.detached()
        )
    }

    func renderOntology(
        _ response: OntologyExecuteOperation.Response,
        format: OutputFormat,
        jsonFraming: JSONPageFraming = .single
    ) throws -> RenderedPage {
        var stream = try EventStream(
            output: output,
            elementQuota: elementQuota,
            format: format,
            jsonFraming: jsonFraming
        )
        let continuation: ByteString?
        switch response {
        case .document(let page):
            var imports = page.makeImportIterator()
            while let value = try imports.next() {
                try stream.write(.object([
                    ("type", .string("import")),
                    ("ontology", .string(page.ontology)),
                    ("revision", .string(String(page.revision))),
                    ("value", .string(value)),
                ]))
            }
            var axioms = page.makeAxiomIterator()
            while let quad = try axioms.next() {
                try stream.write(try rdfQuadNode(quad))
            }
            continuation = page.continuation
        case .mutation(let result):
            try stream.write(.object([
                ("commitVersion", .string(String(result.commitVersion))),
                ("revision", .string(String(result.revision))),
            ]))
            continuation = nil
        case .inference(let page):
            var axioms = page.makeInferredAxiomIterator()
            while let quad = try axioms.next() {
                try stream.write(try rdfQuadNode(quad))
            }
            continuation = page.continuation
        case .hierarchy(let page):
            var entries = page.makeEntryIterator()
            while let entry = try entries.next() {
                try stream.write(.object([
                    ("resource", .string(entry.resource)),
                    ("depth", .string(String(entry.depth))),
                ]))
            }
            continuation = page.continuation
        case .validation(let report):
            continuation = try renderValidation(report, stream: &stream)
        }
        try stream.finish()
        return RenderedPage(
            elementCount: stream.count,
            byteCount: stream.bytes,
            continuation: continuation?.detached()
        )
    }

    func renderSHACL(
        _ response: SHACLExecuteOperation.Response,
        format: OutputFormat,
        jsonFraming: JSONPageFraming = .single
    ) throws -> RenderedPage {
        var stream = try EventStream(
            output: output,
            elementQuota: elementQuota,
            format: format,
            jsonFraming: jsonFraming
        )
        let continuation: ByteString?
        switch response {
        case .shapes(let page):
            var shapes = page.makeShapeIterator()
            while let quad = try shapes.next() {
                try stream.write(try rdfQuadNode(quad))
            }
            continuation = page.continuation
        case .mutation(let result):
            try stream.write(.object([
                ("commitVersion", .string(String(result.commitVersion))),
                ("revision", .string(String(result.revision))),
            ]))
            continuation = nil
        case .validation(let report):
            continuation = try renderValidation(report, stream: &stream)
        }
        try stream.finish()
        return RenderedPage(
            elementCount: stream.count,
            byteCount: stream.bytes,
            continuation: continuation?.detached()
        )
    }

    func renderMaintenance(
        _ response: MaintenanceExecuteOperation.Response,
        format: OutputFormat,
        jsonFraming: JSONPageFraming = .single
    ) throws -> RenderedPage {
        var stream = try EventStream(
            output: output,
            elementQuota: elementQuota,
            format: format,
            jsonFraming: jsonFraming
        )
        let continuation: ByteString?
        switch response {
        case .migrationStatus(let status):
            try stream.write(.object([
                ("currentVersion", status.currentVersion.map {
                    .string($0.description)
                } ?? .null),
                ("targetVersion", .string(status.targetVersion.description)),
                ("pendingMigrations", .array(status.pendingMigrationIdentifiers.map {
                    .string($0)
                })),
            ]))
            continuation = nil
        case .indexStatus(let page):
            var indexes = page.makeIndexIterator()
            while let index = try indexes.next() {
                try stream.write(.object([
                    ("entity", .string(index.entity)),
                    ("index", .string(index.index)),
                    ("partitions", try encodedField(.object(index.partitions))),
                    ("state", .string(indexState(index.state))),
                    ("indexedEntityCount", .string(String(index.indexedEntityCount))),
                    ("detail", index.detail.map(StrictJSONValue.string) ?? .null),
                ]))
            }
            continuation = page.continuation
        case .execution(let result):
            try stream.write(.object([
                ("kind", .string(executionKind(result.kind))),
                ("completedWorkUnits", .string(String(result.completedWorkUnits))),
                ("commitVersion", result.commitVersion.map {
                    .string(String($0))
                } ?? .null),
                ("complete", .bool(result.isComplete)),
            ]))
            continuation = result.continuation
        }
        try stream.finish()
        return RenderedPage(
            elementCount: stream.count,
            byteCount: stream.bytes,
            continuation: continuation?.detached()
        )
    }

    func renderCommand(
        _ response: CommandExecuteOperation.Response,
        format: OutputFormat,
        jsonFraming: JSONPageFraming = .single
    ) throws -> RenderedPage {
        var stream = try EventStream(
            output: output,
            elementQuota: elementQuota,
            format: format,
            jsonFraming: jsonFraming
        )
        let continuation: ByteString?
        switch response {
        case .read(let value, let next):
            try stream.write(.object([
                ("access", .string("readOnly")),
                ("output", try encodedField(value)),
            ]))
            continuation = next
        case .write(let value, let commitVersion, let next):
            try stream.write(.object([
                ("access", .string("readWrite")),
                ("commitVersion", .string(String(commitVersion))),
                ("output", try encodedField(value)),
            ]))
            continuation = next
        }
        try stream.finish()
        return RenderedPage(
            elementCount: stream.count,
            byteCount: stream.bytes,
            continuation: continuation?.detached()
        )
    }

    func renderJobStarted(_ job: JobIdentity) throws {
        _ = try renderJSON(jobNode(job, event: "started"))
    }

    func renderJobStatus(_ response: JobStatusOperation.Response) throws {
        _ = try renderJSON(.object([
            ("job", jobNode(response.job, event: nil)),
            ("state", .string(jobState(response.state))),
            ("completedWorkUnits", .string(String(response.completedWorkUnits))),
            ("totalWorkUnits", response.totalWorkUnits.map {
                .string(String($0))
            } ?? .null),
            ("executionCount", .string(String(response.executionCount))),
            ("currentSliceAttempt", .string(String(response.currentSliceAttempt))),
            ("unsuccessfulOutcomeCommitAttempt", .string(String(response.unsuccessfulOutcomeCommitAttempt))),
            ("cancellationRequested", .bool(response.cancellationRequested)),
            ("nextAttemptAt", response.nextAttemptAt.map(timestampNode) ?? .null),
            ("updatedAt", timestampNode(response.updatedAt)),
            ("lastUnsuccessfulOutcomeCommitError", response.lastUnsuccessfulOutcomeCommitError.map {
                .object([
                    ("category", .string(operationErrorCategory($0.category))),
                    ("code", .string($0.code)),
                    ("message", .string($0.message)),
                ])
            } ?? .null),
        ]))
    }

    func renderJobCancellation(
        _ response: JobCancelOperation.Response
    ) throws {
        _ = try renderJSON(.object([
            ("job", jobNode(response.job, event: nil)),
            ("state", .string(jobState(response.state))),
            ("accepted", .bool(response.accepted)),
        ]))
    }
}

private extension ResultRenderer {
    struct EventStream {
        let output: OutputWriter
        let elementQuota: ResultElementQuota?
        let format: OutputFormat
        let jsonFraming: JSONPageFraming
        var count: UInt64 = 0
        var bytes: UInt64 = 0

        init(
            output: OutputWriter,
            elementQuota: ResultElementQuota?,
            format: OutputFormat,
            jsonFraming: JSONPageFraming
        ) throws {
            guard format != .csv && format != .nquads else {
                throw DatabaseCLIError(
                    .input,
                    "This result does not support \(format.rawValue) output"
                )
            }
            self.output = output
            self.elementQuota = elementQuota
            self.format = format
            self.jsonFraming = jsonFraming
            if format == .json, jsonFraming.opensCollection {
                bytes += UInt64(try output.result("["))
            }
        }

        mutating func write(_ node: StrictJSONValue) throws {
            try elementQuota?.reserveOne()
            let json = StrictJSONWriter.encode(node)
            let prefix = format == .json
                && (count > 0 || jsonFraming.hasPriorElements) ? "," : ""
            let suffix = format == .json ? "" : "\n"
            bytes += UInt64(try output.result(prefix + json + suffix))
            count += 1
        }

        mutating func finish() throws {
            if format == .json, jsonFraming.closesCollection {
                bytes += UInt64(try output.result("]\n"))
            }
        }
    }

    func schemaEntityNode(
        _ entity: SchemaDescribeOperation.Entity
    ) throws -> StrictJSONValue {
        .object([
            ("name", .string(entity.name)),
            ("fields", .array(entity.fields.map { field in
                .object([
                    ("number", .string(String(field.number))),
                    ("name", .string(field.name)),
                    ("type", .string(schemaValueType(field.type))),
                    ("nullable", .bool(field.nullable)),
                    ("reference", field.reference.map { reference in
                        .object([
                            ("targetEntity", .string(reference.targetEntity)),
                            ("cardinality", .string(referenceCardinality(reference.cardinality))),
                            ("deleteRule", .string(referenceDeleteRule(reference.deleteRule))),
                        ])
                    } ?? .null),
                ])
            })),
            ("indexes", .array(try entity.indexes.map { index in
                .object([
                    ("name", .string(index.name)),
                    ("kind", .string(index.kind)),
                    ("fields", .array(index.fields.map {
                        .string(String($0))
                    })),
                    ("options", try encodedField(.object(index.options))),
                ])
            })),
        ])
    }

    func encodedField(_ value: FieldValue) throws -> StrictJSONValue {
        try fieldEncoder.node(value)
    }

    func graphTermNode(
        _ term: GraphAlgorithmOperation.Term
    ) throws -> StrictJSONValue {
        switch term {
        case .identifier(let value): try encodedField(.string(value))
        case .rdf(let value): try encodedField(.rdfTerm(value))
        }
    }

    func rdfQuadNode(_ quad: RDFQuad) throws -> StrictJSONValue {
        .object([
            ("subject", try encodedField(.rdfTerm(quad.subject.term))),
            ("predicate", .string(quad.predicate.rawValue)),
            ("object", try encodedField(.rdfTerm(quad.object))),
            ("graph", try quad.graph.map {
                try encodedField(.rdfTerm($0.term))
            } ?? .null),
        ])
    }

    func renderValidation(
        _ report: ValidationReport,
        stream: inout EventStream
    ) throws -> ByteString? {
        try stream.write(.object([
            ("type", .string("validationSummary")),
            ("conforms", .bool(report.conforms)),
            ("issueCount", .string(String(report.issueCount))),
        ]))
        var issues = report.makeIssueIterator()
        while let issue = try issues.next() {
            try stream.write(.object([
                ("type", .string("validationIssue")),
                ("severity", .string(validationSeverity(issue.severity))),
                ("code", .string(issue.code)),
                ("messages", .array(issue.messages.map(StrictJSONValue.string))),
                ("focusNode", try issue.focusNode.map {
                    try encodedField(.rdfTerm($0))
                } ?? .null),
                ("path", issue.path.map { .string($0.description) } ?? .null),
                ("value", try issue.value.map {
                    try encodedField(.rdfTerm($0))
                } ?? .null),
                ("sourceConstraintComponent", issue.sourceConstraintComponent.map(StrictJSONValue.string) ?? .null),
                ("sourceShape", try issue.sourceShape.map {
                    try encodedField(.rdfTerm($0))
                } ?? .null),
                ("details", try encodedField(.object(issue.details))),
            ]))
        }
        return report.continuation
    }

    func operationName(_ value: DatabaseOperationIdentifier) -> String {
        switch value {
        case .capabilitiesDescribe: "capabilitiesDescribe"
        case .schemaDescribe: "schemaDescribe"
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

    func jobNode(
        _ job: JobIdentity,
        event: String?
    ) -> StrictJSONValue {
        var fields: [(key: String, value: StrictJSONValue)] = []
        if let event { fields.append(("event", .string(event))) }
        fields.append(("id", .string(job.jobID.description)))
        fields.append(("family", .string(operationName(job.operation.family))))
        fields.append(("kind", .string(job.operation.kind)))
        return .object(fields)
    }

    func timestampNode(_ value: Timestamp) -> StrictJSONValue {
        .object([
            ("secondsSinceUnixEpoch", .string(String(value.secondsSinceUnixEpoch))),
            ("nanoseconds", .string(String(value.nanoseconds))),
        ])
    }

    func jobState(_ value: JobStatusOperation.State) -> String {
        switch value {
        case .pending: "pending"
        case .running: "running"
        case .committingUnsuccessfulOutcome: "committingUnsuccessfulOutcome"
        case .succeeded: "succeeded"
        case .failed: "failed"
        case .cancelled: "cancelled"
        }
    }

    func operationErrorCategory(_ value: OperationErrorCategory) -> String {
        switch value {
        case .invalidRequest: "invalidRequest"
        case .authentication: "authentication"
        case .authorization: "authorization"
        case .notFound: "notFound"
        case .conflict: "conflict"
        case .constraint: "constraint"
        case .resourceLimit: "resourceLimit"
        case .unavailable: "unavailable"
        case .internalFailure: "internalFailure"
        }
    }

    func mutationKind(_ value: MutationExecuteOperation.Kind) -> String {
        switch value {
        case .insert: "insert"
        case .update: "update"
        case .upsert: "upsert"
        case .delete: "delete"
        }
    }

    func validationSeverity(_ value: ValidationReport.Severity) -> String {
        switch value {
        case .information: "information"
        case .warning: "warning"
        case .violation: "violation"
        }
    }

    func indexState(_ value: MaintenanceExecuteOperation.IndexState) -> String {
        switch value {
        case .ready: "ready"
        case .building: "building"
        case .stale: "stale"
        case .failed: "failed"
        }
    }

    func executionKind(_ value: MaintenanceExecuteOperation.ExecutionKind) -> String {
        switch value {
        case .migrations: "migrations"
        case .indexRebuild: "indexRebuild"
        case .compaction: "compaction"
        }
    }

    func schemaValueType(_ value: SchemaDescribeOperation.ValueType) -> String {
        String(describing: value)
    }

    func referenceCardinality(
        _ value: SchemaDescribeOperation.ReferenceCardinality
    ) -> String { String(describing: value) }

    func referenceDeleteRule(
        _ value: SchemaDescribeOperation.ReferenceDeleteRule
    ) -> String { String(describing: value) }

    func hex<T: FixedWidthInteger>(_ value: T, digits: Int) -> String {
        let raw = String(value, radix: 16)
        return String(repeating: "0", count: digits - raw.count) + raw
    }
}
