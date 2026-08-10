import DatabaseEngine
import Foundation
import StorageKit
import Testing
@testable import DatabaseFDBCommandLine

private struct FDBCommandFixture: Sendable {
    let arguments: [String]
    let path: [String]
}

private let fdbCommandFixtures: [FDBCommandFixture] = [
    .init(arguments: [], path: ["help"]),
    .init(arguments: ["--help"], path: ["help"]),
    .init(arguments: ["--version"], path: ["version"]),
    .init(arguments: ["cluster", "init"], path: ["cluster", "init"]),
    .init(
        arguments: [
            "cluster", "start", "--minimum-available-space-ratio", "0.0",
        ],
        path: ["cluster", "start"]
    ),
    .init(arguments: ["cluster", "stop"], path: ["cluster", "stop"]),
    .init(arguments: ["cluster", "status"], path: ["cluster", "status"]),
    .init(
        arguments: [
            "catalog", "list",
            "--control-namespace", "database",
            "--control-namespace", "main",
        ],
        path: ["catalog", "list"]
    ),
    .init(
        arguments: [
            "catalog", "show", "Person",
            "--control-namespace", "database",
            "--control-namespace", "main",
        ],
        path: ["catalog", "show"]
    ),
    .init(arguments: ["raw", "get", "--key-hex", "00"], path: ["raw", "get"]),
    .init(arguments: ["raw", "range", "--key-utf8", "a", "--max-total-bytes", "10"], path: ["raw", "range"]),
]

@Test("Unresponsive child processes are force-terminated within the bound")
func unresponsiveChildIsForceTerminated() async throws {
    let process = Process()
    let readiness = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", "trap '' TERM; printf ready; while :; do :; done"]
    process.standardOutput = readiness
    process.standardError = FileHandle.nullDevice
    try process.run()
    defer {
        if process.isRunning {
            _ = kill(process.processIdentifier, SIGKILL)
        }
    }
    #expect(try readiness.fileHandleForReading.read(upToCount: 5) == Data("ready".utf8))

    let stopped = await FDBProcessController.terminate(
        process,
        gracePeriod: .milliseconds(100)
    )

    #expect(stopped)
    #expect(!process.isRunning)
    #expect(process.terminationReason == .uncaughtSignal)
    #expect(process.terminationStatus == SIGKILL)
}

@Test("Every FDB companion command parses", arguments: fdbCommandFixtures)
private func parsesFDBCommand(_ fixture: FDBCommandFixture) throws {
    #expect(try FDBCommandParser().parse(fixture.arguments).path == fixture.path)
}

@Test("FDB options reject repetition and unsupported write commands")
func rejectsAmbiguousOrWriteOptions() {
    #expect(throws: FDBCLIError.self) {
        try FDBCommandParser().parse([
            "raw", "get", "--key-hex", "00", "--key-hex", "01",
        ])
    }
    #expect(throws: FDBCLIError.self) {
        try FDBCommandParser().parse(["raw", "set", "--key-hex", "00"])
    }
    #expect(throws: FDBCLIError.self) {
        try FDBCommandParser().parse(["catalog", "list"])
    }
    let repeatedNamespace = try? FDBCommandParser().parse([
            "catalog", "list",
            "--control-namespace", "database",
            "--control-namespace", "main",
        ])
    #expect(
        repeatedNamespace?.optionValues("control-namespace")
            == ["database", "main"]
    )
}

@Test("Cluster initialization writes a private explicit cluster file")
func initializesClusterFile() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(Foundation.UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
        do { try FileManager.default.removeItem(at: directory) }
        catch { Issue.record("Temporary cluster cleanup failed: \(error)") }
    }

    let path = try LocalFDBCluster(output: FDBOutput()).initialize(
        basePath: directory.path,
        port: 46_991
    )
    let contents = try String(contentsOfFile: path, encoding: .utf8)
    let attributes = try FileManager.default.attributesOfItem(atPath: path)
    let permissions = attributes[.posixPermissions] as? NSNumber
    #expect(contents.hasPrefix("local:"))
    #expect(contents.hasSuffix("@127.0.0.1:46991\n"))
    #expect(permissions?.intValue == 0o600)
}

@Test("Cluster discovery walks parents but explicit paths never fall back")
func resolvesExactClusterSelection() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(Foundation.UUID().uuidString, isDirectory: true)
    let nested = directory.appendingPathComponent("a/b", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    defer {
        do { try FileManager.default.removeItem(at: directory) }
        catch { Issue.record("Temporary cluster cleanup failed: \(error)") }
    }
    let cluster = LocalFDBCluster(output: FDBOutput())
    let path = try cluster.initialize(basePath: directory.path, port: 46_992)
    #expect(try cluster.resolveClusterFile(explicit: nil, basePath: nested.path) == path)
    #expect(throws: FDBCLIError.self) {
        try cluster.resolveClusterFile(
            explicit: directory.appendingPathComponent("missing.cluster").path,
            basePath: nested.path
        )
    }
}

@Test("Raw get accepts each explicit key representation and enforces bytes")
func rawGetUsesExplicitKeyContracts() async throws {
    let engine = InMemoryEngine()
    try await engine.executeTransaction { transaction in
        try transaction.setValue(
            ByteString(utf8: "value"),
            for: ByteString(utf8: "key")
        )
    }
    let outputURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(Foundation.UUID().uuidString)
    #expect(FileManager.default.createFile(atPath: outputURL.path, contents: nil))
    defer {
        do { try FileManager.default.removeItem(at: outputURL) }
        catch { Issue.record("Temporary output cleanup failed: \(error)") }
    }
    let handle = try FileHandle(forWritingTo: outputURL)
    let inspector = FDBRawInspector(
        output: FDBOutput(resultHandle: handle, diagnosticHandle: .nullDevice)
    )
    try await inspector.get(
        command: try FDBCommandParser().parse([
            "raw", "get", "--key-utf8", "key", "--max-total-bytes", "5",
        ]),
        engine: engine
    )
    try handle.close()
    let text = try String(contentsOf: outputURL, encoding: .utf8)
    #expect(text.contains(#""valueByteCount":"5""#))

    await #expect(throws: FDBCLIError.self) {
        try await inspector.get(
            command: try FDBCommandParser().parse([
                "raw", "get", "--key-utf8", "key", "--max-total-bytes", "4",
            ]),
            engine: engine
        )
    }
}

@Test("Raw key selectors are mutually exclusive")
func rawKeySelectorsAreExclusive() async {
    let inspector = FDBRawInspector(
        output: FDBOutput(
            resultHandle: .nullDevice,
            diagnosticHandle: .nullDevice
        )
    )
    await #expect(throws: FDBCLIError.self) {
        try await inspector.get(
            command: try FDBCommandParser().parse([
                "raw", "get", "--key-utf8", "key", "--key-hex", "00",
            ]),
            engine: InMemoryEngine()
        )
    }
}
