# Gemma 4 12B MXFP8 — speed / RAM / CPU / KV baseline

First committed perf baseline for `OsaurusAI/gemma-4-12B-it-MXFP8`, capturing
all five requested metrics — TTFT, decode tok/s, prefill tok/s, peak physical
RAM, host CPU%, and KV-cache reuse — per the `AGENTS.md` rule that every
generation row records token/s and peak physical footprint stays within the
intended low-RAM envelope. This is the before-snapshot that every Phase-3
optimization diffs against.

- **Date:** 2026-06-20
- **Model:** `OsaurusAI/gemma-4-12B-it-MXFP8` (local MLX; JANG MXFP8, 328
  per-layer quant overrides at bits=8/gs=32 + a tied embedding head at
  bits=6/gs=64).
- **Host:** Apple M4 Pro, 14 cores, 48 GiB (`totalRamMb=49152`), macOS 26.2.0.
- **Commit:** `f5e2ff97`. **Catalog hash:** `94b0827c8337d35a`.
- **Suite:** `Suites/AgentLoop` (full 17-case run).
- **KV regime:** `memory-only` (`OSAURUS_EVALS_KV_REGIME=memory-only`). The
  disk-L2 lane is forced off via the documented unwritable-dir degradation in
  `ModelRuntime.buildCacheCoordinatorConfig` (see "KV regime" below); the
  in-memory prefix lane stays on. Verified: `~/.osaurus/cache/kv_v2` stayed
  absent / 0 B for the whole run.
- **Judge:** self-judge (no strong-judge key in the run env). 16/17 cases are
  OUTCOME-scored (file state + command exit codes + loop assertions), so their
  verdicts are judge-independent; only `wrap-up-on-budget` is rubric-judged and
  its verdict is therefore lower-confidence here (re-judge with `xai/grok-4.3`
  in the quality phase). NONE of the five perf metrics depend on the judge.
- **Sampling:** greedy (`temperature: 0.0`, `AgentLoopEvaluator`) for
  deterministic scoring; the bundle's native `generation_config.json`
  (`temperature 1.0`, `top_k 64`, `top_p 0.95`) is the chat/API default and is
  a Phase-3 wiring check, not the eval-scoring sampler.
- **Telemetry source:** in-band `StreamingStatsHint` → `AgentLoopTranscript` →
  `EvalCaseTelemetry` (decode/prefill/TTFT/tokens); peak RAM + CPU% from
  `ResourceSampler` over `ProcessMemoryProbe` (phys_footprint) and
  `ProcessCpuProbe` (`getrusage` user+system); KV deltas from
  `ModelRuntime.batchDiagnosticsSnapshot()` before/after each case.
- **Artifacts:** `reports/perf-baseline-gemma4-12b-mxfp8/full-suite/`
  (`gemma4-12b-mxfp8-AgentLoop.json` + `run.log`), local / git-ignored.
- **Wall clock:** ~37 min (dominated by the long multi-step cases below).

## Scoreboard — memory-only KV (pure compute baseline)

| case | verdict | decode tok/s | prefill tok/s | TTFT ms | peak RAM MB | CPU% mean/peak | tok |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `batch-error-isolation` | pass | 15.8 | 246 | 3067 | 5703 | 25 / 198 | 322 |
| `capabilities-load-midrun` | pass | 15.5 | 232 | 64 | 5425 | 21 / 107 | 149 |
| `clarify-on-ambiguity` | pass | 15.7 | 223 | 73 | 5794 | 25 / 108 | 106 |
| `compaction-stress` | **fail** | 14.2 | 220 | 55 | 5970 | 58 / 119 | 2207 |
| `dedupe-replay-fires` | **fail** | 16.2 | 220 | 79 | 5757 | 22 / 104 | 256 |
| `duplicate-call-avoidance` | **fail** | 16.6 | 228 | 55 | 5503 | 22 / 106 | 247 |
| `edit-file-then-verify` | pass | 16.6 | 224 | 69 | 5501 | 21 / 111 | 266 |
| `listing-navigation-discipline` | **fail** | 16.8 | 222 | 70 | 5649 | 20 / 88 | 120 |
| `over-budget-hard-overflow` | pass | — | — | — | 4370 | 1 / 2 | 0 |
| `parallel-batch-reads` | pass | 16.7 | 224 | 71 | 5756 | 20 / 108 | 293 |
| `recover-from-failing-command` | pass | 16.6 | 222 | 72 | 5865 | 22 / 108 | 409 |
| `rejection-stops-run` | pass | 16.7 | 224 | 71 | 5682 | 19 / 109 | 55 |
| `repeated-call-nudge` | pass | 16.6 | 225 | 70 | 5904 | 22 / 112 | 329 |
| `search-then-multi-file-edit` | **fail** | 16.3 | 220 | 51 | 5970 | 19 / 106 | 623 |
| `todo-discipline-multistep` | **fail** | 15.9 | 217 | 65 | 5518 | 24 / 109 | 708 |
| `wrap-up-on-budget` | **fail*** | 16.0 | 213 | 74 | 5796 | 22 / 95 | 154 |
| `write-new-file` | pass | 16.0 | 213 | 69 | 5422 | 22 / 114 | 154 |

`*` `wrap-up-on-budget` is the only rubric-judged case; its verdict is
self-judged here (lower confidence). `over-budget-hard-overflow` exits before
any decode (hard budget gate), so it honestly records no decode/prefill/TTFT —
nil, not zero — but still captures peak RAM + CPU.

