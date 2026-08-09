import DatabaseKit
import DatabaseSchemaJSON
import DatabaseTypes
import DatabaseWire
import Foundation

struct WireRequestBuilder: Sendable {
    let input = InputSource()
    let fieldDecoder = FieldValueJSONDecoder()
    let scalarDecoder = ExplicitScalarLiteralDecoder()

    func executionOptions(_ command: ParsedCommand) throws -> ExecutionOptions {
        try ExecutionOptions(options: command.options)
    }

    func queryInput(
        language: QueryExecuteOperation.Language,
        specification: String
    ) throws -> QueryExecuteOperation.Input {
        .text(language: language, statement: try input.read(specification))
    }

    func schemaExecutionRequest(
        _ command: ParsedCommand
    ) throws -> SchemaExecuteOperation.Request {
        let manifest = try schemaManifest(command.positionals[0])

        let expectedFingerprint = try command.options
            .value("expected-fingerprint")
            .map(schemaFingerprint)
        switch command.path {
        case ["schema", "plan"]:
            return SchemaExecuteOperation.Request(
                invocation: .plan(
                    manifest: manifest,
                    expectedFingerprint: expectedFingerprint
                )
            )
        case ["schema", "apply"]:
            guard let expectedFingerprint else {
                throw DatabaseCLIError(
                    .input,
                    "Schema apply requires '--expected-fingerprint'"
                )
            }
            guard let idempotencyKey = command.options.value("idempotency-key"),
                  !idempotencyKey.isEmpty else {
                throw DatabaseCLIError(
                    .input,
                    "Schema apply requires '--idempotency-key'"
                )
            }
            return SchemaExecuteOperation.Request(
                invocation: .apply(
                    manifest: manifest,
                    expectedFingerprint: expectedFingerprint,
                    idempotencyKey: idempotencyKey
                )
            )
        default:
            throw DatabaseCLIError(.input, "Unsupported schema execution command")
        }
    }

    func schemaManifest(_ specification: String) throws -> SchemaManifest {
        let manifestText = try input.read(specification)
        let manifest: SchemaManifest
        do {
            manifest = try SchemaJSONCodec().decode(manifestText)
        } catch let error {
            switch error {
            case .inputTooLarge, .collectionTooLarge, .nestingTooDeep,
                    .outputTooLarge:
                throw DatabaseCLIError(.resourceLimit, error.description)
            default:
                throw DatabaseCLIError(.input, error.description)
            }
        }
        return manifest
    }

    func queryRequest(
        _ command: ParsedCommand,
        execution: ExecutionOptions,
        continuation: ByteString?
    ) throws -> QueryExecuteOperation.Request {
        let language = try queryLanguage(command)
        return QueryExecuteOperation.Request(
            input: try queryInput(
                language: language,
                specification: command.positionals[0]
            ),
            parameters: try parameters(command.options),
            graphPartitions: try objectOption(
                "graph-partitions",
                options: command.options
            ),
            page: .init(
                limit: execution.pageSize,
                continuation: continuation
            ),
            budget: execution.budget
        )
    }

    func statementMutationRequest(
        _ command: ParsedCommand,
        execution: ExecutionOptions
    ) throws -> MutationExecuteOperation.Request {
        MutationExecuteOperation.Request(
            input: .statement(
                try queryInput(
                    language: queryLanguage(command),
                    specification: command.positionals[0]
                ),
                parameters: try parameters(command.options)
            ),
            graphPartitions: try objectOption(
                "graph-partitions",
                options: command.options
            ),
            budget: execution.budget
        )
    }

