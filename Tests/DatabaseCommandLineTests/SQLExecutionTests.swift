import DatabaseClient
import DatabaseKit
import DatabaseTypes
import DatabaseWire
import Foundation
import Synchronization
import Testing
@testable import DatabaseCommandLine

@Suite("Complete SQL command contracts")
struct SQLExecutionTests {
    @Test("Complete SQL shares shell parsing and exposes only complete-request options")
    func commandContract() throws {
        let arguments = sqlArguments(["sql", "execute", "SELECT 1; SHOW ALL", "--output", "json"])
        let command = try CommandParser().parse(arguments)
        #expect(command.path == ["sql", "execute"])
        #expect(try CommandParser().parse(ShellLexer().parse(ShellLexer().join(arguments))) == command)
        let descriptor = try #require(CommandCatalog.standard.command(for: command.path))
        #expect(descriptor.capability == "query.execute")
        for option in ["page-size", "continuation", "all", "as-job", "graph-partitions"] {
            #expect(descriptor.option(named: option) == nil)
            #expect(throws: DatabaseCLIError.self) {
                try CommandParser().parse(arguments + ["--" + option, "1"])
            }
        }
        let completion = ShellCompletionSnapshot(catalog: .standard, profileNames: [])
        #expect(completion.values(in: "sql execute --output ") == ["json", "jsonl"])
        #if DATABASE_CLI_MULTI_BASE
        #expect(throws: DatabaseCLIError.self) {
            try CommandParser().parse(["sql", "execute", "SELECT 1", "--composition", "read-only"])
        }
        #endif
    }

    @Test("Complete ordered results retain empty schemas duplicate columns counts and COPY bytes")
    func rendersOrderedResults() async throws {
        let response = try sqlResponse()
        let first = try #require(response.results.first)
        let (_, completeRows, _) = try await withSQLOutput { output in
            try ResultRenderer(output: output).renderQuery(first, format: .json)
        }
        #if DATABASE_CLI_MULTI_BASE
        #expect(completeRows.contains("\"$consistency\":null"))
        #endif
        for format in [OutputFormat.json, .jsonl] {
            let (_, stdout, stderr) = try await withSQLOutput { output in
                try ResultRenderer(output: output).renderCompleteQuery(response, format: format)
            }
            let events = try format == .json
                ? StrictJSONParser().parse(stdout).array(named: "results")
                : stdout.split(separator: "\n").map { try StrictJSONParser().parse(String($0)) }
            #expect(stderr.isEmpty)
            #expect(events.count == 5)
            let objects = try events.map(StrictJSONObject.init)
            #expect(try objects.map { try $0.required("index").string(named: "index") } == ["1", "2", "3", "4", "5"])
            #expect(try objects.map { try $0.required("kind").string(named: "kind") } == ["rows", "rows", "copy", "command", "command"])
            let columns = try objects[0].required("columns").array(named: "columns")
            #expect(try columns.map { try StrictJSONObject($0).required("name").string(named: "name") } == ["value", "value"])
            #expect(try objects[1].required("columns") == objects[0].required("columns"))
            #expect(try objects[1].required("rows").array(named: "rows").isEmpty)
            #expect(try objects[0].required("affectedRows") == .string("1"))
            let row = try StrictJSONObject(#require(objects[0].required("rows").array(named: "rows").first))
            let values = try row.required("values").array(named: "values").map {
                try QueryValueJSONDecoder().decode(StrictJSONWriter.encode($0))
            }
            #expect(try values == sqlRow().values)
            #expect(try FieldValueJSONDecoder().decode(StrictJSONWriter.encode(objects[2].required("bytes"))) == .bytes(ByteString([0, 255, 10])))
            #expect(try objects[3].required("command") == .string("update"))
            #expect(try objects[3].required("affectedRows") == .string("2"))
            #expect(try objects[4].required("command") == .string("rollback"))
            #expect(try objects[4].required("affectedRows") == .null)
        }
    }

    @Test("Complete Boolean and RDF outcomes preserve kinds and exact output accounting")
    func rendersGraphOutcomes() async throws {
        let quad = RDFQuad(subject: .iri(try RDFIRI("urn:s")),
            predicate: RDFPredicateIRI(try RDFIRI("urn:p")), object: .iri(try RDFIRI("urn:o")))
        #if DATABASE_CLI_MULTI_BASE
        let consistency = DatabaseReadConsistency.transactional(try DomainReadPoint(domainID: "render-test", position: .version(1)))
        let boolean = try QueryBooleanResult(value: true, provenance: nil, consistency: consistency)
        let graph = try RDFGraphPage(quads: [quad], provenance: nil, consistency: consistency)
        #else
        let boolean = true
        let graph = try RDFGraphPage(quads: [quad])
        #endif
        let response = try QueryExecuteOperation.Response(results: [.boolean(boolean), .rdfGraph(graph)])
        for format in [OutputFormat.json, .jsonl] {
            let (rendered, stdout, stderr) = try await withSQLOutput { output in
                try ResultRenderer(output: output).renderCompleteQuery(response, format: format)
            }
            #expect(rendered.elementCount == 2)
            #expect(rendered.byteCount == UInt64(stdout.utf8.count))
            #expect(stderr.isEmpty)
            let events = try format == .json
                ? StrictJSONParser().parse(stdout).array(named: "results")
                : stdout.split(separator: "\n").map { try StrictJSONParser().parse(String($0)) }
            let first = try StrictJSONObject(events[0])
            let second = try StrictJSONObject(events[1])
            #expect(try first.required("kind") == .string("boolean"))
            #expect(try first.required("value") == .bool(true))
            #expect(try second.required("kind") == .string("rdfGraph"))
            #expect(try second.required("quads").array(named: "quads").count == 1)
        }
    }

    @Test("Unsupported complete SQL output is rejected before sending a request")
    func invalidOutputDoesNotSend() async throws {
        let calls = Mutex(0)
        let transport = SQLCLITransport { _ in
            calls.withLock { $0 += 1 }
            throw DatabaseTransportError.unavailable("Unexpected send")
        }
        let command = try CommandParser().parse(sqlArguments(["sql", "execute", "SELECT 1", "--output", "table"]))
        _ = try await withSQLOutput { output in
            await #expect(throws: DatabaseCLIError.self) {
                try await RemoteCommandExecutor(session: sqlSession(transport), output: output).execute(command)
            }
        }
        #expect(calls.withLock { $0 } == 0)
    }

    @Test("SQL and parameter files are owned before the single complete call")
    func completeSQLFilesAreReadOnce() async throws {
        let directory = try sqlTemporaryDirectory()
        defer { removeSQLDirectory(directory) }
        let sqlURL = directory.appendingPathComponent("request.sql")
        let parameterURL = directory.appendingPathComponent("parameters.json")
        let sql = "BEGIN; SELECT $1; ROLLBACK;\n"
        try sql.write(to: sqlURL, atomically: false, encoding: .utf8)
        try sqlParameterJSON.write(to: parameterURL, atomically: false, encoding: .utf8)
        let calls = Mutex(0)
        let transport = SQLCLITransport { bytes in
            let decoded = try DatabaseWireDecoder().decodeRequest(DatabaseOperationCatalog.queryExecute, from: bytes)
            calls.withLock { $0 += 1 }
            #expect(decoded.request.input == .sql(sql))
            #expect(decoded.request.parameters == [sqlParameter])
            #expect(decoded.request.budget.maximumRows == 3)
            #expect(decoded.metadata.traceID == "file-request")
            try FileManager.default.removeItem(at: sqlURL)
            try FileManager.default.removeItem(at: parameterURL)
            return try DatabaseWireEncoder().encodeResponse(DatabaseOperationCatalog.queryExecute,
                requestID: decoded.requestID, response: .init(results: [.command(.rollback, affectedRows: nil)]))
        }
        let command = try CommandParser().parse(sqlArguments([
            "sql", "execute", "@" + sqlURL.path, "--parameters", "@" + parameterURL.path,
            "--maximum-rows", "3", "--trace-id", "file-request",
        ]))
        _ = try await withSQLOutput { output in
            try await RemoteCommandExecutor(session: sqlSession(transport), output: output).execute(command)
        }
        #expect(calls.withLock { $0 } == 1)
    }

    @Test("Query continuation reuses SQL and parameters after their files are removed")
    func queryFilesAreNotReopenedForPages() async throws {
        let directory = try sqlTemporaryDirectory()
        defer { removeSQLDirectory(directory) }
        let sqlURL = directory.appendingPathComponent("query.sql")
        let parameterURL = directory.appendingPathComponent("parameters.json")
        let sql = "SELECT $1"
        try sql.write(to: sqlURL, atomically: false, encoding: .utf8)
        try sqlParameterJSON.write(to: parameterURL, atomically: false, encoding: .utf8)
        let calls = Mutex(0)
        let token = ByteString([7, 0, 9])
        let columns = [try QueryColumn(number: 1, name: "value", type: .sql(.text), isNullable: true)]
        let transport = SQLCLITransport { bytes in
            let decoded = try DatabaseWireDecoder().decodeRequest(DatabaseOperationCatalog.queryExecute, from: bytes)
            let first = calls.withLock { value in value += 1; return value == 1 }
            #expect(decoded.request.input == .text(language: .sql, statement: sql))
            #expect(decoded.request.parameters == [sqlParameter])
            #expect(decoded.request.page?.continuation == (first ? nil : token))
            if first {
                try FileManager.default.removeItem(at: sqlURL)
                try FileManager.default.removeItem(at: parameterURL)
            }
            #if DATABASE_CLI_MULTI_BASE
            let page = try QueryRowPage(columns: columns, rows: [], continuation: first ? token : nil,
                provenance: nil, consistency: .transactional(DomainReadPoint(domainID: "sql-test", position: .version(1))))
            #else
            let page = try QueryRowPage(columns: columns, rows: [], continuation: first ? token : nil)
            #endif
            return try DatabaseWireEncoder().encodeResponse(DatabaseOperationCatalog.queryExecute,
                requestID: decoded.requestID, response: .rows(page))
        }
        let command = try CommandParser().parse(sqlArguments([
            "query", "sql", "@" + sqlURL.path, "--parameters", "@" + parameterURL.path,
            "--all", "--max-pages", "2", "--max-total-rows", "2", "--max-total-bytes", "100000", "--output", "jsonl",
        ]))
        _ = try await withSQLOutput { output in
            try await RemoteCommandExecutor(session: sqlSession(transport), output: output).execute(command)
        }
        #expect(calls.withLock { $0 } == 2)
    }

    @Test("Query continuation keeps the page limit its token was issued for")
    func queryContinuationKeepsPageLimit() async throws {
        let limits = Mutex<[UInt32]>([])
        let token = ByteString([7, 0, 9])
        let columns = [try QueryColumn(number: 1, name: "value", type: .sql(.text), isNullable: true)]
        let transport = SQLCLITransport { bytes in
            let decoded = try DatabaseWireDecoder().decodeRequest(DatabaseOperationCatalog.queryExecute, from: bytes)
            let requestedPage = try #require(decoded.request.page)
            let first = limits.withLock { value in value.append(requestedPage.limit); return value.count == 1 }
            #expect(decoded.request.page?.continuation == (first ? nil : token))
            let rows = (first ? ["a", "b"] : ["c"]).map { QueryRow(values: [.primitive(.string($0))]) }
            #if DATABASE_CLI_MULTI_BASE
            let page = try QueryRowPage(columns: columns, rows: rows, continuation: first ? token : nil,
                provenance: nil, consistency: .transactional(DomainReadPoint(domainID: "sql-test", position: .version(1))))
            #else
            let page = try QueryRowPage(columns: columns, rows: rows, continuation: first ? token : nil)
            #endif
            return try DatabaseWireEncoder().encodeResponse(DatabaseOperationCatalog.queryExecute,
                requestID: decoded.requestID, response: .rows(page))
        }
        let command = try CommandParser().parse(sqlArguments([
            "query", "sql", "SELECT value FROM items", "--page-size", "2",
            "--all", "--max-pages", "2", "--max-total-rows", "3", "--max-total-bytes", "100000", "--output", "jsonl",
        ]))
        _ = try await withSQLOutput { output in
            try await RemoteCommandExecutor(session: sqlSession(transport), output: output).execute(command)
        }
        #expect(limits.withLock { $0 } == [2, 2])
    }

    @Test("Typed SQL diagnostics reach stderr with stable exit codes and authoritative shutdown")
    func diagnosticIsPrintedWithoutSuccessOutput() async throws {
        let diagnostic = try SQLDiagnostic(sqlState: "23505", category: .constraint, message: "Duplicate key",
            position: 8, schema: "schema", table: "table", column: "column", constraint: "unique")
        let failure = try RemoteOperationError(category: .constraint, code: "sql_failure", message: "Failed",
            retryability: .never, sqlDiagnostic: diagnostic)
        let shutdowns = Mutex(0)
        let transport = SQLCLITransport { bytes in
            let envelope = try DatabaseWireDecoder().decodeRequestEnvelope(bytes)
            return try DatabaseWireEncoder().encodeFailure(requestID: envelope.requestID, operation: .queryExecute, error: failure)
        }
        let (status, stdout, stderr) = try await withSQLOutput { output in
            let app = DatabaseCLIApplication(credentials: CredentialResolver(store: SQLCredentialStore(), environment: [:]),
                output: output, sessionFactory: { _ in
                    RemoteSession(transport: AnyDatabaseTransport(transport) { _ in shutdowns.withLock { $0 += 1 } })
                })
            return await app.run(arguments: sqlArguments(["sql", "execute", "INSERT", "--endpoint", "https://sql.test"]))
        }
        #expect(status == DatabaseCLIExitCode.conflict.rawValue)
        #expect(stdout.isEmpty)
        #expect(shutdowns.withLock { $0 } == 1)
        #expect(stderr.hasPrefix("error: "))
        let object = try StrictJSONObject(StrictJSONParser().parse(String(stderr.dropFirst(7))))
        #expect(try object.required("sqlState") == .string("23505"))
        #expect(try object.required("position") == .string("8"))
        for (key, value) in [("schema", "schema"), ("table", "table"), ("column", "column"), ("constraint", "unique")] {
            #expect(try object.required(key) == .string(value))
        }
        #expect(!stderr.contains("sql-test-secret"))
    }

    @Test("Malformed reserved SQL diagnostics fail instead of falling back to a generic message")
    func malformedDiagnosticDoesNotDisappear() throws {
        let failure = RemoteOperationError(category: .invalidRequest, code: "bad", message: "generic",
            retryability: .never, details: try FieldObject([("sqlDiagnostic", .string("malformed"))]))
        let mapped = DatabaseCLIError.map(failure)
        #expect(mapped.exitCode == .internalFailure)
        #expect(mapped.message.contains("Invalid remote SQL diagnostic"))
    }

    @Test("Cancelled SQL calls are sent once and keep their typed cancellation")
    func cancelledSQLIsNotReplayed() async throws {
        let calls = Mutex(0)
        let transport = SQLCLITransport { _ in
            calls.withLock { $0 += 1 }
            throw DatabaseTransportError.cancelled
        }
        let command = try CommandParser().parse(sqlArguments(["sql", "execute", "UPDATE t SET v = 1"]))
        _ = try await withSQLOutput { output in
            await #expect(throws: DatabaseClientError.transport(.cancelled)) {
                try await RemoteCommandExecutor(session: sqlSession(transport), output: output).execute(command)
            }
        }
        #expect(calls.withLock { $0 } == 1)
    }
}

