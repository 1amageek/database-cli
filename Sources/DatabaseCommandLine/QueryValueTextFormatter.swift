import DatabaseKit
import DatabaseTypes

struct QueryValueTextFormatter {
    let maximumBytes: Int

    init(maximumBytes: Int = 16 * 1_024 * 1_024) {
        self.maximumBytes = maximumBytes
    }

    func format(_ value: QueryValue) throws -> String {
        // Validate the bounded value graph before recursively building display text.
        let encoder = QueryValueJSONEncoder(maximumOutputBytes: maximumBytes)
        guard maximumBytes > 0 else {
            throw DatabaseCLIError(.resourceLimit, "QueryValue display limit must be positive")
        }
        try QueryValueValidator.validate(value, limits: QueryValueLimits(
            maximumRetainedBytes: UInt64(maximumBytes),
            maximumTotalNodes: UInt64(maximumBytes), maximumNestingDepth: 64,
            maximumCollectionElements: UInt64(maximumBytes)
        ))
        let result: String
        switch value {
        case .primitive(let value):
            result = try FieldValueJSONEncoder(maximumOutputBytes: maximumBytes).encode(value)
        case .numeric(let value): result = try numeric(value)
        case .json(let value):
            result = value.bytes.withUnsafeBytes { String(decoding: $0, as: UTF8.self) }
        case .jsonb(let value): result = StrictJSONWriter.encode(try jsonb(value.root))
        case .array, .composite: result = try encoder.encode(value)
        case .interval(let value):
            result = "months=\(value.period.months) days=\(value.period.days) microseconds=\(value.microseconds)"
        case .time(let value): result = time(value)
        case .timeWithTimeZone(let value):
            let offset = Int64(value.utcOffsetSeconds)
            let magnitude = offset < 0 ? -offset : offset
            result = time(value.time) + (offset < 0 ? "-" : "+")
                + padded(magnitude / 3600, digits: 2) + ":"
                + padded(magnitude / 60 % 60, digits: 2) + ":"
                + padded(magnitude % 60, digits: 2)
        case .dateInfinity(let sign), .timestampInfinity(let sign, _), .intervalInfinity(let sign):
            switch sign {
            case .negative: result = "-infinity"
            case .positive: result = "infinity"
            }
        }
        guard result.utf8.count <= maximumBytes else {
            throw DatabaseCLIError(.resourceLimit, "QueryValue display exceeds the output byte limit")
        }
        return result
    }

    private func time(_ value: QueryTimeValue) -> String {
        let micros = value.microsecondsSinceMidnight
        let seconds = micros / 1_000_000
        return padded(seconds / 3600, digits: 2) + ":"
            + padded(seconds / 60 % 60, digits: 2) + ":"
            + padded(seconds % 60, digits: 2) + "."
            + padded(micros % 1_000_000, digits: 6)
    }

    private func padded(_ value: Int64, digits: Int) -> String {
        let text = String(value)
        return String(repeating: "0", count: max(0, digits - text.utf8.count)) + text
    }

    private func numeric(_ value: QueryNumericValue) throws -> String {
        let digits = String(value.value.coefficient.magnitude)
        let scale = Int64(value.value.scale)
        let displayScale = Int64(value.displayScale)
        let integerCount = max(1, Int64(digits.utf8.count) - scale)
        let signCount: Int64 = value.value.coefficient < 0 ? 1 : 0
        let total = signCount + integerCount + (displayScale > 0 ? 1 + displayScale : 0)
        guard maximumBytes > 0, total <= Int64(maximumBytes) else {
            throw DatabaseCLIError(.resourceLimit, "Numeric display exceeds the output byte limit")
        }
        let integer: String
        let fraction: String
        if scale <= 0 {
            integer = digits + String(repeating: "0", count: Int(-scale))
            fraction = ""
        } else if scale < Int64(digits.utf8.count) {
            let split = digits.index(digits.endIndex, offsetBy: -Int(scale))
            integer = String(digits[..<split])
            fraction = String(digits[split...])
        } else {
            integer = "0"
            fraction = String(repeating: "0", count: Int(scale) - digits.utf8.count) + digits
        }
        return (signCount == 1 ? "-" : "") + integer
            + (displayScale > 0
               ? "." + fraction + String(repeating: "0", count: Int(displayScale) - fraction.utf8.count)
               : "")
    }

    private func jsonb(_ value: QueryJSONBNode) throws -> StrictJSONValue {
        switch value {
        case .null: return .null
        case .bool(let value): return .bool(value)
        case .string(let value): return .string(value)
        case .number(let value): return .number(try numeric(value))
        case .array(let values): return .array(try values.map(jsonb))
        case .object(let members):
            return .object(try members.map { ($0.key, try jsonb($0.value)) })
        }
    }
}
