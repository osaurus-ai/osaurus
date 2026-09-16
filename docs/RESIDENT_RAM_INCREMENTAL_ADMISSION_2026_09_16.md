# Bounded resident-child admission

Proof snapshot: native Release replay and deterministic regressions on source
`327ecba03ea85b370e9fc70255c4071d001356e6`. The final full-model scores, failed-case
attribution, CI receipts and merge decision are recorded in
[PR #2784](https://github.com/osaurus-ai/osaurus/pull/2784).
No physical M4/16 GiB qualification is claimed.

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
has an execution-enforced bound, the model budget and allocator ceiling are
known, and the kernel reports normal pressure. The cold-load OS allowance is zero on that path;
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

## Qualification boundary

The final PR receipt must include targeted repeated-child/batching/cache evals,
full AgentLoop and AgentLoopFrontier scores, failed-case attribution and
exact-head CI. Those results are separate from the native and deterministic
receipts below. The local host has 128 GiB: injected 16 GiB-scale facts establish
policy behavior, not physical M4 paging performance. Full-model task quality
is not inferred from successful RAM admission.

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
removal. The combined-source native replay below exercises this correction.

The private host-statistics interposer only lowers reported available bytes
for two named test profiles. It preserves real pressure and physical RAM;
the independent supervisor observes the actual host. emulator-receipt.json
records uncapped, capped and wrong-profile controls plus source/dylib hashes.
The initial interposer helper crashed from recursive dlsym resolution; that
failed probe is retained and the corrected direct call-through probe passed.
This tests admission/lifecycle wiring, not physical M4 paging performance.

Local catalog reproduction: SWIFTTEST_ResidentCatalogTests0916__000021.log
runs the actual external locator and extracted production name-cache/matching
methods with the committed concurrency test. Old memo key: one test, two
identity assertions fail after catalog publication. New memo key: one test,
zero failures. Receipt and input hashes: catalog-tests-20260916-000021/receipt.json.
The harness scaffolds an empty managed catalog, isolated paths and display-only
model metadata; the separate native replay below covers the app path. The preceding 235952 run
also exposed a test URL trailing-slash comparison, corrected to compare paths.


## Combined-source native replay

SOURCE EVIDENCE: app `327ecba03ea85b370e9fc70255c4071d001356e6`,
engine `ea899b85036c12571798ba1987db6b3185e38d40`.
The source trace is `SubagentBatchAdmissionPlanner` (eligibility and arithmetic),
`ModelRuntime.generationAllocatorCacheLimit` / `sampleSubagentBatchMemoryFacts`
(shared actual allocator pricing), `ExternalModelLocator.catalogGeneration`
and `ModelManager.findInstalledMLXModelFromCache` (catalog publication), then
`ChatWindowManager.activeLocalModelNames` / `ModelRuntime.scheduleIdleResidency`
(open-window ownership). The native build is recorded in
`SWIFTTEST_ResidentRAMBuild0916__000117.log` and `release-receipt.json`.
Binary SHA256: `33f20e113ad2e5dfc796fdcfd1995fd0d7c35d5b0d11e9fe24bd86a8c1d2ab6f`.

LIVE EVIDENCE: `candidate327-history.sqlite`, `candidate327-history.json`,
`candidate327-native-summary.json`, `resident-ui-run2-measurements.jsonl`,
`resident-ui-run3-measurements.jsonl`, matching OSLogs, stream timing files and
`candidate327-*.jpg` / `*.ax.txt` under the private root. Actual native Chat and
Settings controls were used; tool arguments/results and terminal replies were
inspected. The isolated app was closed normally and both supervisors reported
zero owned processes remaining.

| Native scenario | Observed result |
| --- | --- |
| RAM Safety On; utilities Off; Core Model=Use chat model | Three fresh single-child chats, then sequential SysAdmin/Writer: 5/5 completed without restart |
| RAM Safety On; both title and follow-up utilities On | The same three-plus-two sequence: 5/5 completed without restart |
| Same-model batch, configured local/server concurrency 2 | 2/2 completed; actual tool result: engine slots 2, RAM slots 1, memoryCapacity limiting, local subwaves [1,1] |
| RAM Safety Off control | 1/1 child completed; effective planner bypass visible in logs |
| Active Writer cancellation | Parent Stop cancelled the observed running child; terminal error names parent cancellation, input unlocked |
| Next child after cancellation | 1/1 completed with RAM Safety On; parent follow-up repeated the actual returned code without tools |
| Relaunch persistence | RAM Safety On, handoff On, coexistence Off, local limit 2, utility toggles On and Core Model=Use chat model persisted; next child completed |

The histories contain 17 child sessions: 16 normal stop completions and one
intentional cancellation. The 16 include a long Writer response from the first
cancellation attempt, which completed before Stop was clicked. That attempt is
retained as a missed cancellation window, not cancellation proof. All 15
minimal-code children returned their requested code. The parent utility-On
sequential reply added `: ok` after each code; do not score that parent wording
as exact-string compliance. No completed child hit its length cap.

Native bundle: `OsaurusAI/gemma-4-E2B-it-8bit`, HF snapshot
`433003a1e3fbfd10819ad15179d5e3c4d02d7ea7`, weight bytes 5,899,232,198.
Runtime generation defaults: temperature 1, top_p 0.949999988079071, top_k 64,
min_p 0, no repetition override, sampler_was_changed=false. Child cap 2,048;
parent cap 16,384. Completed child speeds were 13.7–88.0 tok/s; parent terminal
speeds and per-stream delivery timings are retained separately. Cancellation
proves cleanup, not completion quality or a throughput pass.

The available-memory ceiling stayed 2,442,035,200 bytes and sampled pressure
was normal. Real host physical RAM remained 128 GiB; its available memory was
measured independently by the guard. Run2 lifetime maximum physical footprint
was 3,733,375,880 bytes (3.477 GiB), below the full weight size. Swap stayed
3,055.69 MiB across all 471 extended samples. Run3 peak was 3.431 GiB with the
same unchanged swap. These measurements do not identify the reporter's
historical swap producer.

Residency survived the repeated-child intervals. Idle unloads occurred at the
recorded deadlines (07:14:23Z, 07:15:15Z, 07:21:36Z), after the 30-second policy
window. This differs from the retained intermediate run's immediate unloads.
Paged RAM was off; disk L2 was on. Actual topology: 3 KV and 12 rotating KV
layers, disk-backed restore, required paged-boundary companion, zero TurboQuant
KV layers. Run2 process-lifetime disk-L2 counters ended at 44 hits / 456 misses /
131 stores; the native two-child batch contributed two hits. Final engine
active/pending counts were both zero. The process-lifetime high watermark of
two includes utility work and must not be misreported as the batch's wave width.

CI on the runtime source completed 358 eval-harness tests in 44 suites plus two
XCTest cases with zero failures, and RAMAdmission 18/18 deterministic fixtures
(run 35066442947, job 104697789100). The final PR receipt records the complete
Core/full-model outcomes and exact final-head checks. Documentation-only
follow-up commits must retain the built runtime SHA and verify that production
source, dependencies, tests and eval fixtures are byte-identical before reusing
these binaries; never relabel a binary with a later source SHA.


Retained initial Core CI failure: run 35066442947 reported 9,949 passed,
one failed and 54 skipped tests (10,004 unique tests; parameterized execution
counts differ). The failure was the unchanged
`ChatSessionQueuedSendTests.privacyCancelLeavesQueuedSendPending`: its one-second
wait for `isStreaming` threw code 2 after 1.141 seconds. The new catalog and
resident RAM suites passed. Final-head CI must complete before merge; no test,
timeout or assertion is weakened to suppress this failure. Receipt:
`ci-327-core-summary.json`, with downloaded xcresult and raw job log retained.
