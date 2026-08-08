import DatabaseClient
import DatabaseClientHTTP
import DatabaseClientWebSocket
import DatabaseTypes
import DatabaseWire
import Foundation

public struct AnyDatabaseTransport: DatabaseTransport {
    private let transmission: @Sendable (
        ByteString
    ) async throws(DatabaseTransportError) -> ByteString
    private let shutdownOperation: @Sendable () async -> Void

    public init<Transport: DatabaseTransport>(
        _ transport: Transport,
        shutdown: @escaping @Sendable (Transport) async -> Void
    ) {
        let transmission: @Sendable (
            ByteString
        ) async throws(DatabaseTransportError) -> ByteString = { request in
            try await transport.send(request)
        }
        self.transmission = transmission
        self.shutdownOperation = {
            await shutdown(transport)
        }
    }

    public func send(
        _ request: ByteString
    ) async throws(DatabaseTransportError) -> ByteString {
        try await transmission(request)
    }

    public func shutdown() async {
        await shutdownOperation()
    }
}

public struct ResolvedConnection: Sendable {
    public let profileName: String
    public let endpoint: URL
    public let accessToken: String
    public let databaseID: String
    public let tenantID: String?
    public let workspaceID: String?

    public static func resolve(
        options: CommandOptions,
        profileStore: ProfileStore,
        credentials: CredentialResolver
    ) throws -> Self {
        let requestedProfile = options.value("profile")
        let profile: DatabaseProfile
        if requestedProfile != nil || options.value("endpoint") == nil {
            profile = try profileStore.selectedProfile(named: requestedProfile)
        } else {
            profile = try DatabaseProfile(
                name: "ephemeral",
                endpoint: options.value("endpoint")!,
                databaseID: options.value("database") ?? "main",
                tenantID: options.value("tenant"),
                workspaceID: options.value("workspace")
            )
        }
        let endpointText = options.value("endpoint") ?? profile.endpoint
        guard let endpoint = URL(string: endpointText) else {
            throw DatabaseCLIError(.input, "Endpoint URL is invalid")
        }
        return Self(
            profileName: profile.name,
            endpoint: endpoint,
            accessToken: try credentials.resolve(for: profile),
            databaseID: options.value("database") ?? profile.databaseID,
            tenantID: options.value("tenant") ?? profile.tenantID,
            workspaceID: options.value("workspace") ?? profile.workspaceID
        )
    }
}

public final class RemoteSession: Sendable {
    public let client: DatabaseClient<AnyDatabaseTransport>
    private let transport: AnyDatabaseTransport

    public init(connection: ResolvedConnection) throws {
        let scheme = connection.endpoint.scheme?.lowercased()
        switch scheme {
        case "http", "https":
            let concrete = HTTPDatabaseTransport(
                configuration: try HTTPDatabaseConfiguration(
                    endpoint: connection.endpoint,
                    accessToken: connection.accessToken,
                    databaseID: connection.databaseID,
                    tenantID: connection.tenantID,
                    workspaceID: connection.workspaceID
                )
            )
            self.transport = AnyDatabaseTransport(concrete) { transport in
                await transport.shutdown()
            }
        case "ws", "wss":
            let concrete = WebSocketDatabaseTransport(
                configuration: try WebSocketDatabaseConfiguration(
                    endpoint: connection.endpoint,
                    accessToken: connection.accessToken,
                    databaseID: connection.databaseID,
                    tenantID: connection.tenantID,
                    workspaceID: connection.workspaceID
                )
            )
            self.transport = AnyDatabaseTransport(concrete) { transport in
                await transport.shutdown()
            }
        default:
            throw DatabaseCLIError(
                .input,
                "Endpoint scheme must be http, https, ws, or wss"
            )
        }
        self.client = DatabaseClient(transport: self.transport)
    }

    /// Creates a session over an explicitly owned transport.
    ///
    /// This initializer is used by in-process runtimes and tests. The supplied
    /// transport remains responsible for its authoritative shutdown operation.
    public init(transport: AnyDatabaseTransport) {
        self.transport = transport
        self.client = DatabaseClient(transport: transport)
    }

    public func shutdown() async {
        await transport.shutdown()
    }
}
