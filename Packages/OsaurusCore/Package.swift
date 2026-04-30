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
        //
        // a7db6e5 closes the deterministic Metal-assertion crash class
        // `notifyExternalReferencesNonZeroOnDealloc` inside
        // `BatchEngine.stepPrefill` after `Cache disk hit`. Two upstream
        // commits land that fix together:
        //   - 98289d9 forces `MLX.asyncEval(slot.cache)` after disk
        //     restore so lazy-restore graph ops don't extend into the
        //     next request's command buffer.
        //   - a7db6e5 sets `continuation.onTermination` on
        //     `BatchEngine.generate`'s outStream so orphan slots get
        //     reaped via `engine.cancel(requestId)` whenever a consumer
        //     breaks early.
        // Net effect: the `Task.isCancelled` break in MLXBatchAdapter
        // line 209-222 is safe, and no `enableDiskCache: false` workaround
        // is needed.
        //
        // Also includes c992df9's `GenerateCompletionInfo.unclosedReasoning`,
        // which the chat UI consumes to surface a "thinking didn't close"
        // chip when reasoning-trained models trap themselves on validation
        // prompts.
        .package(
            url: "https://github.com/osaurus-ai/vmlx-swift-lm",
            revision: "a7db6e5fdde525c43f72ba48df8ba12a07451ee9"
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
        // Vendored SQLCipher 4.6.1 amalgamation (CommonCrypto
        // provider, FTS5 enabled). See `SQLCipher/README.md` for
        // re-build instructions and the FTS5 header-guard maintenance
        // contract. OsaurusCore links this *instead of* Apple's
        // system `import SQLite3` so every SQLite call goes through
        // the SQLCipher-extended build (giving us `sqlite3_key_v2`
        // for at-rest encryption).
        //
        // ⚠️  FTS5 typedef collision. `sqlite3.h` declares
        //     `Fts5ExtensionApi`, `fts5_api`, `Fts5Context`,
        //     `Fts5PhraseIter` and `fts5_extension_function`
        //     UNCONDITIONALLY (they are NOT gated by
        //     `SQLITE_ENABLE_FTS5`). When another module in the
        //     same Swift compilation unit imports Apple's system
        //     `SQLite3` (notably vmlx-swift-lm's `DiskCache`),
        //     Swift's Clang importer sees two different definitions
        //     of those typedefs and rejects the build with
        //         'Fts5ExtensionApi' has different definitions in different modules
        //     The fix is three-part:
        //       1. `include/sqlite3.h` wraps the `_FTS5_H` block in
        //          `#ifndef OSAURUS_OMIT_FTS5_HEADERS` (search for
        //          OSAURUS LOCAL MODIFICATION inside that file).
        //       2. `include/OsaurusSQLCipher.h` defines
        //          `OSAURUS_OMIT_FTS5_HEADERS` before including
        //          sqlite3.h so Swift's Clang module import sees the
        //          hidden extension API.
        //       3. The `cSettings` `.define("OSAURUS_OMIT_FTS5_HEADERS")`
        //          below keeps the C compilation path aligned.
        //     `sqlite3.c` itself inlines its own copy of the header
        //     text, so FTS5's SQL-level functionality keeps working;
        //     we only hide the C-extension API, which Osaurus
        //     doesn't use.
        //     `Tests/Storage/SQLCipherVendorGuardTests.swift` asserts
        //     the header guard, umbrella define, and cSettings flag
        //     are in place — CI fails if a SQLCipher bump strips them.
        //
        // ⚠️  sqlite3ext.h collision. Newer macOS SDKs append fields
        //     to `sqlite3_api_routines` before our pinned SQLCipher
        //     adopts that SQLite version. Osaurus does not compile
        //     SQLite loadable extensions, so the umbrella header hides
        //     sqlite3ext.h's loadable-extension API from the Swift
        //     Clang importer while still including the header to keep
        //     module import warnings quiet.
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
                // do the same here. NDEBUG must be a compile flag,
                // not a late `#define` in source — Apple's
                // `<assert.h>` is a precompiled Clang module whose
                // expansion is fixed at module-compilation time.
                .define("NDEBUG"),
                .define("SQLITE_OMIT_DEPRECATED"),
                .define("SQLITE_DEFAULT_MEMSTATUS", to: "0"),
                // Hide the FTS5 C-extension typedefs from
                // `include/sqlite3.h` so the Swift Clang importer
                // doesn't conflict with the system SQLite3 module —
                // see the long comment above. `sqlite3.c`'s inlined
                // copy of sqlite3.h text is unaffected, so the C
                // compilation of FTS5 keeps working.
                .define("OSAURUS_OMIT_FTS5_HEADERS"),
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
