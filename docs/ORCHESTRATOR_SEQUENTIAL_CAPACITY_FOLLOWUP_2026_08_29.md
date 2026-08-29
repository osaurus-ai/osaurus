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

## Start gate

Do not begin these implementation PRs until Eric explicitly authorizes the
lane. At start, first reproduce the reporter's second-child failure on 0.24.2
or an exact-source Release build and freeze the logs before editing. The first
code change must follow the measured lifecycle boundary, not a hypothesis.
