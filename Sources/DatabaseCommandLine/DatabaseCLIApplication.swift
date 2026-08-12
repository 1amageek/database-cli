import DatabaseTypes
import DatabaseWire
import Foundation
import Synchronization

public enum DatabaseCLIVersion {
    public static let current = "26.0812.1"
}

public typealias RemoteSessionFactory = @Sendable (
    ResolvedConnection
) throws -> RemoteSession

public struct DatabaseCLIApplication: Sendable {
    let parser: CommandParser
    let profiles: ProfileStore
    let credentials: CredentialResolver
    let output: OutputWriter
    let sessionFactory: RemoteSessionFactory
    let networkProbe: any DatabaseNetworkProbing

    public init(
        parser: CommandParser = CommandParser(),
        profiles: ProfileStore = ProfileStore(),
        credentials: CredentialResolver = CredentialResolver(),
        output: OutputWriter = OutputWriter(),
        networkProbe: any DatabaseNetworkProbing = DefaultDatabaseNetworkProbe(),
        sessionFactory: @escaping RemoteSessionFactory = {
            try RemoteSession(connection: $0)
        }
    ) {
        self.parser = parser
        self.profiles = profiles
        self.credentials = credentials
        self.output = output
        self.networkProbe = networkProbe
        self.sessionFactory = sessionFactory
    }

    public func run(arguments: [String]) async -> Int32 {
        do {
            try await execute(
                arguments,
                continuationCapture: nil,
                sessionOverride: nil
            )
            return DatabaseCLIExitCode.success.rawValue
        } catch let companion as CompanionExit {
            return companion.code
        } catch {
            let failure = DatabaseCLIError.map(error)
            output.diagnostic("error: \(failure.message)\n")
            return failure.exitCode.rawValue
        }
    }
}

extension DatabaseCLIApplication {
    func execute(
        _ arguments: [String],
        continuationCapture: ContinuationCapture?,
        sessionOverride: RemoteSession?
    ) async throws {
        if arguments.first == "fdb" {
            try await runFDBCompanion(
                arguments: Array(arguments.dropFirst())
            )
            return
        }
        let command = try parser.parse(arguments)
        switch command.path {
        case ["help"]:
            try showHelp(command.positionals)
        case ["version"]:
            _ = try output.result("\(DatabaseCLIVersion.current)\n")
        case let path where path.first == "profile":
            try executeProfile(command)
        case let path where path.first == "auth":
            try executeAuthentication(command)
        case ["shell"]:
            try await DatabaseShell(
                application: self,
                command: command,
                output: output,
                session: sessionOverride
            ).run()
        case ["open"]:
            try await executeOpen(command)
        case ["serve"]:
            try await executeServe(command)
        case let path where path.first == "completion":
            _ = try output.result(
                CompletionGenerator(catalog: parser.catalog).generate(
                    for: path[1]
                )
            )
        case ["doctor"]:
            try await executeDoctor(command)
        default:
            if let sessionOverride {
                try await RemoteCommandExecutor(
                    session: sessionOverride,
                    output: output,
                    continuationSink: { continuation in
                        continuationCapture?.store(continuation)
                    }
                ).execute(command)
                return
            }
            let connection = try ResolvedConnection.resolve(
                options: command.options,
                profileStore: profiles,
                credentials: credentials
            )
            let session = try sessionFactory(connection)
            do {
                try await RemoteCommandExecutor(
                    session: session,
                    output: output,
                    continuationSink: { continuation in
                        continuationCapture?.store(continuation)
                    }
                ).execute(command)
                await session.shutdown()
            } catch {
                await session.shutdown()
                throw error
            }
        }
    }

