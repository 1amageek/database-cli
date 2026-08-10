import DatabaseKit
import DatabaseTypes
import DatabaseWire
import Foundation
import Testing
@testable import DatabaseCommandLine

@Test("Execution budget and metadata map one-to-one")
func mapsExecutionContract() throws {
    let command = try CommandParser().parse([
        "query", "sql", "SELECT 1",
        "--base", "company-a",
        "--trace-id", "trace-1",
        "--idempotency-key", "request-1",
        "--maximum-rows", "11",
        "--maximum-work-units", "12",
        "--maximum-intermediate-rows", "13",
        "--maximum-intermediate-bytes", "14",
        "--timeout-milliseconds", "15",
        "--page-size", "16",
    ])
    let execution = try ExecutionOptions(options: command.options)
    #expect(execution.metadata.traceID == "trace-1")
    #expect(execution.metadata.idempotencyKey == "request-1")
    #expect(execution.budget.maximumRows == 11)
    #expect(execution.budget.maximumWorkUnits == 12)
    #expect(execution.budget.maximumIntermediateRows == 13)
    #expect(execution.budget.maximumIntermediateBytes == 14)
    #expect(execution.budget.timeoutMilliseconds == 15)
    #expect(execution.pageSize == 16)
}

@Test("Continuation is canonical base64url and detached")
func continuationRoundTrip() throws {
    let encoded = Base64URL.encode(ByteString([0, 1, 2, 253, 254, 255]))
    #expect(encoded == "AAEC_f7_")
    #expect(try Base64URL.decode(encoded) == ByteString([0, 1, 2, 253, 254, 255]))
    #expect(throws: DatabaseCLIError.self) {
        try Base64URL.decode("AAEC/f7/")
    }
}

@Test("Output byte and element limits reject before the excess write")
func outputLimitsArePreflighted() throws {
    let temporary = FileManager.default.temporaryDirectory
        .appendingPathComponent(Foundation.UUID().uuidString)
    #expect(FileManager.default.createFile(atPath: temporary.path, contents: nil))
    let handle = try FileHandle(forWritingTo: temporary)
    let output = OutputWriter(
        resultHandle: handle,
        diagnosticHandle: FileHandle.nullDevice
    ).limitingResultBytes(to: 3)
    _ = try output.result("abc")
    #expect(throws: DatabaseCLIError.self) { try output.result("d") }
    try handle.close()
    #expect(try Data(contentsOf: temporary) == Data("abc".utf8))
    try FileManager.default.removeItem(at: temporary)

    let elements = ResultElementQuota(maximumElements: 1)
    try elements.reserveOne()
    #expect(throws: DatabaseCLIError.self) { try elements.reserveOne() }
}

@Test("Remote categories map to stable process exit codes", arguments: [
    (OperationErrorCategory.invalidRequest, DatabaseCLIExitCode.input),
    (.authentication, .authentication),
    (.authorization, .authorization),
    (.notFound, .notFound),
    (.conflict, .conflict),
    (.constraint, .conflict),
    (.resourceLimit, .resourceLimit),
    (.unavailable, .unavailable),
    (.internalFailure, .internalFailure),
])
func mapsRemoteExitCode(
    _ category: OperationErrorCategory,
    _ expected: DatabaseCLIExitCode
) {
    let failure = DatabaseCLIError.map(
        RemoteOperationError(
            category: category,
            code: "TEST",
            message: "test",
            retryability: .never
        )
    )
    #expect(failure.exitCode == expected)
}

@Test("CSV and N-Quads reject incompatible result kinds")
func rejectsIncompatibleOutput() throws {
    let renderer = ResultRenderer(
        output: OutputWriter(
            resultHandle: FileHandle.nullDevice,
            diagnosticHandle: FileHandle.nullDevice
        )
    )
    let result = try QueryBooleanResult(
        value: true,
        provenance: nil,
        consistency: .transactional(
            try DomainReadPoint(domainID: "primary", position: .version(1))
        )
    )
    #expect(throws: DatabaseCLIError.self) {
        try renderer.renderQuery(.boolean(result), format: .csv)
    }
    #expect(throws: DatabaseCLIError.self) {
        try renderer.renderQuery(.boolean(result), format: .nquads)
    }
}

@Test("Composition rows stream provenance and consistency without materializing the page")
func rendersCompositionProvenance() throws {
    let temporary = FileManager.default.temporaryDirectory
        .appendingPathComponent(Foundation.UUID().uuidString)
    #expect(FileManager.default.createFile(atPath: temporary.path, contents: nil))
    let handle = try FileHandle(forWritingTo: temporary)
    let baseID = try Base.ID("company-a")
    let provenance = try CompositionPageProvenance(
        compositionID: Base.Composition.ID("shared"),
        generation: 7,
        baseIDs: [baseID],
        origins: [.source(baseID)]
    )
    let page = try QueryRowPage(
        columns: [QueryColumn(number: 0, name: "name")],
        rows: [QueryRow(values: [.string("Alice")])],
        continuation: nil,
        provenance: provenance,
        consistency: .federated([
            try DomainReadPoint(
                domainID: "primary",
                position: .opaque(ByteString([1, 2, 3]))
            ),
        ])
    )
    let renderer = ResultRenderer(
        output: OutputWriter(
            resultHandle: handle,
            diagnosticHandle: FileHandle.nullDevice
        )
    )

    let rendered = try renderer.renderQuery(.rows(page), format: .jsonl)
    try handle.close()
    let output = try String(contentsOf: temporary, encoding: .utf8)
    try FileManager.default.removeItem(at: temporary)

    #expect(rendered.elementCount == 1)
    #expect(output.contains("\"$provenance\""))
    #expect(output.contains("\"composition\":\"shared\""))
    #expect(output.contains("\"base\":\"company-a\""))
    #expect(output.contains("\"$consistency\""))
    #expect(output.contains("\"type\":\"federated\""))
}
