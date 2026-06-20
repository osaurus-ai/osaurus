# Speed / RAM baseline (W5 perf-and-RAM)

Per-model speed and RAM baseline built on the W1 optimization-loop telemetry
(`EvalCaseTelemetry`: decode tok/s, prefill tok/s, TTFT, peak physical
footprint, completion tokens). This is the first committed perf/RAM
scoreboard so regressions are visible run-over-run, per the
`AGENTS.md` rule that every generation row records token/s and that peak
physical footprint stays within the intended low-RAM envelope.

- **Date:** 2026-06-19
- **Model:** `mlx-community/Qwen3-4B-4bit` (local MLX, 4-bit)
- **Suite:** `Suites/AgentLoop` (representative subset — see "Scope" below)
- **Telemetry source:** in-band `StreamingStatsHint` → `AgentLoopTranscript`
  → `EvalCaseTelemetry`; peak RAM from `PeakMemorySampler` over
  `ProcessMemoryProbe` (eval-process physical footprint).
- **Artifacts:** the rolled-up scoreboard is committed at
  `reports/SNAPSHOT.{md,json}` with one append-only row per run in
  `reports/history.jsonl`; the raw per-case reports this baseline was measured
  from stay local / git-ignored (reproducible via `osaurus-evals matrix`). See
  `reports/README.md` for the layout and record/commit workflow.

## Scope (why a subset, and why it is still honest)

The full 17-case `AgentLoop` suite was **not** used for the committed
baseline numbers on this machine: the host was under genuine resource
pressure during the run (near-full disk + leftover GPU-wedged eval
processes), which inflated per-step TTFT from ~1.2 s to ~7 s on the long
multi-iteration cases. Publishing those thrashing-degraded numbers as a
"baseline" would violate the honest-proof rule, so the scoreboard uses a
4-case representative subset captured when the host was healthy (memory
free ≥ 49 %, disk ≥ 11 GiB). The cases span the loop's shapes: a clean
single write (`write-new-file`), an edit-then-verify
(`edit-file-then-verify`), a dedupe case (`duplicate-call-avoidance`),
and a multi-step todo (`todo-discipline-multistep`). The full 17-case
suite-wide run was subsequently captured on a healthy host (2026-06-19,
after the storage fix: 74 GiB free, 52 % memory free, KV cache cleared) —
see **"Full suite-wide baseline (17 cases)"** below. The 4-case subset is
retained as the per-case compute reference; the full run adds suite-wide
aggregates and the pass-rate + RAM picture across every loop shape.

## Scoreboard — memory-only KV (pure compute baseline)

KV disk-L2 cache forced off (memory-only) so the numbers measure compute,
not disk I/O, and do not depend on cross-run cache state. See the cache
note below.

| case | verdict | decode tok/s | prefill tok/s | TTFT ms | peak RAM MB | tok |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| `write-new-file` | pass | 57.5 | 502 | 1229 | 4247 | 42 |
| `edit-file-then-verify` | pass | 56.8 | 506 | 1213 | 4356 | 53 |
| `duplicate-call-avoidance` | fail | 58.8 | 516 | 1227 | 4287 | 99 |
| `todo-discipline-multistep` | fail | — | — | 1305 | 4541 | 0 |

**Aggregates (memory-only):**

| metric | mean | min | max | n |
| --- | ---: | ---: | ---: | ---: |
| decode tok/s | 57.7 | 56.8 | 58.8 | 3 |
| prefill tok/s | 508 | 502 | 516 | 3 |
| TTFT ms | 1243 | 1213 | 1305 | 4 |
| peak RAM MB | 4358 | 4247 | 4541 | 4 |

Pass rate is incidental (2/4): the subset deliberately includes cases this
model fails on agentic quality (W4 territory), not perf. The
`todo-discipline-multistep` row records **0 completion tokens** — it ended
without a decode-phase stats hint carrying `tokens > 0` (the loop produced
no final decoded text), so decode/prefill are honestly nil rather than
fabricated. TTFT + peak RAM still apply because they are captured
independently of the end-of-step stats.

## Full suite-wide baseline (17 cases)

Full `Suites/AgentLoop` run on the healthy host (memory-only KV, same
regime as the subset, so the per-case numbers are directly comparable).
Artifacts: the 17-case `llm-qwen3-4b-AgentLoop.json` (local / git-ignored
under `reports/perf-baseline-qwen3-4b/full-suite/`); its rolled-up scoreboard
row is recorded in the committed `reports/history.jsonl`. Run wall-clock
~16.8 min — dominated by a single `compaction-stress` case (444 s) under the
memory-only re-prefill penalty.

