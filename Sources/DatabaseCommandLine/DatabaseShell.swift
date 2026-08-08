import DatabaseTypes
import Foundation

struct DatabaseShell: Sendable {
    let application: DatabaseCLIApplication
    let command: ParsedCommand
    let output: OutputWriter

    func run() async throws {
        let input = ShellInputReader()
        var state = State(
            profile: command.options.value("profile"),
            outputFormat: command.options.value("output"),
            pageSize: command.options.value("page-size"),
            persistentHistory: command.options.contains("persist-history"),
            historyURL: try historyURL()
        )
        output.diagnostic(
            "Database shell \(DatabaseCLIVersion.current). Use \\help for commands.\n"
        )
        while true {
            output.diagnostic(state.multiline == nil ? "database> " : "...> ")
            let line: String
            do {
                guard let value = try await input.readLine() else {
                    output.diagnostic("\n")
                    await input.shutdown()
                    return
                }
                line = value
            } catch is ShellInterrupt {
                state.multiline = nil
                output.diagnostic("^C\n")
                continue
            } catch {
                await input.shutdown()
                throw error
            }
            if line.hasPrefix("\\") {
                do {
                    if try await handleMeta(line, state: &state) {
                        await input.shutdown()
                        return
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
            if state.multiline != nil {
                state.multiline?.lines.append(line)
                continue
            }
            let tokens = try ShellLexer().parse(line)
            guard !tokens.isEmpty else { continue }
            if tokens.count >= 2,
               ["query", "mutate"].contains(tokens[0]),
               ["sql", "sparql"].contains(tokens[1]),
               (tokens.count == 2 || tokens[2].hasPrefix("--")) {
                state.multiline = Multiline(
                    prefix: Array(tokens.prefix(2)),
                    options: Array(tokens.dropFirst(2)),
                    lines: []
                )
                continue
            }
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
    struct Multiline {
        let prefix: [String]
        let options: [String]
        var lines: [String]
    }

    struct State {
        var profile: String?
        var outputFormat: String?
        var pageSize: String?
        var timing = false
        var history: [String] = []
        var lastArguments: [String]?
        var lastContinuation: ByteString?
        var multiline: Multiline?
        let persistentHistory: Bool
        let historyURL: URL
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
                \\output table|jsonl|json|csv|nquads
                \\timing on|off
                \\budget
                \\page-size <count>
                \\next
                \\history
                \\mode command
                \\g
                \\clear
                \\quit
                """ + "\n"
            )
        case "\\profile":
            guard tokens.count == 2 else {
                throw DatabaseCLIError(.input, "Usage: \\profile <name>")
            }
            _ = try application.profiles.selectedProfile(named: tokens[1])
            state.profile = tokens[1]
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
            guard tokens == ["\\mode", "command"] else {
                throw DatabaseCLIError(.input, "Usage: \\mode command")
            }
            state.multiline = nil
        case "\\clear":
            guard tokens.count == 1 else {
                throw DatabaseCLIError(.input, "Usage: \\clear")
            }
            state.multiline?.lines.removeAll(keepingCapacity: true)
        case "\\g":
            guard tokens.count == 1, let multiline = state.multiline else {
                throw DatabaseCLIError(.input, "No multiline statement is active")
            }
            let statement = multiline.lines.joined(separator: "\n")
            guard !statement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw DatabaseCLIError(.input, "Statement buffer is empty")
            }
            state.multiline = nil
            try await execute(
                multiline.prefix + [statement] + multiline.options,
                state: &state
            )
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
        appendDefaultOption("profile", value: state.profile, to: &arguments)
        appendDefaultOption("output", value: state.outputFormat, to: &arguments)
        appendDefaultOption("page-size", value: state.pageSize, to: &arguments)
        let executionArguments = arguments

        let capture = ContinuationCapture()
        let start = ContinuousClock.now
        do {
            try await InterruptibleCommand.runShellOperation {
                try await application.execute(
                    executionArguments,
                    continuationCapture: capture
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

    func appendDefaultOption(
        _ name: String,
        value: String?,
        to arguments: inout [String]
    ) {
        guard let value,
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
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("database", isDirectory: true)
            .appendingPathComponent("history", isDirectory: false)
    }

    func appendHistory(_ line: String, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            if !FileManager.default.fileExists(atPath: url.path) {
                guard FileManager.default.createFile(
                    atPath: url.path,
                    contents: nil,
                    attributes: [.posixPermissions: 0o600]
                ) else {
                    throw DatabaseCLIError(.input, "Cannot create history file")
                }
            }
            let handle = try FileHandle(forWritingTo: url)
            var operationError: (any Error)?
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: Data((line + "\n").utf8))
            } catch {
                operationError = error
            }
            do {
                try handle.close()
            } catch {
                if let operationError {
                    throw DatabaseCLIError(
                        .input,
                        "History write failed (\(operationError)) and the file could not be closed (\(error))"
                    )
                }
                throw error
            }
            if let operationError {
                throw operationError
            }
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
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
