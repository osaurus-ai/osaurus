# Settings → runtime parity audit

Running checklist. **Nothing merges without live proof.** A test that calls a
function directly proves it is CORRECT, not that it RUNS — this session has
already shipped two migrations with zero call sites, so reachability is
asserted separately from behaviour everywhere below.

Status key: **FIXED+PROVEN** / **FIXED, unproven live** / **OPEN** /
**UNEXPLAINED** (observed, not understood — never write these off).

---

## A. Disk cache size

| # | item | status |
|---|---|---|
| A1 | Setting is a PERCENT of disk, not GB | FIXED+PROVEN — live label `Disk Cache Size (% of disk)` = 10.0 |
| A2 | One-time reset moves every updating install to 10% | FIXED+PROVEN — live: `maxSizeGB:10` → `maxSizePercent:10`, schemaVersion 3 |
| A3 | `migrateToCurrentSchema()` is actually invoked | FIXED+PROVEN — had **zero call sites**; v2 migration never ran for anyone |
| A4 | Percent reaches `CacheCoordinatorConfig` | FIXED+PROVEN — live `SSD 242.2 GB` |
| A5 | Readout shows the cap the ENGINE enforces | FIXED+PROVEN — host-aware ceiling was over-promised by 130 GB |
| A6 | Chat cache bar shows a real cap, not "Auto" | FIXED+PROVEN — live `DISK CACHE 2.2 GB / 242.1 GB` |
| A7 | Disabled tier renders "Off", never "Auto" | FIXED, unproven live |
| A8 | Small share honoured, not clamped to the 10 GB floor | FIXED+PROVEN — floor now guards auto only |
| A9 | Small share does not silently DISABLE the tier | FIXED, unproven live |
| A10 | Share field keeps precision (`%g`, not `%.1f`) | FIXED+PROVEN — 0.005 was saved as 0 |
| A11 | Eviction enforced at a low share | FIXED+PROVEN — **1638 MB → 408 MB under a 762 MB cap, one store** |
| A12 | Oldest-first eviction ACROSS models | PROVEN (pre-existing test) |
| A13 | Diagnostics report resolved cap, not the stale field | FIXED, unproven live |
| A14 | Eval harness cap not overridden by the share | FIXED, unproven live — every eval would have run at 10% |
| A15 | "Is at defaults" check accounts for the share | FIXED, unproven live |

## B. Context window

| # | item | status |
|---|---|---|
| B1 | Derived per-model from bundle metadata | PROVEN — live `Bundle model maximum 262k · usable budget 85%` → 222k |
| B2 | User cap that actually constrains (`contextLengthCap`) | FIXED, unproven live |
| B3 | Both resolver twins apply it (chip/send-gate AND agent loop) | FIXED, source-asserted |
| B4 | Cap only lowers, never raises past the model | FIXED+tested |
| B5 | Old `contextLength` stays a fallback (128k default must not clamp a 222k model) | FIXED+tested |
| B6 | Agents / subagents / plugin host resolve through the capped path | FIXED, source-asserted |

## C. Multimodal — HIGHEST PRIORITY

| # | item | status |
|---|---|---|
| C1 | Media salt separates same-tokens/different-image | PROVEN (pre-existing) |
| C2 | Salt covers image, video AND audio (+ sample rate) | PROVEN (pre-existing) |
| C3 | **Every** VLM `LMInput` carries `cacheScopeSalt` | **FIXED** — `DeepseekOCRProcessor` was the sole omission; unsalted image path = fluent answer about the WRONG picture |
| C4 | Qwen / Gemma / Zaya / Audex / GLM / FastVLM salted | PROVEN — none appeared in the coverage failure |
| C5 | Live VL multiturn: qwen, muse, gemma — image reuse across turns | **OPEN** |
| C6 | Live VIDEO passthrough + cache | **OPEN** |
| C7 | Live AUDIO passthrough + cache (gemma E2B) | **OPEN** |
| C8 | Media + tools in the same turn | **OPEN** |

