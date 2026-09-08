// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "OsaurusCore",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "OsaurusCore", targets: ["OsaurusCore"]),
        // Out-of-process native plugin host: loads one plugin dylib via the
        // frozen C ABI and executes it over stdio JSON-RPC so the app can
        // kill/restart wedged accessibility/automation plugin code instead
        // of hanging in-process. See `PluginHost/main.swift` and
        // `Services/Plugin/PluginProcessHost.swift`.
        .executable(name: "osaurus-plugin-host", targets: ["osaurus-plugin-host"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.88.0"),
        // Keep this exact pin aligned with SandboxRuntimeAssets.initfsReference.
        // Containerization 0.41 is the SDK shipped by Apple container 1.3 and
        // includes restricted OCI capability defaults, vminit secret
        // redaction, atomic image-store state, and startup cleanup fixes.
        // Keep both app workspace lockfiles in step when bumping.
        .package(url: "https://github.com/apple/containerization.git", exact: "0.41.0"),
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
        // YAML for the declarative `osaurus_config` document (export / plan /
        // apply). Used only by Configuration/Declarative; skills keep their
        // hand-rolled frontmatter parser.
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
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
        // Now also carries #116 (serialize GPU-stream drivers — re-locks
        // eval/asyncEval/item + synchronize/clearCache to kill the Metal
        // concurrent-encoder crash class) and #117 (NormConventionResolver:
        // an unrecognized norm_convention defers to the vote instead of
        // silently disabling the (1+weight) shift). Now also carries the
        // incremental tool-call envelope progress event (`Generation
        // .toolCallProgress`) so the app can show a live "preparing tool call"
        // card during a long buffered tool write (e.g. a large file) instead of
        // a frozen typing indicator. Additive — existing consumers unaffected.
        // Now also carries #123 (production crash-trap fixes): Qwen3VL
        // rotary embedding accepts low-rank position ids and the decode-path
        // rope delta broadcasts per sequence (stale deltas fall back to cache
        // offsets); Gemma4 maskedScatter and NemotronH mambaForward guard the
        // rank-0/empty results a failed MLX op hands back inside a withError
        // scope; the compile() overloads and innerCall degrade to empty
        // results instead of trapping on a failed closure evaluation — so a
        // recorded MLX error reaches the error-scope exit instead of dying in
        // a Swift bounds check. Contains the previous ff714f1 pin. Now also
        // carries #149: native schema-2 affine1 JANG loading and Metal kernels,
        // Qwen3-VL tool-schema preservation, and bounded media-cache cleanup.
        // Also carries #153: fail-closed support for historical schema-1 JANG
        // affine manifests. Also carries #93: Gemma4 model registrations no
        // longer inject the stale `<end_of_turn>` token into extraEOSTokens;
        // bundle generation_config.json remains the stop-token authority. The
        // PR #154 proof revision also reports the exact cache-layer topology
        // before/after each real TurboQuant transition. The ZAYA cache proof
        // revision adds real-attention-only TQ ownership, native CCA companion
        // restore, atomic typed L2 records, and a proven four-bit floor for
        // TQ-native ZAYA disk boundaries. The Nemotron Omni revision also
        // aligns the RADIO/projector contract, bounds media prefill, and
        // enables safe image/audio hybrid-prefix restore. The paged-cache
        // follow-up separates typed-disk persistence from paged compatibility,
        // restores recurrent companions at the exact matched boundary, and
        // keeps every unproven cache topology fail-closed. PR #171 persists
        // stable system/tool warm-up boundaries in SSD L2 and excludes unsafe
        // exact hybrid/GDN candidates while preserving their matched recurrent
        // companion state. The Laguna S 2.1 revision adds the released
        // full-KV + rotating-SWA runtime contract, safe fresh-session SSD
        // seeds, growing partial-leaf reuse, and complete TQ window restore.
        // vmlx-swift#179 additionally recovers Qwen XML plain bracket lists
        // only for schema-declared array<string> tool arguments and routes
        // Gemma's decoded thought-channel opener into reasoning. The static
        // prefix hint revision lets Osaurus's byte-stable system prefix seed
        // SSD cache boundaries even when mutable DB/tool state changes later
        // in the same rendered system message. The disk-recency revision
        // refreshes accepted KV + recurrent companion groups on restore so
        // combined-quota eviction preserves genuinely hot SSD prefixes. The
        // stable-checkpoint follow-up also refreshes the existing canonical
        // system/tool seed when a longer compatible disk entry serves a
        // growing turn, preventing tool-loop snapshots from evicting the next
        // chat's warm-start checkpoint. vmlx-swift#189 makes the solo
        // TokenIterator path report an accepted disk/paged restore only after
        // path-dependent rollback checks, with exact restored/total counts.
        // vmlx-swift#190 captures the exact prompt-minus-one SSD seed while the real
        // prefill crosses it for standalone rotating/SWA cache topologies.
        // This preserves the existing fail-closed post-hoc rederive guard
        // while allowing a later compatible turn to restore the longer seed.
        // vmlx-swift#191 preserves canonical scalar content for Gemma 4
        // text-only system/developer turns. Real bundle templates otherwise
        // omit prompt-affecting settings text and can accept an incompatible
        // SSD checkpoint because distinct revisions tokenize identically.
        // vmlx-swift#192 adds Nanbeige 4.2's looped-transformer runtime with
        // 44 loop-layer KV slots and fail-closed runtime-contract validation.
        // The atomic BatchEngine-capacity revision exposes one actor-consistent
        // configured/active/pending snapshot so Osaurus can report and plan
        // subagent waves against the engine that actually owns admission.
        // vmlx-swift#195 keeps Qwen 3.5 / Ornith GatedDelta recurrent state
        // in float32 across cold and restored prefix partitions, and admits
        // linked KV + recurrent disk boundaries under one quota transaction.
        // vmlx-swift#196 marks caller-proven reusable-prefix warmup prompts
        // explicitly so solo, batched, and native-MTP cache writers retain
        // exact boundaries for fully restorable topologies and recurrent-safe
        // processor seeds for hybrid state, without persisting the warmup's
        // throwaway decoded token. vmlx-swift#198 prevents fully restorable,
        // non-recurrent disk-only caches such as DSV4 from synchronously
        // replaying older stable boundaries before warmup can finish and keeps
        // DSV4 on its measured model-native compiled gate/SwiGLU path instead
        // of the incompatible generic whole-cache compiled trace.
        // vmlx-swift#199 captures DSV4's complete SWA/CSA/HSA prompt-minus-one
        // disk seed during prefill so exact replay restores the longest valid
        // prefix and re-feeds only the final prompt token. Warm restores do not
        // recapture the seed or retain an unusable exact-prompt duplicate.
        // Its follow-up persists that materialized seed before decode and drops
        // the duplicate pool state so an uncached DSV4 turn keeps native speed.
        // Reusable-prefix warmups publish that same seed so the visible request
        // restores the warmed prefix instead of prefilling it a second time.
        // vmlx-swift#186-#188 correct FalconH1 key
        // projection scaling, prefixed output-head loading, and gated RMSNorm
        // group normalization without changing the shared unload/cache APIs.
        // vmlx-swift#210 round-trips LFM2/LFM2.5 short-conv prefix-cache
        // state: the v2 disk payload persists the single occupied MambaCache
        // slot (a stateless tagged mamba layer is an atomic required miss,
        // retiring KV-only pseudo-hits), the paged companion rail recovers
        // per-layer arity so 1-slot conv layers no longer cross-wire, and
        // LFM2Configuration reads stock intermediate_size configs. It also
        // pins the LFM2.5-2.6B template ({% generation %}, Pythonic tool
        // envelope, unconditional <think> generation prompt) and the
        // qwen3-reasoning + lfm2-tool capability stamp resolution.
        // vmlx-swift#211 advances LFM2/LFM2.5 short-conv cache offsets each
        // forward so the #208 boundary-offset guard admits the family's
        // paged/disk stores instead of vetoing every one (conv layers were
        // stuck at offset 0; observed live as zero kv_v2 entries).
        // vmlx-swift#212 honors DSV4's bundle thinking default (absent
        // enable_thinking = thinking rail), publishes the N-1 disk seed for
        // reusable-prefix warmups on the solo path (a DSV4 warmup otherwise
        // published nothing and the visible send re-prefilled the identical
        // prefix), aligns the post-answer boundary key with the consumed
        // stop token the async pipeline already forwarded, and hardens SSD
        // q8 pool blocks (empty-pool round-trip, non-q8 poison-to-miss,
        // atomic .qkv record refusal).
        // The DSV4 decode-fastpath revision defaults the quantized lm_head to
        // fused 8-bit quantizedMatmul instead of dequantizing the whole head
        // to FP32 every forward (greedy-identical, turn-1 wall 37.4s -> 8.9s;
        // VMLX_DSV4_LM_HEAD_MODE=exact restores the old path), shares exact
        // RoPE cos/sin tables across equal-frequency instances, and projects
        // the Metal live-buffer ceiling (iogpu.rsrc_limit) into a generated-
        // token cap for cache topologies that retain per-token buffers —
        // DSV4's cumulative pools retained ~1 buffer/layer/token and long
        // generations died mid-stream at the 499000 allocator wall.
        // Conventional KV topologies report zero retention and are never
        // capped (VMLX_METAL_BUFFER_COUNT_GUARD=0 disables).
        // vmlx-swift#228 parses GLM/DeepSeek tool calls that take no
        // arguments. `GLM4ToolCallParser` read the function name as
        // everything before the first <arg_key> and returned nil when there
        // was none, so `<tool_call>list_mailboxes</tool_call>` — the only way
        // to invoke a tool that declares no parameters — was discarded.
        // Nothing downstream can tell that from a silent model: the envelope
        // is consumed as non-content, the turn carries no text and no tool
        // work, the empty-turn nudges re-elicit the same correct call, and
        // the run ends on `emptyToolTaskFallback`. Reproduced on Raptor 1.0
        // 16B with the Mail capability loaded. The route covers GLM-4.x/5,
        // DeepSeek V3 aliases, Laguna/Raptor, Poolside and Ling/Bailing.
        // vmlx-swift#229 halts generation when the visible output collapses
        // into a verbatim cycle. Observed on Raptor after two consecutive
        // `invalid_args` rejections: the turn repeated one sentence pair to
        // the token cap and recorded no terminal stop reason at all. Firing
        // needs a unit repeated 4x, 32+ characters, AND primitive at that
        // scale — a run of `---` or `| | |` repeats at period 32 too, so a
        // length floor alone would truncate real answers. VMLX_REPETITION_STOP=0
        // disables it.
        // vmlx-swift#230 consumes Muse Glimmer's tool-recipient channel
        // headers. The parser knew `to=self` and `to=user`; a tool call names
        // the TOOL as recipient, so `to=<tool><|message|>` matched no spelling
        // and streamed verbatim into the reasoning rail — consistently at the
        // end of the first think block, and stored in `thinking` where history
        // replayed it back to the model as prose. `to=user` still closes
        // reasoning and `to=self` still opens it.
        // vmlx-swift#234 implements the Nemotron-H native MTP head (270
        // `mtp.*` tensors that `sanitize` previously dropped) and declines
        // speculation whenever the KV window is bounded, since a
        // `RotatingKVCache` cannot un-write a rejected draft.
        //
        // The head is DEFAULT OFF behind `VMLX_NEMOTRON_MTP`. Measured on
        // Lightning 30B-A3B: D2 is 0.84x — 16 % SLOWER than plain
        // autoregressive at 72.4 % accept — and D3 is 0.48x, both
        // token-identical. A 3 B-active model is not purely bandwidth-bound,
        // so the two-token verify batch costs +46 % instead of ~0 %. D1 is the
        // shipped path; turning MTP on is an explicit per-machine decision.
        // vmlx-swift#250 makes LFM2.5-VL usable: the `<image>` id was resolved
        // with `convertTokenToId`, which returns the UNK id rather than nil for
        // a bundle that spells the token differently, so every image expanded
        // against the wrong placeholder; the expansion also ran once per turn
        // instead of once per placeholder, which trapped in
        // `mergeInputIdsWithImageFeatures` as soon as a turn carried two
        // images. Tool schemas now reach `LMInput` on both the text and image
        // paths, and the pythonic parser accepts the `function`/`parameters`
        // spelling this bundle emits, so an offered tool is no longer dropped.
        // vmlx-swift#283 re-arms the adaptive MTP depth controller upward
        // (demote-only never recovered a transient dip) and gives restored
        // sessions a 4x warmup grace window; #284 scopes the hybrid warmup
        // memo to catastrophic misses only, so a prose-grade first turn can
        // no longer lock native MTP off for the model's whole residency —
        // acceptance is content, and only a below-depth-1-floor miss is a
        // property of the model.
        // The Qwen 3.8 Flash Next revision (447a6a2b) lands the qwen4_exp
        // native runtime: SSD-only PLE n-gram reader (pread + F_NOCACHE, the
        // 20-29 GiB table never becomes resident), mixed-bit fused routed-MoE
        // decode kernels (q2/q3/q4/q6, group 32/64, unit-parity tested against
        // exact f32), six-slot PLE cache topology preserved across
        // copy/restore (the warm-restore bounds trap), a dense-QMV fallback
        // that returns the incoming activation dtype (JANG_2L's 6-bit trunk
        // silently promoted the residual to f32 and halved decode), tensor-
        // evidence MTP census with tuning-gated auto-launch, and the vision
        // bridge (quantized Qwen3-VL tower, per-modality feature scatter,
        // 3-channel M-RoPE with a per-conversation decode rope delta). All six
        // JANG tiers decode at 38-44 tok/s with resident BF16 compute and the
        // PLE table on SSD.
        // vmlx-swift#330 pins the legacy-Hermes parser regressions; #339
        // performs the source correction, recovering Qwen 3.8 bundles from
        // their actual template contract while failing closed without one;
        // #331 preserves per-sequence Qwen 3.5 positions under continuous
        // batching; #335 exposes requested and architecture-limited batch
        // capacity; #341-#342 make AgenticTaskBench sandboxing and scoring
        // reflect the production model/config path; #337 loads the real
        // per-expert Ornith-35B MTP-MoE layout without dropping tensors; #343
        // prevents prompt-scoped tuning rows from authorizing global MTP Auto;
        // and #344 keeps manual MTP available to other families while honoring
        // an explicit bundle-level manual safety block for Ornith 1.5 35B;
        // #346 restores the architecture-scoped compiled GDN/MoE decode path
        // for that model and adds its real q5/q5/q4 affine expert layout.
        // vmlx-swift#376 heals dtype-misaligned safetensors containers before
        // mmap with a byte-verified atomic replacement and advisory fallback;
        // #378 preserves exact reusable boundaries across growing tool loops.
        // vmlx-swift#379 casts DeepseekV3 MoE expert mixes back to the input
        // dtype, ending the F32 residual/KV promotion; #386 overlaps the
        // native-MTP verify graph submission with drafting below 2k context;
        // #387 abandons the prefetched verify before stats finalize so the
        // telemetry is truthful; #388 unions the safetensors index with shard
        // headers so an incomplete index can't veto MTP/vision tensor
        // evidence; #390 stops persisting the recurrent-state copies the
        // hybrid restore path never applies (−30-50% disk-cache bytes per
        // boundary, −70% store latency for MambaCache hybrids).
        // vmlx-swift#391 adds CachePromptIntent.auxiliary: internal utility
        // generations (title/follow-ups/memory/transcript cleanup) restore
        // cache prefixes but never persist prompt boundaries.
        // #392 (mlx#6) reports Metal command-buffer failures through the
        // error handler instead of throwing in completion handlers, so a GPU
        // failure fails the one job instead of aborting the process.
        // vmlx-swift#394 gates the native-MTP exact-prompt store behind the
        // canonical hybrid boundary: one reusable record per tool-call cycle
        // instead of an exact+seed pair (~2x ~400MB synchronous writes).
        // vmlx-swift#396 ends the turn at tool dispatch: consumer termination
        // after an emitted tool call is a natural .stop (stores run), so the
        // adapter stops the engine at dispatch instead of draining the
        // model's post-tool prose to EOS (~110s of dead decode measured).
        // vmlx-swift#401 fuses GDN decode input projections by quantization
        // group (+2.2% 27B decode), runs MLA decode SDPA in the cache dtype
        // instead of casting the full-context KV to fp32 every token (Raptor
        // 2.4x at 26k ctx; DSV3/V4 + Bailing families), and caches the QSA
        // indexer's processed pool blocks (append-only) so Flash Next stops
        // re-pooling its whole index history per token. vmlx-swift#404
        // reorders Qwen3VL vision rows to placeholder order so a video turn
        // followed by an image turn no longer swaps the two feature blocks
        // (same defect #298 fixed for qwen3_5; Qwen3VL also re-applies rows
        // per deepstack layer, covered by the same permutation).
        // vmlx-swift#405 completes the fp32 sweep: DSV4 dense indexer and
        // GLM5-next sparse index score in the pool's native dtype instead of
        // copying full-history pools to fp32 per decode token (selection
        // logits only; env fallbacks; load-bearing fp32 sites documented).
        // vmlx-swift#407 pins quantized-module outputs to the activation
        // dtype: f16 JANG scales no longer silently promote bf16 models to
        // an fp32 activation path (which doubled every KV/disk cache entry
        // and disqualified compiled-decode regions); 21 MoE reducers get the
        // DeepseekV3 score-cast pattern; repo-wide source guard added.
        // vmlx-swift#408 pins quantized-embedding output to bf16 under the
        // Gemma-4/DSV4 jang_affine mmap preserve branches (the last audited
        // f16 seed into bf16 streams; dequant math keeps exact f16 metadata).
        .package(
            url: "https://github.com/osaurus-ai/vmlx-swift",
            revision: "45bcb1de740d979a2322570a06edd457ce3d0697"
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
                .product(name: "Yams", package: "Yams"),
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
            exclude: ["Tests", "SQLCipher", "ObjCSupport", "PluginHost"],
            resources: [.process("Resources")],
            swiftSettings: [
                // `SystemLanguageModel.contextSize` only exists in the macOS 26.4+
                // SDK. Enable this flag when building against that SDK (or newer) to
                // read the real on-device context window; leave it off on older SDKs
                // (≤ 26.2), where FoundationModelService falls back to `nil`.
                // .define("HAS_FM_CONTEXT_SIZE"),
            ]
        ),
        // Dependency-free (Foundation-only) helper executable: it must never
        // link the app graph, so a wedged app subsystem can't wedge the
        // helper and the binary stays small enough to respawn instantly.
        .executableTarget(
            name: "osaurus-plugin-host",
            path: "PluginHost"
        ),
        .testTarget(
            name: "OsaurusCoreTests",
            dependencies: [
                "OsaurusCore",
                "OsaurusSQLCipher",
                // Ensures the helper binary is built into the products
                // directory for every test lane (swift test AND xcodebuild),
                // so PluginProcessHostTests can spawn the real executable.
                "osaurus-plugin-host",
                .product(name: "VMLXJinja", package: "vmlx-swift"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
                .product(name: "VecturaKit", package: "VecturaKit"),
            ],
            path: "Tests",
            resources: [.process("ComputerUse/Fixtures")]
        ),
    ]
)
