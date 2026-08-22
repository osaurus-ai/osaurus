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
| A16 | A store too big for the cap does not wipe the cache | FIXED in vmlx (#293) — MEASURED 2 entries → 0; **not on the shipping path**, see below |

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
| C5 | VL multiturn: image reuse across turns | CHARACTERIZED — resumes for text follow-ups; a media-INTRODUCING turn re-prefills (below) |
| C6 | Live VIDEO passthrough + cache | **OPEN** (video EVS additionally needs a post-prepare cache key) |
| C7 | Live AUDIO passthrough + cache (gemma E2B) | CHARACTERIZED with C5 — audio rides the same two mechanisms |
| C8 | Media + tools in the same turn | **OPEN** |
| C9 | Best prefix/suffix match block for multimodal | **DIAGNOSED, NOT FIXED** — the suffix rollback is the binding constraint, not the salt |

## D. Generation config parity

| # | item | status |
|---|---|---|
| D1 | Merge order puts the user's Sampling Defaults ahead of bundle defaults | **FIXED — defect confirmed on three independent signals** (below) |
| D2 | Reasoning-effort enforcement reaches the engine | PROVEN — `request.reasoning_effort` → `modelOptions["reasoningEffort"]` → `context["reasoning_effort"]` → the bundle's chat template, and the same context feeds `cacheScopeSalt` |
| D2b | Cost of changing reasoning effort mid-conversation | ANSWERED — a full re-prefill, and **unavoidable by cache work** (below) |
| D3 | Settings changes reach the API-server path, not just chat | FIXED with D1 — one shared call site; save invalidates the cached `RuntimeConfig` |
| D4 | Displayed live stats match what the model actually ran | **FIXED** — the effective sampler had NO GUI surface at all; added "Sampler last used" to Live Activity |

## E. MTP / speculative decoding

| # | item | status |
|---|---|---|
| E1 | Native MTP on/off toggle enforced from Settings | PROVEN — `resolvedMTPLaunch` returns `.off` on `mtp.mode == .off`; the toggle is REACHED because `loadedModelRuntimeInputsRequireRefresh` sees `previous.mtp != next.mtp` and unloads, so the next load re-plans (test: `loadedModelRefreshInputs_coverCacheMemorySafetyMultimodalMTPAndLoadPerformance`) |
| E2 | The MTP gate agrees with the toggle at every dispatch site | PROVEN — no `canUseNativeMTP` symbol survives; one planner (`resolveNativeMTPLaunchPlan`) writes `holder.draftStrategy` at load, and both readers take it from the holder. `DFlash2DispatchReachabilityTests` asserts the dispatch sites and their ORDER at source level |
| E3 | dFlash-2 block size + drafter path honoured | PROVEN — `resolvedMTPDraftStrategy` passes `mtp.dflash2BlockSize`; `DFlash2DrafterSelectionTests` covers selection, mismatch rejection, and round-trip |
| E4 | A selected dFlash-2 drafter drafts even with Mode = Off | BY DESIGN, disclosed at the control: *"A selected DFlash 2 drafter drafts regardless of Mode — remove it below to stop."* Pinned by `DFlash2DrafterSelectionTests` (mode `.off` + drafter → `.dflash2`) |

## F. Prefill

| # | item | status |
|---|---|---|
| F1 | Spawned agents reuse the prefill cache | PROVEN — content-addressed key, no session in it |
| F2 | Chunked prefill GROWS from existing KV, not full rebuild | PROVEN for text — longest-boundary probe returns `remainingTokens`, prefill resumes from there. Media-introducing turns are the exception (C9) |
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

## A16 — A store too big for the cap took the whole cache with it

Chasing "proper SSD cache write usage at a ridiculously low percent". Measured
on the real `DiskCache`: two 70 KB entries under a 300 KB cap, then one 430 KB
store — `currentEntryCount` went **2 → 0**.

The store writes the payload, indexes it, then runs the quota pass, which
evicts oldest-first until the total is back under the cap. For one entry `E`
larger than the cap `C` with `others` resident, `excess = others + E - C`.
Evicting every other entry accumulates only `others`, and `others < excess`
exactly when `E > C` — so the loop continued and evicted `E` too. The oversized
file was written to the SSD and immediately deleted, **and** every previously
cached boundary went with it.

Fixed in vmlx #293 by deciding on the **measured** file size (not an `nbytes`
estimate, which could drop a store that would have fit after quantization) and
dropping only that file.

**Reachability — this is NOT on the shipping path, and saying otherwise would
be an overclaim.** `CacheCoordinator` passes `enforceQuota:
!usesCombinedQuota`, and `usesCombinedQuota = config.enableDiskCache`, so
whenever the disk cache is on the *combined* pass owns the quota — and that
path already refuses an oversized newest boundary while keeping the prior
fitting prefix (`combinedQuotaRejectsOversizedNewestBoundaryButPreservesPriorFittingPrefix`,
passing). What #293 closes is the public `store(tokens:arrays:mediaSalt:)`
surface, which enforces `DiskCache`'s own quota and had no such protection.
Real and measured, but defense in depth.

## D2b — Changing reasoning effort mid-conversation costs a full re-prefill

Asked because a mid-conversation effort change looked like it might be
throwing away the cached prefix unnecessarily. **It is a full re-prefill, and
no cache change can avoid it** — the prompt itself diverges at the front.

Checked against the real bundles rather than reasoned about: 8 templates in
`~/models` consume `reasoning_effort`, and every one renders it into the
**system message, before anything else**.

