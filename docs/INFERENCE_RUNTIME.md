# Inference runtime

osaurus's MLX inference path is a thin shell around `vmlx-swift`'s
`BatchEngine`. Tool-call parsing, reasoning extraction, KV cache
management, and per-model scheduling all live inside the library. This
document describes the small slice osaurus owns.

Native Swift image generation is a separate pending lane. Osaurus does not
currently route local `/v1/images/generations` or `/v1/images/edits` through
`vMLXFlux`; see `NATIVE_SWIFT_IMAGE_GENERATION_INTEGRATION.md` for the wiring
contract and the current blocked vMLX matrix.

## End-to-end shape

```
ChatEngine (route resolution, attribution, logging)
    -> ModelRuntime (container lifecycle, model lease, prefill progress)
        -> MLXBatchAdapter
            -> BatchEngine.generate(input:parameters:)
                -> AsyncStream<Generation>
            -> GenerationEventMapper (Generation -> ModelRuntimeEvent)
                -> AsyncThrowingStream<ModelRuntimeEvent, Error>
```

`BatchEngine.generate` returns these event cases:

- `.chunk(String)` -- pure user-visible text. Reasoning markers and
  tool-call markers are stripped by the library before they reach
  osaurus.
- `.reasoning(String)` -- model reasoning text. Osaurus forwards this to
  `ModelRuntimeEvent.reasoning`, HTTP `reasoning_content`, the ChatView
  Think panel, and plugin `chunk.delta.reasoning_content`.
- `.prefillProgress(PrefillProgress)` -- real prompt-processing progress
  before the first generated token. Osaurus forwards this to
  `ModelRuntimeEvent.prefillProgress`, the in-band `prefill:` sentinel, and
  `InferenceProgressManager` so the Chat UI can render a determinate prefill
  percentage when total prompt/cache units are known.
- `.toolCall(ToolCall)` -- a fully-parsed tool call. Every supported
  family (JSON, Qwen `xml_function`, Mistral, GLM-4, LFM2, Kimi K2,
  Gemma-3/4, MiniMax M2) emits this once the call is complete.
- `.info(GenerateCompletionInfo)` -- final stats (token counts, prompt
  / generation time, stop reason, and `unclosedReasoning`). One per request.

`GenerationEventMapper` translates those into osaurus's local
`ModelRuntimeEvent` (`.tokens`, `.reasoning`, `.prefillProgress`,
`.toolInvocation`, `.completionInfo`).

## Cache management

vmlx's `CacheCoordinator` owns KV cache geometry. osaurus configures it
per container at load time
(`installCacheCoordinator` / `buildCacheCoordinatorConfig` in
[`ModelRuntime.swift`](../Packages/OsaurusCore/Services/ModelRuntime.swift)):

| Field | Value | Why |
|---|---|---|
| `modelKey` | `"<modelName>\|kv=turbo(3,3)\|cachefmt=2\|restore=fullhit-trim-eval1\|..."` for engine-selected proven full-KV rows; `kv=fp16` for hybrid/rotating/CCA/DSV4 rows unless explicitly overridden | per-model isolation across loads; KV-mode, serializer, restore-contract, and topology tags prevent serving disk entries encoded under a different cache contract after a runtime update |
| `diskCacheDir` | `OsaurusPaths.diskKVCache()` | osaurus-managed sandbox path |
| `enableDiskCache` | `true` when probe-write succeeds, else `false` | graceful fallback to memory-only when the dir is read-only / out-of-disk |
| `usePagedCache` | `false` by default | paged RAM KV blocks are opt-in because they mainly help multi-batch workloads; default single-batch UX keeps prefix reuse through disk/L2 without holding an extra paged RAM tier |
| `defaultKVMode` | `engine_selected` by default, resolved per model/topology: eligible full-KV Gemma QAT MXFP4/JANG_4M rows get TurboQuant KV, while hybrid/rotating/CCA/DSV4 rows stay native/fp16 unless explicitly overridden | TurboQuant is enabled by default only where the cache topology is valid for the architecture; DSV4/ZAYA/SSM/rotating companion caches keep their typed serializers and are not replaced by generic KV compression |
| `defaultMaxKVSize` | `65536` | prefill window; `longPromptMultiplier=2.0` covers the 131K case |
| `longPromptMultiplier` | `2.0` | rotating-cache cap kicks in only past 131K |
| `ssmMaxEntries` | `50` | SSM state cap for hybrid Mamba/CCA companion cache |
| `enableSSMReDerive` | `true` | enables hybrid SSM/linear-attention companion-state rederive/store by default |

