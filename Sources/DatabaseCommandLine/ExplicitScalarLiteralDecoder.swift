import DatabaseTypes

struct ExplicitScalarLiteralDecoder: Sendable {
    private let taggedDecoder = FieldValueJSONDecoder()

    func decode(_ literal: String) throws -> FieldValue {
        guard let separator = literal.firstIndex(of: ":") else {
            throw DatabaseCLIError(
                .input,
                "Typed scalar literal must use '<type>:<value>'"
            )
        }
        let type = String(literal[..<separator])
        let value = String(literal[literal.index(after: separator)...])
        switch type {
        case "string":
            return .string(value)
        case "bool":
            guard value == "true" || value == "false" else {
                throw DatabaseCLIError(.input, "Boolean literal must be true or false")
            }
            return .bool(value == "true")
        case "int64", "uint64", "decimal":
            return try taggedDecoder.decode(
                tagged(type: type, key: "value", value: value)
            )
        case "float32bits":
            return try taggedDecoder.decode(
                tagged(type: "float32", key: "bits", value: value)
            )
        case "float64bits":
            return try taggedDecoder.decode(
                tagged(type: "float64", key: "bits", value: value)
            )
        case "bytes", "uuid":
            return try taggedDecoder.decode(
                tagged(type: type, key: "value", value: value)
            )
        case "date":
            return .date(try date(value))
        case "time":
            return .time(try time(value))
        case "timestamp":
            return .timestamp(try timestamp(value))
        default:
            throw DatabaseCLIError(
                .input,
                "Unsupported scalar literal type '\(type)'"
            )
        }
    }

    private func tagged(
        type: String,
        key: String,
        value: String
    ) -> String {
        StrictJSONWriter.encode(.object([
            ("$type", .string(type)),
            (key, .string(value)),
        ]))
    }

    private func date(_ value: String) throws -> CivilDate {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let year = Int32(parts[0]),
              let month = UInt8(parts[1]),
              let day = UInt8(parts[2]) else {
            throw DatabaseCLIError(.input, "Date literal must be YYYY-MM-DD")
        }
        do {
            return try CivilDate(year: year, month: month, day: day)
        } catch {
            throw DatabaseCLIError(.input, "Invalid date literal: \(error)")
        }
    }

    private func time(_ value: String) throws -> CivilTime {
        let components = value.split(separator: ":", omittingEmptySubsequences: false)
        guard components.count == 3,
              let hour = UInt8(components[0]),
              let minute = UInt8(components[1]) else {
            throw DatabaseCLIError(
                .input,
                "Time literal must be HH:MM:SS[.nanoseconds]"
            )
        }
        let seconds = components[2].split(
            separator: ".",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard let second = UInt8(seconds[0]),
              seconds.count <= 2 else {
            throw DatabaseCLIError(.input, "Invalid time literal")
        }
        let nanoseconds: UInt32
        if seconds.count == 1 {
            nanoseconds = 0
        } else {
            guard seconds[1].count == 9,
                  let value = UInt32(seconds[1]) else {
                throw DatabaseCLIError(
                    .input,
                    "Time fractional seconds must contain exactly 9 digits"
                )
            }
            nanoseconds = value
        }
        do {
            return try CivilTime(
                hour: hour,
                minute: minute,
                second: second,
                nanoseconds: nanoseconds
            )
        } catch {
            throw DatabaseCLIError(.input, "Invalid time literal: \(error)")
        }
    }

    private func timestamp(_ value: String) throws -> Timestamp {
        let components = value.split(
            separator: ".",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard let seconds = Int64(components[0]), components.count <= 2 else {
            throw DatabaseCLIError(
                .input,
                "Timestamp literal must be <seconds>[.<9-digit-nanoseconds>]"
            )
        }
        let nanoseconds: UInt32
        if components.count == 1 {
            nanoseconds = 0
        } else {
            guard components[1].count == 9,
                  let value = UInt32(components[1]) else {
                throw DatabaseCLIError(
                    .input,
                    "Timestamp nanoseconds must contain exactly 9 digits"
                )
            }
            nanoseconds = value
        }
        do {
            return try Timestamp(
                secondsSinceUnixEpoch: seconds,
                nanoseconds: nanoseconds
            )
        } catch {
            throw DatabaseCLIError(.input, "Invalid timestamp literal: \(error)")
        }
    }
}
