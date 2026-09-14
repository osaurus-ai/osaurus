# RAM admission eval follow-up — 2026-09-14

Status: PARTIAL. PR #2752 is not qualified on the reporter's M4 16 GB hardware.
This follow-up integrates main `6e67eec2154eb23746c1075d92a1df2a8213c185`
with vMLX pin `5b0c8e6b8b29a7ead21fe785688bc0621580cc62` and strengthens
regression evaluation. It does not reduce the OS reserve or bypass RAM safety.

## What the reporter evidence establishes

The 0.25.2 capture has a resident target, zero incremental weight charge,
2,442,035,200 reclaimable bytes, a 3,221,225,472-byte OS reserve, and a
536,870,912-byte child bound. A single child needs 3,758,096,384 bytes of
measured headroom. Thus zero capacity follows from host headroom, not a second
weight charge. The capture alone does not establish why headroom declined.
Releasing an admission reservation does not establish that physical memory was
released. Historical swap usage and memory_pressure's free percentage are not
substitutes for the counters used by the admission estimator.

## Source and eval coverage

- `SubagentAdmissionEvaluator`: explicit injected host facts call production
  `SubagentBatchAdmissionPlanner.memoryFactsAfterReclaimingIfNeeded`, `plan`,
  and one `SubagentAdmission` actor across all steps. No model execution is
  simulated or claimed. Real delayed sampling is retained.
- `Suites/RAMAdmission`: 13 deterministic cases, registered in the catalog and
  the 1.0 CI floor. Repeated release, actual reporter cutoff, one-byte boundary,
  successful/failed/unknown reclamation, explicit budget, RAM off, same-model
  width two, memory/engine serialization, batching off and occupied-engine
  submission width versus total capacity.
- `AgentLoopEvaluator.ToolInvocation.spawnSummary`: the complete successful
  single-child digest is extracted before the 300-character forensic preview.
  Both ordinary and deduped result paths preserve it; the strict scorer rejects
  deduped/error/missing children, wrong order and wrong exact contents.
- `EvalRunnerAgentLoop`: explicit delegation settings use and restore the same
  settings store as production. Child budgets and server concurrency are
  fixture-controlled. Fresh-chat warmups retain the workers, runtime and caches,
  are independently scored/persisted, and require zero remaining reservations.
- `AgentLoopRAMAdmission`: four strict repeated trials each for single and
  sequential children, plus three fresh singles followed by a fresh sequential
  pair without restart. Exact child results are required, not parent echoes.
- `AgentLoopRAMControls`: independent RAM-off, handoff-off and coexistence-on
  same-model sequential controls. Existing native/disabled/architecture-capped
  batch cases now explicitly set RAM/handoff/coexistence too.

## Current evidence

Private artifacts: `/Users/eric/vmlx-private-evidence/ram-evals-2026-09-14/`.
No screenshots or model artifacts are committed to the repository.

- Full eval harness after target and transcript assertions: 353/353 tests,
  43 suites (`evals-final-tests.log`). The new policy fixture runner covers all
  13 committed memory scenarios. Scorer adversarial tests reject parent-only
  echoes, failed/deduped children, wrong order and truncated/missing evidence.
- `scripts/live-proof/assert-eval-floors-makefile-sync.sh`: 11 suite directories
  agree with floors; RAMAdmission is included.
- Affected Core matrix: 660/660 tests in 84 suites (`core-tests-retry.log`).
  The initial attempt is retained: one test compared `/private/tmp` to its
  `/tmp` canonical path, then the SwiftPM helper could not locate its Metal
  library. Retried without source changes using `/tmp` and the matching Cmlx
  bundle in the test bundle's Resources.
- Fresh isolated Release: build succeeded (`release-build.log`), binary SHA-256
  `9d42ed9dd5190296bed7f3acd5c464c590d54e760ecd031d3145862888d17148`,
  bundle `com.dinoki.osaurus.ramevals20260914`. Native UI evidence follows below; a later cancellation fix requires a new binary.
