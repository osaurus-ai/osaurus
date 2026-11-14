# Gather row tiles engine pin — closeout in progress

Candidate engine: `094cc09b8e0130504976a38370a5a92fbcf258b0`.
Core: `083a6742d4beb0a2d3484e1ba35c7f360aec2a06` (osaurus-ai/mlx#12, merged).
All six executable pin/contract locations agree. Historical receipts retain their original source and binary identities.

The engine consumes expert-boundary scheduling for floating-point and eligible affine gathered Metal matmul, the partial-K NAX bounds correction, dynamic Qwen compiled B2-to-B1 score expansion, safe media-cache boundaries, tied-head activation dtype and native Gemma KV storage precision. It also contains the previously merged Unicode BPE, BPE ordering, quantization_config and SDK-gated JACCL changes. Small decode and custom quantization paths are not claimed to accelerate. The pin introduces no sampling or residency setting override.

## Completed evidence and source boundaries

The prior app `2608bc55aae8a8538181f843322451fa616c8433` pinned engine `e8b5a7eb75ef76cd6629fb17c899e05ed4b1d359` and passed a Release build plus actual GUI cold generation, follow-up disk restore and process-restart restore. Binary SHA256: `afd4a9a454fbad66fae5515ae2cb090590c66266f60b9566ddeb2f90a4297290`. The three answers completed naturally and coherently at 55.8, 57.2 and 57.8 tokens/s (57, 31 and 25 tokens). Eleven new cache payloads each retained 60 FP16 tensors, without FP32 promotion. Peak physical footprint was 13.87 GB. This proves those cache-correctness rows; it is not a paired speed benchmark or proof of requested compiled execution.

The current engine's complete tree equals the tested Xcode wiring candidate `c0deb299e4c0c65233135e57a5491135e76d56ed`. Its only changes from e8 are the standalone Xcode project/config inclusion of existing SDK-gated JACCL wrappers. SwiftPM configuration and all runtime source/test files are unchanged from e8. The standalone Xcode link omission was reproduced before the wiring fix; candidate build passes, with remaining test status tracked separately. This does not establish distributed hardware or collective execution.

Exact-e8 local checks completed: SwiftPM build, Cmlx 2/2, MLX XCTest 545 passes with three documented skips, Swift Testing 11/11, and CMake 251/251. Prior numerical, batch and cache diagnostics include 396 numerical cases, 64 targeted regressions, real concurrent requests on three architectures and supported generated media replay/follow-up. Four focused dtype/cache tests passed at e8. The prior app's nine CI checks pass. Eval CI is scripted/model-free and cannot supply live AgentLoop/Frontier model scores.

This app candidate merges upstream main `0a114acdb` before repinning. Upstream application changes mean the new app must be built and checked; the historical2608 GUI run is not relabeled as execution of the new app.

## Remaining promotion gates

- [ ] Final-head engine CI/local standalone Xcode test closeout with skips attributed.
- [ ] Fresh pinned Release app build, binary identity and final app CI.
- [ ] Current pinned app B2 concurrency with coherent completed responses and throughput/residency evidence.
- [ ] Current pinned GUI real-media replay, changed-media miss and generated history follow-up, preserving architecture companion state and truthful cache telemetry.
- [ ] Applicable live model eval scores, with every failure/skip attributed; model-free CI is insufficient.

Gemma cache telemetry must distinguish rotating/full KV and disk restore from TurboQuant layers and paged RAM; requested settings alone are not execution evidence. The cache namespace includes tied-head policy and source activation contract, while native Gemma storage has its own versioned identity.

Nemotron EVS video still falls back to full prefill without a safe recurrent checkpoint; video-cache reuse is not claimed. Gemma4 video is unsupported. No universal-chip speedup or physical M3/M4 result is claimed.

Smart-swap default ON, persisted OFF, same-model batching, different-model unload/load/restore, OFF coexistence, cancellation and parent continuation remain separately scoped live proof. No release or tag. Merge only after the applicable live gates close.
