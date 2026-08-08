import Foundation

public struct ParsedCommand: Sendable, Hashable {
    public let path: [String]
    public let positionals: [String]
    public let options: CommandOptions

    public init(
        path: [String],
        positionals: [String] = [],
        options: CommandOptions = CommandOptions()
    ) {
        self.path = path
        self.positionals = positionals
        self.options = options
    }
}

public struct CommandOptions: Sendable, Hashable {
    private var storage: [String: [String?]]

    public init(_ storage: [String: [String?]] = [:]) {
        self.storage = storage
    }

    public func contains(_ name: String) -> Bool {
        storage[name] != nil
    }

    public func value(_ name: String) -> String? {
        guard let values = storage[name], values.count == 1 else {
            return nil
        }
        return values[0]
    }

    public func values(_ name: String) -> [String] {
        storage[name, default: []].compactMap { $0 }
    }

    mutating func append(_ value: String?, for name: String) {
        storage[name, default: []].append(value)
    }
}

public struct CommandParser: Sendable {
    public init() {}

    public func parse(_ arguments: [String]) throws -> ParsedCommand {
        guard !arguments.isEmpty else {
            return ParsedCommand(path: ["help"])
        }

        var tokens = arguments
        if tokens == ["--help"] || tokens == ["-h"] {
            return ParsedCommand(path: ["help"])
        }
        if tokens == ["--version"] {
            return ParsedCommand(path: ["version"])
        }

        let path = try resolvePath(tokens)
        tokens.removeFirst(path.count)
        if tokens.contains("--help") || tokens.contains("-h") {
            return ParsedCommand(path: ["help"], positionals: path)
        }

        let definition = try Self.definition(for: path)
        var positionals: [String] = []
        var options = CommandOptions()
        var index = 0
        var optionsEnded = false

        while index < tokens.count {
            let token = tokens[index]
            if token == "--", !optionsEnded {
                optionsEnded = true
                index += 1
                continue
            }
            if !optionsEnded, token.hasPrefix("--") {
                let parsed = try parseOptionToken(token)
                let option = parsed.name
                guard definition.valueOptions.contains(option)
                    || definition.flagOptions.contains(option)
                    || Self.commonValueOptions.contains(option)
                    || Self.commonFlagOptions.contains(option) else {
                    throw DatabaseCLIError(
                        .input,
                        "Unknown option '--\(option)' for '\(path.joined(separator: " "))'"
                    )
                }
                let requiresValue = definition.valueOptions.contains(option)
                    || Self.commonValueOptions.contains(option)
                guard !options.contains(option) else {
                    throw DatabaseCLIError(
                        .input,
                        "Option '--\(option)' may be specified only once"
                    )
                }
                if requiresValue {
                    let value: String
                    if let inlineValue = parsed.value {
                        value = inlineValue
                    } else {
                        index += 1
                        guard index < tokens.count else {
                            throw DatabaseCLIError(
                                .input,
                                "Option '--\(option)' requires a value"
                            )
                        }
                        value = tokens[index]
                    }
                    guard !value.isEmpty else {
                        throw DatabaseCLIError(
                            .input,
                            "Option '--\(option)' requires a non-empty value"
                        )
                    }
                    options.append(value, for: option)
                } else {
                    guard parsed.value == nil else {
                        throw DatabaseCLIError(
                            .input,
                            "Flag '--\(option)' does not accept a value"
                        )
                    }
                    options.append(nil, for: option)
                }
            } else {
                positionals.append(token)
            }
            index += 1
        }

        guard definition.positionalRange.contains(positionals.count) else {
            throw DatabaseCLIError(
                .input,
                "Invalid arguments for '\(path.joined(separator: " "))'; expected \(definition.usage)"
            )
        }
        try validateCommonOptions(options)
        return ParsedCommand(
            path: path,
            positionals: positionals,
            options: options
        )
    }

    private func resolvePath(_ tokens: [String]) throws -> [String] {
        let nonOptionPrefix = tokens.prefix { !$0.hasPrefix("-") }
        let maximum = min(3, nonOptionPrefix.count)
        guard maximum > 0 else {
            throw DatabaseCLIError(.input, "A command is required")
        }
        for count in stride(from: maximum, through: 1, by: -1) {
            let candidate = Array(nonOptionPrefix.prefix(count))
            if Self.definitions[candidate] != nil {
                return candidate
            }
        }
        throw DatabaseCLIError(
            .input,
            "Unknown command '\(nonOptionPrefix.joined(separator: " "))'"
        )
    }

    private func parseOptionToken(
        _ token: String
    ) throws -> (name: String, value: String?) {
        guard token.count > 2 else {
            throw DatabaseCLIError(.input, "Invalid option '\(token)'")
        }
        let body = token.dropFirst(2)
        if let separator = body.firstIndex(of: "=") {
            let name = String(body[..<separator])
            let value = String(body[body.index(after: separator)...])
            return (name, value)
        }
        return (String(body), nil)
    }

    private func validateCommonOptions(
        _ options: CommandOptions
    ) throws {
        if options.contains("all") {
            for required in ["max-total-rows", "max-total-bytes", "max-pages"] {
                guard options.value(required) != nil else {
                    throw DatabaseCLIError(
                        .input,
                        "'--all' requires '--\(required)'"
                    )
                }
            }
        }
        if options.value("continuation") != nil, options.contains("all") {
            throw DatabaseCLIError(
                .input,
                "'--continuation' cannot be combined with '--all'"
            )
        }
    }
}

private extension CommandParser {
    struct Definition {
        let positionalRange: ClosedRange<Int>
        let valueOptions: Set<String>
        let flagOptions: Set<String>
        let usage: String