- First live targeted run on Core/eval source `cd93bfcf2`: 7/8 aggregate cases
  passed. Four single trials, four sequential trials and the reporter-order
  scenario passed, as did all three same-model setting controls and batching
  disabled. All 27 children were admitted and settled. Native width two
  admitted both children in `[2]`, but one exact digest failed after the parent
  changed its task to “Calculate the result BATCH_ALPHA_42.” The parent's final
  claimed the expected marker, demonstrating why parent-only grading is unsafe.
  The failed row is preserved, not retried into a reported pass. Physical
  footprint collector peak: 1,831.89 MiB. Parent final-step throughput is
  recorded per case; tool-call-step throughput is explicitly unavailable in
  this harness, and complete per-child speed qualification is not established.
- Follow-up transcript-only changes preserve full batch observations, validate
  ordered worker selectors and retain successful RAM/batch traces when
  `--transcripts` is enabled. These do not change the built Core runtime.
  The stricter run on `9b303cb65` again scored 7/8: RAM cases and all three
  controls passed; native width two passed, batching-disabled exact content
  failed. All 27 children were admitted and settled. The parent replaced both
  marker tasks with generic math/writing jobs; both actual child digests asked
  for missing context. All 17 trial/warmup transcripts are retained in
  `targeted-final/`, including successful full child observations.
- Full AgentLoop: 37 passed / 6 failed / 4 skipped; Frontier: 18 passed /
  21 failed. `full-agent-loop/` contains raw results and failure transcripts;
  `full-agent-loop-failures.txt` extracts every failed/skipped row. Failures
  include incomplete file edits, omitted artifacts, malformed tool arguments,
  budget/compaction/ordering violations and an existing rejection expectation
  mismatch. The local Gemma self-judge is not independent quality evidence.
  Prior branch live evidence is recorded separately in
  `ORCHESTRATOR_RAM_SAFETY_AUDIT_2026_09_13.md` and is not relabeled current proof.
- Reporter hardware qualification: absent. Required before claiming the
  recurring M4 16 GB failure resolved. Preserve measured refusals and capture
  before/after headroom plus process footprint; do not count a safe refusal as
  successful execution or injected 16 GB arithmetic as hardware proof.

## Native Release evidence and cancellation defect

`ui-single-1/2/3`, `ui-sequential`, and `ui-parent-followup` AX/screenshots
capture three fresh SysAdmin chats followed by a fourth fresh chat with
SysAdmin then Writer, without restarting. All five actual children returned
the requested markers. Child decode rates: 22.6, 31.3, 31.3, 30.6, 30.4 tok/s.
The grounded parent follow-up returned both markers at 83.2 tok/s. Expanded
payloads identify the intended worker IDs and `residency_mode: in_place`.

Native settings were saved and relaunched before the sequence: RAM ON,
handoff ON, coexistence OFF, local concurrency one. The RAM-off control then
returned RAM_OFF_OK at 30.0 child tok/s. `ui-admission-live.log` observes the
actual planner switch from `ramSafety=false` back to `true` after restoring
baseline. This proves same-model control behavior, not different-model swaps.

The native Stop probe exposed a separate completion race. The child stopped
mid-sentence, but its envelope said `ok: true` and had no usage. The immediate
next child returned AFTER_STOP_OK; therefore this row demonstrates admission
recovery but fails cancellation-result correctness and throughput qualification.
Artifacts: `ui-cancel-active`, `ui-cancel-settled`, `ui-after-stop-result`.
Source: `BackgroundTaskManager.cancelTask` called `ChatSession.stop()` before
setting `.cancelled`; stop synchronously publishes `isStreaming=false`, and
`handleChatStreamingChange` could resume the waiting dispatcher as completed.
The correction marks cancellation first. The regression asserts the pending
waiter's result, since the final state alone hides this ordering defect.
Current cancellation rebuild and verification are pending.

The native process peaked at 2,942.14 MiB physical footprint (not RSS), on
128 GiB physical RAM. Cache API captures show 3 ordinary KV + 12 rotating KV
layers, disk-backed restore, paged RAM off, zero TurboQuant KV layers, and
increasing disk L2 hits. Resident weight bytes: 5,899,232,198. This is not a
16 GiB footprint/capacity qualification. Cancellation and broader native
batch/handoff combinations must not inherit a pass from this evidence.
