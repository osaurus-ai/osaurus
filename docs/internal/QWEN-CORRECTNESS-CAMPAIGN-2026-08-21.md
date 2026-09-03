# Qwen correctness campaign — 2026-08-21

Scope: **Qwen 2D/4D JANG with MTP** and **Ornith 9B/35B** (same `qwen3_5` /
`qwen3_5_moe` model_types), on the SSD-only cache lane, judged by live harness
runs. Ornith is in scope because it *is* the Qwen family under a different name.

Ground rules inherited from the Python vmlx audit agents, every one earned by a
wrong verdict — read these before filing anything:

- `cached_tokens` measures ONLY the paged tier. A family with a native cache
  reads 0 forever. Grep startup for `forcing … OFF` before filing zero-reuse.
- KV-quant default is **per bundle**. Read the startup line; never infer.
- A reasoning-effort change re-prefills **by template design** when the effort
  is stamped into the system message. Invalidation there is correct.
- Media turns get 0 reuse on non-allow-listed families; allow-listed ones reuse
  only on the *next* turn.
- A/B needs a NOVEL seed per run and a ≥2 s settle. **A latency win is not
  proof** — A/B the answer TEXT at temperature 0.
- 🚨 **Sustained decode is ALWAYS measured over a MULTITURN conversation**, never
  a single turn. A one-turn number is peak decode on a clean cache and hides
  everything this campaign is about: store cost growing per turn, restore cost
  growing with depth, accept rate decaying, compaction firing. Report the
  per-turn series (turn 1..N), not one figure — and say which turn the decay
  starts.
- A chat you have been toggling settings in is a CONTAMINATED fixture. Open a
  new conversation before judging degenerate output.
- Store/fetch must use the SAME tier. Healthy stores + 100 % misses is a tier or
  key mismatch, not a coherence bug.
- Log STATE (resume_at, flags, counters). Never grep for your own log marker and
  conclude "the branch never runs".

---

## PRIORITY ORDER — work top-down

Ordered by: does it BLOCK other work, is it PROVEN broken, how big is the win.
Applies to Qwen 27B, Ornith 9B/35B and the SSM/hybrid families alike.

### P0 — blocking or proven broken (do these first)

| # | item | why first | state |
|---|---|---|---|
| P0.1 | **Assert + LOG native MTP eligibility per turn** (§N) | Every MTP measurement is invalid until this exists — the gate excludes SILENTLY and has already caused one misdiagnosis ("MTP barely does anything"). Blocks P1.2 and P1.3. | to build |
| P0.2 | **Harness must show which decode path ran** (MTP / dFlash / AR) | Same reason, plus a user cannot tell today. Visual-harness wiring. | to build |
| P0.3 | **Cache store writes each boundary as a FULL payload** — verified at BatchEngine.swift:3457-3494 | Direct storage + per-turn store cost. Mean payload here is 174 MB, max 358 MB; a conversation storing a system/tool boundary plus up to 3 history rungs writes overlapping copies of the same early KV. | VERIFIED, needs fix design |
| P0.4 | **Reuse RESIDENT KV instead of a disk round-trip** when the model and conversation are already live | Removes the entire serialize→write→read→deserialize path for the common multiturn case. Likely the single biggest overhead win. | to investigate |
| P0.5 | **Explicit MTP "Off" does not survive a cold load** (§M1) | Verified user-visible defect: `.off → .auto` migration cannot tell stale default from user choice. | VERIFIED, fix = schema version / user-selected marker |

### P1 — the measurements that answer the speed question

| # | item | notes |
|---|---|---|
| P1.1 | **Cache ON vs OFF depth curve** — 2k/8k/16k/32k, hot ABAB, PhysMem per leg | Finds the crossover where reuse stops paying. Two candidate causes already RULED OUT by measurement (§K): probe hashing 24.5 ms, payload read 13-29 ms warm. |
| P1.2 | **Qwen 27B per quant (2D/4D/6D/MXFP8): MTP accept rate at depth** | Requires P0.1. A collapsing accept rate makes MTP pure overhead at long context. |
| P1.3 | **MTP byte-identical vs AR at temperature 0, every depth** | The only acceptance criterion. Temp 0 helps most — a speedup that changes text is a bug. |
| P1.4 | **Chunked prefill coverage per path** (§O) + `phys_footprint` | Text paths already chunk; find what still one-shots. If chunking dodges the paging cliff it is worth more at depth than any per-token win. |
| P1.5 | **Max-context enforcement + WHEN compaction fires** (§H) | Late = a turn overflows first; early = context discarded that still fit. Push to the ceiling, not near it. |

### P2 — parity and correctness

| # | item |
|---|---|
| P2.1 | API vs harness absent-field defaults diverge (temperature, max_tokens, top_p) (§L) |
| P2.2 | `max_tokens <= 0` still emits one token; `repetition_penalty` silently ignored (§L) |
| P2.3 | SSD cap: wiring VERIFIED (§A3), but eviction-at-cap still unproven — starve it and watch |
| P2.4 | TQ/SSM encoding is default OFF — prove q4 correctness when a user turns it ON |
| P2.5 | Tool calling JSON vs XML, suffix/prefix matching, tools+media+effort at max context |
| P2.6 | Two context resolvers disagree on fallback chain (§A1) |

---

## P. Making cache storage cheaper (P0.3 / P0.4 detail)

66. **Deduplicate overlapping boundaries.** Each stored boundary is an
    independent full safetensors payload, so a system/tool boundary plus three
    history rungs writes the same early KV four times. Options: content-address
    the shared prefix once and store rungs as references, or store only the
    LONGEST boundary and slice shorter prefixes out of it on restore (a KV
    prefix IS a slice — this may be nearly free).
67. **Store deltas, not whole prefixes.** Turn N+1's KV is turn N's plus the new
    tail. Persisting only the tail turns an O(context) write per turn into
    O(new tokens).
68. **Is the post-answer store synchronous or on the user's next turn?** A store
    that grows every turn (33 MB → 358 MB here) is a cost the user pays later.
    Measure it; make it async/incremental if it is not already.
69. **Resident-KV first.** If the model is loaded and the conversation is the
    same one, extend the in-memory cache and skip disk entirely. Confirm whether
    a memory tier already survives between turns, and if so why disk is still
    consulted. (Searched `CacheCoordinator` for `memoryCache`/`residentCache`/
    `inMemory` and found none by those names — needs a proper trace, not a
    grep.)
70. **Quantized/compressed KV on disk.** TQ encoding is default off; if enabling
    it shrinks payloads materially, it changes the storage economics — but prove
    q4 correctness first (P2.4).
71. **Do not write what will never be read.** Are rungs stored that no later
    request can match? Instrument store→hit ratio per boundary label.

### Block-level best-match reuse on SSD (today it is whole-prefix only)

Established in §K: `CacheCoordinator` does a genuine longest-STORED-prefix
search, but every SSD candidate is `tokens.prefix(boundary)` — a whole-prompt
payload. **Per-block chain hashes exist only in the paged RAM tier**
(CacheBlock.swift:110/132, walked by PagedCacheManager, which can also reuse a
partial leaf). SSD has no block-level equivalent.