    func executeOpen(_ command: ParsedCommand) async throws {
        let storage = try StandaloneStorageSelection.resolve(command)
        let maximumFrameBytes = try command.options.integer(
            "maximum-frame-bytes",
            default: 16 * 1_024 * 1_024
        )
        guard maximumFrameBytes > 0 else {
            throw DatabaseCLIError(
                .input,
                "'--maximum-frame-bytes' must be positive"
            )
        }
        let local = try await LocalDatabaseSession.open(
            executable: DatabaseServerExecutable.adjacent(),
            storage: storage,
            maximumFrameBytes: maximumFrameBytes
        )
        do {
            let capabilities = try await local.remoteSession.client.database.execute(
                DatabaseOperationCatalog.capabilitiesDescribe,
                request: EmptyOperationPayload()
            )
            guard capabilities.features.contains(where: {
                $0.identifier == "schema.execute" && $0.version == 1
            }) else {
                throw DatabaseCLIError(
                    .unavailable,
                    "database-server does not advertise schema.execute version 1"
                )
            }
            if let schema = command.options.value("schema") {
                try await applySchema(
                    schema,
                    to: local.remoteSession
                )
            }
            try await DatabaseShell(
                application: self,
                command: command,
                output: output,
                session: local.remoteSession,
                connectionName: "local",
                databaseName: "main"
            ).run()
            await local.shutdown()
        } catch {
            await local.shutdown()
            throw error
        }
    }

    func executeServe(_ command: ParsedCommand) async throws {
        guard let profileName = command.options.value("profile") else {
            throw DatabaseCLIError(.input, "Database serve requires '--profile'")
        }
        let explicitConfiguration = command.options.value("config")
        let configurationURL = try serverConfigurationURL(
            explicit: explicitConfiguration,
            profileName: profileName
        )
        let hasStorageSelection = StandaloneStorageSelection
            .hasExplicitSelection(command)
        if explicitConfiguration != nil, hasStorageSelection {
            throw DatabaseCLIError(
                .input,
                "Storage options cannot be combined with '--config'"
            )
        }
        let storageArguments: [String]
        if explicitConfiguration != nil
            || (!hasStorageSelection
                && FileManager.default.fileExists(atPath: configurationURL.path)) {
            storageArguments = []
        } else {
            storageArguments = try StandaloneStorageSelection
                .resolve(command).serverArguments
        }
        let listener = try command.options.value("listen")
            .map(parseListener)
        try SecureLocalFile.ensureDirectory(
            configurationURL.deletingLastPathComponent()
        )
        let executable = try DatabaseServerExecutable.adjacent()
        let originalDocument = try profiles.load()
        let originalStoredToken = try credentials.storedToken(
            profile: profileName
        )
        var profileWasCreated = false
        var credentialWasChanged = false
        var preparationCommitted = false

        do {
            let bootstrap = try await DatabaseServerBootstrap(
                executable: executable
            ).prepare(
                request: .init(
                    configurationURL: configurationURL,
                    storageArguments: storageArguments,
                    host: listener?.host,
                    port: listener?.port,
                    databaseID: command.options.value("database") ?? "main",
                    tenantID: command.options.value("tenant"),
                    workspaceID: command.options.value("workspace")
                )
            ) { response in
                let profile = try DatabaseProfile(
                    name: profileName,
                    endpoint: response.endpoint,
                    databaseID: response.databaseID,
                    tenantID: response.tenantID,
                    workspaceID: response.workspaceID
                )
                var document = originalDocument
                if let existing = document.profiles.first(where: {
                    $0.name == profileName
                }) {
                    guard existing.endpoint == profile.endpoint,
                          existing.databaseID == profile.databaseID,
                          existing.tenantID == profile.tenantID,
                          existing.workspaceID == profile.workspaceID else {
                        throw DatabaseCLIError(
                            .conflict,
                            "Profile '\(profileName)' points to a different server"
                        )
                    }
                } else {
                    document.profiles.append(profile)
                    if document.activeProfile == nil {
                        document.activeProfile = profileName
                    }
                    try profiles.save(document)
                    profileWasCreated = true
                }

                if let token = response.token {
                    try credentials.storeToken(token, profile: profileName)
                    credentialWasChanged = true
                } else if originalStoredToken == nil {
                    throw DatabaseCLIError(
                        .authentication,
                        "The server already has credentials, but profile '\(profileName)' has no Keychain token"
                    )
                }
            }
            preparationCommitted = true

            output.diagnostic(
                "Serving \(bootstrap.endpoint) with profile '\(profileName)'.\n"
            )
            try await DatabaseServerForegroundProcess(
                executable: executable
            ).run(
                configurationURL: configurationURL,
                host: listener?.host,
                port: listener?.port
            )
        } catch {
            let originalError = error
            guard !preparationCommitted else {
                throw originalError
            }
            do {
                if credentialWasChanged {
                    if let originalStoredToken {
                        try credentials.storeToken(
                            originalStoredToken,
                            profile: profileName
                        )
                    } else {
                        try credentials.removeToken(profile: profileName)
                    }
                }
                if profileWasCreated {
                    try profiles.save(originalDocument)
                }
            } catch {
                throw DatabaseCLIError(
                    .internalFailure,
                    "Database serve failed and client state rollback also failed: \(error)"
                )
            }
            throw originalError
        }
    }