private func sqlArguments(_ arguments: [String]) -> [String] {
    #if DATABASE_CLI_MULTI_BASE
    arguments + ["--base", "sql-test"]
    #else
    arguments
    #endif
}

private let sqlParameter = QueryParameter(position: 1, value: .primitive(.null), type: .sql(.text))
private let sqlParameterJSON = #"[{"position":"1","value":{"$type":"null"},"type":{"kind":"sql","type":{"kind":"text"}}}]"#

private func sqlRow() throws -> QueryRow {
    QueryRow(values: [.numeric(try QueryNumericValue(value: ExactDecimal(coefficient: 123, scale: 2), displayScale: 4)), .primitive(.null)])
}

private func sqlResponse() throws -> QueryExecuteOperation.Response {
    let columns = [
        try QueryColumn(number: 1, name: "value", type: .sql(.decimal(precision: nil, scale: nil)), isNullable: false),
        try QueryColumn(number: 2, name: "value", type: .sql(.text), isNullable: true),
    ]
    return try .init(results: [
        .rows(try .init(columns: columns, rows: [sqlRow()], affectedRows: 1)),
        .rows(try .init(columns: columns, rows: [])),
        .copy(bytes: ByteString([0, 255, 10]), affectedRows: 1),
        .command(.update, affectedRows: 2), .command(.rollback, affectedRows: nil),
    ])
}