## D. Generation config parity

| # | item | status |
|---|---|---|
| D1 | Merge order puts the user's Sampling Defaults ahead of bundle defaults | **FIXED — defect confirmed on three independent signals** (below) |
| D2 | Reasoning-effort enforcement reaches the engine | **OPEN** |
| D3 | Settings changes reach the API-server path, not just chat | FIXED with D1 — one shared call site; save invalidates the cached `RuntimeConfig` |
| D4 | Displayed live stats match what the model actually ran | **OPEN** |

## E. MTP / speculative decoding

| # | item | status |
|---|---|---|
| E1 | Native MTP on/off toggle enforced from Settings | **OPEN** |
| E2 | `canUseNativeMTP` gate agrees with the toggle at all 5 dispatch sites | **OPEN** |
| E3 | dFlash-2 block size + drafter path honoured | **OPEN** |

## F. Prefill

| # | item | status |
|---|---|---|
| F1 | Spawned agents reuse the prefill cache | PROVEN — content-addressed key, no session in it |
| F2 | Chunked prefill GROWS from existing KV, not full rebuild | **OPEN** — the expensive failure mode is a silent full re-prefill |
| F3 | Cold-load time reported separately from TTFT | FIXED; **chip never observed live** — `load_container` measured **0.0 ms** for a 17 GB model (MLX mmaps), so on a healthy host no load overlaps the turn |

## G. Host memory

| # | item | status |
|---|---|---|
| G1 | Advisory when the machine, not the model, is the bottleneck | FIXED, unproven live |
| G2 | Advises, never refuses | asserted — no throw/gate in the path |
| G3 | Trigger is decompression rate + low free, NOT swap % | FIXED+tested — a healthy Mac reads 78% swap |

---

## D1 — Sampling Defaults were inert on almost every model

The Settings → Sampling Defaults panel wrote temperature / top-p / top-k /
min-p / repetition-penalty / max-tokens into `server-runtime.json`, and
`MLXBatchAdapter.effectiveGenerationSettings` then resolved them **behind** the
model bundle's own `generation_config.json`. **83 of 95 bundles** in the local
`~/models` library ship `temperature`/`top_p`/`top_k`, so on nearly every model
the field was editable, persisted, and had no effect on sampling.

Confirmed a defect — not deliberate design — on three independent signals:

1. **The panel's own copy contradicts the behaviour.** Every field reads
   `Blank = model default` and the card says *"Leave blank to honor the
   model's own defaults."* That sentence only means something if a
   **non-blank** field applies.
2. **The first-run migration encodes "non-nil = the user chose it."**
   `initialSettings` writes `topP: nil` unless the legacy `genTopP` differs
   from `ServerConfiguration.default.genTopP` (1.0), commented *"Everything
   else stays nil so model defaults still win."* Distinguishing nil from a
   value is pointless if the value loses either way.
3. **`RuntimeConfig.snapshot()` bridges the legacy value only when it
   deviates**, under the comment *"Honor a legacy `genTopP` override."*
   Honoring it was impossible under the old order.

New order: **per-request → user's Sampling Defaults → model-shipped → vmlx
engine.** Per-request still outranks the user's defaults, so no API client or
agent that sends its own sampler changes behaviour.

Four existing tests failed on the change. They did **not** encode the old
design — each passed the fixture `VMLXServerGenerationDefaults(topP: 1.0)`,
and 1.0 is exactly the legacy default that production writes as `nil`. The
fixture modelled a state the real code path never produces. Corrected to blank
defaults, which is what "when the request is omitted" actually means, and two
tests now pin the contract in both directions:
`effectiveGenerationSettings_userSamplingDefaultsOutrankBundle` and
`effectiveGenerationSettings_requestOutranksUserSamplingDefaults`.
Suite: **86/86 pass.**

