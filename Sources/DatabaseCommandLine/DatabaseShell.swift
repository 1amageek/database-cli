import DatabaseKit
import DatabaseTypes
import DatabaseWire
import Foundation

struct DatabaseShell: Sendable {
    let application: DatabaseCLIApplication
    let command: ParsedCommand
    let output: OutputWriter
    let session: RemoteSession?
    let connectionName: String?
    let databaseName: String?

    init(
        application: DatabaseCLIApplication,
        command: ParsedCommand,
        output: OutputWriter,
        session: RemoteSession? = nil,
        connectionName: String? = nil,
        databaseName: String? = nil
    ) {
        self.application = application
        self.command = command
        self.output = output
        self.session = session
        self.connectionName = connectionName
        self.databaseName = databaseName
    }

    func run() async throws {
        let input = try ShellInputReader()
        let initialMode = try ShellMode(
            command.options.value("mode")
                ?? (command.path == ["open"]
                    ? ShellMode.sqlQuery.rawValue
                    : ShellMode.command.rawValue)
        )
        let selectedProfile = try application.profiles.selectedProfileIfConfigured(
            named: command.options.value("profile")
        )
        var state = State(
            profile: selectedProfile?.name ?? command.options.value("profile"),
            promptConnection: connectionName
                ?? selectedProfile?.name
                ?? command.options.value("profile")
                ?? "unconfigured",
            database: databaseName ?? selectedProfile?.databaseID ?? "main",
            mode: initialMode,
            target: nil,
            outputFormat: command.options.value("output"),
            pageSize: command.options.value("page-size"),
            persistentHistory: command.options.contains("persist-history"),
            historyURL: try historyURL()
        )
        var completions = await completionSnapshot(
            profileName: state.profile,
            fixedSession: session
        )
        output.diagnostic(
            "Database shell \(DatabaseCLIVersion.current). Use \\help for commands.\n"
        )
        while true {
            if !input.rendersPrompt {
                output.diagnostic(state.prompt)
            }
            let line: String
            do {
                let candidates = state.mode == .command
                    ? completions.entries
                    : completions.entries.filter {
                        $0.context.isEmpty && $0.value.hasPrefix("\\")
                    }
                guard let value = try await input.readLine(
                    prompt: state.prompt,
                    completions: candidates
                ) else {
                    output.diagnostic("\n")
                    await input.shutdown()
                    return
                }
                line = value
            } catch is ShellInterrupt {
                state.statementLines.removeAll(keepingCapacity: true)
                output.diagnostic("^C\n")
                continue
            } catch {
                await input.shutdown()
                throw error
            }
            if line.hasPrefix("\\") {
                do {
                    let previousProfile = state.profile
                    if try await handleMeta(line, state: &state) {
                        await input.shutdown()
                        return
                    }
                    if state.profile != previousProfile {
                        completions = await completionSnapshot(
                            profileName: state.profile,
                            fixedSession: session
                        )
                    }
                } catch is CancellationError {
                    await input.shutdown()
                    throw CancellationError()
                } catch {
                    let failure = DatabaseCLIError.map(error)
                    output.diagnostic("error: \(failure.message)\n")
                }
                continue
            }
            if state.mode != .command {
                state.statementLines.append(line)
                continue
            }
            let tokens = try ShellLexer().parse(line)
            guard !tokens.isEmpty else { continue }
            do {
                try await execute(tokens, state: &state)
            } catch is CancellationError {
                await input.shutdown()
                throw CancellationError()
            } catch {
                let failure = DatabaseCLIError.map(error)
                output.diagnostic("error: \(failure.message)\n")
            }
        }
    }
}

private extension DatabaseShell {
    enum ShellMode: String, Sendable {
        case command
        case sqlQuery = "sql-query"
        case sqlMutation = "sql-mutation"
        case sparqlQuery = "sparql-query"
        case sparqlUpdate = "sparql-update"

        init(_ rawValue: String) throws {
            guard let value = Self(rawValue: rawValue) else {
                throw DatabaseCLIError(
                    .input,
                    "Invalid shell mode '\(rawValue)'"
                )
            }
            self = value
        }

        var commandPrefix: [String]? {
            switch self {
            case .command: nil
            case .sqlQuery: ["query", "sql"]
            case .sqlMutation: ["mutate", "sql"]
            case .sparqlQuery: ["query", "sparql"]
            case .sparqlUpdate: ["mutate", "sparql"]
            }
        }

        var promptLabel: String {
            switch self {
            case .command: "command"
            case .sqlQuery: "sql:query"
            case .sqlMutation: "sql:mutation"
            case .sparqlQuery: "sparql:query"
            case .sparqlUpdate: "sparql:update"
            }
        }
    }

