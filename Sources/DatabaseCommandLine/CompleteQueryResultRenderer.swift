import DatabaseKit
import DatabaseWire

extension ResultRenderer {
    @discardableResult
    func renderCompleteQuery(
        _ response: QueryExecuteOperation.Response,
        format: OutputFormat
    ) throws -> RenderedPage {
        guard format == .json || format == .jsonl else {
            throw DatabaseCLIError(.input, "Complete query results require JSON or JSONL output")
        }
        var emittedByteCount: UInt64 = 0
        var elements: UInt64 = 0
        if format == .json { emittedByteCount += UInt64(try output.result("[")) }
        for (offset, result) in response.results.enumerated() {
            if format == .json, offset > 0 { emittedByteCount += UInt64(try output.result(",")) }
            let prefix: [(key: String, value: StrictJSONValue)] = [
                ("index", .string(String(offset + 1))),
            ]
            switch result {
            case .rows(let rows):
                var fields = prefix + [
                    (key: "kind", value: StrictJSONValue.string("rows")),
                    ("columns", .array(try rows.columns.map(QueryColumnJSONCodec.node))),
                    ("rowCount", .string(String(rows.rowCount))),
                    ("affectedRows", rows.affectedRows.map { .string(String($0)) } ?? .null),
                ]
                if !rows.metadata.fields.isEmpty { fields.append(("metadata", try fieldEncoder.node(.object(rows.metadata)))) }
                #if DATABASE_CLI_MULTI_BASE
                if let consistency = rows.consistency { fields.append(("$consistency", consistencyNode(consistency))) }
                var origins = rows.provenance?.makeOriginIterator()
                #endif
                let metadata = StrictJSONWriter.encode(.object(fields))
                emittedByteCount += UInt64(try output.result(String(metadata.dropLast()) + ",\"rows\":["))
                var iterator = rows.makeRowIterator()
                var emitted = false
                while let row = try iterator.next() {
                    try elementQuota?.reserveOne()
                    if emitted { emittedByteCount += UInt64(try output.result(",")) }
                    #if DATABASE_CLI_MULTI_BASE
                    let origin = try rowProvenanceNode(rows.provenance, iterator: &origins)
                    #else
                    let origin: StrictJSONValue? = nil
                    #endif
                    emittedByteCount += UInt64(try output.result(rowJSON(row, provenance: origin)))
                    emitted = true
                    elements += 1
                }
                #if DATABASE_CLI_MULTI_BASE
                try requireOriginsExhausted(&origins)
                #endif
                emittedByteCount += UInt64(try output.result("]}"))
            case .copy(let bytes, let affectedRows):
                emittedByteCount += UInt64(try output.result(StrictJSONWriter.encode(.object(prefix + [
                    ("kind", .string("copy")),
                    ("affectedRows", .string(String(affectedRows))),
                    ("bytes", try fieldEncoder.node(.bytes(bytes))),
                ]))))
            case .boolean(let value):
                try elementQuota?.reserveOne()
                elements += 1
                var fields = prefix + [(key: "kind", value: StrictJSONValue.string("boolean")),
                    (key: "value", value: .bool(value.value))]
                #if DATABASE_CLI_MULTI_BASE
                fields.append(("$consistency", consistencyNode(value.consistency)))
                if let provenance = value.provenance {
                    var origins = provenance.makeOriginIterator()
                    guard let origin = try origins.next(), try origins.next() == nil else {
                        throw DatabaseCLIError(.internalFailure, "Boolean provenance is inconsistent")
                    }
                    fields.append(("$provenance", provenanceNode(provenance, origin: origin)))
                }
                #endif
                emittedByteCount += UInt64(try output.result(StrictJSONWriter.encode(.object(fields))))
            case .rdfGraph(let graph):
                var fields = prefix + [(key: "kind", value: StrictJSONValue.string("rdfGraph")),
                    (key: "quadCount", value: .string(String(graph.quadCount)))]
                #if DATABASE_CLI_MULTI_BASE
                fields.append(("$consistency", consistencyNode(graph.consistency)))
                var origins = graph.provenance?.makeOriginIterator()
                #else
                if let version = graph.snapshotVersion { fields.append(("$snapshotVersion", .string(String(version)))) }
                #endif
                let metadata = StrictJSONWriter.encode(.object(fields))
                emittedByteCount += UInt64(try output.result(String(metadata.dropLast()) + ",\"quads\":["))
                var quads = graph.makeQuadIterator()
                var first = true
                while let quad = try quads.next() {
                    try elementQuota?.reserveOne()
                    var fields: [(key: String, value: StrictJSONValue)] = [
                        ("subject", try fieldEncoder.node(.rdfTerm(quad.subject.term))),
                        ("predicate", try fieldEncoder.node(.rdfTerm(quad.predicate.term))),
                        ("object", try fieldEncoder.node(.rdfTerm(quad.object))),
                        ("graph", try quad.graph.map { try fieldEncoder.node(.rdfTerm($0.term)) } ?? .null)]
                    #if DATABASE_CLI_MULTI_BASE
                    if let origin = try rowProvenanceNode(graph.provenance, iterator: &origins) {
                        fields.append(("$provenance", origin))
                    }
                    #endif
                    if !first { emittedByteCount += UInt64(try output.result(",")) }
                    emittedByteCount += UInt64(try output.result(StrictJSONWriter.encode(.object(fields))))
                    first = false; elements += 1
                }
                #if DATABASE_CLI_MULTI_BASE
                try requireOriginsExhausted(&origins)
                #endif
                emittedByteCount += UInt64(try output.result("]}"))
            case .block:
                throw DatabaseCLIError(.internalFailure, "Nested query result blocks are invalid")
            case .command(let kind, let affectedRows):
                emittedByteCount += UInt64(try output.result(StrictJSONWriter.encode(.object(prefix + [
                    ("kind", .string("command")),
                    ("command", .string(sqlCommandName(kind))),
                    ("affectedRows", affectedRows.map { .string(String($0)) } ?? .null),
                ]))))
            }
            if format == .jsonl { emittedByteCount += UInt64(try output.result("\n")) }
        }
        if format == .json { emittedByteCount += UInt64(try output.result("]\n")) }
        return RenderedPage(elementCount: elements, byteCount: emittedByteCount, continuation: nil)
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
