import DatabaseClient
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

private extension OutputWriter {
    static var discarded: OutputWriter {
        OutputWriter(
            resultHandle: .nullDevice,
            diagnosticHandle: .nullDevice
        )
    }
}
