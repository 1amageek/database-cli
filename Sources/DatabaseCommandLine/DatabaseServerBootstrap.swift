import Foundation

struct DatabaseServerBootstrap: Sendable {
    struct Request: Sendable {
        let configurationURL: URL
        let storageArguments: [String]
        let host: String?
        let port: Int?
        let databaseID: String
        let tenantID: String?
        let workspaceID: String?
    }

    struct Response: Sendable {
        let createdCredential: Bool
        let token: String?
        let endpoint: String
        let databaseID: String
        let tenantID: String?
        let workspaceID: String?
    }

    let executable: DatabaseServerExecutable

    func prepare(
        request: Request,
        onPrepared: (Response) throws -> Void
    ) async throws -> Response {
        try await executable.validateVersion(expected: DatabaseCLIVersion.current)
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let diagnostic = Pipe()
        let termination = DatabaseServerChildTermination()
        process.executableURL = executable.url
        process.arguments = arguments(for: request)
        process.standardInput = input
        process.standardOutput = output
        process.standardError = diagnostic
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
                "Cannot start database-server bootstrap: \(error)"
            )
        }
        input.fileHandleForReading.closeFile()
        output.fileHandleForWriting.closeFile()
        diagnostic.fileHandleForWriting.closeFile()

        async let diagnosticData = readBounded(
            diagnostic.fileHandleForReading,
            maximumBytes: 4_096
        )
        do {
            let response = try await readResponse(
                output.fileHandleForReading
            )
            do {
                try onPrepared(response)
            } catch {
                if response.createdCredential {
                    try writeAcknowledgement(
                        accepted: false,
                        to: input.fileHandleForWriting
                    )
                }
                input.fileHandleForWriting.closeFile()
                _ = await termination.wait()
                _ = try await diagnosticData
                throw error
            }
            if response.createdCredential {
                try writeAcknowledgement(
                    accepted: true,
                    to: input.fileHandleForWriting
                )
            }
            input.fileHandleForWriting.closeFile()
            let status = await termination.wait()
            let diagnostics = try await diagnosticData
            guard status == 0 else {
                throw DatabaseCLIError(
                    .unavailable,
                    "database-server bootstrap failed: \(safeDiagnostic(diagnostics))"
                )
            }
            return response
        } catch {
            input.fileHandleForWriting.closeFile()
            if process.isRunning { process.terminate() }
            _ = await termination.wait()
            throw error
        }
    }

    private func arguments(for request: Request) -> [String] {
        var arguments = [
            "bootstrap",
            "--config", request.configurationURL.path,
            "--database", request.databaseID,
        ]
        arguments.append(contentsOf: request.storageArguments)
        if let host = request.host {
            arguments.append(contentsOf: ["--host", host])
        }
        if let port = request.port {
            arguments.append(contentsOf: ["--port", String(port)])
        }
        if let tenantID = request.tenantID {
            arguments.append(contentsOf: ["--tenant", tenantID])
        }
        if let workspaceID = request.workspaceID {
            arguments.append(contentsOf: ["--workspace", workspaceID])
        }
        return arguments
    }

    private func readResponse(_ handle: FileHandle) async throws -> Response {
        let data = try await Task.detached {
            defer { handle.closeFile() }
            let prefix = try readExactly(4, from: handle)
            let length = prefix.reduce(UInt32(0)) {
                ($0 << 8) | UInt32($1)
            }
            guard length > 0, length <= 16 * 1_024 else {
                throw DatabaseCLIError(
                    .unavailable,
                    "database-server bootstrap response length is invalid"
                )
            }
            return try readExactly(Int(length), from: handle)
        }.value
        guard let text = String(data: data, encoding: .utf8) else {
            throw DatabaseCLIError(
                .unavailable,
                "database-server bootstrap response is not UTF-8"
            )
        }
        let object = try StrictJSONObject(
            StrictJSONParser(maximumBytes: 16 * 1_024).parse(text)
        )
        try object.validateKeys([
            "formatVersion", "createdCredential", "token", "endpoint",
            "databaseID", "tenantID", "workspaceID",
        ])
        guard try object.required("formatVersion")
            .number(named: "formatVersion") == "1" else {
            throw DatabaseCLIError(
                .unavailable,
                "database-server bootstrap protocol version is unsupported"
            )
        }
        let createdCredential = try object.required("createdCredential")
            .bool(named: "createdCredential")
        let token = try optionalString(object.required("token"), name: "token")
        guard createdCredential == (token != nil) else {
            throw DatabaseCLIError(
                .unavailable,
                "database-server bootstrap credential response is inconsistent"
            )
        }
        let endpoint = try object.required("endpoint").string(named: "endpoint")
        guard let endpointURL = URL(string: endpoint),
              ["http", "https"].contains(endpointURL.scheme?.lowercased()),
              endpointURL.host != nil else {
            throw DatabaseCLIError(
                .unavailable,
                "database-server bootstrap endpoint is invalid"
            )
        }
        return Response(
            createdCredential: createdCredential,
            token: token,
            endpoint: endpoint,
            databaseID: try object.required("databaseID")
                .string(named: "databaseID"),
            tenantID: try optionalString(
                object.required("tenantID"),
                name: "tenantID"
            ),
            workspaceID: try optionalString(
                object.required("workspaceID"),
                name: "workspaceID"
            )
        )
    }

    private func optionalString(
        _ value: StrictJSONValue,
        name: String
    ) throws -> String? {
        if case .null = value { return nil }
        return try value.string(named: name)
    }

    private func writeAcknowledgement(
        accepted: Bool,
        to handle: FileHandle
    ) throws {
        try handle.write(contentsOf: Data([accepted ? 1 : 0]))
    }

    private func readBounded(
        _ handle: FileHandle,
        maximumBytes: Int
    ) async throws -> Data {
        try await Task.detached {
            defer { handle.closeFile() }
            let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
            return Data(data.prefix(maximumBytes))
        }.value
    }

    private func safeDiagnostic(_ data: Data) -> String {
        String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? "non-UTF-8 diagnostic"
    }
}

private func readExactly(
    _ count: Int,
    from handle: FileHandle
) throws -> Data {
    var result = Data()
    result.reserveCapacity(count)
    while result.count < count {
        guard let chunk = try handle.read(upToCount: count - result.count),
              !chunk.isEmpty else {
            throw DatabaseCLIError(
                .unavailable,
                "database-server bootstrap response was truncated"
            )
        }
        result.append(chunk)
    }
    return result
}

private actor DatabaseServerChildTermination {
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
