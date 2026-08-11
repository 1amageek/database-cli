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
    public let requiredAnyOf: [Set<String>]
    public let capability: String?

    public init(
        path: [String],
        positionalRange: ClosedRange<Int>,
        usage: String,
        summary: String,
        options: [CommandOptionDescriptor] = [],
        requiredAnyOf: [Set<String>] = [],
        capability: String? = nil
    ) {
        self.path = path
        self.positionalRange = positionalRange
        self.usage = usage
        self.summary = summary
        self.options = options
        self.requiredAnyOf = requiredAnyOf
        self.capability = capability
    }

    public func option(named name: String) -> CommandOptionDescriptor? {
        options.first { $0.name == name }
    }
}

public struct CommandCatalog: Sendable {
    public let commands: [CommandDescriptor]
    private let commandsByPath: [[String]: CommandDescriptor]

    public init(commands: [CommandDescriptor]) {
        self.commands = commands
        self.commandsByPath = Dictionary(
            uniqueKeysWithValues: commands.map { ($0.path, $0) }
        )
    }

    public func command(for path: [String]) -> CommandDescriptor? {
        commandsByPath[path]
    }

    public func option(
        named name: String,
        for command: CommandDescriptor
    ) -> CommandOptionDescriptor? {
        command.option(named: name)
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
        let connectionOptions: [CommandOptionDescriptor] = [
            .value("profile", "name", summary: "Use a saved connection profile."),
            .value("endpoint", "url", summary: "Override the profile endpoint."),
            .value("database", "id", summary: "Override the database routing identity."),
            .value("tenant", "id", summary: "Override the tenant routing identity."),
            .value("workspace", "id", summary: "Override the workspace routing identity."),
        ]
        let executionBudgetOptions: [CommandOptionDescriptor] = [
            .value("maximum-rows", "count", summary: "Set the execution row budget.", defaultValue: "10000"),
            .value("maximum-work-units", "count", summary: "Set the execution work budget.", defaultValue: "1000000"),
            .value("maximum-intermediate-rows", "count", summary: "Set the intermediate-row budget.", defaultValue: "10000"),
            .value("maximum-intermediate-bytes", "bytes", summary: "Set the intermediate-byte budget.", defaultValue: "16777216"),
            .value("timeout-milliseconds", "milliseconds", summary: "Set the server execution timeout.", defaultValue: "30000"),
        ]
        let parameterOptions: [CommandOptionDescriptor] = [
            .value("parameters", "typed-json", summary: "Supply the canonical typed parameter array.", conflictsWith: ["parameter"]),
            .value("parameter", "binding", summary: "Supply one explicitly typed scalar parameter.", repeatable: true, conflictsWith: ["parameters"]),
        ]
        let graphPartitionOptions: [CommandOptionDescriptor] = [
            .value("graph-partitions", "typed-json", summary: "Supply graph partition values."),
        ]

        func remoteOptions(
            specific: [CommandOptionDescriptor] = [],
            outputFormats: String? = nil,
            budget: Bool = false,
            pageSize: Bool = false,
            continuation: Bool = false,
            fetchAll: Bool = false,
            parameters: Bool = false,
            graphPartitions: Bool = false,
            job: Bool = false,
            baseTarget: Bool = false,
            readableTarget: Bool = false,
            jobTarget: Bool = false,
            requiredIdempotencyKey: Bool = false
        ) -> [CommandOptionDescriptor] {
            var result = connectionOptions + [
                .value(
                    "trace-id",
                    "id",
                    summary: "Attach an operation trace identifier."
                ),
                .value(
                    "idempotency-key",
                    "key",
                    summary: requiredIdempotencyKey
                        ? "Identify this schema publication attempt."
                        : "Attach an idempotency key.",
                    required: requiredIdempotencyKey
                ),
            ]
            if let outputFormats {
                result.append(
                    .value(
                        "output",
                        outputFormats,
                        summary: "Select the result output format."
                    )
                )
            }
            if budget { result += executionBudgetOptions }
            if parameters { result += parameterOptions }
            if graphPartitions { result += graphPartitionOptions }
            if baseTarget {
                result.append(
                    .value(
                        "base",
                        "id",
                        summary: "Execute against one Base instead of the database."
                    )
                )
            }
            if readableTarget {
                result += [
                    .value(
                        "base",
                        "id",
                        summary: "Read from one Base.",
                        conflictsWith: ["composition"]
                    ),
                    .value(
                        "composition",
                        "id",
                        summary: "Read from one Composition.",
                        conflictsWith: ["base"]
                    ),
                ]
            }
            if jobTarget {
                result += [
                    .value(
                        "base",
                        "id",
                        summary: "Address a Base-bound job.",
                        conflictsWith: ["database-target"]
                    ),
                    .flag(
                        "database-target",
                        summary: "Address a database-bound job.",
                        conflictsWith: ["base"]
                    ),
                ]
            }
            if pageSize {
                result.append(
                    .value(
                        "page-size",
                        "count",
                        summary: "Set the maximum elements requested in one server page.",
                        defaultValue: "1000"
                    )
                )
            }
            if continuation {
                result.append(
                    .value(
                        "continuation",
                        "base64url",
                        summary: "Resume from a detached server continuation.",
                        conflictsWith: fetchAll ? ["all"] : []
                    )
                )
            }
            if fetchAll {
                result += [
                    .value("max-total-rows", "count", summary: "Bound aggregate result elements fetched by --all.", requires: ["all"]),
                    .value("max-total-bytes", "bytes", summary: "Bound aggregate output bytes fetched by --all.", requires: ["all"]),
                    .value("max-pages", "count", summary: "Bound aggregate pages fetched by --all.", requires: ["all"]),
                    .flag(
                        "all",
                        summary: "Fetch successive pages until completion or an aggregate limit failure.",
                        conflictsWith: job ? ["as-job", "continuation"] : ["continuation"],
                        requires: ["max-total-rows", "max-total-bytes", "max-pages"]
                    ),
                ]
            }
            if job {
                result.append(
                    .value(
                        "as-job",
                        "kind",
                        summary: "Start the advertised operation as a persistent job.",
                        conflictsWith: fetchAll ? ["all"] : []
                    )
                )
            }
            result += specific
            return result
        }

        var commands: [CommandDescriptor] = []
        func add(
            _ path: [String],
            _ range: ClosedRange<Int>,
            usage: String,
            summary: String,
            options: [CommandOptionDescriptor] = [],
            requiredAnyOf: [Set<String>] = [],
            capability: String? = nil
        ) {
            commands.append(
                CommandDescriptor(
                    path: path,
                    positionalRange: range,
                    usage: usage,
                    summary: summary,
                    options: options,
                    requiredAnyOf: requiredAnyOf,
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
        add(["capabilities"], 0...0, usage: "", summary: "Describe server capabilities.", options: remoteOptions(), capability: "capabilities.describe")
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
            .value("profile", "name", summary: "Use a saved connection profile."),
            .value("output", "format", summary: "Set the initial result output format."),
            .value("page-size", "count", summary: "Set the initial result page size.", defaultValue: "1000"),
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
            .value("profile", "name", summary: "Select the credential profile."),
            .value("token-environment", "name", summary: "Read the token from a named environment variable."),
        ])
        add(["auth", "logout"], 0...0, usage: "", summary: "Remove a profile credential.", options: [
            .value("profile", "name", summary: "Select the credential profile."),
        ])
        add(["schema", "list"], 0...0, usage: "", summary: "List schema entities.", options: remoteOptions(), capability: "schema.describe")
        add(["schema", "show"], 1...1, usage: "<entity>", summary: "Describe one schema entity.", options: remoteOptions(), capability: "schema.describe")
        add(["schema", "plan"], 1...1, usage: "<manifest|@path|@->", summary: "Plan a strict Schema JSON manifest without changing the database.", options: remoteOptions(
            specific: [
                .value("expected-fingerprint", "base64url", summary: "Require the current canonical schema fingerprint."),
            ],
            job: true
        ), capability: "schema.execute")
        add(["schema", "apply"], 1...1, usage: "<manifest|@path|@->", summary: "Atomically publish a strict Schema JSON manifest.", options: remoteOptions(
            specific: [
                .value("expected-fingerprint", "base64url", summary: "Require the current canonical schema fingerprint.", required: true),
            ],
            job: true,
            requiredIdempotencyKey: true
        ), capability: "schema.execute")

        let expectedRevision = CommandOptionDescriptor.value(
            "expected-revision",
            "uint64",
            summary: "Require the current resource revision.",
            required: true
        )
        let initialGrant = CommandOptionDescriptor.value(
            "initial-grant",
            "principal:<id>=<access-list>|role:<id>=<access-list>",
            summary: "Create one initial Base Grant; repeat for additional subjects.",
            required: true,
            repeatable: true
        )
        add(["base", "placements"], 0...0, usage: "", summary: "List named Base placements.", options: remoteOptions(), capability: "base.execute")
        add(["base", "list"], 0...0, usage: "", summary: "List visible Bases.", options: remoteOptions(), capability: "base.execute")
        add(["base", "describe"], 1...1, usage: "<base>", summary: "Describe one Base and its lifecycle state.", options: remoteOptions(), capability: "base.execute")
        add(["base", "create"], 1...1, usage: "<base> --placement <placement> --initial-grant <grant>", summary: "Create a Base through its persistent lifecycle job.", options: remoteOptions(
            specific: [
                .value("placement", "id", summary: "Select the named creation placement.", required: true),
                initialGrant,
                expectedRevision,
            ],
            requiredIdempotencyKey: true
        ), capability: "base.execute")
        for action in ["retire", "activate", "delete"] {
            add(["base", action], 1...1, usage: "<base>", summary: "\(action.capitalized) one Base through its persistent lifecycle job.", options: remoteOptions(
                specific: [expectedRevision],
                requiredIdempotencyKey: true
            ), capability: "base.execute")
        }
        add(["base", "placement", "plan"], 1...1, usage: "<base> --destination <placement>", summary: "Plan an offline Base placement transition.", options: remoteOptions(specific: [
            .value("destination", "placement", summary: "Select the destination placement.", required: true),
            expectedRevision,
        ]), capability: "base.execute")
        add(["base", "placement", "apply"], 1...1, usage: "<base> --destination <placement>", summary: "Start an offline Base placement transition.", options: remoteOptions(
            specific: [
                .value("destination", "placement", summary: "Select the destination placement.", required: true),
                expectedRevision,
            ],
            requiredIdempotencyKey: true
        ), capability: "base.execute")
        add(["base", "legacy-migration", "plan"], 1...1, usage: "<base> --placement <placement> --initial-grant <grant>", summary: "Inventory and plan migration of a legacy global layout.", options: remoteOptions(specific: [
            .value("placement", "id", summary: "Select the destination placement.", required: true),
            initialGrant,
        ]), capability: "base.execute")
        add(["base", "legacy-migration", "apply"], 1...1, usage: "<base> --placement <placement> --initial-grant <grant> --expected-layout-fingerprint <base64url>", summary: "Start explicit migration of a legacy global layout.", options: remoteOptions(
            specific: [
                .value("placement", "id", summary: "Select the destination placement.", required: true),
                initialGrant,
                .value("expected-layout-fingerprint", "base64url", summary: "Require the planned legacy layout fingerprint.", required: true),
                expectedRevision,
            ],
            requiredIdempotencyKey: true
        ), capability: "base.execute")

        let compositionBases = CommandOptionDescriptor.value(
            "base",
            "id",
            summary: "Add one member Base; repeat to add more members.",
            required: true,
            repeatable: true
        )
        add(["composition", "list"], 0...0, usage: "", summary: "List visible Compositions.", options: remoteOptions(), capability: "composition.execute")
        add(["composition", "describe"], 1...1, usage: "<composition>", summary: "Describe one Composition.", options: remoteOptions(), capability: "composition.execute")
        add(["composition", "create"], 1...1, usage: "<composition> --base <base>...", summary: "Create a named read Composition.", options: remoteOptions(
            specific: [compositionBases, expectedRevision],
            requiredIdempotencyKey: true
        ), capability: "composition.execute")
        add(["composition", "replace"], 1...1, usage: "<composition> --base <base>...", summary: "Replace all members of a Composition.", options: remoteOptions(
            specific: [compositionBases, expectedRevision],
            requiredIdempotencyKey: true
        ), capability: "composition.execute")
        add(["composition", "delete"], 1...1, usage: "<composition>", summary: "Delete a Composition.", options: remoteOptions(
            specific: [expectedRevision],
            requiredIdempotencyKey: true
        ), capability: "composition.execute")

        let grantTargetOptions: [CommandOptionDescriptor] = [
            .value("base", "id", summary: "Select a Base Grant store.", conflictsWith: ["database-target"]),
            .flag("database-target", summary: "Select the database Grant store.", conflictsWith: ["base"]),
        ]
        let grantSubjectOptions: [CommandOptionDescriptor] = [
            .value("principal", "id", summary: "Select a principal subject.", conflictsWith: ["role"]),
            .value("role", "id", summary: "Select a principal-role subject.", conflictsWith: ["principal"]),
        ]
        let grantSubjectRequirement: Set<String> = ["principal", "role"]
        add(["grant", "direct"], 0...0, usage: "[--base <base>] [--principal <id>|--role <id>]", summary: "List direct Grants; the database is the default target.", options: remoteOptions(specific: grantTargetOptions + grantSubjectOptions), capability: "grant.execute")
        add(["grant", "effective"], 0...0, usage: "[--base <base>]", summary: "Resolve the authenticated principal's effective access; the database is the default target.", options: remoteOptions(specific: grantTargetOptions), capability: "grant.execute")
        for action in ["add", "revoke"] {
            add(["grant", action], 0...0, usage: "[--base <base>] --principal <id>|--role <id> --access <list>", summary: "\(action.capitalized) one persisted Grant; the database is the default target.", options: remoteOptions(
                specific: grantTargetOptions + grantSubjectOptions + [
                    .value("access", "read,write,administer", summary: "Select independent access bits.", required: true),
                    expectedRevision,
                ],
                requiredIdempotencyKey: true
            ), requiredAnyOf: [grantSubjectRequirement], capability: "grant.execute")
        }

        for language in ["sql", "sparql"] {
            add(["query", language], 1...1, usage: "<statement|@path|@->", summary: "Execute a read-only \(language.uppercased()) statement.", options: remoteOptions(
                outputFormats: "table|jsonl|json|csv|nquads",
                budget: true,
                pageSize: true,
                continuation: true,
                fetchAll: true,
                parameters: true,
                graphPartitions: true,
                job: true,
                readableTarget: true
            ), capability: "query.execute")
            add(["mutate", language], 1...1, usage: "<statement|@path|@->", summary: "Execute a mutating \(language.uppercased()) statement.", options: remoteOptions(
                budget: true,
                parameters: true,
                graphPartitions: true,
                job: true,
                baseTarget: true
            ), capability: "mutation.execute")
        }

        let preconditions: [CommandOptionDescriptor] = [
            .value("partitions", "typed-json", summary: "Supply entity partition values."),
            .value(
                "expected-version",
                "version",
                summary: "Require the current entity version.",
                conflictsWith: ["must-exist", "must-not-exist"]
            ),
            .flag(
                "must-exist",
                summary: "Require the entity to exist.",
                conflictsWith: ["expected-version", "must-not-exist"]
            ),
            .flag(
                "must-not-exist",
                summary: "Require the entity not to exist.",
                conflictsWith: ["expected-version", "must-exist"]
            ),
        ]
        for action in ["insert", "update", "upsert"] {
            add(["entity", action], 3...3, usage: "<entity> <id> <fields>", summary: "Apply a canonical entity \(action).", options: remoteOptions(
                specific: preconditions,
                budget: true,
                graphPartitions: true,
                job: true,
                baseTarget: true
            ), capability: "mutation.execute")
        }
        add(["entity", "delete"], 2...2, usage: "<entity> <id>", summary: "Delete an entity.", options: remoteOptions(
            specific: preconditions,
            budget: true,
            graphPartitions: true,
            job: true,
            baseTarget: true
        ), capability: "mutation.execute")
        add(["entity", "apply"], 1...1, usage: "<manifest|@path|@->", summary: "Apply an atomic entity change manifest.", options: remoteOptions(
            budget: true,
            graphPartitions: true,
            job: true,
            baseTarget: true
        ), capability: "mutation.execute")

        let graphSourceOptions: [CommandOptionDescriptor] = [
            .value("index", "name", summary: "Select the declared graph index.", required: true),
            .value("partitions", "typed-json", summary: "Select graph index partitions."),
            .value("graph", "all|default|typed-rdf-term", summary: "Select all, default, or one named RDF graph."),
            .value("edge-label", "typed-graph-term", summary: "Restrict traversal to one edge label."),
        ]
        func graphOptions(
            _ algorithm: [CommandOptionDescriptor]
        ) -> [CommandOptionDescriptor] {
            remoteOptions(
                specific: graphSourceOptions + algorithm,
                outputFormats: "table|jsonl|json",
                budget: true,
                pageSize: true,
                continuation: true,
                fetchAll: true,
                job: true,
                baseTarget: true
            )
        }
        add(["graph", "shortest-path"], 0...0, usage: "--index <name> --source <term> --target <term>", summary: "Find an unweighted path between two graph terms.", options: graphOptions([
            .value("source", "typed-graph-term", summary: "Set the starting graph term.", required: true),
            .value("target", "typed-graph-term", summary: "Set the destination graph term.", required: true),
            .value("maximum-depth", "count", summary: "Bound traversal depth.", defaultValue: "64"),
            .value("maximum-nodes", "count", summary: "Bound explored nodes.", defaultValue: "100000"),
            .flag("bidirectional", summary: "Search from both endpoints."),
        ]), capability: "graph.algorithm")
        add(["graph", "weighted-shortest-path"], 0...0, usage: "--index <name> --source <term> --target <term> --weight-property <name>", summary: "Find a minimum-weight path between two graph terms.", options: graphOptions([
            .value("source", "typed-graph-term", summary: "Set the starting graph term.", required: true),
            .value("target", "typed-graph-term", summary: "Set the destination graph term.", required: true),
            .value("weight-property", "name", summary: "Select the numeric edge-weight property.", required: true),
            .value("maximum-weight", "finite-number", summary: "Reject paths above this total weight.", defaultValue: "1.7976931348623157e308"),
            .value("maximum-nodes", "count", summary: "Bound explored nodes.", defaultValue: "100000"),
        ]), capability: "graph.algorithm")
        add(["graph", "page-rank"], 0...0, usage: "--index <name>", summary: "Rank graph vertices with PageRank.", options: graphOptions([
            .value("damping-factor", "finite-number", summary: "Set the PageRank damping factor.", defaultValue: "0.85"),
            .value("maximum-iterations", "count", summary: "Bound PageRank iterations.", defaultValue: "100"),
            .value("convergence-threshold", "finite-number", summary: "Stop when score delta reaches this threshold.", defaultValue: "0.000001"),
            .value("personalized-source", "typed-graph-term", summary: "Use personalized PageRank from one graph term."),
        ]), capability: "graph.algorithm")
        add(["graph", "community"], 0...0, usage: "--index <name>", summary: "Detect graph communities.", options: graphOptions([
            .value("maximum-iterations", "count", summary: "Bound community-detection iterations.", defaultValue: "100"),
            .value("minimum-community-size", "count", summary: "Discard smaller communities.", defaultValue: "1"),
            .value("seed", "uint64", summary: "Set the deterministic algorithm seed."),
            .flag("compute-modularity", summary: "Include the modularity score."),
        ]), capability: "graph.algorithm")
        add(["graph", "cycles"], 0...0, usage: "--index <name>", summary: "Detect cycles and back edges.", options: graphOptions([
            .value("maximum-cycles", "count", summary: "Bound returned cycles.", defaultValue: "1000"),
            .value("maximum-nodes", "count", summary: "Bound explored nodes.", defaultValue: "100000"),
        ]), capability: "graph.algorithm")
        add(["graph", "strongly-connected-components"], 0...0, usage: "--index <name>", summary: "Find strongly connected components.", options: graphOptions([
            .value("maximum-components", "count", summary: "Bound returned components.", defaultValue: "10000"),
            .value("maximum-nodes", "count", summary: "Bound explored nodes.", defaultValue: "100000"),
        ]), capability: "graph.algorithm")
        add(["graph", "topological-sort"], 0...0, usage: "--index <name>", summary: "Produce a topological order and report cyclic nodes.", options: graphOptions([
            .value("maximum-nodes", "count", summary: "Bound processed nodes.", defaultValue: "100000"),
        ]), capability: "graph.algorithm")

        let pagedDomainOptions: (
            [CommandOptionDescriptor]
        ) -> [CommandOptionDescriptor] = { specific in
            remoteOptions(
                specific: specific,
                outputFormats: "table|jsonl|json",
                budget: true,
                pageSize: true,
                continuation: true,
                fetchAll: true,
                job: true,
                baseTarget: true
            )
        }
        let mutationDomainOptions: (
            [CommandOptionDescriptor]
        ) -> [CommandOptionDescriptor] = { specific in
            remoteOptions(
                specific: specific,
                outputFormats: "table|jsonl|json",
                budget: true,
                job: true,
                baseTarget: true
            )
        }
        add(["ontology", "describe"], 1...1, usage: "<ontology>", summary: "Read an ontology document.", options: pagedDomainOptions([]), capability: "ontology.execute")
        add(["ontology", "upsert"], 1...1, usage: "<document|@path|@->", summary: "Create or replace an ontology document.", options: mutationDomainOptions([
            .value("expected-revision", "uint64", summary: "Require the current ontology revision."),
        ]), capability: "ontology.execute")
        add(["ontology", "delete"], 1...1, usage: "<ontology>", summary: "Delete an ontology document.", options: mutationDomainOptions([
            .value("expected-revision", "uint64", summary: "Require the current ontology revision."),
        ]), capability: "ontology.execute")
        add(["ontology", "reason"], 1...1, usage: "<ontology>", summary: "Derive inferred axioms from an ontology.", options: pagedDomainOptions([
            .value("profile-kind", "rdfs|owl-rl", summary: "Select the reasoning profile.", defaultValue: "rdfs"),
        ]), capability: "ontology.execute")
        add(["ontology", "hierarchy"], 2...2, usage: "<ontology> <resource>", summary: "Traverse an ontology resource hierarchy.", options: pagedDomainOptions([
            .value("resource-kind", "class|object-property|data-property", summary: "Select the resource kind.", defaultValue: "class"),
            .value("direction", "ancestors|descendants", summary: "Select traversal direction.", defaultValue: "ancestors"),
            .value("maximum-depth", "count", summary: "Bound hierarchy traversal depth.", defaultValue: "64"),
        ]), capability: "ontology.execute")
        add(["ontology", "validate-schema"], 1...1, usage: "<ontology>", summary: "Validate ontology and database-schema alignment.", options: pagedDomainOptions([]), capability: "ontology.execute")

        add(["shacl", "describe"], 1...1, usage: "<graph>", summary: "Read a SHACL shapes graph.", options: pagedDomainOptions([]), capability: "shacl.execute")
        add(["shacl", "upsert"], 2...2, usage: "<graph> <nquads|@path|@->", summary: "Create or replace a SHACL shapes graph.", options: mutationDomainOptions([
            .value("expected-revision", "uint64", summary: "Require the current shapes revision."),
        ]), capability: "shacl.execute")
        add(["shacl", "delete"], 1...1, usage: "<graph>", summary: "Delete a SHACL shapes graph.", options: mutationDomainOptions([
            .value("expected-revision", "uint64", summary: "Require the current shapes revision."),
        ]), capability: "shacl.execute")
        add(["shacl", "validate"], 1...1, usage: "<shapes-graph> --entity <name> --index <name>", summary: "Validate indexed entity data against SHACL shapes.", options: pagedDomainOptions([
            .value("entity", "name", summary: "Select the source entity.", required: true),
            .value("index", "name", summary: "Select the source index.", required: true),
            .value("partitions", "typed-json", summary: "Select source partitions."),
            .value("data-graph", "default|typed-rdf-term", summary: "Select the RDF data graph.", defaultValue: "default"),
            .value("focus", "targets|typed-json", summary: "Use shape targets or explicit focus nodes.", defaultValue: "targets"),
            .value("entailment", "none|rdfs|owl-rl", summary: "Select entailment semantics.", defaultValue: "none"),
        ]), capability: "shacl.execute")

        add(["command", "run"], 2...2, usage: "<identifier> <input|@path|@->", summary: "Run a registered application command.", options: remoteOptions(
            specific: [
                .value("access", "read-only|read-write", summary: "Declare command transaction access.", defaultValue: "read-only"),
            ],
            outputFormats: "table|jsonl|json",
            budget: true,
            job: true,
            baseTarget: true
        ), capability: "command.execute")

        func maintenanceOptions(
            specific: [CommandOptionDescriptor] = [],
            resumable: Bool,
            job: Bool = true
        ) -> [CommandOptionDescriptor] {
            remoteOptions(
                specific: specific,
                outputFormats: "table|jsonl|json",
                budget: true,
                continuation: resumable,
                fetchAll: resumable,
                job: job,
                baseTarget: true
            )
        }
        add(["migration", "status"], 0...0, usage: "", summary: "Read current and pending migration state.", options: maintenanceOptions(resumable: false), capability: "maintenance.execute")
        add(["migration", "run"], 0...0, usage: "", summary: "Execute registered migrations through an optional target version.", options: maintenanceOptions(
            specific: [
                .value("target-version", "major.minor.patch", summary: "Stop after reaching this schema version."),
            ],
            resumable: true
        ), capability: "maintenance.execute")
        add(["index", "status"], 0...0, usage: "", summary: "Read index lifecycle state.", options: maintenanceOptions(
            specific: [
                .value("entity", "name", summary: "Filter by entity."),
                .value("index", "name", summary: "Filter by index."),
                .value("partitions", "typed-json", summary: "Filter by partitions."),
            ],
            resumable: true
        ), capability: "maintenance.execute")
        add(["index", "rebuild"], 2...2, usage: "<entity> <index>", summary: "Rebuild one declared index.", options: maintenanceOptions(
            specific: [
                .value("partitions", "typed-json", summary: "Select partitions."),
                .value("batch-size", "count", summary: "Bound one rebuild batch.", defaultValue: "1000"),
            ],
            resumable: true
        ), capability: "maintenance.execute")
        add(["maintenance", "compact"], 0...0, usage: "", summary: "Request backend storage compaction.", options: maintenanceOptions(resumable: true), capability: "maintenance.execute")

        let jobIdentityUsage = "<job-id> <family> <kind>"
        add(["job", "status"], 3...3, usage: jobIdentityUsage, summary: "Read persistent job state and progress; the database is the default target.", options: remoteOptions(jobTarget: true), capability: "job.status")
        add(["job", "wait"], 3...3, usage: jobIdentityUsage, summary: "Poll job status until a terminal state or client deadline.", options: remoteOptions(specific: [
            .value("poll-interval-milliseconds", "milliseconds", summary: "Set the status polling interval.", defaultValue: "500"),
            .value("wait-timeout-milliseconds", "milliseconds", summary: "Bound client-side waiting.", defaultValue: "30000"),
        ], jobTarget: true), capability: "job.wait")
        add(["job", "result"], 3...3, usage: jobIdentityUsage, summary: "Read the typed result of a completed job; the database is the default target.", options: remoteOptions(outputFormats: "table|jsonl|json|csv|nquads", jobTarget: true), capability: "job.result")
        add(["job", "cancel"], 3...3, usage: jobIdentityUsage, summary: "Request persistent job cancellation; the database is the default target.", options: remoteOptions(jobTarget: true), capability: "job.cancel")

        add(["inspect", "overview"], 0...0, usage: "", summary: "Combine advertised capabilities and schema metadata.", options: remoteOptions())
        add(["inspect", "entities"], 0...1, usage: "[entity]", summary: "Inspect all schema entities or one named entity.", options: remoteOptions())
        add(["inspect", "indexes"], 0...0, usage: "", summary: "Combine declared indexes with runtime index state.", options: remoteOptions(
            specific: [.value("entity", "name", summary: "Filter by entity.")],
            budget: true,
            continuation: true,
            baseTarget: true
        ))
        add(["inspect", "graph"], 0...0, usage: "", summary: "Inspect graph-relevant schema declarations.", options: remoteOptions(specific: [
            .value("entity", "name", summary: "Filter by entity."),
        ]))
        add(["inspect", "ontology"], 1...1, usage: "<ontology-id>", summary: "Inspect one ontology through the canonical describe operation.", options: pagedDomainOptions([]))
        add(["inspect", "shapes"], 1...1, usage: "<shape-graph-id>", summary: "Inspect one SHACL shapes graph through the canonical describe operation.", options: pagedDomainOptions([]))
        add(["inspect", "jobs"], 0...0, usage: "", summary: "List job families and kinds advertised by capabilities.", options: remoteOptions())
        add(["doctor"], 0...0, usage: "", summary: "Run bounded read-only installation and connection diagnostics.", options: connectionOptions + [
            .value("server-config", "path", summary: "Inspect a local server configuration."),
        ])
        for shell in ["bash", "zsh", "fish"] {
            add(["completion", shell], 0...0, usage: "", summary: "Generate \(shell) completion from the command catalog.")
        }

        return CommandCatalog(commands: commands)
    }
}