`maxCacheBlocks`, `pagedBlockSize`, and `diskCacheMaxGB` are not
overridden; vmlx's defaults are used so a library tuning bump lands
without an app-layer redeploy.

DSV4 is intentionally left to vmlx's default cache topology. Osaurus does
not set `DSV4_KV_MODE`; unset means the production SWA+CSA+HSA
`DeepseekV4Cache` path. Operator-provided `DSV4_KV_MODE=full` or `tq`
is treated as a diagnostic override and disables the hybrid pool.
DSV4 disk-prefix reuse is additionally namespaced with
`layers=deepseekV4|prefix=hybrid-pool-disk|decode=max-rp110` so records
created before the current native pool serializer and max-reasoning decode
policy cannot be reused after an app/library update.
The final DSV4 server settings renderer must also prove the visible settings
match that topology: native DSV4 cache copy present, paged block size
fixed/disabled for DSV4 with the expected 256 display row when active metadata
reports it, generic q4/q8 KV controls disabled, pool quant state visible, JIT
disabled, and sampling defaults shown from bundle metadata. The CLI preview for
DSV4 must omit invalid generic flags: `--kv-cache-quantization`, `--enable-jit`,
`--is-mllm`, and `--speculative-model`.

The broader switch gate is
[`VMLX_SWIFT_OSAURUS_LIVE_MATRIX_2026_05_18.md`](VMLX_SWIFT_OSAURUS_LIVE_MATRIX_2026_05_18.md).
It requires real Osaurus chat-app and HTTP rows for VLM/omni media, reasoning
settings, saved-setting isolation, generation defaults, parser leak checks, and
cache stats before the consolidated package can be called production-clear.

## Runtime proof validation

Open runtime issues such as #1228, #1161, #1162, #1163, #903, and #1183 need
evidence rows that separate `proven`, `partial`, `failed`, and `unproven`
states. Source inspection or a load-only check is not enough to promote a
model family, cache path, system-prompt path, cancellation path, or media route.

[`RuntimeProofValidation.swift`](../Packages/OsaurusCore/Services/ModelRuntime/RuntimeProofValidation.swift)
contains the source-level validator used to keep that language precise. A row
marked `proven` is blocked unless the requirements it claims have matching
evidence:

- `tokensPerSecond` requires a recorded token/s value for generation rows.
- `visibleOutput` requires non-empty visible assistant text.
- `noParserMarkerLeak` rejects visible/runtime marker leaks such as tool-call,
  reasoning, DSML, or streaming sentinel fragments.
- `multiTurnCoherency` requires an explicit positive follow-up probe rather
  than a single happy-path answer.
- `systemPromptInjection` requires both source trace evidence showing the
  configured agent prompt reached the composed static `persona`/prefix surface
  and a positive live model probe showing the model obeyed that prompt. Source
  trace alone is contract coverage, not runtime proof.
- `ramFootprint` and `cancellation` require physical-footprint and cleanup
  evidence before a RAM or cancel row can be called proven.
- `cacheHit` applies topology-specific checks: full-attention rows need KV,
  prefix, and disk-L2 evidence; hybrid SSM rows need companion hits; ZAYA/CCA
  and DeepSeek pool rows need their companion/pool evidence instead of generic
  KV-only proof.
- `mediaPayload` requires a real media payload, cache salt, media-path routing,
  and cache-hit validation. Text-path evidence cannot prove an audio, image, or
  video route.

Rows marked `failed` remain valid evidence even when they lack the positive
fields above, but they should still carry an artifact path so the failure can be
replayed or inspected.

The live family runner also emits a machine-readable classification report:

```bash
scripts/live-proof/run-family-runtime-chat-matrix.sh FAMILY_FILTER=gemma
```

After the row summaries are collected, the runner writes
`PROOF_CLASSIFICATION.json` next to `SUMMARY.json`. The classifier reads the
existing `family-runtime-chat-matrix.json` manifest and each row summary, then
records:

