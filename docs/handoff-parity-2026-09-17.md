# Local subagent handoff parity

NOW: Focused correction on merged main ebabfb72ad1fd9b1a37b542e1c276d2961e620f8.
DO NOT: Claim full runtime proof, override Server Strict, or unload unrelated owners.
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

## Explicit boundaries

OFF continues to mean no explicit swap sequence, not guaranteed coexistence
under Server Strict. Coexistence remains OFF + Flexible + opt-in + fit. The UI,
guide and settings search explain this composition. A guaranteed-retention
contract needs a separate loader-policy change, not an omitted handoff call.

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
