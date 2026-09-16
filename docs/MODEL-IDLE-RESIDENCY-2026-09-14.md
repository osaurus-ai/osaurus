# Model idle residency and swap-warning removal

## Current isolated integration — September 15

Status: PARTIAL. The idle policy from PR #2771 is integrated with the SSD
notice from #2783, core-utility owner preservation, and persistence of the
explicit Use chat model choice. The vMLX pin remains main
`5b0c8e6b8b29a7ead21fe785688bc0621580cc62`. Fresh Release, native UI and
applicable eval results for this integration are pending. Historical results
below belong to the named earlier commits and do not qualify this source.

Private tests use the user-approved 24 GiB reclaimable-RAM floor, normal
pressure, 1 GiB swap-growth limit, 28 GiB owned physical-footprint cap,
1800-second timeout and process-identity cleanup. Existing swap is observational.
No macOS swap or app admission policy is changed by these test guards.

Required current rows: Keep Loaded off/on/save/relaunch, timed idle despite
focus, chat close with utilities off/on and Core Model set to Use chat model,
API-owner protection, active-request close/cancellation, repeated and sequential
Gemma children, different-model handoff/restore, restored SSD notice controls,
full applicable eval scores with failures retained, exact-head CI.
The M4/16 GiB reporter outcome remains unverified.

## Historical PR #2771 record

Status: PARTIAL. CI's unchanged-source repeat completed successfully, but the
new local dev app has not linked and all source-bound live UI rows remain
required. PR stays draft and unmerged. Preserve the first CI failure below;
a successful repeat is not a causal diagnosis or live model/UI proof.

NOW: Remove the swap/predicted-RAM confirmation UI and make idle residency bounded.
DO NOT: Tune macOS swap, change runtime admission/samplers, release active leases,
or publish a release. Engine pin remains unchanged.
BATCH OWNER: App-only lifecycle checkpoint.
NEXT: Complete the isolated local development build when the shared machine
meets the existing resource gates, then actual settings/chat/delegation proof,
final diff review and PR promotion.

## Source-bound plan

- `FloatingInputCard`: remove predicted/measured swap banners, Use Anyway gate,
  Send/Send Now RAM rechecks and context-popover memory advisory. Keep actual
  runtime load failures, context-size errors and bundle-layout advisories.
- `ServerConfiguration`: default idle policy becomes 30 seconds. Keep Model
  Loaded is an explicit toggle mapping to the existing `never` policy; off
  restores 30 seconds. Retain an Unload After menu for explicit timed choices.
  Missing config starts off. Migrate the old 900-second default once; retain
  explicit never, immediate and other custom timeouts. Old saved JSON cannot
  distinguish an explicit 15-minute choice from the former default; both migrate.
- `ModelRuntime`: focus is observational, not permanent timer cancellation.
  Saved policy changes refresh existing idle timers. Generation/preload completion
  arms a timer only with zero leases. Existing decision identities, drain gate,
  other-window/API ownership and never-policy guards remain authoritative.
- Window close already accelerates chat-owned idle timers to zero; extend the
  same safe release to a detached chat run when it finishes after window close.
- `SwapPressureMonitor`: remain read-only. Move sampling out of the composer
  into the existing off-main system resource tick. Add bounded, consent-gated,
  content-free telemetry for episode/phase/severity changes. Host swap/rates do
  not prove model causality. Never transmit model paths, prompts or output.

## Required evidence

- Default/migration/toggle round trips, timer refresh/cancellation/lease races,
  no warning/send gate, settings search and telemetry consent/deduplication tests.
- Fresh source-bound dev binary and exact unchanged engine pin.
- Real UI: send without warning/acknowledgment, completed coherent answer and
  token/s; resident-to-unloaded at ~30 seconds despite focus; immediate idle
  window-close unload; keep-loaded enabled survives idle/close; setting survives
  navigation and relaunch; off re-arms an already-loaded model; next Send reloads.
- Active stream/window-close protection and no lease underflow. No destructive
  swap-pressure stress or unrelated model/cache changes for this checkpoint.
