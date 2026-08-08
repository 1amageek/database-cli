import CDatabaseCLISignals
import Foundation

public enum InterruptibleCommand {
    @TaskLocal static var broker: InterruptBroker?

    public static func run(
        cancelOperationOnInterrupt: Bool = true,
        operation: @escaping @Sendable () async -> Int32
    ) async -> Int32 {
        let descriptor = database_cli_begin_interrupt_monitoring()
        guard descriptor >= 0 else {
            FileHandle.standardError.write(
                Data("error: Cannot install SIGINT monitoring (\(descriptor))\n".utf8)
            )
            return DatabaseCLIExitCode.internalFailure.rawValue
        }

        let broker = InterruptBroker()
        return await Self.$broker.withValue(broker) {
            let handle = FileHandle(
                fileDescriptor: descriptor,
                closeOnDealloc: false
            )
            let operationTask = Task { await operation() }
            let interruptTask = Task {
                do {
                    for try await _ in handle.bytes {
                        await broker.publish()
                        if cancelOperationOnInterrupt {
                            operationTask.cancel()
                            return
                        }
                    }
                } catch {
                    operationTask.cancel()
                }
            }

            let result = await operationTask.value
            let endResult = database_cli_end_interrupt_monitoring()
            _ = await interruptTask.result

            do {
                try handle.close()
            } catch {
                FileHandle.standardError.write(
                    Data("error: Cannot close SIGINT monitor: \(error)\n".utf8)
                )
                return DatabaseCLIExitCode.internalFailure.rawValue
            }
            guard endResult == 0 else {
                FileHandle.standardError.write(
                    Data("error: Cannot restore SIGINT handling (\(endResult))\n".utf8)
                )
                return DatabaseCLIExitCode.internalFailure.rawValue
            }
            return result
        }
    }
}

extension InterruptibleCommand {
    static func interruptSequence() async -> UInt64 {
        guard let broker else { return 0 }
        return await broker.snapshot()
    }

    static func wasInterrupted(after sequence: UInt64) async -> Bool {
        guard let broker else { return false }
        return await broker.snapshot() > sequence
    }

    static func runShellOperation(
        _ operation: @escaping @Sendable () async throws -> Void
    ) async throws {
        guard let broker else {
            try await operation()
            return
        }
        let sequence = await broker.snapshot()
        let outcome = await withTaskGroup(of: ShellRaceOutcome.self) { group in
            group.addTask {
                do {
                    try await operation()
                    return .operation(.success(()))
                } catch {
                    return .operation(.failure(DatabaseCLIError.map(error)))
                }
            }
            group.addTask {
                do {
                    try await broker.wait(after: sequence)
                    return .interrupt
                } catch {
                    return .cancelledWait
                }
            }
            let first = await group.next() ?? .cancelledWait
            group.cancelAll()
            return first
        }

        switch outcome {
        case .interrupt:
            throw ShellInterrupt()
        case .operation(.success):
            return
        case .operation(.failure(let error)):
            throw error
        case .cancelledWait:
            throw CancellationError()
        }
    }
}

struct ShellInterrupt: Error, Sendable {}

private enum ShellRaceOutcome: Sendable {
    case operation(Result<Void, DatabaseCLIError>)
    case interrupt
    case cancelledWait
}

actor InterruptBroker {
    private struct Waiter {
        let sequence: UInt64
        let continuation: CheckedContinuation<Void, Never>
    }

    private var sequence: UInt64 = 0
    private var waiters: [UUID: Waiter] = [:]

    func snapshot() -> UInt64 { sequence }

    func publish() {
        sequence &+= 1
        let ready = waiters.filter { $0.value.sequence < sequence }
        for (identifier, waiter) in ready {
            waiters.removeValue(forKey: identifier)
            waiter.continuation.resume()
        }
    }

    func wait(after observedSequence: UInt64) async throws {
        try Task.checkCancellation()
        if sequence > observedSequence { return }
        let identifier = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if sequence > observedSequence {
                    continuation.resume()
                } else {
                    waiters[identifier] = Waiter(
                        sequence: observedSequence,
                        continuation: continuation
                    )
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(identifier) }
        }
        try Task.checkCancellation()
    }

    private func cancelWaiter(_ identifier: UUID) {
        waiters.removeValue(forKey: identifier)?.continuation.resume()
    }
}
