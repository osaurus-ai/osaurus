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
- A chat you have been toggling settings in is a CONTAMINATED fixture. Open a
  new conversation before judging degenerate output.
- Store/fetch must use the SAME tier. Healthy stores + 100 % misses is a tier or
  key mismatch, not a coherence bug.
- Log STATE (resume_at, flags, counters). Never grep for your own log marker and
  conclude "the branch never runs".

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

## Method

Every claim proven live in the running dev app GUI, never by curl and never by
unit test alone. Per-turn variation is mandatory — no plain follow-ups. Record
passes AND fails. Fix and merge one item at a time.