    func commandRequest(
        _ command: ParsedCommand,
        execution: ExecutionOptions
    ) throws -> CommandExecuteOperation.Request {
        let access: CommandAccess
        switch command.options.value("access") ?? "read-only" {
        case "read-only": access = .readOnly
        case "read-write": access = .readWrite
        case let value:
            throw DatabaseCLIError(
                .input,
                "Unknown command access '\(value)'"
            )
        }
        let identifier: CommandIdentifier
        do {
            identifier = try CommandIdentifier(command.positionals[0])
        } catch {
            throw DatabaseCLIError(.input, "Invalid command identifier: \(error)")
        }
        let inputValue = try fieldDecoder.decode(
            input.read(command.positionals[1])
        )
        guard case .object(let commandInput) = inputValue else {
            throw DatabaseCLIError(
                .input,
                "Command input must be a tagged object"
            )
        }
        return CommandRequest(
            command: CommandDeclaration(
                identifier: identifier,
                access: access
            ),
            input: commandInput,
            budget: execution.budget
        )
    }

    func parameters(_ options: CommandOptions) throws -> [QueryParameter] {
        if options.value("parameters") == nil {
            return try scalarParameters(options.values("parameter"))
        }
        guard let specification = options.value("parameters") else { return [] }
        let node = try StrictJSONParser().parse(input.read(specification))
        let entries = try node.array(named: "parameters")
        return try entries.map { entry in
            let object = try StrictJSONObject(entry)
            try object.validateKeys(["position", "name", "value"])
            let rawPosition = try object.required("position").string(named: "position")
            guard let position = UInt32(rawPosition), position > 0 else {
                throw DatabaseCLIError(.input, "Query parameter position is invalid")
            }
            let name = try object.optional("name")?.string(named: "name")
            if let name, name.isEmpty {
                throw DatabaseCLIError(.input, "Query parameter name is empty")
            }
            return QueryParameter(
                position: position,
                name: name,
                value: try fieldDecoder.decode(
                    StrictJSONWriter.encode(object.required("value"))
                )
            )
        }
    }

    func scalarParameters(_ bindings: [String]) throws -> [QueryParameter] {
        var parameters: [QueryParameter] = []
        parameters.reserveCapacity(bindings.count)
        var usedPositions = Set<UInt32>()
        var usedNames = Set<String>()
        for binding in bindings {
            guard let separator = binding.firstIndex(of: "=") else {
                throw DatabaseCLIError(
                    .input,
                    "Parameter binding must use '<selector>=<typed-literal>'"
                )
            }
            let selector = String(binding[..<separator])
            let literal = String(binding[binding.index(after: separator)...])
            guard !selector.isEmpty, !literal.isEmpty else {
                throw DatabaseCLIError(.input, "Parameter binding is empty")
            }
            let position: UInt32
            let name: String?
            if selector.first == "$" {
                guard let parsed = UInt32(selector.dropFirst()), parsed > 0 else {
                    throw DatabaseCLIError(.input, "Parameter position is invalid")
                }
                position = parsed
                name = nil
            } else {
                guard usedNames.insert(selector).inserted else {
                    throw DatabaseCLIError(
                        .input,
                        "Duplicate parameter name '\(selector)'"
                    )
                }
                var candidate: UInt32 = 1
                while usedPositions.contains(candidate) {
                    guard candidate < UInt32.max else {
                        throw DatabaseCLIError(
                            .resourceLimit,
                            "Parameter position space is exhausted"
                        )
                    }
                    candidate += 1
                }
                position = candidate
                name = selector
            }
            guard usedPositions.insert(position).inserted else {
                throw DatabaseCLIError(
                    .input,
                    "Duplicate parameter position '$\(position)'"
                )
            }
            parameters.append(
                QueryParameter(
                    position: position,
                    name: name,
                    value: try scalarDecoder.decode(literal)
                )
            )
        }
        return parameters
    }

    func objectOption(
        _ name: String,
        options: CommandOptions
    ) throws -> FieldObject {
        guard let specification = options.value(name) else {
            return FieldObject()
        }
        return try fieldDecoder.decodeObject(input.read(specification))
    }

