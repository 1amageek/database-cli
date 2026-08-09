import Darwin
import Foundation

struct LocalFDBCluster: Sendable {
    static let directoryName = ".database"
    static let defaultPort: UInt16 = 4690

    let output: FDBOutput

    func initialize(basePath: String, port: UInt16) throws -> String {
        guard port > 0 else { throw FDBCLIError(.input, "Port must be positive") }
        guard isPortAvailable(port) else {
            throw FDBCLIError(.conflict, "Port \(port) is already in use")
        }
        let base = URL(fileURLWithPath: basePath, isDirectory: true).standardized
        let directory = base.appendingPathComponent(Self.directoryName, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: directory.path) else {
            throw FDBCLIError(.conflict, "Cluster is already initialized at \(directory.path)")
        }
        let data = directory.appendingPathComponent("data", isDirectory: true)
        let logs = directory.appendingPathComponent("logs", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: data,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.createDirectory(
                at: logs,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let identifier = Foundation.UUID().uuidString
                .replacingOccurrences(of: "-", with: "")
                .lowercased()
                .prefix(16)
            let clusterFile = directory.appendingPathComponent("fdb.cluster")
            try Data("local:\(identifier)@127.0.0.1:\(port)\n".utf8)
                .write(to: clusterFile, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: clusterFile.path
            )
            return clusterFile.path
        } catch let error as FDBCLIError {
            throw error
        } catch {
            throw FDBCLIError(.internalFailure, "Cluster initialization failed: \(error)")
        }
    }

    func start(
        clusterFile: String,
        minimumAvailableSpaceRatio: Double? = nil
    ) async throws -> Int32 {
        let cluster = URL(fileURLWithPath: clusterFile).standardized
        guard FileManager.default.fileExists(atPath: cluster.path) else {
            throw FDBCLIError(.notFound, "Cluster file does not exist: \(cluster.path)")
        }
        let directory = cluster.deletingLastPathComponent()
        if let pid = try readPID(directory: directory), isAlive(pid) {
            throw FDBCLIError(.conflict, "FoundationDB server is already running with PID \(pid)")
        }
        let port = try parsePort(clusterFile: cluster.path)
        let machineID = try parseMachineID(clusterFile: cluster.path)
        guard isPortAvailable(port) else {
            throw FDBCLIError(.conflict, "Port \(port) is already in use")
        }
        let server = try executable(
            name: "fdbserver",
            knownPaths: [
                "/usr/local/libexec/fdbserver",
                "/opt/homebrew/libexec/fdbserver",
                "/usr/sbin/fdbserver",
                "/usr/local/sbin/fdbserver",
            ]
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: server)
        var arguments = [
            "-p", "auto:\(port)",
            "-i", machineID,
            "-C", cluster.path,
            "-d", directory.appendingPathComponent("data").path,
            "-L", directory.appendingPathComponent("logs").path,
        ]
        if let minimumAvailableSpaceRatio {
            arguments.append(
                "--knob_min_available_space_ratio=\(minimumAvailableSpaceRatio)"
            )
        }
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        let serverErrorURL = directory
            .appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent("fdbserver.stderr.log")
        guard FileManager.default.createFile(
            atPath: serverErrorURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw FDBCLIError(
                .internalFailure,
                "Cannot create FoundationDB diagnostic log at \(serverErrorURL.path)"
            )
        }
        let serverErrorHandle: FileHandle
        do {
            serverErrorHandle = try FileHandle(forWritingTo: serverErrorURL)
        } catch {
            throw FDBCLIError(
                .internalFailure,
                "Cannot open FoundationDB diagnostic log: \(error)"
            )
        }
        process.standardError = serverErrorHandle
        var startedPID: Int32?
        do {
            try process.run()
            try serverErrorHandle.close()
            let pid = process.processIdentifier
            startedPID = pid
            try Data("\(pid)\n".utf8).write(
                to: directory.appendingPathComponent("fdb.pid"),
                options: [.atomic]
            )
            let configuredMarker = directory.appendingPathComponent("configured")
            if !FileManager.default.fileExists(atPath: configuredMarker.path) {
                if await protocolReady(clusterFile: cluster.path) == false {
                    _ = try await runFDBCLI(
                        clusterFile: cluster.path,
                        command: "configure new single ssd",
                        timeout: .seconds(15)
                    )
                }
                try Data("configured\n".utf8).write(
                    to: configuredMarker,
                    options: [.atomic]
                )
            }
            let ready = await waitForReadiness(
                clusterFile: cluster.path,
                expectedReady: true,
                timeout: .seconds(15)
            )
            try Task.checkCancellation()
            guard ready else {
                _ = kill(pid, SIGTERM)
                throw FDBCLIError(.unavailable, "FoundationDB did not become ready")
            }
            try Task.checkCancellation()
            return pid
        } catch is CancellationError {
            closeIfNeeded(serverErrorHandle)
            if let startedPID {
                try await cleanupFailedStart(
                    pid: startedPID,
                    clusterFile: cluster.path,
                    directory: directory,
                    startupError: FDBCLIError(.cancelled, "Startup cancelled")
                )
            }
            throw CancellationError()
        } catch let error as FDBCLIError {
            closeIfNeeded(serverErrorHandle)
            if let startedPID {
                try await cleanupFailedStart(
                    pid: startedPID,
                    clusterFile: cluster.path,
                    directory: directory,
                    startupError: error
                )
            }
            throw error
        } catch {
            closeIfNeeded(serverErrorHandle)
            let startupError = FDBCLIError(
                .unavailable,
                "FoundationDB startup failed: \(error)"
            )
            if let startedPID {
                try await cleanupFailedStart(
                    pid: startedPID,
                    clusterFile: cluster.path,
                    directory: directory,
                    startupError: startupError
                )
            }
            throw startupError
        }
    }

    func stop(clusterFile: String) async throws {
        let cluster = URL(fileURLWithPath: clusterFile).standardized
        let directory = cluster.deletingLastPathComponent()
        guard let pid = try readPID(directory: directory) else {
            throw FDBCLIError(.notFound, "No FoundationDB PID file exists")
        }
        if isAlive(pid), kill(pid, SIGTERM) != 0 {
            throw FDBCLIError(.unavailable, "Cannot signal FoundationDB PID \(pid)")
        }
        let stopped = await Task.detached {
            await self.waitForStopped(
                pid: pid,
                clusterFile: cluster.path,
                timeout: .seconds(15)
            )
        }.value
        guard stopped else {
            throw FDBCLIError(.unavailable, "FoundationDB remained reachable after stop")
        }
        try removePIDFile(directory: directory)
        try Task.checkCancellation()
    }

    func status(clusterFile: String) async throws -> FDBClusterStatus {
        let cluster = URL(fileURLWithPath: clusterFile).standardized
        let directory = cluster.deletingLastPathComponent()
        let pid = try readPID(directory: directory)
        let alive = pid.map(isAlive) ?? false
        let ready = await protocolReady(clusterFile: cluster.path)
        return FDBClusterStatus(
            clusterFile: cluster.path,
            pid: pid,
            processAlive: alive,
            ready: ready
        )
    }

    func resolveClusterFile(
        explicit: String?,
        basePath: String?
    ) throws -> String {
        if let explicit {
            let path = URL(fileURLWithPath: explicit).standardized.path
            guard FileManager.default.fileExists(atPath: path) else {
                throw FDBCLIError(.notFound, "Cluster file does not exist: \(path)")
            }
            return path
        }
        let start = basePath ?? FileManager.default.currentDirectoryPath
        guard let discovered = discoverClusterFile(from: start) else {
            throw FDBCLIError(
                .notFound,
                "No .database/fdb.cluster was found from \(start)"
            )
        }
        return discovered
    }
}

struct FDBClusterStatus: Sendable {
    let clusterFile: String
    let pid: Int32?
    let processAlive: Bool
    let ready: Bool
}

private extension LocalFDBCluster {
    func cleanupFailedStart(
        pid: Int32,
        clusterFile: String,
        directory: URL,
        startupError: FDBCLIError
    ) async throws {
        if isAlive(pid), kill(pid, SIGTERM) != 0, errno != ESRCH {
            throw FDBCLIError(
                .unavailable,
                "Startup failed (\(startupError.message)) and PID \(pid) could not be signalled"
            )
        }
        let stopped = await Task.detached {
            await self.waitForStopped(
                pid: pid,
                clusterFile: clusterFile,
                timeout: .seconds(15)
            )
        }.value
        if !stopped {
            if isAlive(pid) {
                _ = kill(pid, SIGKILL)
            }
            let forceStopped = await Task.detached {
                await self.waitForStopped(
                    pid: pid,
                    clusterFile: clusterFile,
                    timeout: .seconds(5)
                )
            }.value
            guard forceStopped else {
                throw FDBCLIError(
                    .unavailable,
                    "Startup failed (\(startupError.message)) and cluster teardown could not be proven"
                )
            }
        }
        try removePIDFile(directory: directory)
    }

