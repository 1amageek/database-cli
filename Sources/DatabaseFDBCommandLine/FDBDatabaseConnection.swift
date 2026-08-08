import FDBStorage
import FoundationDB
import StorageKit

struct FDBDatabaseConnection: Sendable {
    func withEngine<Result: Sendable>(
        clusterFile: String,
        operation: @escaping @Sendable (FDBStorageEngine) async throws -> Result
    ) async throws -> Result {
        guard !FDBClient.isInitialized else {
            throw FDBCLIError(
                .internalFailure,
                "FoundationDB client was initialized before cluster selection"
            )
        }
        try await FDBClient.initialize()

        let engine: FDBStorageEngine
        do {
            engine = try await makeEngine(clusterFile: clusterFile)
        } catch {
            FDBClient.shutdown()
            throw error
        }

        do {
            let result = try await operation(engine)
            await engine.waitUntilShutdown()
            FDBClient.shutdown()
            return result
        } catch {
            await engine.waitUntilShutdown()
            FDBClient.shutdown()
            throw error
        }
    }

    private func makeEngine(
        clusterFile: String
    ) async throws -> FDBStorageEngine {
        let database = try FDBClient.openDatabase(clusterFilePath: clusterFile)
        return try await FDBStorageEngine(
            configuration: .init(database: database)
        )
    }
}
