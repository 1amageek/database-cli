import Foundation

public struct InputSource: Sendable {
    public let maximumBytes: Int

    public init(maximumBytes: Int = 16 * 1_024 * 1_024) {
        self.maximumBytes = maximumBytes
    }

    public func read(_ specification: String) throws -> String {
        if specification == "@-" {
            return try read(handle: .standardInput, name: "standard input")
        }
        if specification.hasPrefix("@") {
            let path = String(specification.dropFirst())
            guard !path.isEmpty else {
                throw DatabaseCLIError(.input, "Input path is empty")
            }
            do {
                let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
                let value: String
                do {
                    value = try read(handle: handle, name: path)
                } catch {
                    do {
                        try handle.close()
                    } catch let closeError {
                        throw DatabaseCLIError(
                            .input,
                            "Input failed and '\(path)' could not be closed: \(closeError)"
                        )
                    }
                    throw error
                }
                try handle.close()
                return value
            } catch let error as DatabaseCLIError {
                throw error
            } catch {
                throw DatabaseCLIError(.input, "Cannot read '\(path)': \(error)")
            }
        }
        guard specification.utf8.count <= maximumBytes else {
            throw DatabaseCLIError(.resourceLimit, "Inline input exceeds byte limit")
        }
        return specification
    }

    private func read(handle: FileHandle, name: String) throws -> String {
        var bytes: [UInt8] = []
        while true {
            let remaining = maximumBytes - bytes.count
            guard remaining >= 0 else {
                throw DatabaseCLIError(.resourceLimit, "Input exceeds byte limit")
            }
            let data = try handle.read(upToCount: min(64 * 1_024, remaining + 1))
            guard let data, !data.isEmpty else { break }
            guard data.count <= remaining else {
                throw DatabaseCLIError(
                    .resourceLimit,
                    "Input from \(name) exceeds \(maximumBytes) bytes"
                )
            }
            bytes.append(contentsOf: data)
        }
        guard let string = String(bytes: bytes, encoding: .utf8) else {
            throw DatabaseCLIError(.input, "Input from \(name) is not UTF-8")
        }
        return string
    }
}