    func removePIDFile(directory: URL) throws {
        let pidFile = directory.appendingPathComponent("fdb.pid")
        guard FileManager.default.fileExists(atPath: pidFile.path) else { return }
        do {
            try FileManager.default.removeItem(at: pidFile)
        } catch {
            throw FDBCLIError(.internalFailure, "Cannot remove PID file: \(error)")
        }
    }

    func discoverClusterFile(from startPath: String) -> String? {
        var current = URL(fileURLWithPath: startPath, isDirectory: true).standardized
        while true {
            let candidate = current
                .appendingPathComponent(Self.directoryName, isDirectory: true)
                .appendingPathComponent("fdb.cluster")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate.path
            }
            let parent = current.deletingLastPathComponent().standardized
            if parent.path == current.path { return nil }
            current = parent
        }
    }

    func parsePort(clusterFile: String) throws -> UInt16 {
        let content = try clusterFileContent(at: clusterFile)
        guard let separator = content.lastIndex(of: ":"),
              let port = UInt16(content[content.index(after: separator)...]),
              port > 0 else {
            throw FDBCLIError(.input, "Cluster file has an invalid port")
        }
        return port
    }

    func parseMachineID(clusterFile: String) throws -> String {
        let content = try clusterFileContent(at: clusterFile)
        guard let descriptionEnd = content.firstIndex(of: ":"),
              let coordinatorsStart = content[content.index(after: descriptionEnd)...]
                .firstIndex(of: "@") else {
            throw FDBCLIError(.input, "Cluster file has an invalid identifier")
        }
        let identifier = content[content.index(after: descriptionEnd)..<coordinatorsStart]
        guard !identifier.isEmpty,
              identifier.utf8.count <= 16,
              identifier.utf8.allSatisfy({ byte in
                  (byte >= 48 && byte <= 57)
                      || (byte >= 65 && byte <= 70)
                      || (byte >= 97 && byte <= 102)
              }) else {
            throw FDBCLIError(
                .input,
                "Cluster identifier must contain 1 through 16 hexadecimal characters"
            )
        }
        return String(identifier)
    }

