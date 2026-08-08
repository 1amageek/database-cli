import DatabaseKit
import DatabaseTypes
import DatabaseWire
import Foundation
import Synchronization

final class ResultElementQuota: Sendable {
    private let remaining: Mutex<UInt64>

    init(maximumElements: UInt64) {
        self.remaining = Mutex(maximumElements)
    }

    func reserveOne() throws {
        let accepted = remaining.withLock { remaining in
            guard remaining > 0 else { return false }
            remaining -= 1
            return true
        }
        guard accepted else {
            throw DatabaseCLIError(
                .resourceLimit,
                "Result output exceeds '--max-total-rows'"
            )
        }
    }
}

public struct RenderedPage: Sendable {
    public let elementCount: UInt64
    public let byteCount: UInt64
    public let continuation: ByteString?

    public init(
        elementCount: UInt64,
        byteCount: UInt64,
        continuation: ByteString?
    ) {
        self.elementCount = elementCount
        self.byteCount = byteCount
        self.continuation = continuation
    }
}

struct JSONPageFraming: Sendable {
    let opensCollection: Bool
    let closesCollection: Bool
    let hasPriorElements: Bool

    static let single = Self(
        opensCollection: true,
        closesCollection: true,
        hasPriorElements: false
    )
}

public struct ResultRenderer: Sendable {
    let output: OutputWriter
    let fieldEncoder: FieldValueJSONEncoder
    let elementQuota: ResultElementQuota?

    public init(output: OutputWriter, maximumElements: UInt64? = nil) {
        self.output = output
        self.fieldEncoder = FieldValueJSONEncoder()
        self.elementQuota = maximumElements.map(ResultElementQuota.init)
    }

    public func selectedFormat(_ requested: OutputFormat?) -> OutputFormat {
        requested ?? (output.standardOutputIsTTY ? .table : .jsonl)
    }

    func renderQuery(
        _ response: QueryExecuteOperation.Response,
        format: OutputFormat,
        jsonFraming: JSONPageFraming = .single
    ) throws -> RenderedPage {
        switch response {
        case .boolean(let value):
            try elementQuota?.reserveOne()
            guard format != .csv && format != .nquads else {
                throw DatabaseCLIError(.input, "Boolean results do not support \(format.rawValue) output")
            }
            let text = format == .json
                ? "{\"$type\":\"bool\",\"value\":\(value)}\n"
                : "\(value)\n"
            return RenderedPage(
                elementCount: 1,
                byteCount: UInt64(try output.result(text)),
                continuation: nil
            )
        case .rows(let page):
            return try renderRows(
                page,
                format: format,
                jsonFraming: jsonFraming
            )
        case .rdfGraph(let page):
            return try renderRDF(
                page,
                format: format,
                jsonFraming: jsonFraming
            )
        }
    }

    func renderRows(
        _ page: QueryRowPage,
        format: OutputFormat,
        jsonFraming: JSONPageFraming = .single
    ) throws -> RenderedPage {
        guard format != .nquads else {
            throw DatabaseCLIError(.input, "N-Quads output requires an RDF result")
        }
        var iterator = page.makeRowIterator()
        var count: UInt64 = 0
        var bytes: UInt64 = 0
        if format == .json, jsonFraming.opensCollection {
            bytes += UInt64(try output.result("["))
        } else if format == .table {
            bytes += UInt64(
                try output.result(
                    page.columns.map(\.name).joined(separator: "\t") + "\n"
                )
            )
        } else if format == .csv {
            bytes += UInt64(
                try output.result(
                    page.columns.map { csvEscape($0.name) }.joined(separator: ",") + "\n"
                )
            )
        }
        while let row = try iterator.next() {
            try elementQuota?.reserveOne()
            let encoded: String
            switch format {
            case .jsonl:
                encoded = try rowJSON(row, columns: page.columns) + "\n"
            case .json:
                encoded = (count == 0 && !jsonFraming.hasPriorElements ? "" : ",")
                    + (try rowJSON(row, columns: page.columns))
            case .table:
                encoded = try row.values.map(tableValue).joined(separator: "\t") + "\n"
            case .csv:
                encoded = try row.values.map(csvValue).joined(separator: ",") + "\n"
            case .nquads:
                throw DatabaseCLIError(
                    .internalFailure,
                    "N-Quads row rendering reached an invalid state"
                )
            }
            bytes += UInt64(try output.result(encoded))
            count += 1
        }
        if format == .json, jsonFraming.closesCollection {
            bytes += UInt64(try output.result("]\n"))
        }
        try renderPageMetadata(
            continuation: page.continuation,
            snapshotVersion: page.snapshotVersion.map(String.init),
            format: format,
            bytes: &bytes
        )
        return RenderedPage(
            elementCount: count,
            byteCount: bytes,
            continuation: page.continuation?.detached()
        )
    }

