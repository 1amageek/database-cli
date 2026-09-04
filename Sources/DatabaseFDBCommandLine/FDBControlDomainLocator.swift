import DatabaseEngine
import StorageKit

/// Resolves the `database-framework` catalog root inside one control domain.
///
/// `database-framework` stores its catalog under the Default Partition of the
/// database root Directory:
///
/// ```text
/// <database root>
/// └── default                     Default Partition
///     ├── system
///     │   └── database-framework  catalog and schema registry
///     └── data
/// ```
///
/// Those Directory names are `package`-visible inside `DatabaseEngine`, so this
/// companion executable duplicates them. They are copied from
/// `database-framework/Sources/DatabaseEngine/Directory/DatabaseDirectoryLayout.swift`
/// and must be changed together with that file. The end-to-end catalog test
/// resolves a container written by `DBContainer.open`, so a name that drifts
/// away from the framework layout fails that test rather than silently reading
/// an unrelated keyspace.
struct FDBControlDomainLocator: Sendable {
    static let defaultPartitionName = "default"
    static let systemDirectoryName = "system"
    static let frameworkDirectoryName = "database-framework"

    /// The ordered Directory path of the control domain's database root.
    let rootComponents: [String]

    /// Opens the framework catalog root read-only, creating no Directory.
    ///
    /// A control domain that `database-framework` has never initialized
    /// resolves to no Directory and is reported as not found. Resolution never
    /// falls back to the store root or to another Partition.
    func resolveCatalogRoot(engine: any StorageEngine) async throws -> Subspace {
        let components = rootComponents + [
            Self.defaultPartitionName,
            Self.systemDirectoryName,
            Self.frameworkDirectoryName
        ]
        let address: StorageAddress
        do {
            address = try StorageAddress(components)
        } catch {
            throw FDBCLIError(
                .input,
                """
                Invalid control namespace \
                \(rootComponents.joined(separator: "/")): \(error)
                """
            )
        }
        let access = engine.directoryAccess
        let resolved = try await engine.withTransaction { transaction in
            try await access.openDirectory(at: address, transaction: transaction)
        }
        guard let resolved else {
            throw FDBCLIError(
                .notFound,
                """
                No database framework catalog exists at control namespace \
                \(rootComponents.joined(separator: "/"))
                """
            )
        }
        return resolved.root
    }
}