72. Consequence: a conversation that diverges mid-history can only reuse up to a
    boundary that HAPPENED to be stored. Two conversations sharing a long
    system+tools+early-history prefix but differing later take whole-file misses
    where a block tier would reuse the shared run. Measure how often that
    happens in real multiturn use before building anything.
73. Would block-addressed SSD storage — chain-hashed blocks, the scheme the
    paged tier already uses — give better reuse AND cheaper storage at once? It
    dedupes P0.3's overlapping payloads by construction, since shared blocks are
    stored once, and makes reuse granular instead of boundary-gated.
74. Cost to weigh: many small files instead of few large ones, more index rows,
    more per-block probes. §K measured probe hashing at 24.5 ms for 256
    candidates so there is headroom, but block counts are far larger than
    boundary counts.
75. Middle option worth pricing first: store the LONGEST prefix once and slice
    shorter reuses out of it. A KV prefix is a slice, so this may be nearly free
    and captures much of the win without a new on-disk format.

---

## A. Findings already confirmed by reading the code (not yet fixed)

**A1. Two independent context-window resolvers, nothing reconciles them.**
`ContextSizeResolver.resolve(modelId:)` (ContextSizeClass.swift) has **30
callers**; `AgentLoopBudget.resolveContextWindow(modelId:)` (AgentToolLoop.swift)
has **15**, plus sync/async twins (`resolveContextWindowSync`,
`resolveContextWindowResolution`). `RemoteProviderService` separately carries
`contextLength`, `maxContextLength` AND `contextWindow` on one type.
→ **Q:** for a given Qwen bundle, do all resolvers return the same number? If
they disagree, budget/truncation decisions disagree with prefill decisions, and
which one you get depends on which call site ran.

**A1b. The cold-miss path silently changes prompt shape — a cache bug.**
`ContextWindowInfo.unknown` is `(sizeClass: .normal, contextLength: nil)` and
the initialiser defaults `prefersCompactPrompt` to **false**. `resolveUnadjusted`
returns `.unknown` on a cold memo miss (deliberately — the disk probe has hung
the UI before). Once the memo warms, a model at or below
`compactParamCeilingBillions = 20` resolves `prefersCompactPrompt = true`.

So for **Ornith 9B**, and any Qwen at or below 20 B:

| render | memo | prefersCompactPrompt | prompt |
|---|---|---|---|
| first | cold | **false** | verbose |
| later | warm | **true** | compact |

The system prompt therefore changes shape between renders, which changes the
prefix, which misses the cache — on exactly the read sites whose own comment
says they must stay mutually consistent "a KV-cache requirement". Ornith/Qwen
35 B is false in both states, so this hides on the big models and bites the
small ones.
→ **Q:** does a first-turn-after-launch Qwen 9B conversation get a different
system prompt than the same conversation one render later? Measure the composed
prompt, not the flag.
→ Also: `.unknown` claims `sizeClass: .normal` rather than admitting it does not
know, so toolset/manifest decisions are made on a guess during that window.

**A2. Family routing is substring matching on the model id.**
`ModelRuntime` routes on `lower.contains("qwen3_5")`, `contains("qwen3_6")`,
`contains("ornith")` — and the source already flags `notornith` / `bonsaified`
as live hazards.
→ **Q:** what does a bundle named `not-ornith-test` or a user-renamed directory
route to? Is there a single authoritative family resolver, or does every
subsystem re-derive family from the id string?

**A3. VERIFIED CORRECT — max SSD cache size IS wired and IS displayed.**
Checked because it was suspected broken; it is not, and the near-miss is worth
recording. An osaurus-only grep shows `cache.blockDisk.maxSizeGB` with three
consumers — the UI binding, two `== nil` default checks, and an HTTP field that
reports it — which reads as "the setting does nothing". **It is not.** The
mapping lives in the vmlx-swift package, which that grep excluded along with
`.build`:

    cache.blockDisk.maxSizeGB           (UI, ServerRuntimeSettingsStore)
      -> diskMaxSizeGB                  (VMLXServerRuntimeSettings)
      -> diskMaxGB = Float(... ?? 10.0)
      -> CacheCoordinatorConfig.diskCacheMaxGB
      -> DiskCache(maxSizeGB:)          (CacheCoordinator.swift:178)

`ModelRuntime.buildCacheCoordinatorConfig` then normalises a non-positive cap
(0 would self-evict every entry at insert) and applies a host-aware free-space
clamp, logging a notice when it lowers the value.

Parity is also already right: `CacheSection.swift:189` displays
`active.diskL2MaxGB` — the **post-clamp effective** cap, not the typed one —
and `/health` reports the same field. So a user whose 200 GB request was
clamped sees the real number.

→ Still open, and only answerable live: does the typed value survive a restart,
and does the janitor actually evict at the cap (starve it with a tiny cap and
watch)? Wiring being present is not the same as eviction being enforced.
→ **Method note for this campaign:** grepping osaurus alone is not sufficient
for anything cache- or runtime-related — the implementation is split across the
vmlx-swift package. This nearly produced a false bug report and an unnecessary
"fix".

---

## B. Cache reuse (SSD-only lane) — the questions

1. On SSD-only (no paged pool), does a Qwen 2D turn-2 actually **hit**, or does
   it store-and-miss? Healthy stores + 0 hits = tier/key mismatch.
2. Is the reuse boundary **exact-prefix only**, or does the best-match
   suffix/prefix search actually fire? What is the measured hit rate for a
   prompt that shares 90 % of a prefix but diverges at the tail?
3. Does the stored key include everything that changes the KV — tool schemas,
   system prompt, reasoning effort, media salt? A key missing any of them
   returns a cache that is silently wrong rather than merely cold.
4. Hybrid (`qwen3_5` GatedDelta) has an **SSM companion**. Do KV and companion
   evict *in step* on the SSD lane? A companion surviving its KV (or vice versa)
   is corruption, not a miss.
5. What happens at the eviction boundary with a STARVED budget — does the
   conversation degrade or produce garbage? Eviction proof requires starving it,
   not waiting for it.
6. After an app restart, does the SSD cache restore for Qwen, and is the restored
   answer byte-identical at temp 0 to the pre-restart answer?
7. Ornith 9B (dense) vs 35B (MoE): same lane? MoE routing state is not KV — is
   anything expert-related being cached that shouldn't be?

## C. MTP — autodetection, cache, correctness

8. How is MTP **autodetected** for a Qwen bundle — weights present, config flag,
   or id substring? What happens when detection is wrong in each direction?
9. Does MTP interact with the SSD cache at all? Are draft-model KV states cached,
   and if so are they keyed separately from the target's?
10. On a cache HIT, is the MTP draft state consistent with the restored target
    state, or is the drafter starting cold against a warm target?
11. Is MTP output **byte-identical** to non-MTP at temp 0 on Qwen? (This is the
    only acceptance criterion — a speedup that changes text is a bug.)
12. Does the accept rate hold as context grows, or does it collapse past some
    depth? (Directly feeds the long-context speed concern.)
13. What is the MTP warmup cost, and is it paid once per residency or once per
    turn?

## D. Long-context speed decay — the headline concern

