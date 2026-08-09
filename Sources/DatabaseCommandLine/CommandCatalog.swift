public enum CommandOptionValueMode: Sendable, Hashable {
    case flag
    case value(String)
}

public struct CommandOptionDescriptor: Sendable, Hashable {
    public let name: String
    public let valueMode: CommandOptionValueMode
    public let minimumOccurrences: Int
    public let maximumOccurrences: Int?
    public let defaultValue: String?
    public let conflictsWith: Set<String>
    public let requires: Set<String>
    public let summary: String

    public init(
        name: String,
        valueMode: CommandOptionValueMode,
        minimumOccurrences: Int = 0,
        maximumOccurrences: Int? = 1,
        defaultValue: String? = nil,
        conflictsWith: Set<String> = [],
        requires: Set<String> = [],
        summary: String
    ) {
        self.name = name
        self.valueMode = valueMode
        self.minimumOccurrences = minimumOccurrences
        self.maximumOccurrences = maximumOccurrences
        self.defaultValue = defaultValue
        self.conflictsWith = conflictsWith
        self.requires = requires
        self.summary = summary
    }
}

public struct CommandDescriptor: Sendable, Hashable {
    public let path: [String]
    public let positionalRange: ClosedRange<Int>
    public let usage: String
    public let summary: String
    public let options: [CommandOptionDescriptor]
    public let capability: String?

    public init(
        path: [String],
        positionalRange: ClosedRange<Int>,
        usage: String,
        summary: String,
        options: [CommandOptionDescriptor] = [],
        capability: String? = nil
    ) {
        self.path = path
        self.positionalRange = positionalRange
        self.usage = usage
        self.summary = summary
        self.options = options
        self.capability = capability
    }

    public func option(named name: String) -> CommandOptionDescriptor? {
        options.first { $0.name == name }
    }
}

public struct CommandCatalog: Sendable {
    public let commands: [CommandDescriptor]
    public let commonOptions: [CommandOptionDescriptor]
    private let commandsByPath: [[String]: CommandDescriptor]
    private let commonOptionsByName: [String: CommandOptionDescriptor]

    public init(
        commands: [CommandDescriptor],
        commonOptions: [CommandOptionDescriptor]
    ) {
        self.commands = commands
        self.commonOptions = commonOptions
        self.commandsByPath = Dictionary(
            uniqueKeysWithValues: commands.map { ($0.path, $0) }
        )
        self.commonOptionsByName = Dictionary(
            uniqueKeysWithValues: commonOptions.map { ($0.name, $0) }
        )
    }

    public func command(for path: [String]) -> CommandDescriptor? {
        commandsByPath[path]
    }

    public func option(
        named name: String,
        for command: CommandDescriptor
    ) -> CommandOptionDescriptor? {
        command.option(named: name) ?? commonOptionsByName[name]
    }

    public func childCommands(of path: [String]) -> [CommandDescriptor] {
        commands.filter {
            $0.path.count == path.count + 1
                && $0.path.starts(with: path)
        }.sorted { $0.path.lexicographicallyPrecedes($1.path) }
    }

    public static let standard = CommandCatalog.makeStandard()
}

private extension CommandOptionDescriptor {
    static func value(
        _ name: String,
        _ valueName: String,
        summary: String,
        required: Bool = false,
        repeatable: Bool = false,
        defaultValue: String? = nil,
        conflictsWith: Set<String> = [],
        requires: Set<String> = []
    ) -> Self {
        Self(
            name: name,
            valueMode: .value(valueName),
            minimumOccurrences: required ? 1 : 0,
            maximumOccurrences: repeatable ? nil : 1,
            defaultValue: defaultValue,
            conflictsWith: conflictsWith,
            requires: requires,
            summary: summary
        )
    }

    static func flag(
        _ name: String,
        summary: String,
        conflictsWith: Set<String> = [],
        requires: Set<String> = []
    ) -> Self {
        Self(
            name: name,
            valueMode: .flag,
            conflictsWith: conflictsWith,
            requires: requires,
            summary: summary
        )
    }
}

