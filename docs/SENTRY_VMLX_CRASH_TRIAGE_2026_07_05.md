# Sentry VMLX Crash Triage — 0.21.6 (2026-07-05)

Handoff list for the VMLX workstream. These crash groups were triaged from the
`osaurus-inc/apple-macos` Sentry project for release
`com.dinoki.osaurus@0.21.6+0.21.6` (production). Every stack bottoms out in
`vmlx-swift` frames (`BatchEngine.swift`, `Evaluate.swift`, model files) or
MLX core / Metal — none of the crashing files exist in the Osaurus repo, so
**no Osaurus-side code changes were made for these rows**. Flagged only, per
triage instruction.

The one app-side crash from the same triage (APPLE-MACOS-9T,
`ExternalPlugin.shutdown` teardown use-after-free) was fixed in Osaurus — see
`Packages/OsaurusCore/Models/Plugin/ExternalPlugin.swift` and
`PluginShutdownRaceTests`.

## Theme 1 — Indexing / precondition failures in model forward passes

| Issue | Events | Status | Signature |
|---|---|---|---|
| [APPLE-MACOS-WV](https://osaurus-inc.sentry.io/issues/APPLE-MACOS-WV) | 27, **escalating**, new in 0.21.6 window | unresolved | `MLXArray` indexing precondition in `Qwen3VLLanguage.RotaryEmbedding` via `BatchEngine.stepBatchDecode` (BatchEngine.swift:2375, Qwen3VL.swift:1110, MLXArray+Indexing.swift:696) |
| [APPLE-MACOS-1A](https://osaurus-inc.sentry.io/issues/APPLE-MACOS-1A) | 31 since Jun 4 | unresolved | `Array._checkSubscript` OOB in `Gemma4.prepare` → `maskedScatter` (Gemma4.swift:1104) during solo fast-path prefill |
| [APPLE-MACOS-EJ](https://osaurus-inc.sentry.io/issues/APPLE-MACOS-EJ) | 13 since Jun 16 | unresolved | `Array._checkSubscript` OOB in Gemma4 `TextMLP` inside the compiled decode trace (Gemma4Text.swift:376, Transforms+Compile.swift) |
| [APPLE-MACOS-CA](https://osaurus-inc.sentry.io/issues/APPLE-MACOS-CA) | 15, last on 0.21.2 (Jul 1) | resolved as stale | `MiniMaxJANGTQAttention` MLXArray ellipsis indexing (MiniMaxJANGTQ.swift:119, MLXArray+Indexing.swift:517). Auto-reopens on regression |

## Theme 2 — Metal command-encoder / command-buffer lifecycle races

Common thread: encoder/buffer state races in `mlx::core::metal` under
concurrent load (BatchEngine + chunked VLM prefill). Likely one underlying
lifecycle bug with several surfaces.

| Issue | Events | Status | Signature |
|---|---|---|---|
| [APPLE-MACOS-6H](https://osaurus-inc.sentry.io/issues/APPLE-MACOS-6H) | 27 (16 in 0.21.6) | **reopened as regressed** | `addCompletedHandler: provided after commit call` assertion during `Mistral3VLMJANGTQ.prepare` → `chunkedPrefillEmbedding` (ChunkedPrefillVLM.swift:71) |
| [APPLE-MACOS-PE](https://osaurus-inc.sentry.io/issues/APPLE-MACOS-PE) (+ siblings 12, T2) | 4 | unresolved | `EXC_BAD_ACCESS` creating a compute command encoder in the same Mistral3VLMJANGTQ chunked-prefill path (device.cpp:537). Same user/machine as 6H |
| [APPLE-MACOS-33](https://osaurus-inc.sentry.io/issues/APPLE-MACOS-33) / KY / WZ | 8 / 2 / 1 | unresolved | AGX driver assertion "a command encoder is already encoding" across G16/G17 GPU families |
| [APPLE-MACOS-1Z](https://osaurus-inc.sentry.io/issues/APPLE-MACOS-1Z) / K1 | 3 / 2 | unresolved | malloc "pointer being freed was not allocated" in `CommandEncoder::set_input_array` / `maybeInsertBarrier` |
| [APPLE-MACOS-T1](https://osaurus-inc.sentry.io/issues/APPLE-MACOS-T1) | 4 | unresolved | `_status < MTLCommandBufferStatusCommitted` assertion |
| [APPLE-MACOS-11](https://osaurus-inc.sentry.io/issues/APPLE-MACOS-11) / XT | 6 / 1, last 6h ago | unresolved | `EXC_BAD_ACCESS` in `mlx::core::metal::Device::end_encoding` |
| [APPLE-MACOS-XY](https://osaurus-inc.sentry.io/issues/APPLE-MACOS-XY) | 1, brand new | unresolved | `EXC_BAD_ACCESS` in `mlx::core::Reduce::eval_gpu` → `setComputePipelineState:`. Watch for growth |
| [APPLE-MACOS-3T](https://osaurus-inc.sentry.io/issues/APPLE-MACOS-3T) | 18 | ignored | C++ `runtime_error`: Metal command buffer OOM (`kIOGPUCommandBufferCallbackErrorOutOfMemory`). Related to RAM-gate policy work |
| [APPLE-MACOS-4](https://osaurus-inc.sentry.io/issues/APPLE-MACOS-4) | 10 | ignored, assigned Eric Jang | `commit command buffer with uncommitted encoder` assertion |

## Theme 3 — Deterministic config / kernel bugs (100% repro for affected users)

| Issue | Events | Status | Signature |
|---|---|---|---|
| [APPLE-MACOS-SM](https://osaurus-inc.sentry.io/issues/APPLE-MACOS-SM) | 4 | unresolved | `custom_kernel_jangtq_hadamard_multiblock` requests 65536 B threadgroup memory on a GPU with a 32768 B limit — deterministic abort for JANGTQ models on lower-tier chips. Kernel must size to the device limit |
| [APPLE-MACOS-PD](https://osaurus-inc.sentry.io/issues/APPLE-MACOS-PD) | 4 | unresolved | `fatalError` at MLXVLM/Mistral3.swift:342: `rope_parameters['rope_theta'] is required` — hard crash on loading a Mistral3 bundle missing the key. Should be a typed load error, not `fatalError` (per the memory-safety contract: fail before unsafe allocation with a clear typed error) |

## Notes

- All rows above report 0 "users impacted" only because `sendDefaultPii`
  is off and `event.user` is stripped in `beforeSend`; event counts and
  distinct `app.device` hashes are the real impact signal.
- The high-volume `OsaurusMain.main` app-hang group (APPLE-MACOS-5, 1153
  events) and SwiftUI/CoreText framework hang groups remain ignored as
  non-actionable sample points.
