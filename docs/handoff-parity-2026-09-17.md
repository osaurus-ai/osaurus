# Local subagent handoff parity

NOW: Focused correction on merged main ebabfb72ad1fd9b1a37b542e1c276d2961e620f8.
DO NOT: Claim full runtime proof, change global eviction policy, or unload unrelated owners.
BATCH OWNER: Parent identity, post-admission residency and AppleScript warm ownership.
NEXT: Run deterministic regressions, a fresh isolated development app, affected evals and exact-head CI before merge.

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
background/protected. Image jobs own their producer and load policy; compaction
is a separate helper and is not changed by this patch. Do not claim those routes
follow this switch. No vMLX pin, sampler, prompt, permission or memory limit changed.

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
