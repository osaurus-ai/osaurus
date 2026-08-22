# Qwen3.8-27B native MTP: measured depth-1 enablement

**Before:** of 15 local bundles carrying a complete MTP artifact, exactly **1**
launched speculation, and it launched at depth 3.
**After:** all **6** Qwen3.8-27B bundles launch at **depth 1**, each on its own
measurement.

Verified with the real `MTPBundleInspector` + `NativeMTPAutoDecodePolicy`, not
by reading the JSON.

## Measured matrix

M5 Max 128 GB, settled, no paging (free logged before every leg). ABAB
interleaved, 3 rounds, round 1 discarded as cold, median of the rest, staged
verify, temp 0, 256 tokens, code prompt. Every arm byte-identical to baseline.

| bundle | baseline | depth 1 | speedup | downshifts |
|---|---|---|---|---|
| JANGQ-AI/…JANG_2D | 19.87 | **26.16** | 1.316× | 0 |
| JANGQ-AI/…JANG_4D | 17.46 | **21.88** | 1.253× | 0 |
| JANGQ-AI/…JANG_6D | 14.33 | **18.29** | 1.276× | 0 |
| dealign.ai/…JANG_2D-CRACK | 19.85 | **27.36** | 1.378× | 0 |
| dealign.ai/…JANG_4D-CRACK | 17.39 | **23.54** | 1.354× | 0 |
| dealign.ai/…JANG_6D-CRACK | 14.38 | **20.31** | 1.412× | 0 |

**Best sustained: 27.36 tok/s.** The 39 tok/s target is NOT met — the gap is
~30%, and 39 has never been measured on this family.

## Why nothing was launching

Two independent causes, both silent.

1. **Shape mismatch.** PR #278's sweep writes the measurement nested under
   `native_mtp`; `stamp_qwen38_27b` writes the same keys flat. Only nested
   decoded, so a flat file was indistinguishable from no file — including to
   `rejectionReason`, which sent readers after the wrong thing. Fixed: the
   loader now accepts both, nested first.
2. **The stamps were unmeasured**, and said so: *"Conservative UNMEASURED
   default: 1 draft/step. Run a depth sweep."* `usableBestDepth` correctly
   refuses those. Fixed by measuring, not by filling in fields.

## Depth 1 is not a preference — it is the only depth that pays

A depth-3 request does not run at depth 3. The adaptive controller demotes
3→2→1 on acceptance and lands at 18.50–18.66 on JANG_4D.

Forcing **true** depth 3 (by widening the demote grace window) measured
**16.58 tok/s = 0.951×, slower than plain decode.** So the demotion is
correct, and the grace-window change was reverted rather than shipped. This is
worth stating plainly: a plausible "cold cache under-reads acceptance" story
produced a change that would have made users slower, and only measuring the
forced case caught it.

The 2026-08-19 row claiming depth 3 at 25.1 tok/s / 1.43× does not reproduce.
The control rules out the machine: baseline was 17.5 then and 17.46 now, 0.2%
apart. Today's commit-per-verify at "depth 3" is 1.92 — which is that same
note's **depth-one** figure (1.88).

## Content dependence is large

Same bundle (JANG_2D), same everything else:

- code: d1 26.16, **1.316×**
- prose: d1 19.12, **1.068×**, and d3 **diverged** from baseline (672/1240)

Prose is the conservative floor. A single-prompt-class measurement would
misstate this by ~25 points of speedup, which is how a 1.83× MTP figure once
got published off a counting prompt.

## Not covered

Nine bundles still ship MTP off because they carry **no** tuning file at all —
4× Ornith-1.5-35B-A3B, 3× Nemotron-3.5-Lightning-30B-A3B,
`Qwen3.6-35B-A3B-MXFP4-CRACK-MTP`, `ornith15-src`. Each needs its own sweep;
none can inherit a number from a sibling.

## Reproducing

    VMLX_NATIVE_MTP=1 VMLX_MTP_TUNING_MEASUREMENT=1 \
    VMLX_MTP_SWEEP_VERIFIER=input_capture_staged \
    VMLX_MTP_SWEEP_PROMPT=code \
    VMLX_MTP_SWEEP_TARGET=~/models/JANGQ-AI/Qwen3.8-27B-JANG_2D \
    VMLX_MTP_SWEEP_DEPTHS=1,2,3 VMLX_MTP_SWEEP_ROUNDS=4 \
    swift test --filter QwenNativeMTPDepthSweepTests

`VMLX_MTP_TUNING_MEASUREMENT` is required: the load gate refuses native MTP
without usable tuning, and tuning can only come from running the head.

Every previous artifact is preserved alongside as `vmlx_mtp_tuning.json.bak`.
