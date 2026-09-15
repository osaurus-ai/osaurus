# Model idle residency and swap-warning removal

Status: implementation in progress; live proof pending.

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
