import Foundation

enum DatabaseCLIPaths {
    static func configurationDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let path = environment["DATABASE_CLI_CONFIG_HOME"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
                .standardizedFileURL
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("database", isDirectory: true)
    }
}
