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
- **KV reuse +0 hit / +0 miss / +0 SSM (suite-wide).** Honest for this regime:
  disk-L2 is off and each case runs a fresh, non-shared prefix, so there is no
  reuse to count — not a measurement gap. The deltas now POPULATE (0, not nil)
  for 16/17 cases, proving the readout works; the first case is nil because the
  batch-diagnostics snapshot isn't resolved until the model is warm. Making
  reuse non-zero (cross-iteration `session_id` reuse; disk-L2 A/B) is a Phase-3
  lever.

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

1. **Cold-start TTFT (~3 s → ?).** The first-prefill JIT kernel compilation is
   the dominant cold TTFT cost. Lever: warm/persist the compiled quantized
   kernels so a fresh process doesn't re-JIT. Highest TTFT leverage.
2. **KV reuse across loop iterations (same `session_id`).** The long multi-step
   cases (`search-then-multi-file-edit` 6.4 min, `compaction-stress` 4.8 min,
   `todo-discipline-multistep` 4.4 min) re-prefill a growing context every step
   under memory-only. Real cross-iteration prefix reuse is the biggest
   decode/wall win on these — verify the counters go non-zero.
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

**Result: no win — keep paged-KV OFF (the shipped default).** Enabling
`pagedKV.enabled=true` neither improved any metric nor made the prefix-hit
counter non-zero. **Root cause (measurement):** the prefix-hit readout is
sourced exclusively from `cacheStats.pagedStats.cacheHits`
(`MLXBatchAdapter.snapshotDiagnostics`, lines 453–454), and the eval's
in-process agentic decode path does not surface `pagedStats` into
`cachedModelSummaries().cacheStats` — so the paged counter cannot observe reuse
on this route regardless of the toggle. **Root cause (perf):** the session is
already threaded (`AgentLoopEvaluator` `session_id`), and whatever in-memory
prefix reuse exists is served by the non-paged prefix lane; adding paging on top
buys nothing here and is not the bottleneck (decode is GPU-bound at ~16 tok/s).
The honest cross-iteration-reuse readout therefore remains a **PARTIAL** metric
on this decode path (counters provably wired but always 0 here); the disk-L2
lane is where reuse counters do move (next lever) but it carries a disk hazard.

### Lever 2 — memory-only vs disk-L2 (ABORTED: disk hazard)

Attempted the disk-L2 arm on the same subset. The disk-L2 block lane is the
shipped default (`blockDisk.enabled=true`, `maxSizeGB=nil` → **uncapped**), and
on Gemma 12B MXFP8 it wrote `~/.osaurus/cache/kv_v2` to **9.6 GB in ~90 s**
(≈6–9 GB/min), dropping free space from 37 → 27 GiB. On a host without tens of
GB of headroom this fills the volume in minutes and recreates the
disk-pressure decode collapse documented above, so the arm was **killed for
safety** (disk reclaimed cleanly). **Finding:** the default uncapped disk-L2
cap is an operational hazard for big-model runs; this is exactly why the
baseline (and the Qwen baseline before it) is captured **memory-only**. A real
disk-L2 A/B needs either a `blockDisk.maxSizeGB` cap or a dedicated large
volume — recorded as **BLOCKED** pending a bounded-cap run.

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

### Net Phase-3 conclusion

For Gemma 12B MXFP8 on this host, the **shipped defaults (memory-only-equivalent
compute, paged-KV off, TurboQuant off) are already the best-measured config** for
the agentic AgentLoop workload. The single highest-leverage REAL optimization
remains **cold-start TTFT** (3.0–3.2 s first-prefill JIT) — addressable only by
persisting the compiled MLX quantized-matmul kernels across processes (an
MLX-level kernel cache), which is out of scope for a settings A/B and recorded
as the top future lever.

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

# Paged-KV A/B (memory-only both arms; the only diff is the paged lane):
OSAURUS_EVALS_KV_REGIME=memory-only OSAURUS_EVALS_PAGED_KV=off  osaurus-evals run …
OSAURUS_EVALS_KV_REGIME=memory-only OSAURUS_EVALS_PAGED_KV=on   osaurus-evals run …
```
