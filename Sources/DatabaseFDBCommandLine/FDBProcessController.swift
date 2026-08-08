import Darwin
import Foundation

enum FDBProcessController {
    static func waitForExit(
        _ process: Process,
        timeout: Duration
    ) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while process.isRunning, clock.now < deadline {
            try Task.checkCancellation()
            try await clock.sleep(for: .milliseconds(25))
        }
        return !process.isRunning
    }

    static func terminate(
        _ process: Process,
        gracePeriod: Duration = .seconds(1)
    ) async -> Bool {
        guard process.isRunning else { return true }
        process.terminate()
        if await waitIgnoringCancellation(process, timeout: gracePeriod) {
            return true
        }
        if process.isRunning {
            _ = kill(process.processIdentifier, SIGKILL)
        }
        return await waitIgnoringCancellation(process, timeout: .seconds(1))
    }

    private static func waitIgnoringCancellation(
        _ process: Process,
        timeout: Duration
    ) async -> Bool {
        await Task.detached {
            do {
                return try await waitForExit(process, timeout: timeout)
            } catch {
                return !process.isRunning
            }
        }.value
    }
}
