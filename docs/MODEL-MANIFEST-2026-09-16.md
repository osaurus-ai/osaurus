# Model manifest admission and updates

Runtime source tested: `340d20a619c8ce896a088b92f81216b7afcab1ed`.
The Release app exercised manifest refusals, normal downloads, update detection,
pause/resume/cancel, interruption across relaunch, and explicit Repair recovery.
This document records that run; it does not independently attest later source changes.
PR and CI status: <https://github.com/osaurus-ai/osaurus/pull/2789>.
Evidence root: `/Users/eric/vmlx-private-evidence/manifest-fix-2026-09-16`.

Follow-up: the final source review reproduced a dangling HF-cache manifest symlink
being treated as absent (`broken-manifest-before.log`). The follow-up rejects that
unreadable sidecar and allows explicit Repair to remove it when upstream has no
manifest. Valid symlinks remain supported. Fresh Release and CI receipts for this
follow-up belong in the PR proof record; the historical matrix below remains tied
to its stated source SHA.

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

## Source and artifact identity

- Shared contract: `Services/ModelManifest.swift`; local gate:
  `Services/ModelRuntime.swift`; HTTP mapping: `Networking/HTTPProtocolErrors.swift`.
- Remote/pinned downloads: `Services/HuggingFaceService.swift` and
  `Services/ModelDownloadService.swift`; update refresh:
  `Managers/Model/ModelManifestUpdates.swift`; controls:
  `Views/Model/ModelDetailView.swift` and `Views/Model/ModelDownloadView.swift`.
- Engine pin: `8ba593aff16c13cf526211b8477c0a037f0122af` (unchanged).
- App: `/private/tmp/osaurus-manifest-340d20a6.app`; binary SHA-256
  `a9755e655cfc3cf9ab0f36f5f1217a1585664f76c87d54cabe07fa32c22a8e91`.
- The isolated development bundle reports version `1.0`. The private future-version
  fixture requires `999.0.0`; this is not a claim about an official release's version.
- `release-receipt.json`, `LIVE-RECEIPT.json`, and `live/run{3,4,5}-launch.json`
  record source, engine, metallib hashes, command identity, profile, and instrumentation.
  The app uses a private model/profile directory. Original user models were unchanged.

## Observed live behavior

| Contract | Observation and artifact under the evidence root |
| --- | --- |
| Future minimum, cold | Native Chat displays the version error; OpenAI Chat, Anthropic Messages, Responses, and Ollama Chat each return HTTP 400. `live/future-chat-340.*`, `live/future-cold-protocols.json` |
| Future minimum, resident | Health confirms SmolLM is resident; all four APIs then refuse after its private manifest changes. `live/warm-health-before.json`, `live/future-warm-protocols.json` |
| Malformed present file | Explicit native Chat and HTTP 400 error, without silent legacy fallback. `live/malformed-chat-340.*`, `live/malformed-cold.json` |
| Obsolete manifest | Actual Repair removes the invalid sidecar absent from the pinned upstream repository; completion message is visible. `live/obsolete-repair-complete.*`, `live/obsolete-repair-receipt.json` |
| Update detection | Raptor installed revision 0 versus remote 1 shows the catalog badge, minimum host version, and Update Model action. `live/update-card-340.*`, `live/update-detail-340.*` |
| Transfer controls | A one-byte fault in the private Raptor weight triggers a real transfer. Pause at 29%, Resume to 56%, then Cancel are exercised. The manifest stays at revision 0 and admission refuses the incomplete bundle. `live/update-{transfer,paused,resumed,cancelled}.*`, `live/paused-update.json` |
| Atomic cancellation | The cancelled transfer leaves the destination's original faulted hash unchanged. The test byte is restored locally after app exit; this is explicitly not a completed weight-download claim. `live/raptor-private-fault.json`, `live/cancel-atomic-restore.json` |
| Restart and recovery | The pending marker survives app restart and still yields HTTP 400. Repair verifies the restored weights, downloads revision 1, clears the marker, and removes the badge. All 13 downloaded Raptor files match pinned HF hashes. `live/restarted-incomplete.json`, `live/update-complete.*`, `live/raptor-update-completed-hashes.json` |
| Regular Download | MiniCPM's actual catalog Download button verifies cached weights and restores missing config/manifest metadata. All 11 downloaded files match pinned hashes; the pending marker is absent. `live/minicpm-normal-download-*.{png,txt}`, `live/minicpm-download-completed-hashes.json` |
| Manual refresh and persistence | Check for Model Updates is clicked; current revision remains 1. Raptor's cleared badge and usable conversation survive relaunch. `live/manual-update-check-*.{png,txt}`, `live/update-cleared-after-relaunch.txt`, `live/raptor-relaunch-turn.*` |