    func entityRequest(
        _ command: ParsedCommand,
        execution: ExecutionOptions
    ) throws -> MutationExecuteOperation.Request {
        if command.path.last == "apply" {
            return try entityApplyRequest(
                specification: command.positionals[0],
                execution: execution,
                graphPartitions: objectOption(
                    "graph-partitions",
                    options: command.options
                )
            )
        }
        let kind: MutationExecuteOperation.Kind
        switch command.path.last {
        case "insert": kind = .insert
        case "update": kind = .update
        case "upsert": kind = .upsert
        case "delete": kind = .delete
        default: throw DatabaseCLIError(.input, "Unknown entity mutation")
        }
        let entity = command.positionals[0]
        let identifierSpecification = try input.read(command.positionals[1])
        let identifierValue: FieldValue
        if identifierSpecification.first == "{" {
            identifierValue = try fieldDecoder.decode(identifierSpecification)
        } else {
            identifierValue = try scalarDecoder.decode(identifierSpecification)
        }
        let partitions = try objectOption("partitions", options: command.options)
        let identity = try EntityReference(
            entity: entity,
            id: referenceIdentifier(identifierValue),
            partitions: partitions
        )
        let fields: FieldObject
        if kind == .delete {
            fields = FieldObject()
        } else {
            fields = try fieldDecoder.decodeObject(
                input.read(command.positionals[2])
            )
        }
        return MutationExecuteOperation.Request(
            input: .entities([
                MutationExecuteOperation.Change(
                    kind: kind,
                    identity: identity,
                    fields: fields
                ),
            ]),
            preconditions: try preconditions(
                identity: identity,
                options: command.options
            ),
            graphPartitions: try objectOption(
                "graph-partitions",
                options: command.options
            ),
            budget: execution.budget
        )
    }

    func graphRequest(
        _ command: ParsedCommand,
        execution: ExecutionOptions,
        continuation: ByteString?
    ) throws -> GraphAlgorithmOperation.Request {
        guard let index = command.options.value("index") else {
            throw DatabaseCLIError(.input, "Graph command requires '--index'")
        }
        let source = GraphAlgorithmOperation.Source(
            index: index,
            partitions: try objectOption("partitions", options: command.options),
            graph: try graphSelector(command.options.value("graph")),
            edgeLabel: try command.options.value("edge-label").map(graphTerm)
        )
        let invocation: GraphAlgorithmOperation.Invocation
        switch command.path.last {
        case "shortest-path":
            invocation = .shortestPath(
                source: try requiredGraphTerm("source", command.options),
                target: try requiredGraphTerm("target", command.options),
                maximumDepth: try command.options.integer("maximum-depth", default: 64),
                bidirectional: command.options.contains("bidirectional"),
                maximumNodes: try command.options.integer("maximum-nodes", default: 100_000)
            )
        case "weighted-shortest-path":
            guard let weightProperty = command.options.value("weight-property") else {
                throw DatabaseCLIError(.input, "Weighted path requires '--weight-property'")
            }
            invocation = .weightedShortestPath(
                source: try requiredGraphTerm("source", command.options),
                target: try requiredGraphTerm("target", command.options),
                weightProperty: weightProperty,
                maximumWeight: try finiteDouble(
                    command.options.value("maximum-weight") ?? "1.7976931348623157e308",
                    option: "maximum-weight"
                ),
                maximumNodes: try command.options.integer("maximum-nodes", default: 100_000)
            )
        case "page-rank":
            invocation = .pageRank(
                dampingFactor: try finiteDouble(
                    command.options.value("damping-factor") ?? "0.85",
                    option: "damping-factor"
                ),
                maximumIterations: try command.options.integer("maximum-iterations", default: 100),
                convergenceThreshold: try finiteDouble(
                    command.options.value("convergence-threshold") ?? "0.000001",
                    option: "convergence-threshold"
                ),
                personalizedSource: try command.options.value("personalized-source").map(graphTerm)
            )
        case "community":
            invocation = .community(
                maximumIterations: try command.options.integer("maximum-iterations", default: 100),
                computeModularity: command.options.contains("compute-modularity"),
                minimumCommunitySize: try command.options.integer("minimum-community-size", default: 1),
                seed: try command.options.value("seed").map {
                    guard let value = UInt64($0) else {
                        throw DatabaseCLIError(.input, "Invalid '--seed'")
                    }
                    return value
                }
            )
        case "cycles":
            invocation = .cycleDetection(
                maximumCycles: try command.options.integer("maximum-cycles", default: 1_000),
                maximumNodes: try command.options.integer("maximum-nodes", default: 100_000)
            )
        case "strongly-connected-components":
            invocation = .stronglyConnectedComponents(
                maximumComponents: try command.options.integer("maximum-components", default: 10_000),
                maximumNodes: try command.options.integer("maximum-nodes", default: 100_000)
            )
        case "topological-sort":
            invocation = .topologicalSort(
                maximumNodes: try command.options.integer("maximum-nodes", default: 100_000)
            )
        default:
            throw DatabaseCLIError(.input, "Unknown graph algorithm")
        }
        return GraphAlgorithmOperation.Request(
            source: source,
            invocation: invocation,
            page: .init(limit: execution.pageSize, continuation: continuation),
            budget: execution.budget
        )
    }

