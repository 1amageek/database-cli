import Darwin
import Foundation
import Security

public protocol CredentialStore: Sendable {
    func read(profile: String) throws -> String?
    func write(_ token: String, profile: String) throws
    func remove(profile: String) throws
}

public struct KeychainCredentialStore: CredentialStore {
    private let service = "com.1amageek.database-cli"

    public init() {}

    public func read(profile: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profile,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8) else {
            throw keychainError(status, operation: "read")
        }
        return token
    }

    public func write(_ token: String, profile: String) throws {
        guard !token.isEmpty else {
            throw DatabaseCLIError(.authentication, "Access token is empty")
        }
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profile,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String:
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(
            identity as CFDictionary,
            attributes as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw keychainError(updateStatus, operation: "update")
        }
        var item = identity
        attributes.forEach { item[$0.key] = $0.value }
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw keychainError(addStatus, operation: "write")
        }
    }

    public func remove(profile: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profile,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw keychainError(status, operation: "remove")
        }
    }

    private func keychainError(
        _ status: OSStatus,
        operation: String
    ) -> DatabaseCLIError {
        let detail = SecCopyErrorMessageString(status, nil) as String?
        return DatabaseCLIError(
            .authentication,
            "Keychain \(operation) failed: \(detail ?? String(status))"
        )
    }
}

public struct CredentialResolver: Sendable {
    private let store: any CredentialStore
    private let environment: [String: String]

    public init(
        store: any CredentialStore = KeychainCredentialStore(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.store = store
        self.environment = environment
    }

    public func resolve(for profile: DatabaseProfile) throws -> String {
        if let token = try store.read(profile: profile.name), !token.isEmpty {
            return token
        }
        if let name = profile.tokenEnvironment,
           let token = environment[name], !token.isEmpty {
            return token
        }
        if let token = environment["DATABASE_ACCESS_TOKEN"], !token.isEmpty {
            return token
        }
        return try SecureTokenPrompt.read(
            prompt: "Access token for \(profile.name): "
        )
    }

    public func resolvedTokenIfAvailable(
        for profile: DatabaseProfile
    ) throws -> String? {
        if let token = try store.read(profile: profile.name), !token.isEmpty {
            return token
        }
        if let name = profile.tokenEnvironment,
           let token = environment[name], !token.isEmpty {
            return token
        }
        if let token = environment["DATABASE_ACCESS_TOKEN"], !token.isEmpty {
            return token
        }
        return nil
    }

    public func storeToken(_ token: String, profile: String) throws {
        try store.write(token, profile: profile)
    }

    func storedToken(profile: String) throws -> String? {
        try store.read(profile: profile)
    }

    public func removeToken(profile: String) throws {
        try store.remove(profile: profile)
    }

    public func loginToken(environmentName: String?) throws -> String {
        if let environmentName {
            guard let token = environment[environmentName], !token.isEmpty else {
                throw DatabaseCLIError(
                    .authentication,
                    "Environment variable '\(environmentName)' has no access token"
                )
            }
            return token
        }
        return try SecureTokenPrompt.read(prompt: "Access token: ")
    }
}

enum SecureTokenPrompt {
    static func read(prompt: String) throws -> String {
        guard isatty(STDIN_FILENO) == 1 else {
            throw DatabaseCLIError(
                .authentication,
                "No access token is available and standard input is not a TTY"
            )
        }
        var original = termios()
        guard tcgetattr(STDIN_FILENO, &original) == 0 else {
            throw DatabaseCLIError(.authentication, "Cannot read terminal settings")
        }
        var hidden = original
        hidden.c_lflag &= ~tcflag_t(ECHO)
        guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &hidden) == 0 else {
            throw DatabaseCLIError(.authentication, "Cannot disable terminal echo")
        }
        defer {
            _ = tcsetattr(STDIN_FILENO, TCSAFLUSH, &original)
            FileHandle.standardError.write(Data("\n".utf8))
        }
        FileHandle.standardError.write(Data(prompt.utf8))
        guard let token = readLine(), !token.isEmpty else {
            throw DatabaseCLIError(.authentication, "Access token is empty")
        }
        return token
    }
}
