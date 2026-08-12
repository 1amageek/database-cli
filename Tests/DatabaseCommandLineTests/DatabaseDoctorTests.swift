import DatabaseClient
import DatabaseKit
import DatabaseTypes
import DatabaseWire
import Foundation
import Synchronization
import Testing
@testable import DatabaseCommandLine

@Suite("Database doctor")
struct DatabaseDoctorTests {
    @Test("doctor uses read-only operations and never emits the credential")
    func doctorIsReadOnlyAndRedactsCredential() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(Foundation.UUID().uuidString)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let profileStore = ProfileStore(
            fileURL: directory.appendingPathComponent("profiles.json")
        )
        let profile = try DatabaseProfile(
            name: "doctor-test",
            endpoint: "https://database.test/v1/database",
            databaseID: "main"
        )
        try profileStore.save(
            ProfileDocument(
                activeProfile: profile.name,
                profiles: [profile]
            )
        )
        let resultURL = directory.appendingPathComponent("result.json")
        #expect(
            FileManager.default.createFile(
                atPath: resultURL.path,
                contents: nil
            )
        )
        let resultHandle = try FileHandle(forWritingTo: resultURL)
        let probe = DoctorProbeTransport()
        let credential = "doctor-secret-must-never-be-rendered"
        let application = DatabaseCLIApplication(
            profiles: profileStore,
            credentials: CredentialResolver(
                store: StaticCredentialStore(token: credential),
                environment: [:]
            ),
            output: OutputWriter(
                resultHandle: resultHandle,
                diagnosticHandle: .nullDevice
            ),
            networkProbe: PassingNetworkProbe(),
            sessionFactory: { _ in
                RemoteSession(
                    transport: AnyDatabaseTransport(probe) { _ in }
                )
            }
        )

        let exitCode = await application.run(arguments: ["doctor"])
        try resultHandle.close()
        let result = try String(
            contentsOf: resultURL,
            encoding: .utf8
        )

        #expect(exitCode == 0)
        #expect(!result.contains(credential))
        #expect(result.contains("security.credential"))
        #expect(result.contains("network.dns"))
        #expect(result.contains("network.tcp"))
        #expect(result.contains("network.tls"))
        #expect(result.contains("protocol.capabilities"))
        #expect(result.contains("database.schema"))
        #expect(
            probe.operations
                == [.capabilitiesDescribe, .schemaDescribe]
        )
        try FileManager.default.removeItem(at: directory)
    }
}

private struct PassingNetworkProbe: DatabaseNetworkProbing {
    func probe(_ endpoint: URL) async -> DatabaseNetworkProbeReport {
        _ = endpoint
        return DatabaseNetworkProbeReport(
            dns: .passed("DNS passed."),
            tcp: .passed("TCP passed."),
            tls: .passed("TLS passed.")
        )
    }
}

private struct StaticCredentialStore: CredentialStore {
    let token: String

    func read(profile: String) throws -> String? {
        token
    }

    func write(_ token: String, profile: String) throws {}

    func remove(profile: String) throws {}
}

private final class DoctorProbeTransport: DatabaseTransport, Sendable {
    private let state = Mutex<[DatabaseOperationIdentifier]>([])

    var operations: [DatabaseOperationIdentifier] {
        state.withLock { $0 }
    }

    func send(
        _ request: ByteString
    ) async throws(DatabaseTransportError) -> ByteString {
        do {
            let header = try DatabaseWireDecoder().decodeRequestHeader(request)
            state.withLock { $0.append(header.operation) }
            switch header.operation {
            case .capabilitiesDescribe:
                return try DatabaseWireEncoder().encodeResponse(
                    DatabaseOperationCatalog.capabilitiesDescribe,
                    requestID: header.requestID,
                    response: CapabilitiesDescribeOperation.Response(
                        runtimeVersion: "doctor-runtime",
                        features: [],
                        jobOperations: []
                    )
                )
            case .schemaDescribe:
                return try DatabaseWireEncoder().encodeResponse(
                    DatabaseOperationCatalog.schemaDescribe,
                    requestID: header.requestID,
                    response: SchemaDescribeOperation.Response(
                        version: Schema.Version(1, 0, 0),
                        entities: []
                    )
                )
            default:
                throw DatabaseTransportError.invalidResponse(
                    "Doctor attempted a non-read-only operation"
                )
            }
        } catch let error as DatabaseTransportError {
            throw error
        } catch {
            throw .invalidResponse(String(describing: error))
        }
    }
}
