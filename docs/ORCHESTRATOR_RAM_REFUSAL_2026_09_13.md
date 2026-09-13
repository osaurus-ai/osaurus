# PR #2733 follow-up: actual 16 GB reproduction still fails

Status: **UNRESOLVED on the reporter's 16 GB machine**. The subsequent audit
reproduced a kernel-statistics freshness defect and four additional policy
defects. A local freshness correction passes 109 focused tests; it is not
16 GB acceptance proof. See `ORCHESTRATOR_RAM_SAFETY_AUDIT_2026_09_13.md` for
the findings, evidence, uncorrected defects, and merge limits.

HarrisMagnum4 reports that the isolated #2733 build on an M4 Mac mini with
16 GB ran the first minimal child successfully (`RAM_FIRST_OK`), then refused
the same test in a fresh chat without restarting. The failure says "after the
fresh memory check". This supersedes any inference that the earlier local
128 GB proof resolved the actual 16 GB report.

Source reviewed: Osaurus `a609acdb5` (live/main, containing the #2733 merge
`8fcd06156496df5aee1bfd0bc227e2f5209969a0`). The initial investigation below
preceded the local freshness patch. The original tests and UI evidence remain recorded in
`ORCHESTRATOR_RAM_REFUSAL_2026_09_12.md`; they are not new-head or 16 GB proof.

## What the new error does and does not establish

`SubagentSession.runPrepared` uses the new wording for every refusal at its
post-reservation capacity check. It does **not** establish that
`memoryFactsAfterReclaimingIfNeeded` attempted allocator recovery. That helper
skips recovery for unknown estimates, explicit-budget failures, cancellation,
and decisions that already have at least one RAM slot.

For known facts, the current planner computes:

```
incremental_weights = resident ? 0 : target_load_bytes
host_residual = max(0, reclaimable_bytes + releasable_parent_bytes
                       - incremental_weights - os_reserve_bytes)
host_slots = floor(host_residual / per_child_bytes)
budget_slots = floor(max(0, load_budget_bytes - target_load_bytes)
                     / per_child_bytes)
ram_slots = min(host_slots, budget_slots) // when a total budget exists
```

The model footprint is charged once against the total budget. A resident
same-model child pays no incremental weight charge against measured host
memory. Each concurrently active child still needs its bounded cache and
activation allowance; engine and agent limits independently constrain width.
Sequential reservations are released on the refusal path as well as completion.
This source trace does not establish the reporter's actual resident flag or
prove that every execution lifecycle is leak-free.

The fixed host reserve is 3 GiB. A bounded child commonly hits the 512 MiB
estimator floor. Such a resident child requires at least 3.5 GiB of measured
host reclaimable memory even when the configured total model budget fits.
Whether that reserve or another term refused this run is still unknown.
Changing the reserve or granting a minimum slot without the actual counters
would be a policy change, not a demonstrated correction of this reproduction.

`SwapPressureMonitor` warnings do not directly set this capacity. The shared
host estimator subtracts wired pages, physical compressor pages, and
non-purgeable internal/anonymous pages from physical RAM. Swap can correlate
with those measurements, but swap-used bytes are not directly subtracted.
The reporter's earlier `memory_pressure` output lacks the internal-page count;
its 59% headline cannot reconstruct this estimator.

Allocator recovery drains the GPU producer, clears only freed buffers, and
resamples. It does not release live model or KV state. The earlier local proof
used Safe Auto with a 128 MiB allocator cache; that is not evidence that the
reporter's retained pool contains enough bytes to resolve this refusal.

## Decisive capture from the existing build

The complete Run 2 `spawn_agent` error already contains `memory_decision` with
resident status, weight and child costs, reclaimable bytes, reserve, budget,
engine slots, and RAM slots. Obtain that object before requesting another
test build. When retained, the `SubagentAdmission` log also records successful
decisions and the recovery before/after measurement.

`scripts/live-proof/capture-ram-admission.sh` collects those retained logs,
`vm_stat` (including anonymous pages), swap, and process physical footprint
without restarting, clearing memory, or issuing a generation. Run immediately
after failure. Its output is private local evidence, not uploaded. An empty
info log is inconclusive; the error JSON is the fallback. Captured host
counters are later samples, not replacements for decision-time measurements.

Collector validation: `bash -n` and `git diff --check` passed; host-only
collection returned all three command statuses zero. The process variant was
checked against an explicitly owned, idle Python helper (not a model run):
all six commands returned zero, `vmmap` reported 6,928 KiB physical footprint,
and the output directory had mode 0700. Invalid PID text exits 64. Raw capture
files are in `/Users/eric/vmlx-private-evidence/ram-admission-2026-09-13/`.
This validates the evidence collector only; no new app or 16 GB acceptance
proof is claimed.

## Remaining gate

1. Attribute the actual refusal to the numerical host, budget, estimate, or
   reservation constraint; distinguish a bad estimate from a real shortfall.
2. If accounting or retention is wrong, reproduce that mechanism with a
   failing regression and correct its owner. Preserve actual batch memory
   charges, cancellation, and configured safety limits.
3. Run the affected regression and live matrix on the final code. The actual
   M4/16 GB acceptance rows are first minimal child, sequential children, and
   a fresh chat without restart with RAM on, handoff on, coexistence off,
   batch width one and same-model ceiling one. Record decision inputs,
   physical footprint, child output, throughput, and cleanup for each row.
4. Keep the report unresolved until those original failing scenarios pass.
   A 128 GB success or diagnostic memory override cannot close that gate.
