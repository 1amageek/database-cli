import Foundation
@testable import DatabaseCommandLine
import Testing

@Suite("Database server executable")
struct DatabaseServerExecutableTests {
    @Test("Version validation accepts only the exact adjacent version")
    func exactVersionIsRequired() async throws {
        try await withExecutable(
            "#!/bin/sh\nprintf '26.0809.1\\n'\n"
        ) { url in
            let executable = DatabaseServerExecutable(url: url)
            try await executable.validateVersion(
                expected: "26.0809.1",
                timeout: .seconds(1)
            )
            await #expect(throws: DatabaseCLIError.self) {
                try await executable.validateVersion(
                    expected: "26.0809.2",
                    timeout: .seconds(1)
                )
            }
        }
    }

    @Test("Version validation terminates a non-responsive executable")
    func timeoutTerminatesProcess() async throws {
        try await withExecutable(
            "#!/bin/sh\ntrap '' TERM\nwhile true; do :; done\n"
        ) { url in
            let executable = DatabaseServerExecutable(url: url)
            let clock = ContinuousClock()
            let started = clock.now
            await #expect(throws: DatabaseCLIError.self) {
                try await executable.validateVersion(
                    expected: "26.0809.1",
                    timeout: .milliseconds(100)
                )
            }
            #expect(started.duration(to: clock.now) < .seconds(3))
        }
    }

    @Test("Bootstrap acknowledges a credential only after client state is prepared")
    func bootstrapAcknowledgementFollowsPreparation() async throws {
        let executable = DatabaseServerExecutable(
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
        let executable = DatabaseServerExecutable(
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
