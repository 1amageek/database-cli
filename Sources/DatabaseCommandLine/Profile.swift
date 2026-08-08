import Foundation

public struct DatabaseProfile: Codable, Sendable, Hashable {
    public let name: String
    public let endpoint: String
    public let databaseID: String
    public let tenantID: String?
    public let workspaceID: String?
    public let tokenEnvironment: String?

    public init(
        name: String,
        endpoint: String,
        databaseID: String = "main",
        tenantID: String? = nil,
        workspaceID: String? = nil,
        tokenEnvironment: String? = nil
    ) throws {
        guard Self.isValidName(name) else {
            throw DatabaseCLIError(
                .input,
                "Profile names may contain only ASCII letters, digits, '.', '-', and '_'"
            )
        }
        guard let url = URL(string: endpoint),
              let scheme = url.scheme?.lowercased(),
              ["http", "https", "ws", "wss"].contains(scheme),
              url.host != nil else {
            throw DatabaseCLIError(.input, "Profile endpoint is invalid")
        }
        guard !databaseID.isEmpty else {
            throw DatabaseCLIError(.input, "Database identifier must not be empty")
        }
        self.name = name
        self.endpoint = endpoint
        self.databaseID = databaseID
        self.tenantID = tenantID
        self.workspaceID = workspaceID
        self.tokenEnvironment = tokenEnvironment
    }

    private static func isValidName(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        return value.utf8.allSatisfy {
            (65...90).contains($0)
                || (97...122).contains($0)
                || (48...57).contains($0)
                || $0 == 0x2E || $0 == 0x2D || $0 == 0x5F
        }
    }
}

public struct ProfileDocument: Codable, Sendable, Hashable {
    public var activeProfile: String?
    public var profiles: [DatabaseProfile]

    public init(
        activeProfile: String? = nil,
        profiles: [DatabaseProfile] = []
    ) {
        self.activeProfile = activeProfile
        self.profiles = profiles
    }
}

public struct ProfileStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            self.fileURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config", isDirectory: true)
                .appendingPathComponent("database", isDirectory: true)
                .appendingPathComponent("profiles.json", isDirectory: false)
        }
    }

    public func load() throws -> ProfileDocument {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return ProfileDocument()
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let document = try JSONDecoder().decode(ProfileDocument.self, from: data)
            let names = document.profiles.map(\.name)
            guard Set(names).count == names.count else {
                throw DatabaseCLIError(.input, "Profile file contains duplicate names")
            }
            if let active = document.activeProfile,
               !names.contains(active) {
                throw DatabaseCLIError(
                    .input,
                    "Active profile '\(active)' does not exist"
                )
            }
            return document
        } catch let error as DatabaseCLIError {
            throw error
        } catch {
            throw DatabaseCLIError(
                .input,
                "Cannot read profile file: \(error)"
            )
        }
    }

    public func save(_ document: ProfileDocument) throws {
        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let data = try JSONEncoder().encode(document)
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
        } catch {
            throw DatabaseCLIError(
                .input,
                "Cannot write profile file: \(error)"
            )
        }
    }

    public func selectedProfile(
        named requestedName: String?
    ) throws -> DatabaseProfile {
        let document = try load()
        let name = requestedName ?? document.activeProfile
        guard let name else {
            throw DatabaseCLIError(
                .input,
                "No profile selected; use '--profile' or 'database profile use'"
            )
        }
        guard let profile = document.profiles.first(where: { $0.name == name }) else {
            throw DatabaseCLIError(.input, "Profile '\(name)' does not exist")
        }
        return profile
    }
}
