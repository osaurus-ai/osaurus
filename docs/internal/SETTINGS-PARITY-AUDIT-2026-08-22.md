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
| A7 | Disabled tier renders "Off", never "Auto" | **WAS UNREACHABLE — now FIXED+PROVEN LIVE**; a user-disabled tier made the whole row VANISH rather than render "Off" (below). Live: `DISK CACHE  0 MB · Off` |
| A8 | Small share honoured, not clamped to the 10 GB floor | FIXED+PROVEN — floor now guards auto only |
| A9 | Small share does not silently DISABLE the tier | **FIXED+PROVEN LIVE** — 0.005% → `0.005% of 3721.8 GB ≈ 191 MB`, chat reads `DISK CACHE 0 MB / 191 MB` (a real cap, not "Off", not "Auto") |
| A10 | Share field keeps precision (`%g`, not `%.1f`) | FIXED+PROVEN — 0.005 was saved as 0 |
| A11 | Eviction enforced at a low share | FIXED+PROVEN — **1638 MB → 408 MB under a 762 MB cap, one store** |
| A12 | Oldest-first eviction ACROSS models | PROVEN (pre-existing test) |
| A13 | Diagnostics report resolved cap, not the stale field | FIXED; **NOT visually provable** — the payload is HTTP-only (`HTTPHandler` `block_disk_max_size_gb`) with no GUI surface, and curl is banned. It calls the same `resolveDiskCacheMaxGB` proven live at two shares below, so the figure is verified; the endpoint itself is not |
| A14 | Eval harness cap not overridden by the share | FIXED, unproven live — every eval would have run at 10% |
| A15 | "Is at defaults" check accounts for the share | **FIXED+PROVEN LIVE** — 0.002% survived a full quit/relaunch (shipped default is 10%), field reads back `0.002` → `≈ 76 MB`; the defaults migration did not overwrite a deliberate share |
| A16 | A store too big for the cap does not wipe the cache | FIXED in vmlx (#293) — MEASURED 2 entries → 0; **not on the shipping path**, see below |

## B. Context window

| # | item | status |
|---|---|---|
| B1 | Derived per-model from bundle metadata | PROVEN — live `Bundle model maximum 262k · usable budget 85%` → 222k |
| B2 | User cap that actually constrains (`contextLengthCap`) | **WAS UNREACHABLE — now wired**; the field existed and both resolvers read it, but NO Settings control ever wrote it, so the user could not set it. Added "Context Window Cap (tokens)" to Server → Cache → Context & KV Policy (below) |
| B3 | Both resolver twins apply it (chip/send-gate AND agent loop) | **chip/send-gate twin PROVEN LIVE** — the 108k ↔ 7.0k transition in B2 came through `resolveContextWindowResolutionSync`, which is that twin; the agent-loop twin (`resolveContextWindow`) stays source-asserted |
| B4 | Cap only lowers, never raises past the model | FIXED+tested |
| B5 | Old `contextLength` stays a fallback (128k default must not clamp a 222k model) | FIXED+tested |
| B6 | Agents / subagents / plugin host resolve through the capped path | FIXED, source-asserted |

### A7 — the "Off" state was built and then never rendered

`DiskCacheUsage.headlineLabel` has a dedicated branch returning `"<used> · Off"`,
and `isDisabled` exists specifically so a switched-off tier is not mislabelled
"Auto". Both were correct. Neither ran when the USER switched the tier off.

Two things stood between them:

```swift
guard let settings = ServerRuntimeSettingsStore.load(),
    settings.cache.blockDisk.enabled          // <-- user's toggle
else { return nil }                            //     -> no row at all
```

and the section gate `if let diskCache, diskCache.usedBytes > 0 || maxBytes > 0`,
which a disabled tier fails anyway because its cap is 0. `isDisabled` was only
ever set from `hostAwareDiskCacheDecision` — the disk-nearly-full path — so the
"Off" label was reachable only when the HOST disabled the tier, never when the
person did.

Observed live before the fix: unticking Disk Cache made the DISK CACHE row
disappear from the Context Budget popover entirely (popover 442px → 397px).
Never "Auto", so the letter of A7 held — but the row said nothing at all, which
is the failure the comment directly above that guard already warns about for an
idle chat ("reads as the feature being missing rather than merely unmeasured").

Fixed by returning a `DiskCacheUsage(isDisabled: true)` instead of nil, and
letting `isDisabled` pass the section gate on its own.

**Live proof**, tier unticked in Settings → Save → `server-runtime.json` reads
`blockDisk.enabled = false` → Context Budget popover renders:

```
DISK CACHE                    0 MB · Off
```

### A9 / A11 — small share, and eviction actually enforced at it

Same session, `Qwen3 0.6B 8bit`, share driven from the Settings field:

| share | Settings resolves | chat readout |
|---|---|---|
| 0.005% | `0.005% of 3721.8 GB ≈ 191 MB` | `DISK CACHE 0 MB / 191 MB` |
| 0.002% | `0.002% of 3721.8 GB ≈ 76 MB` | `DISK CACHE 0 MB / 76 MB` |

A9 holds: a share three orders of magnitude below the default resolves to a
real cap and the tier stays live. It is not clamped up to the old 10 GB floor
(A8) and `0.005` survives round-tripping rather than rendering as `0.0` (A10).

**Eviction (A11), re-measured today rather than inherited.** Eight turns grew
the tier to only 116 MB in 5 files — nowhere near the 191 MB cap, so that run
did NOT exercise eviction and is not evidence about it. Instead of loading a
larger model on a host that kernel-panicked this morning, the cap was lowered
*below* the existing cache and one ordinary turn was sent to trigger a store:

```
before:  116 MB in 5 files      cap 191 MB
cap ->   76 MB
after:     1 MB in 4 files      cap  76 MB
```

The tier is genuinely bounded by the share — it does not ignore the cap. Note
the overshoot: getting under 76 MB needed roughly two of the five entries
dropped, and it fell to 1 MB. Enforcement is the safe direction, so this is
recorded as measured rather than called a defect; whether oldest-first evicts
more than necessary needs its own run with entry-level accounting.

**Harness note, because it nearly produced a false result.** A first eviction
attempt reported the cache flat at 114 MB across four turns, which looked like
"writes are being suppressed". The transcript was empty — `key code 36` had
gone to whichever window was key, not the chat. A second attempt then reported
"turn did not send" on turns that HAD sent, because sent bubbles and model
replies are also `AXTextArea`s and the probe grabbed a transcript bubble rather
than the composer. Both directions of lie, from the same harness, within
minutes. `sendturn.sh` now presses the send button, picks the bottom-most text
area, and fails loudly unless the composer actually clears.

### Settings search could not find the cache section by any name it displays

Same class as D5, found while proving A7: `0 settings match "disk cache"`. The
`server.cache` entry is titled "Prompt Cache" with keywords
`["cache", "kv cache", "prefix"]`, while every control inside it reads "Disk
Cache", "SSD Cache (L2)", "Disk Cache Size (% of disk)" or "Clear SSD Cache".
None resolved.

The existing self-find probe could not catch this: it sweeps each entry's own
`title` and `section`, and "Prompt Cache" resolves fine. An entry can be
self-findable and still unreachable by every word actually on screen. Added
`controlsFindableByOnScreenLabel`, which pins the control labels the sweeps
structurally cannot see — verified to FAIL without the keyword fix, naming all
five missing labels, and pass with it.

Live: `0 settings match "disk cache"` → **`1 setting matches "disk cache"`**.

### B2 — the cap existed, was read, and had no way to be set

`contextLengthCap` was already correct on the runtime side: both resolver twins
in `AgentToolLoop` apply it — the async `resolveContextWindow` and the
`@MainActor resolveContextWindowResolutionSync` that the doc comment names as
"the context chip and send gate" — each through `applyingUserCap(_:cap:)`. B3
and B6 were right.

What was missing is that **nothing in Settings ever wrote the field.** The only
context control in Server → Cache bound `contextLength`, and that one is a
FALLBACK whose own doc comment says it "cannot constrain anything: a user who
lowered it saw no change on any local model, since bundle metadata is consulted
first and wins." So a user who wanted a smaller window had no way to ask for
one. Same class as the two migrations with zero call sites: correct code that
is never reached.

Added `Context Window Cap (tokens)` to Server → Cache → Context & KV Policy,
threaded through `ServerSettingsTabContent` exactly like the fallback twin
(draft/saved state, `hasUnsavedChanges`, load, save, `resetToDefaults`), plus a
`Saved context window cap` readout and search keywords.

**Live proof — driven through the running app, one model, one session, only the
cap varying.** Model `Qwen3 0.6B 8bit`:

| cap set in Settings | chat chip | Context Budget popover | `chat.json` on disk |
|---|---|---|---|
| blank | `~2.5k / 108k` | — | `contextLengthCap: null` |
| **8192** | `~2.5k / 7.0k` | **`Your context limit 8.2k · usable budget 85%`** | `contextLengthCap: 8192` |
| blank again | `~2.5k / 108k` | — | `contextLengthCap: null` |
| **8192 again** | `~2.5k / 7.0k` | | `contextLengthCap: 8192` |

7.0k is 8192 × 0.85, the declared safety margin. It reverts and re-applies, so
it tracks the setting rather than having landed there once by accident.

Discoverability, same query on two builds differing only in the search-index
entry: `0 settings match "max context"` → **`1 setting matches "max context"`**,
resolving to Server → Cache → Context & KV Policy.

Three varying turns under the cap, all correct, cap held at 7.0k throughout:

| turn | shape | answer | TTFT | tok/s |
|---|---|---|---|---|
| 1 | list | `red, blue, yellow` | 0.42s | 366.1 |
| 2 | arithmetic | `144` | 0.13s | 398.8 |
| 3 | recall turn 1 | `red, blue, yellow` | 0.14s | 377.6 |

Turn 3 recovers turn 1's answer, so conversation carryover survives the cap
rather than the cap silently truncating history. TTFT falling 0.42 → 0.13 after
the first turn is prefix reuse engaging, and the disk tier grew live during the
run (`DISK CACHE 3.7 GB / 262.3 GB` in the same popover — which also re-proves
A6's real-cap readout).

Free RAM before this run: **84.3 GB**. Recorded per the rule added under C9.

## C. Multimodal — HIGHEST PRIORITY

| # | item | status |
|---|---|---|
| C1 | Media salt separates same-tokens/different-image | PROVEN (pre-existing) |
| C2 | Salt covers image, video AND audio (+ sample rate) | PROVEN (pre-existing) |
| C3 | **Every** VLM `LMInput` carries `cacheScopeSalt` | **FIXED** — `DeepseekOCRProcessor` was the sole omission; unsalted image path = fluent answer about the WRONG picture |
| C4 | Qwen / Gemma / Zaya / Audex / GLM / FastVLM salted | PROVEN — none appeared in the coverage failure |
| C5 | VL multiturn: image reuse across turns | CHARACTERIZED — resumes for text follow-ups; a media-INTRODUCING turn re-prefills (below) |
| C6 | Live VIDEO passthrough + cache | **PASSTHROUGH PROVEN LIVE** — clip read as `7, 3, 5, 9` in order (twice), and vMLX genuinely frame-samples it (`AVAssetImageGenerator`, zero tolerance) into a temporal patch grid. The model's "I can't watch video" was confabulation, not evidence (below). Video *cache* reuse still untouched |
| C7 | Live AUDIO passthrough + cache (gemma E2B) | **UNTESTABLE ON THIS HOST** — no installed bundle contains `embed_audio.embedding_projection`; `~/models`, `~/models/JANGQ-AI` and the whole HF cache return zero matches, so no audio turn can be run. Needs an E2B/E4B fetched first. An earlier "defect" claim here was withdrawn (below) |
| C8 | Media + tools in the same turn | **PROVEN LIVE in a clean conversation** — image + tool answered correctly in one turn. But a NEW image after a PRIOR media turn was ignored and the model described the OLD media (below) |
| C9 | Best prefix/suffix match block for multimodal | **FIXED+PROVEN LIVE for the Qwen VL families** — follow-up TTFT 3.40s → 0.59s median, A/B against the baseline vmlx pin (below). Other families still unreached |

## D. Generation config parity

| # | item | status |
|---|---|---|
| D1 | Merge order puts the user's Sampling Defaults ahead of bundle defaults | **FIXED+PROVEN LIVE** — drove the real app, two turns; readout went `temp 0.6 · top-k 0` → `temp 0.23 · top-k 7` (below) |
| D2 | Reasoning-effort enforcement reaches the engine | PROVEN — `request.reasoning_effort` → `modelOptions["reasoningEffort"]` → `context["reasoning_effort"]` → the bundle's chat template, and the same context feeds `cacheScopeSalt` |
| D2b | Cost of changing reasoning effort mid-conversation | **CORRECTED — my first answer was wrong and backwards.** Only 2 of 97 templates render `reasoning_effort`; for the rest the tokens are identical and the `effort=` salt discards reuse for nothing (below) |
| D3 | Settings changes reach the API-server path, not just chat | FIXED with D1 — one shared call site; save invalidates the cached `RuntimeConfig` |
| D4 | Displayed live stats match what the model actually ran | **FIXED+PROVEN LIVE** — the effective sampler had NO GUI surface at all; added "Sampler last used" to Live Activity, read back off the running app |
| D5 | The row is discoverable from Settings search | **FIXED+PROVEN LIVE** — `0 settings match "sampler"` → `2 settings match "sampler"`, and the result navigates to Sampling Defaults (below) |

## H. Tool permissions — "enabled" is not "allowed"

| # | item | status |
|---|---|---|
| H1 | Every shipped tool is enabled | PROVEN — 83/83 `enabled: true` |
| H2 | An enabled tool runs without prompting | **NO — and this is the popup** |
| H3 | A bulk control exists to allow everything | **NO — none anywhere** |
| H4 | A headless test process cannot hang on the prompt | FIXED — `ToolPermissionPromptService` returns `.denied` under `RuntimeEnvironment.isUnderTests` at all three entry points |

`ToolConfiguration.policy(for:)` returns **`.ask`** when a tool has no explicit
policy, and `enabled` is a separate map. So a config with all 83 tools enabled
and `"policy": {}` — which is the shipped starting state — prompts on first use
of every one of them. That is the modal reported as *"dude what the fuck is
this close this shit i cant even click or quit it"*: not a stuck window so much
as 83 of them waiting in line.

The controls that do exist are per-tool Auto / Ask / Deny pickers
(`ToolCatalogRows`, `ChatSettingsView`). The only bulk action is
`resetAllToDefault()`, which iterates `Self.folderTools` — a subset — and
resets them to `.ask`, i.e. it moves *toward* prompting, never away. There is
no "allow all", so clearing the prompts means 83 individual picker changes or
83 trips through the modal.

Not fixed here: a one-click "allow everything" is a security-posture control,
and adding one to a shipped app is a product decision rather than an audit
finding. Recorded so it can be decided deliberately. For proof runs the
equivalent is written directly into the isolated root:

    python3 - <<'EOF'
    import json; p = "<root>/config/tools.json"
    d = json.load(open(p))
    d["policy"] = {n: "auto" for n in d.get("enabled", {})}
    json.dump(d, open(p, "w"), indent=2, sort_keys=True)
    EOF

Related and separate: a *keychain* prompt can also block the UI, and denying it
does not help — see the SecurityAgent note under D5.

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
| G1 | Advisory when the machine, not the model, is the bottleneck | FIXED; **deliberately NOT exercised today** — it only renders once the host is genuinely thrashing, and this host kernel-panicked from memory exhaustion at 09:31 (see C9). Manufacturing that state to photograph a banner is not worth a second panic. Needs a box that is not this one, or a fault-injected `memoryPressure` value |
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

## D2b — RETRACTED, and the truth is the opposite

**What I wrote first was wrong.** I inspected 4 template files, wrote "all 8",
and generalised that to the model library: *"changing reasoning effort
mid-conversation costs a full re-prefill, and no cache change can avoid it …
the `effort=` salt component is not costing reuse; leave it alone."*

Measured properly:

| fact | count |
|---|---|
| chat templates in `~/models` | **97** |
| files consuming `reasoning_effort` | 8 |
| **distinct template bodies** among those 8 | **2** (6 + 2 copies across quants) |
| templates using `enable_thinking` | 75 |
| templates using `reasoning_strength` (Muse Glimmer) | 3 |

The "8 templates" were 2 in-house bodies duplicated across quant/CRACK
variants. Two templates out of 97 is not a property of the library.

**For the other ~89 the conclusion inverts.** Their template never references
`reasoning_effort`, so the rendered prompt is byte-identical across effort
levels — output cannot depend on a variable the template never reads. But
`MLXBatchAdapter.chatTemplateContext` still injects
`context["reasoning_effort"]` on the Qwen, Nemotron-thinking, Zaya and generic
`disableThinking` branches, so `cacheScopeSalt` emits `effort=<v>`, the key
changes, and the fetch misses.

**Identical tokens, different key, guaranteed full re-prefill that buys
nothing.** Concrete instance:
`dealign.ai/Qwen3.6-35B-A3B-MXFP4-CRACK-MTP` — Qwen family, template contains
no `reasoning_effort` reference, and `isQwenFamily` sets it whenever the effort
is positive.

So the salt **is** discarding reuse across most of the library — the opposite
of "leave it alone".

What remains true from the original pass: for the 2 bodies that *do* render it
(Step-3.7-Flash emits `"Reasoning: " + reasoning_effort` as the first tokens
after BOS; Qwen3.8-27B-JANG_* emits `reasoning_instructions` as the first
content of the system block), the tokens genuinely diverge at the front and the
re-prefill there is unavoidable. That narrow claim was the only one the
evidence supported.

**Not fixed in this pass, deliberately.** Narrowing the salt has to key off
what the template actually consumes, which means getting the template source to
the point where the salt is computed. Shipping that on the strength of a claim
I already got wrong once would be the same mistake twice. Pinned by
`ReasoningEffortSaltScopeTests` so the cost is visible and any narrowing shows
up as a deliberate behaviour change.

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

### Live proof of D1 + D4 (the readout is what closed it)

Driven against the dev-built app in an isolated root, two real turns, model
`qwen3-0.6b-8bit`:

| turn | prompt | result | Sampler last used |
|---|---|---|---|
| 1 | "Name three colors." | "The three colors are red, blue, and green." — TTFT 0.29s, 375.6 tok/s | `temp 0.23 · top-p 1 · top-k 7 · min-p 0 · max 16384` |
| 2 | "Name two fruits." | "Fruits include apples and oranges." — TTFT 0.11s, 359.5 tok/s | same |

`config/server-runtime.json` carried only `generation.temperature = 0.23` and
`generation.topK = 7`. Both reached the sampler. `top-p 1` and `min-p 0` stayed
at engine defaults, which is the point: untouched keys fall through instead of
being stamped. Before the D1 fix the identical readout showed `temp 0.6 ·
top-k 0` — the model/engine defaults, with the user's values discarded.

**The first attempt at this proof was a harness error, not a product defect,
and it is worth recording because it read exactly like one.** I hand-wrote the
two keys at the JSON *top level* rather than under `generation`. The app parsed
the file, ignored the unknown top-level keys, and ran on defaults — so the row
said `temp 0.6` and I logged it as UNEXPLAINED. On the next launch the schema-3
migration re-homed both keys into `generation`, and the same turn produced
`0.23`. Nothing in the product changed between those two readings. Suspect the
measurement first.

### D5 — the row could not be found by its own name

While reading the row back, Settings search for **`sampler`** returned
*"0 settings match"* in the live app. `SettingsSearchIndex.search` matches by
substring/token with `allowFuzzy: false`, so nothing bridges `sampler` to the
indexed `sampling`. Three terms printed on screen — `sampler`, `top k`,
`min p` — reached no entry at all.

Fixed by adding those tokens to the `server.generation` and
`server.liveActivity` entries. `searchFindsSamplerByTheWordShownOnScreen`
fails with 4 expectations against the old keyword lists, so it pins the
behaviour instead of restating it.

One caveat on the same probe: after that first search I tried four more terms
by clicking the field and retyping, and reported them as also returning zero.
That was wrong — the field still read `sampler` and I was re-reading a stale
result string. Those four results are discarded. Only the `sampler` observation
was made with the field verified to hold what I typed; `top k` and `min p` were
then established from the index source and pinned by the test.

**Live proof after the fix.** Rebuilt the app with the new keyword lists and
drove the real Settings window:

    Search Results
    2 settings match "sampler"
      SERVER
      Generation Defaults   / Sampling Defaults
      Live Activity         / Live Activity

Pressing the first result navigates to the Sampling Defaults panel with
`Temperature` on screen, so the entry is findable *and* reachable, not just
indexed.

Two harness facts worth keeping, because both cost time here:

- **Synthesized keystrokes never reached that search field by any method** —
  CGEvent unicode, CGEvent virtual keycodes, with and without `AXFocused`, with
  the app confirmed frontmost, launched via LaunchServices and directly. Mouse
  clicks reached the same window fine (clicking a nav item changed the pane),
  and `AXIsProcessTrusted` was true with `IsSecureEventInputEnabled` false, so
  neither trust nor secure input explains it. What worked was setting
  `AXValue` on the field, which SwiftUI wrote straight through to the binding.
  Note this is field-specific: the same `AXValue` write did NOT fire the
  binding on the Sampling Defaults temperature field earlier in this audit.
- **A leftover proof app held a keychain prompt open across the whole session.**
  `OsaurusBonsaiProof` had been running ~55 minutes and kept a SecurityAgent
  dialog ("Osaurus wants to use your confidential information stored in
  'Osaurus Master Key'") at layer 1000 over the settings window, re-posting a
  new one each time it was denied. Quitting the requesting app is what stopped
  it; denying alone never does. This is the stuck modal reported earlier as
  "i closed osaurus but this bs is still open". It is NOT the keystroke cause
  above — keystrokes still failed after it was gone.

**Swept the rest of the index for the same class.** The obvious follow-up to
one unreachable setting is whether there are others: all 87 entries are
findable by their own title, and every entry that displays a section header is
findable by that header. No further gaps. Kept as a sweep
(`SettingsSearchSelfFindProbe`) rather than named cases, so an entry added
later inherits the guarantee, with an anti-vacuity check because an index that
shrank to nothing would otherwise pass both sweeps silently.

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

| turn shape | reuses **in principle** | reuses **on a shipping family** |
|---|---|---|
| text follow-up after an image turn | yes — same tensor → same salt; suffix is text-only | **no** |
| turn that ADDS an image / video / audio | no — salt changed AND the suffix carries new placeholders | **no** |
| text turn after a media-introducing turn | yes — tensor matches the previous turn again | **no** |

**The right-hand column is the correction.** The left column is what the
mechanism does when it is fed; it is not what ships.

So the cost is **per media-introducing turn**, not cumulative — but a chat that
varies modality every turn introduces media every turn and therefore never
resumes, re-running the vision tower over all prior images each time. That is
the long-context degradation to expect, and it is the shape worth optimizing.

### Correction: the mechanism is correct and almost nothing reaches it

The two mechanisms above are accurate, and the conclusion drawn from them was
still too optimistic, because it assumed processors feed them. Measured against
the sources:

- **3 of the VLM processors that build a media-bearing `LMInput` declare
  `mediaTokenIds`** — Audex, DeepSeek-OCR, Nemotron-H Omni. Qwen3-VL,
  Qwen2.5-VL, Qwen2-VL, Gemma 4, Gemma 3, Muse Glimmer, LFM2-VL, Mistral 3,
  GLM-4V, Zaya1-VL, Idefics3, Pixtral, SmolVLM2 and FastVLM declare none.
- Undeclared is not a smaller version of declared. It takes
  `guard let mediaTokenIds else { return true }`, which rolls back on **any**
  non-empty suffix — including the pure-text follow-up the table above listed
  as reusing.
- Qwen3-VL's **text** branch computes canonical boundaries and passes
  `cachePrefixTokenCounts` / `cacheStablePrefixTokenCounts`. Its **media**
  branch returns an `LMInput` carrying `image:` / `video:` and neither. A
  prompt that declares no boundaries gives the coordinator nothing to probe, so
  the rollback is not even reached — there is no candidate hit to roll back.

So a VL conversation on the families Eric actually runs re-prefills every turn,
vision tower included. That is the long-context degradation, and it is not the
salt and not (yet) the suffix rollback — it is that neither is wired up.

**And the rollback is load-bearing, not cautious.** Qwen 3.5 VL's
`mergeInputIdsWithImageFeatures` throws `featureTokenMismatch` unless the
number of masked placeholder elements equals the image-feature size. A suffix
prefill that carried image features onto zero placeholders would not silently
mis-substitute, it would throw. Any fix therefore has to drop the media from
the suffix input, not merely permit the resume — while keeping the cache salt
computed from the ORIGINAL media, since the restored KV contains those
embeddings.

Pinned by `Tests/MLXLMCommonFocusedTests/VLMediaTokenDeclarationReachabilityTests.swift`
(5 tests: the unconditional-rollback branch, the declaring set, the mainstream
families named individually so a failure says which one moved, and the
Qwen3-VL boundary asymmetry).

### The fix, and the A/B that makes it causal

`QwenVL.mediaTokenIds` resolves `<|image_pad|>` / `<|video_pad|>` through the
tokenizer and Qwen3-VL / Qwen2.5-VL / Qwen2-VL now pass them. Nothing else
changed: the engine's resume branch already built its suffix input as
`LMInput(text: remainingArray, image: nil, video: nil)`, so no media reaches
the merge and `featureTokenMismatch` cannot fire; entries are stored at the
full prompt length by `storeAfterGeneration`; and candidates come from
`SELECT DISTINCT token_count FROM cache_entries`, so no boundary arithmetic is
involved. Declaring the ids is the whole fix.

Two osaurus builds differing **only** in the vmlx pin, same machine, same
model (`Qwen3.8 27B JANG_2D`), same agent, same images, same prompts:

| turn | baseline pin `2fbd1c49` | with the declaration |
|---|---|---|
| 1 — image + "what digit / what colour" | 4.19s, 3.27s | 4.10s (cold), 0.60s (warm root) |
| 2 — "spell that digit as an English word" | 3.45s, 3.37s | 0.59s, 0.74s |
| 3 — "and what colour was it again?" | 3.30s, 3.42s | 0.48s |

Follow-up turns: baseline **3.30 / 3.37 / 3.42 / 3.45** (median 3.40s), fixed
**0.48 / 0.59 / 0.74** (median 0.59s). **5.8× on the median, no overlap between
the legs**, and the spread inside each leg is a few percent. Cold turn 1
matched at 4.19 vs 4.10 (2%), which is the noise indicator: the legs are
identical where the change should do nothing.

Correctness held on both legs and is scored against opposite images rather
than a word list — the test images are a blue 7 and a red 3, so a constant
answer fails. Both builds answered "7 … blue", then "seven", then "Blue". A
control run in a *fresh chat with no history* answered "zero", confirming the
follow-up genuinely depends on the retained image context rather than guessing.

Disk L2 counters moved with it: 2/11/6 → 5/20/11 across the two VL turns
(+3 hits), SSM 1 → 4.

### The other families: declared, and it is not enough

Every processor whose placeholder tokens could be established now declares
them through one shared `MediaTokenIds.resolve` — Gemma 4 (`<|image|>`,
`<|audio|>`), Muse Glimmer (`<|patch|>`, `<|video|>`), LFM2-VL, Zaya1-VL,
FastVLM, SmolVLM2 (`<image>`), Mistral 3 and Pixtral (`[IMG]`, `[IMG_BREAK]`,
`[IMG_END]`). A family emitting more than one KIND declares all of them:
declaring only some is the dangerous direction, because a suffix carrying the
undeclared kind matches nothing, reads as media-free, and resumes onto the
wrong media.

Gemma 3, GLM-4V and Idefics3 are deliberately left undeclared — they carry the
placeholder only as a numeric config id the processor cannot see, and a WRONG
id is worse than none for the same reason. The test states that as a decision
rather than leaving it looking like an oversight.

**Gemma 4 live result — declared correctly, and reuse still does not engage.**
Same three-turn harness, `Gemma 4 26B A4B it JANG_4M CRACK`:

| turn | TTFT | answer |
|---|---|---|
| 1 — image | 1.70s | "The image shows the digit 7 and the background is blue." |
| 2 — text | 1.52s | "Seven" |
| 3 — text | 1.58s | "Blue" |

Answers are correct across all three, which is the safety result that matters
for a newly-declared family: the ids are right and nothing is mis-mapped. But
Disk L2 read **0 hits / 55 misses / 12 stores** — no reuse at all, and TTFT is
flat because this model prefills cheaply either way.

So for Gemma the declaration is **necessary but not sufficient**: something
further down still blocks the hit.

Scoped it with a control rather than leaving it as "something". Same model,
same build, same session, varying only whether the conversation carries media:

| Gemma 4 conversation | Disk L2 hits |
|---|---|
| two VL turns (clean cache) | **0** (0 / 98 / 15) |
| two text-only turns | **5** (5 / 116 / 28) |

So Gemma's cache path works — it reuses on text and never on media. That rules
out topology (`Cache-enabled models 1`, `Hybrid caches 0`,
`Paged-incompatible caches 0`) and rules out "Gemma never caches". The
remaining block is **media-specific and still unidentified**. Explicitly NOT
claimed as fixed; only the Qwen VL families are proven end-to-end.

**Condition caveat on the Gemma numbers — free RAM was never recorded.** The
host kernel-panicked later the same morning (09:31, `watchdog timeout: no
checkins from watchdogd in 93 seconds`) with **914 free pages (~15 MB)** and
**~64 GB in the VM compressor**; `pagesWanted 3086 / pagesReclaimed 0`. Cause
was a VL family matrix that loaded three models in sequence in ONE app process
without verifying each unload actually freed.

The two tables above were captured at 08:19 and 08:54, i.e. 35–70 minutes
before that, so they are **not** known to be degraded — but no free-RAM reading
was logged alongside them, so their condition is *unknown* rather than clean.
Treat the Gemma rows as provisional and re-measure with `vm_stat` free pages
and compressor size logged per leg.

Separately: a later, uncommitted matrix run in which Gemma answered "I cannot
see the image you are referring to" (attachment confirmed present) sat directly
against the panic and is **discarded outright** — that is a dying host, not a
Gemma media-delivery defect, and it must not be cited as one.

Standing rule for every future run here: one model per app process, and verify
free RAM actually returned between loads rather than trusting the app's own
"Unloaded" label.

**A wrong lead, recorded because it was convincing.** Setting
`multimodal.requireMediaSaltForCache = false` and re-running produced 2 hits
where the default produced 0, which looked like a clean single-variable A/B.
It is not: `requireMediaSaltForCache` is read **nowhere** at runtime — it
appears only as a stored property and a validation rule, never reaching
`CacheCoordinatorConfig` or any fetch/store decision. Since `false` combined
with any cache tier is a validation *error*, that run was almost certainly
executing a rejected config on fallback defaults, not the flag's effect. The
attribution is withdrawn.

That the flag is inert is also **not** a defect. The salt is applied
unconditionally, so the invariant genuinely holds, and the control discloses
exactly that: *"Engine invariant whenever a cache reuse tier is enabled …
Disabling fails validation."* Same disclosed-invariant pattern as
"Keep Draft Cache Separate" and "Only Accepted Tokens Enter Base Cache" under
Speculative Decoding. Documented here so the next person does not read the
missing runtime call site as a wiring bug.

`VLMediaTokenDeclarationReachabilityTests` names every family individually so
the declared set cannot silently drift.

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

---

## The context cap turned a preference into a silent wall

Found by testing B2 at its hard shape rather than a comfortable one: set the
cap BELOW what the non-compactable prefix already costs.

With `contextLengthCap = 2048` against a ~2.5k prefix (system prompt 1.1k +
tools 1.4k), **the send button stopped working.** No error, no notice, no
disabled styling — pressing it did nothing at all. The chip went red
(`⚠ ~2.5k / 1.7k`), which is the only hint, and it does not name the setting.

Controlled A/B, same text, model, session and window, only the cap varying:

| cap | pressing send |
|---|---|
| 2048 | nothing happens; text stays in the composer |
| cleared | sends immediately, model replies `ok` |

The gate is `canSend`'s `guard !isContextHardOverflow`. Its reasoning is sound
when the MODEL's window is the ceiling — the request would fail whatever
compaction did. But `contextLengthCap` is a **preference**: the weights here
have a 108k window and can take the prompt fine. Letting a preference kill the
send makes it a wall, and a silent one.

That is the rule this repo already has about invented limits: an estimate or a
preference may ADVISE, never REFUSE. A ceiling the user chose must not behave
like a hardware limit. And this was reachable only *because* B2 shipped the
control for it — the fix created the exposure, so it belongs in the same PR.

Fixed two ways:

1. `canSend` no longer blocks when `contextWindowResolution.source == .userCap`.
   The chip still turns red — the advisory stays, the refusal goes.
2. The over-budget message now names the cap when the cap is the ceiling.
   Telling someone to "shorten the input" while their model has 108k free and
   their own cap is 2048 sends them to fix the wrong thing.

**Live proof after the fix**, identical scenario:

```
Say the single word: ok
->  Context window cannot fit this request. The limit in force is your Context
    Window Cap (Settings -> Server -> Cache -> Context & KV Policy), not the
    model's own window — raise or clear it, or shorten the input.
```

The turn now sends and fails loudly and specifically, instead of a dead button.

**Still open, recorded rather than papered over.** The request does not
complete. The honest end state is that a cap smaller than the non-compactable
prefix is simply unsatisfiable, and the engine should relax it to what the
prefix needs (bounded by the model window) and say it did — so the cap governs
the conversation budget and never makes a request impossible. That needs the
prefix size at resolver time, which `applyingUserCap` does not have, so it is a
follow-up rather than a same-PR change.

---

## The picker says "Vision", the runtime says "not advertised"

Hit while setting up the C9 re-proof: a locally-installed VL bundle selected
from the model picker — badged **Vision**, attachment accepted, thumbnail
shown — was refused the moment it was sent:

```
Error: Request is blocked by local MLX runtime policy for lfm2.5-vl-3b-jang_4m:
Image input is not advertised for LFM2.5-VL-3B-JANG_4M.
```

Two different capability resolvers disagreeing:

- **Composer** (badge + attach) uses
  `ModelMediaCapabilities.composerCapabilities(modelId:fallbackSupportsImages:localModelType:)`,
  which combines the scan record's `model_type` with the bundle's actual
  vision bit — the real facts.
- **Runtime policy** ends up in `descriptor(modelId:)`, which calls
  `from(modelId:)` — capability inferred from the model NAME.

There IS a config-aware `descriptor(directory:modelId:)`, and `MLXService`
tries to use it — but it rebuilds the bundle path as
`effectiveModelsDirectory() + modelId components`. A model discovered in the
HF cache, LM Studio, or a **custom model folder** does not live there, the
`fileExists` check fails, and it silently falls back to the name-only
descriptor. So every externally-discovered VL bundle whose name the regex
does not recognise is offered as Vision and then refused.

Same `name-is-not-the-bits` class as the JANG quant work: the ID is not the
manifest.

Fixed by asking the locator where the bundle actually is before falling back:

```swift
let localDirectory =
    modelDirectory
    ?? ExternalModelLocator.path(forId: modelId)   // <-- added
    ?? modelId.split(separator: "/")...
```

**Live proof, same model, same session, before/after the rebuild:**

| build | sending the image |
|---|---|
| before | `Error: ... Image input is not advertised for LFM2.5-VL-3B-JANG_4M.` |
| after | `The digit shown is 7 and the background is blue.` — TTFT 2.15s, 223.9 tok/s, 12 tokens |

The probe image is a white `7` on blue, paired with a red `3` so a blind model
answering one constant scores wrong on at least one probe rather than passing
by luck.

Worth noting for the C9 work: this gate sat in FRONT of the media cache path,
so on this host no externally-discovered VL bundle could reach the reuse logic
at all. Any earlier "0 disk hits" for such a bundle says nothing about the
cache — the request never got there.

---

## Model-derived generation config, live

Asked directly: does chat derive and use the MODEL's own generation params?
Read the bundle on disk and the app's own readout of what it actually ran.

`/Users/eric/models/JANGQ-AI/LFM2.5-VL-3B-JANG_4M/generation_config.json`:

```json
{"temperature": 0.2, "top_k": 50, "top_p": 1.0, "repetition_penalty": 1.0, ...}
```

Settings → Server → Live Activity → **Sampler last used**:

```
temp 0.2 · top-p 1 · top-k 50 · min-p 0 · max 16384 · rep 1
```

Exact match on every shipped field. These are not app defaults — the Sampling
Defaults path was proven separately in D1 to override with `temp 0.23 · top-k 7`
when the user sets them — so the value shown is the bundle's, reaching the
sampler, and visible.

## Cache tier is reported per model

Same session, LFM2.5-VL-3B-JANG_4M resident, Live Activity → Cache:

```
Cache-enabled models        1
Hybrid caches               0
Paged-incompatible caches   0
```

The topology counters are per resident model, so a hybrid-SSM bundle reports
`Hybrid caches 1` and this one correctly reports the standard tier. Combined
with the disk figures below, the tier in force is observable rather than
assumed.

Disk tier during the VL session: **3027 MB across 18 entries**, and the
eviction test earlier drove 116 MB / 5 entries → 1 MB / 4 entries when the cap
was lowered to 76 MB. Storage and enforcement are both live.

## What is NOT proven, and why

**VL follow-up cache REUSE is not re-proven on this host today.** A three-turn
VL conversation ran — image turn answered correctly, then two text follow-ups
answered correctly and fast — but by the time the follow-ups ran the model chip
read `Qwen3 0.6B 8bit`, not the VL bundle. Those follow-ups cannot be
attributed to the VL model resuming a media cache; a text model reading the
visible transcript produces the same answers and the same fast TTFT. The
numbers are discarded rather than reported.

So the C9 headline (Qwen VL follow-up TTFT 3.40s → 0.59s) still rests on this
morning's A/B, whose free-RAM condition was never recorded — see the C9
caveat. That measurement belongs to **vmlx #292** and is not a claim this
osaurus PR makes.

**Confound noted on the capability fix.** Its before-state was observed on a
build pinned to the old vmlx revision and its after-state on a rebuild that
also carried the newer pin, so two variables moved. The attribution still
holds on inspection rather than on the A/B alone: `Image input is not
advertised for …` is emitted by `ModelMediaCapabilities` in OsaurusCore, and
the vmlx pin cannot reach that string. Recorded this way rather than presented
as a clean single-variable result.

---

## Precedence and lifetime of sampling settings — measured, not assumed

Two questions asked directly: does a new model's gen config populate the
Settings temp/top-p/top-k fields, and is a user-set value scoped to the chat
session until the next model swap re-derives it?

**Answer to both: no.** Measured live in one session.

The user's Sampling Defaults (`VMLXServerGenerationDefaults`) are all
`Optional` and ship `nil`. Blank means "follow the model" — it does NOT mean
"copy the model's values in". Nothing ever writes a bundle's numbers into
those fields; they stay user-owned and empty.

With every field blank, `server-runtime.json` read `temperature: null` while
Live Activity → **Sampler last used** showed the bundle's own values. Then
`temperature = 0.77` was set and saved, and a different model was used:

```
lfm2.5-vl-3b-jang_4m   temp 0.2   · top-p 1 · top-k 50 · min-p 0 · max 16384 · rep 1
qwen3-0.6b-8bit        temp 0.77  · top-p 1 · top-k 0  · min-p 0 · max 16384
```

The readout is **per model**, and the user's 0.77 followed the model swap. So:

- A user value is persisted **globally** in `server-runtime.json`, not per chat
  and not per model. It is not re-derived on swap.
- It **outranks the bundle** for every subsequent model — the repo's own
  `effectiveGenerationSettings_userSamplingDefaultsOutrankBundle` pins this.

Worth stating plainly because it is easy to expect otherwise: a temperature
set while using one model silently governs every other model afterwards,
including bundles that ship a very different value, until it is cleared.

`top-k 0` for Qwen is not a partial-override defect — that bundle ships no
`generation_config.json` and no `jang_config.json`, so there is nothing to
derive and unset fields fall through to engine defaults. The LFM bundle does
ship one, which is why it shows 0.2 / 50 / 1.0.

**Derivation sources, in order** (`LocalGenerationDefaults`):

1. `jang_config.json > chat > sampling_defaults` — JANG bundles carry their own
   sampling contract and it wins over the generic file.
2. `generation_config.json` — the Hugging Face standard.
3. Neither present → `.empty`, engine defaults.

**Reasoning / thinking budget is separately model-declared.**
`DeclaredReasoningEffort` reads `preserve_thinking_supported`,
`preserve_thinking_default` and `preserve_thinking_transport` from the bundle,
so preserved-thinking is enforced the way each model declares rather than
uniformly. This matters for the SSD tier: reasoning effort feeds
`cacheScopeSalt` (D2), so a prefix built at one effort cannot be reused at
another — which is the correct behaviour, since preserved thinking changes the
prompt prefix itself.

---

## Reasoning was unfindable by every word it uses

Third instance of the D5 class, and the worst of the three because reasoning
is a feature people go looking for. Probed on the running app:

```
0 settings match "reasoning"
0 settings match "thinking"
0 settings match "effort"
0 settings match "preserve thinking"
```

Three real controls existed the whole time — `Reasoning Parser Override`
(Server → Tools & Templates), `Expand Thinking While Streaming` and
`Group Thinking & Tool Activity` (Chat). None was reachable by any of its own
words. `Expand Thinking While Streaming` had no index entry at all.

Fixed by indexing the Tools & Templates entry for reasoning vocabulary and
adding a `settings.chat.thinkingDisplay` entry, and by extending
`controlsFindableByOnScreenLabel` so the class cannot come back. The probe was
verified to FAIL without the keywords, naming all five queries.

**Live, same build, before → after:**

| query | before | after |
|---|---|---|
| `reasoning` | 0 | **2** |
| `thinking` | 0 | **2** |
| `effort` | 0 | **1** |
| `preserve thinking` | 0 | **1** |

Three separate sections have now been found unreachable by their own on-screen
words (sampler, disk cache, reasoning). The title/section sweeps cannot see
this — an entry passes them while every label a user reads misses — which is
why the control-label sweep is the one that matters.

---

## Reasoning-effort change mid-conversation — PROVEN LIVE

**Correction.** An earlier revision of this section claimed the thinking
control had "no separately addressable AX element". That was wrong, and it was
wrong for an avoidable reason: the model popover was not reliably open when the
tree was dumped, so the row was simply absent from what was inspected. Pressing
the chip toggles the popover, and an odd number of presses closes it again.

The control exists and is properly exposed:

```
AXHeading  desc="MODEL OPTIONS"
AXCheckBox desc="Thinking" value="0"
```

The `brain` glyph on the chip is a read-only status indicator — its own comment
says so ("the interactive control remains directly available in both the footer
and picker"). Driving the glyph was the mistake; the checkbox under MODEL
OPTIONS is the control.

Toggling it updates both places at once — checkbox `value 0 → 1` and the chip's
own `value "Off" → "On"` — so the display-lie defect fixed earlier has not
returned.

**Live A/B, one conversation, effort changed BETWEEN the two turns**
(`Qwen3 0.6B 8bit`):

| turn | Thinking | reasoning block | answer | tokens | TTFT | tok/s |
|---|---|---|---|---|---|---|
| A | **On** | `Thought for 612ms`, 876 chars | yellow | **212** | 0.16s | 379.5 |
| B | **Off** | none | yellow | **1** | 0.13s | 451.5 |

The change takes effect on the very next turn inside the same conversation —
212 generated tokens collapse to 1, and the reasoning block disappears
entirely. That is the setting reaching the engine mid-conversation, observed
rather than inferred.

Disk tier across the pair: 29 → 33 entries (turn A) → 38 (turn B). Each leg
wrote new entries rather than reusing the previous prefix, which is what
`cacheScopeSalt` carrying `reasoning_effort` predicts: a prefix built while
thinking was on is not a valid prefix once it is off. That is the correct
behaviour and it is also the re-prefill cost to expect when effort is changed
deep into a long conversation.

Noted honestly: turn B answered "yellow" again rather than a different colour.
That is model quality on a 0.6B, not a harness or settings fault — the point
under test was whether the effort change took, and it plainly did.

---

## "All tools always allowed" — the control existed but search hid it

`enabled` is not `allowed`. In the proof root, `config/tools.json` reads:

```
enabled: 83 entries, all true
policy:  0 entries          <-- empty
```

and `ToolConfiguration.policy(for:)` is `policy[name] ?? .ask`. So all 83
shipped tools are enabled and every one of them would prompt.

The control that resolves this is `Auto-Allow All Tool Calls` (Chat), stored at
`ToolApprovalSettings.autoAllowAllDefaultsKey`, read by `ToolRegistry` at each
`.ask`-policy decision, default `false`. It works — it simply could not be
found:

| query | before | after |
|---|---|---|
| `auto allow` | **0** | 1 |
| `allow all tools` | **0** | 1 |
| `always allow` | **0** | 2 |
| `approve tools` | **0** | 1 |

`auto allow` is literally the first two words of the setting's own name.

**This one was worse than unfindable.** The toggle had NO index entry at all,
and the single query that did return something — `tool calls` — matched
`Max Tool Attempts`, a different setting in a different section. A user
searching for tool permissions was routed confidently to the wrong control.
A wrong destination is more harmful than an empty result, because it looks
like an answer.

Fixed with a `settings.chat.autoAllowAllTools` entry and the vocabulary people
actually type, and pinned in `controlsFindableByOnScreenLabel` (verified to
fail without it, naming all four queries). Live: `auto allow` now resolves to
**Auto-Allow All Tool Calls · Chat**.

Fourth section found unreachable by its own words, after sampler, disk cache
and reasoning.

---

## Tool usage per turn — PROVEN LIVE

With `Auto-Allow All Tool Calls` enabled (checkbox `value 1`, and
`chatAutoAllowAllTools = 1` in the app's own defaults domain), one turn on
`Qwen3 0.6B 8bit`:

```
Use your tools to tell me the current date and time. Call the appropriate tool.

  ⚙ Get current time · 118ms
  The current date and time is Saturday, August 22, 2026 at 4:03 PM PDT.
  TTFT 0.22s • 350.7 tok/s • 27 tokens
```

The tool card is rendered in the transcript with its own latency, the call ran
with no approval card in the way, and the result reached the answer. A 0.6B
cannot produce today's date from weights, and the card is visible rather than
inferred — both halves matter.

The auto-allow toggle sits behind a confirmation that names the risk in
plain terms ("tools that can execute code, modify files, or send data"). That
is the right shape: an informed confirmation, not a silent refusal, and it can
be turned off again from the same place.

## Multimodal gating controls

Live in Settings → Multimodal: `Vision-Language Mode`, `Allow Video`,
`Allow Audio`, described as "Auto follows the loaded model; Force-Off rejects
media regardless of model capability; Force-On requires model support."

Image input is proven end to end above (LFM2.5-VL answering "the digit shown is
7 and the background is blue"). **Video and audio are NOT proven here** — only
the gating controls were observed, no video or audio turn was run. Recorded as
untested rather than folded into the image result.

---

## Audio input — CORRECTED: no defect demonstrated, and untestable on this host

**This section previously claimed a defect. That claim was wrong and is
withdrawn.** Recording the whole path because the mistake is instructive.

The probe was a self-made WAV (`say` → 3.0s 16 kHz mono, "the secret word is
umbrella") so a model that cannot hear would score wrong rather than pass by
luck. Selected `Gemma-4-26B-A4B-it-JANG_4M-dynA-osaurus`, which **does** declare
`audio_config` in config.json, opened the attachment picker, and the panel read:

```
Select files to attach (image supported)
```

I concluded the composer was gating audio by model NAME and refusing a bundle
with audio weights. Both halves of that were wrong:

1. **26B-A4B has no audio weights.** `from(directory:modelId:)` is explicit
   that Gemma4 audio is "checkpoint-fact-driven, not name-driven", and lists
   three different audio realities in one family: 12B `gemma4_unified` has an
   encoder-free `embed_audio` raw-frame projection; E2B/E4B have mel +
   conformer `audio_tower` plus `embed_audio`; and **26B-A4B / 31B have NO
   audio tensors — "audio is impossible there, not 'unwired'"**. So refusing
   audio for that bundle is the CORRECT answer, reached by
   `gemma4BundleSupportsAudio` scanning the safetensors index for
   `embed_audio.embedding_projection` rather than trusting `audio_config`
   (which Gemma4 configs carry regardless). The design is better than the check
   I was about to "fix" it with.

2. **`audio_config` presence is not evidence of audio.** That is precisely the
   trap the index scan exists to avoid, and I walked into it by grepping
   configs for `audio_config` when picking a test model.

**Audio remains untested here, for a concrete reason.** Scanning every bundle
on this machine — `~/models`, `~/models/JANGQ-AI`, and the whole HF cache — for
`embed_audio.embedding_projection` returns **zero matches**. There is no
audio-capable Gemma checkpoint installed, so no audio turn can be run at all.
Testing it needs an E2B/E4B (or audio-bearing 12B) bundle fetched first.

**What genuinely remains unverified** (as opposed to broken): whether the
composer's `composerCapabilities`, which takes `supportsAudio` from the
name-based `from(modelId:)` while image and video get bundle-derived bits,
agrees with the checkpoint-fact-driven `from(directory:)` for a model that
DOES ship audio tensors. On this host the two cannot disagree, because every
installed bundle is genuinely audio-less. That question needs an audio-bearing
checkpoint to answer, and must not be asserted either way until one exists.

---

## Video — PROVEN LIVE (C6 was OPEN)

Probe built so it cannot be guessed: a 4-second H.264 clip whose digit AND
colour change every frame (7-blue, 3-red, 5-green, 9-orange). A model reading
one frame names one digit; a blind model names none; only a model that sees the
sequence can list all four in order.

`Qwen3.8 27B JANG_4D` (`qwen3_5`, Vision, Extra High), video attached through
the composer's own attachment picker:

```
The digits shown, in order, are: 7, 3, 5, 9.
  1. A "7" on a blue background
  2. A "3" on a red background
  3. A "5" on a green background
  4. A "9" on a yellow background
TTFT 9.19s • 33.3 tok/s • 96 tokens
```

All four digits correct and in order. Three of four colours correct — orange
read as "yellow", which is colour naming, not a failure to see the frame.

**Gating is correct in BOTH directions**, which is the part worth keeping:

| model | attach panel title |
|---|---|
| `Qwen3.8 27B JANG_4D` (qwen3_5, video-capable) | `Select files to attach (image + video supported)` |
| `Gemma-4-26B-A4B` (no audio/video tensors) | `Select files to attach (image supported)` |

So the picker is not simply permissive: it offers video exactly where the
checkpoint supports it and withholds it where it does not. Together with the
image proof (LFM2.5-VL) this closes C6 for video; audio remains untestable on
this host for want of an audio-bearing checkpoint (see the corrected audio
section).

Free RAM through the run: 60.3 GB before the 27B load, 26.7 GB after — one
model in one process, per the rule added after the morning panic.

---

## C8 media + tools — passes clean, and a wrong-media carry-over next to it

`Qwen3.8 27B JANG_4D`, auto-allow tools on, one turn asking for BOTH an image
reading and a tool call.

**Clean conversation (no prior media) — correct:**

```
(image: white 3 on red)
"Two things in one reply: (1) what digit and background colour is in this
 image, and (2) use your tool to get the current time."

  The image shows a white digit 3 on a red background.
  ⚙ Get current time · 232ms
  (2) Current time: Saturday, August 22, 2026 at 4:42 PM PDT
  TTFT 5.75s • 42.7 tok/s • 36 tokens
```

Both halves right in a single turn: the vision tower read the new image and the
tool fired and its result was used. C8's mechanism works.

**Same question, same model, same build, in a conversation that already
contained a VIDEO turn — WRONG media:**

The identical red-3 image was attached and the answer was
`Digit in the image: 9 (a white "9" on a yellow background)`. There is no 9 and
no yellow in that image — that is the **last frame of the previous turn's
video** (9 on orange, which this model calls yellow). The tool half was still
correct (`Get current time · 226ms`, 4:40 PM PDT).

So the failing variable is isolated: **prior media in the conversation**, not
media+tools together. The new attachment was ignored and the model answered
about the earlier media — the "fluent answer about the WRONG picture" failure
that C3's cache-scope salt exists to prevent, here reached through conversation
history rather than a cache hit.

**Honest limits of this observation.** One reproduction of the failure and one
of the pass. What is NOT yet established: whether it needs video specifically
(vs any prior media), whether the new image reaches the model at all or is
merely out-ranked by the older frames, and whether it depends on the two media
being different kinds. Naming the property rather than the shape I happened to
run: *a media-introducing turn that follows earlier media in the same
conversation.* That is the case to re-run before anyone calls it understood —
and it deserves its own investigation rather than a line in this PR.

---

## Video, second look: the content is right, the mechanism is not what I claimed

An earlier revision of this document said "video passthrough PROVEN". That
overstated what was observed, and a follow-up run said so in the model's own
words. Asked to list the digits in the same clip, `Qwen3.8 27B JANG_4D`
replied:

> **I can't watch video** — what came through as a still image showing four
> digits stacked vertically, top to bottom: 7 (blue), 3 (brown/red),
> 5 (green), 9 (yellow/gold). So the sequence is: 7, 3, 5, 9.

The digits and their order are right, twice, which is why the first run looked
like clean video support. But the model describes receiving ONE stacked still,
not four frames — and "stacked vertically, top to bottom" is a specific spatial
claim, not vague hedging.

**What is established:** attaching a video to a video-capable bundle produces a
correct reading of its frame content, and the attach path is gated correctly
(offered for `qwen3_5`, withheld for a bundle with no video tensors).

**What is NOT established:** whether the runtime hands the model true temporal
frames or composites them into a single image. A model's self-report is
evidence, not proof — it could be describing a 4-frame grid it received as one
tensor. The video preparation lives in vMLX rather than OsaurusCore, so it was
not settled from this repository.

This also gives a plausible mechanism for the wrong-media carry-over recorded
above (a new image after a video turn answered about the video's last frame),
and it sharpens that finding: the image→image control PASSED — a new image
after a prior IMAGE was read correctly — so the failing ingredient involves
video specifically, not merely "prior media".

| prior turn | new attachment | result |
|---|---|---|
| image (blue 7) | image (green 5) | **correct** — "5 on a green background" |
| video (4 frames) | image (red 3) | **wrong** — "9 on a yellow background", the video's last frame |

Two runs, one each way. Enough to rule OUT the broad "any prior media" framing
I first wrote, not enough to call the video-specific mechanism understood.

---

## Video, settled: I believed the model about its own plumbing

The section above walked back "video passthrough proven" because the model
said *"I can't watch video — what came through as a still image showing four
digits stacked vertically."* **That walk-back was wrong, and the reason it was
wrong matters more than the conclusion.**

vMLX extracts real frames. `MediaProcessing.asCIImageSequence` drives
`AVAssetImageGenerator` with `requestedTimeToleranceBefore/After = .zero`,
samples `duration × samplesPerSecond` timestamps via `MLXArray.linspace`, and
returns a `[CIImage]` sequence. `QwenVL.patchify` then folds that sequence into
a temporal patch grid — `gridT = patches.dim(0) / temporalPatchSize`, i.e. time
is a real axis, not a collage.

So the pipeline does exactly what C6 asks. The model's description of its own
input was **confabulation** — an entirely ordinary VLM behaviour, and worthless
as evidence about the runtime.

**The mistake:** I treated a model's self-report as a fact about the pipeline
and rewrote a status row on it. A model saying "I received X" is a token
sequence, not instrumentation. The source was checked out on the same machine
the whole time — vMLX is a sibling repo, not an external dependency — and one
grep settled what two rewrites had guessed at.

Rule for this document: pipeline claims are settled by reading the pipeline.
Model output is evidence about the MODEL, never about the plumbing that fed it.

The carry-over finding above still stands on its own controls (image→image
passes, video→image fails) — those are observed behaviours, not self-reports.

---

## Carry-over root cause: video pads and image pads share one feature scatter

Upgraded from "candidate" — the evidence chain now closes, and tools are out.

**Reproductions (Qwen3.8 27B JANG_4D, red-3 image attached each time):**

| prior turn | tools in turn | answer | correct? |
|---|---|---|---|
| image (blue 7) | no | "5 on a green background" | ✅ |
| video (4 frames) | yes | "9 ... yellow background" | ❌ |
| video (4 frames) | **no** | "9 on a yellow/gold background" | ❌ |

2/2 deterministic with a video prior, 1/1 correct with an image prior. **Tools
are irrelevant** — the second failure had none. The wrong answer is not random:
both times it is the video's LAST frame (9 on orange, which this model calls
yellow/gold).

**The mechanism, both halves now checked in source:**

1. *Prior media stays in the payload.* Chat messages carry `contentParts`, and
   the enum includes `.videoUrl` alongside `.imageUrl` — history messages keep
   their media parts, so turn 2's request still contains turn 1's video.

2. *The merge pools both placeholder kinds.*
   `QwenVL.mergeInputIdsWithImageFeatures` collects positions for
   `imageTokenId` **or** `videoTokenId` into ONE list and scatters a single
   feature tensor across all of them:

   ```swift
   if v == imageTokenId || v == videoTokenId { imageIndices.append(i) }
   ...
   result[0..., MLXArray(imageIndices), 0...] = imageFeatures
   ```

With video pads and image pads both present, every position is filled from one
tensor — so the new image's positions receive video features, and the tail of
that tensor (the last frames) lands on the last pads. That predicts the exact
symptom observed, including *which* frame comes back.

**Still not patched here, and the reasons narrowed to one.** The "single
observation" objection is gone and the missing link is closed. What remains:
this is a vMLX change to the merge path shared by every Qwen VL model, while
#2442 is a finished, green osaurus PR. A correct fix has to split the two pad
kinds and route each to its own feature tensor — which needs its own tests for
image-only, video-only, and mixed prompts, because getting the split wrong
silently corrupts every VL prompt rather than failing loudly. That belongs in
vMLX with its own proof, not bolted onto this one.


### Fixed in vMLX and proven by A/B (2026-08-22, later the same day)

vMLX `e9971205` splits the scatter by placeholder kind: image rows go to image
pads, video rows to video pads, with `imageRowCount` computed from the image
`THW` frames. `f6f5a4c1` records the proof.

The A/B, on the live app — same model (Qwen3.8 27B JANG_4D), same isolated
root, byte-identical files (`sha256 616b4a4f…` video, `0264acad…` image), same
prompts:

- Turn 1 attaches a 4-frame video: 7 blue, 3 red, 5 green, 9 gold.
- Turn 2 attaches a purple **4** — a digit/colour pair in NO video frame, so a
  leak from the video cannot be mistaken for a lucky guess. The earlier probe
  (a red "3") was ambiguous: red-3 is also frame 2.

| build | answer to "what digit and colour is this NEW image?" |
|---|---|
| `ProofDD-base` (pre-fix; binary has no `mergedRowCount`) | "the digit **9** in white on a solid **orange/amber (golden)** background" — the video's LAST frame |
| `ProofDD-vlfixorder` (`e9971205`) | "the digit **4** on a **blue (indigo)** background" — correct |

Screenshots: `CONTROL-prefix-video-then-image.png`,
`t2-image-after-video-FIXED.png`.

**The shape matters, and the obvious test is the wrong one.** A single turn
carrying both an image and a video does NOT reproduce this. Within one message
`Qwen3VLMessageGenerator` emits image content before video content, so pads and
feature rows already agree and a pooled scatter is accidentally correct — that
turn passes on both builds (verified: it answered image=4 indigo and video=7,3,
5,9 correctly on the pre-fix ordering path). The defect needs the two kinds in
DIFFERENT turns, because `UserInput` flattens images and videos across all
messages into two arrays while pads stay in conversation order.

Two harness lessons from this run, both of which produced a false result first:

- An attachment that silently fails to attach still yields a fluent answer.
  One turn ran with no image and the model said "I don't see any image attached
  to your message" — read as a product finding until the screenshot showed an
  empty composer. The gate now counts the chip's own `AXButton desc="Close"`;
  counting `AXImage` reported FAIL on a turn whose file WAS attached.
- Clearing `cache/` in a proof root also deletes `cache/external-models.json`,
  the external model registry — the app then lists only Hugging Face cache
  models and the bundle under test vanishes from the picker.