## Suite-wide aggregates (memory-only)

| metric | mean | min | max | n |
| --- | ---: | ---: | ---: | ---: |
| decode tok/s | 16.1 | 14.2 | 16.8 | 16 |
| prefill tok/s | 223 | 213 | 246 | 16 |
| TTFT ms | 255 | 51 | 3067 | 16 |
| peak RAM MB | — | 4370 | 5970 | 17 |
| CPU % | 23 (mean) | — | 198 (peak) | 17 |
| KV prefix hit/miss | 0 / 0 (suite-wide delta) | | | 16 |

**Pass rate: 10 / 17 (59%)** — self-judged; 16/17 verdicts are outcome-scored
and judge-independent.

## What each metric says (the bar to beat in Phase 3)

- **decode ~16 tok/s, steady (14.2–16.8).** Healthy for a 12B MXFP8 model on an
  M4 Pro (~273 GB/s): MXFP8 moves ~2× the bytes/token of MXFP4 and the M4 Pro
  has ~half the bandwidth of an M5 Max, so ~16 tok/s tracks the published
  M5-Max MXFP4 12B number (48.6 tok/s) scaled for bytes×bandwidth. The slowest
  row, `compaction-stress` (14.2), pays the memory-only re-prefill tax on a
  growing ~multi-KB context.
- **TTFT is bimodal: 3067 ms cold vs ~51–79 ms warm.** The first case per
  process pays a one-time MLX **JIT Metal-kernel compilation** cost: the JANG
  layout instantiates many distinct quantized-matmul kernel variants
  (`QuantizedMatmul::eval_gpu → get_quantized_kernel → Device::get_library`),
  compiled on first prefill. Every subsequent case reuses the in-process
  kernels → ~60–80 ms TTFT. **This cold-start TTFT is the single biggest
  per-process TTFT lever** (see Candidate targets).
- **prefill ~223 tok/s, steady.** Cold prompt-processing throughput (no served
  prefix in memory-only with no cross-case reuse).
- **peak RAM 5.4–5.97 GB.** Within a sane low-RAM envelope for a 12B model
  (eval-process phys_footprint, which includes the Swift/MLX runtime + harness,
  so it's an upper bound on the model's own residency). No row approached full
  model size. `over-budget-hard-overflow` sits at 4370 MB (no decode).
- **CPU mean 23% / peak 198%.** Decode is GPU-bound, so this is HOST overhead
  (tokenizer, sampler, JSON, stream plumbing, harness). The 198% peak is the
  cold first case — JIT kernel compilation runs on CPU across ~2 cores.
  `compaction-stress` mean 58% reflects sustained host work over its 2207-token,
  4.8-min run. A high steady value would be an optimization target; 23% mean is
  reasonable.
- **KV reuse +0 hit / +0 miss / +0 SSM (suite-wide, this baseline regime).**
  Honest for memory-only: disk-L2 is off, so the cross-iteration reuse lane is
  disabled and there is nothing to count — not a measurement gap. The deltas
  POPULATE (0, not nil) for 16/17 cases, proving the readout works; the first
  case is nil because the batch-diagnostics snapshot isn't resolved until the
  model is warm. Two things were later proven about this 0: (a) the *paged*
  counter is 0 **by design** for Gemma-4 (paged-incompatible rotating-window
  topology, Lever 1), and (b) turning ON the *disk-L2* lane with a bounded cap
  makes reuse provably fire (`+12 disk-L2 hit`) and cuts long-case wall 3.6×
  (Lever 5 — the KV win).

## KV regime — how "memory-only" is enforced (and why it's honest)

