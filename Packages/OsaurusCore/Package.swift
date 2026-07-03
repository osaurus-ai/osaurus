// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "OsaurusCore",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "OsaurusCore", targets: ["OsaurusCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.88.0"),
        // Keep package-local SwiftPM builds aligned with the workspace
        // lockfiles. Containerization 0.32.x changed Process.kill's signal
        // parameter type while the app CI graph is still pinned to 0.31.x.
        .package(url: "https://github.com/apple/containerization.git", .upToNextMinor(from: "0.31.0")),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.0"),
        // MCP pulls EventSource transitively. Enable its AsyncHTTPClient
        // trait at the root so the target's conditional AsyncHTTPClient
        // source has declared NIO/shim dependencies when vmlx/MLX is also
        // in the graph.
        .package(
            url: "https://github.com/mattt/eventsource.git",
            from: "1.4.1",
            traits: [.trait(name: "AsyncHTTPClient")]
        ),
        .package(url: "https://github.com/orlandos-nl/IkigaJSON", from: "2.3.2"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.7.0"),
        // Single consolidated vMLX dependency. This package vendors the MLX,
        // MLXLMCommon, MLXLLM, MLXVLM, Tokenizers, Jinja, cache, parser,
        // MTP, and media-runtime surfaces Osaurus previously pulled from
        // separate MLX, inference, tokenizer, template, and transformer pins.
        // Pinned to vmlx main with the deterministic qwen3.5 RMSNorm-shift fix,
        // the full order-dependent-load sweep (#108, no more ~7.5% degenerate
        // loads), the Mistral3 VLM fix that honors the bundle's longest_edge
        // instead of clamping images to 336px, the stop-string fix (#109), the
        // Mistral bare-JSON-array tool-call recovery (#110), chunk-level
        // prefill cancellation (#111), shutdown-drains-producers (#112), and
        // serialized disk-restore evals (#113) — together closing the
        // client-disconnect crash train (engine teardown returns only after
        // producers are off the GPU; restores can't race input tokenization).
        .package(
            url: "https://github.com/osaurus-ai/vmlx-swift",
            revision: "8dffa0a8e69d7617d68f0843635158684120a3dc"
        ),
        // FluidAudio 0.14.3 added a breaking `language:` parameter to TTS
        // calls that osaurus's `TTSService` doesn't pass. Pinning to the
        // last working version until osaurus catches up. Bumping requires
        // a paired osaurus-side TTSService update.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", "0.14.0" ..< "0.14.2"),
        // VecturaKit 6.x keeps embedding providers out of the core package.
        // Osaurus supplies its embedder from vmlx-swift so the app graph does
        // not pull a second transformer/embedding stack.
        .package(
            url: "https://github.com/rryam/VecturaKit",
            revision: "3bc52538f16a95d956c575abbc7e0423737dfd64"
        ),
        .package(url: "https://github.com/21-DOT-DEV/swift-secp256k1", exact: "0.21.1"),
        .package(path: "../OsaurusNetworking"),
        .package(path: "../OsaurusRepository"),
        .package(url: "https://github.com/mgriebling/SwiftMath", from: "1.7.3"),
        .package(url: "https://github.com/raspu/Highlightr", from: "2.3.0"),
        .package(url: "https://github.com/AAChartModel/AAChartKit-Swift.git", from: "9.5.0"),
        .package(url: "https://github.com/aptabase/aptabase-swift.git", from: "0.3.11"),
        // Crash + app-hang reporting (Sentry). Consent-gated through the same
        // `TelemetryService` opt-in as Aptabase — see `CrashReportingService`.
        .package(url: "https://github.com/getsentry/sentry-cocoa.git", from: "9.15.0"),
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
        //     `SQLite3` (notably vmlx-swift's `DiskCache`),
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
        // Objective-C shim for framework calls that raise an NSException Swift
        // cannot `catch` (see `osr_catch_exception`). Kept in its own target
        // because a SwiftPM target cannot mix Swift and Objective-C sources.
        .target(
            name: "OsaurusObjCSupport",
            path: "ObjCSupport",
            publicHeadersPath: "include"
        ),
        .target(
            name: "OsaurusCore",
            dependencies: [
                "OsaurusSQLCipher",
                "OsaurusObjCSupport",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "IkigaJSON", package: "IkigaJSON"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "MLX", package: "vmlx-swift"),
                .product(name: "MLXLLM", package: "vmlx-swift"),
                .product(name: "MLXVLM", package: "vmlx-swift"),
                .product(name: "MLXLMCommon", package: "vmlx-swift"),
                .product(name: "MLXEmbedders", package: "vmlx-swift"),
                .product(name: "RampartPII", package: "vmlx-swift"),
                .product(name: "VMLXTokenizers", package: "vmlx-swift"),
                // Native on-device image generation (mFLUX). Umbrella import
                // `import vMLXFlux`; shares the one MLX runtime above and is
                // routed through MetalGate's exclusive image lane (see
                // ImageGenerationService).
                .product(name: "vMLXFlux", package: "vmlx-swift"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "VecturaKit", package: "VecturaKit"),
                .product(name: "OsaurusNetworking", package: "OsaurusNetworking"),
                .product(name: "OsaurusRepository", package: "OsaurusRepository"),
                .product(name: "P256K", package: "swift-secp256k1"),
                .product(name: "SwiftMath", package: "SwiftMath"),
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationExtras", package: "containerization"),
                .product(name: "Highlightr", package: "Highlightr"),
                .product(name: "AAInfographics", package: "AAChartKit-Swift"),
                .product(name: "Aptabase", package: "aptabase-swift"),
                .product(name: "Sentry", package: "sentry-cocoa"),
            ],
            path: ".",
            exclude: ["Tests", "SQLCipher", "ObjCSupport"],
            resources: [.process("Resources")],
            swiftSettings: [
                // `SystemLanguageModel.contextSize` only exists in the macOS 26.4+
                // SDK. Enable this flag when building against that SDK (or newer) to
                // read the real on-device context window; leave it off on older SDKs
                // (≤ 26.2), where FoundationModelService falls back to `nil`.
                // .define("HAS_FM_CONTEXT_SIZE"),
            ]
        ),
        .testTarget(
            name: "OsaurusCoreTests",
            dependencies: [
                "OsaurusCore",
                "OsaurusSQLCipher",
                .product(name: "VMLXJinja", package: "vmlx-swift"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
                .product(name: "VecturaKit", package: "VecturaKit"),
            ],
            path: "Tests",
            resources: [.process("ComputerUse/Fixtures")]
        ),
    ]
)
