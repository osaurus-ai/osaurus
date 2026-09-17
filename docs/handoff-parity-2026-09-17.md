# Local subagent handoff parity

NOW: PR #2796 at 662c0d460 includes main 51ee70e3e. Follow-up PR #2798 carries image/compaction and post-await corrections.
DO NOT: Claim full runtime proof, change global eviction policy, or unload unrelated owners.
BATCH OWNER: Parent identity, post-admission residency and AppleScript warm ownership.
NEXT: Complete the separate current-source auxiliary live matrix; retain the native run4 observations and full-catalog failures below.

## Source defects and correction

- Browser Use and Computer Use omitted the invoking model when resolving residency.
  They now pass the captured parent, preserve the canonical installed child ID,
  and inherit the actual invoking model rather than a later agent default.
- Browser/CU/AppleScript now refresh residency after admission using the same
  helper as text delegation. Selection and action permissions are not re-run or
  widened. A removed canonical local bundle fails closed, not into another route.
- AppleScript no longer forces the global swap setting ON. Its read-model shortcut
  is limited to the invoking parent, not an unrelated current resident.
- Cold and adopted warm execution bind their own child ownership token. Cold
  unload uses the shared exact-parent/restore-only implementation. Warm holds
  are keyed by parent/session/agent as well as child, verify current ownership,
  and are settled on settings changes before repricing residency. Cleanup is an
  owned cancellation-independent task; concurrent waiters join it and failed
  restores retain a receipt for retry instead of being reported as success.
- The live dedicated-helper run exposed another lifecycle conflict: ordinary
  idle policy treated its absent chat window as a closed chat and unloaded it
  between model steps. Handoff-owned children now use the handoff's cleanup/warm
  deadline instead; stale idle teardown rechecks ownership before committing.
  Unowned/shared residents still follow the configured idle/close policy. Load
  admission, pressure cleanup and explicit unload are unchanged. This correction
  still needs its fresh-build live reproduction.

## Explicit boundaries

The follow-up corrects OFF to mean scoped parent retention, including under
Strict. A runtime-registered permit binds the approved target to the parent's
exact residency generation. The loader validates it before/after its cold-load
slot and before publication. Idle/pressure/model-switch cleanup cannot take the
held parent; explicit unload/clear/quit still revoke the permission. Cleanup
drains only the job's cold-loaded children and releases the hold, including on
cancellation. Reused foreign targets never become cleanup-owned.

Queued delegation now captures that permit and child ownership at dispatch,
not when a different task later pumps the queue. Other dispatch sources do not
inherit it. RAM preflight, bundle load budgets and serialized generation remain
independent; rejection never silently falls back to parent eviction. The
redundant experimental coexistence control is removed, with its stored key
retained as an inert compatibility value. New policy proof is still pending.

Independent watchers/scheduled jobs have no invoking parent and remain
background/protected; nested delegation uses the job's own parent. The separate
PR #2798 brings image and compaction onto the shared parent policy; see
`auxiliary-handoff-parity-2026-09-17.md` for its source and proof boundaries.
No vMLX pin, sampler, prompt, permission or memory limit changed.

## Evidence (not yet complete)

Private audit and pre-change executable diagnoses:
`/Users/eric/vmlx-private-evidence/handoff-parity-2026-09-16/AUDIT.md`.
The separate native tool-stream batch fix is already merged as PR #2792; its
live receipts are not proof of this new parity patch. Current build, tests,
live rows, raw eval scores and remaining failures will be recorded separately.

At cc76420d4a10b9f230a1c2c377f54350b204d17d, CI run 35200968418 completed
all seven jobs. Live ON text and Browser Use handoffs restored their invoking
models, with completed follow-ups. OFF was inconsistent: Strict evicted the
parent for text but refused Browser Use's protected background load. The
dedicated AppleScript run failed to produce the requested scripts and was
cancelled; parent restoration was observed, but its follow-up stalled after
partial text and also required Stop. These are retained failures, not a clean
matrix. The isolated run exited normally with zero owned survivors. Computer
Use actual control execution remains untested without macOS Accessibility
permission. Full current-head live AgentLoop/Frontier coverage remains pending.

