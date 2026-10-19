import DatabaseKit
import DatabaseWire

extension ResultRenderer {
    func renderSQL(
        _ response: SQLExecuteOperation.Response,
        format: OutputFormat
    ) throws {
        guard format == .json || format == .jsonl else {
            throw DatabaseCLIError(.input, "Complete SQL results require JSON or JSONL output")
        }
        if format == .json { _ = try output.result("[") }
        for (offset, result) in response.results.enumerated() {
            if format == .json, offset > 0 { _ = try output.result(",") }
            let prefix: [(key: String, value: StrictJSONValue)] = [
                ("index", .string(String(offset + 1))),
            ]
            switch result {
            case .rows(let rows):
                let metadata = StrictJSONWriter.encode(.object(prefix + [
                    ("kind", .string("rows")),
                    ("columns", .array(try rows.columns.map(QueryColumnJSONCodec.node))),
                    ("rowCount", .string(String(rows.rowCount))),
                    ("affectedRows", rows.affectedRows.map { .string(String($0)) } ?? .null),
                ]))
                _ = try output.result(String(metadata.dropLast()) + ",\"rows\":[")
                var iterator = rows.makeRowIterator()
                var emitted = false
                while let row = try iterator.next() {
                    try elementQuota?.reserveOne()
                    if emitted { _ = try output.result(",") }
                    _ = try output.result(rowJSON(row, provenance: nil))
                    emitted = true
                }
                _ = try output.result("]}")
            case .copy(let bytes, let affectedRows):
                _ = try output.result(StrictJSONWriter.encode(.object(prefix + [
                    ("kind", .string("copy")),
                    ("affectedRows", .string(String(affectedRows))),
                    ("bytes", try fieldEncoder.node(.bytes(bytes))),
                ])))
            case .command(let kind, let affectedRows):
                _ = try output.result(StrictJSONWriter.encode(.object(prefix + [
                    ("kind", .string("command")),
                    ("command", .string(sqlCommandName(kind))),
                    ("affectedRows", affectedRows.map { .string(String($0)) } ?? .null),
                ])))
            }
            if format == .jsonl { _ = try output.result("\n") }
        }
        if format == .json { _ = try output.result("]\n") }
    }

    private func sqlCommandName(_ kind: SQLCommandKind) -> String {
        switch kind {
        case .begin: "begin"
        case .commit: "commit"
        case .rollback: "rollback"
        case .set: "set"
        case .show: "show"
        case .reset: "reset"
        case .prepare: "prepare"
        case .execute: "execute"
        case .deallocate: "deallocate"
        case .explain: "explain"
        case .copy: "copy"
        case .createSchema: "createSchema"
        case .alterSchema: "alterSchema"
        case .dropSchema: "dropSchema"
        case .createTable: "createTable"
        case .alterTable: "alterTable"
        case .dropTable: "dropTable"
        case .createIndex: "createIndex"
        case .dropIndex: "dropIndex"
        case .createView: "createView"
        case .dropView: "dropView"
        case .createMaterializedView: "createMaterializedView"
        case .refreshMaterializedView: "refreshMaterializedView"
        case .dropMaterializedView: "dropMaterializedView"
        case .setConstraints: "setConstraints"
        case .createSequence: "createSequence"
        case .alterSequence: "alterSequence"
        case .dropSequence: "dropSequence"
        case .insert: "insert"
        case .update: "update"
        case .delete: "delete"
        case .merge: "merge"
        case .truncate: "truncate"
        case .savepoint: "savepoint"
        case .rollbackTo: "rollbackTo"
        case .release: "release"
        }
    }
}
