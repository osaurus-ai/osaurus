# Bonsai2 FP16 attention KV / FP32 recurrence

Status: exact-pinned native precision proof completed; final-repin CI required.
Merged engine: 6026359408f02c5867643d84300b0ca2225a2e88, PR484.
Tested engine: 73ebf52507743a871bac58c432e9c0522bf262c2. The squash adds only
evidence documentation relative to that tested production/test source.

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

## Current native proof

SOURCE EVIDENCE: app `f21ea6e21c640f8c032273ccc01c9cb17cdf94bb` was built with
all four pins at tested engine `73ebf525`. This final repin changes only those
four revisions, two pin assertions and this evidence document. The consumed
engine implementation and tests are unchanged by squash; verify the full diff
against `60263594`, not merely its commit message.

LIVE EVIDENCE: optimized development build log
`fp16-pin-build-f21ea6e21c640f8c032273ccc01c9cb17cdf94bb-one.log`, binary SHA256
`adff63f38576441a1d010797a12446d0cff55bffa592709386f73f73086ee52a`,
UUID `6863D2B0-7A59-3892-9E03-7FB54E2F75C9`.
This is the candidate-pin binary, not a claimed rebuild of the final squash pin.
The production source identity is checked separately, with final-head CI.

On authorized M5 Max2, each bundle completed three real native UI turns:
image recognition, file_write then file_read with correct answer, and no-tool
follow-up recall. Both correctly named red circle, blue square, green triangle,
and BIRCH. Ten generation steps naturally completed without a loop, marker leak
or length stop. Nine inspected actual checkpoints contain 32 F16 K/V tensors,
48 F32 recurrent states, 48 F32 convolution states and dtype-preservation marker1.
Each model restored all 64 layers from disk three times after tool boundaries
and on the next user turn; five stores per model. Stores/drain precede the next
tool execution and continuation. Paged/prefix RAM hits remained zero.

| Bundle | Five-step generation tok/s | Warm continuation prompt ms | Restored tokens |
| --- | --- | --- | --- |
| 1.75-bit | 16.6, 16.9, 18.0, 16.5, 16.9 | 1265, 947, 797 | 3134, 3491, 3686 |
| Ternary | 18.5, 16.4, 16.4, 16.3, 17.5 | 1893, 964, 659 | 3128, 3512, 3708 |

These 14–85-token outputs are not matched speedup or sustained-speed proof.
Cold image prompt processing was 21.874s /8.288s, with separately reported
model load 17.7s /11.4s. Tool-required second turns freshly prefilled; subsequent
tool continuations reused disk prefixes. Bundle sampling: temperature1,top-p.95,
top-k20,min-p0,MTPoff, UI reasoningNone. No sampler or template masking.

Raw evidence under the directory above: `fp16p2.stdout`, `fp16t.stdout`,
both `*-prefill-full.log` (offsets in launch JSON),
`live-captures/fp16p2-final`, `live-captures/fp16t-final`,
`fp16p2-vision-cache-dtypes.json`, `fp16p2-tools-recall-cache-dtypes.json`,
`fp16t-cache-dtypes.json`, and inspected `fp16{p2,t}-*-done.png`.
Both guarded runs exited0 with cleanup0 and normal host pressure; peak tracked
physical footprints 11.02GiB /9.37GiB, no swap growth. Setup/resource failures
and an extra packed selection retry are retained in `MERGE-CLOSEOUT.md`, not
counted as ternary acceptance. Only one model was loaded at a time.

Engine regressions: 49 tests /9 suites passed at the tested runtime revision,
including strict canonical tool-cache equality, vision prefill, GDN, legacy
restores and non-Hadamard/explicit-quantized behavior. Engine evidence:
https://github.com/osaurus-ai/vmlx-swift/pull/484#issuecomment-5733290653
Engine advisory formatting was not green; native proof is scoped to the rows
above, not a universal regression, 16GBM4, audio/video or long-context claim.
Osaurus candidate CI35365974786 passed all four required checks; final-repin
head must satisfy its own required checks before ordinary merge.
