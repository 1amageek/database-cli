import DatabaseWire

struct ShellCompletionEntry: Sendable, Hashable, Comparable {
    let context: String
    let value: String

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.context != rhs.context { return lhs.context < rhs.context }
        return lhs.value < rhs.value
    }
}

/// One immutable, session-local completion view.
///
/// Static command metadata is always available. Server-advertised features,
/// job kinds, entities, and indexes are added only after a successful bounded
/// capabilities/schema fetch; completion never performs network I/O itself.
struct ShellCompletionSnapshot: Sendable, Hashable {
    let entries: [ShellCompletionEntry]

    init(
        catalog: CommandCatalog,
        profileNames: [String],
        capabilities: CapabilitiesDescribeOperation.Response? = nil,
        schema: SchemaDescribeOperation.Response? = nil
    ) {
        let advertisedFeatures = capabilities.map {
            Set($0.features.map(\.identifier))
        }
        let commands = catalog.commands.filter { command in
            guard let capability = command.capability,
                  let advertisedFeatures else {
                return true
            }
            return advertisedFeatures.contains(capability)
        }
        var result = Set<ShellCompletionEntry>()

        for command in commands where command.path != ["help"] {
            for index in command.path.indices {
                let context = command.path[..<index].joined(separator: " ")
                result.insert(
                    ShellCompletionEntry(
                        context: context.isEmpty ? "" : context + " ",
                        value: command.path[index]
                    )
                )
            }
            let commandContext = command.path.joined(separator: " ") + " "
            for option in command.options {
                result.insert(
                    ShellCompletionEntry(
                        context: commandContext,
                        value: "--\(option.name)"
                    )
                )
            }
            for profile in profileNames {
                result.insert(
                    ShellCompletionEntry(
                        context: commandContext + "--profile ",
                        value: profile
                    )
                )
            }
            if command.option(named: "output") != nil {
                for format in ["table", "jsonl", "json", "csv", "nquads"] {
                    result.insert(
                        ShellCompletionEntry(
                            context: commandContext + "--output ",
                            value: format
                        )
                    )
                }
            }
            if let family = Self.jobFamily(for: command.capability) {
                for operation in capabilities?.jobOperations ?? []
                where operation.family == family {
                    result.insert(
                        ShellCompletionEntry(
                            context: commandContext + "--as-job ",
                            value: operation.kind
                        )
                    )
                }
            }
        }

        Self.insertMetaCommands(into: &result, profiles: profileNames)
        if let schema {
            Self.insertSchema(
                schema,
                commands: commands,
                into: &result
            )
        }
        self.entries = result.sorted()
    }

    func values(in context: String) -> [String] {
        entries.lazy
            .filter { $0.context == context }
            .map(\.value)
    }
}

private extension ShellCompletionSnapshot {
    static func insertMetaCommands(
        into entries: inout Set<ShellCompletionEntry>,
        profiles: [String]
    ) {
        for command in [
            "\\help", "\\profile", "\\database", "\\base", "\\composition", "\\output",
            "\\timing", "\\budget",
            "\\page-size", "\\next", "\\history", "\\mode", "\\g",
            "\\clear", "\\quit",
        ] {
            entries.insert(.init(context: "", value: command))
        }
        for profile in profiles {
            entries.insert(.init(context: "\\profile ", value: profile))
        }
        for format in ["table", "jsonl", "json", "csv", "nquads"] {
            entries.insert(.init(context: "\\output ", value: format))
        }
        for value in ["on", "off"] {
            entries.insert(.init(context: "\\timing ", value: value))
        }
        for mode in [
            "command", "sql-query", "sql-mutation", "sparql-query",
            "sparql-update",
        ] {
            entries.insert(.init(context: "\\mode ", value: mode))
        }
    }

    static func insertSchema(
        _ schema: SchemaDescribeOperation.Response,
        commands: [CommandDescriptor],
        into entries: inout Set<ShellCompletionEntry>
    ) {
        let entities = schema.entities.map(\.name).sorted()
        for entity in entities {
            for context in [
                "schema show ", "inspect entities ", "entity insert ",
                "entity update ", "entity upsert ", "entity delete ",
                "index rebuild ", "index status --entity ",
                "inspect indexes --entity ", "inspect graph --entity ",
                "shacl validate --entity ",
            ] {
                entries.insert(.init(context: context, value: entity))
            }
        }

        let indexes = schema.entities.flatMap { entity in
            entity.indexes.map { (entity: entity.name, index: $0.name) }
        }
        for value in indexes {
            entries.insert(
                .init(
                    context: "index rebuild \(value.entity) ",
                    value: value.index
                )
            )
            for context in [
                "index status --index ", "shacl validate --index ",
            ] {
                entries.insert(.init(context: context, value: value.index))
            }
            for command in commands where command.path.first == "graph" {
                entries.insert(
                    .init(
                        context: command.path.joined(separator: " ")
                            + " --index ",
                        value: value.index
                    )
                )
            }
        }
    }

    static func jobFamily(
        for capability: String?
    ) -> DatabaseOperationIdentifier? {
        switch capability {
        case "schema.execute": .schemaExecute
        case "query.execute": .queryExecute
        case "mutation.execute": .mutationExecute
        case "graph.algorithm": .graphAlgorithm
        case "ontology.execute": .ontologyExecute
        case "shacl.execute": .shaclExecute
        case "command.execute": .commandExecute
        case "maintenance.execute": .maintenanceExecute
        default: nil
        }
    }
}
