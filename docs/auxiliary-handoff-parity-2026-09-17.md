# Image and compaction handoff parity — implementation, proof pending

NOW: Follow-up PR #2798 at 197b077fb to PR #2796, based on 662c0d460. All seven CI jobs and 275 focused tests completed successfully; current-source same-model background resume was exercised in the development app. Auxiliary cross-model proof remains incomplete.
DO NOT: Count source inspection, parse checks or prior text/Browser receipts as image/compaction runtime proof.
BATCH OWNER: The actual invoking model and source across auxiliary producer lifetimes.
NEXT: Rebuild the grouped-session ownership correction, repeat actual scheduled-tab-close proof, and rerun affected suites/catalogs before merge. Image/CU execution remains permission-blocked.

## UI6 findings and grouped-session ownership correction

At197b077fb, compaction ON/OFF and nested scheduled Gemma→Qwen work executed through the actual controls. OFF retained the exact parent generation; ON drained the child and restored Gemma. OFF compaction follow-up and one scheduled arithmetic follow-up failed model quality; no sampler/prompt rescue was applied. Private RUN6-LIVE-REVIEW.md and RUN6-SCHEDULE-OWNERSHIP-FAILURE.md retain the measured rates and full transcripts.

Repeated Run Now with its prior conversation still open exposed a separate data-loss defect: dispatch hydrated another ChatSession for the same ID. The new run saved10turns; closing the old six-turn tab replaced that history with6turns. Correction reuses the idle window/shared/retained owner, refuses reattachment while that instance is busy, registers the new run before asynchronous preparation, resets old terminal observers/timers, and refreshes only model selection after picker discovery (never rehydrates the transcript twice). Busy grouped requests retain the existing independent-session behavior. Regression tests cover sources, inactive tabs, newer live edits, draft/history during preparation, cancellation and repeat completion. Fresh live proof is still required.

Current197 full catalogs: AgentLoop41passed/7failed/4errored/4skipped of56; Frontier19passed/21failed/2errored of42. Self-judged, not independent external grading. Raw/model-quality failures remain visible in private EVAL-REVIEW-197b077fb.md; these scores do not prove the new correction. UI6 quit normally07:43:21, zero survivors,3.56GiB peak physical footprint,2.56GiB swap unchanged. No release/tag/install.

## Source-bound defects

- `NativeImageJobContext` previously omitted parent/source. ImageSubagentKind captures context before detached consumption, but only tool/session IDs survived. The image coordinator also used a separate image load policy to decide parent unloading. It now receives explicit invocation provenance and uses the same exact-parent/protected-resident planner as text helpers.
- Image cleanup previously checked unloaded names, skipping restore-only leases. It now checks restore names through `isEmpty`, joins the job's producer before cleanup, and restores from cancellation-independent awaited cleanup. A written image remains available when parent restoration fails; restored names reflect actual verification.
- ImageGenerationService cancelled the task iterating the engine stream when the outward stream terminated. AsyncStream cancellation can end that iteration before an unstructured engine producer drains. Cancellation now stops a queued gate waiter or requests soft cancellation after entry; it does not cancel the engine consumer. Coordinator cleanup joins that exact job. Duplicate active job IDs are rejected.
- Context compaction used an interactive load with no invoking-parent handoff. ChatView now snapshots the selected model/source together with the turns, and the summarizer uses the shared lifecycle. The entire owned operation sits inside the non-rejoining timeout so a timed-out caller cannot release admission or restore over a still-draining producer.
- Restored scheduled/API/plugin parents previously lost their source on preload. Restore carries the original request source; preload supplies it only for a newly unused handoff-restored resident, never overwriting a resident already used by another request.
- A coalesced cold-load waiter must validate its own parent hold after waiting, not only the load creator's hold. All three return paths now revalidate after publication/warm-up; an explicit unload during that suspension cannot let a stale waiter continue. This is a source-audit correction with policy/wiring regression coverage; the concurrent live interleaving remains unproven.
- Current live retention build `662c0d460` reproduced a background continuation metadata gap: the acknowledgement and report-back omit the persisted worker `session_id`. A natural "continue that same worker" request failed; supplying the observed ID resumed the existing worker correctly. Background dispatch now retains its completed envelope and report-back includes only a validated UUID from a successful `spawn_result`. It never guesses from summary text, changes the immediate acknowledgement, or grants new continuation authority. Dispatch/delivery and malformed/failed/non-worker-result regressions cover this correction; fresh-build automatic resume remains required.

## Settings contract

