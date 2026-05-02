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
        // mlx-swift pinned by revision (was `branch: "osaurus-0.31.3"`) so
        // the runtime can't change under us if the branch tip moves. The
        // revision below is the merge point on `osaurus-0.31.3` that
        // (a) refreshes the submodule URL to the host-side `osaurus-ai/mlx`
        // fork and (b) advances the submodule pointer to a commit
        // (`f58e52da` on the fork's `fix/clear-library-no-release`) that
        // contains the Bug-1 fix for the deterministic Metal validation
        // crash class `notifyExternalReferencesNonZeroOnDealloc` that
        // fired on warm-disk-cache 2nd-request flows on Apple M4 Pro
        // Debug builds. Revert by setting `MLX_CLEAR_LIBRARY_RELEASE=1`
        // at runtime if needed for A/B testing.
        .package(
            url: "https://github.com/osaurus-ai/mlx-swift",
            revision: "0a56f9041d56b4b8161f67a6cbd540ae66efc9fd"
        ),
        // Pinned by commit (was `branch: "main"`) so the runtime can't change
        // under us between identical osaurus source revisions. Bump
        // intentionally when validating a new upstream commit.
        //
        // `13abe40` collects every relevant runtime + docs fix accrued
        // since `a7db6e5` (the prior osaurus pin). PR #967's host-side
        // additions (Nemotron-3 omni registry entries, broader hybrid
        // family setHybrid path, audio/video content-part wiring) all
        // want these:
        //
        // Stability fix carried in this pin:
        //   - cf8c525 fix(repetition): treat `repetition_penalty: 1.0`
        //     as a no-op at `Evaluate.swift:279`. Closes the
        //     `Index out of range` Swift array-bounds panic that fired
        //     on Nemotron-3 first decode (Nemotron's
        //     `generation_config.json` ships `repetition_penalty: 1.0`,
        //     the HuggingFace idiom for "no penalty"). 15-case
        //     coverage in `Tests/MLXLMTests/SampleTests.swift`.
        //
        // Carries forward (commits already included before this PR):
        //   - 98289d9 fix(disk-cache): eager `MLX.evaluate(slot.cache)`
        //     after `restoreFromDiskArrays` at `BatchEngine.swift:748`
        //     so the disk-restored cache materialises in its own
        //     command buffer before prefill encoding starts. The full
        //     fix for the `notifyExternalReferencesNonZeroOnDealloc`
        //     class lands in the mlx submodule via the mlx-swift pin
        //     block above.
        //   - a7db6e5 fix(BatchEngine): reap slots when consumer stops
        //     iterating — sets `continuation.onTermination` on
        //     `BatchEngine.generate`'s outStream so orphan slots get
        //     reaped via `engine.cancel(requestId)` whenever a
        //     consumer breaks early.
        //   - c992df9 feat(reasoning): `GenerateCompletionInfo.
        //     unclosedReasoning` flag for trapped-thinking detection;
        //     the host chat UI surfaces this as a "thinking didn't
        //     close" chip when reasoning-trained models trap themselves.
        //
        // Runtime fixes between a7db6e5 and 13abe40 (selected):
        //   - ae526a3 fix(jang): authoritative blockSize + omni quant
        //     plumbing — closes the `rms_norm` trap class that killed
        //     Cascade-2 JANG_4M and Nemotron-Omni MXFP4 first-prefill
        //     under the bits=4 / 164-override JANG path. Pairs with
        //     the host-side `MLXErrorRecovery.installGlobalHandler()`.
        //   - 537e386 feat(omni): `NemotronHJANGTQ` — closes
        //     `Unhandled keys ["experts"]` on omni JANGTQ bundles by
        //     stacking per-expert TQ-packed tensors and swapping in
        //     `TurboQuantSwitchLinear` for the routed-expert switch.
        //   - ae49c7c feat(omni): full audio `LMInput` integration —
        //     STT + voice I/O. Closes the prior "audio open seam" in
        //     `OMNI-OSAURUS-HOOKUP.md` §3.
        //   - 3b78db4 feat(omni): close audio + video gaps. Together
        //     with `ae49c7c` makes the audio/video HTTP-API surface in
        //     this PR's `feat(api)` commit round-trip end-to-end.
        //   - d020e76 docs+fix(omni): voice integration guide +
        //     `BatchEngine` text-only `.logits` return so a
        //     `[concatenate] dims 3 vs 4` trap doesn't cascade into
        //     Mamba2 conv state merge.
        //
        // Foundational omni stack (already in 1c62d21, kept by 13abe40):
        //   - b4eec09 native Swift port of Nemotron-3-Nano-Omni — first
        //     time the host runs Parakeet/RADIO without a torch dep.
        //   - 08994b0 `OMNI-OSAURUS-HOOKUP.md` spec — cited by
        //     `ModelRuntime.installCacheCoordinator` (§5.1) and the
        //     Nemotron-3 registry comments (§12.5).
        //   - 75549cb @ModuleInfo single-segment fix for omni weight
        //     loading.
        //   - 1c62d21 `OMNI-OSAURUS-HOOKUP.md` §10 correction: prior
        //     "BatchEngine omni B=1 empty stream" claim was a bench
        //     methodology artifact — the bench counted only `.chunk`
        //     events and missed `.reasoning(_)` events that
        //     reasoning-on-by-default omni emits during `<think>...</think>`.
        //     The host-side `GenerationEventMapper` correctly forwards
        //     `.reasoning(_)` (`PluginHostAPI.swift:1139` emits
        //     `delta.reasoning_content`), so streaming clients see the
        //     full output. No host-side workaround needed.
        //
        // The audio + video HTTP-API surface
        // (`MessageContentPart.audioInput` / `.videoUrl` →
        // `UserInput.audios` / `.videos`) is part of this PR (the
        // `feat(api)` commit on tip). vmlx-side wiring is in place at
        // this pin via `ae49c7c` + `3b78db4`.
        .package(
            url: "https://github.com/osaurus-ai/vmlx-swift-lm",
            revision: "2e61c12a1573d073618ee2f98f39149ea36068e1"
        ),
        // swift-jinja: pinned to osaurus-ai fork at 58d21aa5 — same fork
        // vmlx-swift-lm pins. Must also be declared HERE (root level) so
        // the app's xcodeproj resolution picks up the fork instead of
        // resolving the upstream `huggingface/swift-jinja` transitively
        // via swift-transformers. SwiftPM resolves the root package's
        // declared deps, so without this line the app silently uses
        // upstream and Mistral 3.5 / Mistral-Medium-3.5-128B-JANGTQ
        // chat templates throw "Expected '%}' after for loop.. Got plus
        // instead" on the `loop_messages + [{'role': '__sentinel__'}]`
        // construct (line 72 of Mistral 3.5's chat_template.jinja). Fork
        // adds for-loop iterable expression support via parseFilter →
        // parseOr in Sources/Jinja/Parser.swift:186. All 756 swift-jinja
        // tests pass + 2 new regression tests (forLoopIterableAccepts-
        // BinaryPlus + mistral3RealNativeTemplateParses).
        .package(
            url: "https://github.com/osaurus-ai/swift-jinja",
            revision: "58d21aa5b69fdd9eb7e23ce2c3730f47db8e0c9d"
        ),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.1.6"),
        // FluidAudio 0.14.3 added a breaking `language:` parameter to TTS
        // calls that osaurus's `TTSService` doesn't pass. Pinning to the
        // last working version until osaurus catches up. Bumping requires
        // a paired osaurus-side TTSService update.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", "0.14.0" ..< "0.14.2"),
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
