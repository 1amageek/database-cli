// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "database-cli",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "database", targets: ["DatabaseCLIExecutable"]),
        .executable(name: "database-fdb", targets: ["DatabaseFDBExecutable"]),
    ],
    traits: [
        .trait(name: "MultiBase"),
    ],
    dependencies: [
        .package(
            url: "https://github.com/1amageek/database-types.git",
            from: "26.1021.0"
        ),
        .package(
            url: "https://github.com/1amageek/database-kit.git",
            revision: "b325109676a4b9b3431e2e306ca8c0dcf1d9a7bf",
            traits: [
                .trait(
                    name: "MultiBase",
                    condition: .when(traits: ["MultiBase"])
                ),
            ]
        ),
        .package(
            url: "https://github.com/1amageek/database-client.git",
            revision: "cd81942c063e4d26ac9fd5ffb002b312dbf6580b",
            traits: [
                .trait(
                    name: "MultiBase",
                    condition: .when(traits: ["MultiBase"])
                ),
            ]
        ),
        .package(
            url: "https://github.com/1amageek/storage-kit.git",
            from: "26.1021.0"
        ),
        .package(
            url: "https://github.com/1amageek/fdb-swift-bindings.git",
            from: "0.4.1"
        ),
        .package(
            url: "https://github.com/1amageek/database-framework.git",
            revision: "4fe236dc47d7d7ded0921caafb3d7e317d81b504",
            traits: [
                .trait(name: "AllRuntimeFeatures"),
                .trait(
                    name: "MultiBase",
                    condition: .when(traits: ["MultiBase"])
                ),
            ]
        ),
        .package(
            url: "https://github.com/apple/swift-nio.git",
            exact: "2.101.3"
        ),
    ],
    targets: [
        .target(
            name: "CDatabaseCLIReadline",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedLibrary("edit"),
            ]
        ),
        .target(
            name: "CDatabaseCLISignals",
            publicHeadersPath: "include"
        ),
        .target(
            name: "DatabaseCommandLine",
            dependencies: [
                "CDatabaseCLIReadline",
                "CDatabaseCLISignals",
                .product(name: "DatabaseTypes", package: "database-types"),
                .product(name: "DatabaseKit", package: "database-kit"),
                .product(name: "DatabaseSchemaJSON", package: "database-kit"),
                .product(name: "DatabaseWire", package: "database-kit"),
                .product(name: "DatabaseClient", package: "database-client"),
                .product(name: "DatabaseClientHTTP", package: "database-client"),
                .product(name: "DatabaseClientWebSocket", package: "database-client"),
                .product(name: "DatabaseClientFramedStream", package: "database-client"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ],
            swiftSettings: [
                .define(
                    "DATABASE_CLI_MULTI_BASE",
                    .when(traits: ["MultiBase"])
                ),
            ]
        ),
        .executableTarget(
            name: "DatabaseCLIExecutable",
            dependencies: ["DatabaseCommandLine"]
        ),
        .target(
            name: "DatabaseFDBCommandLine",
            dependencies: [
                "DatabaseCommandLine",
                .product(name: "DatabaseTypes", package: "database-types"),
                .product(name: "DatabaseKit", package: "database-kit"),
                .product(name: "StorageKit", package: "storage-kit"),
                .product(name: "StorageKitSystemClock", package: "storage-kit"),
                .product(name: "FDBStorage", package: "storage-kit"),
                .product(name: "FoundationDB", package: "fdb-swift-bindings"),
                .product(name: "DatabaseEngine", package: "database-framework"),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L/usr/local/lib",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/usr/local/lib",
                ]),
            ]
        ),
        .executableTarget(
            name: "DatabaseFDBExecutable",
            dependencies: [
                "DatabaseCommandLine",
                "DatabaseFDBCommandLine",
            ]
        ),
        .testTarget(
            name: "DatabaseCommandLineTests",
            dependencies: [
                "DatabaseCommandLine",
                .product(name: "DatabaseTypes", package: "database-types"),
                .product(name: "DatabaseKit", package: "database-kit"),
                .product(name: "DatabaseWire", package: "database-kit"),
            ],
            swiftSettings: [
                .define(
                    "DATABASE_CLI_MULTI_BASE",
                    .when(traits: ["MultiBase"])
                ),
            ]
        ),
        .testTarget(
            name: "DatabaseFDBCommandLineTests",
            dependencies: [
                "DatabaseFDBCommandLine",
                .product(name: "DatabaseTypes", package: "database-types"),
                .product(name: "DatabaseKit", package: "database-kit"),
                .product(name: "DatabaseEngine", package: "database-framework"),
                .product(name: "StorageKit", package: "storage-kit"),
                .product(name: "StorageKitSystemClock", package: "storage-kit"),
            ],
            swiftSettings: [
                .define(
                    "DATABASE_CLI_MULTI_BASE",
                    .when(traits: ["MultiBase"])
                ),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
