# Inference Runtime

How Osaurus routes inference requests, what protects you from crashes when many requests fly at once, and the feature flags for tuning the system without rebuilding.

If you came here because of a freeze or a Metal crash, jump to [Crash & freeze classes we close](#crash--freeze-classes-we-close).

---

## Default behavior (TL;DR)

With **no flags set** (the shipping defaults):

- **One MLX generation runs at a time.** Every chat / API / plugin / background-task request goes through the same global slot. This matches pre-refactor behavior — no surprises, no Metal-vs-Metal races.
- **Requests are served by priority, not arrival order.** A typing user (`.interactive`) jumps ahead of a webhook plugin (`.plugin`) which jumps ahead of background work and maintenance.
- **In-flight models can never be unloaded.** A model lease pins weights for the entire stream lifetime, including across the multi-iteration tool-calling loop. Closing a chat window mid-stream no longer crashes Metal.
- **Plugins are capped at 2 concurrent inference calls each.** Bursts above the cap return `{"error": "plugin_busy"}` immediately instead of stacking blocked threads — that's what was causing the "frozen UI" reports.
- **Local embeddings still mutually-exclude with MLX generation** at the Metal layer (this is the original purpose of `MetalGate`).

Everything else listed below is opt-in via `defaults write`. Defaults are conservative because the new paths haven't burned in under production load yet.

---

## Architecture

```
┌─────────────┐  ┌────────┐  ┌────────┐  ┌─────────────┐  ┌─────────────┐
│ Chat UI     │  │ HTTP   │  │ Plugin │  │ Background  │  │ Preflight / │
│ (.interactive)  │ (.httpAPI) │ (.plugin) │ Work        │  │ Memory      │
└──────┬──────┘  └───┬────┘  └───┬────┘  │ (.background)│  │ (.maintenance)
       │             │           │       └──────┬──────┘  └──────┬──────┘
       └─────────────┴───────────┴──────────────┴────────────────┘
                                 │
                          ChatEngine (per source)
                                 │
                          MLXService.streamWithTools(...)
                                 │
                                 ▼
              ╔══════════════════════════════════════╗
              ║           ModelRuntime               ║
              ║                                      ║
              ║  ┌────────────────────────────────┐  ║
              ║  │ ModelLease.acquire(modelName)  │  ║   ← pin against eviction
              ║  └──────────────┬─────────────────┘  ║
              ║                 │                    ║
              ║      ┌──────────┴──────────┐         ║
              ║      │  mlxBatchEngine ?   │         ║
              ║      └──────┬──────────────┘         ║
              ║   off       │             on         ║
              ║   ▼         │             ▼          ║
              ║ Direct path │      BatchEngine path  ║
              ║             │                        ║
              ╚═════════════╪════════════════════════╝
                            │
        ┌───────────────────┴────────────────────┐
        │                                        │
        ▼                                        ▼
┌──────────────────────┐              ┌─────────────────────┐
│ Direct (default)     │              │ BatchEngine (flag)  │
│                      │              │                     │
│ ModelWorker          │              │ Per-model engine    │
│   ↓                  │              │ actor (continuous   │
│ InferenceScheduler   │              │ batching)           │
│   ↓ (priority FIFO)  │              │                     │
│ MetalGate            │              │ Multi-turn KV cache │
│   ↓                  │              │ reuse,  mediaSalt,  │
│ TokenIterator +      │              │ sliding-window      │
│ CacheCoordinator     │              │ rotating cache      │
└──────────────────────┘              └─────────────────────┘
```

### What each layer does

| Layer | Type | Purpose |
|---|---|---|
| `ModelLease` | actor (refcount) | Pins a model name. `unload(name)` waits for `count == 0` before freeing buffers. Closes the eviction-mid-stream Metal crash class. |
| Per-plugin in-flight cap | `NSLock` | Limits any one plugin to N (default 2) concurrent inference calls. Excess calls return `plugin_busy` instead of blocking plugin worker threads. |
| `InferenceScheduler` | priority actor | Single-slot admission queue. Highest `InferencePriority` wins; FIFO within the same priority. Decides ORDER of MetalGate entry. |
| `ModelWorker` | per-model actor | Per-model serialization point. Today same-model requests still serialize; the seam is in place for future time-multiplexing. |
| `MetalGate` | actor | Mutual-exclusion gate against MLX-vs-CoreML overlap (the original `EXC_BAD_ACCESS` class on Apple Silicon). Optionally also gates MLX-vs-MLX. |
| `TokenIterator` | upstream | Per-request iterator with `CacheCoordinator` integration — multi-tier KV reuse, prefix matching, partial prefill. |
| `BatchEngine` | upstream actor | Continuous batching engine. One actor per model, runs its own scheduling loop, batches multiple requests into a single forward pass per decode step. |

### Priority levels

Set automatically based on `InferenceSource` in `ChatEngine.streamChat`:

| Priority | Raw | Sources |
|---|---|---|
| `.interactive` | 100 | Foreground chat UI typing |
| `.httpAPI` | 75 | External clients hitting `/v1/chat/completions` etc. |
| `.plugin` | 50 | Plugin `complete` / `complete_stream` calls |
| `.background` | 25 | Scheduled / detached background tasks |
| `.maintenance` | 0 | Preflight capability search, memory extraction, summarization, anything the user didn't explicitly request |

A typing user can never be starved by a 50k-token plugin batch job — the scheduler will admit `.interactive` ahead of any queued `.plugin` work as soon as the current generation finishes.

---

## Crash & freeze classes we close

| Symptom | Root cause | Fix |
|---|---|---|
| Metal `notifyExternalReferencesNonZeroOnDealloc` after closing a chat window mid-stream. | GC unloaded the model while a background task was still streaming from it. | `ModelLease` blocks `unload(name)` until the active stream releases its lease. |
| Metal assertion when switching models with `strictSingleModel` while a background task is mid-stream. | `loadContainer` evicted the in-use model. | Same lease, same wait — `unload` defers until safe. |
| UI freezes / unresponsive notch when several plugin webhooks fire at once. | Each plugin trampoline blocked a worker thread on a `DispatchSemaphore` while waiting for the global MLX gate. | Per-plugin in-flight cap (default 2) returns `plugin_busy` immediately for excess calls, plus `Task.detached` + dedicated GCD bridge queue so semaphore waits can't starve the cooperative pool. |
| Long-context plugin batch job blocks a typing user. | `MetalGate` was strictly FIFO — interactive requests waited behind whoever arrived first. | `InferenceScheduler` decides queue order by priority before MetalGate entry. |

---

## Feature flags

Flip any of these with `defaults write`. They take effect on the next inference request — no rebuild required.

### `mlxBatchEngine` (default: OFF)

Route MLX inference through `vmlx-swift-lm`'s continuous-batching `BatchEngine` instead of per-request `TokenIterator`. **2.5–5× throughput** when multiple requests for the same model arrive concurrently (they share a single forward pass per decode step).

```bash
defaults write ai.osaurus ai.osaurus.scheduler.mlxBatchEngine -bool YES
```

**When to enable**

- You serve many concurrent short prompts to one model (webhook fanout, batch classification).
- You want the throughput numbers from `vmlx-swift-lm/Libraries/MLXLMCommon/BatchEngine/BATCH_ENGINE.md`.

**What you give up**

- KV-cache quantization (`kvBits` / `kvMode`) is not yet applied during batched decode — wired-memory footprint per slot grows linearly until the upstream `BatchQuantizedKVCache` lands.
- `compile()` tracing is unavailable due to dynamic batch sizes — single-batch decode loses ~2-5% vs the iterator path; the gain comes purely from sharing the forward pass.
- When this flag is on, `MetalGate` / `InferenceScheduler` / `ModelWorker` are **bypassed for MLX** — the engine's own actor loop is the serialization point. `ModelLease` and per-plugin caps still apply. Local CoreML embeddings are no longer mutually-exclusive with batched MLX generation; if you mix the two heavily, validate stability before enabling.

What still works under this flag: multi-turn KV cache reuse (each slot calls `coordinator.fetch()` before prefill and `coordinator.storeAfterGeneration()` after), VLM cache via `mediaSalt`, sliding-window rotating cache, per-request sampling parameters.

### `mlxBatchEngineMaxBatchSize` (default: 4, max: 32)

Maximum simultaneous decode slots per model when the batch engine is on. Higher values increase total throughput but also wired-memory footprint and per-token latency for any one request.

```bash
defaults write ai.osaurus ai.osaurus.scheduler.mlxBatchEngineMaxBatchSize -int 8
```

The upstream default is 8; we ship 4 because on a 32 GB machine, 8 active slots of an MoE model can exhaust the wired cache budget. Tune up on workstations with more RAM.

### `mlxAllowConcurrentStreams` (default: OFF)

When on, `MetalGate.enterGeneration` no longer mutually-excludes MLX-vs-MLX (still gates MLX-vs-CoreML). Combined with the per-model `ModelWorker`, two streams of **different** models can run concurrently.

```bash
defaults write ai.osaurus ai.osaurus.scheduler.mlxAllowConcurrentStreams -bool YES
```

**Use only with `manualMultiModel` eviction policy** and enough RAM headroom for both models. Same-model concurrency is still forbidden by the per-model worker.

**Caution**: `MetalGate`'s docstring notes that overlapping Metal submissions can `EXC_BAD_ACCESS` on Apple Silicon. The MLX-vs-MLX risk has not been broadly validated in this codebase — opting in is at the operator's discretion.

### `cooperativeYield` (default: OFF)

When on, `StreamAccumulator` yields the cooperative thread pool between every 16 tokens whenever the scheduler has higher-priority work queued.

```bash
defaults write ai.osaurus ai.osaurus.scheduler.cooperativeYield -bool YES
```

This is **not** preemption — the GPU work continues; it just frees Swift Concurrency's pool so plugin event delivery, SwiftUI redraws, and log flushing don't stall during a long stream. Reduces "frozen UI" symptoms during 5k-token generations without introducing a true preemption mechanism.

---

## Inspecting what's in flight

Open the **Loaded Models** popover in the Management window. The "Inference Scheduler" section shows:

- **Active priority** (or `idle`) and which priority bucket is currently generating
- **Queue depth** total
- Per-priority queued counts (when there's a backlog)
- Lifetime **Admitted** and **Rejected** counters

This is your first stop when diagnosing latency: if you see `interactive: 1, plugin: 8` queued, the per-plugin cap is doing its job and a misbehaving plugin is sending too many concurrent requests.

---

## Reverting / disabling

Every flag clears with one line:

```bash
defaults delete ai.osaurus ai.osaurus.scheduler.mlxBatchEngine
defaults delete ai.osaurus ai.osaurus.scheduler.mlxBatchEngineMaxBatchSize
defaults delete ai.osaurus ai.osaurus.scheduler.mlxAllowConcurrentStreams
defaults delete ai.osaurus ai.osaurus.scheduler.cooperativeYield
```

Or wipe everything Osaurus-side:

```bash
defaults delete ai.osaurus
```

(That nukes the rest of Osaurus's preferences too — only do it if you're starting clean.)

---

## Source map

Implementation lives under `Packages/OsaurusCore/Services/ModelRuntime/`:

| File | Role |
|---|---|
| `ModelLease.swift` | Refcount lease that gates eviction. |
| `InferenceScheduler.swift` | Priority-aware single-slot admission queue. |
| `ModelWorker.swift` | Per-model serialization actor. |
| `MetalGate.swift` | MLX-vs-CoreML mutual exclusion. |
| `BatchEngineAdapter.swift` | Bridges per-model `BatchEngine` instances into the standard runtime stream shape. |
| `BatchEnginePlan.swift` | Tracks remaining upstream blockers (`kvQuantization`, `compileSupport`). |
| `InferenceFeatureFlags.swift` | All four flags above; `defaults`-backed. |
| `MLXGenerationEngine.swift` | The non-batch `TokenIterator` path. |
| `StreamAccumulator.swift` | Token-stream → typed event stream; tool-call detection; cooperative yield checkpoint. |
| `../ModelRuntime.swift` | Top-level `generateEventStream` dispatcher and lifecycle. |

Tests live alongside in `Packages/OsaurusCore/Tests/Service/`:

| Suite | Coverage |
|---|---|
| `ModelLeaseTests` | acquire/release/wait, double-release safety, `activeNames()` |
| `InferenceSchedulerTests` | priority ordering, FIFO within priority, snapshot, `shouldYield` |
| `ModelWorkerTests` | per-model serialization, registry identity, multi-model concurrency |
| `MetalGateTests` | the original embedding/generation mutual-exclusion contract |
| `BatchEngineAdapterTests` | flag default + override + clamping, registry shutdown safety |

---

## Related Documentation

- [Developer Tools](DEVELOPER_TOOLS.md) — Insights / Server Explorer / monitoring UI
- [OpenAI API Guide](OpenAI_API_GUIDE.md) — How requests reach the runtime in the first place
- [Plugin Authoring](PLUGIN_AUTHORING.md) — `complete` / `complete_stream` / `embed` semantics from the plugin side
