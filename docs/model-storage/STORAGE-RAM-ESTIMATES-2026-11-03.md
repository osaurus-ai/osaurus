# Model storage and RAM estimate hardening

Status: implementation in progress; runtime/UI qualification and merge pending.
No release tagging is part of this work.

## Contract

Download bytes count the files selected by the existing download manifest, including
SSD-backed tables and bundled drafters. Installed weight bytes come from actual
root-level safetensors file sizes, following directory/shard symlinks. The index's
`metadata.total_size` is a fallback when no weight files are available; it must
not override real files after conversion.

Resident-weight estimates subtract only tensor spans matching the runtime's
`.ple.ngram_embedding.` storage contract. Discovery inspects indexes/headers,
not architecture tags, product names or JANG precision labels. Native MTP,
vision and ordinary compute weights remain counted. This is not a promise that
all future architectures use this marker: a new storage contract requires a
corresponding runtime and estimator implementation before bytes can be excluded.

Remote inspections pin shard reads to the index's Hub commit when supplied.
Ranges require an exact 206 response and known complete file length; tensor
spans must be nonnegative, inside the payload and nonoverlapping. Invalid,
unavailable or inconsistent metadata does not create a cached false zero.
Indexed and standard `model.safetensors` single-file bundles are supported.
The versioned table cache invalidates previous less-strict measurements.

The catalog publishes sizes before bounded background table inspections finish.
Cold/offline mixed JANG/JANGH/JANGHT entries remain unknown until measured;
precision labels do not imply an exact four-bit byte count. Plain parameter
fallbacks use decimal billions. RAM projections retain the existing advisory
runtime allowance and GPU budget; they are not measured physical footprint,
context-sized KV estimates, or a guarantee of machine/model fit. File caching,
context and optional draft loading can change actual RAM use.

Installed bundle facts take precedence over unrelated Hub measurements, including
when the local table cannot be validated. The detail sheet, cards, onboarding,
filters and handoff estimates consume the shared model assessment.

## Source and validation

Base main: `13a7b1719c06128043586e8be095026f604eaf0a`.

Private evidence: `/Users/eric/vmlx-private-evidence/model-storage-residency-20261103/`.
Original inventories and failed attempts are retained.

Header/file inventory on erics-m5-max2 (decimal bytes):

| Installed bundle | Weight files | SSD table | Resident weight files |
| --- | ---: | ---: | ---: |
| Qwen Flash-Next JANG_2L | 70,158,268,772 | 20,800,099,840 | 49,358,168,932 |
| Qwen Flash-Next JANGH4 | 134,825,034,712 | 57,600,276,480 | 77,224,758,232 |
| Allosaurus v0.1 JANGH2 | 94,572,434,104 | 57,600,276,480 | 36,972,157,624 |
| Allosaurus v0.2 JANGHT1.8 | 86,438,394,488 | 57,600,276,480 | 28,838,118,008 |
| DeepSeek V4.1 JANGHT1.4 | 98,965,578,032 | 0 | 98,965,578,032 |
| GLM 5.3 Flash JANGHT2.4 | 98,320,846,968 | 0 | 98,320,846,968 |

These are file/header measurements, not generation or physical-footprint proof.
Public Hub index probes confirm the table inventory distinction for both
Allosaurus bundles and no matching tables for DeepSeek/GLM. The private Qwen
Hub probe returned HTTP 401; local Qwen file/header evidence remains available.

## Remaining proof and order

1. Finish focused tests for malformed/overlapping/out-of-bounds metadata,
   revision/range behavior, single-file discovery, precision/grouping, local
   symlinks and installed-versus-Hub precedence.
2. Build a fresh isolated Release app. Inspect actual catalog/detail controls
   against measured inventories, including a table-free model and a mixed format.
   Check refresh/reopen behavior and keep source/app receipts.
3. Scoped commit, PR, CI, normal merge; update this document and private wiki
   with exact results. Do not call this hardened or merged before those receipts.
4. Only then audit past Osaurus cache/terminal-wait/SSD/native-MTP/DSpark/DFlash2
   evidence against current model bundles and pins. Preserve accepted evidence,
   fix concrete failures, qualify affected multi-turn/tool/cache paths, and merge
   proven fixes. No release tags.
