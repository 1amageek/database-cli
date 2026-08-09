import DatabaseClient
import DatabaseKit
import DatabaseTypes
import DatabaseWire
import Foundation
import Synchronization
import Testing
@testable import DatabaseCommandLine

private struct OperationFixture: Sendable {
    let arguments: [String]
    let operation: DatabaseOperationIdentifier
}

private let operationFixtures: [OperationFixture] = [
    .init(arguments: ["capabilities"], operation: .capabilitiesDescribe),
    .init(arguments: ["schema", "list"], operation: .schemaDescribe),
    .init(
        arguments: ["schema", "plan", schemaJSON],
        operation: .schemaExecute
    ),
    .init(
        arguments: [
            "schema", "apply", schemaJSON,
            "--expected-fingerprint", emptyFingerprint,
            "--idempotency-key", "schema-1",
        ],
        operation: .schemaExecute
    ),
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
    .init(
        arguments: [
            "command", "run", "system.inspect",
            #"{"$type":"object","value":{}}"#,
        ],
        operation: .commandExecute
    ),
    .init(arguments: ["maintenance", "compact"], operation: .maintenanceExecute),
    .init(
        arguments: ["job", "status", jobID, "queryExecute", "query"],
        operation: .jobStatus
    ),
    .init(
        arguments: ["job", "result", jobID, "queryExecute", "query"],
        operation: .jobResult
    ),
    .init(
        arguments: ["job", "cancel", jobID, "queryExecute", "query"],
        operation: .jobCancel
    ),
]

private let jobID = "00000000-0000-0000-0000-000000000001"
private let schemaJSON = #"{"formatVersion":1,"schemaVersion":{"major":1,"minor":0,"patch":0},"entities":[]}"#
private let emptyFingerprint = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"

@Test("Schema plan and apply preserve the manifest and concurrency contract")
func schemaExecutionRequestContract() throws {
    let plan = try CommandParser().parse([
        "schema", "plan", schemaJSON,
        "--expected-fingerprint", emptyFingerprint,
    ])
    let planRequest = try WireRequestBuilder().schemaExecutionRequest(plan)
    guard case .plan(let planManifest, let planExpected) = planRequest.invocation else {
        Issue.record("Expected a schema plan request")
        return
    }
    #expect(planManifest.schema.version == SchemaVersion(1, 0, 0))
    #expect(planExpected?.bytes == ByteString(repeating: 0, count: 32))

    let apply = try CommandParser().parse([
        "schema", "apply", schemaJSON,
        "--expected-fingerprint", emptyFingerprint,
        "--idempotency-key", "schema-1",
    ])
    let applyRequest = try WireRequestBuilder().schemaExecutionRequest(apply)
    guard case .apply(
        let applyManifest,
        let applyExpected,
        let idempotencyKey
    ) = applyRequest.invocation else {
        Issue.record("Expected a schema apply request")
        return
    }
    #expect(applyManifest.schema.version == SchemaVersion(1, 0, 0))
    #expect(applyExpected.bytes == ByteString(repeating: 0, count: 32))
    #expect(idempotencyKey == "schema-1")
}

@Test("Open schema applies the fingerprint returned by its immediately preceding plan")
func openSchemaUsesPlanFingerprint() async throws {
    let probe = OpenSchemaProbeTransport()
    let session = RemoteSession(
        transport: AnyDatabaseTransport(probe) { _ in }
    )
    let application = DatabaseCLIApplication(
        output: OutputWriter(
            resultHandle: .nullDevice,
            diagnosticHandle: .nullDevice
        )
    )

    try await application.applySchema(schemaJSON, to: session)

    #expect(probe.operations == [.schemaExecute, .schemaExecute])
    #expect(probe.appliedPlanFingerprint)
    #expect(probe.metadataMatchedInvocation)
    await session.shutdown()
}

@Test("Every direct remote command uses its canonical wire operation", arguments: operationFixtures)
private func mapsDirectWireOperation(_ fixture: OperationFixture) async throws {
    let probe = OperationProbeTransport()
    let session = RemoteSession(
        transport: AnyDatabaseTransport(probe) { _ in }
    )
    let command = try CommandParser().parse(fixture.arguments)

    await #expect(throws: DatabaseClientError.self) {
        try await RemoteCommandExecutor(
            session: session,
            output: .discarded
        ).execute(command)
    }
    #expect(probe.operations == [fixture.operation])
    await session.shutdown()
}

@Test("As-job validates capabilities before using jobStart")
func mapsJobStartAfterCapabilityAdvertisement() async throws {
    let operation = try JobOperationIdentifier(
        family: .queryExecute,
        kind: "query"
    )
    let probe = OperationProbeTransport(advertisedJob: operation)
    let session = RemoteSession(
        transport: AnyDatabaseTransport(probe) { _ in }
    )
    let command = try CommandParser().parse([
        "query", "sql", "SELECT 1", "--as-job", "query",
    ])

    await #expect(throws: DatabaseClientError.self) {
        try await RemoteCommandExecutor(
            session: session,
            output: .discarded
        ).execute(command)
    }
    #expect(probe.operations == [.capabilitiesDescribe, .jobStart])
    await session.shutdown()
}

