# 0.25.1 same-model admission follow-up

Status: **PARTIAL — investigation and candidate correction, not reporter-qualified.**

Source base: Osaurus `4680ce594` (current `live/main` fetched September 12).
Runtime pin: `74103982a292a5037e82acca6f35b72dc1e75ea7`.
Worktree: `/Users/eric/osaurus-resident-child-ram`.

## Latest local evidence (supersedes progress entries below)

Production source tested: `ec721fece7779f2cb43139135ed51d6c732a523f`.
The subsequent catalog/documentation commit changes no runtime or eval-case code.
Release executable SHA256:
`40e65df07aec102e7050c0258b2daf8f0898df3f8a8ebe60e2fe00ee94971dda`.
The exact 8-bit bundle, native generation defaults and runtime pin are recorded below.

- Affected automated matrix: 460/460 tests in 28 suites passed.
- Real Metal recovery: 2/2 tests passed, including queued drain/cancellation
  and already-empty-pool resampling. The new empty-pool assertion failed before
  the correction. Live arrays retained their contents; 64 MiB of freed buffers
  were reclaimed only after gate acquisition.
- Exact-model AgentLoopRAMAdmission: single child 3/3 and two sequential
  children at ceiling one 3/3. Same-model two-worker batch: 3/3. Total 9/9
  trials, 15 successful child executions, exact markers, no admission errors.
  Peak footprints were 1,937 / 2,023 / 3,053 MiB respectively; final responses
  measured 34.98-39.16 token/s. These are harness rows, not native UI scores.
- Eval harness unit tests: 345/345 passed after adding the two new cases to
  the committed catalog manifest. CI initially caught that omitted inventory
  update (344 passed, one manifest mismatch); that failure is retained.

Native Release Chat/Settings proof used isolated storage and port 19312:

| Scenario | Actual result |
| --- | --- |
| Exact reporter SysAdmin prompt | 7/7 actual child markers and parent answers matched: initial load, new chat without restart, RAM off, RAM restored on, after Stop, batching off, and after app relaunch with batching restored on. Child envelope throughput 27.5-55.2 token/s; native final-response throughput 84.3-88.4 token/s. |
| Research then Marketing in separate turns | Both admitted and completed; strict task/output contract failed. Coordinator copied unrelated date instructions; Marketing returned a date while the parent claimed MARKETING-OK. |
| Two sequential children requested in one prompt | 0/2 workflow passes. Coordinator called spawn_batch over the one-child limit; the second attempt also repeatedly supplied an invalid target_type to spawn_agent. These were invalid_args before RAM admission, not stable_memory_refusal. |
| Two-slot same-model batch | Both children admitted, process active high-watermark rose from 1 to 2, and active/pending returned to 0 with one model loaded. Children measured 73.2 / 82.1 token/s. Requested marker contract failed because Coordinator invented larger research/marketing tasks. |
| Stop during active child generation | Stop disappeared, input unlocked, runtime active/pending returned to 0, and the next exact SysAdmin child passed. Partial text (1 through 139) was retained in an ok envelope; cancelled-child throughput was absent. Cleanup passed; cancellation-result presentation/throughput remains partial. |

UI process 57336 peaked at 3,624.43 MiB physical footprint (proc_pid_rusage,
not RSS). No stable_memory_refusal occurred on this 128 GiB host. Cache
telemetry reported 3 KV + 12 rotating layers, fp16 effective KV, disk-backed
restore, zero TurboQuant KV layers, paged RAM off, prefix on, and disk L2
reuse. The two-slot batch observed two additional disk L2 hits. Final restored
settings are RAM ON, handoff ON, coexistence OFF, continuous batching ON,
concurrency one, and child budgets 2048 tokens / 2 turns / 120 seconds.
The isolated spawn_agent Always Allow permission survived relaunch.

The UI failures are retained, not replaced with retries or prompt/sampler
repairs. The recovery branch does not run when initial RAM capacity is
positive; the observed UI batch had ram_slots=168. This correction therefore
must not be described as a fix for Coordinator task expansion, result
fabrication, or the complete reported workflow. The 16 GiB reporter workload
is still unqualified; the supplied counters cannot reconstruct its refusal.

