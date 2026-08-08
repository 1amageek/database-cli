import DatabaseCommandLine
import DatabaseTypes
import StorageKit

struct FDBRawInspector: Sendable {
    let output: FDBOutput

    func get(
        command: FDBCommand,
        engine: any StorageEngine
    ) async throws {
        let key = try rawKey(command)
        let maximumBytes = try integerOption(
            "max-total-bytes",
            command: command,
            default: 16 * 1_024 * 1_024
        )
        let value = try await StorageTransactionExecutor(engine: engine)
            .withTransaction { transaction in
                try await transaction.getValue(for: key, snapshot: true)
            }
        guard let value else {
            throw FDBCLIError(.notFound, "Raw key was not found")
        }
        guard value.count <= maximumBytes else {
            throw FDBCLIError(.resourceLimit, "Raw value exceeds the byte limit")
        }
        try output.json([
            "key": output.byteNode(key),
            "value": output.byteNode(value),
            "valueByteCount": String(value.count),
        ])
    }

    func range(
        command: FDBCommand,
        engine: any StorageEngine
    ) async throws {
        let prefix = try rawKey(command)
        let limit = try integerOption(
            "limit",
            command: command,
            default: 100
        )
        guard (1...10_000).contains(limit) else {
            throw FDBCLIError(.input, "Range limit must be 1 through 10000")
        }
        guard command.option("max-total-bytes") != nil else {
            throw FDBCLIError(
                .input,
                "Raw range requires '--max-total-bytes'"
            )
        }
        let maximumBytes = try integerOption(
            "max-total-bytes",
            command: command,
            default: 0
        )
        guard maximumBytes > 0 else {
            throw FDBCLIError(.input, "Raw range byte limit must be positive")
        }
        let end = try prefixEnd(prefix)
        try await engine.executeTransaction { transaction in
            var byteCount = 0
            var cursor = transaction.rangeCursor(
                from: .firstGreaterOrEqual(prefix),
                to: .firstGreaterOrEqual(end),
                limit: limit,
                reverse: false,
                snapshot: true,
                streamingMode: .iterator
            )
            try await cursor.consume { key, value in
                let next = byteCount.addingReportingOverflow(
                    key.count + value.count
                )
                guard !next.overflow,
                      next.partialValue <= maximumBytes else {
                    throw FDBCLIError(
                        .resourceLimit,
                        "Raw range exceeded '--max-total-bytes'"
                    )
                }
                byteCount = next.partialValue
                try output.json([
                    "key": output.byteNode(key),
                    "value": output.byteNode(value),
                    "valueByteCount": String(value.count),
                ])
            }
        }
    }
}

private extension FDBRawInspector {
    func rawKey(_ command: FDBCommand) throws -> ByteString {
        let selected = ["key-hex", "key-utf8", "key-tuple"].compactMap { name in
            command.option(name).map { value in (name, value) }
        }
        guard selected.count == 1, let (kind, value) = selected.first else {
            throw FDBCLIError(
                .input,
                "Specify exactly one of --key-hex, --key-utf8, or --key-tuple"
            )
        }
        switch kind {
        case "key-hex": return try decodeHex(value)
        case "key-utf8": return ByteString(utf8: value)
        case "key-tuple":
            let source = try InputSource().read(value)
            let decoded = try FieldValueJSONDecoder().decode(source)
            guard case .array(let fields) = decoded else {
                throw FDBCLIError(
                    .input,
                    "Tuple key must be a tagged FieldValue array"
                )
            }
            return Tuple(try fields.map(tupleElement)).pack()
        default:
            throw FDBCLIError(.internalFailure, "Unknown raw key selector")
        }
    }

    func tupleElement(_ value: FieldValue) throws -> any TupleElement {
        switch value {
        case .null: TupleNil()
        case .bool(let value): value
        case .int8(let value): Int64(value)
        case .int16(let value): Int64(value)
        case .int32(let value): Int64(value)
        case .int64(let value): value
        case .uint8(let value): UInt64(value)
        case .uint16(let value): UInt64(value)
        case .uint32(let value): UInt64(value)
        case .uint64(let value): value
        case .float32(let value): value
        case .float64(let value): value
        case .string(let value): value
        case .bytes(let value): value
        case .uuid(let value): value
        case .array(let values): Tuple(try values.map(tupleElement))
        default:
            throw FDBCLIError(
                .input,
                "FieldValue case is not supported by the FDB tuple layer"
            )
        }
    }

    func decodeHex(_ raw: String) throws -> ByteString {
        guard raw.utf8.count.isMultiple(of: 2) else {
            throw FDBCLIError(.input, "Hex key must contain an even number of digits")
        }
        let bytes = Array(raw.utf8)
        var decoded: [UInt8] = []
        decoded.reserveCapacity(bytes.count / 2)
        var index = 0
        while index < bytes.count {
            guard let high = hexValue(bytes[index]),
                  let low = hexValue(bytes[index + 1]) else {
                throw FDBCLIError(.input, "Hex key contains a non-hexadecimal digit")
            }
            decoded.append((high << 4) | low)
            index += 2
        }
        return ByteString(decoded)
    }

    func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: byte - 48
        case 65...70: byte - 55
        case 97...102: byte - 87
        default: nil
        }
    }

    func prefixEnd(_ prefix: ByteString) throws -> ByteString {
        guard !prefix.isEmpty else { return ByteString([0xFF]) }
        // Prefix successor calculation must own mutable bytes; the cursor
        // retains the final ByteString and no borrowed pointer escapes.
        var bytes = Array(prefix)
        var index = bytes.count
        while index > 0 {
            index -= 1
            if bytes[index] != 0xFF {
                bytes[index] += 1
                bytes.removeSubrange((index + 1)..<bytes.count)
                return ByteString(bytes)
            }
        }
        throw FDBCLIError(
            .input,
            "A prefix containing only 0xff bytes has no bounded successor"
        )
    }

    func integerOption(
        _ name: String,
        command: FDBCommand,
        default defaultValue: Int
    ) throws -> Int {
        guard let raw = command.option(name) else { return defaultValue }
        guard let value = Int(raw) else {
            throw FDBCLIError(.input, "Option '--\(name)' must be an integer")
        }
        return value
    }
}