14. **Measure the actual curve.** Decode tok/s and prefill pp/s at 2k / 8k / 16k
    / 32k / 64k on the same Qwen bundle, hot ABAB, `PhysMem` logged before each
    leg. Is the decay real, and is it *depth-dependent* or flat?
    (DSV4 turned out to be depth-INVARIANT at ~29 tok/s — the "sag with depth"
    framing was wrong there. Do not assume Qwen is different; measure.)
15. Separate the three candidate causes, because they need different fixes:
    memory pressure/paging, attention cost growth, and cache-restore overhead
    growing with prompt length.
16. Does TTFT grow linearly with prompt tokens, or superlinearly? Superlinear
    means the prefill path is re-doing work.
17. Is the post-answer store getting more expensive every turn (serializing an
    ever-larger KV)? That cost lands on the *user's* next turn.
18. Does the app re-prefill the whole conversation on any turn it shouldn't
    (the class of bug that already ate long hybrid turns once)?

## E. Tool calling, reasoning effort, and the swaps between them

19. Reasoning effort changed **between tool calls** mid-loop: does the loop keep
    a coherent cache, and does the model actually honour the new effort for the
    remainder?
20. Tools declared → tools OFF → tools declared again within one conversation:
    does each transition invalidate correctly in BOTH directions? (The reverse
    transition is the one that gets missed.)
21. Does Qwen re-call a tool it has already satisfied? (Known Qwen 3.5 failure
    mode.)
22. Tool **availability**: does the model see the same tool list the UI claims?
    A tool that is declared but unavailable, or available but undeclared, both
    produce silent misbehaviour.
23. Sandbox: when a tool runs sandboxed, do failures surface as tool errors the
    model can recover from, or as silent empties?
24. Does an effort swap mid-loop change the *template* (and therefore force a
    legitimate re-prefill), or is it a sampling-only change? These have opposite
    correct behaviours and must not be conflated.

## F. Multimodality

25. Image between tool calls: does the media survive the tool round-trip, or is
    it dropped from the re-sent history?
26. Is the media salt part of the cache key, and does a *different* image with
    the same text produce a different key?
27. Video on Qwen 3.5/3.6: same questions, plus frame budget interaction with
    the context window.
28. Does an image turn poison the cache for the following text-only turn?

## G. Loading and warmup

29. What exactly does warmup do for a Qwen bundle, and is its cost paid before
    the user's first token or during it?
30. Is warmup state reused across model switches, or silently discarded?
31. Does a failed/partial load leave a usable-looking model that produces
    degraded output? (The truncated-bundle class.)

## H. Max-context enforcement and WHEN compaction fires

Push each of these to the limit rather than near it — the interesting behaviour
is at and past the boundary, and a conversation that merely gets long proves
nothing.

32. What is the enforced ceiling for a Qwen/Ornith bundle, and is it the
    resolver's number, the bundle's `contextLength`, or a settings override?
    (Two resolvers disagree on the fallback chain — see A1.)
33. **When** does compaction trigger — at what fraction of the window, measured?
    Is the trigger on prompt tokens, prompt+generation, or a budget estimate
    that can be wrong?
34. Grow one conversation continuously to the ceiling and record, per turn:
    prompt_tokens, cached_tokens, TTFT, decode tok/s, whether compaction fired.
    The failure to look for is compaction firing LATE (a turn that overflows
    first) or EARLY (throwing away context that still fit).
35. Does compaction preserve the tool-call/tool-result pairing? Dropping a tool
    result while keeping its call produces a model that re-calls or hallucinates
    the result.
36. Does compaction preserve media references, or does an image silently vanish
    from history while the text still refers to it?
37. After compaction, is the KV prefix still reusable, or does every compaction
    force a full re-prefill? (This is the long-context speed question in
    disguise — if compaction invalidates the cache, cost spikes exactly when the
    conversation is most expensive.)
38. With tools declared AND media attached AND reasoning effort changing, how
    close to the ceiling can the harness actually get before it breaks? That
    combination is the real user workload and the one least likely to be tested.
39. What happens at the ceiling with the SSD cap ALSO starved — do the two
    limits interact, or does one mask the other?
40. Is the ceiling enforced identically on the chat path and the exposed API
    server path? They build messages in separate functions; a fix in one is
    inert in the other.

## I. Three surfaces that must not diverge

The visual harness, the **exposed HTTP API server** users hit, and the
CLI/RunBench harness are NOT the same thing. They build messages and apply
settings in separate code, so a fix in one is inert in the others. **The visual
harness is the one that matters most** — but the API is user-facing and gets
judged by strangers.

41. **Sampling kwargs actually enforced?** For every parameter the API accepts —
    temperature, top_p, top_k, min_p, repetition/frequency/presence penalty,
    seed, max_tokens, stop — does the caller's value reach `GenerateParameters`,
    or is it accepted by the schema and then dropped, overridden or clamped?
    There is history here: seed was a no-op, stop returned 400, penalties were
    mis-mapped. Build the table: parameter → reaches the sampler? → where it is
    lost.
42. When a field is ABSENT, does the API default match what the chat UI would
    have used? Every divergence is a support ticket where "same prompt, different
    answer" is the report.
43. **Tool wiring**: does the API build tool schemas through the same code as the
    chat path? Do `tool_choice` (auto/none/required/named) and
    `parallel_tool_calls` behave identically on both?
44. Does the API path enforce the context window and compaction at all, or only
    the chat path?
45. Is `reasoning_effort` honoured on the API path, and does a per-bundle
    declared constraint apply there too?

## J. Native MTP on/off, and effort → generation config

46. Is native MTP **ON by default**? Trace the default at every layer: settings
    store → runtime config → the iterator that decides. Name the field and value
    at each.
47. If the user turns MTP **off**, does that reach the decode path, or does an
    autodetect/heuristic override it? Prove which wins — a toggle the runtime
    ignores is worse than no toggle.
48. How is MTP autodetected (weights present, config flag, id substring), and
    what happens when detection is wrong in each direction?
49. Is there a warmup/memo that latches an MTP decision for the whole model
    residency and ignores a later toggle? (A memo doing exactly this was fixed
    for the hybrid warmup once already.)
50. **Effort → what actually changes?** Does `reasoning_effort` alter the
    template, the sampling params, a thinking budget, or nothing? These have
    different cache consequences and must not be conflated.
51. What happens when a user requests an effort the bundle declares unsupported?
52. dFlash-2 and native MTP: document that **temperature 0 helps most**, and
    that any speedup must be byte-identical to the non-MTP path at temp 0 —
    a speedup that changes text is a bug, not a tradeoff.

---

## K. Measured so far (2026-08-21) — and what is still NOT proven

**Two candidate causes of "SSD reuse gets slower as context grows" — both
MEASURED AND RULED OUT.** Recording them so nobody spends a day on either:

| candidate | measurement | verdict |
|---|---|---|
| probe-loop hashing | 64k tokens x 256 candidates = **24.5 ms** total (SHA-256 + prefix copy, `-O`) | not the cause |
| payload read | 358 MB in **13-29 ms** warm (page-cache speed) | not the cause |