- per-row verdicts using `proven`, `partial`, `failed`, or `unproven`
- the claimed proof requirements for that row
- blocker messages for missing token/s, visible output, parser-leak checks,
  multi-turn coherency, topology-specific cache evidence, or media-path proof
- issue-coverage notes for #1228, #1161, #1162, #1163, #903, and #1183

This report is intentionally stricter than the harness pass/fail bit. A row can
complete the tool/cache harness and still remain `partial` if, for example, a
VL model was tested through a text/tool path without a real media payload and
media cache salt. Those rows stay useful as evidence, but they must not close a
runtime/media issue as proven.

Use `scripts/live-proof/render-runtime-proof-matrix.py` to render the latest
`PROOF_CLASSIFICATION.json` into the matrix appendix in
[`RUNTIME_VALIDATION_STANDARD.md`](RUNTIME_VALIDATION_STANDARD.md). The renderer
also writes a read-only JSON surface for inspection workflows, and it keeps the
#903 system-prompt-injection and #1163 Hy3/harmony schema rows `unproven` until
real live artifacts exist. A #903 row needs both the source prompt trace and the
live probe artifact before it can move to `proven`.

osaurus deliberately does not pass `GenerateParameters.maxKVSize` -- a
global rotating cache window forced from the app layer conflicted with
sliding-window attention layers (e.g. Gemma-4 with a fixed per-layer
1024-position window) and produced
`[broadcast_shapes] (1,1,1,N) and (1,16,1,1024)` crashes on the first
decode step.

Before any local tool dictionary reaches a tokenizer chat template, Osaurus
normalizes only the template-facing JSON Schema copy: array-valued `type`
unions become a scalar `type` plus `nullable`, malformed or missing schema
types and bare boolean schemas get conservative renderable fallbacks, and
boolean `additionalProperties` is dropped. The original schema still drives
tool argument validation. This protects Gemma-4/Jang templates that run string
filters over schema metadata without adding hidden prompt repairs or parser
coercion.

For hybrid SSM families, osaurus eagerly calls `CacheCoordinator.setHybrid(_:)`
for known model families and vmlx also auto-detects Mamba/Arrays caches on
first slot admission. DSV4 is not an SSM hybrid; vmlx detects its
`HybridPoolCache` and flips `isPagedIncompatible` so prefix reuse goes through
the `LayerKind.deepseekV4` disk serializer instead of generic paged KV blocks.

## Concurrency

| Layer | What it protects |
|---|---|
| `BatchEngine` actor (vmlx) | Serializes Metal / model access. Continuous batching for same-model concurrent requests. |
| `MLXBatchAdapter.Registry` | Keeps one `BatchEngine` per model name and coalesces concurrent first creation so two same-model requests cannot build duplicate engines for one `ModelContainer`. |
| `ModelLease` | Pins a model name for the lifetime of one stream so eviction (`unload`, `clearAll`, GC) blocks until the lease drops to zero. |
| `ModelResidencyManager` | Schedules Osaurus-owned idle unload policy after the final lease drops; it never owns execution, KV cache, or disk cache deletion. |
| `PluginHostAPI` per-plugin in-flight cap | Caps concurrent inference calls per plugin (default 2). Excess returns `plugin_busy`. |
| `MetalGate` (`enterGeneration` / `enterEmbedding` / `enterModelLoad`) | Serializes GPU producers across families so concurrent command buffers can't trip `AGXG17XFamilyCommandBuffer` asserts. Generation (`gen:<model>`, shared per model) gates `MLXBatchAdapter.prepareInput` and the live-voice audio pre-encode (`ModelRuntime.preencodeLiveVoiceAudioIfResident`); embedding (`MetalSafeEmbedder`) and model load are exclusive. |

## Residency policy

Settings > Local Inference > Model Management includes **Keep model loaded
after use**. The default remains `Immediately` for compatibility with older
window-close GC behavior. Users can choose 5, 15, 30, or 60 minutes, or
`Never`, to keep weights resident after the last stream releases its
`ModelLease`.

