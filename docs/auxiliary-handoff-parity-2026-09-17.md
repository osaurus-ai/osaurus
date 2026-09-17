# Image and compaction handoff parity — implementation, proof pending

NOW: Follow-up PR #2798 to PR #2796, based on 662c0d460. Image/compaction source changes remain separate from the retention app currently building at 662c0d460.
DO NOT: Count source inspection, parse checks or prior text/Browser receipts as image/compaction runtime proof.
BATCH OWNER: The actual invoking model and source across auxiliary producer lifetimes.
NEXT: Full-module tests, source-bound isolated app, ON/OFF controls and actual image/compaction execution before merge.

## Source-bound defects

- `NativeImageJobContext` previously omitted parent/source. ImageSubagentKind captures context before detached consumption, but only tool/session IDs survived. The image coordinator also used a separate image load policy to decide parent unloading. It now receives explicit invocation provenance and uses the same exact-parent/protected-resident planner as text helpers.
- Image cleanup previously checked unloaded names, skipping restore-only leases. It now checks restore names through `isEmpty`, joins the job's producer before cleanup, and restores from cancellation-independent awaited cleanup. A written image remains available when parent restoration fails; restored names reflect actual verification.
- ImageGenerationService cancelled the task iterating the engine stream when the outward stream terminated. AsyncStream cancellation can end that iteration before an unstructured engine producer drains. Cancellation now stops a queued gate waiter or requests soft cancellation after entry; it does not cancel the engine consumer. Coordinator cleanup joins that exact job. Duplicate active job IDs are rejected.
- Context compaction used an interactive load with no invoking-parent handoff. ChatView now snapshots the selected model/source together with the turns, and the summarizer uses the shared lifecycle. The entire owned operation sits inside the non-rejoining timeout so a timed-out caller cannot release admission or restore over a still-draining producer.
- Restored scheduled/API/plugin parents previously lost their source on preload. Restore carries the original request source; preload supplies it only for a newly unused handoff-restored resident, never overwriting a resident already used by another request.
- A coalesced cold-load waiter must validate its own parent hold after waiting, not only the load creator's hold. All three return paths now revalidate after publication/warm-up; an explicit unload during that suspension cannot let a stale waiter continue. This is a source-audit correction with policy/wiring regression coverage; the concurrent live interleaving remains unproven.

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
- Swift parser and localization/diff checks have run; these are not typechecking or runtime proof. Full-module compilation/tests and current CI still required.
- Required live rows: actual global and per-agent reflected controls; save/navigation/relaunch; native generate/edit and Stop with a real installed compatible image model; configured compaction model ON/OFF with visible summary and parent follow-up; actual load/retention/restore traces, physical footprint and cache telemetry. Record token/s for any text generation. No implicit downloads or OS grants.
- CI run 35213560870 at 4f2a083a failed compilation before tests: the image coordinator's actor-isolated closure crossed a nonisolated `ModelJobInvocation.withContext` boundary (lines 346 and 379). The binding now inherits caller isolation explicitly; a MainActor regression exercises suspension and mutable actor-local captures. Fresh CI is required; this correction is not a runtime pass.
- The retention app build resumed after host memory recovered, with the original 24 GiB free-memory guard unchanged. Do not merge either scope on stale app evidence. Dedicated AppleScript previous outputs hit their step limits; residency evidence does not erase that quality failure.

Private working audit: `/Users/eric/vmlx-private-evidence/handoff-parity-2026-09-16/implementation/FOLLOWUP-ROUTE-PLAN.md` and `ACTIVE.md`.
