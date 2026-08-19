import DatabaseClient
import DatabaseKit
import DatabaseTypes
import DatabaseWire
import Foundation
import Synchronization
import Testing
@testable import DatabaseCommandLine

#if !DATABASE_CLI_MULTI_BASE
private struct SingleDatabaseOperationFixture: Sendable {
    let arguments: [String]
    let operation: DatabaseOperationIdentifier
}

private let singleDatabaseOperationFixtures: [SingleDatabaseOperationFixture] = [
    .init(arguments: ["capabilities"], operation: .capabilitiesDescribe),
    .init(arguments: ["schema", "list"], operation: .schemaDescribe),
    .init(arguments: ["schema", "plan", schemaJSON], operation: .schemaExecute),
    .init(arguments: ["inspect", "entities"], operation: .schemaDescribe),
    .init(arguments: ["inspect", "graph"], operation: .schemaDescribe),
    .init(arguments: ["inspect", "jobs"], operation: .capabilitiesDescribe),
    .init(arguments: ["inspect", "ontology", "world"], operation: .ontologyExecute),
    .init(arguments: ["inspect", "shapes", "urn:shapes"], operation: .shaclExecute),
    .init(arguments: ["query", "sql", "SELECT 1"], operation: .queryExecute),
    .init(arguments: ["mutate", "sparql", "CLEAR DEFAULT"], operation: .mutationExecute),
    .init(arguments: ["graph", "page-rank", "--index", "social"], operation: .graphAlgorithm),
    .init(arguments: ["ontology", "describe", "world"], operation: .ontologyExecute),
    .init(arguments: ["shacl", "describe", "urn:shapes"], operation: .shaclExecute),
    .init(arguments: ["command", "run", "system.inspect", emptyObject], operation: .commandExecute),
    .init(arguments: ["maintenance", "compact"], operation: .maintenanceExecute),
    .init(arguments: ["job", "status", jobID, "queryExecute", "query"], operation: .jobStatus),
    .init(arguments: ["job", "result", jobID, "queryExecute", "query"], operation: .jobResult),
    .init(arguments: ["job", "cancel", jobID, "queryExecute", "query"], operation: .jobCancel),
]

private let jobID = "00000000-0000-0000-0000-000000000001"
private let schemaJSON = #"{"formatVersion":2,"schemaVersion":{"major":1,"minor":0,"patch":0},"entities":[]}"#
private let emptyObject = #"{"$type":"object","value":{}}"#

@Test(
    "Every single-database remote command uses its canonical wire operation",
    arguments: singleDatabaseOperationFixtures
)
private func mapsSingleDatabaseWireOperation(
    _ fixture: SingleDatabaseOperationFixture
) async throws {
    let probe = SingleDatabaseOperationProbeTransport()
    let session = RemoteSession(
        transport: AnyDatabaseTransport(probe) { _ in }
    )
    let command = try CommandParser().parse(fixture.arguments)

    await #expect(throws: DatabaseClientError.self) {
        try await RemoteCommandExecutor(
            session: session,
            output: singleDatabaseDiscardedOutput
        ).execute(command)
    }
    #expect(probe.operations == [fixture.operation])
    await session.shutdown()
}

@Test("Single-database job start follows capability advertisement")
func mapsSingleDatabaseJobStart() async throws {
    let operation = try JobOperationIdentifier(
        family: .queryExecute,
        kind: "query"
    )
    let probe = SingleDatabaseOperationProbeTransport(advertisedJob: operation)
    let session = RemoteSession(
        transport: AnyDatabaseTransport(probe) { _ in }
    )
    let command = try CommandParser().parse([
        "query", "sql", "SELECT 1", "--as-job", "query",
    ])

    await #expect(throws: DatabaseClientError.self) {
        try await RemoteCommandExecutor(
            session: session,
            output: singleDatabaseDiscardedOutput
        ).execute(command)
    }
    #expect(probe.operations == [.capabilitiesDescribe, .jobStart])
    await session.shutdown()
}

@Test("Single-database schema apply preserves its concurrency contract")
func singleDatabaseSchemaApplyRequestContract() throws {
    let command = try CommandParser().parse([
        "schema", "apply", schemaJSON,
        "--expected-fingerprint",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "--idempotency-key", "schema-1",
    ])
    let request = try WireRequestBuilder().schemaExecutionRequest(command)
    guard case .apply(
        let manifest,
        let fingerprint,
        let idempotencyKey
    ) = request.invocation else {
        Issue.record("Expected a schema apply request")
        return
    }
    #expect(manifest.schema.version == SchemaVersion(1, 0, 0))
    #expect(fingerprint.bytes == ByteString(repeating: 0, count: 32))
    #expect(idempotencyKey == "schema-1")
}

private final class SingleDatabaseOperationProbeTransport:
    DatabaseTransport,
    Sendable {
    private let state = Mutex<[DatabaseOperationIdentifier]>([])
    private let advertisedJob: JobOperationIdentifier?

    init(advertisedJob: JobOperationIdentifier? = nil) {
        self.advertisedJob = advertisedJob
    }

    var operations: [DatabaseOperationIdentifier] {
        state.withLock { $0 }
    }

    func send(
        _ request: ByteString
    ) async throws(DatabaseTransportError) -> ByteString {
        do {
            let envelope = try DatabaseWireDecoder().decodeRequestEnvelope(request)
            state.withLock { $0.append(envelope.operation) }
            if envelope.operation == .capabilitiesDescribe,
               let advertisedJob {
                return try DatabaseWireEncoder().encodeResponse(
                    DatabaseOperationCatalog.capabilitiesDescribe,
                    requestID: envelope.requestID,
                    response: CapabilitiesDescribeOperation.Response(
                        runtimeVersion: "single-database-probe",
                        features: [],
                        jobOperations: [advertisedJob]
                    )
                )
            }
            return try DatabaseWireEncoder().encodeFailure(
                requestID: envelope.requestID,
                operation: envelope.operation,
                error: RemoteOperationError(
                    category: .internalFailure,
                    code: "SINGLE_DATABASE_PROBE",
                    message: "The operation reached the wire boundary",
                    retryability: .never
                )
            )
        } catch {
            throw .invalidResponse(String(describing: error))
        }
    }
}

private let singleDatabaseDiscardedOutput = OutputWriter(
    resultHandle: .nullDevice,
    diagnosticHandle: .nullDevice
)
#endif
