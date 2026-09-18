# Bonsai2 FP16 attention KV / FP32 recurrence

Status: candidate pin; native precision proof pending. Do not merge until the
exact-pinned development build exercises actual image and tool continuations.
Candidate engine: 73ebf52507743a871bac58c432e9c0522bf262c2, PR484.

Consumes engine PR484. FP32 normalization weights promote Bonsai activations;
the old configured FP16 mode did not narrow actual K/V. New code narrows Q/K/V
only at attention after normalization and RoPE, selected by installed Hadamard
projection modules on both text and VLM routes. Projection output math, stored
weights, FP32 GDN recurrent state and explicit quantized caches are unchanged.
The new numerical policy has a separate model cache key; existing image,
tool/schema and reasoning salts are retained.
Model-owned native dtype preservation also covers disk and paged restores;
unmarked legacy records and other models retain their previous behavior.

All four dependency pins and two exact-pin regression assertions move together.
No new app setting, sampler/template override, release, tag or installation.

## Proof required before merge

- Engine focused Metal dtype/storage/compiled/batch/vision/disk-tool regressions.
- Current-source optimized development app with exact engine pin, binary hash
  and vendor identity. One local Bonsai model loaded at a time on authorized Max2.
- Real image and per-tool cache continuations for both local storage variants;
  actual persisted KV F16 and recurrent F32, not a nominal settings label.
- Record visible outcomes, natural stops, prefill/cache tokens, token/s and
  physical footprint; report failures, not a blanket family-quality claim.
- Required Osaurus CI and ordinary squash merge after scoped source review.

Raw evidence: private runtime-followup-2026-09-18; old run8 cache headers confirm
32 FP32 attention tensors and48 FP32 recurrent tensors per full checkpoint.
Those old files establish the baseline, not proof of this new pin.
