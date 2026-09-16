# Bounded resident-child admission

Status: local policy reproduction and regressions complete; fresh Release UI
and exact-head CI are pending. No physical M4/16 GiB qualification is claimed.

## Causal result

The reporter supplied an already-resident target, 2,442,035,200 reclaimable
bytes, a 536,870,912-byte bounded child, no parent-release credit, and zero
capacity. The old planner subtracts a fixed 3,221,225,472-byte OS/app allowance
before pricing that child. Therefore it refuses even with all reservations
released. Repeating allocator cleanup cannot fix that inequality if the
post-cleanup sample remains 2,442,035,200 bytes.

That extra allowance came from the cold/coexistence model-load policy. Normal
chat reuse does not apply it. The host estimator already excludes wired,
compressed and non-purgeable anonymous memory, and the child price includes
KV/SSM state, transient/allocator slack and a 512 MiB minimum. The model's
configured total working-set budget remains an independent ceiling. Treating
every bounded resident continuation like an additional cold load imposes an
unrelated 3 GiB free-memory floor on delegation.

This establishes an over-conservative admission rule, not a memory leak or
the cause of the reporter's system-wide historical swap. The reported memory
percentage is not a kernel pressure-level sample. Do not infer that level.

## Policy correction and boundaries

Use incremental child pricing only when the target is resident, the request
has an execution-enforced bound, the model budget is known, and the kernel
reports normal pressure. The cold-load OS allowance is zero on that path;
weight reuse remains zero incremental bytes and each child still costs its
full bounded state estimate. At the reporter's byte count, a ceiling of one
admits one child and retains 1,905,164,288 measured bytes beyond its price.

Cold loads, unbounded requests, unknown pressure and warning pressure retain
the existing allowance. Critical pressure refuses RAM-safe local admission.
Failed or unfamiliar kernel samples remain unknown. RAM Safety Off continues
to bypass this optional gate. No swap-used cutoff, model-name exception,
minimum-one-slot override, prompt forcing or synthetic memory credit is added.

Pressure is sampled again after recovery alongside memory bytes. Diagnostics
distinguish the applied reserve from the cold-load allowance. Cache-status
telemetry now separates actual MLX active/cached/peak bytes from allocator
limits, so future retention analysis need not infer usage from a ceiling.

## Source evidence

- `SubagentBatchAdmissionPlanner.swift`: pressure sampling/decoding, explicit
  resident eligibility, capacity arithmetic, and decision diagnostics.
- `ModelRuntime.sampleSubagentBatchMemoryFacts`: supplies actual kernel
  pressure on every initial and post-reclaim sample.
- `SubagentAdmissionEvaluator`: the same production policy/reservation actor
  receives explicit pressure facts in model-free evals.
- `HTTPHandler.memoryStatusJSONObject`: actual allocator occupancy and host
  memory/pressure observability, with no allocator-policy change.

Apple XNU `osfmk/kern/host.c`, `vm_stats`, reports
`internal_page_count = vm_page_pageable_internal_count + local_q_internal_count`;
wired pages are separate. No wired/anonymous double-count correction was
justified. `bsd/kern/kern_memorystatus_notify.c` converts the pressure sysctl to
dispatch levels. The sampler recognizes only those defined values.

## Local execution evidence

Private root:
`/Users/eric/vmlx-private-evidence/ornith-vision-2026-09-14/ram-causal-audit`.

- Red: `SWIFTTEST_ResidentRAMTests0916__230057.log` ran the new reproduction
  against the unchanged old capacity arithmetic: 29 tests, 15 assertions
  failed in the new policy suite. The legacy planner/recovery suites passed.
  The prior 230031 attempt was a compiler-plugin setup failure, not a test run.
- Green: `SWIFTTEST_ResidentRAMTests0916__230507.log`: 39 tests in five suites,
  zero failures, including all 18 committed RAM fixtures. Source hashes and
  exact compiler argv are retained under `tests-20260915-230507`.
- The bounded helper compiles the actual planner, reservation actor and eval
  bridge. It removes only test-module imports and scaffolds the unused engine
  diagnostic type and remote fanout constant. It is not whole-app proof.
- Scenarios cover three singles then two sequential children at the reporter
  byte count, per-child batching costs, one-byte-short refusal, cold loads,
  model-budget shortfall, unbounded/unknown facts, pressure decoding,
  warning-to-normal recovery, critical pressure, and RAM Safety Off.
- Supervisor retained normal pressure, 24 GiB minimum reclaimable RAM,
  28 GiB owned-footprint cap, 1 GiB swap-growth guard and owned cleanup.
  All owned processes exited. No system memory purge or swap mutation.

## Remaining proof

Fresh isolated Release app, actual Chat/Settings and live allocator telemetry;
targeted repeated-child and batching evals; full applicable agent evals;
exact-head CI. Retain all failures and distinguish model task fidelity from
admission. The local host has 128 GiB: injected 16 GiB-scale facts establish
policy behavior, not physical M4 paging performance.
