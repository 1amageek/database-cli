struct CompletionGenerator: Sendable {
    let catalog: CommandCatalog

    func generate(for shell: String) throws -> String {
        let paths = catalog.commands
            .filter { $0.path != ["help"] }
            .map { $0.path.joined(separator: " ") }
            .sorted()
        let roots = Set(catalog.commands.compactMap(\.path.first)).sorted()
        switch shell {
        case "bash":
            return """
            _database() {
                local current="${COMP_WORDS[COMP_CWORD]}"
                local prefix="${COMP_WORDS[*]:1:COMP_CWORD-1}"
                local commands="\(paths.joined(separator: " "))"
                if [[ -z "$prefix" ]]; then
                    COMPREPLY=( $(compgen -W "\(roots.joined(separator: " "))" -- "$current") )
                else
                    COMPREPLY=( $(compgen -W "$commands" -- "$prefix $current") )
                    COMPREPLY=( "${COMPREPLY[@]#"$prefix "}" )
                fi
            }
            complete -F _database database
            """ + "\n"
        case "zsh":
            return """
            #compdef database
            _database() {
                local -a commands
                commands=(\(paths.map(shellQuote).joined(separator: " ")))
                _describe 'database command' commands
            }
            compdef _database database
            """ + "\n"
        case "fish":
            return paths.map {
                "complete -c database -f -a \(shellQuote($0))"
            }.joined(separator: "\n") + "\n"
        default:
            throw DatabaseCLIError(
                .input,
                "Unsupported completion shell '\(shell)'"
            )
        }
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
