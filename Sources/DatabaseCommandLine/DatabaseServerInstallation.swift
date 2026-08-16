import Darwin
import Foundation

struct DatabaseServerInstallation: Sendable {
    let url: URL

    static func adjacent() throws -> Self {
        guard let executableURL = Bundle.main.executableURL else {
            throw DatabaseCLIError(
                .unavailable,
                "Cannot locate the database executable"
            )
        }
        let serverURL = executableURL.deletingLastPathComponent()
            .appendingPathComponent("database-server", isDirectory: false)
        guard FileManager.default.isExecutableFile(atPath: serverURL.path) else {
            throw DatabaseCLIError(
                .unavailable,
                "The version-matched database-server executable is not installed next to database"
            )
        }
        return Self(url: serverURL)
    }

    func validateVersion(
        expected: String,
        timeout: Duration = .seconds(5)
    ) async throws {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let termination = DatabaseServerVersionCheckTermination()
        process.executableURL = url
        process.arguments = ["--version"]
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.terminationHandler = { process in
            let status = process.terminationReason == .exit
                ? process.terminationStatus
                : -process.terminationStatus
            Task { await termination.finish(status: status) }
        }
        do {
            try process.run()
            outputPipe.fileHandleForWriting.closeFile()
            errorPipe.fileHandleForWriting.closeFile()
            async let outputRead = Self.readBounded(
                outputPipe.fileHandleForReading
            )
            async let diagnosticRead = Self.readBounded(
                errorPipe.fileHandleForReading
            )
            let timeoutTask = Task {
                do {
                    try await Task.sleep(for: timeout)
                    await termination.timeOut()
                } catch {
                    // The process terminated before the deadline.
                }
            }
            let outcome = await termination.waitForOutcome()
            timeoutTask.cancel()
            if case .timedOut = outcome {
                process.terminate()
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    // Cancellation shortens the grace period; the child still
                    // must be terminated and reaped below.
                }
                if process.isRunning {
                    _ = Darwin.kill(process.processIdentifier, SIGKILL)
                }
                _ = await termination.waitForStatus()
            }
            let output = try await outputRead
            let diagnostic = try await diagnosticRead
            guard case .terminated(let status) = outcome else {
                throw DatabaseCLIError(
                    .unavailable,
                    "database-server version check timed out"
                )
            }
            guard status == 0 else {
                throw DatabaseCLIError(
                    .unavailable,
                    "database-server version check failed: "
                        + Self.safeDiagnostic(diagnostic.data)
                )
            }
            guard !output.exceededLimit,
                  let actual = String(data: output.data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                actual == expected else {
                throw DatabaseCLIError(
                    .unavailable,
                    "database and database-server versions do not match"
                )
            }
        } catch let error as DatabaseCLIError {
            throw error
        } catch {
            throw DatabaseCLIError(
                .unavailable,
                "Cannot execute database-server: \(error)"
            )
        }
    }

    fileprivate enum TerminationOutcome: Sendable {
        case terminated(Int32)
        case timedOut
    }

    private struct BoundedOutput: Sendable {
        let data: Data
        let exceededLimit: Bool
    }

    private static func readBounded(
        _ handle: FileHandle
    ) async throws -> BoundedOutput {
        defer { handle.closeFile() }
        let maximumByteCount = 4_096
        let data = try handle.read(upToCount: maximumByteCount + 1) ?? Data()
        return BoundedOutput(
            data: Data(data.prefix(maximumByteCount)),
            exceededLimit: data.count > maximumByteCount
        )
    }

    private static func safeDiagnostic(_ data: Data) -> String {
        let limit = 4_096
        let bounded = data.prefix(limit)
        guard let value = String(data: bounded, encoding: .utf8) else {
            return "non-UTF-8 diagnostic"
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private actor DatabaseServerVersionCheckTermination {
    private var status: Int32?
    private var outcome: DatabaseServerInstallation.TerminationOutcome?
    private var statusWaiters: [CheckedContinuation<Int32, Never>] = []
    private var outcomeWaiters: [CheckedContinuation<
        DatabaseServerInstallation.TerminationOutcome,
        Never
    >] = []

    func finish(status: Int32) {
        guard self.status == nil else { return }
        self.status = status
        if outcome == nil {
            finishOutcome(.terminated(status))
        }
        let waiters = statusWaiters
        statusWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume(returning: status)
        }
    }

    func timeOut() {
        guard outcome == nil else { return }
        finishOutcome(.timedOut)
    }

    func waitForStatus() async -> Int32 {
        if let status { return status }
        return await withCheckedContinuation { continuation in
            statusWaiters.append(continuation)
        }
    }

    func waitForOutcome() async -> DatabaseServerInstallation.TerminationOutcome {
        if let outcome { return outcome }
        return await withCheckedContinuation { continuation in
            outcomeWaiters.append(continuation)
        }
    }

    private func finishOutcome(
        _ outcome: DatabaseServerInstallation.TerminationOutcome
    ) {
        self.outcome = outcome
        let waiters = outcomeWaiters
        outcomeWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume(returning: outcome)
        }
    }
}
