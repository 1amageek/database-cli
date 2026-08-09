import DatabaseClientFramedStream
import DatabaseTypes
import Darwin
import Foundation
import NIOCore
import NIOPosix

actor LocalDatabaseServerProcessConnection:
    DatabaseFramedStreamConnection
{
    private struct ReadWaiter {
        let byteCount: Int
        let continuation: CheckedContinuation<
            Result<ByteString, DatabaseFramedStreamConnectionError>,
            Never
        >
    }

    private let process: Process
    private let channel: NIOAsyncChannel<ByteBuffer, ByteBuffer>
    private let termination: ProcessTerminationWaiter
    private var received = ByteBufferAllocator().buffer(capacity: 0)
    private var outbound: NIOAsyncChannelOutboundWriter<ByteBuffer>?
    private var outboundWaiters: [CheckedContinuation<
        Result<NIOAsyncChannelOutboundWriter<ByteBuffer>, DatabaseFramedStreamConnectionError>,
        Never
    >] = []
    private var readWaiter: ReadWaiter?
    private var terminalError: DatabaseFramedStreamConnectionError?
    private var lifecycleTask: Task<Void, Never>?
    private var shutdownRequested = false
    private var shutdownComplete = false
    private var shutdownWaiters: [CheckedContinuation<Void, Never>] = []

    static func launch(
        executable: DatabaseServerExecutable,
        arguments: [String]
    ) async throws -> LocalDatabaseServerProcessConnection {
        try await executable.validateVersion(expected: DatabaseCLIVersion.current)

        let process = Process()
        let standardInput = Pipe()
        let standardOutput = Pipe()
        let termination = ProcessTerminationWaiter()
        process.executableURL = executable.url
        process.arguments = arguments
        process.standardInput = standardInput
        process.standardOutput = standardOutput
        process.standardError = FileHandle.standardError
        process.terminationHandler = { process in
            let status = process.terminationReason == .exit
                ? process.terminationStatus
                : -process.terminationStatus
            Task { await termination.finish(status: status) }
        }

        do {
            try process.run()
        } catch {
            throw DatabaseCLIError(
                .unavailable,
                "Cannot start database-server: \(error)"
            )
        }

        standardInput.fileHandleForReading.closeFile()
        standardOutput.fileHandleForWriting.closeFile()

        let inputDescriptor = Darwin.dup(
            standardOutput.fileHandleForReading.fileDescriptor
        )
        guard inputDescriptor >= 0 else {
            standardInput.fileHandleForWriting.closeFile()
            standardOutput.fileHandleForReading.closeFile()
            process.terminate()
            _ = await termination.wait()
            throw DatabaseCLIError(
                .unavailable,
                "Cannot duplicate the database-server output descriptor"
            )
        }
        let outputDescriptor = Darwin.dup(
            standardInput.fileHandleForWriting.fileDescriptor
        )
        guard outputDescriptor >= 0 else {
            Darwin.close(inputDescriptor)
            standardInput.fileHandleForWriting.closeFile()
            standardOutput.fileHandleForReading.closeFile()
            process.terminate()
            _ = await termination.wait()
            throw DatabaseCLIError(
                .unavailable,
                "Cannot duplicate the database-server input descriptor"
            )
        }
        standardInput.fileHandleForWriting.closeFile()
        standardOutput.fileHandleForReading.closeFile()

        let channel: NIOAsyncChannel<ByteBuffer, ByteBuffer>
        do {
            channel = try await NIOPipeBootstrap(
                group: MultiThreadedEventLoopGroup.singleton
            ).takingOwnershipOfDescriptors(
                input: inputDescriptor,
                output: outputDescriptor
            ) { channel in
                channel.eventLoop.makeCompletedFuture {
                    try NIOAsyncChannel(
                        wrappingChannelSynchronously: channel
                    )
                }
            }
        } catch {
            Darwin.close(inputDescriptor)
            Darwin.close(outputDescriptor)
            process.terminate()
            _ = await termination.wait()
            throw DatabaseCLIError(
                .unavailable,
                "Cannot connect to database-server stdio: \(error)"
            )
        }

        let connection = LocalDatabaseServerProcessConnection(
            process: process,
            channel: channel,
            termination: termination
        )
        await connection.start()
        return connection
    }

    private init(
        process: Process,
        channel: NIOAsyncChannel<ByteBuffer, ByteBuffer>,
        termination: ProcessTerminationWaiter
    ) {
        self.process = process
        self.channel = channel
        self.termination = termination
    }

    func write(
        _ bytes: ByteString
    ) async throws(DatabaseFramedStreamConnectionError) {
        guard !bytes.isEmpty else { return }
        let writer = try await waitForOutbound()
        guard !shutdownRequested else { throw .cancelled }

        // NIO owns the outbound buffer until the asynchronous pipe write
        // completes, so the borrowed ByteString must be copied once at this
        // operating-system I/O boundary.
        var buffer = ByteBufferAllocator().buffer(capacity: bytes.count)
        _ = bytes.withUnsafeBytes { source in
            buffer.writeBytes(source)
        }
        do {
            try await writer.write(buffer)
        } catch is CancellationError {
            throw .cancelled
        } catch {
            if shutdownRequested {
                throw .cancelled
            }
            throw .unavailable("database-server stdio write failed")
        }
    }

    func readExactly(
        _ byteCount: Int
    ) async throws(DatabaseFramedStreamConnectionError) -> ByteString {
        guard byteCount >= 0 else {
            throw .unavailable("A negative stdio read length was requested")
        }
        guard byteCount > 0 else { return ByteString() }
        if received.readableBytes >= byteCount {
            return takeReceivedBytes(byteCount)
        }
        if let terminalError {
            throw endOfStreamError(
                terminalError,
                expectedByteCount: byteCount
            )
        }
        guard readWaiter == nil else {
            throw .unavailable("Concurrent database-server stdio reads are unsupported")
        }

        let result: Result<ByteString, DatabaseFramedStreamConnectionError> =
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if Task.isCancelled {
                        continuation.resume(returning: .failure(.cancelled))
                    } else {
                        readWaiter = ReadWaiter(
                            byteCount: byteCount,
                            continuation: continuation
                        )
                    }
                }
            } onCancel: {
                Task { await self.cancelOutstandingRead() }
            }
        return try result.get()
    }

    func shutdown() async {
        if shutdownRequested {
            guard !shutdownComplete else { return }
            await withCheckedContinuation { continuation in
                shutdownWaiters.append(continuation)
            }
            return
        }
        shutdownRequested = true
        failOutstandingOperations(with: .cancelled)
        outbound?.finish()
        do {
            try await channel.channel.close()
        } catch {
            // Closing an already inactive pipe is equivalent to a completed
            // local transport shutdown. Process termination remains the
            // authoritative completion boundary below.
        }
        if let lifecycleTask {
            await lifecycleTask.value
        }
        _ = await termination.wait()
        completeShutdown()
    }

    private func start() {
        lifecycleTask = Task { [weak self] in
            guard let self else { return }
            await self.consumeChannel()
        }
    }

    private func consumeChannel() async {
        var failure: DatabaseFramedStreamConnectionError?
        do {
            try await channel.executeThenClose(isolation: self) {
                inbound,
                outbound in
                install(outbound: outbound)
                for try await var chunk in inbound {
                    received.writeBuffer(&chunk)
                    fulfillReadIfPossible()
                }
            }
        } catch is CancellationError {
            failure = .cancelled
        } catch {
            failure = .unavailable("database-server stdio channel failed")
        }

        let status = await termination.wait()
        if failure == nil, status != 0 {
            failure = .unavailable(
                "database-server exited with status \(status)"
            )
        }
        terminalError = failure ?? .endOfStream(
            expectedByteCount: 1,
            actualByteCount: 0
        )
        failOutstandingOperations(with: terminalError ?? .cancelled)
    }

    private func install(
        outbound: NIOAsyncChannelOutboundWriter<ByteBuffer>
    ) {
        self.outbound = outbound
        let waiters = outboundWaiters
        outboundWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume(returning: .success(outbound))
        }
    }

    private func waitForOutbound() async throws(
        DatabaseFramedStreamConnectionError
    ) -> NIOAsyncChannelOutboundWriter<ByteBuffer> {
        if let outbound { return outbound }
        if let terminalError { throw terminalError }
        if shutdownRequested { throw .cancelled }
        let result: Result<
            NIOAsyncChannelOutboundWriter<ByteBuffer>,
            DatabaseFramedStreamConnectionError
        > = await withCheckedContinuation { continuation in
            outboundWaiters.append(continuation)
        }
        return try result.get()
    }

    private func fulfillReadIfPossible() {
        guard let readWaiter,
              received.readableBytes >= readWaiter.byteCount else {
            return
        }
        self.readWaiter = nil
        readWaiter.continuation.resume(
            returning: .success(takeReceivedBytes(readWaiter.byteCount))
        )
    }

    private func takeReceivedBytes(_ count: Int) -> ByteString {
        guard let slice = received.readSlice(length: count) else {
            preconditionFailure("Validated readable bytes became unavailable")
        }
        if received.readerIndex > 64 * 1_024,
           received.readableBytes < received.readerIndex {
            received.discardReadBytes()
        }
        return ByteString(retaining: NIOByteBufferOwner(buffer: slice))
    }

    private func cancelOutstandingRead() {
        guard let readWaiter else { return }
        self.readWaiter = nil
        readWaiter.continuation.resume(returning: .failure(.cancelled))
        Task { await self.shutdown() }
    }

    private func failOutstandingOperations(
        with error: DatabaseFramedStreamConnectionError
    ) {
        if let readWaiter {
            self.readWaiter = nil
            readWaiter.continuation.resume(
                returning: .failure(
                    endOfStreamError(
                        error,
                        expectedByteCount: readWaiter.byteCount
                    )
                )
            )
        }
        let waiters = outboundWaiters
        outboundWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume(returning: .failure(error))
        }
    }

    private func endOfStreamError(
        _ error: DatabaseFramedStreamConnectionError,
        expectedByteCount: Int
    ) -> DatabaseFramedStreamConnectionError {
        guard case .endOfStream = error else { return error }
        return .endOfStream(
            expectedByteCount: expectedByteCount,
            actualByteCount: received.readableBytes
        )
    }

    private func completeShutdown() {
        guard !shutdownComplete else { return }
        shutdownComplete = true
        let waiters = shutdownWaiters
        shutdownWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
        _ = process
    }
}

private struct NIOByteBufferOwner: ByteStringOwner {
    let buffer: ByteBuffer

    var count: Int { buffer.readableBytes }
    var retainedByteCount: Int? { buffer.capacity }
    var isStorageSelfContained: Bool {
        buffer.readerIndex == 0 && buffer.readableBytes == buffer.capacity
    }

    func borrowBytes(
        _ body: (UnsafeRawBufferPointer) throws -> Void
    ) rethrows {
        try buffer.withUnsafeReadableBytes(body)
    }
}

private actor ProcessTerminationWaiter {
    private var status: Int32?
    private var waiters: [CheckedContinuation<Int32, Never>] = []

    func finish(status: Int32) {
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
