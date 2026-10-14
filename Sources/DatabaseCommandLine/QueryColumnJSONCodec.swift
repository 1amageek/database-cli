import DatabaseKit
import DatabaseSchemaJSON

enum QueryColumnJSONCodec {
    static func node(_ column: QueryColumn) throws -> StrictJSONValue {
        .object([
            ("number", .string(String(column.number))),
            ("name", .string(column.name)),
            ("type", try typeNode(column.type)),
            ("isNullable", .bool(column.isNullable)),
        ])
    }

    static func typeNode(_ type: QueryColumnType) throws -> StrictJSONValue {
        try StrictJSONParser().parse(QueryColumnTypeJSONCodec().encode(type))
    }

    static func type(_ node: StrictJSONValue) throws -> QueryColumnType {
        do {
            return try QueryColumnTypeJSONCodec().decode(StrictJSONWriter.encode(node))
        } catch let error {
            switch error {
            case .inputTooLarge, .nestingTooDeep, .collectionTooLarge, .outputTooLarge:
                throw DatabaseCLIError(.resourceLimit, "Query type exceeds its limits: \(error)")
            case .invalidQueryValue(_, .resourceLimit), .invalidQueryValue(_, .arithmeticOverflow):
                throw DatabaseCLIError(.resourceLimit, "Query type exceeds its limits: \(error)")
            default:
                throw DatabaseCLIError(.input, "Invalid query type: \(error)")
            }
        }
    }
}
