import DatabaseKit
import DatabaseTypes

public struct QueryValueJSONEncoder: Sendable {
    public let maximumOutputBytes: Int
    public let maximumDepth: Int

    public init(maximumOutputBytes: Int = 16 * 1_024 * 1_024, maximumDepth: Int = 64) {
        self.maximumOutputBytes = maximumOutputBytes
        self.maximumDepth = maximumDepth
    }

    public func encode(_ value: QueryValue) throws -> String {
        let text = StrictJSONWriter.encode(try node(value))
        guard text.utf8.count <= maximumOutputBytes else {
            throw DatabaseCLIError(.resourceLimit, "Encoded QueryValue exceeds the output byte limit")
        }
        return text
    }

    func node(_ value: QueryValue) throws -> StrictJSONValue {
        guard maximumOutputBytes > 0, maximumDepth > 0 else {
            throw DatabaseCLIError(.resourceLimit, "QueryValue output limits must be positive")
        }
        try QueryValueValidator.validate(value, limits: QueryValueLimits(
            maximumRetainedBytes: UInt64(maximumOutputBytes),
            maximumTotalNodes: UInt64(maximumOutputBytes),
            maximumNestingDepth: UInt64(maximumDepth),
            maximumCollectionElements: UInt64(maximumOutputBytes)
        ))
        return try valueNode(value)
    }

    private func valueNode(_ value: QueryValue) throws -> StrictJSONValue {
        switch value {
        case .primitive(let value):
            return try FieldValueJSONEncoder(maximumOutputBytes: maximumOutputBytes).node(value)
        case .numeric(let value): return numericNode(value, tagged: true)
        case .json(let value):
            // Lexical JSON is materialized only at the CLI's external text boundary.
            let text = value.bytes.withUnsafeBytes { String(decoding: $0, as: UTF8.self) }
            return .object([("$type", .string("json")), ("value", .string(text))])
        case .jsonb(let value):
            return .object([("$type", .string("jsonb")), ("value", try jsonbNode(value.root))])
        case .array(let value):
            return .object([
                ("$type", .string("sqlArray")),
                ("elementType", try QueryColumnJSONCodec.typeNode(.sql(value.elementType))),
                ("dimensions", .array(value.dimensions.map { dimension in
                    .object([("lowerBound", .string(String(dimension.lowerBound))),
                             ("length", .string(String(dimension.length)))])
                })),
                ("elements", .array(try value.elements.map(valueNode))),
            ])
        case .interval(let value):
            return .object([
                ("$type", .string("interval")),
                ("months", .string(String(value.period.months))),
                ("days", .string(String(value.period.days))),
                ("microseconds", .string(String(value.microseconds))),
            ])
        }
    }

    private func numericNode(_ value: QueryNumericValue, tagged: Bool) -> StrictJSONValue {
        var members: [(key: String, value: StrictJSONValue)] = []
        if tagged { members.append(("$type", .string("numeric"))) }
        members.append(("coefficient", .string(String(value.value.coefficient))))
        members.append(("scale", .string(String(value.value.scale))))
        members.append(("displayScale", .string(String(value.displayScale))))
        return .object(members)
    }

    private func jsonbNode(_ value: QueryJSONBNode) throws -> StrictJSONValue {
        let kind: String
        let payload: StrictJSONValue?
        switch value {
        case .null: kind = "null"; payload = nil
        case .bool(let value): kind = "bool"; payload = .bool(value)
        case .string(let value): kind = "string"; payload = .string(value)
        case .number(let value): kind = "number"; payload = numericNode(value, tagged: false)
        case .array(let values): kind = "array"; payload = .array(try values.map(jsonbNode))
        case .object(let members):
            kind = "object"
            payload = .array(try members.map { member in
                .object([("key", .string(member.key)), ("value", try jsonbNode(member.value))])
            })
        }
        var members: [(key: String, value: StrictJSONValue)] = [("kind", .string(kind))]
        if let payload { members.append(("value", payload)) }
        return .object(members)
    }
}
