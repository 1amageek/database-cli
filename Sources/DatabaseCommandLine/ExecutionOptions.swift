import DatabaseKit
import DatabaseTypes
import DatabaseWire

public enum OutputFormat: String, Sendable, CaseIterable {
    case table
    case jsonl
    case json
    case csv
    case nquads
}

public struct PaginationLimits: Sendable, Hashable {
    public let fetchAll: Bool
    public let maximumTotalRows: UInt64
    public let maximumTotalBytes: UInt64
    public let maximumPages: UInt32

    public init(options: CommandOptions) throws {
        self.fetchAll = options.contains("all")
        if fetchAll {
            self.maximumTotalRows = try options.requiredInteger(
                "max-total-rows",
                as: UInt64.self
            )
            self.maximumTotalBytes = try options.requiredInteger(
                "max-total-bytes",
                as: UInt64.self
            )
            self.maximumPages = try options.requiredInteger(
                "max-pages",
                as: UInt32.self
            )
            guard maximumTotalRows > 0,
                  maximumTotalBytes > 0,
                  maximumPages > 0 else {
                throw DatabaseCLIError(.input, "'--all' limits must be positive")
            }
        } else {
            self.maximumTotalRows = 0
            self.maximumTotalBytes = 0
            self.maximumPages = 1
        }
    }
}

public struct ExecutionOptions: Sendable {
    public let metadata: OperationRequestMetadata
    public let budget: ExecutionBudget
    public let pageSize: UInt32
    public let continuation: ByteString?
    public let outputFormat: OutputFormat?
    public let pagination: PaginationLimits

    public init(options: CommandOptions) throws {
        self.metadata = OperationRequestMetadata(
            traceID: options.value("trace-id"),
            idempotencyKey: options.value("idempotency-key")
        )
        self.budget = ExecutionBudget(
            maximumRows: try options.integer(
                "maximum-rows",
                default: 10_000
            ),
            maximumWorkUnits: try options.integer(
                "maximum-work-units",
                default: 1_000_000
            ),
            maximumIntermediateRows: try options.integer(
                "maximum-intermediate-rows",
                default: 10_000
            ),
            maximumIntermediateBytes: try options.integer(
                "maximum-intermediate-bytes",
                default: 16 * 1_024 * 1_024
            ),
            timeoutMilliseconds: try options.integer(
                "timeout-milliseconds",
                default: 30_000
            )
        )
        self.pageSize = try options.integer("page-size", default: 1_000)
        guard pageSize > 0 else {
            throw DatabaseCLIError(.input, "Page size must be positive")
        }
        if let encoded = options.value("continuation") {
            self.continuation = try Base64URL.decode(encoded)
        } else {
            self.continuation = nil
        }
        if let raw = options.value("output") {
            guard let format = OutputFormat(rawValue: raw) else {
                throw DatabaseCLIError(.input, "Unknown output format '\(raw)'")
            }
            self.outputFormat = format
        } else {
            self.outputFormat = nil
        }
        self.pagination = try PaginationLimits(options: options)
    }

    private init(
        metadata: OperationRequestMetadata,
        budget: ExecutionBudget,
        pageSize: UInt32,
        continuation: ByteString?,
        outputFormat: OutputFormat?,
        pagination: PaginationLimits
    ) {
        self.metadata = metadata
        self.budget = budget
        self.pageSize = pageSize
        self.continuation = continuation
        self.outputFormat = outputFormat
        self.pagination = pagination
    }

    func limitingPageSize(to remainingRows: UInt64) -> Self {
        let bounded = UInt32(min(UInt64(pageSize), remainingRows))
        return Self(
            metadata: metadata,
            budget: budget,
            pageSize: max(1, bounded),
            continuation: continuation,
            outputFormat: outputFormat,
            pagination: pagination
        )
    }
}

extension CommandOptions {
    func integer<T: FixedWidthInteger>(
        _ name: String,
        default defaultValue: T
    ) throws -> T {
        guard let raw = value(name) else { return defaultValue }
        guard let parsed = T(raw) else {
            throw DatabaseCLIError(.input, "Invalid integer for '--\(name)'")
        }
        return parsed
    }

    func requiredInteger<T: FixedWidthInteger>(
        _ name: String,
        as type: T.Type
    ) throws -> T {
        guard let raw = value(name), let parsed = T(raw) else {
            throw DatabaseCLIError(.input, "Invalid integer for '--\(name)'")
        }
        return parsed
    }
}
