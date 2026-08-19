import Foundation
import Testing
@testable import DatabaseCommandLine

#if DATABASE_CLI_MULTI_BASE
private struct CommandFixture: Sendable {
    let arguments: [String]
    let path: [String]
}

private let commandFixtures: [CommandFixture] = [
    .init(arguments: [], path: ["help"]),
    .init(arguments: ["--version"], path: ["version"]),
    .init(arguments: ["capabilities"], path: ["capabilities"]),
    .init(arguments: ["profile", "create", "local", "--endpoint", "https://db.test"], path: ["profile", "create"]),
    .init(arguments: ["profile", "list"], path: ["profile", "list"]),
    .init(arguments: ["profile", "show", "local"], path: ["profile", "show"]),
    .init(arguments: ["profile", "use", "local"], path: ["profile", "use"]),
    .init(arguments: ["profile", "remove", "local"], path: ["profile", "remove"]),
    .init(arguments: ["auth", "login"], path: ["auth", "login"]),
    .init(arguments: ["auth", "logout"], path: ["auth", "logout"]),
    .init(arguments: ["schema", "list"], path: ["schema", "list"]),
    .init(arguments: ["schema", "show", "Person"], path: ["schema", "show"]),
    .init(arguments: ["schema", "plan", schemaJSON], path: ["schema", "plan"]),
    .init(
        arguments: [
            "schema", "apply", schemaJSON,
            "--expected-fingerprint", emptyFingerprint,
            "--idempotency-key", "schema-1",
        ],
        path: ["schema", "apply"]
    ),
    .init(arguments: ["base", "placements"], path: ["base", "placements"]),
    .init(arguments: ["base", "list"], path: ["base", "list"]),
    .init(arguments: ["base", "describe", baseID], path: ["base", "describe"]),
    .init(arguments: ["base", "create", baseID, "--placement", "default", "--initial-grant", initialGrant, "--expected-revision", "0", "--idempotency-key", "base-create"], path: ["base", "create"]),
    .init(arguments: ["base", "retire", baseID, "--expected-revision", "1", "--idempotency-key", "base-retire"], path: ["base", "retire"]),
    .init(arguments: ["base", "activate", baseID, "--expected-revision", "2", "--idempotency-key", "base-activate"], path: ["base", "activate"]),
    .init(arguments: ["base", "delete", baseID, "--expected-revision", "3", "--idempotency-key", "base-delete"], path: ["base", "delete"]),
    .init(arguments: ["base", "placement", "plan", baseID, "--destination", "archive", "--expected-revision", "4"], path: ["base", "placement", "plan"]),
    .init(arguments: ["base", "placement", "apply", baseID, "--destination", "archive", "--expected-revision", "4", "--idempotency-key", "base-move"], path: ["base", "placement", "apply"]),
    .init(arguments: ["composition", "list"], path: ["composition", "list"]),
    .init(arguments: ["composition", "describe", compositionID], path: ["composition", "describe"]),
    .init(arguments: ["composition", "create", compositionID, "--base", baseID, "--expected-revision", "0", "--idempotency-key", "composition-create"], path: ["composition", "create"]),
    .init(arguments: ["composition", "replace", compositionID, "--base", baseID, "--expected-revision", "1", "--idempotency-key", "composition-replace"], path: ["composition", "replace"]),
    .init(arguments: ["composition", "delete", compositionID, "--expected-revision", "2", "--idempotency-key", "composition-delete"], path: ["composition", "delete"]),
    .init(arguments: ["grant", "direct"], path: ["grant", "direct"]),
    .init(arguments: ["grant", "effective", "--base", baseID], path: ["grant", "effective"]),
    .init(arguments: ["grant", "add", "--base", baseID, "--principal", "alice", "--access", "read,write", "--expected-revision", "0", "--idempotency-key", "grant-add"], path: ["grant", "add"]),
    .init(arguments: ["grant", "revoke", "--base", baseID, "--principal", "alice", "--access", "write", "--expected-revision", "1", "--idempotency-key", "grant-revoke"], path: ["grant", "revoke"]),
    .init(arguments: ["query", "sql", "SELECT 1", "--base", baseID], path: ["query", "sql"]),
    .init(arguments: ["query", "sparql", "SELECT * WHERE {}", "--composition", compositionID], path: ["query", "sparql"]),
    .init(arguments: ["mutate", "sql", "DELETE FROM Person", "--base", baseID], path: ["mutate", "sql"]),
    .init(arguments: ["mutate", "sparql", "CLEAR DEFAULT", "--base", baseID], path: ["mutate", "sparql"]),
    .init(arguments: ["entity", "insert", "Person", idValue, objectValue, "--base", baseID], path: ["entity", "insert"]),
    .init(arguments: ["entity", "update", "Person", idValue, objectValue, "--base", baseID], path: ["entity", "update"]),
    .init(arguments: ["entity", "upsert", "Person", idValue, objectValue, "--base", baseID], path: ["entity", "upsert"]),
    .init(arguments: ["entity", "delete", "Person", idValue, "--base", baseID], path: ["entity", "delete"]),
    .init(arguments: ["entity", "apply", "[]", "--base", baseID], path: ["entity", "apply"]),
    .init(arguments: ["graph", "shortest-path", "--index", "graph", "--source", stringValue, "--target", stringValue, "--base", baseID], path: ["graph", "shortest-path"]),
    .init(arguments: ["graph", "weighted-shortest-path", "--index", "graph", "--source", stringValue, "--target", stringValue, "--weight-property", "cost", "--base", baseID], path: ["graph", "weighted-shortest-path"]),
    .init(arguments: ["graph", "page-rank", "--index", "graph", "--base", baseID], path: ["graph", "page-rank"]),
    .init(arguments: ["graph", "community", "--index", "graph", "--base", baseID], path: ["graph", "community"]),
    .init(arguments: ["graph", "cycles", "--index", "graph", "--base", baseID], path: ["graph", "cycles"]),
    .init(arguments: ["graph", "strongly-connected-components", "--index", "graph", "--base", baseID], path: ["graph", "strongly-connected-components"]),
    .init(arguments: ["graph", "topological-sort", "--index", "graph", "--base", baseID], path: ["graph", "topological-sort"]),
    .init(arguments: ["ontology", "describe", "world", "--base", baseID], path: ["ontology", "describe"]),
    .init(arguments: ["ontology", "upsert", objectValue, "--base", baseID], path: ["ontology", "upsert"]),
    .init(arguments: ["ontology", "delete", "world", "--base", baseID], path: ["ontology", "delete"]),
    .init(arguments: ["ontology", "reason", "world", "--base", baseID], path: ["ontology", "reason"]),
    .init(arguments: ["ontology", "hierarchy", "world", "urn:Class", "--base", baseID], path: ["ontology", "hierarchy"]),
    .init(arguments: ["ontology", "validate-schema", "world", "--base", baseID], path: ["ontology", "validate-schema"]),
    .init(arguments: ["shacl", "describe", "urn:shapes", "--base", baseID], path: ["shacl", "describe"]),
    .init(arguments: ["shacl", "upsert", "urn:shapes", "<urn:s> <urn:p> <urn:o> .", "--base", baseID], path: ["shacl", "upsert"]),
    .init(arguments: ["shacl", "delete", "urn:shapes", "--base", baseID], path: ["shacl", "delete"]),
    .init(arguments: ["shacl", "validate", "urn:shapes", "--entity", "Person", "--index", "byName", "--base", baseID], path: ["shacl", "validate"]),
    .init(arguments: ["command", "run", "system.inspect", objectValue, "--base", baseID], path: ["command", "run"]),
    .init(arguments: ["migration", "status", "--base", baseID], path: ["migration", "status"]),
    .init(arguments: ["migration", "run", "--base", baseID], path: ["migration", "run"]),
    .init(arguments: ["index", "status", "--base", baseID], path: ["index", "status"]),
    .init(arguments: ["index", "rebuild", "Person", "byName", "--base", baseID], path: ["index", "rebuild"]),
    .init(arguments: ["maintenance", "compact", "--base", baseID], path: ["maintenance", "compact"]),
    .init(arguments: ["job", "status", uuid, "queryExecute", "query", "--base", baseID], path: ["job", "status"]),
    .init(arguments: ["job", "wait", uuid, "queryExecute", "query", "--base", baseID], path: ["job", "wait"]),
    .init(arguments: ["job", "result", uuid, "queryExecute", "query", "--base", baseID], path: ["job", "result"]),
    .init(arguments: ["job", "cancel", uuid, "queryExecute", "query", "--base", baseID], path: ["job", "cancel"]),
    .init(arguments: ["shell"], path: ["shell"]),
    .init(arguments: ["inspect", "overview"], path: ["inspect", "overview"]),
    .init(arguments: ["inspect", "entities"], path: ["inspect", "entities"]),
    .init(arguments: ["inspect", "indexes", "--base", baseID], path: ["inspect", "indexes"]),
    .init(arguments: ["inspect", "graph"], path: ["inspect", "graph"]),
    .init(arguments: ["inspect", "ontology", "world", "--base", baseID], path: ["inspect", "ontology"]),
    .init(arguments: ["inspect", "shapes", "urn:shapes", "--base", baseID], path: ["inspect", "shapes"]),
    .init(arguments: ["inspect", "jobs"], path: ["inspect", "jobs"]),
    .init(arguments: ["doctor"], path: ["doctor"]),
    .init(arguments: ["completion", "bash"], path: ["completion", "bash"]),
    .init(arguments: ["completion", "zsh"], path: ["completion", "zsh"]),
    .init(arguments: ["completion", "fish"], path: ["completion", "fish"]),
    .init(arguments: ["open", "database.sqlite"], path: ["open"]),
    .init(arguments: ["open", "--memory"], path: ["open"]),
    .init(
        arguments: [
            "open", "--storage", "postgresql",
            "--postgres-host", "db.test",
            "--postgres-user", "database",
            "--postgres-database", "database",
        ],
        path: ["open"]
    ),
    .init(
        arguments: [
            "open", "--storage", "foundationdb",
            "--fdb-cluster-file", "/tmp/fdb.cluster",
            "--fdb-directory", "applications",
            "--fdb-directory", "main",
        ],
        path: ["open"]
    ),
    .init(
        arguments: ["serve", "database.sqlite", "--profile", "local"],
        path: ["serve"]
    ),
    .init(arguments: ["fdb", "cluster", "status"], path: ["fdb"]),
]