Durable local artifacts:
`/Users/eric/vmlx-private-evidence/ram-admission-2026-09-12/` contains raw
reports, transcripts, memory samples, cache snapshots, build/test logs, and
SHA256SUMS.json. The initial broad model matrix remains 53 passed / 29 failed /
4 skipped out of 86 at c00bdbd2f, with self-judge and unavailable-fixture
limitations recorded below. CI for the catalog/documentation commit remains
a separate merge gate; its final result belongs in PR #2733.

## Report and acceptance boundary

M4 Mac mini, 16 GB, Gemma 4 E2B 8-bit for Coordinator and every child;
RAM-Safety ON, Handoff ON, Coexistence OFF, batch size and same-model ceiling 1.
Both the first trivial child and a second sequential child can fail with
`stable_memory_refusal` / `refreshed_capacity: 0`. A restart sometimes permits
one child. Research task expansion is also reported, but admission refuses
before the child runs. These facts do not establish a leaked reservation.

## Recent changes checked against current source

| Change | Shipped behavior / relevance |
| --- | --- |
| #2498 | Agent dispatch uses the real target chat session. |
| #2533 | Admission prices the enforced delegated context and output contract. |
| #2535 | Normal load and delegation share physical-minus-unreclaimable host memory accounting. The previous 128 GB UI proof was not 16 GB proof. |
| #2595 | KV estimates distinguish sliding, full and recurrent layer state. |
| #2592 | Delegated reasoning uses the child model's settings. |
| #2639 | Different local models use the handoff sequence; same-model reuse stays in place. |
| #2643, #2646, #2647 | Watcher folder resolution, knowledge paging and tool-result history do not release allocator buffers or bypass spawn admission. |
| #2688, #2692, #2695 | Admitted model forwarding reaches local/workspace dispatched agents. |
| #2720 | Sibling spawn calls execute as a wave, so recovery must cover both direct and batch memory-fact consumers. |
| #2718 (open) | Separates original task intent from the delegated delivery footer for tool-choice inference. It is not shipped in 0.25.1 and does not establish causality for arbitrary task expansion. Keep that candidate separate. |

## Source-confirmed reclamation gap

`SubagentSession.localInPlaceSlotCapacity` obtains memory facts after admission;
`SpawnBatchTool` uses the same `ModelRuntime.subagentBatchMemoryFacts` boundary.
The host estimator subtracts non-purgeable anonymous/wired pages. MLX's freed
buffer reuse pool is still allocated memory at that boundary. It can retain
parent/previous-child intermediates even though the next child could reuse
or release them. Ordinary generation restores the configured dynamic reuse
ceiling, not necessarily an empty pool.

`trimFreedBufferCacheUnderMemoryPressure` releases only freed MLX buffers under
the exclusive Metal gate. Before this candidate its only caller was the OS
memory-pressure responder. An admission refusal does not imply macOS emitted
that notification. Thus a final refusal can precede an available reclamation
operation. This is a concrete missing lifecycle step, **not yet proof that
the reporter's zero capacity has this cause**: the report lacks the numeric
admission log and allocator-pool measurements.

## Candidate contract

Before rejecting an otherwise affordable single child, attempt one guarded
freed-buffer trim and resample the complete memory facts. No arithmetic credit
for hypothetical reclamation. No forced slot, model exception, smaller hidden
context, sampler change, parent unload, or altered persisted allocator limit.
An active producer, unavailable estimate, explicit budget that cannot fit the
child, cancellation, or still-insufficient fresh memory remains fail-closed.
Direct spawns and batches share this step through ModelRuntime.

## Evidence and remaining work

- New deterministic recovery tests are being run with an empty model store.
  Eric explicitly authorized local app/model proof during this task.
- Runtime host reachable: `erics-m5-max.local`. It has a Gemma E2B QAT JANG_4M
  bundle on `/Volumes/EricsLLMDrive`; it is not the reporter's 8-bit bundle.
- Real 16 GB/8-bit first-child, sequential, stop/error/timeout, restart and
  numeric pre/post-trim proof remain required to close the reported defect.
- No release or merge has been performed.

## Reporter evidence added during investigation

