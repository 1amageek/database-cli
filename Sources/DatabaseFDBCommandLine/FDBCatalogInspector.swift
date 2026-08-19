import DatabaseEngine
import DatabaseKit
import StorageKit
import StorageKitSystemClock

struct FDBCatalogInspector: Sendable {
    let output: FDBOutput

    func list(engine: any StorageEngine, root: Subspace) async throws {
        let entities = try await loadEntities(engine: engine, root: root)
        for entity in entities {
            try output.json([
                "name": entity.name,
                "fieldCount": String(entity.fields.count),
                "indexCount": String(entity.indexes.count),
            ])
        }
    }

    func show(
        name: String,
        engine: any StorageEngine,
        root: Subspace
    ) async throws {
        let entities = try await loadEntities(engine: engine, root: root)
        guard let entity = entities.first(where: { $0.name == name }) else {
            throw FDBCLIError(.notFound, "Catalog entity '\(name)' was not found")
        }
        let fields: [[String: Any]] = entity.fields.map { field in
            var value: [String: Any] = [
                "name": field.name,
                "type": field.type.rawValue,
                "optional": field.isOptional,
                "array": field.isArray,
            ]
            if let cases = entity.enumMetadata[field.name] {
                value["enumCases"] = cases
            }
            return value
        }
        let indexes: [[String: Any]] = entity.indexes.map { index in
            [
                "name": index.name,
                "type": index.type.diagnosticName,
                "fields": index.fieldNames,
                "unique": index.isUnique,
            ]
        }
        try output.json([
            "name": entity.name,
            "fields": fields,
            "indexes": indexes,
        ])
    }
}

private extension FDBCatalogInspector {
    func loadEntities(
        engine: any StorageEngine,
        root: Subspace
    ) async throws -> [Schema.Entity] {
        let clock = SystemStorageClock()
        _ = try await DatabaseFormatCatalog(
            database: engine,
            root: root,
            clock: clock
        ).loadRequired()
        return try await SchemaRegistry(
            database: engine,
            root: root,
            clock: clock
        ).loadAll().sorted { $0.name < $1.name }
    }
}
