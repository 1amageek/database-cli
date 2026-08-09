import CDatabaseCLIReadline
import Darwin
import Foundation
import Synchronization

final class ShellInputReader: Sendable {
    private enum Backend: Sendable {
        case interactive(InteractiveShellInputReader)
        case stream(StreamShellInputReader)
    }

    private let backend: Backend

    init(
        handle: FileHandle = .standardInput,
        terminalOutput: FileHandle = .standardError,
        maximumLineBytes: Int = 16 * 1_024 * 1_024
    ) throws {
        guard maximumLineBytes > 0 else {
            throw DatabaseCLIError(
                .input,
                "Shell maximum line bytes must be positive"
            )
        }
        if isatty(handle.fileDescriptor) == 1 {
            self.backend = .interactive(
                try InteractiveShellInputReader(
                    inputDescriptor: handle.fileDescriptor,
                    outputDescriptor: terminalOutput.fileDescriptor,
                    maximumLineBytes: maximumLineBytes
                )
            )
        } else {
            self.backend = .stream(
                StreamShellInputReader(
                    handle: handle,
                    maximumLineBytes: maximumLineBytes
                )
            )
        }
    }

    var rendersPrompt: Bool {
        if case .interactive = backend { return true }
        return false
    }

    func readLine(
        prompt: String,
        completions: [ShellCompletionEntry]
    ) async throws -> String? {
        switch backend {
        case .interactive(let reader):
            return try await reader.readLine(
                prompt: prompt,
                completions: completions
            )
        case .stream(let reader):
            return try await reader.readLine()
        }
    }

    func shutdown() async {
        switch backend {
        case .interactive(let reader):
            reader.shutdown()
        case .stream(let reader):
            await reader.shutdown()
        }
    }
}

private final class InteractiveShellInputReader: Sendable {
    private struct State: Sendable {
        var isReading = false
        var isShutdown = false
    }

    private let inputDescriptor: Int32
    private let outputDescriptor: Int32
    private let interruptReadDescriptor: Int32
    private let interruptWriteDescriptor: Int32
    private let maximumLineBytes: Int
    private let state = Mutex(State())

    init(
        inputDescriptor: Int32,
        outputDescriptor: Int32,
        maximumLineBytes: Int
    ) throws {
        var descriptors = [Int32](repeating: -1, count: 2)
        guard pipe(&descriptors) == 0 else {
            throw DatabaseCLIError(
                .unavailable,
                "Cannot create the interactive shell interrupt pipe: errno \(errno)"
            )
        }
        do {
            for descriptor in descriptors {
                guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0,
                      fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else {
                    throw DatabaseCLIError(
                        .unavailable,
                        "Cannot configure the interactive shell interrupt pipe: errno \(errno)"
                    )
                }
            }
        } catch {
            close(descriptors[0])
            close(descriptors[1])
            throw error
        }
        self.inputDescriptor = inputDescriptor
        self.outputDescriptor = outputDescriptor
        self.interruptReadDescriptor = descriptors[0]
        self.interruptWriteDescriptor = descriptors[1]
        self.maximumLineBytes = maximumLineBytes
    }

    deinit {
        close(interruptReadDescriptor)
        close(interruptWriteDescriptor)
    }

