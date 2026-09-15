# Model idle residency and swap-warning removal

Status: PARTIAL. Implementation and proof harness prepared; current CI and all
source-bound live UI rows remain required. PR stays draft and unmerged.

NOW: Remove the swap/predicted-RAM confirmation UI and make idle residency bounded.
DO NOT: Tune macOS swap, change runtime admission/samplers, release active leases,
or publish a release. Engine pin remains unchanged.
BATCH OWNER: App-only lifecycle checkpoint.
NEXT: Focused tests, isolated local development build, actual settings/chat proof,
diff review and PR.

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