    func ontologyRequest(
        _ command: ParsedCommand,
        execution: ExecutionOptions,
        continuation: ByteString?
    ) throws -> OntologyExecuteOperation.Request {
        let invocation: OntologyExecuteOperation.Invocation
        switch command.path.last {
        case "describe":
            invocation = .describe(ontology: command.positionals[0])
        case "upsert":
            invocation = .upsert(
                document: try ontologyDocument(command.positionals[0]),
                expectedRevision: try optionalUInt64("expected-revision", command.options)
            )
        case "delete":
            invocation = .delete(
                ontology: command.positionals[0],
                expectedRevision: try optionalUInt64("expected-revision", command.options)
            )
        case "reason":
            let profile: OntologyExecuteOperation.ReasoningProfile
            switch command.options.value("profile-kind") ?? "rdfs" {
            case "rdfs": profile = .rdfs
            case "owl-rl": profile = .owlRL
            case let value:
                throw DatabaseCLIError(.input, "Unknown reasoning profile '\(value)'")
            }
            invocation = .reason(ontology: command.positionals[0], profile: profile)
        case "hierarchy":
            let resourceKind: OntologyExecuteOperation.HierarchyResourceKind
            switch command.options.value("resource-kind") ?? "class" {
            case "class": resourceKind = .class
            case "object-property": resourceKind = .objectProperty
            case "data-property": resourceKind = .dataProperty
            case let value:
                throw DatabaseCLIError(.input, "Unknown resource kind '\(value)'")
            }
            let direction: OntologyExecuteOperation.HierarchyDirection
            switch command.options.value("direction") ?? "ancestors" {
            case "ancestors": direction = .ancestors
            case "descendants": direction = .descendants
            case let value:
                throw DatabaseCLIError(.input, "Unknown hierarchy direction '\(value)'")
            }
            invocation = .hierarchy(
                ontology: command.positionals[0],
                resource: command.positionals[1],
                resourceKind: resourceKind,
                direction: direction,
                maximumDepth: try command.options.integer("maximum-depth", default: 64)
            )
        case "validate-schema":
            invocation = .validateSchema(ontology: command.positionals[0])
        default:
            throw DatabaseCLIError(.input, "Unknown ontology command")
        }
        return OntologyExecuteOperation.Request(
            invocation: invocation,
            page: .init(limit: execution.pageSize, continuation: continuation),
            budget: execution.budget
        )
    }

