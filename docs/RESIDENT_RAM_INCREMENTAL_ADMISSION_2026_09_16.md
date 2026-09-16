# Bounded resident-child admission

Status: final policy/allocator regressions passed locally; fresh Release UI
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
has an execution-enforced bound, the model budget is known, a known allocator ceiling, and the kernel
reports normal pressure. The cold-load OS allowance is zero on that path;
weight reuse remains zero incremental bytes and each child still costs its
full bounded state estimate. At the reporter's byte count, a ceiling of one
admits one child after also charging the full 1,474,808,049-byte allocator
ceiling, leaving 430,356,239 bytes beyond both allowances. The allocator is
shared: charge its full prospective generation ceiling once per wave, not once
per child. Current cached bytes are not credited because they may be compressed
or nonresident. The same helper resolves native-MTP/architecture-specific
generation windows and admission; the profile display default is insufficient.

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

Build `SWIFTTEST_ResidentRAMBuild0916__230705.log` was deliberately stopped
(exit130, owned cleanup zero) before acceptance to include the allocator pool
allowance found during review. It is not a build/test failure or runtime proof.

Final focused rerun after shared allocator pricing: `SWIFTTEST_ResidentRAMTests0916__231402.log`,
40 tests / five suites / zero failures, including all 18 committed fixtures.
`tests-20260915-231403/source-receipt.json` records exact inputs and argv.

## Native replay found a second causal path

The unchanged baseline app (09cee61, binary d4b1b6f) reproduces the exact
2,442,035,200-byte resident refusal in native Chat with RAM Safety On. Turning
that control Off admits the identical SysAdmin request and returns RAM_FIRST_OK;
a follow-up repeats the actual tool result. Source, image and process receipts
are under ram-causal-audit/baseline-ui-run1-* and baseline-on-decision.*.

Candidate 57be5d9 (binary 39aaa9e6) admits the first child with RAM Safety On,
normal pressure and the full 1,474,808,049-byte allocator allowance. Its second
fresh chat refuses because the model has become nonresident. Half-second live
samples show unloading immediately after each generation, despite an open
chat and the saved 30-second idle policy. This is a retained failed row,
not proof of repeated-run success (resident-ui-run1-*, candidate-off-single2-*).

The cache-only name resolver versions its memo by registry identity, but the
nonblocking external catalog initially returns an empty/stale snapshot and
later publishes the completed catalog without changing that registry version.
A cached miss therefore survives publication. The model remains loadable via
the blocking runtime resolver while the open-chat reference set omits it;
scheduleIdleResidency treats that omission as a closed window and unloads at
the parent/child boundary. The same miss also labels the picker as generic
"Model ready" instead of a local loaded/cold state.

The correction versions the name memo by both registry and materialized
catalog generation. ExternalCatalogResidencyTests holds catalog construction
after registration, caches the provisional miss, completes construction
without a registry change, and checks both local identity recovery and later
removal. Native repeated-run proof must be repeated on this combined source.

The private host-statistics interposer only lowers reported available bytes
for two named test profiles. It preserves real pressure and physical RAM;
the independent supervisor observes the actual host. emulator-receipt.json
records uncapped, capped and wrong-profile controls plus source/dylib hashes.
The initial interposer helper crashed from recursive dlsym resolution; that
failed probe is retained and the corrected direct call-through probe passed.
This tests admission/lifecycle wiring, not physical M4 paging performance.
