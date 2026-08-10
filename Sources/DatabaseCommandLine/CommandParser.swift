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

    public func occurrenceCount(_ name: String) -> Int {
        storage[name]?.count ?? 0
    }

    mutating func append(_ value: String?, for name: String) {
        storage[name, default: []].append(value)
    }
}

public struct CommandParser: Sendable {
    public let catalog: CommandCatalog

    public init(catalog: CommandCatalog = .standard) {
        self.catalog = catalog
    }

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

        guard let definition = catalog.command(for: path) else {
            throw DatabaseCLIError(.input, "Unknown command")
        }
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
                guard let descriptor = catalog.option(
                    named: option,
                    for: definition
                ) else {
                    throw DatabaseCLIError(
                        .input,
                        "Unknown option '--\(option)' for '\(path.joined(separator: " "))'"
                    )
                }
                if let maximum = descriptor.maximumOccurrences,
                   options.occurrenceCount(option) >= maximum {
                    throw DatabaseCLIError(
                        .input,
                        "Option '--\(option)' may be specified only once"
                    )
                }
                let requiresValue: Bool
                switch descriptor.valueMode {
                case .flag: requiresValue = false
                case .value: requiresValue = true
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
        try validate(options, for: definition)
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
            if catalog.command(for: candidate) != nil {
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

    private func validate(
        _ options: CommandOptions,
        for command: CommandDescriptor
    ) throws {
        var errors: [String] = []
        for descriptor in command.options {
            let count = options.occurrenceCount(descriptor.name)
            if count < descriptor.minimumOccurrences {
                errors.append("Missing required option '--\(descriptor.name)'")
            }
            guard count > 0 else { continue }
            for conflict in descriptor.conflictsWith.sorted()
            where options.contains(conflict) {
                errors.append(
                    "'--\(descriptor.name)' cannot be combined with '--\(conflict)'"
                )
            }
            for requirement in descriptor.requires.sorted()
            where !options.contains(requirement) {
                errors.append(
                    "'--\(descriptor.name)' requires '--\(requirement)'"
                )
            }
        }
        for requirement in command.requiredAnyOf where
            requirement.isDisjoint(with: Set(
                command.options.compactMap { descriptor in
                    options.contains(descriptor.name) ? descriptor.name : nil
                }
            ))
        {
            errors.append(
                "One of "
                    + requirement.sorted().map { "'--\($0)'" }
                        .joined(separator: ", ")
                    + " is required"
            )
        }
        let uniqueErrors = errors.reduce(into: [String]()) { result, error in
            if !result.contains(error) { result.append(error) }
        }
        guard uniqueErrors.isEmpty else {
            throw DatabaseCLIError(.input, uniqueErrors.joined(separator: "\n"))
        }
    }
}
