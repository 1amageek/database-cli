import Foundation
import Testing
@testable import DatabaseCommandLine

@Suite("Command catalog")
struct CommandCatalogTests {
    @Test("catalog paths and option names are unique and every contract resolves")
    func catalogIsInternallyConsistent() throws {
        let catalog = CommandCatalog.standard
        #expect(Set(catalog.commands.map(\.path)).count == catalog.commands.count)
        #expect(
            Set(catalog.commonOptions.map(\.name)).count
                == catalog.commonOptions.count
        )
        for command in catalog.commands {
            let options = command.options + catalog.commonOptions.filter {
                command.option(named: $0.name) == nil
            }
            let names = Set(options.map(\.name))
            #expect(names.count == options.count)
            for option in options {
                #expect(option.minimumOccurrences >= 0)
                if let maximum = option.maximumOccurrences {
                    #expect(maximum >= option.minimumOccurrences)
                }
                #expect(option.conflictsWith.isSubset(of: names))
                #expect(option.requires.isSubset(of: names))
            }
        }
    }

    @Test("nested help is generated from the same required option descriptors")
    func nestedHelpShowsExactContracts() throws {
        let result = try captureResult { output in
            try DatabaseCLIApplication(output: output)
                .showHelp(["graph", "shortest-path"])
        }

        #expect(result.contains("database graph shortest-path"))
        #expect(result.contains("--index <value>"))
        #expect(result.contains("required"))
        #expect(result.contains("--parameter <binding>"))
        #expect(result.contains("repeatable"))
    }

    @Test("every static completion is generated from every catalog path", arguments: [
        "bash", "zsh", "fish",
    ])
    func completionContainsEveryCatalogPath(_ shell: String) throws {
        let catalog = CommandCatalog.standard
        let completion = try CompletionGenerator(catalog: catalog)
            .generate(for: shell)

        for command in catalog.commands where command.path != ["help"] {
            #expect(completion.contains(command.path.joined(separator: " ")))
        }
        #expect(!completion.contains("https://"))
        #expect(!completion.contains("curl "))
    }

    @Test("checked-in completions exactly match the catalog generator")
    func checkedInCompletionsMatchGenerator() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixtures = [
            (shell: "bash", path: "Completions/database.bash"),
            (shell: "zsh", path: "Completions/_database"),
            (shell: "fish", path: "Completions/database.fish"),
        ]
        let generator = CompletionGenerator(catalog: .standard)

        for fixture in fixtures {
            let checkedIn = try String(
                contentsOf: root.appendingPathComponent(fixture.path),
                encoding: .utf8
            )
            let generated = try generator.generate(for: fixture.shell)
            #expect(checkedIn == generated)
        }
    }
}

private func captureResult(
    _ body: (OutputWriter) throws -> Void
) throws -> String {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(Foundation.UUID().uuidString)
    guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
        throw DatabaseCLIError(.internalFailure, "Unable to create test output")
    }
    let handle = try FileHandle(forWritingTo: url)
    do {
        try body(
            OutputWriter(
                resultHandle: handle,
                diagnosticHandle: .nullDevice
            )
        )
        try handle.close()
        let data = try Data(contentsOf: url)
        try FileManager.default.removeItem(at: url)
        guard let result = String(data: data, encoding: .utf8) else {
            throw DatabaseCLIError(.internalFailure, "Test output is not UTF-8")
        }
        return result
    } catch let operationError {
        do {
            try handle.close()
        } catch let closeError {
            throw closeError
        }
        do {
            try FileManager.default.removeItem(at: url)
        } catch let removalError {
            throw removalError
        }
        throw operationError
    }
}
