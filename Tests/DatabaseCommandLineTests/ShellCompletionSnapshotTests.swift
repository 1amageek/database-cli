import DatabaseKit
import DatabaseTypes
import DatabaseWire
import Testing
@testable import DatabaseCommandLine

@Suite("Shell completion snapshot tests")
struct ShellCompletionSnapshotTests {
    @Test("Static completion is generated from the command catalog")
    func staticCatalogCompletion() {
        let snapshot = ShellCompletionSnapshot(
            catalog: .standard,
            profileNames: ["production", "staging"]
        )

        #expect(snapshot.values(in: "").contains("schema"))
        #expect(snapshot.values(in: "").contains("\\base"))
        #expect(snapshot.values(in: "").contains("\\composition"))
        #expect(snapshot.values(in: "").contains("\\database"))
        #expect(snapshot.values(in: "schema ").contains("show"))
        #expect(snapshot.values(in: "\\profile ") == ["production", "staging"])
        #expect(snapshot.values(in: "schema show --profile ") == [
            "production", "staging",
        ])
    }

    @Test("Advertised capabilities and schema add typed candidates")
    func remoteCandidates() throws {
        let job = try JobOperationIdentifier(
            family: .queryExecute,
            kind: "query-export"
        )
        let capabilities = CapabilitiesDescribeOperation.Response(
            runtimeVersion: "test",
            features: [
                .init(identifier: "schema.describe", version: 1),
                .init(identifier: "query.execute", version: 1),
            ],
            jobOperations: [job]
        )
        let schema = SchemaDescribeOperation.Response(
            version: Schema.Version(1, 0, 0),
            entities: [
                .init(
                    name: "Document",
                    fields: [],
                    indexes: [
                        .init(
                            name: "Document_graph",
                            kind: "graph",
                            fields: []
                        ),
                    ]
                ),
            ]
        )
        let snapshot = ShellCompletionSnapshot(
            catalog: .standard,
            profileNames: [],
            capabilities: capabilities,
            schema: schema
        )

        #expect(snapshot.values(in: "").contains("query"))
        #expect(!snapshot.values(in: "").contains("mutate"))
        #expect(snapshot.values(in: "schema show ").contains("Document"))
        #expect(snapshot.values(in: "index rebuild Document ") == [
            "Document_graph",
        ])
        #expect(snapshot.values(in: "query sql --as-job ") == [
            "query-export",
        ])
    }

}