Cache profile on this box: 22 payloads, 3.7 GB, mean 174 MB, **max 358 MB**.
Payload size scales with context, so a long-context restore reads ~10x what a
short one does — but warm I/O is far too fast to explain the symptom.

Still unmeasured in the restore path, in rough order of suspicion:
deserialization into MLXArrays (`TQDiskSerializer.deserializeIndexed`), the
**process-wide `MLXDiskCacheIOLock` held across the whole restore**
(DiskCache.swift:381), the SQLite recency touch, the re-hash on hit, and GPU
upload/dtype conversion.

🚨 **The only measurement that answers the question is a live A/B**: cache ON vs
OFF, same prompts, at 2k/8k/16k/32k, hot ABAB, PhysMem before each leg, looking
for the **crossover depth** where reuse stops paying for itself. Component
timings cannot produce that number and must not be reported as if they did.

### Confirmed by reading (verified against source myself, file:line checked)

- SSD reuse **is** a genuine longest-stored-prefix search, not exact-key only:
  `CacheCoordinator.fetch` probes N and N-1, then walks SQLite for distinct
  stored boundaries <= N in 128-length pages, merges processor-proven
  boundaries, sorts descending and exact-probes each
  (CacheCoordinator.swift:604/615/640/653). It is **not** a longest-common-prefix
  scan inside payloads, and there is no suffix matching — every candidate is
  `tokens.prefix(boundary)`.
- The cache key covers system prompt and tool schemas **indirectly** (they are in
  the rendered token sequence) and reasoning effort + media **explicitly** via
  the salt (MediaSalt.swift:135/141/151). No wrong-cache identity omission found.
- `Tool.toTokenizerToolSpec` canonicalises JSON because non-deterministic key
  order "silently invalidates the MLX paged KV cache prefix" — tool schema bytes
  are already treated as cache-key-critical.

### Leads from parallel Codex audits — UNVERIFIED, source-only

Every one of these came with "no A/B was run" / "a Metal trace is needed".
Treat as hypotheses to disprove, not findings:

- **API parity gap (highest value if true):** no exact-token admission check
  found between MLX tokenization and `engine.generate`; the strict OpenAI path
  may not share typed context admission with the chat path
  (MLXBatchAdapter.swift:2188 / 1662). Matches section I directly.
- **Compaction drops media:** summaries retain prose but "the original media
  payload definitely is not retained" — question 36, likely confirmed.
- **MoE/SwiGLU:** ranked opportunities include inactive/nested SwiGLU compile
  wrappers and replacing per-layer GDN conv-state concatenation with a rolling
  decode kernel (flagged high payoff). Explicitly RULED OUT: a Swift loop over
  experts (gatherMM / gatherQuantizedMM / JANGTQ kernels), missing decode QMV
  routing, RMSNorm decomposition, per-token gate/up splitting.
- **Do NOT blindly enable whole JANGTQ SwitchGLU compile** — the source records
  real regressions and deliberately keeps it experimental.

## L. Sampling-kwarg parity (API vs visual harness) — UNVERIFIED, source-only

From the parallel audit, cross-checked only where noted. Each needs live proof
before it is treated as real.

**Previously-fixed bugs that HELD** (good news, recorded so they are not
re-chased): `seed` is no longer a global-RNG no-op — it reaches per-request
sampler state; `frequency_penalty` is no longer mis-mapped to
`repetitionPenalty`; `presence_penalty` is no longer dropped locally.

**Candidate defects, highest value first:**

1. **`max_tokens <= 0` can still emit one token.** There is no positive-range
   validation, and batched generation checks the cap *after* yielding its first
   token (BatchEngine.swift:2515-2527). Cheap to prove with a focused test.
2. **`repetition_penalty` is silently ignored per request.** It is not a
   property or coding key (OpenAIAPI.swift:691-719, 822-830), and `ChatEngine`
   always sets the per-request value to nil (ChatEngine.swift:136-145). A caller
   sending it gets no error and no effect — only bundle/server defaults apply.
3. **Out-of-range sampling values silently disable their filter instead of
   erroring**: `top_p` outside (0,1), `top_k <= 0`, non-positive `min_p`
   (Evaluate.swift:366-379). Silent no-op is the same failure shape as an
   ignored setting.
4. **Absent-field defaults DIVERGE between the API and the visual harness** —
   this is the parity concern directly:

   | field absent | strict API | visual chat UI |
   |---|---|---|
   | `temperature` | nil -> bundle -> server -> vmlx `0.6` | sends the active agent's temperature if configured |
   | `max_tokens` | implicit `16384` -> bundle -> server | sends the active agent's cap if configured |
   | `top_p` | bundle -> server -> `1.0` | sends `ChatConfiguration.topPOverride` if configured |

   Same prompt, different answer, depending on which surface sent it.
5. **`seed` negative values are lost on the remote path** — `Int(exactly:)` on a
   bit-pattern-preserved `UInt64` yields nil (RemoteProviderService.swift:2943).

→ Next: prove 1 and 2 with focused tests (cheap, deterministic), then decide
whether 3 should 400 or stay permissive, and whether 4 is intended product
behaviour or an accident. Do not "fix" 4 without deciding the contract first.

## M. Native MTP — two findings VERIFIED IN SOURCE (still need live proof)

Both claims below I read myself at the cited lines, not taken on trust.

**M1. A user's explicit MTP "Off" does not survive a cold load.**
`normalizeLoadedSettings` rewrites `.off` -> `.auto` whenever the MTP settings
are otherwise default-shaped
(ServerRuntimeSettingsStore.swift:342), and both `load()` and the cold
`snapshot()` path run it and **resave** (lines 80, 152). A test enshrines it:
`load_repairsOldPersistedMTPDefaultOffToAuto` (Tests:443). `Off` survives only
when some other MTP field is non-default, e.g. `draftTokenLimit = 2`
(Tests:465).

This is **intentional migration code, not an accident** — the comment explains
vmlx-swift `e095d0f` changed the engine default from off to auto, so installs
that persisted the old default need repairing or tuned bundles never reach
autodetect. The problem is that the migration **cannot distinguish "stale old
default" from "the user just chose Off"**. Net effect for a user today: turn MTP
off, relaunch, it is Auto again, silently.

Fix shape (do NOT just delete the migration — genuinely old installs still need
it): a settings **schema version**, or an explicit `userSelectedMode` marker, so
the repair runs once for pre-`e095d0f` data and never again. Update the two
tests together with it.

**M2. Native MTP is disqualified on the HTTP API path — and ONLY that path.**
(Corrected: an earlier draft of this entry implied it might apply everywhere.
It does not, and the scoping matters.)

Eligibility requires `requestedReasoningBudgetTokens == nil`
(Evaluate.swift:497 — the comment explains a drafted token could sail past the
budget ceiling before it arms). That field is set from
`apiReasoningAnswerBudget` (MLXBatchAdapter.swift:1288, assigned 1558), whose
FIRST line is `guard requestSource == .httpAPI else { return nil }`.

`RequestSource` is `chatUI | httpAPI | plugin | p2p | autonomous`
(RequestLog.swift:78-90). So:

