import DatabaseWire
import Foundation

extension DatabaseCLIApplication {
    func executeDoctor(_ command: ParsedCommand) async throws {
        var checks: [StrictJSONValue] = []
        var terminalFailure: DatabaseCLIError?

        func record(
            _ id: String,
            _ status: String,
            _ summary: String,
            remediation: String? = nil,
            duration: Duration = .zero
        ) {
            checks.append(.object([
                ("id", .string(id)),
                ("status", .string(status)),
                ("summary", .string(summary)),
                ("remediation", remediation.map(StrictJSONValue.string) ?? .null),
                ("duration", .string(String(describing: duration))),
            ]))
        }

        let installStart = ContinuousClock.now
        if let executable = Bundle.main.executableURL {
            let directory = executable.deletingLastPathComponent()
            let fdb = directory.appendingPathComponent("database-fdb")
            let server = directory.appendingPathComponent("database-server")
            let missing = [fdb, server].filter {
                !FileManager.default.isExecutableFile(atPath: $0.path)
            }.map(\.lastPathComponent)
            record(
                "install.companions",
                missing.isEmpty ? "pass" : "warn",
                missing.isEmpty
                    ? "Version-matched companion executables are installed."
                    : "Missing companion executables: \(missing.joined(separator: ", ")).",
                remediation: missing.isEmpty
                    ? nil
                    : "Install database-fdb and database-server beside database.",
                duration: installStart.duration(to: .now)
            )
        } else {
            record(
                "install.companions",
                "warn",
                "The running executable path is unavailable.",
                remediation: "Run doctor from an installed database executable.",
                duration: installStart.duration(to: .now)
            )
        }

        if let configPath = command.options.value("server-config") {
            let start = ContinuousClock.now
            let attributes: [FileAttributeKey: Any]
            do {
                attributes = try FileManager.default.attributesOfItem(
                    atPath: configPath
                )
            } catch {
                record(
                    "local.server-config",
                    "fail",
                    "Server configuration cannot be read.",
                    remediation: "Provide an existing readable configuration path.",
                    duration: start.duration(to: .now)
                )
                terminalFailure = DatabaseCLIError(
                    .input,
                    "Server configuration cannot be read"
                )
                attributes = [:]
            }
            if let permissions = attributes[.posixPermissions] as? NSNumber {
                let secure = permissions.intValue & 0o077 == 0
                record(
                    "local.server-config",
                    secure ? "pass" : "fail",
                    secure
                        ? "Server configuration permissions are restricted."
                        : "Server configuration is accessible by group or other users.",
                    remediation: secure ? nil : "Set the file mode to 0600.",
                    duration: start.duration(to: .now)
                )
                if !secure {
                    terminalFailure = DatabaseCLIError(
                        .input,
                        "Server configuration permissions are unsafe"
                    )
                }
            } else if terminalFailure == nil {
                record(
                    "local.server-config",
                    "fail",
                    "Server configuration cannot be read.",
                    remediation: "Provide an existing readable configuration path.",
                    duration: start.duration(to: .now)
                )
                terminalFailure = DatabaseCLIError(
                    .input,
                    "Server configuration cannot be read"
                )
            }
        } else {
            record(
                "local.server-config",
                "skipped",
                "No local server configuration was selected."
            )
        }

        let profile: DatabaseProfile
        let profileStart = ContinuousClock.now
        do {
            profile = try profiles.selectedProfile(
                named: command.options.value("profile")
            )
            record(
                "config.profile",
                "pass",
                "Profile '\(profile.name)' is valid.",
                duration: profileStart.duration(to: .now)
            )
        } catch {
            let failure = DatabaseCLIError.map(error)
            record(
                "config.profile",
                "fail",
                failure.message,
                remediation: "Create or select a valid profile.",
                duration: profileStart.duration(to: .now)
            )
            try writeDoctor(checks)
            throw failure
        }

        let credentialStart = ContinuousClock.now
        let token: String
        do {
            guard let available = try credentials.resolvedTokenIfAvailable(
                for: profile
            ) else {
                throw DatabaseCLIError(
                    .authentication,
                    "No non-interactive credential is available"
                )
            }
            token = available
            record(
                "security.credential",
                "pass",
                "A credential is available from an approved source.",
                duration: credentialStart.duration(to: .now)
            )
        } catch {
            let failure = DatabaseCLIError.map(error)
            record(
                "security.credential",
                "fail",
                failure.message,
                remediation: "Run 'database auth login' for the selected profile.",
                duration: credentialStart.duration(to: .now)
            )
            try writeDoctor(checks)
            throw failure
        }

        let endpointText = command.options.value("endpoint") ?? profile.endpoint
        guard let endpoint = URL(string: endpointText),
              let scheme = endpoint.scheme?.lowercased(),
              ["http", "https", "ws", "wss"].contains(scheme),
              endpoint.host != nil else {
            record("network.endpoint", "fail", "Endpoint URL is invalid.")
            try writeDoctor(checks)
            throw DatabaseCLIError(.input, "Endpoint URL is invalid")
        }
        let networkStart = ContinuousClock.now
        let networkReport = await networkProbe.probe(endpoint)
        var networkFailure: DatabaseCLIError?
        func recordNetworkCheck(
            id: String,
            result: DatabaseNetworkCheckResult
        ) {
            switch result {
            case .passed(let summary):
                record(
                    id,
                    "pass",
                    summary,
                    duration: networkStart.duration(to: .now)
                )
            case .skipped(let summary):
                record(
                    id,
                    "skipped",
                    summary,
                    duration: networkStart.duration(to: .now)
                )
            case .failed(let summary, let remediation):
                record(
                    id,
                    "fail",
                    summary,
                    remediation: remediation,
                    duration: networkStart.duration(to: .now)
                )
                if networkFailure == nil {
                    networkFailure = DatabaseCLIError(.unavailable, summary)
                }
            }
        }
        recordNetworkCheck(id: "network.dns", result: networkReport.dns)
        recordNetworkCheck(id: "network.tcp", result: networkReport.tcp)
        recordNetworkCheck(id: "network.tls", result: networkReport.tls)
        if let networkFailure {
            try writeDoctor(checks)
            throw networkFailure
        }
        let connection = ResolvedConnection(
            profileName: profile.name,
            endpoint: endpoint,
            accessToken: token,
            databaseID: command.options.value("database") ?? profile.databaseID,
            tenantID: command.options.value("tenant") ?? profile.tenantID,
            workspaceID: command.options.value("workspace") ?? profile.workspaceID
        )
        let protocolStart = ContinuousClock.now
        let session: RemoteSession
        do {
            session = try sessionFactory(connection)
        } catch {
            let failure = DatabaseCLIError.map(error)
            record(
                "protocol.capabilities",
                "fail",
                failure.message,
                remediation: "Verify the endpoint scheme and client configuration.",
                duration: protocolStart.duration(to: .now)
            )
            try writeDoctor(checks)
            throw failure
        }
        do {
            let capabilities = try await session.client.database.execute(
                DatabaseOperationCatalog.capabilitiesDescribe,
                request: EmptyOperationPayload()
            )
            record(
                "protocol.capabilities",
                "pass",
                "Authenticated DatabaseWire probe succeeded for runtime \(capabilities.runtimeVersion).",
                duration: protocolStart.duration(to: .now)
            )
        } catch {
            let failure = DatabaseCLIError.map(error)
            await session.shutdown()
            record(
                "protocol.capabilities",
                "fail",
                failure.message,
                remediation: "Verify DNS, TLS, authentication, and routing identity.",
                duration: protocolStart.duration(to: .now)
            )
            try writeDoctor(checks)
            throw failure
        }

        let schemaStart = ContinuousClock.now
        do {
            let schema = try await session.client.database.execute(
                DatabaseOperationCatalog.schemaDescribe,
                request: EmptyOperationPayload()
            )
            record(
                "database.schema",
                "pass",
                "Schema \(schema.version) is readable with \(schema.entities.count) entities.",
                duration: schemaStart.duration(to: .now)
            )
        } catch {
            let failure = DatabaseCLIError.map(error)
            record(
                "database.schema",
                "fail",
                failure.message,
                remediation: "Verify schema capability and authorization.",
                duration: schemaStart.duration(to: .now)
            )
            terminalFailure = failure
        }
        await session.shutdown()
        try writeDoctor(checks)
        if let terminalFailure { throw terminalFailure }
    }

    private func writeDoctor(_ checks: [StrictJSONValue]) throws {
        _ = try output.result(
            StrictJSONWriter.encode(.object([("checks", .array(checks))]))
                + "\n"
        )
    }
}
