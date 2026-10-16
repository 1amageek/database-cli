import DatabaseKit
import DatabaseTypes
import DatabaseWire
import Foundation
import Testing
@testable import DatabaseCommandLine

@Suite("Typed query row rendering contracts")
struct QueryRowRenderingTests {
    @Test("Temporal row values retain tags, endpoint text, offsets and positional declarations")
    func temporalCellsAcrossFormats() throws {
        let time = try QueryTimeValue(microsecondsSinceMidnight: 86_400_000_000)
        let intervalType = DataType.interval(fields: .dayToSecond, precision: 3)
        let values: [QueryValue] = [
            .time(time), .timeWithTimeZone(QueryTimeWithTimeZoneValue(time: time, utcOffsetSeconds: .min)),
            .dateInfinity(.negative), .timestampInfinity(.positive, withTimeZone: false),
            .timestampInfinity(.negative, withTimeZone: true), .intervalInfinity(.positive), .primitive(.null),
        ]
        let types: [DataType] = [
            .time(withTimeZone: false, precision: 6), .time(withTimeZone: true, precision: 6), .date,
            .timestamp(withTimeZone: false, precision: nil), .timestamp(withTimeZone: true, precision: nil),
            intervalType, intervalType,
        ]
        let columns = try types.enumerated().map { index, type in
            try QueryColumn(number: UInt32(index + 1), name: "value", type: .sql(type), isNullable: index == 6)
        }
        let page = try queryPage(columns: columns, rows: [QueryRow(values: values)])
        for format in [OutputFormat.json, .jsonl] {
            let (rendered, text) = try withQueryOutput { output in
                try ResultRenderer(output: output).renderQuery(.rows(page), format: format)
            }
            let (actualColumns, rows) = try rowEvents(text, format: format)
            try expectColumns(actualColumns, equalTo: columns)
            #expect(try decodedCells(StrictJSONObject(#require(rows.first))) == values)
            #expect(rendered.elementCount == 1)
            #expect(rendered.byteCount == UInt64(text.utf8.count))
        }
        let cells = ["24:00:00.000000", "24:00:00.000000-596523:14:08", "-infinity", "infinity", "-infinity", "infinity", #"{"$type":"null"}"#]
        for format in [OutputFormat.table, .csv] {
            let (rendered, text) = try withQueryOutput { output in
                try ResultRenderer(output: output).renderQuery(.rows(page), format: format)
            }
            let separator = format == .table ? "\t" : ","
            let displayed = format == .table ? cells : cells.map { value in
                value.contains("\"") ? "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : value
            }
            #expect(text == Array(repeating: "value", count: values.count).joined(separator: separator)
                + "\n" + displayed.joined(separator: separator) + "\n")
            #expect(rendered.elementCount == 1)
            #expect(rendered.byteCount == UInt64(text.utf8.count))
        }
    }