| surface | reasoning budget set? | native MTP eligible? |
|---|---|---|
| **HTTP API** | yes (when maxTokens >= ~129 and budget >= 64) | **NO** |
| **visual chat UI** | no | **yes** |
| plugin / P2P / autonomous | no | yes |

This is deliberate and documented in situ: the API surface cannot see
`reasoning_content`, so a think block that spends the whole `max_tokens`
returns an empty answer (the live Anarlog report). The chat UI renders
reasoning itself and owns its own limits.

The real consequence, which is NOT documented anywhere user-facing: **API
callers never get native MTP speedups.** That is a genuine
harness-vs-API divergence of exactly the kind section I is about — same
model, same prompt, different decode path, no way for the caller to know.
→ Live proof needed: confirm AR on the API path and MTP on the harness path
for the same bundle, and measure the speed difference so the tradeoff is a
number rather than a guess.
→ For the MTP-slowdown hypothesis this narrows the search: MTP cannot be
causing slowdowns on the API path, because it never runs there. Any
MTP-related decay must be reproduced in the visual harness.

**Ruled out by the same audit** (recorded so they are not re-chased): MTP
autodetection by bundle-path/model-ID substring; bundle autodetect overriding a
live `.off`; a warmup memo surviving the model unload a saved toggle causes
(a settings change calls `clearAll()`, ServerController.swift:514, so the new
model object cannot inherit the old weak-keyed memo).

**Still open — the hypothesis that MTP caching degrades with context:** verify
is already known to be ~84% of MTP wall time. If verify carries full attention
over the context, its per-step cost grows with depth while the accepted-token
payoff stays fixed, so the net win shrinks and can go negative. Measure accept
rate AND verify cost at 2k/8k/16k/32k, and confirm byte-identical output at
temperature 0 at every depth.

## N. 🚨 MTP eligibility is a MATRIX — and it fails SILENTLY

Reasoning budgets and enforcement are **per family**. DSV4 0731 in particular
does it differently from Qwen/Ornith, and that changes whether MTP runs at all.

The governing rule, stated in the gate itself (`isNativeMTPPenaltyFree`,
Evaluate.swift:483-498): **anything whose logits depend on the SAMPLED HISTORY
disqualifies MTP**, because a drafted token bypasses the per-token processor.
Floors, suppress lists, budgets and penalties all qualify.

| condition | native MTP eligible |
|---|---|
| HTTP API (budget derived from `max_tokens`) | **no** |
| `VMLX_REASONING_BUDGET` env set (process-global) | **no — every surface** |
| repetition / presence / frequency penalty non-zero | **no** |
| chat UI, no env budget, no penalties | **yes** |

**CORRECTED** — an earlier draft of this table claimed the minimum-thinking
floor arms per family and killed MTP in the harness for DSV4. It does not.
`MinimumReasoningFloor.armIfNeeded` runs on every `BatchEngine.submit`
(BatchEngine.swift:477-481, 609), but its first line is
`guard let budget = configuredTokenCount else { return nil }`, and
`configuredTokenCount` reads **only** `VMLX_REASONING_BUDGET`
(ReasoningBudget.swift:99-106). Its own doc is explicit: "nothing arms by
default". So the floor is opt-in via env, or via the per-request `arm(...)`
form that the HTTP API uses — not automatic for any family.

The DSV4 references (Evaluate.swift:209, 1003) describe that model's own
enforced-low thinking behaviour, which is a separate mechanism from this gate.
**Per-family reasoning enforcement still differs — that part stands — but it is
not what disqualifies MTP in the harness.**

`DFlash2TokenIterator.swift:276` carries the parallel suppress-token check, so
dFlash-2 is gated the same way when the env IS set.

**Consequence for Qwen 27B (the current focus): in the visual harness, with no
`VMLX_REASONING_BUDGET` set and default penalties, native MTP IS eligible.**
Sampled requests are eligible too — `SpeculativeSamplingController` applies the
verifier's own temperature/top-p/top-k/min-p chain and accepts with min(1, p/q),
so the output distribution is the target sampler's token for token. Temperature
1.0 no longer excludes (that was the old silent-exclusion bug, now fixed).

**This gate has already shipped a silent-exclusion bug once.** Its own comment:

> "This is the gate that used to silently exclude every real chat session:
> bundles default to temperature 1.0, so 'MTP on' produced plain AR decode with
> no error and no log line — the exact shape of the 'MTP barely does anything'
> reports."

**Consequence for every MTP measurement in this campaign:** confirm MTP is
actually RUNNING for that bundle, on that surface, with those parameters, before
timing anything. Otherwise you A/B autoregressive against autoregressive, get a
null result, and report "MTP does not help at long context" — a false pass of
exactly the kind the testing methodology warns about. There is no log line when
the gate excludes, so the assertion has to be explicit.

Open questions this raises:
53. Should the gate LOG when it excludes? A silent fallback to AR is
    indistinguishable from MTP being slow, and has already cost this project one
    misdiagnosis.
54. Does the harness surface which decode path a turn actually used? If not, a
    user (and this campaign) cannot tell MTP from AR without instrumentation.
55. Per family: which of Ornith 9B / Ornith 35B / Qwen 27B arm a minimum
    reasoning floor by default, and at which effort settings? That determines
    which of them can benefit from MTP at all.

## O. Qwen3.8-27B + MTP (current focus) and chunked prefill

Bundles present: `Qwen3.8-27B-JANG_2D`, `-JANG_4D`, `-JANG_6D`, `-MXFP8` — the
2D/4D JANG variants named in the campaign scope.

56. Per quant (2D / 4D / 6D / MXFP8): is native MTP actually SELECTED in the
    harness? Assert eligibility first (section N), then confirm the iterator ran
    — there is no log line when the gate excludes.
57. Accept rate per quant at 2k / 8k / 16k / 32k. Does it hold with depth or
    collapse? A collapsing accept rate turns MTP into pure overhead.
58. Byte-identical output vs AR at temperature 0, at EVERY depth — the only
    acceptance criterion. A speedup that changes text is a bug.
59. Does a lower-bit draft (2D) accept worse than 4D/6D? That trades model size
    against MTP benefit and the answer decides which quant to recommend.
60. MTP + tools + reasoning effort together — the gate excludes on penalties, so
    check what the harness actually sends for a tool turn.

### Chunked prefill — apply everywhere it is safe

`chunkedPrefillEmbedding` (ChunkedPrefillVLM.swift) walks the sequence in
`prefillStepSize` chunks; the header notes `prepare` **already chunks
text-only paths**, and this covers the VLM embedding path. Falls back to a
single call when `prefillStepSize <= 0` or the sequence already fits.

61. Which model paths actually chunk today, and which still prefill in one
    shot? Enumerate per family (Ornith 9B/35B, Qwen 27B, VLM paths) rather than
    assuming the helper is wired everywhere.
62. What is `prefillStepSize` per path, and is it tuned or inherited? A step
    that is too small wastes dispatch overhead; too large defeats the purpose.
63. Does chunking change peak memory enough to avoid the paging cliff at long
    context? That is the sustained-speed argument for it — measure
    `phys_footprint`, not just wall time.
64. Does chunked prefill interact correctly with cache restore — i.e. when a
    prefix is restored and only the tail needs prefilling, is the tail chunked
    too?
