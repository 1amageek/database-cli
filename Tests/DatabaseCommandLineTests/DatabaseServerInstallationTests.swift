import Darwin
import Foundation
@testable import DatabaseCommandLine
import Testing

@Suite("Database server installation", .serialized)
struct DatabaseServerInstallationTests {
    @Test("Version validation accepts only the exact adjacent version")
    func exactVersionIsRequired() async throws {
        try await withExecutable(
            "#!/bin/sh\nprintf '26.0818.0\\n'\n"
        ) { url in
            let executable = DatabaseServerInstallation(url: url)
            try await executable.validateVersion(
                expected: "26.0818.0",
                timeout: .seconds(1)
            )
            await #expect(throws: DatabaseCLIError.self) {
                try await executable.validateVersion(
                    expected: "26.0812.2",
                    timeout: .seconds(1)
                )
            }
        }
    }

    @Test(
        "Version validation terminates a non-responsive executable",
        .timeLimit(.minutes(1))
    )
    func timeoutTerminatesProcess() async throws {
        try await withExecutable(
            "#!/bin/sh\nprintf '%s' \"$$\" > \"${0%/*}/pid\"\ntrap '' TERM\nexec sleep 60\n"
        ) { url in
            let executable = DatabaseServerInstallation(url: url)
            do {
                try await executable.validateVersion(
                    expected: "26.0818.0",
                    timeout: .seconds(1)
                )
                Issue.record("Expected version validation to time out")
            } catch let error as DatabaseCLIError {
                #expect(error.exitCode == .unavailable)
                #expect(error.message == "database-server version check timed out")
            } catch {
                Issue.record("Unexpected error: \(error)")
            }

            let pidURL = url.deletingLastPathComponent()
                .appendingPathComponent("pid", isDirectory: false)
            let pidText = try String(contentsOf: pidURL, encoding: .utf8)
            let pid = try #require(Int32(pidText))
            errno = 0
            #expect(Darwin.kill(pid, 0) == -1)
            #expect(errno == ESRCH)
        }
    }

    @Test("Bootstrap acknowledges a credential only after client state is prepared")
    func bootstrapAcknowledgementFollowsPreparation() async throws {
        let executable = DatabaseServerInstallation(
            url: try fixtureURL(named: "BootstrapDatabaseServer.sh")
        )
        var preparedToken: String?
        let response = try await DatabaseServerBootstrap(
            executable: executable
        ).prepare(
            request: .init(
                configurationURL: URL(fileURLWithPath: "/tmp/server.json"),
                storageArguments: [
                    "--storage", "sqlite", "--path", "/tmp/database.sqlite",
                ],
                host: nil,
                port: nil,
                databaseID: "main",
                tenantID: nil,
                workspaceID: nil
            )
        ) { response in
            preparedToken = response.token
        }

        #expect(response.createdCredential)
        #expect(preparedToken == "bootstrap-secret")
        #expect(response.endpoint == "http://127.0.0.1:7878/v1/database")
    }

    @Test("Bootstrap sends rejection when client state preparation fails")
    func bootstrapRejectsFailedPreparation() async throws {
        let executable = DatabaseServerInstallation(
            url: try fixtureURL(named: "BootstrapDatabaseServer.sh")
        )

        await #expect(throws: BootstrapFixtureError.rejected) {
            _ = try await DatabaseServerBootstrap(
                executable: executable
            ).prepare(
                request: .init(
                    configurationURL: URL(fileURLWithPath: "/tmp/server.json"),
                    storageArguments: [
                        "--storage", "sqlite", "--path", "/tmp/database.sqlite",
                    ],
                    host: nil,
                    port: nil,
                    databaseID: "main",
                    tenantID: nil,
                    workspaceID: nil
                )
            ) { _ in
                throw BootstrapFixtureError.rejected
            }
        }
    }

    private func withExecutable<Result>(
        _ source: String,
        operation: (URL) async throws -> Result
    ) async throws -> Result {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "database-cli-version-check-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        let executableURL = directory.appendingPathComponent("database-server")
        do {
            try source.write(
                to: executableURL,
                atomically: true,
                encoding: .utf8
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: executableURL.path
            )
            let result = try await operation(executableURL)
            try FileManager.default.removeItem(at: directory)
            return result
        } catch {
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
            throw error
        }
    }

    private func fixtureURL(named name: String) throws -> URL {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent(name, isDirectory: false)
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw DatabaseCLIError(
                .internalFailure,
                "Test fixture is not executable: \(url.path)"
            )
        }
        return url
    }
}

private enum BootstrapFixtureError: Error, Equatable {
    case rejected
}
