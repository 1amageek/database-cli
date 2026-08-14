import Testing
@testable import DatabaseCommandLine

#if !DATABASE_CLI_MULTIPLE_BASES
private struct SingleDatabaseCommandFixture: Sendable {
    let arguments: [String]
    let path: [String]
}

private let singleDatabaseCommandFixtures: [SingleDatabaseCommandFixture] = [
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
    .init(arguments: ["schema", "apply", schemaJSON, "--expected-fingerprint", emptyFingerprint, "--idempotency-key", "schema-1"], path: ["schema", "apply"]),
    .init(arguments: ["query", "sql", "SELECT 1"], path: ["query", "sql"]),
    .init(arguments: ["query", "sparql", "SELECT * WHERE {}"], path: ["query", "sparql"]),
    .init(arguments: ["mutate", "sql", "DELETE FROM Person"], path: ["mutate", "sql"]),
    .init(arguments: ["mutate", "sparql", "CLEAR DEFAULT"], path: ["mutate", "sparql"]),
    .init(arguments: ["entity", "insert", "Person", idValue, objectValue], path: ["entity", "insert"]),
    .init(arguments: ["entity", "update", "Person", idValue, objectValue], path: ["entity", "update"]),
    .init(arguments: ["entity", "upsert", "Person", idValue, objectValue], path: ["entity", "upsert"]),
    .init(arguments: ["entity", "delete", "Person", idValue], path: ["entity", "delete"]),
    .init(arguments: ["entity", "apply", "[]"], path: ["entity", "apply"]),
    .init(arguments: ["graph", "shortest-path", "--index", "graph", "--source", stringValue, "--target", stringValue], path: ["graph", "shortest-path"]),
    .init(arguments: ["graph", "weighted-shortest-path", "--index", "graph", "--source", stringValue, "--target", stringValue, "--weight-property", "cost"], path: ["graph", "weighted-shortest-path"]),
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
    .init(arguments: ["serve", "database.sqlite", "--profile", "local"], path: ["serve"]),
    .init(arguments: ["fdb", "cluster", "status"], path: ["fdb"]),
]

private let idValue = #"{"$type":"string","value":"p1"}"#
private let stringValue = #"{"$type":"string","value":"node"}"#
private let objectValue = #"{"$type":"object","value":{}}"#
private let uuid = "00000000-0000-0000-0000-000000000001"
private let schemaJSON = #"{"formatVersion":1,"schemaVersion":{"major":1,"minor":0,"patch":0},"entities":[]}"#
private let emptyFingerprint = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"

@Test("Every single-database command parses", arguments: singleDatabaseCommandFixtures)
private func parsesEverySingleDatabaseCommand(
    _ fixture: SingleDatabaseCommandFixture
) throws {
    #expect(try CommandParser().parse(fixture.arguments).path == fixture.path)
}

@Test("Single-database fixtures cover every public command path")
func singleDatabaseParserFixturesCoverCatalog() {
    #expect(
        Set(singleDatabaseCommandFixtures.map(\.path))
            == Set(CommandCatalog.standard.commands.map(\.path))
    )
}

@Test("Single-database one-shot and shell parsing share one AST")
func singleDatabaseShellAndOneShotShareAST() throws {
    let line = #"query sql "SELECT * FROM Person" --page-size 25 --output jsonl"#
    let tokens = try ShellLexer().parse(line)
    let shellAST = try CommandParser().parse(tokens)
    let oneShotAST = try CommandParser().parse([
        "query", "sql", "SELECT * FROM Person",
        "--page-size", "25", "--output", "jsonl",
    ])
    #expect(shellAST == oneShotAST)
}

@Test("Single-database commands reject MultipleBases selectors")
func singleDatabaseRejectsMultipleBasesSelectors() {
    #expect(throws: DatabaseCLIError.self) {
        try CommandParser().parse([
            "query", "sql", "SELECT 1", "--base", "company-a",
        ])
    }
    #expect(throws: DatabaseCLIError.self) {
        try CommandParser().parse(["base", "list"])
    }
    #expect(throws: DatabaseCLIError.self) {
        try CommandParser().parse(["grant", "effective"])
    }
}

@Test("Single-database all-page mode requires explicit safety bounds")
func singleDatabaseAllRequiresBounds() {
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
#endif