65. Any correctness risk: does chunking change numerics vs one-shot prefill?
    Prove byte-identical output at temp 0 before recommending it be widened.

---

## Session 2026-08-21 — verified findings

### FIXED: decode path is now observable (P0.1 + P0.2 were one fix)

`GenerateCompletionInfo` already carried `nativeMTPStats:
NativeMTPGenerationStats?`, populated **only** when the native-MTP iterator
produced the tokens. A grep of the whole app returned **zero** uses of that
field — osaurus received the entire MTP diagnostic payload every turn and threw
it away.

That is why every MTP measurement so far has been unfalsifiable: a turn that
requested MTP and was silently excluded by `canUseNativeMTP` looked exactly like
a turn where MTP ran and did not help. Both produced a tok/s number and nothing
else.

Fixed in `GenerationEventMapper.logCompletionInfo` — the one function that
already logs completion stats — by emitting `decodePath=nativeMTP` with
`acceptedByDepth`, `avgCommittedPerVerify`, `avgAcceptProbability`,
`arFallbackTokens`, `adaptiveDownshifts`, `adaptiveFallbackReason`,
`verifierMode`, `cacheMode`, or `decodePath=plain mtp=off` when the field is
nil. Also mirrored into `PrefillDebugLog` as `STEP-MTP` so it sits alongside the
existing `STEP-STATS` / `STEP-END` cache counters in the same trace.

Purely additive instrumentation — no behavioural change, no vmlx repin.

**Honest scope:** this makes the EFFECT observable, not the REASON.
`mtp=off` covers both "the gate rejected this turn" and "MTP was never
requested". Distinguishing them requires the gate itself to report why, and the
gate (`GenerateParameters.canUseNativeMTP`, Evaluate.swift:500) lives in vmlx.
That remains open.

### The MTP gate has FIVE dispatch sites — a parity surface in itself

`canUseNativeMTP` is consulted at ChatSession.swift:458, Evaluate.swift:3745,
Evaluate.swift:4199, BatchEngine.swift:1249, and
NativeMTPTokenIterator.swift:398. **The visual harness dispatches through
BatchEngine**, so BatchEngine.swift:1249 is the site that governs everything
Eric actually sees. Any MTP change verified only through Evaluate is verified on
a path the app does not take.

Every one of these falls through to plain autoregressive in an unconditional
`else` — no error, no log. That is the silent-exclusion shape, now at least
visible after the fact.

### SwiGLU / MoE compile gating — a Codex claim CORRECTED

A parallel Codex audit implied `Qwen35.swift` compiles unconditionally while
`Gemma4.swift` is hardware-gated. **That is wrong.** Direct reading shows every
site — `safeGeluApproximate`, `compiledSwiGLU`, `compiledGeGLU`
(SwitchLayers.swift:16/46/58), `compiledSigmoidMultiply`, `compiledSigmoidGate`
(Qwen35.swift:22/35) — is preceded by `guard
HardwareInfo.isCompiledDecodeSupported else { return body }`. Codex's grep dump
showed the `compile(` line without the `guard` directly above it. Verified by
reading, not by grep.

**The real open question found instead:** all of these deliberately bypass the
compiled path when the OUTER trace is active —
`return { x in CompiledDecodeTrace.isActive ? body(x) : compiled(x) }` — because
a nested compile is illegal. The in-code justification is that "its ops are
captured into the outer graph and fused there, so there is no throughput loss."
That equivalence is **asserted, never measured**. Since compiled decode is off
by default in osaurus, the inner compiled path is the one normally taken; the
claim only matters when a user enables compiled decode, and it has never been
A/B'd.

### L2 SSD eviction janitor — audited, mostly sound, three real gaps

Confirmed by Codex and consistent with the earlier correction that the
settings→runtime mapping lives in vmlx's `cacheCoordinatorConfig`, NOT in
osaurus (grepping osaurus alone previously produced a FALSE bug report here):

- Eviction is **access-recency LRU**, not FIFO, not size-sorted, not directory
  order. Ruled out as a suspect.
- Size accounting uses **real payload file lengths** from the `cache_entries`
  table, not a shape estimate. Ruled out.
- Same-process eviction **cannot** unlink a file mid-read: `DiskCache.fetch`
  holds `MLXDiskCacheIOLock.shared` across the existence check and
  `loadArraysAndMetadata` (DiskCache.swift:372/401), and quota deletion takes
  the same lock (DiskCache.swift:596). Ruled out as a corruption source.

Real gaps, all documented rather than "fixed" — none is proven to bite live:

1. **No timer janitor exists.** Eviction runs only at init and after a store. A
   cap SHRUNK while the app is idle does not take effect until the next store.
2. **Orphan files are never reconciled.** Quota enumeration reads only
   `cache_entries` (DiskCache.swift:534) and init does not reconcile the
   directory against it (DiskCache.swift:162). A crash between the file write
   and `_insertEntryLocked` leaves an unindexed payload that counts against
   `du` forever but is invisible to the cap.
3. **The cap is a soft cap by construction** — it excludes the SQLite db, WAL,
   and directory metadata. The UI already says "Soft cap"
   (CacheSection.swift:207), so the label is accurate and this is NOT a bug.
   Noted so it is not re-reported as one.

Post-read window: `fetch` releases the IO lock before `CacheCoordinator`
validates companion state and touches recency (CacheCoordinator.swift:557), so a
concurrent quota pass could unlink that pathname during validation. It cannot
interrupt the completed read. Low severity, unproven live.

No interprocess lock exists (`OSAllocatedUnfairLock` is process-local), so two
processes sharing one cache directory are not covered.

### LIVE PROOF of the decode-path instrumentation (2026-08-21)

Rebuilt the proof app with the change, ran it against `~/models/OsaurusAI` on a
fresh test root, and drove the GUI. Three generation steps, each emitting the
new line paired 1:1 with the pre-existing ones:

    STEP-MTP   decodePath=plain mtp=off
    STEP-STATS promptTokens=3295 promptMs=1865 promptTps=1766.3 genTokens=1  genTps=3215.3 stop=length
    STEP-END   cacheAfter{prefixHits=0 prefixMisses=0 diskL2Hits=0 diskL2Misses=5 diskL2Stores=2}
    STEP-MTP   decodePath=plain mtp=off
    STEP-STATS promptTokens=3401 promptMs=278  promptTps=12228.4 genTokens=13 genTps=77.9   stop=stop
    STEP-END   cacheAfter{prefixHits=0 prefixMisses=0 diskL2Hits=1 diskL2Misses=6 diskL2Stores=7}
    STEP-MTP   decodePath=plain mtp=off
    STEP-STATS promptTokens=3415 promptMs=270  promptTps=12615.5 genTokens=1  genTps=2915.7 stop=length
    STEP-END   cacheAfter{prefixHits=0 prefixMisses=0 diskL2Hits=2 diskL2Misses=7 diskL2Stores=9}

**Honest scope:** the model in this run was not MTP-capable, so `mtp=off` is the
CORRECT answer and this proves only that the nil branch renders and pairs
correctly. The `decodePath=nativeMTP` branch with the accept-rate fields has NOT
been rendered live yet — that needs an MTP-capable bundle loaded and is the next
step.

