# Model manifest admission and updates

Status: diagnostic Release d155473f5 rejected future999 in native Chat and HTTP400,
and displayed the Raptor revision0-to1 update badge/detail/action. Final refresh and
obsolete-manifest repair hardening, full live matrix, and exact-head CI are pending.
Diagnostic screenshots/API: `/Users/eric/vmlx-private-evidence/manifest-fix-2026-09-16`.

The 39fc21b baseline downloaded `osaurus.json` without reading its version contract.
The isolated Release audit accepted required version 999.0.0 in Chat and API and
showed a locally downgraded Raptor revision 0 as ready while HF published revision 1.
Baseline artifacts: `/Users/eric/vmlx-private-evidence/model-manifest-2026-09-16/REPORT.md`.

`ModelManifest` is the shared decoder for local admission, remote update checks and
pinned download preflight. Missing sidecars preserve legacy/offline operation.
Present unreadable/malformed sidecars fail explicitly. Unknown keys are tolerated;
both version fields are required when the file is present. `required_osaurus_version`
is SemVer and `model_version` is a non-negative
JSON string decimal counter. This matches the publisher contract in
`/Users/eric/jang/docs/runtime/OSAURUS-JSON-CONTRACT.md`. Revision comparison never uses lexicographic ordering
or machine-integer conversion. App build metadata is ignored for precedence;
prereleases precede final releases. Short Apple host versions have zero-filled
missing components. An unknown host version cannot bypass a declared minimum.

Automatic metadata top-up never stamps the latest manifest onto unverified older
weights. Explicit versioned downloads hash existing files before accepting the
publisher revision, including same-size weight replacements.

Runtime checks before cold loading and resident reuse, then again after automatic
metadata top-up. This host gate does not change generation or runtime settings.
Protocol errors use the existing invalid-request envelopes. Remote checks pin one
HF revision, retain authentication/proxy support, cap manifest reads at 64 KiB,
and distinguish absent sidecars from transport/authentication/parse failures.

The existing model detail and catalog show available publisher revisions. Update
Model uses the tracked Repair downloader, exclusive model lease, hash checking,
progress, pause/resume/cancel and atomic file replacement. The publisher sidecar
commits last. Pause/resume keeps the same immutable HF revision. A persistent incomplete-update marker prevents loading mixed files
after interruption and clears only after successful completion. External bundles
remain managed by their original application. Explicit Repair removes an obsolete
osaurus.json only after successful verification when the pinned repository no longer
advertises it; automatic top-up never removes it. Forced refreshes arriving during
another check are coalesced and run afterwards, including download completion. This does not implement automatic
updates or rollbacks; a cancelled update needs Resume or Repair.

Acceptance still required: focused parser/HTTP/admission tests, current CI, fresh
Release Chat/API future-version and malformed refusal, legacy and current model
multiturn, stale revision -> Update Model -> normal progress -> cleared status,
interruption/retry, relaunch, physical footprint and generation timing receipts.