The vmlx resolved memory-safety plan couples the prefix and disk lanes: when
`cache.prefix.enabled` is true it FORCES `cache.blockDisk.enabled = true`
(`ServerRuntimeSettings.resolvedMemorySafetyPlan`). So "prefix-on + disk-off"
cannot be expressed by toggling the `.enabled` flag — the resolved plan
overwrites it. The supported, documented way to get memory-only (same as the
Qwen `perf-ram-baseline.md`) is to make the disk-KV directory **unwritable**,
which trips `buildCacheCoordinatorConfig`'s `!diskDirUsable → enableDiskCache =
false` degradation while leaving the in-memory prefix lane on. The eval CLI does
this process-locally: `OSAURUS_EVALS_KV_REGIME=memory-only` redirects
`blockDisk.directory`/`legacyDisk.directory` to an unwritable sentinel
(`/dev/null/...`) via `ServerRuntimeSettingsStore.overrideSnapshotInMemory`,
never persisting to the user's saved settings. Confirmed live: `kv_v2` stayed
0 B and the `L2 +Nhit/+Nstore` telemetry line disappeared.

## Failures (7) — evidence-based attribution

Read from the run JSON's per-case `summary`/`exit`/tool-usage. 16/17 cases are
OUTCOME-scored (judge-independent); only `wrap-up-on-budget` carries a rubric,
and its OUTCOME gate fails on its own regardless of the judge. **All seven are
model-capability (agentic-discipline) ceilings — none is an eval bug or a
runtime defect.** Two failure shapes:

**A. Hit the iteration cap (never converged) — `exit=iterationCapReached`:**

| case | iters | decisive evidence |
| --- | ---: | --- |
| `search-then-multi-file-edit` | cap | `file_search ×18 (17 deduped, 1 err)` then capped — pathological identical-search loop, never reached the multi-file edit. The standout small-model failure. |
| `dedupe-replay-fires` | 6 | `[todo,file_read,todo,file_read,todo,share_artifact]` — burned iterations cycling todos, didn't produce a final response before the cap. |
| `wrap-up-on-budget` | 5 | budget notices fired at 3/2/1 remaining; model ignored the wrap-up nudge and was cut off at the cap instead of `finalResponse`. |

**B. Finished (`exit=finalResponse`) but missed a content/discipline assertion:**

| case | iters | decisive evidence |
| --- | ---: | --- |
| `compaction-stress` | 4 | only `[todo,file_read,file_read]` — answered after **2 of the required 5 reads**, so the sticky-compaction path/expected summary was never satisfied (premature wrap-up). |
| `duplicate-call-avoidance` | 6 | `todo ×4` — issued redundant duplicate `todo` calls, the exact anti-pattern the case asserts against. |
| `todo-discipline-multistep` | 12 | did the edits (`file_edit ×3`,`file_read ×3`) but missed the checklist-discipline assertion (ordering / carried-checked-box). |
| `listing-navigation-discipline` | 4 | `[todo,file_read,todo,complete]` — navigation/listing-discipline assertion missed. |

These overlap the known small-model agentic-discipline / synthesis headroom set.
Per `AGENTS.md` they are honest model-capability rows, not masked — and Phase 4
confirms it: **grok-4.3 passes all 17 under identical eval logic**, so every one
of these is achievable, not an eval bug. `wrap-up-on-budget`'s Gemma failure is
an OUTCOME failure (`iterationCapReached`), judge-independent; grok passes the
same case.

## Harness notes discovered while capturing this baseline

- **Disk pressure tanks decode.** At 98% used / 21 GiB free, mmap page-in of the
  ~12 GB model during decode was pathologically slow (a single case ran >15 min,
  weights never resident). Freeing `~/Library/Developer/Xcode/DerivedData`
  (16 GB → 37 GiB free / 96%) restored normal speed. Mirror the Qwen doc's
  healthy-host requirement: capture baselines with ample free disk.
- **Full-suite stdout is batched/buffered.** The eval prints `[PASS]/[FAIL]`
  lines as a block at the END of the run, and per-case `[Osaurus][Stream]` tool
  lines are block-buffered when stdout is a pipe (vs. line-buffered on a tty).
  A long full-suite run therefore looks "hung" with no visible output for many
  minutes even while progressing normally. Run under a pty (`script -q`) to see
  live per-tool progress. (No code defect; a monitoring gotcha.)
- **No persistent MLX JIT kernel cache** in `~/Library/Caches/mlx` etc.; the
  per-user `…/com.apple.metal/` archive helps, but the JANG quantized-matmul
  variants are JIT-compiled on each fresh process's first prefill — the cold
  TTFT above.

## Candidate targets (emerge from this baseline)

1. **Cold-start TTFT (~3 s → ~50 ms). LANDED ✅ (Phase 3 Lever 4).** The
   first-prefill JIT kernel compilation was the dominant cold TTFT cost.
   Fixed by `ModelWarmup.warmUp` (warm-on-load): compile the kernels off the
   request path. First-request TTFT 3697 → 50 ms (74×), suite-mean 255 → ~68 ms.
   Remaining sub-lever: cross-process kernel cache for one-shot CLI cold starts.
2. **KV reuse across loop iterations. LANDED ✅ (Phase 3 Lever 5).** The long
   multi-step cases re-prefill a growing context every step under memory-only.
   Bounded disk-L2 reuse (the only lane Gemma-4's rotating-window topology can
   use — see Lever 1) makes `todo-discipline-multistep` **3.6× faster wall**
   (303 → 84 s) with the reuse counter provably non-zero (`+12 disk-L2 hit`),
   decode flat, and disk bounded by a 4 GB cap. Remaining sub-lever: a lower
   default `blockDisk.maxSizeGB` for big-model hosts (the 10 GB default is the
   Lever-2 hazard).
3. **memory-only vs disk-L2 A/B.** Now that disk is free, measure the
   decode/TTFT/RAM tradeoff of the disk-L2 lane on a representative subset.
4. **Native `generation_config.json` wiring.** Confirm chat/API defaults resolve
   the bundle's `top_k=64 / temp=1.0 / top_p=0.95`, not synthetic defaults.
5. **Host CPU hot path.** 23% mean is reasonable; if a lever pushes it up, trace
   tokenizer/sampler/stream-parsing cost.

## Phase 3 — optimization A/B results (one lever at a time)

Each lever flips one setting, re-runs the SAME cases, and diffs all five
metrics. Per `AGENTS.md`, a lever is kept only if it's a real win; "the shipped
default is best" is a legitimate, recorded outcome. The new
`OSAURUS_EVALS_PAGED_KV=on|off` knob (process-local, never persisted) makes the
paged lane A/B-able.

### Lever 1 — paged-KV ON vs OFF (memory-only, 4-case multi-step subset)

Subset: `parallel-batch-reads`, `recover-from-failing-command`,
`repeated-call-nudge`, `todo-discipline-multistep` (same case order both arms ⇒
identical cold-start). Both arms memory-only, so the ONLY difference is
`cache.pagedKV.enabled`.

| metric | paged-OFF (default) | paged-ON | delta |
| --- | ---: | ---: | --- |
| decode tok/s (mean) | 15.47 | 15.82 | +0.35 (≈noise) |
| total wall | 685 s | 745 s | +60 s (agentic step-count variance) |
| peak RAM (max) | 5931 MB | 5821 MB | ≈flat |
| CPU % (mean) | 23 | 23 | flat |
| KV prefix hit/miss (Σ) | 0 / 0 | **0 / 0** | unchanged |

**Result: no win — keep paged-KV OFF for Gemma-4.** Enabling
`pagedKV.enabled=true` neither improved any metric nor made the prefix-hit
counter non-zero.

**Root cause (corrected 2026-06-20 — the earlier "counter can't observe reuse
on this route" claim was imprecise; the real path was traced end-to-end):**
the paged tier is *structurally inapplicable to Gemma-4*, by design. The
telemetry IS correctly wired — `ModelRuntime.batchDiagnosticsSnapshot()` →
`Registry.snapshotDiagnostics()` reads `holder.container.cacheCoordinator
?.snapshotStats()`, the **same** coordinator instance the decode `BatchEngine`
captures via `container.makeBatchEngine` — so a real paged hit WOULD surface.
It reads 0 hit / **0 miss** because the paged tier is never *consulted*:

1. Gemma-4's cache is **heterogeneous** — sliding-window `RotatingKVCache`
   layers mixed with full-attention `KVCacheSimple` (vmlx
   `BatchEngine.swift:2144-2197`).
2. At slot admission, `cacheRequiresDiskBackedCoordinatorRestore(cache)` returns
   true (it contains `RotatingKVCache`; `CacheHelpers.swift`) so `BatchEngine`
   flips the coordinator to **`isPagedIncompatible = true`**
   (`BatchEngine.swift:1405-1411`). The code comment: *"PagedCacheManager stores
   per-block full-history KV tensors … cannot encode rotating/sliding-window
   ring metadata … the v2 disk serializer is therefore the correct restore
   mechanism for these models."*
3. `CacheCoordinator.fetch` then sets `skipPaged = isPagedIncompatible`
   (`CacheCoordinator.swift:352`), so `pagedCache.fetchPrefix(...)` is **never
   called** → `cacheHits`/`cacheMisses` stay at 0/0 (the hit/miss counters live
   *inside* `fetchPrefix`). Zero **misses** is the tell: a consulted-but-empty
   tier would log misses.

So the 0/0 is **honest and by-design**, NOT a measurement gap and NOT a reuse
failure. **Empirical confirmation:** in the Lever-5 disk-L2 run below, cross-
iteration reuse provably fires (`KV disk-L2 +12 hit`) while
`kvPrefixHitsDelta` *still* reads 0 — i.e. paged is bypassed even when reuse is
active. **Gemma-4's only cross-iteration prefix-reuse lane is the disk-L2 v2
serializer** (which tags every layer kind incl. `.rotating`). That is the lever
that actually moves the needle — see **Lever 5**. (The `OSAURUS_EVALS_PAGED_KV`
knob remains valid for pure full-attention families where paged is applicable.)

### Lever 2 — memory-only vs disk-L2 (first attempt ABORTED on disk hazard → RESOLVED in Lever 5)

First attempt of the disk-L2 arm on the 4-case subset. The disk-L2 block lane's
resolved-default cap is `maxSizeGB = nil → 10 GB` (`cacheCoordinatorConfig`:
`Float(diskMaxSizeGB ?? 10.0)`), and on Gemma 12B MXFP8 it wrote
`~/.osaurus/cache/kv_v2` to **9.6 GB in ~90 s** (≈6–9 GB/min) — i.e. it raced
toward that 10 GB ceiling before eviction kicked in, dropping free space from
37 → 27 GiB. On a host without tens of GB of headroom that ceiling is too high
and recreates the disk-pressure decode collapse documented above, so the arm was
**killed for safety** (disk reclaimed cleanly). **Finding:** the *default* 10 GB
cap is too high for a constrained host — not "uncapped", but effectively so for
this volume. The fix is a **lower** cap. `DiskCache._evictIfNeededLocked` runs
**synchronously after every store** (evicting oldest-first until under the cap),
so a small cap bounds growth to ≤ cap + one entry. This unblocked the real
A/B — see **Lever 5**, which runs disk-L2 safely at a 4 GB cap (peaked at 3.8 GB)
and is the first lever to make cross-iteration reuse provably fire on Gemma-4.

### Lever 3 — grok judge re-verification (resolved: not a hang)

The earlier suspicion that the `xai/grok-4.3` auto-judge "hangs" is **false**.
A single rubric case (`wrap-up-on-budget`) run with `XAI_API_KEY` set completed
in **77 s total**; the provider connect returns immediately. The earlier
multi-minute "stall" was the stdout-buffering artifact (per-case lines flush at
process exit), not the judge. NOTE: the provided key is **invalid**
(`HTTP 400: Incorrect API key provided`), so the judge calls fell through to
`Model 'xai/grok-4.3' is not installed` — the Phase-4 quality comparison is
blocked on a valid key, not on any hang.

### Levers not separately A/B-run (with rationale, not skipped silently)

- **TurboQuant-KV:** policy-disabled for ALL families
  (`ModelRuntime.shouldUseTurboQuantByDefault`, Eric directive 2026-06-12 — the
  per-step compress/decompress cost outweighs RAM savings). Force-enabling it
  would contradict the shipped contract; no decode win expected. Not changed.
- **`defaultMaxKVSize` / `longPromptMultiplier`:** these cap the KV ceiling
  (peak-RAM-vs-max-context), not steady-state decode/TTFT at the short contexts
  these cases use (≤2.2 K tokens). Out of band for this subset; the resolved
  `safe_auto` plan already sets `defaultMaxKVSize=65536`.
- **Native `generation_config.json`:** eval scoring is greedy
  (`temperature 0.0`) by design for determinism; the bundle's
  `top_k 64 / temp 1.0 / top_p 0.95` is the CHAT/API default, a wiring check
  (resolved from the bundle, not synthetic), not an eval-scoring perf lever.
- **Host CPU hot path:** mean 23% is healthy for GPU-bound decode; the only
  spike is the cold-start JIT (peak ~198% on the first case). No steady-state
  hot path to cut without a profiler pass.

### Lever 4 — warm-on-load eliminates cold-start TTFT (LANDED ✅)

The baseline's #1 candidate target. Instead of the (hard, MLX-level) cross-process
kernel cache, this lands the **in-process** fix a real inference server uses:
compile the JIT'd quantized-matmul kernels with one tiny throwaway generation the
moment a bundle becomes resident, BEFORE the request path. New real runtime API
`ModelWarmup.warmUp(modelId:)` (`Services/ModelWarmup.swift`) — idempotent per
(process, model), best-effort, local-only, latency-only (output discarded; never
touches sampling/parsing). Wired into `EvalRunner` inside the `withSelection`
scope so every scored case measures the warm steady-state a running server
delivers; `OSAURUS_EVALS_DISABLE_WARMUP=1` reproduces the old cold-start for the
A/B.

Same-binary A/B, 2-case subset (`--filter call` →
`duplicate-call-avoidance`, then `repeated-call-nudge`; identical order/config,
the ONLY difference is the warm-up):

| metric | warm-up OFF (old) | warm-up ON (new) | delta |
| --- | ---: | ---: | --- |
| **first-case TTFT** | **3697 ms** (cold JIT) | **50 ms** | **−98.6 % (74× faster)** |
| 2nd-case TTFT (already warm) | 72 ms | 54 ms | ≈flat (warm both) |
| suite mean TTFT | 1885 ms | **52 ms** | **−97 %** |
| decode tok/s (mean) | 16.1 | 15.5 | ≈flat (±noise) |
| prefill tok/s (mean) | 211 | 243 | +32 (no cold row dragging it) |
| peak RAM MB (max) | 5871 | 5896 | ≈flat |
| CPU % mean / peak | 25 / 193 | 25 / **126** | peak ↓ (JIT spike moved to warm-up) |
| outcomes (dup-call / repeated) | fail / pass | **fail / pass** | **unchanged** |

The warm-up logged `elapsedMs=3922` — i.e. it absorbed the full ~3.9 s one-time
JIT into a pre-request phase, off the measured/served path. **Outcomes are
identical across arms** (the only token-count jitter is ordinary run-to-run
agentic + MLX-numerical variance, present between any two repeats), confirming the
change is latency-only and not eval-gaming: warm-up cannot change what the model
emits because the scored requests run on the same deterministically-compiled
kernels and the same greedy sampler.

**Result: kept — warm-on-load is a real win on the #1 TTFT lever.** Extrapolated
to the full 17-case suite (only the single cold first case changes,
3067 → ~52 ms): **suite mean TTFT 255 → ~68 ms (3.7×)**, worst-case
(first request) **~3.1 s → ~50 ms (≈60×)**.

**Honest scope of the win:** this is the *server/agentic* workload (load once,
serve many requests — exactly what the benchmark and the Osaurus HTTP/chat server
are). A fresh **one-shot CLI** process still JITs on its single request; making
*that* fast still needs the cross-process MLX kernel cache (deeper follow-up).
**App adoption is a product decision, not landed here:** chat deliberately loads
lazily (on first message, not on model *select*) to avoid loading a 12 GB bundle
the user is only previewing, so warming eagerly trades RAM/battery/eagerness.
The clean adoption points are **warm-on-model-select** (user signalled intent) and
the **keep-resident/server preload** path (residency already paid) — wiring either
is a deliberate UX call, deferred to the owner rather than silently changing
startup.

### Lever 5 — bounded disk-L2 cross-iteration reuse (LANDED ✅, the KV win)

Candidate target #2. Gemma-4's **only** cross-iteration prefix-reuse lane is the
disk-L2 v2 serializer (Lever 1 root cause: paged is structurally bypassed for
its rotating-window topology). The blocker was the disk hazard (Lever 2); the
fix is a **bounded cap**. New process-local knob `OSAURUS_EVALS_DISK_L2_CAP_GB`
(`EvalBootstrap`) sets `cache.blockDisk.maxSizeGB`, which flows to
`DiskCache.maxSizeBytes` and is enforced **synchronously after every store**
(`_evictIfNeededLocked`, oldest-first) — so a small cap is safe.

A/B on the **longest multi-step case** `todo-discipline-multistep` (the case
that re-prefills a growing context every step), warm-up ON both arms, the ONLY
difference is the disk-L2 reuse lane. Fresh `kv_v2` before each arm:

| metric | memory-only (no reuse) | disk-L2 (cap 4 GB) | delta |
| --- | ---: | ---: | --- |
| **wall (case latency)** | **303.2 s** | **83.6 s** | **−72 % (3.6× faster)** |
| **KV disk-L2 reuse** | none (lane off) | **+12 hit / +13 store / +15 miss** | reuse **PROVEN** |
| decode tok/s | 15.3 | 15.5 | ≈flat (reuse ≠ decode) |
| decode tokens emitted | 565 | 769 | B emitted MORE, still 3.6× faster |
| decode time (tok ÷ rate) | 36.9 s | 49.6 s | +12.7 s |
| **non-decode (≈prefill) time** | **266.3 s** | **34.0 s** | **−87 % (the win)** |
| TTFT ms | 59 | 53 | ≈flat (warm both) |
| peak RAM MB | 5567 | 6314 | +747 (disk-restore buffers) |
| CPU % mean / peak | 22 / 109 | 48 / 160 | ↑ (disk deserialize/restore) |
| `kvPrefixHitsDelta` (paged) | 0 | **0** | confirms paged bypassed |
| disk `kv_v2` peak | 0 (off) | **3.8 GB** | under the 4 GB cap ✅ |
| outcome | fail | **fail** | **unchanged** (capability ceiling) |

**Result: kept — bounded disk-L2 reuse is a real win on long agentic cases.**
The whole 3.6× is in **non-decode time** (266 → 34 s): arm B decoded *more*
tokens (769 vs 565) yet finished 3.6× faster, so this is not a step-count
artifact — it is re-prefill that reuse eliminated. The reuse restores the large
**static prefix** (system prompt + 13 tool schemas, ~2–3 K tokens) from disk on
every iteration instead of re-prefilling it 13–15× cold. Proven by the
`+12 disk-L2 hit` counter; `kvPrefixHitsDelta` stays 0 even while reuse fires,
which is the empirical confirmation of the Lever-1 paged-incompatible root cause.

**Honest scope & cost.** (1) The win scales with iteration count × static-prefix
size, so it's largest on long, tool-heavy multi-step cases and ~nil on
single-shot cases. (2) It trades CPU (mean 22 → 48 %, disk deserialize) and
peak RAM (+~0.75 GB) for the wall-time cut — a clear win on this workload but a
real resource cost. (3) Safe only **with a bounded cap**; the shipped 10 GB
default is too high for a constrained host (Lever 2) — the actionable
recommendation is a lower default `blockDisk.maxSizeGB` for big-model hosts.
(4) Decode and outcomes are unchanged, so this is latency-only and not
eval-gaming. (5) `prefill tok/s` is a first-step-only metric (245 vs 183 is
single-sample noise); the aggregate **wall** is the honest signal here.

#### Lever 5b — generalization + output-preservation proof (`--filter file` subset)

The single-case win could be a fluke and — more importantly — restoring KV from
disk for a rotating-window topology has a real correctness risk (a stale/partial
restore could corrupt the next structured-argument emission, which is exactly why
the runtime guards it). So the A/B was repeated on a 3-case subset chosen to test
**both** breadth and correctness: two cases the model PASSES (regression canaries)
plus the longest case. Same arms (memory-only vs disk-L2 cap 4 GB), fresh `kv_v2`
each arm.

| case | verdict (mem → L2) | wall mem | wall L2 | speedup | L2 reuse | decode tok (mem / L2) |
| --- | --- | ---: | ---: | ---: | --- | ---: |
| `edit-file-then-verify` | **PASS → PASS** | 91.2 s | 32.2 s | **2.8×** | +5 hit / +6 store | **216 / 216** |
| `write-new-file` | **PASS → PASS** | 69.6 s | 26.2 s | **2.7×** | +3 hit / +4 store | **154 / 154** |
| `search-then-multi-file-edit` | fail → fail | 370.6 s | 222.6 s | 1.7× | +11 hit / +20 store | **623 / 623** |

**Output-preservation PROVEN (the "not losing functionality" gate).** Both
passing cases stay passing, and across **all three** cases the disk-L2 arm
produced the **identical decode-token count** and the **identical tool-call
sequence** as the memory-only arm — i.e. reuse is transparent to *what the model
emits*; it only changes *how fast*. (This is a stronger result than verdict-match
alone, and it sidesteps MLX's run-to-run numerical non-determinism, which is why
the earlier single-case `todo-discipline` trajectory differed run-to-run — that
was sampler noise, not a cache effect.) Correctness rests on the runtime's
existing contract: `DiskCache.fetch` **content-address-verifies** every candidate
(only KV stored for the exact same token prefix is restored) and the v2
serializer tags every layer kind incl. `.rotating`.

**Breadth.** Reuse fires on every case (+5/+3/+11 disk-L2 hits). The speedup
scales with the prefill share of wall: 2.7–2.8× on the prefill-bound clean cases,
3.6× on `todo-discipline`, but only 1.7× on `search-then-multi-file-edit` because
that case is **tool-execution-bound** (18 `file_search` index queries dominate its
wall, not prefill) — an honest, mechanism-consistent variation, not a regression.
Disk held exactly at the **4 GB cap** (eviction working). One inefficiency noted:
the suite-wide disk probe count is high (`+147 miss` for `+19 hit`) — the
multi-boundary probe walks many non-existent boundaries per fetch; a smaller
probe set is a future micro-optimization, not a correctness issue.

### Net Phase-3 conclusion

For Gemma 12B MXFP8 on this host the loop found **three real, landed wins** plus
a set of honest nulls. The nulls: **paged-KV** is structurally inapplicable
(rotating-window topology → `isPagedIncompatible`, Lever 1), and **decode /
sampler** levers are bandwidth-bound nulls (decode is GPU/bandwidth-bound at
~16 tok/s; MXFP8-12B has **no MTP tensors** (`config.json mtp:"none"`) so
speculative-decode is unavailable; RAM is model-bound; TurboQuant is
policy-off). The three wins:

1. **Warm-on-load (Lever 4) — TTFT.** Removes cold-start JIT from the request
   path: first-request TTFT ~3.7 s → ~50 ms (≈60–74×), suite-mean TTFT
   255 → ~68 ms (3.7×), every other metric flat, outcomes unchanged.
2. **Bounded disk-L2 reuse (Lever 5) — wall on long agentic cases.** Gemma-4's
   only viable reuse lane; with a safe cap it cuts `todo-discipline-multistep`
   **303 → 84 s (3.6×)** by eliminating per-iteration re-prefill of the static
   prefix, reuse provably firing (`+12 disk-L2 hit`), decode/outcomes unchanged,
   disk bounded at 3.8 GB. **Generalized (Lever 5b):** 2.7–2.8× on the clean
   prefill-bound cases (`edit-file-then-verify`, `write-new-file`) and 1.7× on the
   tool-exec-bound search case, with **output-preservation proven** (identical
   decode-token count + tool sequence vs memory-only; passing cases stay passing).
   Cost: +CPU and +~0.75 GB RAM.
3. **Host-aware disk-cap (Lever 5c) — LANDED runtime fix.** The Lever-2 hazard
   (10 GB default fills a constrained volume) is now fixed in
   `ModelRuntime.buildCacheCoordinatorConfig`: the L2 cap is bounded to 25 % of
   current free disk (disabled if that's < 1 GB), leaving healthy hosts (≥ 40 GB
   free for the 10 GB default) **unchanged → no reuse loss where there's room**.
   Unit-proven (`HostAwareDiskCacheTests`, 7/7) and **behaviorally proven on the
   live runtime path**: with an explicit 50 GB cap configured, disk bounded at
   **6.2 GB** (≈ 24 GB free × 0.25) instead of growing toward the 9.6 GB Lever-2
   footprint — while both passing cases still PASS and reuse still fires.

Remaining future levers: cross-process MLX kernel cache (one-shot CLI cold
starts); a paged-cache that can encode rotating-window ring metadata (would
unlock the in-memory reuse lane for Gemma-family models); and an upstream
(vmlx) disk-probe micro-opt — `CacheCoordinator.fetch` walks every
`DiskCache.candidateTokenCounts` boundary (`+147 miss` for `+19 hit` in the
3-case subset), but a miss is a cheap prefix-hash + indexed lookup (not a
deserialize), the restores (`hits`) are the real cost, and the high miss ratio
is partly an artifact of unrelated cases sharing one cache — so it is a low-value
upstream change, not the bottleneck.

#### Cross-model regression safety (shared-path changes)

Warm-on-load and the host-aware cap live in the **shared** runtime path
(`ModelWarmup`, `ModelRuntime.buildCacheCoordinatorConfig`), so they were
re-verified on other local models / topologies, not just Gemma-4:

| model | topology | result | warm-up | disk-L2 reuse | host-aware cap |
| --- | --- | --- | --- | --- | --- |
| Qwen3-4B-4bit | full-attention (paged-compatible) | **14/17 — = baseline, same 3 fails** | ✓ 1.3 s | +55 hit / +163 store | bounded 6.2 GB, reuse intact |
| Qwen3.5-4B-OptiQ-4bit | full-attention, diff. quant | **3/3 subset PASS** | ✓ 4.7 s | +14 hit / +18 store | under cap, no breakage |

Qwen3-4B reproduces the documented 14/17 **exactly** (same three hardest cases
fail) on the new shipped default path — zero capability regression — and decode
(61 tok/s) / prefill (727) match the Phase-4 baseline. So the landed changes are
safe across rotating-window (Gemma-4) and full-attention (Qwen) families and
across MXFP8 / 4-bit / OptiQ quants.

## Phase 4 — cross-model comparison (grok-4.3 frontier + Qwen local incumbent)

Same AgentLoop 17-case suite, same host. Locals run memory-only; `xai/grok-4.3`
is remote (frontier reference). Quality (pass rate) is the comparable axis;
grok's speed/RAM/CPU are NOT comparable (see caveat).

| metric | Gemma-4-12B MXFP8 | Qwen3-4B-4bit | grok-4.3 (remote) |
| --- | ---: | ---: | ---: |
| **pass rate** | 10/17 | 14/17 | **17/17** |
| decode tok/s | 16.1 | 60.9 | — (remote) |
| prefill tok/s | 223 | 709 | — (remote) |
| TTFT ms (mean) | 255 | 188 | 521 (network RTT) |
| peak RAM MB | 5970 | 10569 | 19 (client-only) |
| CPU % mean/peak | 23 / 198 | 25 / 201 | 2 / 36 (client-only) |

**Remote-vs-local caveat:** grok runs on xAI servers, so its `peakRAM 19 MB`,
`CPU 2%`, and `TTFT 521 ms` measure only the local HTTP client + network RTT, not
model compute. Grok is included ONLY as the **quality ceiling**; the
TTFT/tok-s/RAM/CPU optimization story is Gemma-vs-Qwen (both local) and Gemma
before/after.

**Quality ordering is cleanly separated: grok 17 > Qwen 14 > Gemma 10.**
Per-case (identical eval logic):

- **grok passes ALL 17** — including every case Gemma fails AND the 3 hardest
  cases both local models fail (`duplicate-call-avoidance`,
  `search-then-multi-file-edit`, `todo-discipline-multistep`).
- **Qwen passes a strict superset of Gemma** (the 4 extra:
  `compaction-stress`, `dedupe-replay-fires`, `listing-navigation-discipline`,
  `wrap-up-on-budget`); 0 cases where Gemma wins and Qwen loses.

**Reading:** grok passing 17/17 proves **every** Gemma failure is achievable
under the exact same eval — so all 7 are genuine **model-capability** gaps, not
eval bugs or runtime defects. The clean 10 < 14 < 17 ladder shows the suite is
well-calibrated (discriminates across the capability range). **Net for the Gemma
checkpoint:** MXFP8-12B delivers the best **RAM** profile of the local pair
(~5.97 GB, ~½ of Qwen's KV-driven peak) but currently the **lowest
agentic-discipline quality** — it trails even the 4B local model and the frontier
grok ceiling. The actionable gap is agentic discipline (budget-heeding,
dedup/loop avoidance, checklist discipline), not throughput or memory.

**Throttling note (grok):** the first grok pass returned 11/17 `errored` with a
misleading `HTTP 400 Incorrect API key` on interleaved cases despite a valid key
(the connect and 6 cases succeeded). A clean re-run returned **17/17**, so the
errors were transient xAI-side throttling under the agentic request burst, not a
key or harness fault. Recorded so a future flaky grok pass isn't misread as a
capability result — re-run on transient 400s.

## Reproduce

```bash
# Healthy host required (ample free disk). Run under a pty to see live progress:
rm -rf ~/.osaurus/cache/kv_v2
OUT=reports/perf-baseline-gemma4-12b-mxfp8/full-suite
script -q "$OUT/run.log" env -u XAI_API_KEY OSAURUS_EVALS_KV_REGIME=memory-only \
  Packages/OsaurusEvals/.build/debug/osaurus-evals run \
  --suite "$PWD/Packages/OsaurusEvals/Suites/AgentLoop" \
  --model "OsaurusAI/gemma-4-12B-it-MXFP8" \
  --out "$OUT/gemma4-12b-mxfp8-AgentLoop.json"

