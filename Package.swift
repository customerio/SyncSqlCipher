// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "SyncSqlCipher",
    platforms: [
        .macOS(.v10_15),
        .iOS(.v13),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "SyncSqlCipher", targets: ["SyncSqlCipher"])
    ],
    targets: [
        // MARK: - C amalgamation target
        .target(
            name: "CSqlCipher",
            path: "Sources/CSqlCipher",
            sources: ["sqlite3.c"],
            publicHeadersPath: "include",
            cSettings: [
                .define("SQLITE_HAS_CODEC"),
                .define("SQLITE_TEMP_STORE", to: "2"),
                .define("SQLITE_EXTRA_INIT", to: "sqlcipher_extra_init"),
                .define("SQLITE_EXTRA_SHUTDOWN", to: "sqlcipher_extra_shutdown"),
                .define("SQLITE_THREADSAFE", to: "1"),
                .define(
                    "SQLCIPHER_CRYPTO_CC",
                    .when(platforms: [.macOS, .iOS, .visionOS])),
                .define(
                    "SQLCIPHER_CRYPTO_OPENSSL",
                    .when(platforms: [.linux])),
                .define("HAVE_STDINT_H", to: "1"),
                .define("NDEBUG"),
                .define("SQLITE_DQS", to: "0"),
            ],
            linkerSettings: [
                .linkedFramework(
                    "Security",
                    .when(platforms: [.macOS, .iOS, .visionOS])),
                .linkedLibrary(
                    "crypto",
                    .when(platforms: [.linux])),
            ]
        ),

        // MARK: - Swift wrapper target
        .target(
            name: "SyncSqlCipher",
            dependencies: ["CSqlCipher"],
            path: "Sources/SyncSqlCipher",
            swiftSettings: [
                .enableExperimentalFeature("AccessLevelOnImport"),
            ]
        ),

        // MARK: - Tests
        .testTarget(
            name: "SyncSqlCipherTests",
            dependencies: ["SyncSqlCipher"],
            path: "Tests/SyncSqlCipherTests"
        ),
    ]
)