    func shaclRequest(
        _ command: ParsedCommand,
        execution: ExecutionOptions,
        continuation: ByteString?
    ) throws -> SHACLExecuteOperation.Request {
        let invocation: SHACLExecuteOperation.Invocation
        switch command.path.last {
        case "describe":
            invocation = .describeShapes(graph: command.positionals[0])
        case "upsert":
            let dataset = try NQuadsDecoder().decode(
                from: input.read(command.positionals[1])
            )
            invocation = .upsertShapes(
                graph: command.positionals[0],
                shapes: dataset.quads,
                expectedRevision: try optionalUInt64("expected-revision", command.options)
            )
        case "delete":
            invocation = .deleteShapes(
                graph: command.positionals[0],
                expectedRevision: try optionalUInt64("expected-revision", command.options)
            )
        case "validate":
            guard let entity = command.options.value("entity"),
                  let index = command.options.value("index") else {
                throw DatabaseCLIError(.input, "SHACL validate requires '--entity' and '--index'")
            }
            invocation = .validate(
                shapesGraph: command.positionals[0],
                data: SHACLExecuteOperation.DataSource(
                    entity: entity,
                    index: index,
                    partitions: try objectOption("partitions", options: command.options),
                    graph: try shaclDataGraph(command.options.value("data-graph"))
                ),
                focus: try shaclFocus(command.options.value("focus")),
                entailment: try shaclEntailment(command.options.value("entailment"))
            )
        default:
            throw DatabaseCLIError(.input, "Unknown SHACL command")
        }
        return SHACLExecuteOperation.Request(
            invocation: invocation,
            page: .init(limit: execution.pageSize, continuation: continuation),
            budget: execution.budget
        )
    }

    func maintenanceRequest(
        _ command: ParsedCommand,
        execution: ExecutionOptions,
        continuation: ByteString?
    ) throws -> MaintenanceExecuteOperation.Request {
        let invocation: MaintenanceExecuteOperation.Invocation
        switch command.path {
        case ["migration", "status"]:
            invocation = .migrationStatus
        case ["migration", "run"]:
            invocation = .runMigrations(
                targetVersion: try command.options.value("target-version").map(schemaVersion)
            )
        case ["index", "status"]:
            invocation = .indexStatus(
                entity: command.options.value("entity"),
                index: command.options.value("index"),
                partitions: try objectOption("partitions", options: command.options)
            )
        case ["index", "rebuild"]:
            invocation = .rebuildIndex(
                entity: command.positionals[0],
                index: command.positionals[1],
                partitions: try objectOption("partitions", options: command.options),
                batchSize: try command.options.integer("batch-size", default: 1_000)
            )
        case ["maintenance", "compact"]:
            invocation = .compact
        default:
            throw DatabaseCLIError(.input, "Unknown maintenance command")
        }
        return MaintenanceExecuteOperation.Request(
            invocation: invocation,
            continuation: continuation,
            budget: execution.budget
        )
    }
}

private extension WireRequestBuilder {
    func schemaFingerprint(_ value: String) throws -> SchemaFingerprint {
        do {
            return try SchemaFingerprint(Base64URL.decode(value))
        } catch let error as DatabaseCLIError {
            throw error
        } catch {
            throw DatabaseCLIError(
                .input,
                "Invalid schema fingerprint: \(error)"
            )
        }
    }

    func queryLanguage(
        _ command: ParsedCommand
    ) throws -> QueryExecuteOperation.Language {
        switch command.path.last {
        case "sql": return .sql
        case "sparql": return .sparql
        default:
            throw DatabaseCLIError(.input, "Unknown query language")
        }
    }

    func preconditions(
        identity: EntityReference,
        options: CommandOptions
    ) throws -> [MutationExecuteOperation.Precondition] {
        let selected = [
            options.value("expected-version") != nil,
            options.contains("must-exist"),
            options.contains("must-not-exist"),
        ].filter { $0 }.count
        guard selected <= 1 else {
            throw DatabaseCLIError(.input, "Entity precondition options are mutually exclusive")
        }
        if let version = options.value("expected-version") {
            return [.expectedVersion(identity: identity, version: try Base64URL.decode(version))]
        }
        if options.contains("must-exist") { return [.mustExist(identity)] }
        if options.contains("must-not-exist") { return [.mustNotExist(identity)] }
        return []
    }

