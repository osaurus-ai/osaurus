# Model manifest admission and updates

Status: implementation in progress; live Release proof and CI pending.

The 39fc21b baseline downloaded `osaurus.json` without reading its version contract.
The isolated Release audit accepted required version 999.0.0 in Chat and API and
showed a locally downgraded Raptor revision 0 as ready while HF published revision 1.
Baseline artifacts: `/Users/eric/vmlx-private-evidence/model-manifest-2026-09-16/REPORT.md`.

`ModelManifest` is the shared decoder for local admission, remote update checks and
pinned download preflight. Missing sidecars preserve legacy/offline operation.
Present unreadable/malformed sidecars fail explicitly. Unknown keys are tolerated;
optional `required_osaurus_version` is SemVer, `model_version` is a non-negative
JSON string decimal counter. Revision comparison never uses lexicographic ordering
or machine-integer conversion. App build metadata is ignored for precedence;
prereleases precede final releases. Short Apple host versions have zero-filled
missing components. An unknown host version cannot bypass a declared minimum.

Runtime checks before cold loading and resident reuse, then again after automatic
metadata top-up. This host gate does not change generation or runtime settings.
Protocol errors use the existing invalid-request envelopes. Remote checks pin one
HF revision, retain authentication/proxy support, cap manifest reads at 64 KiB,
and distinguish absent sidecars from transport/authentication/parse failures.

The existing model detail and catalog show available publisher revisions. Update
Model uses the tracked Repair downloader, exclusive model lease, hash checking,
progress, pause/resume/cancel and atomic file replacement. The publisher sidecar
commits last. A persistent incomplete-update marker prevents loading mixed files
after interruption and clears only after successful completion. External bundles
remain managed by their original application. This does not implement automatic
updates or rollbacks; a cancelled update needs Resume or Repair.

Acceptance still required: focused parser/HTTP/admission tests, current CI, fresh
Release Chat/API future-version and malformed refusal, legacy and current model
multiturn, stale revision -> Update Model -> normal progress -> cleared status,
interruption/retry, relaunch, physical footprint and generation timing receipts.
