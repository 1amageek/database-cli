import DatabaseCommandLine
import Foundation
import StorageKit

public struct DatabaseFDBApplication: Sendable {
    private let output = FDBOutput()

    public init() {}

    public func run(arguments: [String]) async -> Int32 {
        do {
            try validateCompanionVersion()
            let command = try FDBCommandParser().parse(arguments)
            try await execute(command)
            return FDBCLIExitCode.success.rawValue
        } catch let error as FDBCLIError {
            output.diagnostic("error: \(error.message)\n")
            return error.exitCode.rawValue
        } catch let error as DatabaseCLIError {
            output.diagnostic("error: \(error.message)\n")
            return error.exitCode.rawValue
        } catch is CancellationError {
            output.diagnostic("error: Operation cancelled\n")
            return FDBCLIExitCode.cancelled.rawValue
        } catch {
            output.diagnostic("error: \(error)\n")
            return FDBCLIExitCode.internalFailure.rawValue
        }
    }
}

private extension DatabaseFDBApplication {
    func execute(_ command: FDBCommand) async throws {
        let cluster = LocalFDBCluster(output: output)
        switch command.path {
        case ["help"]:
            try output.result(FDBCommandParser().usage + "\n")
        case ["version"]:
            try output.result(DatabaseCLIVersion.current + "\n")
        case ["cluster", "init"]:
            let basePath = command.option("path")
                ?? FileManager.default.currentDirectoryPath
            let port: UInt16
            if let raw = command.option("port") {
                guard let parsed = UInt16(raw), parsed > 0 else {
                    throw FDBCLIError(.input, "Port must be 1 through 65535")
                }
                port = parsed
            } else {
                port = LocalFDBCluster.defaultPort
            }
            let clusterFile = try cluster.initialize(
                basePath: basePath,
                port: port
            )
            try output.json([
                "clusterFile": clusterFile,
                "initialized": true,
                "port": String(port),
            ])
        case ["cluster", "start"]:
            let clusterFile = try cluster.resolveClusterFile(
                explicit: command.option("cluster-file"),
                basePath: command.option("path")
            )
            let minimumAvailableSpaceRatio: Double?
            if let rawRatio = command.option("minimum-available-space-ratio") {
                guard let ratio = Double(rawRatio), ratio.isFinite,
                      (0...1).contains(ratio) else {
                    throw FDBCLIError(
                        .input,
                        "Minimum available space ratio must be between 0 and 1"
                    )
                }
                minimumAvailableSpaceRatio = ratio
            } else {
                minimumAvailableSpaceRatio = nil
            }
            let pid = try await cluster.start(
                clusterFile: clusterFile,
                minimumAvailableSpaceRatio: minimumAvailableSpaceRatio
            )
            try output.json([
                "clusterFile": clusterFile,
                "pid": String(pid),
                "ready": true,
            ])
        case ["cluster", "stop"]:
            let clusterFile = try cluster.resolveClusterFile(
                explicit: command.option("cluster-file"),
                basePath: command.option("path")
            )
            try await cluster.stop(clusterFile: clusterFile)
            try output.json([
                "clusterFile": clusterFile,
                "ready": false,
                "stopped": true,
            ])
        case ["cluster", "status"]:
            let clusterFile = try cluster.resolveClusterFile(
                explicit: command.option("cluster-file"),
                basePath: command.option("path")
            )
            let status = try await cluster.status(clusterFile: clusterFile)
            var result: [String: Any] = [
                "clusterFile": status.clusterFile,
                "processAlive": status.processAlive,
                "ready": status.ready,
            ]
            result["pid"] = status.pid.map { String($0) } ?? NSNull()
            try output.json(result)
        case ["catalog", "list"], ["catalog", "show"],
             ["raw", "get"], ["raw", "range"]:
            let clusterFile = try cluster.resolveClusterFile(
                explicit: command.option("cluster-file"),
                basePath: nil
            )
            try await FDBDatabaseConnection().withEngine(
                clusterFile: clusterFile
            ) { engine in
                switch command.path {
                case ["catalog", "list"]:
                    let root = try await engine.resolveExistingNamespace(
                        path: command.optionValues("control-namespace")
                    )
                    try await FDBCatalogInspector(output: output).list(
                        engine: engine,
                        root: root
                    )
                case ["catalog", "show"]:
                    let root = try await engine.resolveExistingNamespace(
                        path: command.optionValues("control-namespace")
                    )
                    try await FDBCatalogInspector(output: output).show(
                        name: command.positionals[0],
                        engine: engine,
                        root: root
                    )
                case ["raw", "get"]:
                    try await FDBRawInspector(output: output).get(
                        command: command,
                        engine: engine
                    )
                case ["raw", "range"]:
                    try await FDBRawInspector(output: output).range(
                        command: command,
                        engine: engine
                    )
                default:
                    throw FDBCLIError(.internalFailure, "Invalid FDB dispatch")
                }
            }
        default:
            throw FDBCLIError(.input, "Unknown FoundationDB command")
        }
    }

    func validateCompanionVersion() throws {
        guard let expected = ProcessInfo.processInfo.environment[
            "DATABASE_FDB_EXPECTED_VERSION"
        ] else { return }
        guard expected == DatabaseCLIVersion.current else {
            throw FDBCLIError(
                .internalFailure,
                "database and database-fdb versions do not match"
            )
        }
    }
}