| Situation | Shared swap ON | Shared swap OFF |
| --- | --- | --- |
| Different local auxiliary model, exact owned parent | Unload parent; execute; drain/unload child; restore parent | Hold exact parent generation; execute; release hold after cleanup |
| Same model or remote helper | No parent swap | No parent swap |
| No invoking local parent | Never infer the frontmost model | Never infer the frontmost model |
| Unrelated protected resident | No added eviction authority | No added eviction authority |

The image menu controls only post-job image cleanup. Persisted `agent_single_residency` remains decodable and maps to unload-after-job; it is no longer offered as a competing parent control. Restoring a swapped parent requires image unload regardless of keep-loaded preference. RAM preflight, server budgets, tool permission and concurrency limits remain independent.

Autonomous watchers/schedules do not borrow the frontmost chat parent. Their nested delegation uses that job's own selected model/source. Existing housekeeping/title/memory work remains background work without invented ownership. No vMLX pin, prompt, sampler, OS permission or runtime memory-limit change.

## Verification plan and current limits

- Added deterministic tests for explicit context across every SessionSource, typed success/failure cleanup, a delayed producer surviving a caller deadline, all persisted image policy values with swap ON/OFF, restore-only provenance, and queued/in-flight image cancellation.
- CI 35220765698 at 197b077fb completed all seven jobs. XCTest reports 413 tests, eight skipped, zero failures; Swift Testing suites also completed successfully. The local source-bound build12 completed 275 tests across 18 suites, zero failures. CI is not image/compaction runtime proof.
- Required live rows: actual global and per-agent reflected controls; save/navigation/relaunch; native generate/edit and Stop with a real installed compatible image model; configured compaction model ON/OFF with visible summary and parent follow-up; actual load/retention/restore traces, physical footprint and cache telemetry. Record token/s for any text generation. No implicit downloads or OS grants.
- CI run 35213560870 at 4f2a083a failed compilation before tests: the image coordinator's actor-isolated closure crossed a nonisolated `ModelJobInvocation.withContext` boundary (lines 346 and 379). The binding now inherits caller isolation explicitly; a MainActor regression exercises suspension and mutable actor-local captures. Fresh CI is required; this correction is not a runtime pass.
- CI run 35215438447 at 736c064e compiled and ran the suites, but failed two `RuntimePolicySourceTests` assertions that still searched for the old direct `return try await finishLoadedContainer` expression. The loader now publishes into a local, revalidates the caller's hold, then returns. The source tests retain the cancellation/drain checks and now check publication plus post-await validation on all three paths. The original failed run is retained; a new full CI result is still required.
- The prior retention app at 662c0d460 completed the native ON/OFF matrix and both full eval catalogs; see `handoff-parity-2026-09-17.md`. Original 24 GiB free-memory guard remains unchanged. Do not merge either scope on stale auxiliary app evidence. Dedicated AppleScript previous outputs hit their step limits; residency evidence does not erase that quality failure.

Private working audit: `/Users/eric/vmlx-private-evidence/handoff-parity-2026-09-16/implementation/FOLLOWUP-ROUTE-PLAN.md` and `ACTIVE.md`.

## Combined-source UI5 at 197b077fb

SOURCE EVIDENCE: app SHA256 `8c77400fe7048e2842616481f08e71978f11d3458f914b2e8b5a891597c45f22`, UUID `96B40967-B86E-3DB1-A3C5-7C685C020682`, unchanged vMLX pin above. Native Gemma E2B8bit snapshot433003a1, T1/P.95/K64/EOS1,106,50; real128GiB M5 host, not16GiB emulation.

LIVE EVIDENCE: private `implementation/RUN5-LIVE-REVIEW.md`, `run5.oslog`, `run5-measurements.jsonl`, persisted transcripts and inspected AX/PNG captures. Global swapON survived relaunch; actual OFF save and image cleanup Manual/Unload navigation were exercised independently of RAM preflight. Natural background continuation supplied the exact returned worker UUID without an external ID: child437 then874, parent/follow-up correct. Parent final/resume/follow-up82.4/80.7/82.0tok/s; child86.4/86.8tok/s. Extra time-tool call retained as a quality limitation. This is same-model execution, not cross-model media proof.

The rebuilt app's removable-volume permission was not granted. After denying the pending prompt, Raptor loads failed with unreadable osaurus.json; image catalog was empty. Two duplicate Raptor dispatches both failed and restored Gemma; do not call them admitted child successes or RAM refusals. Normal Quit exited0, zero owned survivors, peak2.67GiB physical footprint, swap2.56GiB unchanged. Current-source full catalogs, cross-model compaction/image execution, schedule/watcher and CU still require their own evidence.