    struct State {
        var profile: String?
        var promptConnection: String
        var database: String
        var mode: ShellMode
        var target: Target?
        var outputFormat: String?
        var pageSize: String?
        var timing = false
        var history: [String] = []
        var lastArguments: [String]?
        var lastContinuation: ByteString?
        var statementLines: [String] = []
        let persistentHistory: Bool
        let historyURL: URL

        var prompt: String {
            let suffix = statementLines.isEmpty ? "> " : "...> "
            let targetLabel = target?.promptLabel ?? "target:none"
            return "\(promptConnection)/\(database) [\(targetLabel)] [\(mode.promptLabel)]\(suffix)"
        }
    }

    enum Target: Sendable, Equatable {
        case base(String)
        case composition(String)

        var promptLabel: String {
            switch self {
            case .base(let id): "base:\(id)"
            case .composition(let id): "composition:\(id)"
            }
        }
    }

    func completionSnapshot(
        profileName: String?,
        fixedSession: RemoteSession?
    ) async -> ShellCompletionSnapshot {
        let profileNames: [String]
        do {
            profileNames = try application.profiles.load().profiles
                .map(\.name)
                .sorted()
        } catch {
            output.diagnostic(
                "warning: profile completion is unavailable: \(error)\n"
            )
            return ShellCompletionSnapshot(
                catalog: application.parser.catalog,
                profileNames: []
            )
        }

        let activeSession: RemoteSession
        let ownsSession: Bool
        do {
            if let fixedSession {
                activeSession = fixedSession
                ownsSession = false
            } else if let profileName {
                let options = CommandOptions([
                    "profile": [profileName],
                ])
                activeSession = try application.sessionFactory(
                    ResolvedConnection.resolve(
                        options: options,
                        profileStore: application.profiles,
                        credentials: application.credentials
                    )
                )
                ownsSession = true
            } else {
                return ShellCompletionSnapshot(
                    catalog: application.parser.catalog,
                    profileNames: profileNames
                )
            }
        } catch {
            output.diagnostic(
                "warning: server completion is unavailable: \(error)\n"
            )
            return ShellCompletionSnapshot(
                catalog: application.parser.catalog,
                profileNames: profileNames
            )
        }

        let capabilities: CapabilitiesDescribeOperation.Response
        do {
            capabilities = try await activeSession.client.database.execute(
                DatabaseOperations.capabilitiesDescribe,
                request: EmptyOperationPayload()
            )
        } catch {
            if ownsSession { await activeSession.shutdown() }
            output.diagnostic(
                "warning: capability completion is unavailable: \(error)\n"
            )
            return ShellCompletionSnapshot(
                catalog: application.parser.catalog,
                profileNames: profileNames
            )
        }

        var schema: SchemaDescribeOperation.Response?
        if capabilities.features.contains(where: {
            $0.identifier == "schema.describe"
        }) {
            do {
                schema = try await activeSession.client.database.execute(
                    DatabaseOperations.schemaDescribe,
                    request: EmptyOperationPayload()
                )
            } catch {
                output.diagnostic(
                    "warning: schema completion is unavailable: \(error)\n"
                )
            }
        }
        if ownsSession { await activeSession.shutdown() }
        return ShellCompletionSnapshot(
            catalog: application.parser.catalog,
            profileNames: profileNames,
            capabilities: capabilities,
            schema: schema
        )
    }

