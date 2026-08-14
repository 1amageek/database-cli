import Foundation

struct StandaloneStorageSelection: Sendable, Equatable {
    private enum Backend: String {
        case sqlite
        case postgreSQL = "postgresql"
        case foundationDB = "foundationdb"
    }

    let serverArguments: [String]

    static func resolve(_ command: ParsedCommand) throws -> Self {
        let backendValue = command.options.value("storage") ?? Backend.sqlite.rawValue
        guard let backend = Backend(rawValue: backendValue) else {
            throw DatabaseCLIError(
                .input,
                "'--storage' must be sqlite, postgresql, or foundationdb"
            )
        }

        switch backend {
        case .sqlite:
            return try sqlite(command)
        case .postgreSQL:
            return try postgreSQL(command)
        case .foundationDB:
            return try foundationDB(command)
        }
    }

    static func hasExplicitSelection(_ command: ParsedCommand) -> Bool {
        !command.positionals.isEmpty
            || localOptionNames.contains(where: command.options.contains)
    }

    private static func sqlite(_ command: ParsedCommand) throws -> Self {
        try rejectOptions(postgreSQLOptionNames + foundationDBOptionNames, in: command)
        let memory = command.options.contains("memory")
        let path = command.positionals.first
        guard memory != (path != nil) else {
            throw DatabaseCLIError(
                .input,
                "SQLite requires exactly one database path or '--memory'"
            )
        }
        if memory {
            return Self(
                serverArguments: ["--storage", "sqlite", "--memory"]
                    + (try multipleBasesNamespaceArguments(command, backend: .sqlite))
            )
        }
        guard let path else {
            throw DatabaseCLIError(.input, "SQLite database path is required")
        }
        return Self(
            serverArguments: [
                "--storage", "sqlite",
                "--path", URL(fileURLWithPath: path).standardizedFileURL.path,
            ] + (try multipleBasesNamespaceArguments(command, backend: .sqlite))
        )
    }

    private static func postgreSQL(_ command: ParsedCommand) throws -> Self {
        try rejectSQLiteInput(command)
        try rejectOptions(foundationDBOptionNames, in: command)

        let host = command.options.value("postgres-host")
        let socket = command.options.value("postgres-unix-socket")
        guard (host != nil) != (socket != nil) else {
            throw DatabaseCLIError(
                .input,
                "PostgreSQL requires exactly one of '--postgres-host' or '--postgres-unix-socket'"
            )
        }
        guard let user = command.options.value("postgres-user") else {
            throw DatabaseCLIError(.input, "PostgreSQL requires '--postgres-user'")
        }
        guard let database = command.options.value("postgres-database") else {
            throw DatabaseCLIError(.input, "PostgreSQL requires '--postgres-database'")
        }
        let port = try command.options.integer("postgres-port", default: 5_432)
        guard (1...65_535).contains(port) else {
            throw DatabaseCLIError(
                .input,
                "'--postgres-port' must be between 1 and 65535"
            )
        }
        let tls = command.options.value("postgres-tls") ?? "disable"
        guard tls == "disable" || tls == "require" else {
            throw DatabaseCLIError(
                .input,
                "'--postgres-tls' must be disable or require"
            )
        }
        if socket != nil, tls != "disable" {
            throw DatabaseCLIError(
                .input,
                "PostgreSQL TLS requires a TCP host"
            )
        }
        let schemaManagement = command.options.value(
            "postgres-schema-management"
        ) ?? "create-if-needed"
        guard schemaManagement == "create-if-needed"
                || schemaManagement == "assume-exists" else {
            throw DatabaseCLIError(
                .input,
                "'--postgres-schema-management' must be create-if-needed or assume-exists"
            )
        }

        var arguments = ["--storage", "postgresql"]
        if let host {
            arguments.append(contentsOf: ["--postgres-host", host])
            arguments.append(contentsOf: ["--postgres-port", String(port)])
        }
        if let socket {
            arguments.append(contentsOf: [
                "--postgres-unix-socket",
                URL(fileURLWithPath: socket).standardizedFileURL.path,
            ])
        }
        arguments.append(contentsOf: ["--postgres-user", user])
        if let passwordFile = command.options.value("postgres-password-file") {
            arguments.append(contentsOf: [
                "--postgres-password-file",
                URL(fileURLWithPath: passwordFile).standardizedFileURL.path,
            ])
        }
        arguments.append(contentsOf: ["--postgres-database", database])
        arguments.append(contentsOf: [
            "--postgres-table",
            command.options.value("postgres-table") ?? "kv_store",
            "--postgres-schema-management", schemaManagement,
            "--postgres-tls", tls,
        ])
        arguments.append(contentsOf: try multipleBasesNamespaceArguments(
            command,
            backend: .postgreSQL
        ))
        return Self(serverArguments: arguments)
    }