@Test("Inspect overview composes capabilities and schema without a new wire operation")
func inspectOverviewComposesReadOnlyOperations() async throws {
    let probe = OperationProbeTransport()
    let session = RemoteSession(
        transport: AnyDatabaseTransport(probe) { _ in }
    )
    let command = try CommandParser().parse(["inspect", "overview"])

    await #expect(throws: DatabaseClientError.self) {
        try await RemoteCommandExecutor(
            session: session,
            output: .discarded
        ).execute(command)
    }
    #expect(
        Set(probe.operations)
            == Set([.capabilitiesDescribe, .schemaDescribe])
    )
    await session.shutdown()
}

@Test("Inspect indexes composes schema and runtime maintenance status")
func inspectIndexesComposesReadOnlyOperations() async throws {
    let probe = OperationProbeTransport()
    let session = RemoteSession(
        transport: AnyDatabaseTransport(probe) { _ in }
    )
    let command = try CommandParser().parse(["inspect", "indexes"])

    await #expect(throws: DatabaseClientError.self) {
        try await RemoteCommandExecutor(
            session: session,
            output: .discarded
        ).execute(command)
    }
    #expect(
        Set(probe.operations)
            == Set([.schemaDescribe, .maintenanceExecute])
    )
    await session.shutdown()
}

private final class OperationProbeTransport: DatabaseTransport, Sendable {
    private struct State: Sendable {
        var operations: [DatabaseOperationIdentifier] = []
    }

    private let state = Mutex(State())
    private let advertisedJob: JobOperationIdentifier?

    init(advertisedJob: JobOperationIdentifier? = nil) {
        self.advertisedJob = advertisedJob
    }

    var operations: [DatabaseOperationIdentifier] {
        state.withLock { $0.operations }
    }

    func send(
        _ request: ByteString
    ) async throws(DatabaseTransportError) -> ByteString {
        do {
            let header = try DatabaseWireDecoder().decodeRequestHeader(request)
            state.withLock { $0.operations.append(header.operation) }
            if header.operation == .capabilitiesDescribe,
               let advertisedJob {
                return try DatabaseWireEncoder().encodeResponse(
                    DatabaseOperations.capabilitiesDescribe,
                    requestID: header.requestID,
                    response: CapabilitiesDescribeOperation.Response(
                        runtimeVersion: "operation-probe",
                        features: [],
                        jobOperations: [advertisedJob]
                    )
                )
            }
            return try DatabaseWireEncoder().encodeFailure(
                requestID: header.requestID,
                operation: header.operation,
                error: RemoteOperationError(
                    category: .internalFailure,
                    code: "OPERATION_PROBE",
                    message: "The operation reached the wire boundary",
                    retryability: .never
                )
            )
        } catch {
            throw .invalidResponse(String(describing: error))
        }
    }
}

private final class OpenSchemaProbeTransport: DatabaseTransport, Sendable {
    private struct State: Sendable {
        var operations: [DatabaseOperationIdentifier] = []
        var plannedManifest: SchemaManifest?
        var appliedPlanFingerprint = false
        var metadataMatchedInvocation = false
    }

    private let state = Mutex(State())

    var operations: [DatabaseOperationIdentifier] {
        state.withLock { $0.operations }
    }

    var appliedPlanFingerprint: Bool {
        state.withLock { $0.appliedPlanFingerprint }
    }

    var metadataMatchedInvocation: Bool {
        state.withLock { $0.metadataMatchedInvocation }
    }

    func send(
        _ request: ByteString
    ) async throws(DatabaseTransportError) -> ByteString {
        do {
            let decoded = try DatabaseWireDecoder().decodeRequest(
                DatabaseOperations.schemaExecute,
                from: request
            )
            state.withLock { $0.operations.append(.schemaExecute) }
            let currentFingerprint = try SchemaFingerprint(
                ByteString(repeating: 7, count: SchemaFingerprint.byteCount)
            )
            switch decoded.request.invocation {
            case .plan(let manifest, let expectedFingerprint):
                guard expectedFingerprint == nil else {
                    throw DatabaseCLIError(
                        .internalFailure,
                        "Open schema plan unexpectedly supplied a fingerprint"
                    )
                }
                state.withLock { $0.plannedManifest = manifest }
                return try DatabaseWireEncoder().encodeResponse(
                    DatabaseOperations.schemaExecute,
                    requestID: decoded.requestID,
                    response: .plan(
                        .init(
                            currentFingerprint: currentFingerprint,
                            targetFingerprint: try manifest.fingerprint(),
                            compatibility: .compatible,
                            issues: []
                        )
                    )
                )
            case .apply(
                let manifest,
                let expectedFingerprint,
                let idempotencyKey
            ):
                state.withLock { state in
                    state.appliedPlanFingerprint =
                        expectedFingerprint == currentFingerprint
                        && state.plannedManifest == manifest
                    state.metadataMatchedInvocation =
                        decoded.metadata.idempotencyKey == idempotencyKey
                }
                let targetFingerprint = try manifest.fingerprint()
                return try DatabaseWireEncoder().encodeResponse(
                    DatabaseOperations.schemaExecute,
                    requestID: decoded.requestID,
                    response: .applied(
                        .init(
                            previousFingerprint: currentFingerprint,
                            fingerprint: targetFingerprint,
                            schemaVersion: manifest.schema.version,
                            generation: 1
                        )
                    )
                )
            }
        } catch {
            throw .invalidResponse(String(describing: error))
        }
    }
}

private extension OutputWriter {
    static var discarded: OutputWriter {
        OutputWriter(
            resultHandle: .nullDevice,
            diagnosticHandle: .nullDevice
        )
    }
}