**Reachability** (correctness ≠ reachability, per the header):
`effectiveGenerationSettings` has exactly **one** live call site —
`MLXBatchAdapter.generate` (`stage: "submitted_to_batch_engine"`) — reached by
chat, the HTTP API server and agents alike, and it passes
`runtime.generation`. `RuntimeConfig` is cached, and
`ServerController.runtimeConfigInputsRequireInvalidate` compares
`previous.generation != next.generation`, so saving the panel invalidates the
cache and the next request re-reads it. That single shared call site is also
why **D3** (settings reach the API-server path) resolves with D1.

---

## RESOLVED

- **Storage plateau — EXPLAINED, not a defect.** Six live turns added zero
  cache entries while the cache sat below its cap. `VMLX_CACHE_FETCH_TRACE=1`
  shows why:

      [vmlx][cache/disk-store] count=2316 hash=fc4b1f4973e3 salt=0803a8034339
      [vmlx][cache/disk-store] SKIP validated hash=fc4b1f4973e3... bytes=20526264

  The store is SKIPPED because an entry with that exact content hash is
  already on disk and validated. Same hash, same token count, every turn. The
  boundary being offered was already stored — content-hash dedupe working as
  designed. "The cache is storing" is a safe claim; it simply has nothing new
  to store when the stable prefix has not moved.

## Cache-quant / KV-policy isolation — PROVEN live

Same trace, same run:

    policy={cache-policy-v4|promptBoundaryDisk=raw-kv|zaya-typed-tq-min44-v1
            |kvMode=none|kvBits=none|kvGroup=64|qStart=0|maxKV=none}
    scope=reasoning=off  media=nil

KV mode, bit width, group size, rotating-window cap and the serializer
contract version are all folded into the cache key by `cachePolicySalt`. A
TurboQuant-KV or affine-KV entry therefore cannot be restored into a request
running different cache semantics. The reasoning scope (`reasoning=off`) and
media component are carried in the same key.

Useful diagnostic for any future cache question — prints the raw pre-hash
components, which is the only way to see a store/fetch salt mismatch:

    VMLX_CACHE_FETCH_TRACE=1

## Model discovery in ~/models — checked, NOT a defect

Ran the scanner's own predicate (`isModelBundle` + `isLikelyOrganizationContainer`)
across the full library: **99 of 124 discoverable**. Both layouts work; depth-2
org containers descend correctly (JANGQ-AI 36, dealign.ai 23 via the domain-dot
rule, OsaurusAI 10, ornith15-src, gemma4-src, image).

Of the 25 rejects: 22 are `Logs/*` subdirectories, and two are Nemotron
bundles that are genuinely incomplete on disk —
`Nemotron-3.5-Lightning-30B-A3B-JANG_4M` has only config/generation/jang JSON
with **no tokenizer and no weights**, and `NemotronLabs-VoiceChat-11B-MXFP8`
is an **empty directory**. Correctly rejected; they are broken downloads, not
hidden models.

A low-count model list therefore means the models directory in use is not
`~/models` — resolution is `OSU_MODELS_DIR` → saved bookmark → default.

**Fragile heuristic worth revisiting (not changed):**
`isLikelyOrganizationContainer` rejects any directory with 3+ hyphen-separated
parts as an org container, so bundles under e.g. `my-model-collection/` would
be silently invisible. Does not bite the current layout.

## Corrected earlier claim

I said the M3 Max user's 215 s TTFT was explained by "TTFT includes cold model
load". **Measured: `load_container_done` = 0.0 ms for a 17 GB model.** MLX
mmaps weights, so container load cannot produce 215 s on a healthy host. The
real driver is memory pressure — 254 MB free, 13 of 27 GB compressed,
~2.5 GB/s of decompression — which lands in `first_model_output`, not load.
The TTFT split is still correct and worth having; it was not the explanation.

Definitive probe for any slow host:

    OSAURUS_TTFT_TRACE=1 open -a "Osaurus Beta"
    cat /tmp/osaurus_ttft_trace.log
