import Foundation
import Testing
@testable import DatabaseCommandLine

@Suite("Profile store")
struct ProfileStoreTests {
    @Test("Optional selection distinguishes no configuration from an invalid profile")
    func optionalSelectionPreservesConfigurationFailures() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "database-cli-profile-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                Issue.record("Failed to remove profile fixture: \(error)")
            }
        }
        let store = ProfileStore(
            fileURL: directory.appendingPathComponent("profiles.json")
        )

        #expect(try store.selectedProfileIfConfigured(named: nil) == nil)
        #expect(throws: DatabaseCLIError.self) {
            _ = try store.selectedProfileIfConfigured(named: "missing")
        }

        try Data("not-json".utf8).write(to: store.fileURL)
        #expect(throws: DatabaseCLIError.self) {
            _ = try store.selectedProfileIfConfigured(named: nil)
        }
    }
}