private struct SQLCLITransport: DatabaseTransport {
    let exchange: @Sendable (ByteString) async throws -> ByteString

    init(_ exchange: @escaping @Sendable (ByteString) async throws -> ByteString) { self.exchange = exchange }

    func send(_ request: ByteString) async throws(DatabaseTransportError) -> ByteString {
        do { return try await exchange(request) }
        catch let error as DatabaseTransportError { throw error }
        catch { throw .invalidResponse(String(describing: error)) }
    }
}

private func sqlSession(_ transport: SQLCLITransport) -> RemoteSession {
    RemoteSession(transport: AnyDatabaseTransport(transport) { _ in })
}

private struct SQLCredentialStore: CredentialStore {
    func read(profile: String) throws -> String? { "sql-test-secret" }
    func write(_ token: String, profile: String) throws {}
    func remove(profile: String) throws {}
}

private func sqlTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sql-cli-" + Foundation.UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    return directory
}

private func removeSQLDirectory(_ directory: URL) {
    do { try FileManager.default.removeItem(at: directory) }
    catch { Issue.record("SQL test cleanup failed: \(error)") }
}

private func withSQLOutput<Result>(
    _ body: (OutputWriter) async throws -> Result
) async throws -> (Result, String, String) {
    let directory = try sqlTemporaryDirectory()
    defer { removeSQLDirectory(directory) }
    let resultURL = directory.appendingPathComponent("stdout")
    let errorURL = directory.appendingPathComponent("stderr")
    guard FileManager.default.createFile(atPath: resultURL.path, contents: nil),
          FileManager.default.createFile(atPath: errorURL.path, contents: nil) else {
        throw DatabaseCLIError(.unavailable, "Could not create SQL test output")
    }
    let result = try FileHandle(forWritingTo: resultURL)
    let diagnostic = try FileHandle(forWritingTo: errorURL)
    defer {
        do { try result.close(); try diagnostic.close() }
        catch { Issue.record("SQL test output close failed: \(error)") }
    }
    let value = try await body(OutputWriter(resultHandle: result, diagnosticHandle: diagnostic))
    return (value, try String(contentsOf: resultURL, encoding: .utf8), try String(contentsOf: errorURL, encoding: .utf8))
}