Terminal snapshot after the failure: 16 GiB physical, 13,819.81 MiB swap used
(about 13.50 GiB), 231,956 wired pages (3.54 GiB), 173,737 compressor pages
(2.65 GiB), with 16 KiB pages. It does not include the internal/file-backed
page split used by admission, nor allocator cache bytes, so the precise RAM
inequality still cannot be reconstructed. Swap usage alone is not admission
capacity and does not establish a leak.

Screenshots downloaded and inspected:
`/private/tmp/osaurus-resident-child-ram-evidence/reporter-1.webp` shows a
~6.1 GB predicted load/cache allowance and the explicit warning that Use Anyway
does not disable runtime safety. `reporter-2.png` shows an observed 1.7 GB swap
increase while Gemma E2B 8-bit is running. The correction must preserve actual
insufficient-memory refusal, not convert either warning into permission to
ignore the gate.

Local store search, including `~/.cache/huggingface/hub` and mounted models,
found Gemma E2B QAT JANG_4M/MXFP4, but no E2B 8-bit snapshot. No weights were
downloaded or converted. The local host also has 128 GiB, not 16 GiB.

## Automated checkpoint

The pre-correction implementation (sampling once without recovery) failed the
new regression: 2 failed tests / 3 tests, 11 assertions, including both
sequential zero-capacity results. After correction, 15/15 tests in the recovery
and SubagentSession admission suites passed. This is deterministic injected
memory evidence, not a captured reproduction of the reporter's host state.
Logs: `/private/tmp/osaurus-resident-child-ram-red-xcode.log` and
`/private/tmp/osaurus-resident-child-ram-green.log`. Earlier setup attempts used
a relocated Clang module cache and then the CLT toolchain without Preview
macros; those were build setup failures, not test scores. Xcode's toolchain
was used for the executed tests.

A further cancellation regression and the wider related test matrix are now
running in `/private/tmp/osaurus-resident-child-ram-matrix.log`. The isolated
Release build log is `/private/tmp/osaurus-resident-child-ram-release.log`.

Refusal metadata now includes the original decision's model/resident status,
actual bounded child charge, cap charge, reclaimable bytes, releasable parent
bytes, OS reserve, load budget, RAM slots and limiting factors. It does not
resample after refusal to manufacture a reason. The rejected-plan headroom
field also reports the effective bounded cost rather than the larger cap cost.

## Expanded verification

- 281/281 tests in 23 suites passed in the broader matrix. Includes the added
  Stop-during-capacity-recovery regression, direct two-child lifecycle,
  batching, RAM toggles, handoff, model/budget forwarding, watcher paths, and
  Metal gate ownership/cancellation. No models loaded in this test matrix.
- Opt-in real Metal allocator test passed 1/1: cache bytes 67,108,864 -> 0;
  live allocation remained 12 bytes and its contents survived. Host reclaimable
  bytes were 94,158,159,872 -> 94,224,482,304. This validates actual freed-buffer
  reclamation, not the reporter's memory state.
  `/private/tmp/osaurus-resident-child-ram-allocator-ready.log`.
- The first opt-in setup attempt could not locate the metallib. The executed
  row colocated the matching Release-build metallib as `mlx.metallib` beside
  the xctest executable; no source or kernel fallback was introduced.


## Producer-drain correction and final candidate tests

Tool invocation is intentionally dispatched before the engine-owned terminal
cache drain. The producer retains the Metal gate until serialization and
allocator-window teardown complete; its runtime task record can outlive the
gate while releasing a model lease and scheduling idle residency. Admission
recovery now waits cancellably for the exclusive GPU gate instead of refusing
to recover merely because that task record is still present. Normal pressure
notifications retain their skip-while-active behavior. No global tool-dispatch
barrier, forced slot, sampler change, or model-specific exception was added.

Final expanded matrix: 349/349 tests in 27 suites passed, including
SubagentAdmission, SubagentSessionAdmission, SubagentBatchAdmission, SpawnBatch,
DelegatedBudget, DelegatedModel, SubagentResidency, ChatResidencyHandoff,
OwnedSubagent, MetalGate, ModelRuntimeFindDirectory, ChatToolChoicePolicy,
Watcher, SwapPressureMonitor, ModelRuntimeRAMFeasibility, MemoryWarningState,
and GenerationEventMapper. Log: `/private/tmp/osaurus-resident-child-ram-final-matrix.log`.

