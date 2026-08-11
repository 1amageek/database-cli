import DatabaseClient
import DatabaseKit
import DatabaseTypes
import DatabaseWire
import Foundation
import Synchronization
import Testing
@testable import DatabaseCommandLine

private struct OperationFixture: Sendable {
    enum Target: Sendable {
        case database
        case base(String)
        case composition(String)
    }

    let arguments: [String]
    let operation: DatabaseOperationIdentifier
    let target: Target
}

private let operationFixtures: [OperationFixture] = [
    .init(arguments: ["capabilities"], operation: .capabilitiesDescribe, target: .database),
    .init(arguments: ["schema", "list"], operation: .schemaDescribe, target: .database),
    .init(
        arguments: ["schema", "plan", schemaJSON],
        operation: .schemaExecute,
        target: .database
    ),
    .init(
        arguments: [
            "schema", "apply", schemaJSON,
            "--expected-fingerprint", emptyFingerprint,
            "--idempotency-key", "schema-1",
        ],
        operation: .schemaExecute,
        target: .database
    ),
    .init(arguments: ["base", "describe", "company-a"], operation: .baseExecute, target: .base("company-a")),
    .init(arguments: ["composition", "describe", "shared"], operation: .compositionExecute, target: .composition("shared")),
    .init(arguments: ["grant", "effective", "--base", "company-a"], operation: .grantExecute, target: .base("company-a")),
    .init(arguments: ["inspect", "entities"], operation: .schemaDescribe, target: .database),
    .init(arguments: ["inspect", "graph"], operation: .schemaDescribe, target: .database),
    .init(arguments: ["inspect", "jobs"], operation: .capabilitiesDescribe, target: .database),
    .init(arguments: ["inspect", "ontology", "world", "--base", "company-a"], operation: .ontologyExecute, target: .base("company-a")),
    .init(arguments: ["inspect", "shapes", "urn:shapes", "--base", "company-a"], operation: .shaclExecute, target: .base("company-a")),
    .init(arguments: ["query", "sql", "SELECT 1"], operation: .queryExecute, target: .database),
    .init(arguments: ["mutate", "sparql", "CLEAR DEFAULT", "--base", "company-a"], operation: .mutationExecute, target: .base("company-a")),
    .init(arguments: ["graph", "page-rank", "--index", "social", "--base", "company-a"], operation: .graphAlgorithm, target: .base("company-a")),
    .init(arguments: ["ontology", "describe", "world", "--base", "company-a"], operation: .ontologyExecute, target: .base("company-a")),
    .init(arguments: ["shacl", "describe", "urn:shapes", "--base", "company-a"], operation: .shaclExecute, target: .base("company-a")),
    .init(
        arguments: [
            "command", "run", "system.inspect",
            #"{"$type":"object","value":{}}"#,
            "--base", "company-a",
        ],
        operation: .commandExecute,
        target: .base("company-a")
    ),
    .init(arguments: ["maintenance", "compact", "--base", "company-a"], operation: .maintenanceExecute, target: .base("company-a")),
    .init(
        arguments: ["job", "status", jobID, "queryExecute", "query"],
        operation: .jobStatus,
        target: .database
    ),
    .init(
        arguments: ["job", "result", jobID, "queryExecute", "query", "--base", "company-a"],
        operation: .jobResult,
        target: .base("company-a")
    ),
    .init(
        arguments: ["job", "cancel", jobID, "queryExecute", "query", "--base", "company-a"],
        operation: .jobCancel,
        target: .base("company-a")
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

@Test("Base creation preserves placement, revision, idempotency, and canonical initial Grants")
func baseCreationRequestContract() throws {
    let command = try CommandParser().parse([
        "base", "create", "company-a",
        "--placement", "primary",
        "--initial-grant", "role:operator=read,administer",
        "--initial-grant", "principal:alice=read,write",
        "--expected-revision", "0",
        "--idempotency-key", "base-create-1",
    ])
    let builder = WireRequestBuilder()
    let request = try builder.baseExecutionRequest(command)

    guard case .create(
        let baseID,
        let placementID,
        let grants,
        let revision,
        let key
    ) = request.invocation else {
        Issue.record("Expected Base creation")
        return
    }
    #expect(try builder.operationTarget(command) == .database)
    #expect(baseID == (try Base.ID("company-a")))
    #expect(placementID == (try Base.Placement.ID("primary")))
    #expect(revision == 0)
    #expect(key == "base-create-1")
    #expect(grants.map(\.subject) == [
        .principal("alice"),
        .principalRole("operator"),
    ])
    #expect(grants[0].access == [.read, .write])
    #expect(grants[1].access == [.read, .administer])
}