private extension CommandCatalog {
    static func makeStandard() -> CommandCatalog {
        let common: [CommandOptionDescriptor] = [
            .value("profile", "name", summary: "Use a saved connection profile."),
            .value("endpoint", "url", summary: "Override the profile endpoint."),
            .value("database", "id", summary: "Override the database routing identity."),
            .value("tenant", "id", summary: "Override the tenant routing identity."),
            .value("workspace", "id", summary: "Override the workspace routing identity."),
            .value("trace-id", "id", summary: "Attach an operation trace identifier."),
            .value("idempotency-key", "key", summary: "Attach an idempotency key."),
            .value("output", "format", summary: "Select table, jsonl, json, csv, or nquads output."),
            .value("page-size", "count", summary: "Limit one response page."),
            .value("continuation", "base64url", summary: "Resume a detached result page.", conflictsWith: ["all"]),
            .value("parameters", "typed-json", summary: "Supply the canonical typed parameter map.", conflictsWith: ["parameter"]),
            .value("parameter", "binding", summary: "Supply one explicitly typed scalar parameter.", repeatable: true, conflictsWith: ["parameters"]),
            .value("graph-partitions", "typed-json", summary: "Supply graph partition values."),
            .value("as-job", "kind", summary: "Start the advertised operation as a persistent job."),
            .value("maximum-rows", "count", summary: "Set the execution row budget."),
            .value("maximum-work-units", "count", summary: "Set the execution work budget."),
            .value("maximum-intermediate-rows", "count", summary: "Set the intermediate-row budget."),
            .value("maximum-intermediate-bytes", "bytes", summary: "Set the intermediate-byte budget."),
            .value("timeout-milliseconds", "milliseconds", summary: "Set the server execution timeout."),
            .value("max-total-rows", "count", summary: "Bound aggregate rows fetched by --all."),
            .value("max-total-bytes", "bytes", summary: "Bound aggregate bytes fetched by --all."),
            .value("max-pages", "count", summary: "Bound aggregate pages fetched by --all."),
            .flag("all", summary: "Fetch pages until all aggregate limits are reached.", conflictsWith: ["continuation"], requires: ["max-total-rows", "max-total-bytes", "max-pages"]),
        ]

        var commands: [CommandDescriptor] = []
        func add(
            _ path: [String],
            _ range: ClosedRange<Int>,
            usage: String,
            summary: String,
            options: [CommandOptionDescriptor] = [],
            capability: String? = nil
        ) {
            commands.append(
                CommandDescriptor(
                    path: path,
                    positionalRange: range,
                    usage: usage,
                    summary: summary,
                    options: options,
                    capability: capability
                )
            )
        }

        let standaloneStorageOptions: [CommandOptionDescriptor] = [
            .value(
                "storage",
                "sqlite|postgresql|foundationdb",
                summary: "Select the standalone storage backend.",
                defaultValue: "sqlite"
            ),
            .flag(
                "memory",
                summary: "Use process-local SQLite memory storage."
            ),
            .value(
                "postgres-host",
                "host",
                summary: "Connect to PostgreSQL over TCP."
            ),
            .value(
                "postgres-port",
                "port",
                summary: "Set the PostgreSQL TCP port.",
                defaultValue: "5432"
            ),
            .value(
                "postgres-unix-socket",
                "path",
                summary: "Connect through a PostgreSQL Unix socket."
            ),
            .value(
                "postgres-user",
                "name",
                summary: "Set the PostgreSQL role."
            ),
            .value(
                "postgres-password-file",
                "path",
                summary: "Read the PostgreSQL password from an owner-only file."
            ),
            .value(
                "postgres-database",
                "name",
                summary: "Set the PostgreSQL database."
            ),
            .value(
                "postgres-table",
                "name",
                summary: "Set the PostgreSQL storage table.",
                defaultValue: "kv_store"
            ),
            .value(
                "postgres-schema-management",
                "create-if-needed|assume-exists",
                summary: "Select PostgreSQL table provisioning behavior.",
                defaultValue: "create-if-needed"
            ),
            .value(
                "postgres-tls",
                "disable|require",
                summary: "Select PostgreSQL transport security.",
                defaultValue: "disable"
            ),
            .value(
                "fdb-cluster-file",
                "path",
                summary: "Select an explicit FoundationDB cluster."
            ),
        ]

        add(["help"], 0...3, usage: "[command]", summary: "Show command-specific help.")
        add(["version"], 0...0, usage: "", summary: "Show the CLI version.")
        add(["capabilities"], 0...0, usage: "", summary: "Describe server capabilities.", capability: "capabilities.describe")
        add(["open"], 0...1, usage: "[path] [storage options]", summary: "Open a standalone database in an interactive shell.", options: standaloneStorageOptions + [
            .value("schema", "manifest", summary: "Validate and apply a strict Schema JSON manifest before opening the shell."),
            .value("mode", "mode", summary: "Select the initial shell mode.", defaultValue: "sql-query"),
            .value("maximum-frame-bytes", "bytes", summary: "Bound one private DatabaseWire frame.", defaultValue: "16777216"),
            .value("history-file", "path", summary: "Select the persistent history file."),
            .flag("persist-history", summary: "Persist non-credential command history."),
        ])
        add(["serve"], 0...1, usage: "[path] --profile <name> [storage options]", summary: "Run a standalone database server in the foreground.", options: standaloneStorageOptions + [
            .value("profile", "name", summary: "Create or use the client profile for this server.", required: true),
            .value("config", "path", summary: "Use an explicit server configuration instead of the profile-owned configuration."),
            .value("listen", "host:port", summary: "Override the listener address."),
            .value("database", "id", summary: "Set the database routing identity for a new configuration.", defaultValue: "main"),
            .value("tenant", "id", summary: "Set the tenant routing identity for a new configuration."),
            .value("workspace", "id", summary: "Set the workspace routing identity for a new configuration."),
        ])
        add(["shell"], 0...0, usage: "", summary: "Start the explicit-mode interactive shell.", options: [
            .value("history-file", "path", summary: "Select the persistent history file."),
            .value("mode", "mode", summary: "Select command, sql-query, sql-mutation, sparql-query, or sparql-update.", defaultValue: "command"),
            .flag("persist-history", summary: "Persist non-credential command history."),
        ])
        add(["fdb"], 1...64, usage: "<cluster|catalog|raw> ...", summary: "Delegate bounded FoundationDB diagnostics.")

        add(["profile", "list"], 0...0, usage: "", summary: "List connection profiles.")
        add(["profile", "create"], 1...1, usage: "<name> --endpoint <url>", summary: "Create a connection profile.", options: [
            .value("endpoint", "url", summary: "Set the profile endpoint.", required: true),
            .value("database", "id", summary: "Set the database routing identity.", defaultValue: "main"),
            .value("tenant", "id", summary: "Set the tenant routing identity."),
            .value("workspace", "id", summary: "Set the workspace routing identity."),
            .value("token-environment", "name", summary: "Select the profile-specific token environment variable."),
        ])
        for action in ["show", "use", "remove"] {
            add(["profile", action], 1...1, usage: "<name>", summary: "\(action.capitalized) a connection profile.")
        }
        add(["auth", "login"], 0...0, usage: "", summary: "Store a profile credential.", options: [
            .value("token-environment", "name", summary: "Read the token from a named environment variable."),
        ])
        add(["auth", "logout"], 0...0, usage: "", summary: "Remove a profile credential.")
        add(["schema", "list"], 0...0, usage: "", summary: "List schema entities.", capability: "schema.describe")
        add(["schema", "show"], 1...1, usage: "<entity>", summary: "Describe one schema entity.", capability: "schema.describe")
        add(["schema", "plan"], 1...1, usage: "<manifest|@path|@->", summary: "Plan a strict Schema JSON manifest without changing the database.", options: [
            .value("expected-fingerprint", "base64url", summary: "Require the current canonical schema fingerprint."),
        ], capability: "schema.execute")
        add(["schema", "apply"], 1...1, usage: "<manifest|@path|@-> --expected-fingerprint <base64url> --idempotency-key <key>", summary: "Atomically publish a strict Schema JSON manifest.", options: [
            .value("expected-fingerprint", "base64url", summary: "Require the current canonical schema fingerprint.", required: true),
            .value("idempotency-key", "key", summary: "Identify this schema publication attempt.", required: true),
        ], capability: "schema.execute")

        for language in ["sql", "sparql"] {
            add(["query", language], 1...1, usage: "<statement|@path|@->", summary: "Execute a read-only \(language.uppercased()) statement.", capability: "query.execute")
            add(["mutate", language], 1...1, usage: "<statement|@path|@->", summary: "Execute a mutating \(language.uppercased()) statement.", capability: "mutation.execute")
        }

        let preconditions: [CommandOptionDescriptor] = [
            .value("partitions", "typed-json", summary: "Supply entity partition values."),
            .value("expected-version", "version", summary: "Require the current entity version."),
            .flag("must-exist", summary: "Require the entity to exist.", conflictsWith: ["must-not-exist"]),
            .flag("must-not-exist", summary: "Require the entity not to exist.", conflictsWith: ["must-exist"]),
        ]
        for action in ["insert", "update", "upsert"] {
            add(["entity", action], 3...3, usage: "<entity> <id> <fields>", summary: "Apply a canonical entity \(action).", options: preconditions, capability: "mutation.execute")
        }
        add(["entity", "delete"], 2...2, usage: "<entity> <id>", summary: "Delete an entity.", options: preconditions, capability: "mutation.execute")
        add(["entity", "apply"], 1...1, usage: "<manifest>", summary: "Apply an atomic entity change manifest.", capability: "mutation.execute")

        let graphOptions = [
            "index", "partitions", "graph", "edge-label", "source", "target",
            "maximum-depth", "maximum-nodes", "weight-property", "maximum-weight",
            "damping-factor", "maximum-iterations", "convergence-threshold",
            "personalized-source", "minimum-community-size", "seed",
            "maximum-cycles", "maximum-components",
        ].map {
            CommandOptionDescriptor.value(
                $0,
                "value",
                summary: "Configure graph execution \($0).",
                required: $0 == "index"
            )
        }
            + [
                .flag("bidirectional", summary: "Use bidirectional traversal."),
                .flag("compute-modularity", summary: "Compute community modularity."),
            ]
        for action in [
            "shortest-path", "weighted-shortest-path", "page-rank", "community",
            "cycles", "strongly-connected-components", "topological-sort",
        ] {
            add(["graph", action], 0...0, usage: "--index <name> [options]", summary: "Run the \(action) graph algorithm.", options: graphOptions, capability: "graph.algorithm")
        }

        add(["ontology", "describe"], 1...1, usage: "<ontology>", summary: "Describe an ontology.", capability: "ontology.execute")
        add(["ontology", "upsert"], 1...1, usage: "<document>", summary: "Upsert an ontology document.", options: [.value("expected-revision", "revision", summary: "Require the current ontology revision.")], capability: "ontology.execute")
        add(["ontology", "delete"], 1...1, usage: "<ontology>", summary: "Delete an ontology.", options: [.value("expected-revision", "revision", summary: "Require the current ontology revision.")], capability: "ontology.execute")
        add(["ontology", "reason"], 1...1, usage: "<ontology>", summary: "Run ontology reasoning.", options: [.value("profile-kind", "kind", summary: "Select the reasoning profile.")], capability: "ontology.execute")
        add(["ontology", "hierarchy"], 2...2, usage: "<ontology> <resource>", summary: "Traverse an ontology hierarchy.", options: [
            .value("resource-kind", "kind", summary: "Select the resource kind."),
            .value("direction", "direction", summary: "Select traversal direction."),
            .value("maximum-depth", "depth", summary: "Bound hierarchy traversal depth."),
        ], capability: "ontology.execute")
        add(["ontology", "validate-schema"], 1...1, usage: "<ontology>", summary: "Validate ontology/schema alignment.", capability: "ontology.execute")

        add(["shacl", "describe"], 1...1, usage: "<graph>", summary: "Describe a SHACL shapes graph.", capability: "shacl.execute")
        add(["shacl", "upsert"], 2...2, usage: "<graph> <nquads>", summary: "Upsert a SHACL shapes graph.", options: [.value("expected-revision", "revision", summary: "Require the current shapes revision.")], capability: "shacl.execute")
        add(["shacl", "delete"], 1...1, usage: "<graph>", summary: "Delete a SHACL shapes graph.", options: [.value("expected-revision", "revision", summary: "Require the current shapes revision.")], capability: "shacl.execute")
        add(["shacl", "validate"], 1...1, usage: "<shapes-graph> --entity <name> --index <name>", summary: "Validate data with SHACL.", options: [
            .value("entity", "name", summary: "Select the source entity.", required: true),
            .value("index", "name", summary: "Select the source index.", required: true),
            .value("partitions", "typed-json", summary: "Select source partitions."),
            .value("data-graph", "graph", summary: "Select an RDF data graph."),
            .value("focus", "typed-json", summary: "Select focus nodes."),
            .value("entailment", "kind", summary: "Select entailment semantics."),
        ], capability: "shacl.execute")

        add(["command", "run"], 2...2, usage: "<identifier> <input>", summary: "Run an application command.", options: [.value("access", "read|write", summary: "Declare command access semantics.")], capability: "command.execute")
        add(["migration", "status"], 0...0, usage: "", summary: "Describe migration status.", capability: "maintenance.execute")
        add(["migration", "run"], 0...0, usage: "", summary: "Run registered migrations.", options: [.value("target-version", "version", summary: "Stop at a target schema version.")], capability: "maintenance.execute")
        add(["index", "status"], 0...0, usage: "", summary: "Describe index lifecycle state.", options: [
            .value("entity", "name", summary: "Filter by entity."),
            .value("index", "name", summary: "Filter by index."),
            .value("partitions", "typed-json", summary: "Filter by partitions."),
        ], capability: "maintenance.execute")
        add(["index", "rebuild"], 2...2, usage: "<entity> <index>", summary: "Rebuild an index.", options: [
            .value("partitions", "typed-json", summary: "Select partitions."),
            .value("batch-size", "count", summary: "Bound one rebuild batch."),
        ], capability: "maintenance.execute")
        add(["maintenance", "compact"], 0...0, usage: "", summary: "Compact database storage.", capability: "maintenance.execute")
        for action in ["status", "wait", "result", "cancel"] {
            add(["job", action], 3...3, usage: "<job-id> <family> <kind>", summary: "\(action.capitalized) a persistent job.", options: [
                .value("poll-interval-milliseconds", "milliseconds", summary: "Set the wait polling interval."),
                .value("wait-timeout-milliseconds", "milliseconds", summary: "Bound client-side waiting."),
            ], capability: "job.\(action)")
        }

        add(["inspect", "overview"], 0...0, usage: "", summary: "Summarize capabilities and schema.")
        add(["inspect", "entities"], 0...1, usage: "[entity]", summary: "Inspect schema entities.")
        add(["inspect", "indexes"], 0...0, usage: "", summary: "Inspect declared and runtime index state.", options: [.value("entity", "name", summary: "Filter by entity.")])
        add(["inspect", "graph"], 0...0, usage: "", summary: "Inspect graph declarations.", options: [.value("entity", "name", summary: "Filter by entity.")])
        add(["inspect", "ontology"], 1...1, usage: "<ontology-id>", summary: "Inspect one ontology.")
        add(["inspect", "shapes"], 1...1, usage: "<shape-graph-id>", summary: "Inspect one SHACL shapes graph.")
        add(["inspect", "jobs"], 0...0, usage: "", summary: "Inspect advertised job families and kinds.")
        add(["doctor"], 0...0, usage: "", summary: "Run bounded read-only installation and connection diagnostics.", options: [.value("server-config", "path", summary: "Inspect a local server configuration.")])
        for shell in ["bash", "zsh", "fish"] {
            add(["completion", shell], 0...0, usage: "", summary: "Generate \(shell) completion from the command catalog.")
        }

        return CommandCatalog(commands: commands, commonOptions: common)
    }
}