private let idValue = #"{"$type":"string","value":"p1"}"#
private let stringValue = #"{"$type":"string","value":"node"}"#
private let objectValue = #"{"$type":"object","value":{}}"#
private let uuid = "00000000-0000-0000-0000-000000000001"
private let schemaJSON = #"{"formatVersion":2,"schemaVersion":{"major":1,"minor":0,"patch":0},"entities":[]}"#
private let emptyFingerprint = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
private let baseID = "company-a"
private let compositionID = "shared"
private let initialGrant = "role:admin=administer"

@Test("Every public command parses", arguments: commandFixtures)
private func parsesEveryCommand(_ fixture: CommandFixture) throws {
    #expect(try CommandParser().parse(fixture.arguments).path == fixture.path)
}

@Test("Parser fixtures cover every public command path")
func parserFixturesCoverCatalog() {
    #expect(Set(commandFixtures.map(\.path)) == Set(CommandCatalog.standard.commands.map(\.path)))
}

@Test("One-shot and shell tokenization produce the same AST")
func shellAndOneShotShareAST() throws {
    let line = #"query sql "SELECT * FROM Person" --base company-a --page-size 25 --output jsonl"#
    let tokens = try ShellLexer().parse(line)
    let shellAST = try CommandParser().parse(tokens)
    let oneShotAST = try CommandParser().parse([
        "query", "sql", "SELECT * FROM Person",
        "--base", "company-a", "--page-size", "25", "--output", "jsonl",
    ])
    #expect(shellAST == oneShotAST)
}

