import DatabaseKit
import DatabaseTypes

public struct QueryValueJSONDecoder: Sendable {
    public let maximumBytes: Int
    public let maximumDepth: Int

    public init(maximumBytes: Int = 16 * 1_024 * 1_024, maximumDepth: Int = 64) {
        self.maximumBytes = maximumBytes
        self.maximumDepth = maximumDepth
    }

    private var limits: QueryValueLimits {
        QueryValueLimits(maximumRetainedBytes: UInt64(max(0, maximumBytes)),
                         maximumTotalNodes: UInt64(max(0, maximumBytes)),
                         maximumNestingDepth: UInt64(max(0, maximumDepth)),
                         maximumCollectionElements: UInt64(max(0, maximumBytes)))
    }

    public func decode(_ text: String) throws -> QueryValue {
        do {
            // The closed tagged grammar adds at most three JSON levels per value level.
            let envelopeDepth = maximumDepth.multipliedReportingOverflow(by: 3)
            guard maximumDepth > 0, maximumBytes > 0, !envelopeDepth.overflow else {
                throw DatabaseCLIError(.resourceLimit, "QueryValue input limits are invalid")
            }
            let node = try StrictJSONParser(maximumBytes: maximumBytes, maximumDepth: envelopeDepth.partialValue).parse(text)
            let value = try decode(node, depth: 0)
            try QueryValueValidator.validate(value, limits: limits)
            return value
        } catch let error as DatabaseCLIError {
            throw error
        } catch let error as QueryValueError {
            switch error {
            case .resourceLimit, .arithmeticOverflow, .dimensionProductOverflow:
                throw DatabaseCLIError(.resourceLimit, "Query value exceeds its limits: \(error)")
            default:
                throw DatabaseCLIError(.input, "Invalid query value: \(error)")
            }
        } catch {
            throw DatabaseCLIError(.input, "Invalid query value: \(error)")
        }
    }

    func decode(_ node: StrictJSONValue, depth: Int) throws -> QueryValue {
        guard depth <= maximumDepth else {
            throw DatabaseCLIError(.resourceLimit, "QueryValue nesting limit exceeded")
        }
        let object = try StrictJSONObject(node)
        let tag = try object.required("$type").string(named: "$type")
        switch tag {
        case "numeric": return .numeric(try numeric(object, tagged: true))
        case "json":
            try object.validateKeys(["$type", "value"])
            let text = try object.required("value").string(named: "value")
            return .json(try QueryJSONValue(bytes: ByteString(utf8: text), limits: limits))
        case "jsonb":
            try object.validateKeys(["$type", "value"])
            return .jsonb(try QueryJSONBValue(root: jsonb(object.required("value"), depth: depth + 1), limits: limits))
        case "sqlArray":
            try object.validateKeys(["$type", "elementType", "dimensions", "elements"])
            guard case .sql(let elementType) = try QueryColumnJSONCodec.type(object.required("elementType")) else {
                throw DatabaseCLIError(.input, "SQL array element type must be a SQL descriptor")
            }
            let dimensions = try object.required("dimensions").array(named: "dimensions").map { node in
                let dimension = try StrictJSONObject(node)
                try dimension.validateKeys(["lowerBound", "length"])
                return try QueryArrayDimension(lowerBound: integer(dimension, "lowerBound"),
                                               length: integer(dimension, "length"))
            }
            let elements = try object.required("elements").array(named: "elements").map {
                try decode($0, depth: depth + 1)
            }
            return .array(try QueryArrayValue(elementType: elementType, dimensions: dimensions,
                                              elements: elements, limits: limits))
        case "interval":
            try object.validateKeys(["$type", "months", "days", "microseconds"])
            let months: Int32 = try integer(object, "months")
            let days: Int32 = try integer(object, "days")
            let micros: Int64 = try integer(object, "microseconds")
            let remainder = micros % 1_000_000
            let seconds = micros / 1_000_000 - (remainder < 0 ? 1 : 0)
            let nanoseconds = UInt32(remainder < 0 ? remainder + 1_000_000 : remainder) * 1000
            return .interval(try QueryIntervalValue(
                period: CalendarPeriod(months: Int64(months), days: Int64(days)),
                time: TimeSpan(seconds: seconds, nanoseconds: nanoseconds)
            ))
        default:
            return .primitive(try FieldValueJSONDecoder(maximumBytes: maximumBytes, maximumDepth: maximumDepth)
                .decode(node, depth: depth))
        }
    }

    private func integer<Value: FixedWidthInteger>(_ object: StrictJSONObject, _ name: String) throws -> Value {
        let text = try object.required(name).string(named: name)
        guard let value = Value(text), String(value) == text else {
            throw DatabaseCLIError(.input, "Invalid canonical integer '\(name)'")
        }
        return value
    }

    private func numeric(_ object: StrictJSONObject, tagged: Bool) throws -> QueryNumericValue {
        try object.validateKeys(tagged ? ["$type", "coefficient", "scale", "displayScale"]
                                      : ["coefficient", "scale", "displayScale"])
        let coefficient: Int128 = try integer(object, "coefficient")
        let scale: Int32 = try integer(object, "scale")
        let value = ExactDecimal(coefficient: coefficient, scale: scale)
        guard value.coefficient == coefficient, value.scale == scale else {
            throw DatabaseCLIError(.input, "Numeric components must be canonical")
        }
        return try QueryNumericValue(value: value, displayScale: integer(object, "displayScale"))
    }

    private func jsonb(_ node: StrictJSONValue, depth: Int) throws -> QueryJSONBNode {
        guard depth <= maximumDepth else {
            throw DatabaseCLIError(.resourceLimit, "JSONB nesting limit exceeded")
        }
        let object = try StrictJSONObject(node)
        let kind = try object.required("kind").string(named: "kind")
        try object.validateKeys(kind == "null" ? ["kind"] : ["kind", "value"])
        switch kind {
        case "null": return .null
        case "bool": return .bool(try object.required("value").bool(named: "value"))
        case "string": return .string(try object.required("value").string(named: "value"))
        case "number": return .number(try numeric(StrictJSONObject(object.required("value")), tagged: false))
        case "array":
            return try .array(object.required("value").array(named: "value").map {
                try jsonb($0, depth: depth + 1)
            }, limits: limits)
        case "object":
            return try .object(object.required("value").array(named: "value").map { node in
                let member = try StrictJSONObject(node)
                try member.validateKeys(["key", "value"])
                return try QueryJSONBMember(key: member.required("key").string(named: "key"),
                                            value: jsonb(member.required("value"), depth: depth + 1))
            }, limits: limits)
        default: throw DatabaseCLIError(.input, "Unknown JSONB kind '\(kind)'")
        }
    }
}