    func serverConfigurationURL(
        explicit: String?,
        profileName: String
    ) throws -> URL {
        if let explicit {
            guard explicit != "@-" else {
                throw DatabaseCLIError(
                    .input,
                    "Server configuration must be a filesystem path"
                )
            }
            let path = explicit.hasPrefix("@")
                ? String(explicit.dropFirst())
                : explicit
            guard !path.isEmpty else {
                throw DatabaseCLIError(.input, "Server configuration path is empty")
            }
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        return DatabaseCLIPaths.configurationDirectory()
            .appendingPathComponent("servers", isDirectory: true)
            .appendingPathComponent(profileName, isDirectory: true)
            .appendingPathComponent("server.json", isDirectory: false)
    }

    func parseListener(_ rawValue: String) throws -> (host: String, port: Int) {
        guard let components = URLComponents(string: "tcp://\(rawValue)"),
              components.scheme == "tcp",
              let parsedHost = components.host,
              !parsedHost.isEmpty,
              let port = components.port,
              (1...65_535).contains(port),
              components.user == nil,
              components.password == nil,
              components.path.isEmpty else {
            throw DatabaseCLIError(
                .input,
                "Listener must use 'host:port' or '[ipv6]:port'"
            )
        }
        let host: String
        if parsedHost.hasPrefix("["), parsedHost.hasSuffix("]") {
            host = String(parsedHost.dropFirst().dropLast())
        } else {
            host = parsedHost
        }
        return (host, port)
    }

    func applySchema(
        _ specification: String,
        to session: RemoteSession
    ) async throws {
        let manifest = try WireRequestBuilder().schemaManifest(specification)
        let planResponse = try await session.client.database.execute(
            DatabaseOperationCatalog.schemaExecute,
            request: SchemaExecuteOperation.Request(
                invocation: .plan(
                    manifest: manifest,
                    expectedFingerprint: nil
                )
            )
        )
        guard case .plan(let plan) = planResponse else {
            throw DatabaseCLIError(
                .internalFailure,
                "Schema plan returned an unexpected response"
            )
        }
        guard let currentFingerprint = plan.currentFingerprint else {
            throw DatabaseCLIError(
                .internalFailure,
                "Schema plan did not return the current fingerprint"
            )
        }

        let idempotencyKey = "database-open-\(UUID().uuidString.lowercased())"
        let applyResponse = try await session.client.database.execute(
            DatabaseOperationCatalog.schemaExecute,
            request: SchemaExecuteOperation.Request(
                invocation: .apply(
                    manifest: manifest,
                    expectedFingerprint: currentFingerprint,
                    idempotencyKey: idempotencyKey
                )
            ),
            metadata: OperationRequestMetadata(
                idempotencyKey: idempotencyKey
            )
        )
        guard case .applied(let applied) = applyResponse else {
            throw DatabaseCLIError(
                .internalFailure,
                "Schema apply returned an unexpected response"
            )
        }
        output.diagnostic(
            "Applied schema \(applied.schemaVersion) at generation \(applied.generation).\n"
        )
    }

    func showHelp(_ path: [String]) throws {
        let catalog = parser.catalog
        if let command = catalog.command(for: path) {
            var text = "database \(command.path.joined(separator: " "))"
            text += " — \(command.summary)\n\n"
            text += "Usage:\n  database \(command.path.joined(separator: " "))"
            if !command.usage.isEmpty { text += " \(command.usage)" }
            if !command.options.isEmpty {
                text += " [options]"
            }
            text += "\n"
            if let capability = command.capability {
                text += "\nCapability:\n  \(capability)\n"
            }
            if !command.options.isEmpty {
                text += "\nOptions:\n"
                for option in command.options.sorted(by: { $0.name < $1.name }) {
                    text += helpLine(for: option)
                }
            }
            if !command.requiredAnyOf.isEmpty {
                text += "\nRequirements:\n"
                for requirement in command.requiredAnyOf {
                    text += "  one of: "
                        + requirement.sorted().map { "--\($0)" }
                            .joined(separator: ", ")
                        + "\n"
                }
            }
            _ = try output.result(text + "\n")
            return
        }

        let matches = catalog.commands.filter {
            path.isEmpty || $0.path.starts(with: path)
        }.sorted {
            $0.path.lexicographicallyPrecedes($1.path)
        }
        guard !matches.isEmpty else {
            throw DatabaseCLIError(
                .input,
                "Unknown help topic '\(path.joined(separator: " "))'"
            )
        }
        var text = path.isEmpty
            ? "database — authenticated DatabaseWire command line\n\n"
            : "database \(path.joined(separator: " "))\n\n"
        text += "Usage:\n  database <command> [options]\n\nCommands:\n"
        for command in matches where command.path != ["help"] {
            text += "  \(command.path.joined(separator: " "))"
            if !command.usage.isEmpty { text += " \(command.usage)" }
            text += "\n      \(command.summary)\n"
        }
        text += "\nUse 'database help <command>' for exact options.\n"
        _ = try output.result(text)
    }

    func helpLine(for option: CommandOptionDescriptor) -> String {
        var spelling = "  --\(option.name)"
        if case .value(let name) = option.valueMode {
            spelling += " <\(name)>"
        }
        var contracts: [String] = []
        if option.minimumOccurrences > 0 { contracts.append("required") }
        if option.maximumOccurrences == nil { contracts.append("repeatable") }
        if let value = option.defaultValue {
            contracts.append("default: \(value)")
        }
        if !option.conflictsWith.isEmpty {
            contracts.append(
                "conflicts: "
                    + option.conflictsWith.sorted().map { "--\($0)" }
                        .joined(separator: ", ")
            )
        }
        if !option.requires.isEmpty {
            contracts.append(
                "requires: "
                    + option.requires.sorted().map { "--\($0)" }
                        .joined(separator: ", ")
            )
        }
        let contract = contracts.isEmpty
            ? ""
            : " [\(contracts.joined(separator: "; "))]"
        return "\(spelling)\(contract)\n      \(option.summary)\n"
    }

    func executeProfile(_ command: ParsedCommand) throws {
        var document = try profiles.load()
        switch command.path {
        case ["profile", "list"]:
            let values = document.profiles.sorted { $0.name < $1.name }.map {
                profileNode($0, active: $0.name == document.activeProfile)
            }
            try writeJSON(.array(values))
        case ["profile", "show"]:
            guard let profile = document.profiles.first(where: {
                $0.name == command.positionals[0]
            }) else {
                throw DatabaseCLIError(.notFound, "Profile does not exist")
            }
            try writeJSON(
                profileNode(
                    profile,
                    active: profile.name == document.activeProfile
                )
            )
        case ["profile", "create"]:
            let name = command.positionals[0]
            guard !document.profiles.contains(where: { $0.name == name }) else {
                throw DatabaseCLIError(.conflict, "Profile already exists")
            }
            guard let endpoint = command.options.value("endpoint") else {
                throw DatabaseCLIError(
                    .input,
                    "Profile creation requires '--endpoint'"
                )
            }
            let profile = try DatabaseProfile(
                name: name,
                endpoint: endpoint,
                databaseID: command.options.value("database") ?? "main",
                tenantID: command.options.value("tenant"),
                workspaceID: command.options.value("workspace"),
                tokenEnvironment: command.options.value("token-environment")
            )
            document.profiles.append(profile)
            if document.activeProfile == nil { document.activeProfile = name }
            try profiles.save(document)
            try writeJSON(profileNode(profile, active: document.activeProfile == name))
        case ["profile", "use"]:
            let name = command.positionals[0]
            guard document.profiles.contains(where: { $0.name == name }) else {
                throw DatabaseCLIError(.notFound, "Profile does not exist")
            }
            document.activeProfile = name
            try profiles.save(document)
            try writeJSON(.object([("activeProfile", .string(name))]))
        case ["profile", "remove"]:
            let name = command.positionals[0]
            guard let index = document.profiles.firstIndex(where: {
                $0.name == name
            }) else {
                throw DatabaseCLIError(.notFound, "Profile does not exist")
            }
            document.profiles.remove(at: index)
            if document.activeProfile == name { document.activeProfile = nil }
            try profiles.save(document)
            try credentials.removeToken(profile: name)
            try writeJSON(.object([("removedProfile", .string(name))]))
        default:
            throw DatabaseCLIError(.input, "Unknown profile operation")
        }
    }

    func executeAuthentication(_ command: ParsedCommand) throws {
        let profile = try profiles.selectedProfile(
            named: command.options.value("profile")
        )
        switch command.path {
        case ["auth", "login"]:
            let token = try credentials.loginToken(
                environmentName: command.options.value("token-environment")
            )
            try credentials.storeToken(token, profile: profile.name)
            try writeJSON(.object([
                ("profile", .string(profile.name)),
                ("authenticated", .bool(true)),
            ]))
        case ["auth", "logout"]:
            try credentials.removeToken(profile: profile.name)
            try writeJSON(.object([
                ("profile", .string(profile.name)),
                ("authenticated", .bool(false)),
            ]))
        default:
            throw DatabaseCLIError(.input, "Unknown authentication operation")
        }
    }

    func profileNode(
        _ profile: DatabaseProfile,
        active: Bool
    ) -> StrictJSONValue {
        .object([
            ("name", .string(profile.name)),
            ("active", .bool(active)),
            ("endpoint", .string(profile.endpoint)),
            ("database", .string(profile.databaseID)),
            ("tenant", profile.tenantID.map(StrictJSONValue.string) ?? .null),
            ("workspace", profile.workspaceID.map(StrictJSONValue.string) ?? .null),
            ("tokenEnvironment", profile.tokenEnvironment.map(StrictJSONValue.string) ?? .null),
        ])
    }

    func writeJSON(_ value: StrictJSONValue) throws {
        _ = try output.result(StrictJSONWriter.encode(value) + "\n")
    }

    func runFDBCompanion(arguments: [String]) async throws {
        guard let executable = Bundle.main.executableURL else {
            throw DatabaseCLIError(.unavailable, "Cannot locate database executable")
        }
        let helper = executable.deletingLastPathComponent()
            .appendingPathComponent("database-fdb", isDirectory: false)
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw DatabaseCLIError(
                .unavailable,
                "database-fdb companion is not installed beside database"
            )
        }
        let process = Process()
        process.executableURL = helper
        process.arguments = arguments
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        var environment = ProcessInfo.processInfo.environment
        environment["DATABASE_FDB_EXPECTED_VERSION"] = DatabaseCLIVersion.current
        process.environment = environment
        let termination = ProcessTerminationWaiter()
        process.terminationHandler = { _ in termination.finish() }
        do {
            try process.run()
        } catch {
            throw DatabaseCLIError(
                .unavailable,
                "Cannot execute database-fdb: \(error)"
            )
        }
        await withTaskCancellationHandler {
            await termination.wait()
        } onCancel: {
            process.interrupt()
        }
        if process.terminationReason == .uncaughtSignal {
            let signalExit = 128 + process.terminationStatus
            if signalExit == DatabaseCLIExitCode.cancelled.rawValue {
                throw DatabaseCLIError(.cancelled, "database-fdb was cancelled")
            }
            throw DatabaseCLIError(
                .internalFailure,
                "database-fdb terminated by signal \(process.terminationStatus)"
            )
        }
        guard process.terminationStatus == 0 else {
            throw CompanionExit(
                code: exitCode(for: process.terminationStatus).rawValue
            )
        }
    }

    func exitCode(for rawValue: Int32) -> DatabaseCLIExitCode {
        DatabaseCLIExitCode(rawValue: rawValue) ?? .internalFailure
    }
}

private struct CompanionExit: Error, Sendable {
    let code: Int32
}

private final class ProcessTerminationWaiter: Sendable {
    private struct State {
        var isFinished = false
        var continuation: CheckedContinuation<Void, Never>?
    }

    private let state = Mutex(State())

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeImmediately = state.withLock { state in
                if state.isFinished { return true }
                state.continuation = continuation
                return false
            }
            if resumeImmediately { continuation.resume() }
        }
    }

    func finish() {
        let continuation = state.withLock { state in
            state.isFinished = true
            return state.continuation.take()
        }
        continuation?.resume()
    }
}

final class ContinuationCapture: Sendable {
    private let value = Mutex<ByteString?>(nil)

    func store(_ continuation: ByteString?) {
        value.withLock { $0 = continuation?.detached() }
    }

    func load() -> ByteString? {
        value.withLock { $0?.detached() }
    }
}