At f0b607aa63dac5209865bb3a98ae1a39d7780f32 the bounded build/test run
completed 222 tests across 11 suites and all seven CI jobs completed (35205344027).
Fresh dev binary SHA256
`b8854174839df0161d939d64600a4ec0e2d43207edc60a8a5a840ed598c539a1`
ran the two AppleScript jobs with native defaults. Both tool calls reached the
helper and OSA returned 42/45. Only one dedicated cold load served all 24 steps;
idle telemetry showed `policy=never handoffOwned=true chatReferenced=false`.
Parent restoration and follow-up 87 completed (41 tokens at 58.4 tok/s, then
11 tokens at 59.1 tok/s). However BOTH helper jobs repeated their scripts until
the 12-step limit and returned partial. The parent's "finished successfully"
claim was inaccurate. Helper rates were 36.2/37.0 tok/s. This is residency
evidence, NOT clean helper-loop quality proof. Peak tracked physical footprint
7.80 GiB; normal Quit exited 0 with zero owned survivors; swap 2.58 GiB unchanged.
Raw receipts: private implementation/run3-applescript-transcript.json,
run3-applescript-details.ax.txt/png, run3-applescript-followup.ax.txt/png,
run3-followup-health.json, run3.oslog and UI3 supervisor artifacts. These do not
prove the subsequent keep-parent changes.

## Retention app run4 at 662c0d460

SOURCE EVIDENCE: vMLX pin `8ba593aff16c13cf526211b8477c0a037f0122af`,
app SHA256 `54c44087f9f26b016c1687d3850b20ccc0e08b4ec33c542bb8b9c27b3f391e5c`,
UUID `C6F476EA-3520-388D-B1FE-D149AC25BFE3`. Focused tests: 244 tests,
15 suites, zero failures. CI 35212389755: seven successful jobs.

LIVE EVIDENCE: private `implementation/RUN4-LIVE-REVIEW.md`, `run4.oslog`,
`run4-measurements.jsonl`, persisted transcript exports and inspected AX/PNG
captures. One isolated development app on M5 Max2, not a release/install or
16 GB emulation. RAM preflight ON; Server Strict; native bundle defaults.

- OFF mixed native batch retained the exact Gemma parent through Raptor, then
  cleaned only its child. Both calls arrived; children returned 12 and 391.
  Parent incorrectly answered 392: transport/residency observed, answer FAIL.
- ON mixed batch unloaded Gemma, ran Raptor, restored Gemma and ran the same-model
  child in place. Final/follow-up 142 were correct, at 81.0/82.3 tok/s.
- Browser ON/OFF used the real local fixture and correct fields; OFF retained
  Raptor through Gemma, ON unloaded/restored it. Repeated phrases remain a
  quality limitation (parent rates 59.9–62.4 tok/s).
- Background spawn/report-back ON and OFF returned 437 and respected the parent
  setting. Natural worker resume FAILED because report-back omitted its session
  ID; explicit observed-ID resume returned 874. #2798 fixes the metadata and
  requires a fresh natural-resume row.
- Stop during child decode drained the child and restored the parent; subsequent
  generation completed at 78.5 tok/s. It referenced an earlier completed essay,
  so this is not evidence of cancellation-aware answer quality.
- Global and custom-agent settings were inspected OFF and ON; the latter refers
  to the one global authority. ON was saved before normal Quit. Relaunch on the
  next source remains part of that source's matrix.

Normal Quit exited 0 with zero owned survivors; peak tracked physical footprint
4.35 GiB, swap 2.56 GiB unchanged. The final parent follow-up correctly retained
437 (20 tokens, 76.8 tok/s). CU OS permission remains ungranted; image/compaction,
coalesced-waiter live interleaving and native schedule/watcher rows are not
qualified by these native text/Browser receipts.

Full unchanged catalogs were run through the source-bound transport driver:
AgentLoop **42 pass / 8 fail / 2 error / 4 skip (56)** and Frontier
**22 pass / 18 fail / 2 error / 0 skip (42)**. Every non-pass and rubric was
manually reviewed in `implementation/EVAL-REVIEW-662c0d460.md`. Interrupted and
contaminated attempts are retained, not substituted. No blanket quality or
regression-free claim follows from these scores. A removable-volume permission
request from the transport-only driver caused the earlier image-discovery stall;
it was denied. The driver now uses an empty image/model root and does not need
local weights or an OS permission grant.
