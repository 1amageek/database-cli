import DatabaseClientFramedStream

struct LocalDatabaseSession: Sendable {
    let remoteSession: RemoteSession

    static func open(
        executable: DatabaseServerInstallation,
        storage: StandaloneStorageSelection,
        maximumFrameBytes: Int
    ) async throws -> Self {
        var arguments = ["stdio"] + storage.serverArguments
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
