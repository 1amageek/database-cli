// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "database-cli",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "database", targets: ["DatabaseCLIExecutable"]),
        .executable(name: "database-fdb", targets: ["DatabaseFDBExecutable"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/1amageek/database-types.git",
            from: "26.0730.0"
        ),
        .package(
            url: "https://github.com/1amageek/database-kit.git",
            from: "26.0808.0"
        ),
        .package(
            url: "https://github.com/1amageek/database-client.git",
            from: "26.0808.0"
        ),
        .package(
            url: "https://github.com/1amageek/storage-kit.git",
            from: "26.0807.0"
        ),
        .package(
            url: "https://github.com/1amageek/fdb-swift-bindings.git",
            from: "0.3.3"
        ),
        .package(
            url: "https://github.com/1amageek/database-framework.git",
            from: "26.0808.0"
        ),
    ],
    targets: [
        .target(
            name: "CDatabaseCLISignals",
            publicHeadersPath: "include"
        ),
        .target(
            name: "DatabaseCommandLine",
            dependencies: [
                "CDatabaseCLISignals",
                .product(name: "DatabaseTypes", package: "database-types"),
                .product(name: "DatabaseKit", package: "database-kit"),
                .product(name: "DatabaseWire", package: "database-kit"),
                .product(name: "DatabaseClient", package: "database-client"),
                .product(name: "DatabaseClientHTTP", package: "database-client"),
                .product(name: "DatabaseClientWebSocket", package: "database-client"),
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
                .product(name: "DatabaseEngine", package: "database-framework"),
                .product(name: "DatabaseRuntime", package: "database-framework"),
                .product(name: "DatabaseServer", package: "database-framework"),
                .product(name: "DatabaseServerFoundation", package: "database-framework"),
                .product(name: "DatabaseTypes", package: "database-types"),
                .product(name: "DatabaseKit", package: "database-kit"),
                .product(name: "DatabaseWire", package: "database-kit"),
                .product(name: "StorageKit", package: "storage-kit"),
                .product(name: "StorageKitSystemClock", package: "storage-kit"),
                .product(name: "SQLiteStorage", package: "storage-kit"),
            ]
        ),
        .testTarget(
            name: "DatabaseFDBCommandLineTests",
            dependencies: [
                "DatabaseFDBCommandLine",
                .product(name: "DatabaseEngine", package: "database-framework"),
                .product(name: "StorageKit", package: "storage-kit"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
