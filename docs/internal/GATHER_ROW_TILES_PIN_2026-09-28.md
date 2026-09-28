# Gather row tiles engine pin — proof pending

Candidate engine: `146ddb0135ac366c64de4ded6ec2468ff947b9e8`.
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