Requires `OSAURUS_PREFILL_DEBUG=1` for the file trace (the os_log line is
`.info` level, which `log show` drops unless passed `--info`). Both were
initially read as "the line never fired" — it had.

### Two things the trace showed that were not the point of the run

Neither is a fix yet; both are now observable per turn and both bear on Eric's
long-context worry.

1. **`prefixHits=0` on every step while `diskL2Hits` climbs 0 → 1 → 2.** Reuse
   is coming entirely from the SSD tier; the in-RAM prefix tier never hit once
   in this conversation. That is the shape predicted by exact-boundary-only
   reuse, now visible live rather than inferred. It is also exactly the case
   where the resident-KV-reuse item (P0.4) would pay — the round trip to disk is
   being taken for state the process may still hold.

2. **Stores outrun hits badly: 2 → 7 → 9 stores against 0 → 1 → 2 hits.** Nine
   stores for three steps of one short conversation. Consistent with the
   already-verified defect that each boundary is written as a FULL payload
   rather than a delta (P0.3), and it means the write amplification is paid on
   every turn, growing with depth — the mechanism most likely to make SSD
   caching cost more than it saves as context grows. Worth measuring directly
   before any block-addressed redesign.

### BLOCKED: rendering the nativeMTP branch (harness issue, not a product issue)