This is an Osaurus memory-residency policy around `ModelRuntime.unload(name:)`.
It unloads model weights and runtime buffers only; it does not delete
downloaded models or vmlx disk KV cache entries. Strict single-model eviction,
manual unload, `clearAll`, app quit, and memory cleanup still win over idle
timers. `/health` keeps the existing `loaded`, `current_model`, and `inflight`
fields and adds `resident_models[]` with per-model `idle_unload_at` and
`idle_seconds_remaining` diagnostics.

## Tunable

A single `defaults` knob remains:

```bash
defaults write ai.osaurus ai.osaurus.scheduler.mlxBatchEngineMaxBatchSize -int 8
```

Defaults to `1`, clamped to `[1, 32]`. The default preserves vmlx's
compiled-decode path for single-user chat. Higher values raise possible
same-model concurrency at the cost of compile eligibility, wired-memory
footprint, and per-request latency.

`BatchEngine.maxBatchSize` is mutable at runtime as of vmlx pin `b9da180`
via `BatchEngine.updateMaxBatchSize(_:)`. The registry hot-resizes the
cached engine when a later request asks for a different value, so the
defaults key takes effect on the next inference call rather than waiting
for an unload/reload. An `engineShutdown` rejection from vmlx (the cached
engine was torn down between calls) triggers an evict + rebuild: the
adapter calls `coalescer.remove(_:dispose:)` to retire the dead handle
through the same tombstone-protected teardown that `shutdownEngine` uses,
then recurses into `engine(...)` so the next request lands through the
coalescer's first-fetch path with a fresh BatchEngine constructed at the
requested batch size. Other errors (e.g. caller-side
`invalidMaxBatchSize`) leave the cached engine intact. See
[`InferenceFeatureFlags.swift`](../Packages/OsaurusCore/Services/ModelRuntime/InferenceFeatureFlags.swift).

## Upstream runtime boundaries

These are deliberately not papered over in osaurus because they belong in
`vmlx-swift`, but the app has explicit policy around each one:

- Ling JANGTQ2 long prompts (`BailingLinearAttention.recurrentGLA`):
  pre-`b9da180`, vmlx dispatched the recurrent loop as `L * layers` small
  MLX graphs and the codebook gather hit a Metal pipeline-state lifetime
  bug at ~2 k tokens, surfacing as `EXC_BAD_ACCESS` on Ling JANGTQ2 long
  prompts. `b9da180` ports the recurrent GLA to a fused Metal kernel
  (`bailing_recurrent_gla` via a singleton kernel manager) so the loop
  runs in one command, eliminating the lifetime bug. Osaurus now defaults
  Ling thinking off through the model profile, but preserves explicit
  user/API opt-in and keeps any `.reasoning` output on the reasoning rail
  for root-cause visibility. MXFP4/JANGTQ4 remain recommended for long
  preambles for the orthogonal JANGTQ2 quality-ceiling reason. See
  `LING_JANGTQ2_LONG_PROMPT_CRASH.md`.
- vmlx pin `b9da180` reorders the SSM re-derive pass to run AFTER the
  generation yields completion `.info`, so the SSE stream no longer
  stays open while the re-derive runs. Osaurus keeps
  `enableSSMReDerive=true` so hybrid SSM/linear-attention rows can
  restore companion state by default instead of silently degrading to
  KV-only reuse.
- A load-time `convertToBFloat16(model:)` crash has been observed after
  prior GPU faults on the same boot: `mlx::core::Fence::wait` ->
  `AGX::ComputeContext::endComputePass`. This is below the recoverable
  MLX error-handler layer. Treat it as mlx-swift/Metal diagnostic
  evidence; reboot clears the poisoned GPU state.
- Runtime `BatchEngine.maxBatchSize` is now mutable on `b9da180` via
  `updateMaxBatchSize(_:)`; the registry hot-resizes instead of evicting.
- `BatchEngine.isShutdown` (also new on `b9da180`) makes terminated-engine
  submissions fail-closed: a stale handle landing during unload returns a
  `.cancelled` info event from vmlx instead of restarting GPU work. This
  is defense-in-depth for the host-side TaskCoalescer drain semantics
  documented in `MLXBatchAdapter.Registry`.

## Sentinel scheme (in-band streaming hints)

`ChatEngine.streamWithTools` returns `AsyncThrowingStream<String,
Error>`. Non-content events ride along on the same stream as sentinel
strings starting with `\u{FFFE}`:

