import DatabaseClientFramedStream

struct LocalDatabaseSession: Sendable {
    let remoteSession: RemoteSession

    static func open(
        executable: DatabaseServerExecutable,
        path: String?,
        memory: Bool,
        maximumFrameBytes: Int
    ) async throws -> Self {
        var arguments = ["stdio"]
        if memory {
            arguments.append("--memory")
        } else if let path {
            arguments.append(contentsOf: ["--path", path])
        } else {
            throw DatabaseCLIError(
                .input,
                "database open requires a path or '--memory'"
            )
        }
        arguments.append(contentsOf: [
            "--maximum-frame-bytes",
            String(maximumFrameBytes),
        ])
        let connection = try await LocalDatabaseServerProcessConnection.launch(
            executable: executable,
            arguments: arguments
        )
        let transport = FramedStreamDatabaseTransport(
            configuration: try FramedStreamDatabaseConfiguration(
                maximumRequestBytes: maximumFrameBytes,
                maximumResponseBytes: maximumFrameBytes
            ),
            connection: connection
        )
        return Self(
            remoteSession: RemoteSession(
                transport: AnyDatabaseTransport(transport) { transport in
                    await transport.shutdown()
                }
            )
        )
    }

    func shutdown() async {
        await remoteSession.shutdown()
    }
}