- Critical swap emulation with an actual sampled-state log receipt and inspected
  screenshots while loading, generating, delegating, and continuing the chat.
- Same-model spawning and different-model delegation: actual child results,
  parent resumption, final Stop/input state, per-generation rates, and residency
  ownership through completion and cancellation.

## Validation progress

- Initial source `e3d1dbf06b0431d5d17add2d149b6f4bf9a965ae`: the local
  whole-module test build was interrupted at 17:32 PDT after app-core compilation
  while the test target was still compiling. No tests executed; this is not a
  passing test result. Supervisor cleanup recorded zero remaining owned processes.
  Log: `SWIFTTEST_ModelIdleResidencyTests0914__171034.log` under the retained
  `mtp-swift-2026-09-04/logs` evidence directory.
- Cross-reference review found two obsolete warning-UI tests and one
  whitespace-sensitive event-name assertion. Update those contracts and use the
  repository's incremental CI test lane before promotion.
- Local live profile: `post-1653-qwen38-audit/mtp-default-off-live.VJzhhW/mlx0322/model-idle-residency-0914.Rf3bEw`.
  Only symlinks to existing LFM2.5-2.6B-JANG_6M and SmolLM2-135M-Instruct-8bit
  bundles; no weight or generation-config edits. Live proof is still pending.
- Draft PR: https://github.com/osaurus-ai/osaurus/pull/2771 . Runtime/UI source
  at `f3e89c8766503aaf33089fbebc3f0b2ceaab2e18`; six engine pins unchanged at
  `5b0c8e6b8b29a7ead21fe785688bc0621580cc62`.
- CI run `34914207229` on that head: CLI 32/32, SwiftLint, shellcheck and small
  package jobs completed successfully. Core tests did not execute: Swift Testing
  macro expansion rejected the new limiter's mutating calls inside `#expect`
  (`cannot use mutating member on immutable value: '$0' is immutable`).
  Materialize each observation before asserting it; rerun CI on the correction.
- Both local dev builds were resource-aborted, not compiler failures. First
  `SWIFTTEST_ModelIdleDevApp0914__174012.log`: available memory 29.4 GiB crossed
  a 32 GiB reserve, tracked peak 15.84 GiB. Retry
  `SWIFTTEST_ModelIdleDevAppRetry0914__175138.log`: available memory 22.2 GiB
  crossed a 24 GiB reserve. Host pressure remained normal and swap stayed
  0.49 GiB. Other local work was active; do not terminate its processes. Logs
  and `.mem`/`.procs` receipts are under `mtp-swift-2026-09-04/logs`.
- No source-bound new app was launched, and no critical-swap UI/model/delegation
  row has run. Do not reuse the old dev binary as proof. Resume with a clear
  local build window, then follow every required live row above. No release.

## Current CI and build receipts