    func readLine(
        prompt: String,
        completions: [ShellCompletionEntry]
    ) async throws -> String? {
        let lineTask = Task.detached {
            self.readSynchronously(
                prompt: prompt,
                completions: completions
            )
        }
        guard let broker = InterruptibleCommand.broker else {
            return try await lineTask.value.get()
        }
        let sequence = await broker.snapshot()
        let outcome = await withTaskGroup(of: ShellInputOutcome.self) { group in
            group.addTask {
                .line(await lineTask.value)
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
            if case .interrupt = first {
                self.signalInterrupt()
            }
            group.cancelAll()
            return first
        }
        switch outcome {
        case .line(let result):
            return try result.get()
        case .interrupt:
            _ = await lineTask.value
            throw ShellInterrupt()
        case .cancelledWait:
            signalInterrupt()
            _ = await lineTask.value
            throw CancellationError()
        }
    }

    func shutdown() {
        let shouldInterrupt = state.withLock { state in
            state.isShutdown = true
            return state.isReading
        }
        if shouldInterrupt { signalInterrupt() }
    }

    private func readSynchronously(
        prompt: String,
        completions: [ShellCompletionEntry]
    ) -> Result<String?, DatabaseCLIError> {
        let mayRead = state.withLock { state in
            guard !state.isShutdown, !state.isReading else { return false }
            state.isReading = true
            return true
        }
        guard mayRead else {
            return .failure(
                DatabaseCLIError(.cancelled, "Shell input is not available")
            )
        }
        defer {
            state.withLock { $0.isReading = false }
        }
        guard completions.count <= 16_384 else {
            return .failure(
                DatabaseCLIError(
                    .resourceLimit,
                    "Shell completion entry limit exceeded"
                )
            )
        }
        let completionBytes = completions.reduce(into: 0) {
            $0 += $1.context.utf8.count + $1.value.utf8.count
        }
        guard completionBytes <= 4 * 1_024 * 1_024 else {
            return .failure(
                DatabaseCLIError(
                    .resourceLimit,
                    "Shell completion byte limit exceeded"
                )
            )
        }

        return prompt.withCString { promptPointer in
            guard let session = database_cli_readline_session_create(
                inputDescriptor,
                outputDescriptor,
                interruptReadDescriptor,
                promptPointer
            ) else {
                return .failure(
                    DatabaseCLIError(
                        .unavailable,
                        "Cannot initialize interactive shell input: errno \(errno)"
                    )
                )
            }
            defer { database_cli_readline_session_destroy(session) }
            for completion in completions {
                let status = completion.context.withCString { context in
                    completion.value.withCString { value in
                        database_cli_readline_session_add_completion(
                            session,
                            context,
                            value
                        )
                    }
                }
                guard status == 0 else {
                    return .failure(
                        DatabaseCLIError(
                            .resourceLimit,
                            "Cannot prepare shell completions: errno \(-status)"
                        )
                    )
                }
            }

            var linePointer: UnsafeMutablePointer<CChar>?
            let status = database_cli_readline_session_read(
                session,
                &linePointer
            )
            switch status {
            case DATABASE_CLI_READLINE_LINE.rawValue:
                guard let linePointer else {
                    return .failure(
                        DatabaseCLIError(
                            .internalFailure,
                            "Interactive shell returned no line"
                        )
                    )
                }
                defer { database_cli_readline_free_line(linePointer) }
                guard let line = String(validatingCString: linePointer) else {
                    return .failure(
                        DatabaseCLIError(
                            .input,
                            "Shell input line is not UTF-8"
                        )
                    )
                }
                guard line.utf8.count <= maximumLineBytes else {
                    return .failure(
                        DatabaseCLIError(
                            .resourceLimit,
                            "Shell input line exceeds \(maximumLineBytes) bytes"
                        )
                    )
                }
                return .success(line)
            case DATABASE_CLI_READLINE_END_OF_FILE.rawValue:
                return .success(nil)
            case DATABASE_CLI_READLINE_INTERRUPTED.rawValue:
                return .failure(
                    DatabaseCLIError(.cancelled, "Shell input interrupted")
                )
            default:
                return .failure(
                    DatabaseCLIError(
                        .unavailable,
                        "Interactive shell input failed with status \(status)"
                    )
                )
            }
        }
    }

    private func signalInterrupt() {
        var byte: UInt8 = 1
        _ = withUnsafeBytes(of: &byte) { bytes in
            write(interruptWriteDescriptor, bytes.baseAddress, bytes.count)
        }
    }
}

private final class StreamShellInputReader: Sendable {
    private let buffer: ShellInputBuffer
    private let producer: Task<Void, Never>

    init(
        handle: FileHandle,
        maximumLineBytes: Int
    ) {
        let buffer = ShellInputBuffer(maximumLineBytes: maximumLineBytes)
        let descriptor = handle.fileDescriptor
        self.buffer = buffer
        // The detached task owns no pointer or descriptor. Each pointer borrow
        // is stack-scoped to poll/read, and shutdown joins after a bounded poll.
        self.producer = Task.detached {
            var storage = [UInt8](repeating: 0, count: 4_096)
            while !Task.isCancelled {
                var descriptorState = pollfd(
                    fd: descriptor,
                    events: Int16(POLLIN | POLLHUP),
                    revents: 0
                )
                let pollResult = poll(&descriptorState, 1, 100)
                if pollResult == 0 { continue }
                if pollResult < 0 {
                    if errno == EINTR { continue }
                    await buffer.fail(DatabaseCLIError(
                        .unavailable,
                        "Shell input polling failed with errno \(errno)"
                    ))
                    return
                }
                let byteCount = storage.withUnsafeMutableBytes { bytes in
                    read(descriptor, bytes.baseAddress, bytes.count)
                }
                if byteCount == 0 {
                    await buffer.finish()
                    return
                }
                if byteCount < 0 {
                    if errno == EINTR || errno == EAGAIN { continue }
                    await buffer.fail(DatabaseCLIError(
                        .unavailable,
                        "Shell input read failed with errno \(errno)"
                    ))
                    return
                }
                await buffer.append(storage.prefix(byteCount))
            }
            await buffer.cancel()
        }
    }

