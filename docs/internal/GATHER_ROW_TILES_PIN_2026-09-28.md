# Gather row tiles engine pin — proof pending

Candidate engine: `e8b5a7eb75ef76cd6629fb17c899e05ed4b1d359`.
Core: `083a6742d` (osaurus-ai/mlx#12, draft).

All six executable pin/contract locations agree. The historical composite-cache
receipt remains unchanged because it describes the previous tested app.

This consumes expert-boundary scheduling for floating-point and affine gathered
Metal matmul, a partial-K NAX bounds correction, and the already-merged Unicode
BPE, BPE merge ordering, quantization_config, and SDK-gated JACCL changes.
No application sampling or residency setting is changed by this pin.

Required before merge:
- [ ] Exact-head engine CI and numerical/batch/cache regressions.
- [ ] Fresh pinned Release app build and recorded binary identity.
- [ ] Text multi-turn and concurrent requests with bundle defaults.
- [ ] Real image/video payloads, repeated-media cache hits and changed-media misses.
- [ ] Prefix/disk restoration with architecture companion state and truthful telemetry.
- [ ] Applicable full eval results, every failed/skipped row attributed, final CI.

The smart-swapping/batching setting audit is a separate follow-up: new-user ON,
persisted OFF, same-model shared batching, different-model unload/load/restore,
OFF coexistence with memory admission, cancellation and parent continuation.
Source defaults alone do not close those live proof rows.

No release or tag. Merge only after the required live evidence is complete.

The updated candidate also fixes a shapeless compiled Qwen MoE batch contraction
crash and propagates canonical Qwen image/video and Nemotron image cache
boundaries. Engine diagnostics passed real concurrent requests on three
architectures, generated restored Qwen image/video and Nemotron/Gemma image
replays, changed-media misses, and parsed follow-ups. These do not close the
pinned app GUI gate.

Known separate follow-up: Nemotron video EVS still falls back to full prefill
because a safe recurrent prefix checkpoint is absent. No video-cache reuse
claim for that path. Gemma4 video is explicitly unsupported. Full-model
performance remains under paired measurement; no universal chip speed claim.

The pin also consumes the focused tied-head activation-dtype correction (vmlx-swift#523). Optional Q6 head conversion now preserves the source FP16 stream instead of promoting Gemma arithmetic through mixed BF16/FP16 types. Engine numerical, matched-output performance, two-slot concurrency and image-cache replay tests pass. The newly pinned app must be rebuilt and re-proven; previous GUI rows describe the prior pin.

The app cache identity now includes the optional tied-head policy (including diagnostic bit/group overrides) and the source-dtype activation contract. Old incompatible entries remain on disk but cannot match the new namespace. Compile diagnostics distinguish a requested path from proof that compilation executed. These host changes require fresh tests/build/GUI evidence.

The latest engine also preserves native Gemma KV storage precision on disk/paged restore, through a model-owned versioned namespace. The preceding pinned app exposed FP16 cold caches becoming BF16 on restore and FP32 on append. Two new Metal tests pass on both Gemma entrypoints and mixed sliding/full caches across FP16/BF16/FP32. Fresh app proof for this follow-up is pending.
