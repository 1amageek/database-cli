import DatabaseTypes
import Foundation

struct FDBOutput: Sendable {
    let resultHandle: FileHandle
    let diagnosticHandle: FileHandle

    init(
        resultHandle: FileHandle = .standardOutput,
        diagnosticHandle: FileHandle = .standardError
    ) {
        self.resultHandle = resultHandle
        self.diagnosticHandle = diagnosticHandle
    }

    func result(_ text: String) throws {
        do {
            try resultHandle.write(contentsOf: Data(text.utf8))
        } catch {
            throw FDBCLIError(.unavailable, "Result output failed: \(error)")
        }
    }

    func diagnostic(_ text: String) {
        diagnosticHandle.write(Data(text.utf8))
    }

    func json(_ object: Any) throws {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw FDBCLIError(.internalFailure, "Internal JSON output is invalid")
        }
        do {
            let data = try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys]
            )
            guard let text = String(data: data, encoding: .utf8) else {
                throw FDBCLIError(.internalFailure, "JSON output is not UTF-8")
            }
            try result(text + "\n")
        } catch let error as FDBCLIError {
            throw error
        } catch {
            throw FDBCLIError(.internalFailure, "JSON encoding failed: \(error)")
        }
    }

    func byteNode(_ bytes: ByteString) -> [String: Any] {
        let data = bytes.withUnsafeBytes { Data($0) }
        let encoded = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return ["$type": "bytes", "value": encoded]
    }
}