    func handleMeta(
        _ line: String,
        state: inout State
    ) async throws -> Bool {
        let tokens = try ShellLexer().parse(line)
        guard let meta = tokens.first else { return false }
        switch meta {
        case "\\help":
            _ = try output.result(
                """
                \\help
                \\profile <name>
                \\base <id>
                \\composition <id>
                \\output table|jsonl|json|csv|nquads
                \\timing on|off
                \\budget
                \\page-size <count>
                \\next
                \\history
                \\mode command|sql-query|sql-mutation|sparql-query|sparql-update
                \\g
                \\clear
                \\quit
                """ + "\n"
            )
        case "\\profile":
            guard session == nil else {
                throw DatabaseCLIError(
                    .input,
                    "A local database shell cannot switch to a remote profile"
                )
            }
            guard tokens.count == 2 else {
                throw DatabaseCLIError(.input, "Usage: \\profile <name>")
            }
            let profile = try application.profiles.selectedProfile(named: tokens[1])
            state.profile = profile.name
            state.promptConnection = profile.name
            state.database = profile.databaseID
            state.target = nil
        case "\\base":
            guard tokens.count == 2 else {
                throw DatabaseCLIError(.input, "Usage: \\base <id>")
            }
            _ = try Base.ID(tokens[1])
            state.target = .base(tokens[1])
            state.statementLines.removeAll(keepingCapacity: true)
        case "\\composition":
            guard tokens.count == 2 else {
                throw DatabaseCLIError(.input, "Usage: \\composition <id>")
            }
            _ = try Base.Composition.ID(tokens[1])
            state.target = .composition(tokens[1])
            state.statementLines.removeAll(keepingCapacity: true)
        case "\\output":
            guard tokens.count == 2,
                  OutputFormat(rawValue: tokens[1]) != nil else {
                throw DatabaseCLIError(
                    .input,
                    "Usage: \\output table|jsonl|json|csv|nquads"
                )
            }
            state.outputFormat = tokens[1]
        case "\\timing":
            guard tokens.count == 2,
                  ["on", "off"].contains(tokens[1]) else {
                throw DatabaseCLIError(.input, "Usage: \\timing on|off")
            }
            state.timing = tokens[1] == "on"
        case "\\budget":
            guard tokens.count == 1 else {
                throw DatabaseCLIError(.input, "Usage: \\budget")
            }
            _ = try output.result(
                "maximumRows=10000 maximumWorkUnits=1000000 "
                    + "maximumIntermediateRows=10000 "
                    + "maximumIntermediateBytes=16777216 "
                    + "timeoutMilliseconds=30000\n"
            )
        case "\\page-size":
            guard tokens.count == 2,
                  let size = UInt32(tokens[1]), size > 0 else {
                throw DatabaseCLIError(
                    .input,
                    "Usage: \\page-size <positive-count>"
                )
            }
            state.pageSize = String(size)
        case "\\next":
            guard tokens.count == 1,
                  let last = state.lastArguments,
                  let continuation = state.lastContinuation else {
                throw DatabaseCLIError(.input, "No continuation is available")
            }
            var next = removingOption("continuation", from: last)
            next.append(contentsOf: [
                "--continuation",
                Base64URL.encode(continuation),
            ])
            try await execute(next, state: &state)
        case "\\history":
            for (index, item) in state.history.enumerated() {
                _ = try output.result("\(index + 1)  \(item)\n")
            }
        case "\\mode":
            guard tokens.count == 2 else {
                throw DatabaseCLIError(
                    .input,
                    "Usage: \\mode command|sql-query|sql-mutation|sparql-query|sparql-update"
                )
            }
            state.mode = try ShellMode(tokens[1])
            state.statementLines.removeAll(keepingCapacity: true)
        case "\\clear":
            guard tokens.count == 1 else {
                throw DatabaseCLIError(.input, "Usage: \\clear")
            }
            state.statementLines.removeAll(keepingCapacity: true)
        case "\\g":
            guard tokens.count == 1,
                  let prefix = state.mode.commandPrefix else {
                throw DatabaseCLIError(.input, "No statement mode is active")
            }
            let statement = state.statementLines.joined(separator: "\n")
            guard !statement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw DatabaseCLIError(.input, "Statement buffer is empty")
            }
            state.statementLines.removeAll(keepingCapacity: true)
            try await execute(prefix + [statement], state: &state)
        case "\\quit":
            guard tokens.count == 1 else {
                throw DatabaseCLIError(.input, "Usage: \\quit")
            }
            return true
        default:
            throw DatabaseCLIError(.input, "Unknown shell meta command '\(meta)'")
        }
        return false
    }

    func execute(
        _ rawArguments: [String],
        state: inout State
    ) async throws {
        var arguments = rawArguments
        let descriptor = try commandDescriptor(for: rawArguments)
        appendDefaultOption(
            "profile",
            value: state.profile,
            whenSupportedBy: descriptor,
            to: &arguments
        )
        appendDefaultOption(
            "output",
            value: state.outputFormat,
            whenSupportedBy: descriptor,
            to: &arguments
        )
        appendDefaultOption(
            "page-size",
            value: state.pageSize,
            whenSupportedBy: descriptor,
            to: &arguments
        )
        try appendSelectedTarget(
            state.target,
            whenSupportedBy: descriptor,
            to: &arguments
        )
        let executionArguments = arguments

        let capture = ContinuationCapture()
        let start = ContinuousClock.now
        do {
            try await InterruptibleCommand.runShellOperation {
                try await application.execute(
                    executionArguments,
                    continuationCapture: capture,
                    sessionOverride: session
                )
            }
        } catch is ShellInterrupt {
            output.diagnostic("^C\n")
            return
        } catch {
            throw error
        }
        if state.timing {
            output.diagnostic("Time: \(start.duration(to: .now))\n")
        }
        state.lastArguments = executionArguments
        state.lastContinuation = capture.load()
        let historyLine = ShellLexer().join(executionArguments)
        if executionArguments.first != "auth" {
            state.history.append(historyLine)
            if state.persistentHistory {
                try appendHistory(historyLine, to: state.historyURL)
            }
        }
    }

    func commandDescriptor(
        for arguments: [String]
    ) throws -> CommandDescriptor {
        if arguments == ["--version"]
            || arguments == ["--help"]
            || arguments == ["-h"] {
            let parsed = try application.parser.parse(arguments)
            guard let descriptor = application.parser.catalog.command(
                for: parsed.path
            ) else {
                throw DatabaseCLIError(
                    .internalFailure,
                    "Global command alias is missing from the command catalog"
                )
            }
            return descriptor
        }
        let prefix = arguments.prefix { !$0.hasPrefix("-") }
        let maximum = min(3, prefix.count)
        guard maximum > 0 else {
            throw DatabaseCLIError(.input, "A command is required")
        }
        for count in stride(from: maximum, through: 1, by: -1) {
            let path = Array(prefix.prefix(count))
            if let descriptor = application.parser.catalog.command(for: path) {
                return descriptor
            }
        }
        throw DatabaseCLIError(
            .input,
            "Unknown shell command '\(prefix.joined(separator: " "))'"
        )
    }

    func appendSelectedTarget(
        _ target: Target?,
        whenSupportedBy command: CommandDescriptor,
        to arguments: inout [String]
    ) throws {
        let supportsBase = command.option(named: "base") != nil
        let supportsComposition = command.option(named: "composition") != nil
        guard supportsBase || supportsComposition else { return }
        guard !arguments.contains("--base"),
              !arguments.contains("--composition"),
              !arguments.contains("--database-target"),
              !arguments.contains(where: { $0.hasPrefix("--base=") }),
              !arguments.contains(where: { $0.hasPrefix("--composition=") }) else {
            return
        }
        guard let target else { return }
        switch target {
        case .base(let id) where supportsBase:
            arguments.append(contentsOf: ["--base", id])
        case .composition(let id) where supportsComposition:
            arguments.append(contentsOf: ["--composition", id])
        case .composition:
            throw DatabaseCLIError(
                .input,
                "'\(command.path.joined(separator: " "))' requires a Base target"
            )
        case .base:
            throw DatabaseCLIError(
                .input,
                "'\(command.path.joined(separator: " "))' does not accept a Base target"
            )
        }
    }

    func appendDefaultOption(
        _ name: String,
        value: String?,
        whenSupportedBy command: CommandDescriptor,
        to arguments: inout [String]
    ) {
        guard command.option(named: name) != nil,
              let value,
              !arguments.contains("--\(name)"),
              !arguments.contains(where: { $0.hasPrefix("--\(name)=") }) else {
            return
        }
        arguments.append(contentsOf: ["--\(name)", value])
    }

    func removingOption(_ name: String, from arguments: [String]) -> [String] {
        var result: [String] = []
        var index = 0
        while index < arguments.count {
            if arguments[index] == "--\(name)" {
                index += min(2, arguments.count - index)
            } else if arguments[index].hasPrefix("--\(name)=") {
                index += 1
            } else {
                result.append(arguments[index])
                index += 1
            }
        }
        return result
    }

    func historyURL() throws -> URL {
        if let configured = command.options.value("history-file") {
            return URL(fileURLWithPath: configured)
        }
        return DatabaseCLIPaths.configurationDirectory()
            .appendingPathComponent("history", isDirectory: false)
    }

    func appendHistory(_ line: String, to url: URL) throws {
        do {
            try SecureLocalFile.append(
                Data((line + "\n").utf8),
                to: url
            )
        } catch let error as DatabaseCLIError {
            throw error
        } catch {
            throw DatabaseCLIError(.input, "Cannot persist shell history: \(error)")
        }
    }
}