        init(
            _ positionalRange: ClosedRange<Int>,
            values: Set<String> = [],
            flags: Set<String> = [],
            usage: String
        ) {
            self.positionalRange = positionalRange
            self.valueOptions = values
            self.flagOptions = flags
            self.usage = usage
        }
    }

    static let commonValueOptions: Set<String> = [
        "profile", "endpoint", "database", "tenant", "workspace",
        "trace-id", "idempotency-key", "output", "page-size",
        "continuation", "parameters", "graph-partitions", "as-job",
        "maximum-rows", "maximum-work-units", "maximum-intermediate-rows",
        "maximum-intermediate-bytes", "timeout-milliseconds",
        "max-total-rows", "max-total-bytes", "max-pages",
    ]

    static let commonFlagOptions: Set<String> = ["all"]

    static let definitions: [[String]: Definition] = {
        var values: [[String]: Definition] = [:]
        func add(
            _ path: [String],
            _ range: ClosedRange<Int>,
            valueOptions: Set<String> = [],
            flagOptions: Set<String> = [],
            usage: String
        ) {
            values[path] = Definition(
                range,
                values: valueOptions,
                flags: flagOptions,
                usage: usage
            )
        }

        add(["help"], 0...3, usage: "[command]")
        add(["version"], 0...0, usage: "")
        add(["capabilities"], 0...0, usage: "")
        add(["shell"], 0...0, valueOptions: ["history-file"], flagOptions: ["persist-history"], usage: "")
        add(["fdb"], 1...64, usage: "<cluster|catalog|raw> ...")

        for action in ["list", "use"] {
            add(["profile", action], action == "list" ? 0...0 : 1...1, usage: action == "list" ? "" : "<name>")
        }
        add(["profile", "create"], 1...1, valueOptions: ["endpoint", "database", "tenant", "workspace", "token-environment"], usage: "<name> --endpoint <url>")
        add(["profile", "show"], 1...1, usage: "<name>")
        add(["profile", "remove"], 1...1, usage: "<name>")
        add(["auth", "login"], 0...0, valueOptions: ["token-environment"], usage: "")
        add(["auth", "logout"], 0...0, usage: "")
        add(["schema", "list"], 0...0, usage: "")
        add(["schema", "show"], 1...1, usage: "<entity>")

        for language in ["sql", "sparql"] {
            add(["query", language], 1...1, usage: "<statement|@path|@->")
            add(["mutate", language], 1...1, usage: "<statement|@path|@->")
        }

        for action in ["insert", "update", "upsert"] {
            add(["entity", action], 3...3, valueOptions: ["partitions", "expected-version"], flagOptions: ["must-exist", "must-not-exist"], usage: "<entity> <id> <fields>")
        }
        add(["entity", "delete"], 2...2, valueOptions: ["partitions", "expected-version"], flagOptions: ["must-exist", "must-not-exist"], usage: "<entity> <id>")
        add(["entity", "apply"], 1...1, usage: "<manifest>")

        let graphValues: Set<String> = [
            "index", "partitions", "graph", "edge-label", "source", "target",
            "maximum-depth", "maximum-nodes", "weight-property", "maximum-weight",
            "damping-factor", "maximum-iterations", "convergence-threshold",
            "personalized-source", "minimum-community-size", "seed",
            "maximum-cycles", "maximum-components",
        ]
        let graphFlags: Set<String> = ["bidirectional", "compute-modularity"]
        for action in [
            "shortest-path", "weighted-shortest-path", "page-rank", "community",
            "cycles", "strongly-connected-components", "topological-sort",
        ] {
            add(["graph", action], 0...0, valueOptions: graphValues, flagOptions: graphFlags, usage: "--index <name> [options]")
        }

        add(["ontology", "describe"], 1...1, usage: "<ontology>")
        add(["ontology", "upsert"], 1...1, valueOptions: ["expected-revision"], usage: "<document>")
        add(["ontology", "delete"], 1...1, valueOptions: ["expected-revision"], usage: "<ontology>")
        add(["ontology", "reason"], 1...1, valueOptions: ["profile-kind"], usage: "<ontology>")
        add(["ontology", "hierarchy"], 2...2, valueOptions: ["resource-kind", "direction", "maximum-depth"], usage: "<ontology> <resource>")
        add(["ontology", "validate-schema"], 1...1, usage: "<ontology>")

        add(["shacl", "describe"], 1...1, usage: "<graph>")
        add(["shacl", "upsert"], 2...2, valueOptions: ["expected-revision"], usage: "<graph> <nquads>")
        add(["shacl", "delete"], 1...1, valueOptions: ["expected-revision"], usage: "<graph>")
        add(["shacl", "validate"], 1...1, valueOptions: ["entity", "index", "partitions", "data-graph", "focus", "entailment"], usage: "<shapes-graph> --entity <name> --index <name>")

        add(["command", "run"], 2...2, valueOptions: ["access"], usage: "<identifier> <input>")
        add(["migration", "status"], 0...0, usage: "")
        add(["migration", "run"], 0...0, valueOptions: ["target-version"], usage: "")
        add(["index", "status"], 0...0, valueOptions: ["entity", "index", "partitions"], usage: "")
        add(["index", "rebuild"], 2...2, valueOptions: ["partitions", "batch-size"], usage: "<entity> <index>")
        add(["maintenance", "compact"], 0...0, usage: "")
        for action in ["status", "wait", "result", "cancel"] {
            add(["job", action], 3...3, valueOptions: ["poll-interval-milliseconds", "wait-timeout-milliseconds"], usage: "<job-id> <family> <kind>")
        }
        return values
    }()

    static func definition(for path: [String]) throws -> Definition {
        guard let definition = definitions[path] else {
            throw DatabaseCLIError(.input, "Unknown command")
        }
        return definition
    }
}