Real Metal proof: 2/2 tests (the producer-drain test has two parameter cases)
passed. Recovery waits behind the generation gate, then frees 67,108,864 bytes;
cancellation while queued leaves all 67,108,864 bytes untouched. The retained
array test keeps its 12-byte live allocation and correct contents. Log:
`/private/tmp/osaurus-resident-child-ram-allocator-final.log`.

The exact reporter bundle was absent from the local stores, then downloaded
into the Hugging Face cache: `OsaurusAI/gemma-4-E2B-it-8bit`, revision
`433003a1e3fbfd10819ad15179d5e3c4d02d7ea7`, 5,932,060,468 bytes across 11 files.
Bundle generation defaults are temperature 1, top-p .95, top-k 64, sampling on,
EOS IDs [1, 106, 50]. This supersedes the earlier QAT-only model-availability
limitation. The host remains 128 GiB; it does not reproduce the reporter's
16 GiB hardware or system-wide swapped workload.

Swap/prelaunch source trace: SwapPressureMonitor state feeds the chat warning,
not the admission planner. Normal load, UI prelaunch projection, handoff and
spawn use the shared physical-minus-wired/compressor/nonpurgeable-anonymous
estimator. The reporter's memory_pressure output omits internal_page_count,
so its 59 percent headline is insufficient to reconstruct that estimator.
The prelaunch projection is advisory for ordinary mmap loads; materialized
loads and the resolved memory-safety plan have their own authoritative limits.
Same-model admission charges weights once against the total model budget,
zero incremental weight bytes when resident, and bounded KV/activation state
per concurrent child. Batch engine capacity and reservation ownership remain
independent clamps; recovery never changes either.

Isolated Release UI onboarding completed, telemetry disabled. RAM-safety,
handoff and coexistence toggled and restored to ON/ON/OFF; persisted JSON
matches. Research, Marketing and SysAdmin models changed via UI to exact E2B
8-bit with visible Saved state. Full post-relaunch workflows remain pending.
AgentLoop and AgentLoopFrontier exact-model evals are running at
`/private/tmp/osaurus-resident-child-ram-evals-full.log`; reports are in
`/private/tmp/osaurus-resident-child-ram-evals/reports`. No external judge key
is available, so rubric results require manual attribution. Physical-footprint
samples use proc_pid_rusage RUSAGE_INFO_V2, not RSS, and are stored in
`/private/tmp/osaurus-resident-child-ram-evidence/physical-footprint.jsonl`.

Status remains PARTIAL pending live workflows and complete eval results.

## Concurrent recovery correction

Two callers can sample a refusal before the first caller clears the allocator
pool. The second must request fresh facts even when its own trim frees zero
bytes. Successful admission drain now always resamples, while cancellation
still returns without granting capacity. The real Metal regression failed
before this correction (1 failed / 2 tests, one assertion), then passed 2/2
with both queued cancellation/drain cases. Logs:
`/private/tmp/osaurus-resident-child-ram-empty-pool-red.log` and
`/private/tmp/osaurus-resident-child-ram-empty-pool-green.log`.
The combined affected automated matrix passed 460/460 tests in 28 suites at
`/private/tmp/osaurus-resident-child-ram-complete-matrix.log`.

Added AgentLoopRAMAdmission cases for a single child and two separate
sequential children under a one-session ceiling, with empty worker personas
and native bundle samplers. Repeating these cases tests fresh agent loops
against retained runtime state; assertions check exact result markers, tool
counts and tool errors without using a judge. Local Release UI scenarios are
being repeated with the reporter's actual SysAdmin prompt and the
Research/Marketing sequence, including a fresh chat without process restart.

Initial full model matrix at c00bdbd2f: AgentLoop 33 passed / 10 failed /
4 skipped out of 47; AgentLoopFrontier 20 passed / 19 failed out of 39.
Combined: 53 passed / 29 failed / 4 skipped out of 86. Same-model two-worker
batch passed with effective width 2, two successful exact results, 1,870 MiB
peak physical footprint, disk L2 reuse, and a 34.81 token/s final continuation.
These scores are not represented as a perfect model-quality pass. The final
empty-pool change is inside the refused-admission recovery branch; the focused
reported-scenario lane is being rerun on that updated production code.