@Test("Duplicate and unknown options are rejected")
func rejectsAmbiguousOptions() {
    #expect(throws: DatabaseCLIError.self) {
        try CommandParser().parse([
            "capabilities", "--profile", "a", "--profile", "b",
        ])
    }
    #expect(throws: DatabaseCLIError.self) {
        try CommandParser().parse(["capabilities", "--secret", "value"])
    }
}

@Test("All-page mode requires every explicit safety bound")
func allRequiresBounds() {
    #expect(throws: DatabaseCLIError.self) {
        try CommandParser().parse(["query", "sql", "SELECT 1", "--base", baseID, "--all"])
    }
    #expect(throws: Never.self) {
        try CommandParser().parse([
            "query", "sql", "SELECT 1", "--base", baseID, "--all",
            "--max-total-rows", "10",
            "--max-total-bytes", "4096",
            "--max-pages", "2",
        ])
    }
    #expect(throws: DatabaseCLIError.self) {
        try CommandParser().parse([
            "query", "sql", "SELECT 1", "--base", baseID,
            "--max-total-rows", "10",
        ])
    }
    #expect(throws: DatabaseCLIError.self) {
        try CommandParser().parse([
            "query", "sql", "SELECT 1", "--base", baseID, "--all",
            "--max-total-rows", "10",
            "--max-total-bytes", "4096",
            "--max-pages", "2",
            "--as-job", "query",
        ])
    }
}

