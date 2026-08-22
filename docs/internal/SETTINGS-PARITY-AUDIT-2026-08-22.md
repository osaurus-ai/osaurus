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
| A13 | Diagnostics report resolved cap, not the stale field | FIXED, unproven live |
| A14 | Eval harness cap not overridden by the share | FIXED, unproven live — every eval would have run at 10% |
| A15 | "Is at defaults" check accounts for the share | FIXED, unproven live |
| A16 | A store too big for the cap does not wipe the cache | FIXED in vmlx (#293) — MEASURED 2 entries → 0; **not on the shipping path**, see below |

## B. Context window

| # | item | status |
|---|---|---|
| B1 | Derived per-model from bundle metadata | PROVEN — live `Bundle model maximum 262k · usable budget 85%` → 222k |
| B2 | User cap that actually constrains (`contextLengthCap`) | **WAS UNREACHABLE — now wired**; the field existed and both resolvers read it, but NO Settings control ever wrote it, so the user could not set it. Added "Context Window Cap (tokens)" to Server → Cache → Context & KV Policy (below) |
| B3 | Both resolver twins apply it (chip/send-gate AND agent loop) | FIXED, source-asserted |
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
| C6 | Live VIDEO passthrough + cache | **OPEN** (video EVS additionally needs a post-prepare cache key) |
| C7 | Live AUDIO passthrough + cache (gemma E2B) | CHARACTERIZED with C5 — audio rides the same two mechanisms |
| C8 | Media + tools in the same turn | **OPEN** |
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