    func renderRDF(
        _ page: RDFGraphPage,
        format: OutputFormat,
        jsonFraming: JSONPageFraming = .single
    ) throws -> RenderedPage {
        guard format == .nquads || format == .jsonl || format == .json else {
            throw DatabaseCLIError(
                .input,
                "RDF results support only nquads, jsonl, or json output"
            )
        }
        let nquads = NQuadsEncoder()
        var iterator = page.makeQuadIterator()
        var count: UInt64 = 0
        var bytes: UInt64 = 0
        if format == .json, jsonFraming.opensCollection {
            bytes += UInt64(try output.result("["))
        }
        while let quad = try iterator.next() {
            try elementQuota?.reserveOne()
            let encoded: String
            if format == .nquads {
                encoded = try nquads.format(quad) + "\n"
            } else {
                let node = StrictJSONValue.object([
                    (
                        "subject",
                        try fieldEncoder.node(.rdfTerm(quad.subject.term))
                    ),
                    (
                        "predicate",
                        try fieldEncoder.node(.rdfTerm(quad.predicate.term))
                    ),
                    ("object", try fieldEncoder.node(.rdfTerm(quad.object))),
                    (
                        "graph",
                        try quad.graph.map {
                            try fieldEncoder.node(.rdfTerm($0.term))
                        } ?? .null
                    ),
                ])
                let json = StrictJSONWriter.encode(node)
                encoded = format == .json
                    ? (count == 0 && !jsonFraming.hasPriorElements ? "" : ",") + json
                    : json + "\n"
            }
            bytes += UInt64(try output.result(encoded))
            count += 1
        }
        if format == .json, jsonFraming.closesCollection {
            bytes += UInt64(try output.result("]\n"))
        }
        try renderPageMetadata(
            continuation: page.continuation,
            snapshotVersion: page.snapshotVersion.map(String.init),
            format: format,
            bytes: &bytes
        )
        return RenderedPage(
            elementCount: count,
            byteCount: bytes,
            continuation: page.continuation?.detached()
        )
    }

    func renderJSON(_ node: StrictJSONValue) throws -> UInt64 {
        UInt64(try output.result(StrictJSONWriter.encode(node) + "\n"))
    }

    private func rowJSON(
        _ row: QueryRow,
        columns: [QueryColumn]
    ) throws -> String {
        var fields: [(key: String, value: StrictJSONValue)] = []
        fields.reserveCapacity(columns.count + 2)
        for (column, value) in zip(columns, row.values) {
            fields.append((column.name, try fieldEncoder.node(value)))
        }
        if let version = row.version {
            fields.append(("$version", .string(Base64URL.encode(version))))
        }
        if !row.annotations.isEmpty {
            fields.append((
                "$annotations",
                try fieldEncoder.node(.object(row.annotations))
            ))
        }
        return StrictJSONWriter.encode(.object(fields))
    }

    private func tableValue(_ value: FieldValue) throws -> String {
        try fieldEncoder.encode(value)
            .replacingOccurrences(of: "\t", with: "\\t")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    private func csvValue(_ value: FieldValue) throws -> String {
        switch value {
        case .array, .object, .reference, .rdfTerm, .vector:
            throw DatabaseCLIError(.input, "CSV output supports scalar rows only")
        default:
            return csvEscape(try fieldEncoder.encode(value))
        }
    }

    private func csvEscape(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"")
            || value.contains("\n") || value.contains("\r") else {
            return value
        }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private func renderPageMetadata(
        continuation: ByteString?,
        snapshotVersion: String?,
        format: OutputFormat,
        bytes: inout UInt64
    ) throws {
        guard continuation != nil || snapshotVersion != nil else { return }
        let metadata = StrictJSONWriter.encode(
            .object([
                ("$continuation", continuation.map { .string(Base64URL.encode($0)) } ?? .null),
                ("$snapshotVersion", snapshotVersion.map(StrictJSONValue.string) ?? .null),
            ])
        )
        if format == .jsonl {
            bytes += UInt64(try output.result(metadata + "\n"))
        } else {
            output.diagnostic(metadata + "\n")
        }
    }

}