struct ShellLexer: Sendable {
    func parse(_ line: String) throws -> [String] {
        var result: [String] = []
        var current = ""
        var quote: Character?
        var escaping = false
        var hasToken = false
        for character in line {
            if escaping {
                current.append(character)
                escaping = false
                hasToken = true
                continue
            }
            if character == "\\", quote != "'" {
                if quote == nil, !hasToken {
                    current.append(character)
                    hasToken = true
                } else {
                    escaping = true
                    hasToken = true
                }
                continue
            }
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else {
                    current.append(character)
                }
                hasToken = true
                continue
            }
            if character == "'" || character == "\"" {
                quote = character
                hasToken = true
            } else if character.isWhitespace {
                if hasToken {
                    result.append(current)
                    current = ""
                    hasToken = false
                }
            } else {
                current.append(character)
                hasToken = true
            }
        }
        guard quote == nil, !escaping else {
            throw DatabaseCLIError(.input, "Unterminated shell quote or escape")
        }
        if hasToken { result.append(current) }
        return result
    }

    func join(_ arguments: [String]) -> String {
        arguments.map { argument in
            if argument.isEmpty { return "''" }
            if argument.allSatisfy({ !$0.isWhitespace && $0 != "'" }) {
                return argument
            }
            return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }.joined(separator: " ")
    }
}
