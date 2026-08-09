import Foundation

struct FDBCommand: Sendable {
    let path: [String]
    let positionals: [String]
    let options: [String: String]

    func option(_ name: String) -> String? { options[name] }
}

struct FDBCommandParser: Sendable {
    func parse(_ arguments: [String]) throws -> FDBCommand {
        if arguments.isEmpty || arguments == ["--help"] || arguments == ["-h"] {
            return FDBCommand(path: ["help"], positionals: [], options: [:])
        }
        if arguments == ["--version"] { return FDBCommand(path: ["version"], positionals: [], options: [:]) }
        guard arguments.count >= 2 else {
            throw FDBCLIError(.input, usage)
        }
        let path = Array(arguments.prefix(2))
        let allowed: Set<String>
        let positionalRange: ClosedRange<Int>
        switch path {
        case ["cluster", "init"]:
            allowed = ["path", "port"]
            positionalRange = 0...0
        case ["cluster", "start"]:
            allowed = ["path", "cluster-file", "minimum-available-space-ratio"]
            positionalRange = 0...0
        case ["cluster", "stop"], ["cluster", "status"]:
            allowed = ["path", "cluster-file"]
            positionalRange = 0...0
        case ["catalog", "list"]:
            allowed = ["cluster-file"]
            positionalRange = 0...0
        case ["catalog", "show"]:
            allowed = ["cluster-file"]
            positionalRange = 1...1
        case ["raw", "get"]:
            allowed = ["cluster-file", "key-hex", "key-utf8", "key-tuple", "max-total-bytes"]
            positionalRange = 0...0
        case ["raw", "range"]:
            allowed = ["cluster-file", "key-hex", "key-utf8", "key-tuple", "limit", "max-total-bytes"]
            positionalRange = 0...0
        default:
            throw FDBCLIError(.input, "Unknown FoundationDB command\n\(usage)")
        }

        var options: [String: String] = [:]
        var positionals: [String] = []
        var index = 2
        while index < arguments.count {
            let token = arguments[index]
            if token.hasPrefix("--") {
                let body = String(token.dropFirst(2))
                let name: String
                let value: String
                if let separator = body.firstIndex(of: "=") {
                    name = String(body[..<separator])
                    value = String(body[body.index(after: separator)...])
                } else {
                    name = body
                    index += 1
                    guard index < arguments.count else {
                        throw FDBCLIError(.input, "Option '--\(name)' requires a value")
                    }
                    value = arguments[index]
                }
                guard allowed.contains(name) else {
                    throw FDBCLIError(.input, "Unknown option '--\(name)'")
                }
                guard !value.isEmpty, options[name] == nil else {
                    throw FDBCLIError(.input, "Option '--\(name)' is empty or repeated")
                }
                options[name] = value
            } else {
                positionals.append(token)
            }
            index += 1
        }
        guard positionalRange.contains(positionals.count) else {
            throw FDBCLIError(.input, usage)
        }
        return FDBCommand(path: path, positionals: positionals, options: options)
    }

    var usage: String {
        """
        Usage:
          database fdb cluster init [--path <directory>] [--port <port>]
          database fdb cluster start [--path <directory>]
                    [--minimum-available-space-ratio <ratio>]
          database fdb cluster stop|status [--path <directory>]
          database fdb catalog list [--cluster-file <path>]
          database fdb catalog show <entity> [--cluster-file <path>]
          database fdb raw get --key-hex|--key-utf8|--key-tuple <value>
          database fdb raw range --key-hex|--key-utf8|--key-tuple <prefix>
                    --limit <rows> --max-total-bytes <bytes>
        """
    }
}
