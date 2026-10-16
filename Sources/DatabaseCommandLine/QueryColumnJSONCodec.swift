import DatabaseKit
import DatabaseSchemaJSON
import DatabaseWire

enum QueryColumnJSONCodec {
    static func node(_ column: QueryColumn) throws -> StrictJSONValue {
        .object([
            ("number", .string(String(column.number))),
            ("name", .string(column.name)),
            ("type", try typeNode(column.type)),
            ("isNullable", .bool(column.isNullable)),
        ])
    }

    static func typeNode(_ type: QueryColumnType, limits: DatabaseWireLimits = .default) throws -> StrictJSONValue {
        do {
            return try StrictJSONParser(maximumBytes: limits.maximumFrameBytes,
                maximumDepth: limits.maximumNestingDepth).parse(QueryColumnTypeJSONCodec(limits: limits).encode(type))
        } catch let error as SchemaJSONError {
            throw mapped(error)
        }
    }

    static func valueTypeLimits(maximumBytes: Int, semanticDepth: Int) throws -> DatabaseWireLimits {
        let depth = semanticDepth.multipliedReportingOverflow(by: 3)
        guard maximumBytes > 0, semanticDepth > 0, !depth.overflow else {
            throw DatabaseCLIError(.resourceLimit, "Query type limits are invalid")
        }
        return try DatabaseWireLimits(maximumFrameBytes: maximumBytes,
            maximumStringBytes: maximumBytes, maximumByteStringBytes: maximumBytes,
            maximumCollectionCount: maximumBytes,
            maximumNestingDepth: min(depth.partialValue, DatabaseWireLimits.maximumSupportedNestingDepth),
            maximumObjectCount: maximumBytes)
    }

    static func type(_ node: StrictJSONValue, limits: DatabaseWireLimits = .default) throws -> QueryColumnType {
        do {
            return try QueryColumnTypeJSONCodec(limits: limits).decode(StrictJSONWriter.encode(node))
        } catch { throw mapped(error) }
    }

    private static func mapped(_ error: SchemaJSONError) -> DatabaseCLIError {
        switch error {
        case .inputTooLarge, .nestingTooDeep, .collectionTooLarge, .outputTooLarge:
            return DatabaseCLIError(.resourceLimit, "Query type exceeds its limits: \(error)")
        case .invalidQueryValue(_, .resourceLimit), .invalidQueryValue(_, .arithmeticOverflow):
            return DatabaseCLIError(.resourceLimit, "Query type exceeds its limits: \(error)")
        default:
            return DatabaseCLIError(.input, "Invalid query type: \(error)")
        }
    }
}