    func entityApplyRequest(
        specification: String,
        execution: ExecutionOptions,
        graphPartitions: FieldObject
    ) throws -> MutationExecuteOperation.Request {
        let root = try StrictJSONObject(
            StrictJSONParser().parse(input.read(specification))
        )
        try root.validateKeys(["changes", "preconditions"])
        let changes = try root.required("changes").array(named: "changes").map {
            try entityChange($0)
        }
        let preconditions = try root.optional("preconditions")?
            .array(named: "preconditions")
            .map { try entityPrecondition($0) } ?? []
        guard !changes.isEmpty else {
            throw DatabaseCLIError(.input, "Entity apply requires at least one change")
        }
        return MutationExecuteOperation.Request(
            input: .entities(changes),
            preconditions: preconditions,
            graphPartitions: graphPartitions,
            budget: execution.budget
        )
    }

    func entityChange(_ node: StrictJSONValue) throws -> MutationExecuteOperation.Change {
        let object = try StrictJSONObject(node)
        try object.validateKeys(["kind", "identity", "fields"])
        let kind: MutationExecuteOperation.Kind
        switch try object.required("kind").string(named: "kind") {
        case "insert": kind = .insert
        case "update": kind = .update
        case "upsert": kind = .upsert
        case "delete": kind = .delete
        case let value: throw DatabaseCLIError(.input, "Unknown entity change kind '\(value)'")
        }
        let identityValue = try fieldDecoder.decode(
            StrictJSONWriter.encode(object.required("identity"))
        )
        guard case .reference(let identity) = identityValue else {
            throw DatabaseCLIError(.input, "Entity change identity must be a tagged reference")
        }
        let fields: FieldObject
        if let value = object.optional("fields") {
            guard case .object(let object) = try fieldDecoder.decode(
                StrictJSONWriter.encode(value)
            ) else {
                throw DatabaseCLIError(.input, "Entity change fields must be a tagged object")
            }
            fields = object
        } else {
            fields = FieldObject()
        }
        return MutationExecuteOperation.Change(kind: kind, identity: identity, fields: fields)
    }

    func entityPrecondition(
        _ node: StrictJSONValue
    ) throws -> MutationExecuteOperation.Precondition {
        let object = try StrictJSONObject(node)
        try object.validateKeys(["kind", "identity", "version"])
        let identityValue = try fieldDecoder.decode(
            StrictJSONWriter.encode(object.required("identity"))
        )
        guard case .reference(let identity) = identityValue else {
            throw DatabaseCLIError(.input, "Precondition identity must be a tagged reference")
        }
        switch try object.required("kind").string(named: "kind") {
        case "expectedVersion":
            return .expectedVersion(
                identity: identity,
                version: try Base64URL.decode(
                    object.required("version").string(named: "version")
                )
            )
        case "mustExist": return .mustExist(identity)
        case "mustNotExist": return .mustNotExist(identity)
        case let value: throw DatabaseCLIError(.input, "Unknown precondition '\(value)'")
        }
    }

    func referenceIdentifier(_ value: FieldValue) throws -> ReferenceIdentifier {
        switch value {
        case .bool(let value): .bool(value)
        case .int8(let value): .int8(value)
        case .int16(let value): .int16(value)
        case .int32(let value): .int32(value)
        case .int64(let value): .int64(value)
        case .uint8(let value): .uint8(value)
        case .uint16(let value): .uint16(value)
        case .uint32(let value): .uint32(value)
        case .uint64(let value): .uint64(value)
        case .string(let value): .string(value)
        case .bytes(let value): .bytes(value)
        case .uuid(let value): .uuid(value)
        case .array(let values): .composite(try values.map(referenceIdentifier))
        default:
            throw DatabaseCLIError(.input, "FieldValue cannot represent an entity identifier")
        }
    }

    func graphSelector(_ raw: String?) throws -> GraphAlgorithmOperation.GraphSelector {
        guard let raw else { return .all }
        switch raw {
        case "all": return .all
        case "default": return .defaultGraph
        default: return .named(try graphTerm(raw))
        }
    }

    func requiredGraphTerm(
        _ name: String,
        _ options: CommandOptions
    ) throws -> GraphAlgorithmOperation.Term {
        guard let value = options.value(name) else {
            throw DatabaseCLIError(.input, "Graph command requires '--\(name)'")
        }
        return try graphTerm(value)
    }

