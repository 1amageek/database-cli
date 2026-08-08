import DatabaseTypes
import Foundation
import Synchronization

public enum DatabaseCLIVersion {
    public static let current = "26.0808.1"
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

    public init(
        parser: CommandParser = CommandParser(),
        profiles: ProfileStore = ProfileStore(),
        credentials: CredentialResolver = CredentialResolver(),
        output: OutputWriter = OutputWriter(),
        sessionFactory: @escaping RemoteSessionFactory = {
            try RemoteSession(connection: $0)
        }
    ) {
        self.parser = parser
        self.profiles = profiles
        self.credentials = credentials
        self.output = output
        self.sessionFactory = sessionFactory
    }

    public func run(arguments: [String]) async -> Int32 {
        do {
            try await execute(arguments, continuationCapture: nil)
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
        continuationCapture: ContinuationCapture?
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
                output: output
            ).run()
        default:
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

    func showHelp(_ path: [String]) throws {
        let heading = path.isEmpty
            ? "database — authenticated DatabaseWire command line"
            : "database \(path.joined(separator: " "))"
        let text = """
        \(heading)

        Usage:
          database <command> [options]
          database shell [--persist-history]

        Commands:
          profile create|list|show|use|remove
          auth login|logout
          capabilities
          schema list|show
          query sql|sparql
          mutate sql|sparql
          entity insert|update|upsert|delete|apply
          graph shortest-path|weighted-shortest-path|page-rank|community
          graph cycles|strongly-connected-components|topological-sort
          ontology describe|upsert|delete|reason|hierarchy|validate-schema
          shacl describe|upsert|delete|validate
          command run
          migration status|run
          index status|rebuild
          maintenance compact
          job status|wait|result|cancel
          fdb cluster|catalog|raw

        Common connection options:
          --profile <name>
          --endpoint <http[s]://...|ws[s]://...>
          --database <id> --tenant <id> --workspace <id>

        Common execution options:
          --trace-id <id> --idempotency-key <key>
          --maximum-rows <n> --maximum-work-units <n>
          --maximum-intermediate-rows <n>
          --maximum-intermediate-bytes <n>
          --timeout-milliseconds <n>
          --page-size <n> --continuation <base64url>
          --output table|jsonl|json|csv|nquads
          --as-job <advertised-kind>

        Fetching every page requires all three safety limits:
          --all --max-total-rows <n> --max-total-bytes <n> --max-pages <n>

        Structured values accept inline JSON, @path, or @- for stdin.
        """
        _ = try output.result(text + "\n")
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