    func readLine() async throws -> String? {
        guard let broker = InterruptibleCommand.broker else {
            return try await buffer.nextLine().get()
        }
        let sequence = await broker.snapshot()
        let outcome = await withTaskGroup(of: ShellInputOutcome.self) { group in
            group.addTask {
                .line(await self.buffer.nextLine())
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
        case .line(let result):
            return try result.get()
        case .interrupt:
            await buffer.clearCurrentLine()
            throw ShellInterrupt()
        case .cancelledWait:
            throw CancellationError()
        }
    }

    func shutdown() async {
        producer.cancel()
        _ = await producer.result
        await buffer.cancel()
    }
}

private enum ShellInputOutcome: Sendable {
    case line(Result<String?, DatabaseCLIError>)
    case interrupt
    case cancelledWait
}

private actor ShellInputBuffer {
    private struct Waiter {
        let continuation: CheckedContinuation<
            Result<String?, DatabaseCLIError>,
            Never
        >
    }

    private let maximumLineBytes: Int
    private var current: [UInt8] = []
    private var ready: [Result<String?, DatabaseCLIError>] = []
    private var waiters: [UUID: Waiter] = [:]
    private var isFinished = false

    init(maximumLineBytes: Int) {
        self.maximumLineBytes = maximumLineBytes
        current.reserveCapacity(min(maximumLineBytes, 4_096))
    }

    func append(_ bytes: ArraySlice<UInt8>) {
        for byte in bytes { append(byte) }
    }

    private func append(_ byte: UInt8) {
        guard !isFinished else { return }
        if byte == 0x0a {
            if current.last == 0x0d { current.removeLast() }
            emitCurrentLine()
            return
        }
        guard current.count < maximumLineBytes else {
            current.removeAll(keepingCapacity: true)
            emit(.failure(DatabaseCLIError(
                .resourceLimit,
                "Shell input line exceeds \(maximumLineBytes) bytes"
            )))
            return
        }
        current.append(byte)
    }

    func clearCurrentLine() {
        current.removeAll(keepingCapacity: true)
    }

    func finish() {
        guard !isFinished else { return }
        if !current.isEmpty { emitCurrentLine() }
        isFinished = true
        emit(.success(nil))
    }

    func fail(_ error: DatabaseCLIError) {
        guard !isFinished else { return }
        isFinished = true
        emit(.failure(error))
    }

    func cancel() {
        guard !isFinished else { return }
        isFinished = true
        emit(.failure(DatabaseCLIError(.cancelled, "Shell input cancelled")))
    }

    func nextLine() async -> Result<String?, DatabaseCLIError> {
        if !ready.isEmpty { return ready.removeFirst() }
        if isFinished { return .success(nil) }
        let identifier = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if !ready.isEmpty {
                    continuation.resume(returning: ready.removeFirst())
                } else if isFinished {
                    continuation.resume(returning: .success(nil))
                } else {
                    waiters[identifier] = Waiter(continuation: continuation)
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(identifier) }
        }
    }

    private func emitCurrentLine() {
        let bytes = current
        current.removeAll(keepingCapacity: true)
        guard let line = String(bytes: bytes, encoding: .utf8) else {
            emit(.failure(DatabaseCLIError(
                .input,
                "Shell input line is not UTF-8"
            )))
            return
        }
        emit(.success(line))
    }

    private func emit(_ value: Result<String?, DatabaseCLIError>) {
        if let entry = waiters.first {
            waiters.removeValue(forKey: entry.key)
            entry.value.continuation.resume(returning: value)
        } else {
            ready.append(value)
        }
    }

    private func cancelWaiter(_ identifier: UUID) {
        waiters.removeValue(forKey: identifier)?.continuation.resume(
            returning: .failure(
                DatabaseCLIError(.cancelled, "Shell input wait cancelled")
            )
        )
    }
}