    func graphTerm(_ specification: String) throws -> GraphAlgorithmOperation.Term {
        switch try fieldDecoder.decode(input.read(specification)) {
        case .string(let value): return .identifier(value)
        case .rdfTerm(let value): return .rdf(value)
        default:
            throw DatabaseCLIError(.input, "Graph term must be a tagged string or rdfTerm")
        }
    }

    func finiteDouble(_ raw: String, option: String) throws -> Double {
        guard let value = Double(raw), value.isFinite else {
            throw DatabaseCLIError(.input, "Invalid finite '--\(option)' value")
        }
        return value
    }

    func optionalUInt64(
        _ name: String,
        _ options: CommandOptions
    ) throws -> UInt64? {
        guard let raw = options.value(name) else { return nil }
        guard let value = UInt64(raw) else {
            throw DatabaseCLIError(.input, "Invalid '--\(name)' value")
        }
        return value
    }

    func ontologyDocument(
        _ specification: String
    ) throws -> OntologyExecuteOperation.Document {
        let object = try StrictJSONObject(
            StrictJSONParser().parse(input.read(specification))
        )
        try object.validateKeys(["ontology", "imports", "axioms"])
        let ontology = try object.required("ontology").string(named: "ontology")
        let imports = try object.optional("imports")?
            .array(named: "imports")
            .map { try $0.string(named: "imports[]") } ?? []
        let axiomsSpecification = try object.required("axioms").string(named: "axioms")
        let dataset = try NQuadsDecoder().decode(from: input.read(axiomsSpecification))
        return OntologyExecuteOperation.Document(
            ontology: ontology,
            imports: imports,
            axioms: dataset.quads
        )
    }

    func shaclDataGraph(_ raw: String?) throws -> SHACLExecuteOperation.DataGraph {
        guard let raw, raw != "default" else { return .defaultGraph }
        guard case .rdfTerm(let term) = try fieldDecoder.decode(input.read(raw)) else {
            throw DatabaseCLIError(.input, "Named SHACL data graph must be a tagged rdfTerm")
        }
        return .named(term)
    }

    func shaclFocus(_ raw: String?) throws -> SHACLExecuteOperation.Focus {
        guard let raw, raw != "targets" else { return .targets }
        let value = try fieldDecoder.decode(input.read(raw))
        guard case .array(let values) = value else {
            throw DatabaseCLIError(.input, "SHACL focus must be 'targets' or a tagged array")
        }
        if values.allSatisfy({ if case .rdfTerm = $0 { true } else { false } }) {
            return .nodes(try values.map {
                guard case .rdfTerm(let term) = $0 else {
                    throw DatabaseCLIError(.input, "Invalid RDF focus")
                }
                return term
            })
        }
        if values.allSatisfy({ if case .reference = $0 { true } else { false } }) {
            return .entities(try values.map {
                guard case .reference(let reference) = $0 else {
                    throw DatabaseCLIError(.input, "Invalid entity focus")
                }
                return reference
            })
        }
        throw DatabaseCLIError(.input, "SHACL focus array must contain only rdfTerm or reference values")
    }

    func shaclEntailment(_ raw: String?) throws -> SHACLExecuteOperation.Entailment {
        guard let raw, raw != "none" else { return .none }
        if raw == "rdfs" { return .rdfs }
        if raw.hasPrefix("owl:") {
            let ontology = String(raw.dropFirst(4))
            guard !ontology.isEmpty else {
                throw DatabaseCLIError(.input, "OWL entailment requires an ontology")
            }
            return .owl(ontology: ontology)
        }
        throw DatabaseCLIError(.input, "Unknown SHACL entailment '\(raw)'")
    }

    func schemaVersion(_ raw: String) throws -> SchemaVersion {
        let components = raw.split(separator: ".")
        guard components.count == 3,
              let major = UInt32(components[0]),
              let minor = UInt32(components[1]),
              let patch = UInt32(components[2]) else {
            throw DatabaseCLIError(.input, "Schema version must be MAJOR.MINOR.PATCH")
        }
        return SchemaVersion(major, minor, patch)
    }
}
