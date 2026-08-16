import Darwin
import Foundation

struct DatabaseServerForegroundProcess: Sendable {
    let executable: DatabaseServerInstallation

    func run(
        configurationURL: URL,
        host: String?,
        port: Int?
    ) async throws {
        try await executable.validateVersion(expected: DatabaseCLIVersion.current)
        let process = Process()
        var arguments = ["serve", "--config", configurationURL.path]
        if let host {
            arguments.append(contentsOf: ["--host", host])
        }
        if let port {
            arguments.append(contentsOf: ["--port", String(port)])
        }
        let termination = DatabaseServerForegroundTermination()
        process.executableURL = executable.url
        process.arguments = arguments
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        process.terminationHandler = { process in
            let status = process.terminationReason == .exit
                ? process.terminationStatus
                : -process.terminationStatus
            Task { await termination.finish(status) }
        }
        do {
            try process.run()
        } catch {
            throw DatabaseCLIError(
                .unavailable,
                "Cannot start database-server: \(error)"
            )
        }

        let status = await withTaskCancellationHandler {
            await termination.wait()
        } onCancel: {
            process.interrupt()
            Task {
                do {
                    try await Task.sleep(for: .seconds(10))
                } catch {
                    return
                }
                if process.isRunning {
                    _ = Darwin.kill(process.processIdentifier, SIGKILL)
                }
            }
        }
        if Task.isCancelled {
            throw CancellationError()
        }
        guard status == 0 else {
            if status == -SIGINT {
                throw CancellationError()
            }
            throw DatabaseCLIError(
                .unavailable,
                "database-server exited with status \(status)"
            )
        }
    }
}

private actor DatabaseServerForegroundTermination {
    private var status: Int32?
    private var waiters: [CheckedContinuation<Int32, Never>] = []

    func finish(_ status: Int32) {
        guard self.status == nil else { return }
        self.status = status
        let waiters = waiters
        self.waiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume(returning: status)
        }
    }

    func wait() async -> Int32 {
        if let status { return status }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}
