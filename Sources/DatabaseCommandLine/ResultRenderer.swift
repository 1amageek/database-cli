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
        case .boolean(let result):
            try elementQuota?.reserveOne()
            guard format != .csv && format != .nquads else {
                throw DatabaseCLIError(.input, "Boolean results do not support \(format.rawValue) output")
            }
            let provenance = try result.provenance.map { provenance in
                var iterator = provenance.makeOriginIterator()
                guard let origin = try iterator.next(),
                      try iterator.next() == nil else {
                    throw DatabaseCLIError(
                        .internalFailure,
                        "Boolean result provenance is inconsistent"
                    )
                }
                return provenanceNode(provenance, origin: origin)
            }
            let text: String
            if format == .table, let provenance {
                text = "value\t$provenance\n\(result.value)\t\(tableJSON(provenance))\n"
            } else if format == .json || format == .jsonl {
                var fields: [(key: String, value: StrictJSONValue)] = [
                    ("$type", .string("bool")),
                    ("value", .bool(result.value)),
                ]
                if let provenance {
                    fields.append(("$provenance", provenance))
                }
                text = StrictJSONWriter.encode(.object(fields)) + "\n"
            } else {
                text = "\(result.value)\n"
            }
            var byteCount = UInt64(try output.result(text))
            try renderPageMetadata(
                continuation: nil,
                consistency: result.consistency,
                format: format,
                bytes: &byteCount
            )
            return RenderedPage(
                elementCount: 1,
                byteCount: byteCount,
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
        var originIterator = page.provenance?.makeOriginIterator()
        var count: UInt64 = 0
        var bytes: UInt64 = 0
        if format == .json, jsonFraming.opensCollection {
            bytes += UInt64(try output.result("["))
        } else if format == .table {
            var columns = page.columns.map(\.name)
            if page.provenance != nil { columns.append("$provenance") }
            bytes += UInt64(
                try output.result(
                    columns.joined(separator: "\t") + "\n"
                )
            )
        } else if format == .csv {
            var columns = page.columns.map { csvEscape($0.name) }
            if page.provenance != nil { columns.append("$provenance") }
            bytes += UInt64(
                try output.result(
                    columns.joined(separator: ",") + "\n"
                )
            )
        }
        while let row = try iterator.next() {
            try elementQuota?.reserveOne()
            let provenanceNode = try rowProvenanceNode(
                page.provenance,
                iterator: &originIterator
            )
            let encoded: String
            switch format {
            case .jsonl:
                encoded = try rowJSON(
                    row,
                    columns: page.columns,
                    provenance: provenanceNode
                ) + "\n"
            case .json:
                encoded = (count == 0 && !jsonFraming.hasPriorElements ? "" : ",")
                    + (try rowJSON(
                        row,
                        columns: page.columns,
                        provenance: provenanceNode
                    ))
            case .table:
                var values = try row.values.map(tableValue)
                if let provenanceNode {
                    values.append(tableJSON(provenanceNode))
                }
                encoded = values.joined(separator: "\t") + "\n"
            case .csv:
                var values = try row.values.map(csvValue)
                if let provenanceNode {
                    values.append(csvEscape(StrictJSONWriter.encode(provenanceNode)))
                }
                encoded = values.joined(separator: ",") + "\n"
            case .nquads:
                throw DatabaseCLIError(
                    .internalFailure,
                    "N-Quads row rendering reached an invalid state"
                )
            }
            bytes += UInt64(try output.result(encoded))
            count += 1
        }
        try requireOriginsExhausted(&originIterator)
        if format == .json, jsonFraming.closesCollection {
            bytes += UInt64(try output.result("]\n"))
        }
        try renderPageMetadata(
            continuation: page.continuation,
            consistency: page.consistency,
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
        guard format != .nquads || page.provenance == nil else {
            throw DatabaseCLIError(
                .input,
                "N-Quads output cannot preserve Composition provenance; use jsonl or json"
            )
        }
        let nquads = NQuadsEncoder()
        var iterator = page.makeQuadIterator()
        var originIterator = page.provenance?.makeOriginIterator()
        var count: UInt64 = 0
        var bytes: UInt64 = 0
        if format == .json, jsonFraming.opensCollection {
            bytes += UInt64(try output.result("["))
        }
        while let quad = try iterator.next() {
            try elementQuota?.reserveOne()
            let provenanceNode = try rowProvenanceNode(
                page.provenance,
                iterator: &originIterator
            )
            let encoded: String
            if format == .nquads {
                encoded = try nquads.format(quad) + "\n"
            } else {
                var fields: [(key: String, value: StrictJSONValue)] = [
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
                ]
                if let provenanceNode {
                    fields.append(("$provenance", provenanceNode))
                }
                let json = StrictJSONWriter.encode(.object(fields))
                encoded = format == .json
                    ? (count == 0 && !jsonFraming.hasPriorElements ? "" : ",") + json
                    : json + "\n"
            }
            bytes += UInt64(try output.result(encoded))
            count += 1
        }
        try requireOriginsExhausted(&originIterator)
        if format == .json, jsonFraming.closesCollection {
            bytes += UInt64(try output.result("]\n"))
        }
        try renderPageMetadata(
            continuation: page.continuation,
            consistency: page.consistency,
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
        columns: [QueryColumn],
        provenance: StrictJSONValue?
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
        if let provenance {
            fields.append(("$provenance", provenance))
        }
        return StrictJSONWriter.encode(.object(fields))
    }

    private func rowProvenanceNode(
        _ provenance: CompositionPageProvenance?,
        iterator: inout CompositionOriginIterator?
    ) throws -> StrictJSONValue? {
        guard let provenance else { return nil }
        guard let origin = try iterator?.next() else {
            throw DatabaseCLIError(
                .internalFailure,
                "Composition provenance ended before its result page"
            )
        }
        return provenanceNode(provenance, origin: origin)
    }

    private func requireOriginsExhausted(
        _ iterator: inout CompositionOriginIterator?
    ) throws {
        guard try iterator?.next() == nil else {
            throw DatabaseCLIError(
                .internalFailure,
                "Composition provenance exceeds its result page"
            )
        }
    }

    private func provenanceNode(
        _ provenance: CompositionPageProvenance,
        origin: CompositionOrigin
    ) -> StrictJSONValue {
        .object([
            ("composition", .string(provenance.compositionID.value)),
            ("generation", .string(String(provenance.generation))),
            ("origin", originNode(origin)),
        ])
    }

    private func originNode(_ origin: CompositionOrigin) -> StrictJSONValue {
        switch origin {
        case .source(let baseID):
            return .object([
                ("type", .string("source")),
                ("base", .string(baseID.value)),
            ])
        case .derived(let contributors):
            return .object([
                ("type", .string("derived")),
                ("contributors", .array(
                    contributors.map { .string($0.value) }
                )),
            ])
        }
    }

    private func tableJSON(_ node: StrictJSONValue) -> String {
        StrictJSONWriter.encode(node)
            .replacingOccurrences(of: "\t", with: "\\t")
            .replacingOccurrences(of: "\n", with: "\\n")
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
        consistency: DatabaseReadConsistency,
        format: OutputFormat,
        bytes: inout UInt64
    ) throws {
        let metadata = StrictJSONWriter.encode(
            .object([
                ("$continuation", continuation.map { .string(Base64URL.encode($0)) } ?? .null),
                ("$consistency", consistencyNode(consistency)),
            ])
        )
        if format == .jsonl {
            bytes += UInt64(try output.result(metadata + "\n"))
        } else {
            output.diagnostic(metadata + "\n")
        }
    }

    private func consistencyNode(
        _ consistency: DatabaseReadConsistency
    ) -> StrictJSONValue {
        switch consistency {
        case .transactional(let readPoint):
            return .object([
                ("type", .string("transactional")),
                ("readPoints", .array([readPointNode(readPoint)])),
            ])
        case .federated(let readPoints):
            return .object([
                ("type", .string("federated")),
                ("readPoints", .array(readPoints.map(readPointNode))),
            ])
        }
    }

    private func readPointNode(_ readPoint: DomainReadPoint) -> StrictJSONValue {
        let position: StrictJSONValue
        switch readPoint.position {
        case .version(let version):
            position = .object([
                ("type", .string("version")),
                ("value", .string(String(version))),
            ])
        case .opaque(let bytes):
            position = .object([
                ("type", .string("opaque")),
                ("value", .string(Base64URL.encode(bytes))),
            ])
        }
        return .object([
            ("domain", .string(readPoint.domainID)),
            ("position", position),
        ])
    }

}