- App implementation/test head: `51aceb98a760f3edb1a9d5137b03aa7f7c4b82b0`.
  CI [run 34915676900, attempt 2](https://github.com/osaurus-ai/osaurus/actions/runs/34915676900/attempts/2)
  completed successfully. CI actually checked out merge commit
  `b5c96ea4c39c5c3d022c23829c344a3ce1639001`, combining that head with
  base `7666cc6ba0cf8c1b24b93c220b8c0331c392cab5`; do not conflate the run's
  reported head with its checkout. The local build remains branch-head-bound.
- Attempt 1 failed `LocalModelDetectionTests.swift:146`,
  `isStreamingLocalModel_composesStreamingStateWithLocality`, expecting true
  but observing false. No assertion, fixture, source or timeout changed before
  rerunning failed jobs. Attempt 2 observed the same test completing in 0.054 s.
  Its precise failure mechanism is not established by this repeat.
- Retained core log `model-idle-ci-core-51aceb9-attempt2.log` under
  `post-1653-qwen38-audit`: checkout lines 101-114; XCTest reports 399 tests,
  eight skipped, zero failures at 16362/16364; locality test 21510; telemetry
  tests 22461-22465; residency manager 22576-22595; configuration tests
  25739-25756; `Test Succeeded` at 28048. Attempt 1's raw assertion is retained
  in `model-idle-core-raw-51aceb9.zip`, member `test-core.log`, line 21021.
- Evals are scripted-only: 133 cases, 118 successful and 15 skipped
  model-driven cases. Unscored judge rubrics and skipped real-model cases are
  not app/delegation evidence. Log: `model-idle-ci-evals-51aceb9-attempt2.log`.
- Local build receipt `SWIFTTEST_ModelIdleDevSingleResume0914__191246`
  reached its 1800-second deadline. Subsequent same-source one-file builds
  retained object outputs, but progress entries alone do not prove actual
  recompilation or completion. A later one-file attempt was deliberately
  stopped through its owned supervisor after its rate was too slow for the
  bounded build window; cleanup confirmed zero owned processes.
- `smallbatch` is now available in the retained build helper: one Xcode task,
  at most eight primary files per frontend, `-O`, runtime assertions and
  testability unchanged. Live samples observed two and five primary files.
  This is a local dev-UI qualification strategy, not interchangeable WMO
  performance proof. No tracked runtime/build-project setting was changed.
- `SWIFTTEST_ModelIdleDevSmallBatch0914__201740` stopped at 20:24:28 PDT
  when kernel-free memory crossed the unchanged 24 GiB floor. Owned footprint
  peaked at 1.08 GiB; cleanup confirmed zero owned processes at 20:24:33.
  Read-only inventory then identified another task's GLM vision evaluation;
  host swap subsequently exceeded this task's 2 GiB admission limit. No
  unrelated process was signaled, and no resource gate was bypassed.
- Full source/command/resource history is in
  `post-1653-qwen38-audit/model-idle-core-ci-investigation-0914.md`.
  `model-idle-runtime-receipts-0914.md` tracks the still-unrun acceptance rows.
  All live app rows remain pending; do not mark this PR ready or merge it yet.

## Resume handles

- App worktree: `/Users/eric/osaurus-mtp-calibration-app`, branch
  `fix/model-idle-unload-no-swap-warning`. Preserve untracked
  `build-mtp-calibration/`; no changes to `/Users/eric/vmlx-swift` are in scope.
- Evidence root: `/Users/eric/vmlx-private-evidence/post-1653-qwen38-audit`.
  `build-mlx0322-development-app-0914.sh` requires the retained bounded
  supervisor and exact app/engine/core/C ABI commits. Core is
  `c0a51a085b9252dc6469afe1aed772b1f538c9b0`; C ABI is
  `2d783ac38713458eae2067ffff9ef8ebbff2ec70`. Only local development build;
  no archive/export/install/release. Confirm no competing heavy process first.
  Include `osaurus-evals` model jobs in that read-only preflight, not only
  xcodebuild, swift-frontend and GUI model processes. Preserve the existing
  memory, swap, pressure, time and ownership guards.
- `launch-model-idle-app-0914.py`: supervisor-owned launch on port 1338,
  isolated profile above, exact new binary/metallib hashes and `--emulate-swap`.
  Actual proof requires the runtime log
  `swap-pressure emulation sampled severity=critical`, not merely the flag.
- `capture-model-idle-turn-0914.py`: PID-bound AX submission, complete parent
  history, screenshots, cache snapshots, exact iterator timings and observed
  UI-rate labels. Pass the actual selected model button label, profile root,
  and new binary SHA. Fast answers may finish between polls; the artifact
  explicitly records whether Stop was observed.
- `observe-model-residency-0914.py`: bounded `/health` lease/deadline/load
  transitions plus physical-footprint samples. Compare the unload timestamp
  with the actual final-lease deadline, not with observer start time.
- All three Python proof helpers passed syntax compilation only. No model,
  UI, delegation, telemetry-delivery, or performance result is implied.
- `snapshot-model-idle-ui-0914.py` captures the actual AX tree, screenshot,
  saved server policy, health/cache snapshots and footprint after UI actions.
  It is identity-bound and returns no pass verdict; syntax compilation only
  until the new app can be launched.