@Test("Options that have no execution meaning are rejected")
func rejectsInapplicableOptions() {
    let parser = CommandParser()
    #expect(throws: DatabaseCLIError.self) {
        try parser.parse(["mutate", "sql", "DELETE FROM Person", "--page-size", "10"])
    }
    #expect(throws: DatabaseCLIError.self) {
        try parser.parse(["entity", "insert", "Person", idValue, objectValue, "--parameter", "$1=int64:1"])
    }
    #expect(throws: DatabaseCLIError.self) {
        try parser.parse(["migration", "run", "--page-size", "10"])
    }
    #expect(throws: DatabaseCLIError.self) {
        try parser.parse(["job", "wait", uuid, "queryExecute", "query", "--base", baseID, "--as-job", "query"])
    }
    #expect(throws: DatabaseCLIError.self) {
        try parser.parse(["profile", "list", "--profile", "local"])
    }
}

@Test("Entity preconditions are mutually exclusive")
func rejectsConflictingEntityPreconditions() {
    let base = ["entity", "delete", "Person", idValue]
    let combinations = [
        ["--expected-version", "1", "--must-exist"],
        ["--expected-version", "1", "--must-not-exist"],
        ["--must-exist", "--must-not-exist"],
    ]

    for combination in combinations {
        #expect(throws: DatabaseCLIError.self) {
            try CommandParser().parse(base + combination)
        }
    }
}

@Test("A leading meta-command backslash survives shell lexing")
func preservesMetaCommand() throws {
    #expect(try ShellLexer().parse(#"\profile staging"#) == ["\\profile", "staging"])
}

@Test("Repeatable scalar parameters and canonical JSON parameters are exclusive")
func parameterInputContractsAreCatalogDriven() throws {
    let command = try CommandParser().parse([
        "query", "sql", "SELECT $1, $2",
        "--base", baseID,
        "--parameter", "$1=int64:42",
        "--parameter", "$2=string:alice",
    ])
    #expect(
        command.options.values("parameter")
            == ["$1=int64:42", "$2=string:alice"]
    )
    #expect(throws: DatabaseCLIError.self) {
        try CommandParser().parse([
            "query", "sql", "SELECT $1",
            "--base", baseID,
            "--parameter", "$1=int64:42",
            "--parameters", #"{"$1":{"$type":"int64","value":"42"}}"#,
        ])
    }
}