    func clusterFileContent(at path: String) throws -> String {
        do {
            return try String(contentsOfFile: path, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw FDBCLIError(.input, "Cannot read cluster file: \(error)")
        }
    }

    func readPID(directory: URL) throws -> Int32? {
        let file = directory.appendingPathComponent("fdb.pid")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let raw: String
        do {
            raw = try String(contentsOf: file, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw FDBCLIError(.input, "Cannot read PID file: \(error)")
        }
        guard let pid = Int32(raw), pid > 1 else {
            throw FDBCLIError(.input, "PID file is malformed")
        }
        return pid
    }

    func isAlive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

    func isPortAvailable(_ port: UInt16) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var reuse: Int32 = 1
        _ = setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_REUSEADDR,
            &reuse,
            socklen_t(MemoryLayout<Int32>.size)
        )
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                ) == 0
            }
        }
    }

    func executable(name: String, knownPaths: [String]) throws -> String {
        for path in knownPaths where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            for directory in path.split(separator: ":") {
                let candidate = "\(directory)/\(name)"
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
        }
        throw FDBCLIError(.notFound, "Required executable '\(name)' was not found")
    }

    func runFDBCLI(
        clusterFile: String,
        command: String,
        timeout: Duration
    ) async throws -> String {
        let cli = try executable(
            name: "fdbcli",
            knownPaths: [
                "/usr/local/bin/fdbcli",
                "/opt/homebrew/bin/fdbcli",
                "/usr/bin/fdbcli",
            ]
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = ["-C", clusterFile, "--exec", command]
        let captureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "database-cli-fdbcli-\(Foundation.UUID().uuidString)",
                isDirectory: true
            )
        do {
            try FileManager.default.createDirectory(
                at: captureDirectory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw FDBCLIError(.internalFailure, "Cannot create fdbcli capture directory: \(error)")
        }
        defer {
            do {
                try FileManager.default.removeItem(at: captureDirectory)
            } catch {
                output.diagnostic("warning: cannot remove fdbcli capture directory: \(error)\n")
            }
        }
        let outputURL = captureDirectory.appendingPathComponent("stdout")
        let errorURL = captureDirectory.appendingPathComponent("stderr")
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil),
              FileManager.default.createFile(atPath: errorURL.path, contents: nil) else {
            throw FDBCLIError(.internalFailure, "Cannot create fdbcli capture files")
        }
        let outputHandle: FileHandle
        let errorHandle: FileHandle
        do {
            outputHandle = try FileHandle(forWritingTo: outputURL)
            errorHandle = try FileHandle(forWritingTo: errorURL)
        } catch {
            throw FDBCLIError(.internalFailure, "Cannot open fdbcli capture files: \(error)")
        }
        process.standardOutput = outputHandle
        process.standardError = errorHandle
        do {
            try process.run()
        } catch {
            closeIfNeeded(outputHandle)
            closeIfNeeded(errorHandle)
            throw FDBCLIError(.unavailable, "fdbcli failed to start: \(error)")
        }
        closeIfNeeded(outputHandle)
        closeIfNeeded(errorHandle)

        let exited: Bool
        do {
            exited = try await FDBProcessController.waitForExit(
                process,
                timeout: timeout
            )
        } catch {
            let stopped = await FDBProcessController.terminate(process)
            guard stopped else {
                throw FDBCLIError(
                    .unavailable,
                    "fdbcli '\(command)' could not be stopped after cancellation"
                )
            }
            throw error
        }
        guard exited else {
            let stopped = await FDBProcessController.terminate(process)
            guard stopped else {
                throw FDBCLIError(
                    .unavailable,
                    "fdbcli '\(command)' timed out and could not be stopped"
                )
            }
            throw FDBCLIError(.unavailable, "fdbcli '\(command)' timed out")
        }
        try Task.checkCancellation()

        let standardOutput: String
        let standardError: String
        do {
            standardOutput = try String(contentsOf: outputURL, encoding: .utf8)
            standardError = try String(contentsOf: errorURL, encoding: .utf8)
        } catch {
            throw FDBCLIError(.internalFailure, "Cannot read fdbcli output: \(error)")
        }
        guard process.terminationReason == .exit,
              process.terminationStatus == 0 else {
            let detail = standardError
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(512)
            throw FDBCLIError(
                .unavailable,
                "fdbcli '\(command)' failed with status \(process.terminationStatus)"
                    + (detail.isEmpty ? "" : ": \(detail)")
            )
        }
        return standardOutput
    }

    func protocolReady(clusterFile: String) async -> Bool {
        do {
            let output = try await runFDBCLI(
                clusterFile: clusterFile,
                command: "status json",
                timeout: .seconds(2)
            )
            guard let data = output.data(using: .utf8),
                  let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let client = root["client"] as? [String: Any],
                  let databaseStatus = client["database_status"] as? [String: Any],
                  let available = databaseStatus["available"] as? Bool,
                  let healthy = databaseStatus["healthy"] as? Bool else {
                return false
            }
            return available && healthy
        } catch {
            return false
        }
    }

    func closeIfNeeded(_ handle: FileHandle) {
        do {
            try handle.close()
        } catch {
            output.diagnostic("warning: file handle close failed: \(error)\n")
        }
    }

    func waitForReadiness(
        clusterFile: String,
        expectedReady: Bool,
        timeout: Duration
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        repeat {
            if await protocolReady(clusterFile: clusterFile) == expectedReady {
                return true
            }
            do {
                try await clock.sleep(for: .milliseconds(200))
            } catch {
                return false
            }
        } while clock.now < deadline
        return false
    }

    func waitForStopped(
        pid: Int32,
        clusterFile: String,
        timeout: Duration
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        repeat {
            let ready = await protocolReady(clusterFile: clusterFile)
            if !isAlive(pid), !ready {
                return true
            }
            do {
                try await clock.sleep(for: .milliseconds(200))
            } catch {
                return false
            }
        } while clock.now < deadline
        let ready = await protocolReady(clusterFile: clusterFile)
        return !isAlive(pid) && !ready
    }
}
