import Foundation
import Testing
@testable import DatabaseCommandLine

@Suite("Profile store")
struct ProfileStoreTests {
    @Test("Saving creates every private directory component securely")
    func saveCreatesPrivateDirectoryHierarchy() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "database-cli-private-profile-\(UUID().uuidString)",
                isDirectory: true
            )
        defer {
            do {
                try FileManager.default.removeItem(at: root)
            } catch where (error as NSError).code
                    == NSFileNoSuchFileError {
            } catch {
                Issue.record("Failed to remove profile fixture: \(error)")
            }
        }
        let configuration = root
            .appendingPathComponent("config", isDirectory: true)
        let profiles = configuration
            .appendingPathComponent("profiles", isDirectory: true)
        let store = ProfileStore(
            fileURL: profiles.appendingPathComponent("profiles.json")
        )

        try store.save(ProfileDocument())

        for directory in [root, configuration, profiles] {
            let attributes = try FileManager.default.attributesOfItem(
                atPath: directory.path
            )
            #expect(
                (attributes[.posixPermissions] as? NSNumber)?.intValue
                    == 0o700
            )
        }
        let attributes = try FileManager.default.attributesOfItem(
            atPath: store.fileURL.path
        )
        #expect(
            (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600
        )
    }

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
