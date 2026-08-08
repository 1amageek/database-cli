import Darwin
import Foundation
import Synchronization

private final class ResultByteQuota: Sendable {
    private let remaining: Mutex<UInt64>

    init(maximumBytes: UInt64) {
        self.remaining = Mutex(maximumBytes)
    }

    func reserve(_ byteCount: Int) throws {
        guard byteCount >= 0, let count = UInt64(exactly: byteCount) else {
            throw DatabaseCLIError(.resourceLimit, "Invalid output byte count")
        }
        let accepted = remaining.withLock { remaining in
            guard count <= remaining else { return false }
            remaining -= count
            return true
        }
        guard accepted else {
            throw DatabaseCLIError(
                .resourceLimit,
                "Result output exceeds '--max-total-bytes'"
            )
        }
    }
}

public struct OutputWriter: Sendable {
    private let resultHandle: FileHandle
    private let diagnosticHandle: FileHandle
    private let resultByteQuota: ResultByteQuota?

    public init(
        resultHandle: FileHandle = .standardOutput,
        diagnosticHandle: FileHandle = .standardError
    ) {
        self.resultHandle = resultHandle
        self.diagnosticHandle = diagnosticHandle
        self.resultByteQuota = nil
    }

    private init(
        resultHandle: FileHandle,
        diagnosticHandle: FileHandle,
        resultByteQuota: ResultByteQuota
    ) {
        self.resultHandle = resultHandle
        self.diagnosticHandle = diagnosticHandle
        self.resultByteQuota = resultByteQuota
    }

    public func limitingResultBytes(to maximumBytes: UInt64) -> Self {
        Self(
            resultHandle: resultHandle,
            diagnosticHandle: diagnosticHandle,
            resultByteQuota: ResultByteQuota(maximumBytes: maximumBytes)
        )
    }

    public var standardOutputIsTTY: Bool {
        resultHandle === FileHandle.standardOutput
            && isatty(STDOUT_FILENO) == 1
    }

    @discardableResult
    public func result(_ value: String) throws -> Int {
        let data = Data(value.utf8)
        try resultByteQuota?.reserve(data.count)
        do {
            try resultHandle.write(contentsOf: data)
            return data.count
        } catch {
            throw DatabaseCLIError(.unavailable, "Result output failed: \(error)")
        }
    }

    public func diagnostic(_ value: String) {
        diagnosticHandle.write(Data(value.utf8))
    }
}