    private static func foundationDB(_ command: ParsedCommand) throws -> Self {
        try rejectSQLiteInput(command)
        try rejectOptions(postgreSQLOptionNames, in: command)
        guard let clusterFile = command.options.value("fdb-cluster-file") else {
            throw DatabaseCLIError(
                .input,
                "FoundationDB requires '--fdb-cluster-file'"
            )
        }
        let directory = command.options.values("fdb-directory")
        guard !directory.isEmpty,
              directory.allSatisfy({ !$0.isEmpty }) else {
            throw DatabaseCLIError(
                .input,
                "FoundationDB requires at least one '--fdb-directory <component>'"
            )
        }
        var arguments = [
            "--storage", "foundationdb",
            "--fdb-cluster-file",
            URL(fileURLWithPath: clusterFile).standardizedFileURL.path,
        ]
        for component in directory {
            arguments.append(contentsOf: ["--fdb-directory", component])
        }
        arguments.append(contentsOf: try multipleBasesNamespaceArguments(
            command,
            backend: .foundationDB
        ))
        return Self(
            serverArguments: arguments
        )
    }

    private static func rejectSQLiteInput(_ command: ParsedCommand) throws {
        guard command.positionals.isEmpty,
              !command.options.contains("memory") else {
            throw DatabaseCLIError(
                .input,
                "A SQLite path or '--memory' cannot be used with the selected storage"
            )
        }
    }

    private static func rejectOptions(
        _ names: [String],
        in command: ParsedCommand
    ) throws {
        if let name = names.first(where: command.options.contains) {
            throw DatabaseCLIError(
                .input,
                "'--\(name)' cannot be used with '--storage \(command.options.value("storage") ?? "sqlite")'"
            )
        }
    }

    private static func multipleBasesNamespaceArguments(
        _ command: ParsedCommand,
        backend: Backend
    ) throws -> [String] {
        #if DATABASE_CLI_MULTIPLE_BASES
        let components = command.options.values("domain-namespace")
        if backend == .foundationDB {
            guard components.isEmpty else {
                throw DatabaseCLIError(
                    .input,
                    "FoundationDB uses '--fdb-directory', not '--domain-namespace'"
                )
            }
            return []
        }
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty }) else {
            throw DatabaseCLIError(
                .input,
                "MultipleBases requires at least one '--domain-namespace <component>'"
            )
        }
        var arguments: [String] = []
        arguments.reserveCapacity(components.count * 2)
        for component in components {
            arguments.append(contentsOf: ["--domain-namespace", component])
        }
        return arguments
        #else
        _ = command
        _ = backend
        return []
        #endif
    }

    private static let postgreSQLOptionNames = [
        "postgres-host", "postgres-port", "postgres-unix-socket",
        "postgres-user", "postgres-password-file", "postgres-database",
        "postgres-table", "postgres-schema-management", "postgres-tls",
    ]
    private static let foundationDBOptionNames = [
        "fdb-cluster-file", "fdb-directory",
    ]
    private static var localOptionNames: [String] {
        #if DATABASE_CLI_MULTIPLE_BASES
        ["storage", "memory"]
            + postgreSQLOptionNames
            + foundationDBOptionNames
            + ["domain-namespace"]
        #else
        ["storage", "memory"]
            + postgreSQLOptionNames
            + foundationDBOptionNames
        #endif
    }
}
