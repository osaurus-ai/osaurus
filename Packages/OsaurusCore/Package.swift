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
        //
        // Current pin also carries the 2026-05-06 Ling/Bailing production
        // path: BailingHybrid factory wiring, think_xml reasoning stamp,
        // hybrid cache reset, prestacker startup path, and unsupported
        // JANGTQ3 rejection (group size does not work out). It maps the
        // standard `enable_thinking` chat-template context to the upstream
        // Bailing/Ling "detailed thinking on/off" system directive inside
        // vmlx, hardens hybrid SSM companion cache state, and fixes
        // MiniMax JANGTQ_K per-projection bit decoding.
        //
        // The final 2026-05-06 hardening commits add DSV4/Laguna runtime
        // validation and the current Osaurus handoff notes: DSV4 defaults to
        // the production SWA+CSA+HSA
        // `DeepseekV4Cache` topology, global TurboQuant KV defaults no
        // longer replace that hybrid pool, DSV4 L2 disk restore preserves
        // rotating-window + pool/buffer state, Laguna include-only bundles
        // use the native Poolside fallback template, and model-factory
        // fallback logs are quiet unless `VMLINUX_MODEL_FACTORY_TRACE=1`.
        //
        // 2026-05-07 bump (`4a832400` → `b9da180`) landed the ZAYA1 port,
        // two Ling/Bailing multi-turn fixes, and a host-integration
        // hardening checkpoint.
        //
        // 2026-05-10 bump (`b9da180` → `a5a0e37`) adds the Osaurus runtime
        // readiness wave: ZAYA parser/cache contracts, native ZAYA1-VL
        // image/text generation with disk-backed CCA cache restore, Hy3
        // native text runtime plus `reasoning_effort`/Hunyuan parser wiring,
        // reasoning/media cache-scope salt propagation, generation_config
        // defaults, VLM extent guards, JANGTQ top-k override plumbing, and
        // the B>1 admission coalescing fix that lets concurrent requests
        // actually overlap before decode starts.
        //
        // The 2026-05-07 concerns addressed for PR #1037 were:
        //
        //   - a138f47 fix(runtime): derive prompt tail for token iterator
        //     generation. Reconstructs the decoded prompt tail from
        //     `TokenIterator.promptTokenIds` when the caller does not pass
        //     `promptTail`, so `ReasoningParser.forPrompt(...)` reads the
        //     actual rendered prompt state instead of a family stamp. Live
        //     impact: Ling/Bailing ChatSession multi-turn output now streams
        //     visible answers through `.chunk` when the prompt tail has no
        //     `<think>` opener, instead of routing the whole answer to
        //     `.reasoning` (the host-visible "Stop button stuck with no
        //     answer text" symptom on Ling 2.6 Flash JANGTQ).
        //   - 88fc352 feat(runtime): harden hybrid cache model gates.
        //     BailingLinearAttention + BailingMLAAttention switch from
        //     `rope(_, offset: cache.offset)` to
        //     `applyRotaryPosition(rope, to:cache:)` so RoPE position comes
        //     from `BatchArraysCache.offsetArray` (per-slot) on mixed-length
        //     B>1 decode. `BatchArraysCache` gains per-sequence
        //     `offsets: [Int]` + `offsetArray: MLXArray` + `advance(by:)` so
        //     the recurrent GLA state advances per-slot instead of by the
        //     batch maximum. Closes the Ling cross-turn cache-state desync
        //     class that surfaced as language drift on multi-turn flows.
        //   - b9da180 feat(runtime): harden osaurus integration checkpoint.
        //     (a) `BatchEngine` lifecycle/fairness: `isShutdown` flag rejects
        //     late submits with a `.cancelled` info event,
        //     `controlPlaneYieldInterval=8` keeps long B=1 decodes from
        //     starving cancel/shutdown/config-update, and
        //     `updateMaxBatchSize(_:)` lets hosts hot-resize without an
        //     explicit model evict. (b) `BailingLinearAttention.recurrentGLA`
        //     ports to a fused Metal kernel (`bailing_recurrent_gla` via a
        //     singleton kernel manager) — closes the `EXC_BAD_ACCESS` Metal
        //     pipeline-state lifetime crash on Ling JANGTQ2 long prompts
        //     (≥ ~2k tokens) tracked in LING_JANGTQ2_LONG_PROMPT_CRASH.md.
        //     Reference path is preserved for `D % 32 != 0`. (c)
        //     `Evaluate.swift` yields completion `.info` BEFORE running
        //     `cacheStoreAction` so consumers don't see the end-of-stream
        //     SSM re-derive stall. The osaurus-side
        //     `enableSSMReDerive: false` policy stays for chat workloads
        //     with mutating system prefixes (no warm-cache payoff to amortize
        //     the cost). (d) ANE acceleration contract
        //     (`AccelerationMode` + `AccelerationRuntime.resolveTextDecode`)
        //     scaffolds future routing — fail-closed for text decode, so no
        //     behavior change today.
        //
        // ZAYA1 (Zyphra; `model_type=zaya`) — full port replaces the prior
        // `unsupportedModelType` throw with a real model class, the
        // `ZayaCCACache` (KV + path-dependent `conv_state` + `prev_hs`)
        // hybrid cache, `BatchZayaCCACache` per-slot CCA gather/scatter
        // for batched decode, `TQDiskSerializer` `.zayaCCA` LayerKind for
        // disk round-trip, and `BatchEngine` admission auto-flips
        // `setHybrid` + `setPagedIncompatible` whenever a slot's per-layer
        // cache list contains `ZayaCCACache`. ZAYA is reasoning-capable:
        // osaurus must trust bundle stamps (`supports_thinking=true`,
        // `think_in_template=false`) and pass structured `enable_thinking`
        // context through Swift Jinja instead of forcing family-name
        // defaults. Tool calls route through `ToolCallFormat.zayaXml`
        // (`<zyphra_tool_call>` wrapper). Osaurus-side wiring keeps only
        // topology policy here: `ModelRuntime.isKnownHybridModel` includes
        // ZAYA family names for eager `setHybrid(true)` parity with the
        // BatchEngine auto-flip.
        //
        // Adjacent runtime hardening also included: `LMInput.hasMediaContent`
        // (image/video/audio) replaces ad-hoc image/video checks in
        // `BatchEngine` + `TokenIterator` partial-cache safety; `MediaSalt`
        // extends fingerprinting to audio waveforms; `Evaluate.swift`
        // TokenIterator restore path now gates partial cache hits on
        // SSM/media to match BatchEngine; `RotatingKVCache` (Gemma4 SWA)
        // is now correctly marked paged-incompatible at admission so
        // prefix reuse routes through the v2 disk serializer instead of
        // the paged tier; DSV4 chat-template context strips
        // `reasoning_effort` when `enable_thinking=false`.
        //
        // 2026-05-10 follow-up (`a5a0e37` → `ac60b5d`) restores MiniMax M2.7
        // JANGTQ single-slot decode speed on the Osaurus path. It adds a
        // cache-safe B=1 `BatchEngine.generate` fast path, restores the
        // JANGTQ Hadamard `newv[8]` + cached-meta kernel optimization, and fixes
        // TokenIterator max-token stop accounting. It also keeps text-only ZAYA
        // out of the VLM registry so `model_type=zaya` routes through MLXLLM.
        // The latest pin also closes the solo lifecycle stream-completion race,
        // indexes pre-stacked JANGTQ streaming experts, and advances Qwen3.5-VL
        // gated-delta Mamba cache offsets. It routes MiniMax tool-call wrappers
        // through the tool parser even while inside `<think>` reasoning, preserves
        // visible text around tagged calls, and keeps the fallback MiniMax Jinja
        // template aligned with tool schemas, assistant tool calls, and tool
        // result turns. It also synthesizes terminal `.info` if the lower token
        // stream closes early, so reasoning-only completions still surface
        // `unclosedReasoning` and final stats to the UI/API layers. Commit
        // `fee2583` reverts the later MiniMax blank-content watchdog so the
        // pin keeps the real stream-info/tool-routing fixes without a
        // heuristic generation cutoff. `bf4087f` then makes the MiniMax
        // tool-call parser lossless: invalid `<minimax:tool_call>` prose in
        // reasoning is released immediately on the reasoning rail instead of
        // being buffered until a closing wrapper that may never arrive.
        // `ac60b5d` widens defensive EOS tokens for Laguna / wide-pipe
        // DeepSeek-style bundles across BatchEngine and synchronous generate.
        // `7223ebb` adds ZAYA's exact LanguageModel array-forward overload
        // so BatchEngine doesn't fall through to the protocol fatalError.
        // `21adfc8` keeps Hy3 off the unsafe compiled batch decode path.
        // `174847b` compiles Laguna's router and wires runtime MoE top-k
        // override into Laguna config. `c980034` adds direct Laguna
        // reasoning/tool capability stamps so future bundles that stamp
        // `laguna` do not bypass the correct parsers. `495ac32` restores
        // disk L2 longest-prefix hits for growing chat prompts after unload.
        // `c0d5c99` pins the swift-transformers added-token regex fix that
        // removes ZAYA text's 30s Osaurus-sized prompt encode path. `d8c2bb2`
        // materializes TokenIterator disk restores before B=1 prefill, keeping
        // Osaurus's single-slot path aligned with BatchEngine's cache safety.
        // `78cf6ac` adds Gemma4 PLE-off config tolerance, serializes
        // safetensors disk-cache IO across resident models, keeps MiniMax off
        // the unsafe compiled decode path while removing automatic forced
        // close-token injection, trims B=1 full-cache hits before seed prefill,
        // preserves assistant `reasoning_content`, adds ZAYA reasoning stamps,
        // and skips per-expert source tensors when a JangPress prestacked
        // overlay is present. `b350af6` preserves DSV4 JANGTQ-K routed
        // expert layer bit plans, keeps routed bit-plan metadata out of
        // generic affine quantization overrides, and wires DSV4 routed MoE
        // top-k into the existing lower-only override path. `6de602c`
        // makes the DSV4 tokenizer fallback match the canonical multi-turn
        // chat encoder so generated cache boundaries can be reused. `ad1d231`
        // synchronizes before and after safetensors disk writes so
        // post-answer cache storage cannot crash after generation.
        .package(
            url: "https://github.com/osaurus-ai/vmlx-swift-lm",
            revision: "ad1d23199b056ed502124717e6ca8877f2fb303a"
        ),
        // Osaurus-owned transformers/Jinja chain. `swift-transformers`
        // depends on `osaurus-ai/Jinja`, but its semver range can fresh-
        // resolve to tag 2.3.5. Pin Jinja's root constraint to 58d21aa so
        // the for-loop iterable parser fix used by Mistral 3.5
        // (`loop_messages + [...]`) is not lost on a clean resolver.
        .package(
            url: "https://github.com/osaurus-ai/Jinja.git",
            revision: "58d21aa5b69fdd9eb7e23ce2c3730f47db8e0c9d"
        ),
        .package(
            url: "https://github.com/osaurus-ai/swift-transformers",
            revision: "087a66b17e482220b94909c5cf98688383ae481a"
        ),
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
                .product(name: "Jinja", package: "jinja"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
                .product(name: "VecturaKit", package: "VecturaKit"),
            ],
            path: "Tests"
        ),
    ]
)