**Pass rate: 13 / 17 (76 %)** — up **+1 from the WS7 baseline of 12/17**.
The gain is `capabilities-load-midrun`, which now PASSES: the W4
`CapabilitiesLoadTool` idempotency fix (re-loading an already-callable but
globally-disabled tool returns idempotent success) is validated end-to-end
through the live loop, not just its unit test.

**Suite-wide aggregates (memory-only):**

| metric | mean | min | max | n |
| --- | ---: | ---: | ---: | ---: |
| decode tok/s | 53.5 | 21.4 | 61.7 | 13 |
| prefill tok/s | 469 | 247 | 643 | 13 |
| TTFT ms | 206 | 111 | 1176 | 16 |
| peak RAM MB | — | 4129 | 10406 | 17 |

- decode `n=13` / TTFT `n=16` / peak RAM `n=17`: the 4 non-model rows
  (budget-gate `over-budget-hard-overflow` at 0 ms, early-exit `clarify`/
  `rejection` cases) honestly carry no decode-phase stats but still record
  TTFT / RAM where captured — same nil-not-faked policy as the subset.
- decode mean 53.5 tok/s tracks the subset's ~57; the full suite pulls the
  mean down via hard, big-context cases (the `compaction-stress` row decodes
  at just 21.4 tok/s under a 24K-token re-prefilled context).

**Failures (4) — all model-capability ceilings, not eval/product bugs:**

| case | wall ms | why it failed (model behavior) |
| --- | ---: | --- |
| `duplicate-call-avoidance` | 16110 | dedup worked (`noDuplicateExecutedCalls ok`) but the final answer was missing the expected value `'50'` — synthesis miss, not a loop bug |
| `search-then-multi-file-edit` | 156372 | scored on disk state; the model did not land the rename in BOTH files (import + call site ×2) — burned steps on relative-path recovery |
| `todo-discipline-multistep` | 84464 | made the checklist but never carried a checked box before completing (`todoUpdatedBeforeComplete`) — discipline miss |
| `compaction-stress` | 444164 | 5 multi-KB reads against a 24K window force mid-run sticky compaction; the model did not finish the task correctly under that pressure |

These are the same headroom W4 targets (small-model agentic discipline /
synthesis), so 13/17 is an honest local-model result, not a strip-to-pass.

### RAM gate — suite-wide

15 / 17 cases peak at **~4.1–4.8 GB** (consistent with the subset and the
RAM gate). **Two large-context cases spike to ~10 GB** (`compaction-stress`
10406 MB failed; one big multi-read case 10177 MB passed). This is the
**memory-only tradeoff, not a leak**: with the disk-L2 lane forced off, the
full KV cache for a 24K-token context is RAM-resident, so peak physical
footprint scales with context instead of offloading to disk. It is the
concrete counter-pressure to the "memory-only is strictly faster" read from
the subset (small contexts) — on big contexts memory-only trades ~6 GB of
extra RAM for the avoided disk I/O. The disk-L2 / paged-KV path is the
correct regime for large-context agent loops; this is the strongest
data-point yet for prioritizing the prefix-reuse work below.

## Cache-regime comparison (`write-new-file`, identical case)

| regime | decode tok/s | prefill tok/s | TTFT ms | peak RAM MB |
| --- | ---: | ---: | ---: | ---: |
| memory-only KV | 57.5 | 502 | 1229 | 4247 |
| disk-L2 KV on | 42.9 | 5916 | 1265 | 4759 |

- **Decode is ~34 % faster memory-only** (57.5 vs 42.9 tok/s): the disk-L2
  store path contends with decode on this case (small context, store cost
  not yet amortized by a re-read hit).
- **Prefill reads ~5900 tok/s with disk-L2** vs ~500 cold: that high number
  is a **served prefix** (cache hit / fast prompt replay), not raw
  prompt-processing throughput — useful as a cache-hit signal, not as the
  cold-prefill baseline.
- **Peak RAM is ~500 MB higher with disk-L2 on** (4759 vs 4247): the disk
  cache coordinator's working set.

## RAM gate (per `AGENTS.md`)

Peak physical footprint for this 4-bit 4B model lands at **~4.2–4.8 GB**
(eval-process footprint, which includes the Swift/MLX runtime + harness,
so it is an upper bound on the model's own footprint, not the pure weight
+ KV residency). This is within a reasonable low-RAM envelope for a 4B-4bit
model on Apple silicon; no row reached anything near full-precision model
size. token/s is recorded on every non-degenerate row, satisfying the gate's
"missing token/s is a blocked row" rule.

## Known gap — KV prefix-hit rate is not surfaced in the eval path

The W1 telemetry reserves `kvPrefixHitsDelta` / `kvPrefixMissesDelta` /
`ssmCompanion*` fields, fed by `ModelRuntime.batchDiagnosticsSnapshot()`
before/after each case. In the **in-process eval decode path these are
nil**, because:

- `MLXBatchAdapter.snapshotDiagnostics()` returns `nil` when no
  `BatchEngine` is resolved (the eval uses single-stream `streamChat`, not
  the batched server engine), and
- `prefixHits`/`prefixMisses` are only counted when `pagedStats` is present
  (paged KV on).

So prefix-hit *counters* are a paged/batch-engine concept the eval does not
engage. The eval path **does** use the disk-L2 KV lane (the
`~/.osaurus/cache/kv_v2` `[vmlx][cache/disk] store` activity proves it), and
in-session memory KV reuse still applies; what is missing is the *paged
prefix-hit counter readout*, not caching itself. This is documented as a
gap rather than faked. Closing it means either routing evals through the
batch engine or adding per-iteration prefill telemetry as a reuse proxy
(later-iteration prefill speedup on a reused `session_id`).

## Fixes shipped under W5

1. **Prefill telemetry capture bug** (`AgentLoopEvaluator`): prefill tok/s
   was gated to the *first model step*, but a first step that ends in a
   tool call throws `ServiceToolInvocations` before emitting its end-of-step
   stats, so prefill was silently dropped (nil) on every tool-using case.
   Now captures the **first available positive** prefill reading across
   steps. Prefill tok/s now populates.
2. **Full-disk crash hardening** (`DebugLog`, `TTFTTrace`, `ChatPerfTrace`):
   the file tracers used the legacy `FileHandle.write(_:)` /
   `seekToEndOfFile()` / `closeFile()` APIs, which raise an **uncatchable
   Objective-C `NSException`** (`No space left on device`) that `try?`
   cannot trap — it terminated the whole process. (Observed live: a full
   disk crashed an eval run mid-suite.) Switched to the throwing Swift APIs
   (`seekToEnd` / `write(contentsOf:)` / `close`) wrapped in `try?`; a full
   disk now degrades silently. Re-verified live: the next run hit the same
   full disk and continued instead of crashing.

## Candidate targets (emerge from the baseline)

- **Disk-L2 KV cache grows fast and is uncapped by default** — it wrote
  **~8 GB in ~1 minute** of a single AgentLoop run (full-attention KV
  safetensors per prefix, ~16–26 MB each), filling a near-full disk. This is
  **by design, not a bug**: per `docs/INFERENCE_RUNTIME.md`, `diskCacheMaxGB`
  is intentionally *not* overridden by osaurus (vmlx's default is used "so a
  library tuning bump lands without an app-layer redeploy"), and the cap is a
  user-facing knob (`blockDisk.maxSizeGB`, Cache settings → Block disk max
  size GB; default `nil`, pinned by `assert-server-settings-runtime-wiring.sh`
  and unit tests). Adding a hidden app-layer default cap would contradict that
  decision and the `AGENTS.md` no-hidden-limits rule. The real defect was the
  **process crash** on a full disk (now fixed — see "Fixes shipped"), which
  restores the documented graceful out-of-disk fallback
  (`INFERENCE_RUNTIME.md`: "graceful fallback to memory-only when the dir is
  read-only / out-of-disk") so a full disk now degrades instead of aborting.
  Genuine follow-ups (not hidden caps): surface a disk-pressure warning, and
  recommend setting `blockDisk.maxSizeGB` on disk-constrained hosts.
- **Decode ~57 tok/s, cold prefill ~500 tok/s, TTFT ~1.2 s** is the bar to
  beat. Levers to A/B via the W1 loop: paged-KV + prefix reuse across loop
  iterations (same `session_id`), TurboQuant-KV, and `defaultMaxKVSize` /
  `longPromptMultiplier` from the resolved memory-safety plan.
- **Long multi-iteration cases dominate wall-clock** (growing context →
  growing prefill each step). Verifying real KV-prefix reuse across loop
  iterations is the highest-leverage speed win and is blocked on the
  prefix-hit-readout gap above.

## Reproduce / extend

```bash
# Full per-model loop on an unloaded host (all suites → matrix → diff):
make evals-loop

# Record a run: refresh the committed snapshot + append a trend row:
RECORD=1 LABEL="what changed" make evals-loop

# Or rebuild the committed scoreboard by hand from a local run dir:
osaurus-evals matrix build/evals/loop/latest \
  --out reports/SNAPSHOT.json --markdown reports/SNAPSHOT.md \
  --history reports/history.jsonl --label "what changed"
```

To reproduce the memory-only regime used here, force the disk-KV dir
unwritable (the supported memory-only degradation in
`ModelRuntime.buildCacheCoordinatorConfig`) before the run, e.g. replace
`~/.osaurus/cache/kv_v2` with a non-writable placeholder; restore it after.