    @Test("JSON and JSONL retain duplicate column names and positional cells")
    func duplicateColumnsAndPositionalCells() throws {
        let columns = try duplicateColumns()
        let row = QueryRow(values: [.primitive(.int32(7)), .primitive(.string("Ada"))],
                           version: ByteString([1, 2, 3]))
        let page = try queryPage(columns: columns, rows: [row])
        for format in [OutputFormat.json, .jsonl] {
            let (rendered, text) = try withQueryOutput { output in
                try ResultRenderer(output: output).renderQuery(.rows(page), format: format)
            }
            #expect(rendered.elementCount == 1)
            #expect(rendered.byteCount == UInt64(text.utf8.count))
            let (actualColumns, rows) = try rowEvents(text, format: format)
            try expectColumns(actualColumns, equalTo: columns)
            #expect(rows.count == 1)
            let event = try StrictJSONObject(#require(rows.first))
            #expect(try event.required("$type").string(named: "$type") == "row")
            #expect(try event.required("$version").string(named: "$version") == "AQID")
            #expect(try decodedCells(event) == row.values)
        }
    }

    @Test("Empty JSON and JSONL pages retain typed nullable column declarations")
    func emptyPageRetainsTypes() throws {
        let columns = [
            try QueryColumn(number: 1, name: "amount", type: .sql(.decimal(precision: 12, scale: 4)), isNullable: true),
            try QueryColumn(number: 2, name: "items", type: .sql(.array(.integer)), isNullable: false),
            try QueryColumn(number: 3, name: "elapsed", type: .sql(.interval(fields: .dayToSecond, precision: 3)), isNullable: true),
        ]
        let page = try queryPage(columns: columns, rows: [])
        for format in [OutputFormat.json, .jsonl] {
            let (rendered, text) = try withQueryOutput { output in
                try ResultRenderer(output: output).renderQuery(.rows(page), format: format)
            }
            #expect(rendered.elementCount == 0)
            let (actualColumns, rows) = try rowEvents(text, format: format)
            try expectColumns(actualColumns, equalTo: columns)
            #expect(rows.isEmpty)
            #expect(!text.contains("\"$type\":\"row\""))
        }
    }

    @Test("Rich row cells retain numeric display scale, lexical JSON, and NULL identity")
    func richCellsRemainTyped() throws {
        let limits = QueryValueLimits(maximumRetainedBytes: 4096, maximumTotalNodes: 100,
                                      maximumNestingDepth: 16, maximumCollectionElements: 100)
        let values: [QueryValue] = [
            .numeric(try QueryNumericValue(value: ExactDecimal(coefficient: 123, scale: 2), displayScale: 4)),
            .json(try QueryJSONValue(bytes: ByteString(utf8: " {\"a\":1,\"a\":2} "), limits: limits)),
            .primitive(.null),
        ]
        let columns = [
            try QueryColumn(number: 1, name: "value", type: .sql(.decimal(precision: 12, scale: 4)), isNullable: false),
            try QueryColumn(number: 2, name: "value", type: .sql(.json), isNullable: false),
            try QueryColumn(number: 3, name: "value", type: .sql(.integer), isNullable: true),
        ]
        let page = try queryPage(columns: columns, rows: [QueryRow(values: values)])
        for format in [OutputFormat.json, .jsonl] {
            let (_, text) = try withQueryOutput { output in
                try ResultRenderer(output: output).renderQuery(.rows(page), format: format)
            }
            let (actualColumns, rows) = try rowEvents(text, format: format)
            try expectColumns(actualColumns, equalTo: columns)
            #expect(try decodedCells(StrictJSONObject(#require(rows.first))) == values)
        }
    }

    @Test("Multi-page JSON remains one valid collection when the first page is empty")
    func emptyFirstPageFraming() throws {
        let columns = try duplicateColumns()
        let continuation = ByteString([9, 8])
        let pages = [
            try queryPage(columns: columns, rows: [], continuation: continuation),
            try queryPage(columns: columns, rows: [QueryRow(values: [.primitive(.int32(1)), .primitive(.string("first"))])], continuation: continuation),
            try queryPage(columns: columns, rows: [QueryRow(values: [.primitive(.int32(2)), .primitive(.string("last"))])]),
        ]
        let (rendered, text) = try withQueryOutput { output in
            let renderer = ResultRenderer(output: output)
            var result: [RenderedPage] = []
            for (index, page) in pages.enumerated() {
                result.append(try renderer.renderQuery(.rows(page), format: .json,
                    jsonFraming: JSONPageFraming(opensCollection: index == 0,
                                                 closesCollection: index == pages.count - 1,
                                                 hasPriorElements: index > 1,
                                                 hasPriorPages: index > 0)))
            }
            return result
        }
        let objects = try StrictJSONParser().parse(text).array(named: "pages")
        try #require(objects.count == 3)
        #expect(rendered.map(\.elementCount) == [0, 1, 1])
        #expect(rendered.map(\.continuation) == [continuation, continuation, nil])
        #expect(rendered.reduce(UInt64(0)) { $0 + $1.byteCount } == UInt64(text.utf8.count))
        for (index, node) in objects.enumerated() {
            let object = try StrictJSONObject(node)
            try expectColumns(object.required("columns").array(named: "columns"), equalTo: columns)
            let rows = try object.required("rows").array(named: "rows")
            #expect(rows.count == (index == 0 ? 0 : 1))
            if index > 0 {
                let expected = try #require(pages[index].materializedRows(maximumCount: 1).first)
                #expect(try decodedCells(StrictJSONObject(#require(rows.first))) == expected.values)
            }
            #if DATABASE_CLI_MULTI_BASE
            _ = try object.required("$consistency")
            #else
            #expect(try object.required("$snapshotVersion") == .string("42"))
            #endif
        }
    }

    @Test("Table and CSV retain duplicate headers and positional cell order")
    func textFormatsPreservePositions() throws {
        let page = try queryPage(columns: duplicateColumns(), rows: [
            QueryRow(values: [.primitive(.int32(7)), .primitive(.string("Ada"))]),
        ])
        for format in [OutputFormat.table, .csv] {
            let (rendered, text) = try withQueryOutput { output in
                try ResultRenderer(output: output).renderQuery(.rows(page), format: format)
            }
            let lines = text.split(separator: "\n")
            #expect(rendered.elementCount == 1)
            try #require(lines.count == 2)
            #expect(lines[0] == (format == .table ? "value\tvalue" : "value,value"))
            let firstPosition = try #require(lines[1].range(of: "7")).lowerBound
            let secondPosition = try #require(lines[1].range(of: "Ada")).lowerBound
            #expect(firstPosition < secondPosition)
        }
    }

    @Test("A shared row quota fails without reporting a completed page")
    func rowQuotaFailure() throws {
        let page = try queryPage(columns: duplicateColumns(), rows: [
            QueryRow(values: [.primitive(.int32(1)), .primitive(.string("accepted"))]),
            QueryRow(values: [.primitive(.int32(2)), .primitive(.string("rejected"))]),
        ])
        let (_, text) = try withQueryOutput { output in
            let renderer = ResultRenderer(output: output, maximumElements: 1)
            do {
                _ = try renderer.renderQuery(.rows(page), format: .json)
                Issue.record("Row quota exhaustion returned a successful page")
            } catch let error as DatabaseCLIError {
                #expect(error.exitCode == .resourceLimit)
            }
        }
        #expect(text.contains("accepted"))
        #expect(!text.contains("rejected"))
        #expect(!text.contains("$continuation"))
        #expect(!text.hasSuffix("]\n"))
    }

    @Test("Output byte quota rejects a page before any oversized write succeeds")
    func byteQuotaFailure() throws {
        let page = try queryPage(columns: duplicateColumns(), rows: [])
        let (_, text) = try withQueryOutput { output in
            do {
                _ = try ResultRenderer(output: output.limitingResultBytes(to: 1))
                    .renderQuery(.rows(page), format: .json)
                Issue.record("Byte quota exhaustion returned a successful page")
            } catch let error as DatabaseCLIError {
                #expect(error.exitCode == .resourceLimit)
            }
        }
        #expect(text.isEmpty)
    }
}

private func duplicateColumns() throws -> [QueryColumn] {
    [try QueryColumn(number: 1, name: "value", type: .sql(.integer), isNullable: false),
     try QueryColumn(number: 2, name: "value", type: .sql(.text), isNullable: false)]
}

private func queryPage(columns: [QueryColumn], rows: [QueryRow], continuation: ByteString? = nil) throws -> QueryRowPage {
    #if DATABASE_CLI_MULTI_BASE
    try QueryRowPage(columns: columns, rows: rows, continuation: continuation, provenance: nil,
                     consistency: .transactional(DomainReadPoint(domainID: "primary", position: .version(42))))
    #else
    try QueryRowPage(columns: columns, rows: rows, continuation: continuation, snapshotVersion: 42)
    #endif
}

private func withQueryOutput<Result>(_ body: (OutputWriter) throws -> Result) throws -> (Result, String) {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("query-row-rendering-\(Foundation.UUID().uuidString)")
    guard FileManager.default.createFile(atPath: path.path, contents: nil) else {
        throw DatabaseCLIError(.unavailable, "Could not create isolated test output")
    }
    defer {
        do { try FileManager.default.removeItem(at: path) }
        catch { Issue.record("Temporary query output cleanup failed: \(error)") }
    }
    let handle = try FileHandle(forWritingTo: path)
    var closed = false
    defer {
        if !closed {
            do { try handle.close() }
            catch { Issue.record("Temporary query output close failed: \(error)") }
        }
    }
    let result = try body(OutputWriter(resultHandle: handle, diagnosticHandle: .nullDevice))
    try handle.close()
    closed = true
    return (result, try String(contentsOf: path, encoding: .utf8))
}

private func rowEvents(_ text: String, format: OutputFormat) throws -> ([StrictJSONValue], [StrictJSONValue]) {
    if format == .json {
        let pages = try StrictJSONParser().parse(text).array(named: "pages")
        #expect(pages.count == 1)
        let page = try StrictJSONObject(#require(pages.first))
        return (try page.required("columns").array(named: "columns"),
                try page.required("rows").array(named: "rows"))
    }
    let events = try text.split(separator: "\n").map { try StrictJSONParser().parse(String($0)) }
    let first = try StrictJSONObject(#require(events.first))
    #expect(try first.required("$type").string(named: "$type") == "columns")
    let rows = try events.dropFirst().filter { node in
        try StrictJSONObject(node).optional("$type") == .string("row")
    }
    return (try first.required("columns").array(named: "columns"), rows)
}

private func decodedCells(_ row: StrictJSONObject) throws -> [QueryValue] {
    try row.required("values").array(named: "values").map {
        try QueryValueJSONDecoder().decode(StrictJSONWriter.encode($0))
    }
}

private func expectColumns(_ nodes: [StrictJSONValue], equalTo columns: [QueryColumn]) throws {
    #expect(nodes.count == columns.count)
    for (node, column) in zip(nodes, columns) {
        let object = try StrictJSONObject(node)
        #expect(try object.required("number").string(named: "number") == String(column.number))
        #expect(try object.required("name").string(named: "name") == column.name)
        #expect(try object.required("isNullable").bool(named: "isNullable") == column.isNullable)
        #expect(try QueryColumnJSONCodec.type(object.required("type")) == column.type)
    }
}