- `dealign.ai/Step-3.7-Flash-JANG_K-CRACK`: `<|im_start|>system\n` then
  immediately `"Reasoning: " + reasoning_effort` — the first tokens after BOS.
- `JANGQ-AI/Qwen3.8-27B-JANG_{2D,4D,6D}`: `reasoning_instructions` resolves
  from `resolved_reasoning_effort` and is emitted as the first content of the
  system block, ahead of the tools block.

So a new effort changes tokens at roughly position 5–30. **No shared prefix
exists at the token level**, and the cache is content-addressed by tokens — the
re-prefill is caused by prompt construction, not by cache policy.

This also settles whether `cacheScopeSalt`'s `effort=<value>` component is
costing reuse: it is not. The tokens have already diverged everywhere it
applies, and the salt still earns its keep for any template that consumes
`reasoning_effort` **without** rendering it, where tokens would be identical
but KV semantics differ. Leave it alone.

Practical consequence to tell users: switching effort mid-chat re-prefills the
whole conversation once. Switching it between conversations costs nothing.

## D4 — Nothing in the GUI showed the sampler that actually ran

`MLXBatchAdapter.effectiveGenerationSettings` resolves per-request over the
user's Sampling Defaults over the bundle's shipped defaults, and the result was
recorded — but the only reader was the **HTTP admin endpoint**
(`last_effective_generation`). No GUI surface existed. The Settings panel
showed what had been *requested*; nothing showed what *ran*.

That is exactly how D1 stayed invisible: the field was editable, saved, and
inert, and there was no readout that would have disagreed with it.

Added **"Sampler last used"** to the Live Activity card, refreshed on the same
2-second timer, sourced from `lastEffectiveGenerationSettingsSnapshot()` —
per model, no HTTP involved:

    JANGQ-AI/Qwen3.8-27B-JANG_2D
    temp 0.7 · top-p 0.95 · top-k 20 · min-p 0.01 · max 4096 · rep 1.05

Two details that are load-bearing rather than cosmetic:

- Formatted with `%g`, not `%.1f`. A `%.1f` share field already rewrote 0.005
  to 0 once this session; a readout that rounds is a readout that lies.
- Temperature 0 appends `(greedy — top-p/top-k/min-p inert)`. An agent stored
  with `temperature: 0` otherwise reads as correctly configured while decoding
  argmax — the mechanism behind the DSV4 verbatim reasoning loop.

Warm-up prefills are excluded upstream by
`shouldRecordAsLastEffectiveGeneration`, so the row always describes a real
turn rather than the `temperature: 0, maxTokens: 1` housekeeping request that
follows one. Tests: `EffectiveSamplerReadoutTests` (5).

## C9 — What a growing VL conversation can actually reuse

**Diagnosed, deliberately NOT fixed this pass.** Stating the property, because
"multimodal caching is broken" and "multimodal caching is fine" are both wrong.

Two independent mechanisms decide reuse, and they have to be read together:

1. **`computeMediaSalt` fingerprints the whole concatenated pixel tensor.**
   `ProcessedImage.pixels` is documented as *"Concatenated pixels from one or
   more images"*, so appending an image changes the salt for the **entire**
   prompt. `CacheCoordinator` passes that salt to `DiskCache.fetch` on every
   candidate boundary probe, so no boundary stored by an earlier turn can
   match.
2. **A hit whose remaining SUFFIX still holds media placeholders is rolled
   back to a full prefill** — `cacheHitSuffixContainsMediaPlaceholder`, applied
   in all four decode paths (`Evaluate`, `BatchEngine`,
   `DFlash2TokenIterator`, `NativeMTPTokenIterator`). This is a real
   correctness requirement, not caution: media embeddings are substituted onto
   placeholder positions **by order across the whole prompt**, so prefilling
   only a suffix would map the wrong image onto them.

Per-turn consequence:

| turn shape | reuses? | why |
|---|---|---|
| text follow-up after an image turn | **yes** | same tensor → same salt; suffix is text-only |
| turn that ADDS an image / video / audio | **no** | salt changed AND the suffix carries the new placeholders |
| text turn after a media-introducing turn | **yes** | tensor matches the previous turn again |

So the cost is **per media-introducing turn**, not cumulative — but a chat that
varies modality every turn introduces media every turn and therefore never
resumes, re-running the vision tower over all prior images each time. That is
the long-context degradation to expect, and it is the shape worth optimizing.

**Finding that prevents wasted work:** mechanism 2 is the binding constraint.
Prefix-scoped salting on its own buys **nothing** — every case it would unlock
is still rejected by the suffix rollback, including the "text-only prefix
stored before any media existed" case, because the suffix from that boundary
still contains the new placeholders. Any real fix has to thread a
*media-consumed offset* into each VLM's `prepare` so the suffix substitutes
starting at image K, and only then is prefix-scoped salting worth adding. That
touches every VLM model file and cannot be proven without live VL turns, so it
is not being half-shipped here.

Pinned as characterization — assertions about today's behaviour, which SHOULD
change deliberately when the above lands:
`Tests/MLXLMCommonFocusedTests/VLGrowingConversationReuseTests.swift` (5 tests,
including a boundary landing *inside* a placeholder run, which is the media
analogue of the non-aligned-size rule).

Live confirmation without driving turns — the rollback announces itself:

    Slot N: cache hit — rolling back to full prefill
            (media placeholder tokens remain in cache-hit suffix)

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