@Test("Required command options are reported before wire construction")
func requiredOptionsAreValidatedByCatalog() throws {
    #expect(throws: DatabaseCLIError.self) {
        try CommandParser().parse(["graph", "shortest-path"])
    }
    #expect(throws: DatabaseCLIError.self) {
        try CommandParser().parse(["shacl", "validate", "urn:shapes"])
    }
    #expect(throws: DatabaseCLIError.self) {
        try CommandParser().parse(["schema", "apply", schemaJSON])
    }
    #expect(throws: DatabaseCLIError.self) {
        try CommandParser().parse(["serve", "database.sqlite"])
    }
    #expect(throws: DatabaseCLIError.self) {
        try CommandParser().parse(["query", "sql", "SELECT 1"])
    }
    #expect(throws: Never.self) {
        try CommandParser().parse([
            "query", "sql", "SELECT 1", "--base", baseID,
        ])
    }
    #expect(throws: DatabaseCLIError.self) {
        try CommandParser().parse([
            "query", "sql", "SELECT 1",
            "--base", baseID,
            "--composition", compositionID,
        ])
    }
    #expect(throws: Never.self) {
        try CommandParser().parse(["grant", "effective", "--database-target"])
    }
    #expect(throws: DatabaseCLIError.self) {
        try CommandParser().parse([
            "grant", "effective", "--database-target", "--principal", "alice",
        ])
    }
    let parser = CommandParser()
    let postgreSQL = try StandaloneStorageSelection.resolve(
        parser.parse([
            "open", "--storage", "postgresql",
            "--postgres-host", "db.test",
            "--postgres-port", "5433",
            "--postgres-user", "database",
            "--postgres-database", "database",
            "--domain-namespace", "applications",
            "--domain-namespace", "main",
        ])
    )
    #expect(postgreSQL.serverArguments.contains("postgresql"))
    #expect(postgreSQL.serverArguments.contains("5433"))
    #expect(postgreSQL.serverArguments.suffix(4) == [
        "--domain-namespace", "applications", "--domain-namespace", "main",
    ])

    let foundationDB = try StandaloneStorageSelection.resolve(
        parser.parse([
            "open", "--storage", "foundationdb",
            "--fdb-cluster-file", "/tmp/fdb.cluster",
            "--fdb-directory", "applications",
            "--fdb-directory", "main",
        ])
    )
    #expect(foundationDB.serverArguments.contains("foundationdb"))
    #expect(foundationDB.serverArguments.contains("/tmp/fdb.cluster"))
    #expect(foundationDB.serverArguments.suffix(4) == [
        "--fdb-directory", "applications", "--fdb-directory", "main",
    ])

    #expect(throws: DatabaseCLIError.self) {
        try StandaloneStorageSelection.resolve(
            parser.parse([
                "open", "--storage", "postgresql", "db.sqlite",
                "--domain-namespace", "main",
            ])
        )
    }
    #expect(throws: DatabaseCLIError.self) {
        try StandaloneStorageSelection.resolve(
            parser.parse(["open", "--storage", "foundationdb"])
        )
    }
    #expect(throws: DatabaseCLIError.self) {
        try StandaloneStorageSelection.resolve(
            parser.parse([
                "open", "--storage", "foundationdb",
                "--fdb-cluster-file", "/tmp/fdb.cluster",
            ])
        )
    }
}

@Test("Listener syntax preserves host and port without inference")
func parsesListenerAddress() throws {
    let application = DatabaseCLIApplication(output: .discardedForTests)
    let ipv4 = try application.parseListener("127.0.0.1:7878")
    #expect(ipv4.host == "127.0.0.1")
    #expect(ipv4.port == 7_878)
    let ipv6 = try application.parseListener("[::1]:7878")
    #expect(ipv6.host == "::1")
    #expect(ipv6.port == 7_878)
    #expect(throws: DatabaseCLIError.self) {
        try application.parseListener("127.0.0.1")
    }
}

private extension OutputWriter {
    static var discardedForTests: OutputWriter {
        OutputWriter(
            resultHandle: .nullDevice,
            diagnosticHandle: .nullDevice
        )
    }
}
#endif