### Model results and limits

Raptor `OsaurusAI/Raptor-0.6-4B-JANG_6M` (HF commit
`41328ca5650100fa2e1913b1be7124ef33cc51c8`) and MiniCPM
`OsaurusAI/MiniCPM5-2B-JANG_8M` (HF commit
`552b42daf18656830e5979eef603f8517d7727ca`) are text models in these bundles.
They retain bundle sampler defaults: temperature 1, top-p 0.95; Raptor declares
top-k -1 and repetition penalty 1, while MiniCPM declares no top-k. Raptor Chat's
Thinking control is On (changed from an earlier private test's Off setting);
MiniCPM stays Default. API requests supply no sampler or thinking overrides.

| Run | UI/client TTFT | Decode tok/s | Engine prompt tok/s | Result |
| --- | --- | --- | --- | --- |
| Raptor Chat 1 / 2 | 4.22 / 0.30 s | 104.22 / 104.35 | 438.02 / 26,130.18 | Correct blue-kite answer and remembered object |
| Raptor after relaunch | 0.34 s | 104.93 | 18,596.09 | Correct follow-up |
| Raptor API | 0.515 s client | 108.93 | 65.83 | HTTP 200, stop, answer 12 |
| MiniCPM Chat 1 / 2 | 1.28 / 0.27 s | 150.27 / 149.18 | 1,574.39 / 62,885.14 | Correct answer and remembered object |
| MiniCPM API | 0.696 s client | 164.19 | 79.46 | HTTP 200, stop, answer 12 |
| Legacy SmolLM Chat 1 / 2 | 2.73 / 0.10 s | 337.86 / 401.83 | 191.09 / 34,549.22 | Admission succeeds; first answer correct, second repetitive/wrong |

All nine generations stopped normally and reported `unclosedReasoning=false`.
Visible-answer correctness was 8/9: Raptor 4/4, MiniCPM 3/3, SmolLM 1/2. The
SmolLM follow-up is a **failed quality row**, not a model-family qualification.
The baseline audit also recorded an incorrect SmolLM answer, but this run does not
establish the cause of its repetition. No output filtering or sampler adjustment
was added to improve that result.

Prompt throughput is the engine's reported metric. Cache-hit rows include restored
prompt tokens and must not be presented as raw prefill throughput or speedups.
Logs record disk restores of 1,773 / 1,691 Raptor tokens and 2,548 MiniCPM tokens;
the exact effective cache/settings snapshots are in the API receipts and final
runtime state. This is not a cache-topology, multimodal, 16 GB delegation, or broad
performance qualification.

Independent 1-second Activity Monitor-style `phys_footprint` samples peaked at
4.00 GiB for run 3, 2.78 GiB for run 4, and 2.40 GiB for run 5. The separate
owned-process supervisor retained the 24 GiB reclaimable-RAM, normal-pressure,
28 GiB footprint, 1 GiB swap-growth, timeout and ownership guards. Swap remained
2.79 GiB across all three runs; each exited with zero owned processes left.
No model-memory emulation, OS swap clearing, or unrelated process termination was used.

## Automated evidence

`Tests/Service/ModelManifestTests.swift` covers semantic and numeric revision
ordering, unknown host versions, malformed/oversized local and remote data,
404 versus authentication errors, pinned resume, automatic-top-up exclusion,
explicit obsolete-manifest removal, and HTTP error envelopes. The independent
production-source parser/admission probe passed 41/41 checks
(`parser-probe-340.log` and its hash receipt); that probe is not the full core suite.

CI run <https://github.com/osaurus-ai/osaurus/actions/runs/35156151482> tests the
runtime source above. Retained raw logs include CLI 32 tests / 3 suites,
StatsPack 20 tests / 4 suites, and Evals 355 Swift Testing tests / 44 suites plus
2 XCTest tests. Scripted eval totals are 143 passed / 158 total, 15 model-driven
cases skipped, 0 failures/errors; those skips are not live model proof. The PR
proof receipt records the completed core job and final merge qualification separately.
