// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "OsaurusCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "OsaurusCore", targets: ["OsaurusCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.88.0"),
        .package(url: "https://github.com/apple/containerization.git", from: "0.26.0"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.0"),
        .package(url: "https://github.com/orlandos-nl/IkigaJSON", from: "2.3.2"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.7.0"),
        .package(url: "https://github.com/osaurus-ai/mlx-swift", branch: "osaurus-0.31.3"),
        // Pinned by commit (was `branch: "main"`) so the runtime can't change
        // under us between identical osaurus source revisions. Bump
        // intentionally when validating a new upstream commit.
        .package(
            url: "https://github.com/osaurus-ai/vmlx-swift-lm",
            revision: "5833aac4d91fcdce03770f573c97c6ec48045ac4"
        ),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.1.6"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.14.0"),
        // Pinned by commit (was `branch: "main"`) — same reasoning as
        // vmlx-swift-lm above.
        .package(
            url: "https://github.com/rryam/VecturaKit",
            revision: "a1b93774d16d8a6e7fc39b7cda9449b719f07f48"
        ),
        .package(url: "https://github.com/21-DOT-DEV/swift-secp256k1", exact: "0.21.1"),
        .package(path: "../OsaurusRepository"),
        .package(url: "https://github.com/mgriebling/SwiftMath", from: "1.7.3"),
        .package(url: "https://github.com/raspu/Highlightr", from: "2.3.0"),
        .package(url: "https://github.com/AAChartModel/AAChartKit-Swift.git", from: "9.5.0"),
    ],
    targets: [
        // Vendored SQLCipher 4.6.1 amalgamation (CommonCrypto provider,
        // FTS5 enabled). See SQLCipher/README.md for re-build instructions.
        // OsaurusCore links this *instead of* the system `import SQLite3`
        // so all SQLite calls go through the SQLCipher-extended build
        // and `sqlite3_key_v2` is available for at-rest encryption.
        .target(
            name: "OsaurusSQLCipher",
            path: "SQLCipher",
            sources: ["sqlite3.c"],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include"),
                .define("SQLITE_HAS_CODEC"),
                .define("SQLCIPHER_CRYPTO_CC"),
                .define("SQLITE_TEMP_STORE", to: "2"),
                .define("SQLITE_THREADSAFE", to: "2"),
                .define("SQLITE_ENABLE_FTS5"),
                .define("SQLITE_ENABLE_RTREE"),
                .define("SQLITE_ENABLE_JSON1"),
                .define("SQLITE_ENABLE_COLUMN_METADATA"),
                .define("SQLITE_ENABLE_LOAD_EXTENSION"),
                .define("SQLITE_ENABLE_DBSTAT_VTAB"),
                .define("HAVE_USLEEP", to: "1"),
                // Strip assert()s. Several SQLite asserts reference
                // identifiers only declared inside debug-only build
                // configs (e.g. `bCorrupt`, `startedWithOom`); the
                // shipped library normally compiles with NDEBUG, so
                // do the same here.
                .define("NDEBUG"),
                .define("SQLITE_OMIT_DEPRECATED"),
                .define("SQLITE_DEFAULT_MEMSTATUS", to: "0"),
                // The SQLite amalgamation calls a few self-references
                // before their forward declarations show up; modern
                // Apple clang upgrades this from a warning to an
                // error. Allow the implicit decls only inside this
                // vendored target so we keep strict diagnostics on
                // the rest of the codebase.
                .unsafeFlags([
                    "-Wno-shorten-64-to-32",
                    "-Wno-ambiguous-macro",
                    "-Wno-implicit-function-declaration",
                    "-Wno-unused-but-set-variable",
                    "-Wno-deprecated-non-prototype",
                ]),
            ],
            linkerSettings: [
                .linkedFramework("Security")
            ]
        ),
        .target(
            name: "OsaurusCore",
            dependencies: [
                "OsaurusSQLCipher",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "IkigaJSON", package: "IkigaJSON"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXLLM", package: "vmlx-swift-lm"),
                .product(name: "MLXVLM", package: "vmlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "vmlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "VecturaKit", package: "VecturaKit"),
                .product(name: "OsaurusRepository", package: "OsaurusRepository"),
                .product(name: "P256K", package: "swift-secp256k1"),
                .product(name: "SwiftMath", package: "SwiftMath"),
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationExtras", package: "containerization"),
                .product(name: "Highlightr", package: "Highlightr"),
                .product(name: "AAInfographics", package: "AAChartKit-Swift"),
            ],
            path: ".",
            exclude: ["Tests", "SQLCipher"],
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "OsaurusCoreTests",
            dependencies: [
                "OsaurusCore",
                "OsaurusSQLCipher",
                .product(name: "NIOEmbedded", package: "swift-nio"),
                .product(name: "VecturaKit", package: "VecturaKit"),
            ],
            path: "Tests"
        ),
    ]
)
