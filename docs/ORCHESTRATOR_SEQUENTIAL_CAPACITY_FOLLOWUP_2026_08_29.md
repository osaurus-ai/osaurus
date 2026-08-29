# Orchestrator sequential-capacity follow-up — 2026-08-29

## Status

**OPEN / LIVE REPRODUCTION REQUIRED. Do not claim fixed.**

Osaurus 0.24.2 corrected the originally reported first-child refusal for a
same-resident Gemma 4 E2B spawn, but the reporter now observes a second-child
failure in a sequential orchestration run. This document freezes that report
and defines the next focused PRs. No implementation should begin until Eric
authorizes the lane.

## Reporter configuration

- Mac mini M4, 16 GB unified memory, 2 TB SSD
- macOS Tahoe 26.6.2
- Osaurus 0.24.2 for the current reproduction
- Orchestrator: Gemma 4 E2B 8-bit
- SysAdmin / Research / Writer: the same
  `OsaurusAI/gemma-4-E2B-it-8bit` bundle
- Local Orchestrator Handoff: ON
- RAM-Safety Preflight: ON
- Keep Chat Model Loaded / Coexistence: OFF
- maximum output tokens per child: 2048
- maximum child turns: 2
- maximum child seconds: 120
- maximum subagents per batch: 1

## Exact observed progression

### 0.24.1

The first tiny `spawn_agent` was rejected after admission with:

```text
spawn_agent no longer fits the current local RAM-safety and batching limits
after waiting for admission
```

Turning RAM-Safety Preflight OFF allowed the identical SysAdmin delegation to
return `SYSADMIN-SPAWN-SUCCESS-829`.

### 0.24.2

The first child now succeeds, confirming that the first-child pricing fix
reaches this reporter's machine. Sequential orchestration still fails:

1. SysAdmin completes successfully.
2. Research is attempted next with the same model and limits.
3. Research is rejected with `admission = stable_memory_refusal`,
   `refreshed_capacity = 0`, and:

```text
local model has no free capacity for a child run under current memory and
batching limits
```

The product defect is therefore no longer “same-model child can never be
admitted.” It is “capacity may remain unavailable or be recomputed incorrectly
after a successful sequential child settles.”

## Current source trace

The terminal refusal is constructed in
`Packages/OsaurusCore/Subagent/SubagentSession.swift` after admission and
residency replanning:

1. `refreshedResidencyPlanAfterAdmission(...)` recomputes the residency plan.
2. A `.localInPlace` run calls `localInPlaceSlotCapacity(...,
   rejectUnsafeSingleRun: true)`.
3. The held local-in-place reservation is resized against that refreshed
   capacity.
4. `refreshedCapacity == 0 || !admissionHeld` returns a non-retryable
   `stable_memory_refusal` envelope.

This is correct fail-closed behavior if capacity is genuinely zero. The open
question is why it is zero after child 1 completed.

The existing test named `local capacity and handoff plan refresh only after
admission wait` proves a queued request refreshes once after a blocker releases.
It does **not** prove the production sequence:

```text
parent resident
  -> child 1 admitted
  -> child 1 model/tool loop completes
  -> child 1 cache/store and engine slot settle
  -> admission reservation releases
  -> child 2 recomputes capacity
  -> child 2 admits
```

Consequently, the root cause is **UNPROVEN**. Candidate boundaries to measure,
not assume, are:

- an admission-controller local-in-place slot not released after child 1;
- the BatchEngine still reporting an active/pending sequence while the child
  result has already been returned;
- a model holder/residency count surviving child settlement;
- cache-store or SSM/CCA/QSA companion work keeping capacity unavailable;
- the second plan counting the already-resident same target as incremental
  weights;
- stale physical-footprint or memory-plan input sampled before child cleanup;
- handoff/coexistence state being re-resolved differently on the second child.

## Mandatory PR 1 — sequential admission lifecycle

Scope this PR to capacity lifecycle and telemetry. Do not mix model parser,
cache-kernel, or general AgentLoop policy changes into it.

### Required code-level tests

Add a production-shaped two-child sequence using the real preparation,
admission, run, cleanup, and replanning path:

1. same agent, same already-resident model, child 1 then child 2;
2. two different configured agents that resolve to the same canonical model;
3. maximum subagents per batch 1, proving sequential reuse rather than B>1;
4. RAM-Safety ON, handoff ON, coexistence OFF;
5. child 1 success followed by child 2 success;
6. child 1 tool-loop error followed by child 2 admission;
7. child 1 cancellation/Stop followed by child 2 admission;
8. child 1 timeout followed by child 2 admission;
9. a genuinely unsafe control that still returns non-retryable
   `stable_memory_refusal`;
10. no leaked exclusive or local-in-place reservations after every terminal
    path.

Do not satisfy these tests by bypassing RAM safety, inventing capacity, or
forcing handoff. Fix the lifecycle boundary shown by telemetry.

