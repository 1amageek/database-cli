import Foundation

enum FDBCLIExitCode: Int32 {
    case success = 0
    case input = 2
    case notFound = 5
    case conflict = 6
    case resourceLimit = 7
    case unavailable = 8
    case internalFailure = 9
    case cancelled = 130
}

struct FDBCLIError: Error, CustomStringConvertible {
    let exitCode: FDBCLIExitCode
    let message: String

    init(_ exitCode: FDBCLIExitCode, _ message: String) {
        self.exitCode = exitCode
        self.message = message
    }

    var description: String { message }
}