@Test("Composition members are canonical and duplicate members are rejected")
func compositionRequestContract() throws {
    let parser = CommandParser()
    let command = try parser.parse([
        "composition", "create", "shared",
        "--base", "company-b",
        "--base", "company-a",
        "--expected-revision", "0",
        "--idempotency-key", "composition-create-1",
    ])
    let builder = WireRequestBuilder()
    let request = try builder.compositionExecutionRequest(command)
    guard case .create(let composition, let revision, let key) = request.invocation else {
        Issue.record("Expected Composition creation")
        return
    }
    #expect(try builder.operationTarget(command) == .database)
    #expect(composition.id == (try Base.Composition.ID("shared")))
    #expect(composition.bases == [
        try Base.ID("company-a"),
        try Base.ID("company-b"),
    ])
    #expect(revision == 0)
    #expect(key == "composition-create-1")

    let duplicate = try parser.parse([
        "composition", "create", "shared",
        "--base", "company-a",
        "--base", "company-a",
        "--expected-revision", "0",
        "--idempotency-key", "composition-create-2",
    ])
    #expect(throws: DatabaseCLIError.self) {
        try builder.compositionExecutionRequest(duplicate)
    }
}

@Test("Grant mutation binds independent access bits to its exact target")
func grantRequestContract() throws {
    let command = try CommandParser().parse([
        "grant", "add",
        "--base", "company-a",
        "--role", "analyst",
        "--access", "read,write",
        "--expected-revision", "7",
        "--idempotency-key", "grant-add-1",
    ])
    let builder = WireRequestBuilder()
    let request = try builder.grantExecutionRequest(command)
    guard case .grant(let grant, let revision, let key) = request.invocation else {
        Issue.record("Expected persisted Grant mutation")
        return
    }
    #expect(
        try builder.operationTarget(command)
            == .base(try Base.ID("company-a"))
    )
    #expect(grant.subject == .principalRole("analyst"))
    #expect(grant.resource == .base(try Base.ID("company-a")))
    #expect(grant.access == [.read, .write])
    #expect(revision == 7)
    #expect(key == "grant-add-1")
}

@Test("Effective Grant evaluation is bound to the authenticated principal")
func effectiveGrantRequestContract() throws {
    let command = try CommandParser().parse([
        "grant", "effective", "--base", "company-a",
    ])
    let request = try WireRequestBuilder().grantExecutionRequest(command)
    #expect(request.invocation == .effective)
}

@Test("Data and Grant commands default to the database target")
func commandsDefaultToDatabaseTarget() throws {
    let parser = CommandParser()
    let builder = WireRequestBuilder()
    let commands = try [
        parser.parse(["query", "sql", "SELECT 1"]),
        parser.parse(["mutate", "sql", "DELETE FROM Person"]),
        parser.parse(["grant", "direct"]),
        parser.parse(["grant", "effective"]),
        parser.parse(["job", "status", jobID, "queryExecute", "query"]),
    ]
    #expect(try commands.map(builder.operationTarget) == [
        .database,
        .database,
        .database,
        .database,
        .database,
    ])
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
    #expect(try probe.targets == [databaseTarget(fixture.target)])
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
        "--base", "company-a",
    ])

    await #expect(throws: DatabaseClientError.self) {
        try await RemoteCommandExecutor(
            session: session,
            output: .discarded
        ).execute(command)
    }
    #expect(probe.operations == [.capabilitiesDescribe, .jobStart])
    #expect(
        probe.targets
            == [.database, .base(try Base.ID("company-a"))]
    )
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
    let command = try CommandParser().parse([
        "inspect", "indexes", "--base", "company-a",
    ])

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
    #expect(
        Set(probe.targets)
            == Set([.database, .base(try Base.ID("company-a"))])
    )
    await session.shutdown()
}

private final class OperationProbeTransport: DatabaseTransport, Sendable {
    private struct State: Sendable {
        var operations: [DatabaseOperationIdentifier] = []
        var targets: [DatabaseOperationTarget] = []
    }

    private let state = Mutex(State())
    private let advertisedJob: JobOperationIdentifier?

    init(advertisedJob: JobOperationIdentifier? = nil) {
        self.advertisedJob = advertisedJob
    }

    var operations: [DatabaseOperationIdentifier] {
        state.withLock { $0.operations }
    }

    var targets: [DatabaseOperationTarget] {
        state.withLock { $0.targets }
    }

    func send(
        _ request: ByteString
    ) async throws(DatabaseTransportError) -> ByteString {
        do {
            let envelope = try DatabaseWireDecoder().decodeRequestEnvelope(request)
            state.withLock {
                $0.operations.append(envelope.operation)
                $0.targets.append(envelope.target)
            }
            if envelope.operation == .capabilitiesDescribe,
               let advertisedJob {
                return try DatabaseWireEncoder().encodeResponse(
                    DatabaseOperations.capabilitiesDescribe,
                    requestID: envelope.requestID,
                    response: CapabilitiesDescribeOperation.Response(
                        runtimeVersion: "operation-probe",
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

private func databaseTarget(
    _ target: OperationFixture.Target
) throws -> DatabaseOperationTarget {
    switch target {
    case .database:
        return .database
    case .base(let id):
        return .base(try Base.ID(id))
    case .composition(let id):
        return .composition(try Base.Composition.ID(id))
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