### Required decision telemetry

Persist one structured record at each boundary:

- canonical parent and child model IDs;
- requested child contract: seed/context positions, turns, output tokens, tool
  posture, and computed position ceiling;
- RAM-safety mode, handoff, coexistence, and continuous-batching settings;
- resident model holders and weight bytes;
- admission class and held slots before/after acquire, resize, child terminal,
  cache completion, handoff restore, and release;
- BatchEngine configured maximum, architecture maximum, effective maximum,
  active count, pending count, and accepting state;
- capacity estimate inputs and final `ram_slots`;
- physical footprint, available memory, compressor/swap state;
- exact refusal reason and whether the state is stable or transient.

The user-facing envelope should remain compact, but a support/eval artifact
must make a second-child refusal attributable without guessing.

## Mandatory live acceptance on 16 GB hardware

The 128 GB development Mac cannot close this gate. Reproduce on an actual 16 GB
Apple-silicon Mac with the reporter's bundle and settings.

### Primary row

From a fresh chat, ask the Orchestrator to run exactly two sequential children:

1. SysAdmin returns `SYSADMIN-SEQUENTIAL-ONE-829`.
2. Research returns `RESEARCH-SEQUENTIAL-TWO-829`.
3. Parent returns both tokens once and stops.

Require:

- RAM-Safety ON throughout;
- exactly one Osaurus instance from the tested Release build;
- both children use `OsaurusAI/gemma-4-E2B-it-8bit`;
- child 2 begins only after child 1 fully settles;
- child 2 has refreshed capacity greater than zero and is admitted;
- no model reload if the same resident holder is safely reusable;
- no hidden retry loop or repeated refusal;
- visible coherent final response;
- TTFT and token/s for parent and both children;
- peak `phys_footprint`, swap growth, cache counters, engine slots, and
  admission lifecycle captured;
- Stop/cancel and app restart variants leave no stale reservation or model
  holder.

### Controls

- RAM-Safety OFF: diagnostic only, never proof of the fix.
- Different child model with handoff ON: must unload/restore according to the
  resolved plan and release capacity before the next child.
- Coexistence ON: must follow its distinct projection; never use this result to
  substitute for the reported coexistence-OFF row.
- True insufficient-memory row: must still refuse before eviction or unsafe
  load, with accurate nonzero inputs and a stable reason.

## Mandatory PR 2 — architecture and AgentLoop matrix

After the sequential lifecycle PR passes, run the same production AgentLoop
and OsaurusEvals path across cache topologies. A model merely loading is not a
pass.

| Family | Execution contract | Required follow-up |
|---|---|---|
| Gemma 4 E2B dense | Same-model reuse; native batch only when effective engine capacity permits | Reporter row above plus 10-child sequential soak, Stop/continue, restart/disk restore |
| Qwen3.5 / Ornith SSM | Native B>1 when its cache contract is proven; sequential max=1 must also release | Two-child sequential and B=2 rows, SSM split-back/companion telemetry, multi-turn continuation |
| Zaya CCA / VLM | Native B>1 is blocked until malformed tool arguments are diagnosed | Capture rendered schema, raw model bytes, resolved parser, parsed args; then CCA isolation and real image multi-turn cache rows |
| Qwen3.8 Flash-Next QSA/MTP | Safe B=1 serialization until QSA supports B-wide state | MTP off/auto/manual depth, two sequential children, request-local MTP stats, prefix/QSA cache correctness, Stop/restart |
| DSV4 hybrid pool | Safe B=1 serialization | Sequential children plus cleanup telemetry; current ~105 GB proof-row footprint remains a separate failed RAM gate |
| Dense Gemma control under CB=2 | Native B>1 | Two simultaneous children must actually report subwave `[2]`, not merely both finish |

For VLM/video rows, use real image and video payloads. Record media preprocessing,
media-salted prefix identity, cache hit/miss, disk restore, companion-state
restore, TTFT, token/s, visible coherency, and physical footprint. Text-only
loads do not validate VLM/video caching.

## Mandatory PR 3 — OsaurusEvals truthfulness

The eval harness must distinguish:

- requested/configured concurrency;
- architecture maximum decode width;
- engine-effective width;
- observed local slots and subwaves;
- native parallel execution versus safe serialization;
- admission refusal versus tool-parser failure versus runtime/cache failure.

Do not hardcode every two-child fixture to slots 2 / subwave `[2]`. Keep one
strict native-parallel fixture and add a strict safe-serialized fixture. A
serialized architecture passes only if both children settle in `[1,1]`, the
limiting factor is truthful, the process survives, and RAM/performance gates
also pass.

Every row must report:

- exact app/eval binary, Osaurus SHA, and vMLX SHA;
- model ID and bundle generation config with no hidden sampler/reasoning
  coercion;