Attempted immediately after the proof above. Relaunched against
`~/models/JANGQ-AI` (Ornith and Qwen3.8-27B live there, NOT in `OsaurusAI` —
searching the picker for "Ornith" in the OsaurusAI instance returns "No models
found", which is correct behaviour and cost a cycle to notice).

Ornith 1.0 9B was selected in the picker, but **the turn never sent**. Text
pastes into the composer fine (clipboard + Cmd-V works), but neither Return nor
clicking the send arrow dispatches it. The app sat at 0% CPU and 1.28 GB RSS —
i.e. the model was never loaded either; the green dot in the picker indicates
SELECTION, not residency.

So `decodePath=nativeMTP` with the accept-rate fields is still unrendered. This
is a GUI-driving problem, not evidence about MTP.

GUI-driving notes worth keeping, all learned this session:

- `osascript`/System Events returns **-1743 (not authorized)** against a freshly
  signed proof build. `cliclick` works instead — it posts CGEvents and does not
  need the Apple Events grant.
- A click on a newly-focused window registers as **hover only**; the second
  click acts. Every button press needs two.
- The onboarding window **moves between launches** (it appeared centre-screen
  once and right-aligned the next). Fixed coordinates from a previous run miss.
  Re-screenshot before every click.
- The launcher takes `(app, bundle-id, models-dir, fresh-test-root)` and
  **refuses a test root that already exists**, so each run needs a new one.
- `launchctl setenv OSAURUS_PREFILL_DEBUG 1` before launching is what turns on
  the file trace; the launcher's cleanup trap does not unset it, so unset it
  afterwards.

Next attempt should drive the send via a path that does not depend on the
composer's key handling, or find why the composer ignores Return under
synthetic events.

### Chunked prefill: VERIFIED SOUND for 27B (three hypotheses killed)

Checked because "chunked prefill for all models" was on the list. It is already
there for the 27B path, and the three defects I suspected are all NOT defects:

- **Does qwen3_5 text-only prefill chunk?** Yes. `Qwen35.swift:2238-2266` loops
  in `prefillStepSize` slices, gated on `inputEmbeddings == nil, pixelValues ==
  nil` — pure-text causal path only. Image/video keep one-shot deliberately,
  because mrope position ids derive from the full image grid.
- **Does the generic text path chunk?** Yes, `LLMModel.swift:59-79`, with
  "Critical for MoE models" in its own comment.
- **Is the user's `prefillStepSize` setting dead?** NO — and this was my
  hypothesis, which was wrong. `prepare(windowSize:)`'s `windowSize` parameter
  IS `parameters.prefillStepSize` (Evaluate.swift:1505, 1944, 3146;
  BatchEngine.swift:2335+; NativeMTPTokenIterator.swift:604). `windowSize ?? 512`
  therefore reads "the user's prefill step, else 512". The name is misleading —
  it is NOT the KV window — but the wiring is correct end to end.
- **Is Qwen35 inconsistent with the generic path?** No. Both use the identical
  `windowSize ?? 512` expression (`Qwen35.swift:2238`, `LLMModel.swift:25`).

So there is no chunked-prefill fix to make for 27B. What remains is a TUNING
question, not a correctness one, and it must be measured before it is touched:

**`MLX.Memory.clearCache()` runs once per chunk** (`Qwen35.swift:2264`,
`Gemma4.swift:1338`, `NemotronHOmni.swift:246`, `LLMModel.swift:79`). At a
32k prompt with the 512 default that is ~64 pool flushes, each forcing
reallocation on the next chunk. It bounds peak memory — which is the thing that
decides whether a 27B at long context stays inside the Metal working set or
falls off the paging cliff — so removing it could easily be a large net LOSS.
Do not touch it without a hot ABAB at a FIXED prompt length with `phys_footprint`
logged per leg. Added as a measurement item, not a fix.

### 27B is genuinely MTP-capable — all four quants ship the weights

Checked because "27B + MTP" is a stated priority and a declared-config-without-
weights bundle is a known trap. All four of `Qwen3.8-27B-{JANG_2D, JANG_4D,
JANG_6D, MXFP8}` declare `mtp_num_hidden_layers = 1` and
`mtp_use_dedicated_embeddings = False`, and each ships **31 MTP weight tensors**
(`mtp.fc.{weight,scales,biases}`, `mtp.layers.0.*`) in its safetensors index.
model_type `qwen3_5` / `qwen3_5_text`, 64 layers, dense (not MoE — `num_experts`
is null; the MoE 256/8 config belongs to the 35B `qwen3_5_moe`).

So depth-1 native MTP is available on every 27B quant, and the accept-rate
fields the new `decodePath=nativeMTP` line carries will have something to report
as soon as the harness can be driven.

### BLOCKER for the extreme-multiturn growing-context run

The requested test — drive context up as far as it goes while watching store /
eviction / rotation — can only be done through the GUI harness. Right now it
cannot be driven **in the background**:

- `System Events` returns **-1743 (not authorized)**, so no AX-based background
  driving. The calling process is `claude`.
- The only working input path is `cliclick`, which posts to whatever is
  frontmost — it steals focus and collides with the user's own typing. Observed
  directly: the composer picked up text the user was typing, and sends became
  unreliable because focus was being traded back and forth.
- The API/curl and RunBench routes are both explicitly out of bounds.

Unblock is a one-time grant: System Settings → Privacy & Security → Automation →
allow the terminal running `claude` to control **System Events**. Until then,
harness-dependent items stay open and only source-level work can proceed.

### PINPOINTED: the 10 GB disk-cache default cannot hold one 27B conversation

Question asked: is SSD-cache slowness at depth just bad user hardware, is the GB
cap too small, or is it a RAM safety rule?

**It is not a RAM safety rule.** The default is a flat literal:
`let diskMaxGB = Float(diskMaxSizeGB ?? 10.0)`
(ServerRuntimeSettings.swift:21 and :840). Nothing derives it from RAM, from
disk capacity, or from the model. The osaurus UI ships it blank and its own
placeholder says so: "Blank = engine default (10 GB)"
(CacheSection.swift:208-210). And the cap is enforced across the WHOLE
persistent cache root, not per model (CacheCoordinator.swift:1088), so every
model the user has ever run shares the same 10 GB.

**The arithmetic, for Qwen3.8-27B** (config: 64 layers, 4 KV heads, head_dim
256):

    per token = 64 * 4 * 256 * 2 (K and V)
              = 256 KiB/token at bf16
              = 128 KiB/token at fp8

    10 GB cap holds  ~41k tokens (bf16)  /  ~82k tokens (fp8)  -- TOTAL, all models
    27B context window                    222k tokens
    one FULL-context conversation needs  ~54 GB (bf16) / ~27 GB (fp8)

So the shipped cap cannot hold a single full-context conversation of the 27B.
It tops out around 18% of one window at bf16. Past that point every store must
evict earlier boundaries of the SAME conversation, so reuse collapses precisely
as context grows — which is the reported symptom.

For comparison, oMLX (installed at /Applications/oMLX.app, sources readable
under Contents/Resources/omlx) defaults `ssd_cache_max_size = "auto"`, defined
as **10% of SSD capacity** (settings.py:246, :274); its non-auto default is
`"100GB"` (config.py:110). On this machine 10% of a 3721 GB volume is ~372 GB —
roughly 37x our default.

**What this does NOT explain — stated so it is not over-claimed.** The live
trace earlier in this document showed 9 stores against 2 hits on a conversation
of a few thousand tokens, nowhere near 10 GB. The cap cannot be the cause of
those misses. Two distinct mechanisms are in play and they must not be
conflated:

1. **Early misses at shallow depth** — not a capacity problem. Candidates remain
   the exact-boundary-only matching and the full-payload-per-boundary store.
2. **Collapse at depth** — this is where the 10 GB cap bites, and the arithmetic
   above says it must bite well before the model's own context limit.

**Status: strongly-supported hypothesis, NOT yet measured.** It rests on config
arithmetic and source reading. The confirming test is a growing-context multiturn
run with `du` on the cache dir and the evicted-boundary counter sampled per turn,
watching for the turn where evictions begin and hits fall off. That run is
currently blocked on background GUI driving.

**Recommended change, deliberately not made unilaterally:** the default should
scale with available disk rather than being a flat 10 GB, because a cache that
cannot hold one conversation of the flagship model is a feature that mostly does
not work. This is a disk-consumption policy for other people's machines, so the
ceiling is the user's call, not mine. It is a one-line default.

### Reference points for "is this fast or slow"

Measured on this machine, so there is something to compare against:

- Gemma-class 26B, cold prompt: **1766 pp/s** prefill, first token ~1.9s at 3.3k
  tokens.
- Same model, warm/partially reused: **12228 pp/s** prefill (270-514 ms for
  ~3.4k tokens), decode **77.9 tok/s**.
- DSV4-Flash (recorded earlier, settled machine): 443 pp/s at 8K, 332 at 16K,
  231 at 32K; decode ~29 tok/s and depth-invariant.

The 6-25x gap between cold and warm prefill is the entire value of the cache.
That is the number a too-small cap destroys at depth.

### OPEN NEEDS from 2026-08-21 (cache pool), with status

**N1. Existing users must also get the 10% default — NOT just fresh installs.**
STATUS: NOT DONE. The auto resolver only fills in for a nil setting. Any install
whose `server-runtime.json` already persists an explicit `maxSizeGB: 10.0` keeps
10 GB forever after upgrading, which is most of the existing fleet if the value
was ever written out.

There is no persisted schema version to migrate against:
`VMLXServerRuntimeSettings.contractVersion = 1` exists at
ServerRuntimeSettings.swift:12 and is **referenced nowhere else in the package** —
a dead constant, never encoded, never compared.

Required work: persist a settings schema version, and on load, when the stored
version predates the auto change AND `maxSizeGB` is exactly the old 10.0
default, reset it to nil so it resolves to auto. Must be a versioned one-shot,
not "rewrite any 10.0 we see" — a user who deliberately picks 10 GB after the
migration must keep it. Same shape as the MTP-Off migration defect: the fix is a
schema version plus a user-selected marker, never deleting the migration.

**N2. Eviction must also drop the oldest OTHER model's cache.**
STATUS: ALREADY TRUE — verified, not assumed. `DiskCache.quotaEntries()` is
`SELECT hash, file_size, created_at FROM cache_entries` with **no model_key
predicate** (DiskCache.swift:544), so the quota pass enumerates every model's
entries in the shared root. `enforceCombinedDiskQuotaLocked` then sorts all
groups by `priority`, then `createdAt` ascending (CacheCoordinator.swift ~1197)
and evicts from the oldest end. So a stale bundle's checkpoints are reclaimed
before a hot bundle's. No change needed; recorded so it is not re-investigated.

**N3. Drive the harness via AppleScript, in the background, not the foreground.**
STATUS: BLOCKED on a permission only the user can grant. `System Events` returns
`-1743 Not authorized` for the `claude` process, so there is no AX path and no
background driving. The only working input is `cliclick`, which posts to the
frontmost window and therefore steals focus and collides with the user's own
typing. Grant needed: System Settings → Privacy & Security → Automation → allow
the terminal running `claude` to control System Events.

Partial mitigation already applied: screen captures are now scoped to the app's
own window via `screencapture -l <windowID>` instead of full-screen. Window IDs
come from a small CoreGraphics helper (`/tmp/winid.swift`) since PyObjC is not
installed. Full-screen capture had been photographing unrelated work, including
a page with API tokens on it — do not go back to it.

**N4. Live proof of the whole cache story.** STATUS: NOT DONE. Needed: multiturn
Qwen 27B, cache growing toward the cap, the footer bar climbing, the 75% warning
appearing, the janitor evicting at the limit, changing the size limit in
Settings and seeing the new limit enforced, and no Qwen regressions across the
run. Blocked behind N3 for background driving, and behind the repin below for
the auto value.

**N5. The auto default cannot reach the app yet.** osaurus pins vmlx by revision
from `github.com/osaurus-ai/vmlx-swift`, and the local clone's push URL is
deliberately `DO_NOT_PUSH_vmlx_local_only_fork_do_not_push_anywhere`. The auto
commit therefore has to land on the vmlx remote before osaurus can repin. Until
then the app runs the old flat 10 GB and the new footer bar will faithfully
display that 10 GB — the UI is correct, the value behind it is stale. This is
why Settings still reads 10 GB.

### Still not measured

The cache ON vs OFF depth curve remains the one measurement that answers Eric's
actual question, and nothing above substitutes for it. Component timings cannot
produce a crossover depth.

---

## Method

Every claim proven live in the running dev app GUI, never by curl and never by
unit test alone. Per-turn variation is mandatory — no plain follow-ups. Record
passes AND fails. Fix and merge one item at a time.
