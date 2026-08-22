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

**Best sustained on Qwen3.8-27B: 27.36 tok/s** — the 39 target is not reachable
on this family. It IS reachable on Qwen3.6-35B-A3B-MXFP4-CRACK-MTP: **44.27
tok/s at depth 3** (below).

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

## Qwen3.6-35B-A3B-MXFP4-CRACK-MTP — the 39 tok/s target IS met here

Same method, same box. All arms byte-identical (952/952):

| depth | tok/s | speedup | active |
|---|---|---|---|
| baseline | 24.40 | — | — |
| 1 | 35.84 | 1.459× | 1/1 |
| 2 | 40.61 | 1.664× | 2/2 |
| **3** | **44.27** | **1.814×** | 2/3, commit 2.51 |
| 4 | 44.14 | 1.809× | 2/3 — converges to d3 |

**44.27 tok/s, comfortably above 39.** Note d3 settles at active depth 2 yet
beats *requesting* 2 directly (40.61, commit 2.21): the higher request drafts
more before settling. d4 converges to the same active depth, so 3 is the
ceiling.

**This bundle's depth profile is the OPPOSITE of Qwen3.8-27B's.** There, depth
1 is the only depth that pays and true depth 3 measured 0.951× — slower than
plain decode. Here depth 3 is worth 1.814×. **Depth is per-bundle and must not
be generalised across families**, which is the same over-generalisation trap as
inferring library-wide template behaviour from four files.

One stamping detail that cost a cycle: the first stamp declared
`model_types: ["qwen3_5"]` while the bundle's `config.json` says
`qwen3_5_moe`. `tuningMatchesBundleModelTypes` rejected it, and the probe
reported `usableBestDepth=Optional(3)` alongside `NO MTP` — usable tuning, still
refused. Worth knowing: a usable depth is not sufficient; model type and
quantization must match the bundle too.

## Not covered

Eight bundles still ship MTP off because they carry **no** tuning file at all —
4× Ornith-1.5-35B-A3B, 3× Nemotron-3.5-Lightning-30B-A3B, `ornith15-src`. None
are Qwen. Each needs its own sweep; none can inherit a number from a sibling.

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


## The 44.27 figure is SHORT-CONTEXT, and SSD caching is not the overhead

Eric's read was that no-SSD-caching sustains 40+ and therefore the disk cache
costs the difference. Measured with cache as an explicit control — same bundle,
same depth, quiet box (85% idle, 69 GB free):

| context | cache | baseline | d3 | speedup |
|---|---|---|---|---|
| short (~56 tok) | none | 24.61 | 44.58 | 1.811× |
| short | paged | 24.41 | 44.24 | 1.812× |
| short | disk | 24.43 | 44.23 | 1.811× |
| **long (~3k tok)** | none | 22.40 | **23.22** | **1.036×** |
| **long** | disk | 22.30 | **23.35** | **1.047×** |

**Caching is free.** None vs disk is within noise at both depths, and the
post-answer store is 27 ms for 124 MB at 56 tokens and 31 ms for 190 MB at
2995 tokens (~6 GB/s), `SKIP validated` on every store after the first. That
also retires the worry raised by DiskCache's own note about a ~357 MB boundary
taking ~25 s — not reproducible here.

**Context depth is the real variable.** MTP's speedup falls from 1.81× to
1.04× between a short prompt and 3k tokens. Notably depth 3 *holds* at long
context (`active=3/3, downshifts=0, commit=2.38`) where it demoted at short
context — so this is not the adaptive controller giving up. Verify cost grows
with context faster than acceptance pays for it.

**Consequence for what gets shipped:** `best_tok_s` in a tuning artifact is a
short-prompt figure by construction, and must not be read as sustained
throughput. The artifacts now say so in their own `note`.

One condition that had been unstated until now: a bare `ModelContext` has no
cache coordinator at all (`enableDiskCache` defaults false; the coordinator
lives on `ModelContainer`), so every number measured before the cache axis
existed was a no-cache number.
