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
- `.toolCall(ToolCall)` -- a fully-parsed tool call. Every supported
  family (JSON, Qwen `xml_function`, Mistral, GLM-4, LFM2, Kimi K2,
  Gemma-3/4, MiniMax M2) emits this once the call is complete.
- `.info(GenerateCompletionInfo)` -- final stats (token counts, prompt
  / generation time, stop reason, and `unclosedReasoning`). One per request.

`GenerationEventMapper` translates those into osaurus's local
`ModelRuntimeEvent` (`.tokens`, `.reasoning`, `.toolInvocation`,
`.completionInfo`).

## Cache management

vmlx's `CacheCoordinator` owns KV cache geometry. osaurus configures it
per container at load time
(`installCacheCoordinator` / `buildCacheCoordinatorConfig` in
[`ModelRuntime.swift`](../Packages/OsaurusCore/Services/ModelRuntime.swift)):

| Field | Value | Why |
|---|---|---|
| `modelKey` | `"<modelName>\|kv=fp16\|cachefmt=2\|restore=fullhit-trim-eval1\|..."` | per-model isolation across loads; KV-mode, serializer, restore-contract, and topology tags prevent serving disk entries encoded under a different cache contract after a runtime update |
| `diskCacheDir` | `OsaurusPaths.diskKVCache()` | osaurus-managed sandbox path |
| `enableDiskCache` | `true` when probe-write succeeds, else `false` | graceful fallback to memory-only when the dir is read-only / out-of-disk |
| `usePagedCache` | `true` | content-addressed paged blocks for prefix reuse |
| `defaultKVMode` | `.none` (fp16) | TurboQuant 3-bit / 4-bit codebooks have an open per-step drift bug (`CompilableTurboQuantKVCache.swift` iter-10 measurement); fp16 is the only safe default until that closes |
| `defaultMaxKVSize` | `65536` | prefill window; `longPromptMultiplier=2.0` covers the 131K case |
| `longPromptMultiplier` | `2.0` | rotating-cache cap kicks in only past 131K |
| `ssmMaxEntries` | `50` | SSM state cap for hybrid Mamba/CCA companion cache |
| `enableSSMReDerive` | `false` | disables vmlx's end-of-generation second-prefill SSM re-derive — see "Upstream runtime boundaries" below |

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
For `reasoningEffort=max`, Osaurus applies a DSV4-specific default
`repetitionPenalty=1.10` only when the request did not specify one and the
bundle default is no-op. This is a decode stability policy for the observed
raw max-reasoning repeated-token loop; explicit request penalties still win.

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

osaurus deliberately does not pass `GenerateParameters.maxKVSize` -- a
global rotating cache window forced from the app layer conflicted with
sliding-window attention layers (e.g. Gemma-4 with a fixed per-layer
1024-position window) and produced
`[broadcast_shapes] (1,1,1,N) and (1,16,1,1024)` crashes on the first
decode step.

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
| `MetalGate.enterEmbedding` | Embedding service (`MetalSafeEmbedder`) opt-in serialization point. The generation surface of the gate was retired; only embeddings call into it today. |

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
  stays open while the re-derive runs. Osaurus still sets
  `enableSSMReDerive=false` for chat traffic — not for the old stream-
  ordering reason but because osaurus's chat workload mutates the
  system prefix every turn (memory injection, preflight capability
  search, dynamic skills) so the SSM cache rarely lands a boundary-
  matching hit and the re-derive cost is paid without warm-cache payoff.
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
| `\u{FFFE}stats:` | post-stream perf | ChatView, plugin `chunk.delta.stats` |
| `\u{FFFE}reasoning:` | local (forward-compat) + remote `reasoning_content` | OpenAI SSE `reasoning_content`; Anthropic `thinking_delta`; OpenResponses `response.reasoning_summary_text.delta`; ChatView Think panel; plugin `chunk.delta.reasoning_content` |

HTTP handlers and the plugin SDK MUST decode `StreamingReasoningHint`
BEFORE the generic `StreamingToolHint.isSentinel` filter, otherwise
reasoning gets dropped together with the other sentinels.

## Source map

| File | Role |
|---|---|
| `ModelRuntime.swift` | Container lifecycle (load / unload / strict eviction), `ModelLease` glue, single MLX entry into `MLXBatchAdapter`. |
| `MLXBatchAdapter.swift` | Per-model `BatchEngine` registry; submits each request via `engine.generate(...)`. |
| `GenerationEventMapper.swift` | `Generation` -> `ModelRuntimeEvent` bridge; stop-sequence lookahead; tool-call argument JSON serialization. |
| `Events.swift` | `ModelRuntimeEvent` enum (`tokens` / `reasoning` / `toolInvocation` / `completionInfo`). |
| `RuntimeConfig.swift` | Server-side default `topP`. |
| `InferenceFeatureFlags.swift` | Single user-tunable: `mlxBatchEngineMaxBatchSize`. |
| `MetalGate.swift` | Embedding-only counter (kept as the canonical hook for any future MLX-vs-CoreML interlock). |
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
| `GenerationEventMapperTests` | `chunk` -> `tokens`; `toolCall` -> `toolInvocation` JSON serialization (happy path + failure envelope); `info` -> `completionInfo`; cross-chunk stop-sequence cut. |
| `StreamingReasoningHintTests` | Sentinel encode/decode round-trip; co-existence with the tool sentinel filter. |
| `MetalGateTests` | Embedding gate happy paths. |
