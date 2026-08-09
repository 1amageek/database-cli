import Foundation
import Testing
@testable import DatabaseCommandLine

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
    .init(arguments: ["query", "sql", "SELECT 1"], path: ["query", "sql"]),
    .init(arguments: ["query", "sparql", "SELECT * WHERE {}"], path: ["query", "sparql"]),
    .init(arguments: ["mutate", "sql", "DELETE FROM Person"], path: ["mutate", "sql"]),
    .init(arguments: ["mutate", "sparql", "CLEAR DEFAULT"], path: ["mutate", "sparql"]),
    .init(arguments: ["entity", "insert", "Person", idValue, objectValue], path: ["entity", "insert"]),
    .init(arguments: ["entity", "update", "Person", idValue, objectValue], path: ["entity", "update"]),
    .init(arguments: ["entity", "upsert", "Person", idValue, objectValue], path: ["entity", "upsert"]),
    .init(arguments: ["entity", "delete", "Person", idValue], path: ["entity", "delete"]),
    .init(arguments: ["entity", "apply", "[]"], path: ["entity", "apply"]),
    .init(arguments: ["graph", "shortest-path", "--index", "graph"], path: ["graph", "shortest-path"]),
    .init(arguments: ["graph", "weighted-shortest-path", "--index", "graph"], path: ["graph", "weighted-shortest-path"]),
    .init(arguments: ["graph", "page-rank", "--index", "graph"], path: ["graph", "page-rank"]),
    .init(arguments: ["graph", "community", "--index", "graph"], path: ["graph", "community"]),
    .init(arguments: ["graph", "cycles", "--index", "graph"], path: ["graph", "cycles"]),
    .init(arguments: ["graph", "strongly-connected-components", "--index", "graph"], path: ["graph", "strongly-connected-components"]),
    .init(arguments: ["graph", "topological-sort", "--index", "graph"], path: ["graph", "topological-sort"]),
    .init(arguments: ["ontology", "describe", "world"], path: ["ontology", "describe"]),
    .init(arguments: ["ontology", "upsert", objectValue], path: ["ontology", "upsert"]),
    .init(arguments: ["ontology", "delete", "world"], path: ["ontology", "delete"]),
    .init(arguments: ["ontology", "reason", "world"], path: ["ontology", "reason"]),
    .init(arguments: ["ontology", "hierarchy", "world", "urn:Class"], path: ["ontology", "hierarchy"]),
    .init(arguments: ["ontology", "validate-schema", "world"], path: ["ontology", "validate-schema"]),
    .init(arguments: ["shacl", "describe", "urn:shapes"], path: ["shacl", "describe"]),
    .init(arguments: ["shacl", "upsert", "urn:shapes", "<urn:s> <urn:p> <urn:o> ."], path: ["shacl", "upsert"]),
    .init(arguments: ["shacl", "delete", "urn:shapes"], path: ["shacl", "delete"]),
    .init(arguments: ["shacl", "validate", "urn:shapes", "--entity", "Person", "--index", "byName"], path: ["shacl", "validate"]),
    .init(arguments: ["command", "run", "system.inspect", objectValue], path: ["command", "run"]),
    .init(arguments: ["migration", "status"], path: ["migration", "status"]),
    .init(arguments: ["migration", "run"], path: ["migration", "run"]),
    .init(arguments: ["index", "status"], path: ["index", "status"]),
    .init(arguments: ["index", "rebuild", "Person", "byName"], path: ["index", "rebuild"]),
    .init(arguments: ["maintenance", "compact"], path: ["maintenance", "compact"]),
    .init(arguments: ["job", "status", uuid, "queryExecute", "query"], path: ["job", "status"]),
    .init(arguments: ["job", "wait", uuid, "queryExecute", "query"], path: ["job", "wait"]),
    .init(arguments: ["job", "result", uuid, "queryExecute", "query"], path: ["job", "result"]),
    .init(arguments: ["job", "cancel", uuid, "queryExecute", "query"], path: ["job", "cancel"]),
    .init(arguments: ["shell"], path: ["shell"]),
    .init(arguments: ["inspect", "overview"], path: ["inspect", "overview"]),
    .init(arguments: ["inspect", "entities"], path: ["inspect", "entities"]),
    .init(arguments: ["inspect", "indexes"], path: ["inspect", "indexes"]),
    .init(arguments: ["inspect", "graph"], path: ["inspect", "graph"]),
    .init(arguments: ["inspect", "ontology", "world"], path: ["inspect", "ontology"]),
    .init(arguments: ["inspect", "shapes", "urn:shapes"], path: ["inspect", "shapes"]),
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
private let objectValue = #"{"$type":"object","value":{}}"#
private let uuid = "00000000-0000-0000-0000-000000000001"
private let schemaJSON = #"{"formatVersion":1,"schemaVersion":{"major":1,"minor":0,"patch":0},"entities":[]}"#
private let emptyFingerprint = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"

@Test("Every public command parses", arguments: commandFixtures)
private func parsesEveryCommand(_ fixture: CommandFixture) throws {
    #expect(try CommandParser().parse(fixture.arguments).path == fixture.path)
}

@Test("One-shot and shell tokenization produce the same AST")
func shellAndOneShotShareAST() throws {
    let line = #"query sql "SELECT * FROM Person" --page-size 25 --output jsonl"#
    let tokens = try ShellLexer().parse(line)
    let shellAST = try CommandParser().parse(tokens)
    let oneShotAST = try CommandParser().parse([
        "query", "sql", "SELECT * FROM Person",
        "--page-size", "25", "--output", "jsonl",
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
        try CommandParser().parse(["query", "sql", "SELECT 1", "--all"])
    }
    #expect(throws: Never.self) {
        try CommandParser().parse([
            "query", "sql", "SELECT 1", "--all",
            "--max-total-rows", "10",
            "--max-total-bytes", "4096",
            "--max-pages", "2",
        ])
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
    let parser = CommandParser()
    let postgreSQL = try StandaloneStorageSelection.resolve(
        parser.parse([
            "open", "--storage", "postgresql",
            "--postgres-host", "db.test",
            "--postgres-port", "5433",
            "--postgres-user", "database",
            "--postgres-database", "database",
        ])
    )
    #expect(postgreSQL.serverArguments.contains("postgresql"))
    #expect(postgreSQL.serverArguments.contains("5433"))

    let foundationDB = try StandaloneStorageSelection.resolve(
        parser.parse([
            "open", "--storage", "foundationdb",
            "--fdb-cluster-file", "/tmp/fdb.cluster",
        ])
    )
    #expect(foundationDB.serverArguments.contains("foundationdb"))
    #expect(foundationDB.serverArguments.contains("/tmp/fdb.cluster"))

    #expect(throws: DatabaseCLIError.self) {
        try StandaloneStorageSelection.resolve(
            parser.parse(["open", "--storage", "postgresql", "db.sqlite"])
        )
    }
    #expect(throws: DatabaseCLIError.self) {
        try StandaloneStorageSelection.resolve(
            parser.parse(["open", "--storage", "foundationdb"])
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