| Sentinel | Producer | Consumer |
|---|---|---|
| `\u{FFFE}tool:` | local + remote tool call name | HTTP SSE -> `tool_calls` deltas; ChatView Think panel |
| `\u{FFFE}args:` | tool argument fragments | HTTP SSE -> `tool_calls.function.arguments` deltas |
| `\u{FFFE}done:` | server-side tool call result | ChatView (tool result card) |
| `\u{FFFE}prefill:` | local vMLX prefill progress JSON | ChatView loading label through `InferenceProgressManager`; HTTP/plugin handlers treat it as an internal sentinel unless they add an explicit public progress event |
| `\u{FFFE}stats:` | post-stream perf | ChatView, plugin `chunk.delta.stats` |
| `\u{FFFE}reasoning:` | local (forward-compat) + remote `reasoning_content` | OpenAI SSE `reasoning_content`; Anthropic `thinking_delta`; OpenResponses `response.reasoning_summary_text.delta`; ChatView Think panel; plugin `chunk.delta.reasoning_content` |

HTTP handlers, ChatView, and the plugin SDK MUST decode any sentinel with
public meaning (`StreamingReasoningHint`, `StreamingStatsHint`, and future
public progress events) BEFORE the generic `StreamingToolHint.isSentinel`
filter, otherwise that signal gets dropped together with the private tool
sentinels.

## Source map

| File | Role |
|---|---|
| `ModelRuntime.swift` | Container lifecycle (load / unload / strict eviction), `ModelLease` glue, single MLX entry into `MLXBatchAdapter`. |
| `MLXBatchAdapter.swift` | Per-model `BatchEngine` registry; submits each request via `engine.generate(...)`. |
| `GenerationEventMapper.swift` | `Generation` -> `ModelRuntimeEvent` bridge; stop-sequence lookahead; prefill progress forwarding; tool-call argument JSON serialization. |
| `Events.swift` | `ModelRuntimeEvent` enum (`tokens` / `reasoning` / `prefillProgress` / `toolInvocation` / `completionInfo`). |
| `RuntimeConfig.swift` | Server-side default `topP`. |
| `InferenceFeatureFlags.swift` | Single user-tunable: `mlxBatchEngineMaxBatchSize`. |
| `RuntimeProofValidation.swift` | Source-level validation for runtime proof rows and issue-closure evidence. |
| `MetalGate.swift` | Cross-family GPU serialization gate. `enterGeneration` (shared per model) wraps `MLXBatchAdapter.prepareInput` + the live-voice audio pre-encode; `enterEmbedding` and `enterModelLoad` are exclusive. |
| `ModelLease.swift` | Per-model refcount; `unload(name)` waits for `count == 0` before freeing buffers. |
| `ModelResidencyManager.swift` | Per-model idle timers and health snapshots for the Settings residency policy. |
| `NATIVE_SWIFT_IMAGE_GENERATION_INTEGRATION.md` | Pending native Swift image-generation lane and release gate. |

## Tests

| File | Coverage |
|---|---|
| `MLXBatchAdapterTests` | Max-batch-size flag clamping; Ling default-off plus explicit thinking opt-in context; ZAYA default-off but explicit thinking opt-in context; registry-shutdown safety. |
| `ModelResidencyManagerTests` | Timer scheduling, cancellation on new use, never policy, and active-lease protection. |
| `TaskCoalescerTests` | Single-flight engine-creation discipline and teardown-during-creation races. |
| `RuntimePolicySourceTests` | Source-level guardrails for DSV4 cache ownership, vmlx pin, SSM re-derive opt-out, idle residency wiring, and max-batch docs. |
| `RuntimeProofValidationTests` | Proven/partial/failed/unproven proof-row validation; token/s, parser leak, cache, media, and artifact checks. |
| `GenerationEventMapperTests` | `chunk` -> `tokens`; `toolCall` -> `toolInvocation` JSON serialization (happy path + failure envelope); `info` -> `completionInfo`; cross-chunk stop-sequence cut. |
| `StreamingReasoningHintTests` | Sentinel encode/decode round-trip; co-existence with the tool sentinel filter. |
| `MetalGateTests` | Embedding gate happy paths. |