# Paged-KV A/B (memory-only both arms; the only diff is the paged lane).
# NOTE: for Gemma-4 this is a structural no-op (paged-incompatible, Lever 1) —
# the KV prefix counter stays 0/0 because the paged tier is never consulted.
OSAURUS_EVALS_KV_REGIME=memory-only OSAURUS_EVALS_PAGED_KV=off  osaurus-evals run …
OSAURUS_EVALS_KV_REGIME=memory-only OSAURUS_EVALS_PAGED_KV=on   osaurus-evals run …

# Disk-L2 reuse A/B (Lever 5; the KV win for Gemma-4). Longest case only;
# clear kv_v2 before each arm so iteration 1 is a genuine cold miss/store.
# Arm A (baseline, no reuse): memory-only. Arm B: disk-L2 with a SAFE bounded cap.
rm -rf ~/.osaurus/cache/kv_v2
env -u XAI_API_KEY OSAURUS_EVALS_KV_REGIME=memory-only \
  osaurus-evals run --suite "$PWD/Packages/OsaurusEvals/Suites/AgentLoop" \
  --model "OsaurusAI/gemma-4-12B-it-MXFP8" --filter todo-discipline \
  --out build/evals-ab/diskl2/memonly.json
rm -rf ~/.osaurus/cache/kv_v2
env -u XAI_API_KEY OSAURUS_EVALS_KV_REGIME=disk-l2 OSAURUS_EVALS_DISK_L2_CAP_GB=4 \
  osaurus-evals run --suite "$PWD/Packages/OsaurusEvals/Suites/AgentLoop" \
  --model "OsaurusAI/gemma-4-12B-it-MXFP8" --filter todo-discipline \
  --out build/evals-ab/diskl2/diskl2-cap4.json
# Arm B logs `KV disk-L2 +Nhit/+Nstore` (reuse) and `kv_v2` stays under the cap.

# Warm-on-load A/B (Lever 4; same order both arms, only diff is the warm-up).
# Default = warm-up ON; set OSAURUS_EVALS_DISABLE_WARMUP=1 to reproduce cold start.
env -u XAI_API_KEY OSAURUS_EVALS_KV_REGIME=memory-only OSAURUS_EVALS_DISABLE_WARMUP=1 \
  osaurus-evals run --suite "$PWD/Packages/OsaurusEvals/Suites/AgentLoop" \
  --model "OsaurusAI/gemma-4-12B-it-MXFP8" --filter call --out build/evals-ab/off.json
env -u XAI_API_KEY OSAURUS_EVALS_KV_REGIME=memory-only \
  osaurus-evals run --suite "$PWD/Packages/OsaurusEvals/Suites/AgentLoop" \
  --model "OsaurusAI/gemma-4-12B-it-MXFP8" --filter call --out build/evals-ab/on.json
# Warm-up logs `[osaurus] warm-up done … elapsedMs=…` to stderr (the absorbed JIT).
```