- child/parent exit reasons and recovery counters;
- TTFT and token/s;
- `phys_footprint`, swap, and model residency;
- prefix/paged/disk-L2 plus SSM/CCA/QSA/MTP/media companion counters;
- multi-turn, Stop/cancel, and restart/disk-restore disposition;
- rendered Release-app confirmation for user-facing claims.

Missing evidence is `PARTIAL` or `BLOCKED`, never an implicit pass.

## Current investigation checkpoint — 2026-08-29

Eric authorized implementation and live proof. Current source trace found a
specific estimator drift rather than a hardcoded model-family exception:

- normal `ModelRuntime` load safety was corrected in `6e2c3c705` (2026-08-09)
  to count ACTIVE mmap/file-cache pages as reclaimable by subtracting wired,
  compressor-resident, and non-purgeable anonymous pages from physical RAM;
- `ChatResidencyHandoff.availableMemoryBytes()` retained its older
  free+inactive+purgeable-only formula from `a29fe877e` (2026-06-23);
- `ModelRuntime.subagentBatchMemoryFacts()` uses the stale handoff value for
  `reclaimableBytes`, including the post-admission refresh that emits
  `stable_memory_refusal`;
- after child 1 materializes mmap-backed model/cache pages, those pages may be
  ACTIVE but reclaimable. The old formula can therefore report less than the
  fixed OS reserve and reduce `ramSlots` to zero for child 2 while the normal
  loader considers the same pages reclaimable.

The in-progress branch centralizes both call paths on one host estimator and
adds pure 16 GiB arithmetic plus sequential reserve/release regressions.

Current verification on the frozen source diff:

- 70/70 tests passed across `SubagentAdmission`, `SubagentSession admission`,
  `Owned subagent operation cancellation`,
  `ChatResidencyHandoffRestoreTests`, and the 16 GiB regression suite. The log
  is `/private/tmp/osaurus-sequential-capacity-broad-tests.log`.
- The isolated pre-fix Release app on this 128 GiB host ran two real sequential
  Gemma 4 E2B delegated sessions and returned `SEQ_ONE_829` then
  `SEQ_TWO_829`. The database records separate child sessions, two model/tool
  iterations per child, and disk-L2 counters; the UI rendered the combined
  answer at 0.39 s parent TTFT and 106.1 tok/s. Evidence is under
  `/private/tmp/osaurus-sequential-capacity-evidence-20260829/` and
  `/private/tmp/osaurus-sequential-before-root-829-20t9ew29/`.
- This 128 GiB before arm establishes a valid production-path fixture but does
  not reproduce or disprove the reporter's 16 GiB failure.

At that checkpoint the lane remained **PARTIAL** pending an exact-head Release
build, a matching post-fix UI row, and the mandatory real 16 GB
reporter/hardware row. The first two gates are recorded below; the 16 GB gate
remains open.

### Exact-head Release proof — `55f59822d`

- Release build completed with RC 0; log:
  `/private/tmp/osaurus-sequential-capacity-release-build.log`.
- Built executable SHA-256 before proof-bundle signing:
  `71eb425f7d054cae9d89930098c4c9ffded247503c90f21a6f543fb591f7d80d`.
  The isolated ad-hoc-signed proof executable is
  `e919b58dceac2110aefcc9491d334122cc52f5f58b91197bb31aca1e3e224e79`.
- The real UI ran two sequential same-model Gemma E2B children under RAM
  Safety ON, Local Handoff ON, Coexistence OFF, one per batch, 2,048 output
  tokens, two turns, 120 seconds, and persisted `Always Allow` permission.
- First process: both children settled, parent rendered a final response at
  0.30 s TTFT and 110.0 tok/s. Admission independently recomputed child 1 and
  child 2 as admitted with reclaimable memory 100.28/100.13 GiB,
  `ramSlots=56`, and `localCapacity=1`.
- Restart process: disk state restored; two more sequential children returned
  exact `RESTART_ONE_829` and `RESTART_TWO_829`. Parent rendered both at
  0.25 s TTFT and 137.3 tok/s. Child completion rates were 43.7 and 27.0 tok/s;
  admission recomputed at 100.16/100.14 GiB reclaimable with the same admitted
  capacity. Current/peak `phys_footprint` was 2,593/3,213 MB.
- Child envelopes recorded increasing disk-L2 counters (first child
  hits/misses/stores 4/11/9; second 5/12/13). No
  `stable_memory_refusal` or `refreshed_capacity` marker exists in the
  isolated database or admission logs.
- UI screenshots, admission logs, hashes, and the database are under
  `/private/tmp/osaurus-sequential-capacity-evidence-20260829/` and
  `/private/tmp/osaurus-ui-proof-seqafter829-wlEKayvi/`.

This makes the source fix and 128 GiB production path **PASS**. Overall issue
status remains **PARTIAL** because the causal acceptance row must still run on
the reporter's real 16 GiB hardware; the larger host cannot validate its
absolute memory-pressure boundary.
