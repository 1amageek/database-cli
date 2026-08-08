import DatabaseClient
import DatabaseWire
import Foundation

public enum DatabaseCLIExitCode: Int32, Sendable {
    case success = 0
    case input = 2
    case authentication = 3
    case authorization = 4
    case notFound = 5
    case conflict = 6
    case resourceLimit = 7
    case unavailable = 8
    case internalFailure = 9
    case cancelled = 130
}

public struct DatabaseCLIError: Error, Sendable, CustomStringConvertible {
    public let exitCode: DatabaseCLIExitCode
    public let message: String

    public init(_ exitCode: DatabaseCLIExitCode, _ message: String) {
        self.exitCode = exitCode
        self.message = message
    }

    public var description: String { message }
}

extension DatabaseCLIError {
    static func map(_ error: any Error) -> Self {
        if let error = error as? Self {
            return error
        }
        if error is CancellationError {
            return Self(.cancelled, "Operation cancelled")
        }
        if let error = error as? DatabaseClientError {
            return map(error)
        }
        if let error = error as? RemoteOperationError {
            return map(error)
        }
        return Self(.internalFailure, String(describing: error))
    }

    private static func map(_ error: DatabaseClientError) -> Self {
        switch error {
        case .requestIdentifierExhausted:
            return Self(.internalFailure, "Database request identifiers are exhausted")
        case .transport(let transport):
            return map(transport)
        case .call(.remote(let remote)):
            return map(remote)
        case .call(.wire(let wire)):
            return Self(.internalFailure, "DatabaseWire response failure: \(wire)")
        case .jobLifecycle(let lifecycle):
            return Self(.internalFailure, "Job lifecycle response mismatch: \(lifecycle)")
        case .jobResult(.failed(let remote)):
            return map(remote)
        case .jobResult(.cancelled):
            return Self(.cancelled, "Job was cancelled")
        case .jobResult(let result):
            return map(result)
        }
    }

    private static func map(_ error: DatabaseTransportError) -> Self {
        switch error {
        case .cancelled:
            return Self(.cancelled, "Database transport was cancelled")
        case .unavailable(let message):
            return Self(.unavailable, message)
        case .timeout:
            return Self(.unavailable, "Database transport timed out")
        case .invalidRequest(let message):
            return Self(.input, message)
        case .invalidResponse(let message):
            return Self(.internalFailure, message)
        case .rejected(let code, let message):
            let exitCode: DatabaseCLIExitCode
            switch code {
            case "http_status_401":
                exitCode = .authentication
            case "http_status_403":
                exitCode = .authorization
            case "http_status_404":
                exitCode = .notFound
            case "http_status_409":
                exitCode = .conflict
            case "http_status_413", "http_status_429", "request_too_large":
                exitCode = .resourceLimit
            default:
                exitCode = .unavailable
            }
            return Self(exitCode, "\(code): \(message)")
        }
    }

    private static func map(_ error: JobResultError) -> Self {
        switch error {
        case .responseTooLarge, .byteCountExceeded:
            return Self(.resourceLimit, "Job result exceeded its configured byte limit: \(error)")
        case .failed(let remote):
            return map(remote)
        case .cancelled:
            return Self(.cancelled, "Job was cancelled")
        default:
            return Self(.internalFailure, "Invalid job result response: \(error)")
        }
    }

    private static func map(_ error: RemoteOperationError) -> Self {
        let code: DatabaseCLIExitCode
        switch error.category {
        case .authentication:
            code = .authentication
        case .authorization:
            code = .authorization
        case .notFound:
            code = .notFound
        case .conflict, .constraint:
            code = .conflict
        case .resourceLimit:
            code = .resourceLimit
        case .unavailable:
            code = .unavailable
        case .invalidRequest:
            code = .input
        case .internalFailure:
            code = .internalFailure
        }
        return Self(code, "\(error.code): \(error.message)")
    }
}
