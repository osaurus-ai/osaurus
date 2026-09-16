# Model idle residency and swap-warning removal

## Current isolated integration — September 15

Status: PARTIAL pending matched handoff/failure attribution and final-head CI.
The current production source is `3f2294c96abaf0320d9f934e327e4f6d4e51716b`;
ancestry-only `60fd8c769578b5e8e767d5170a066221e77fba89` has the identical tracked
tree. The SSD notice is already merged as #2783. This PR changes idle ownership,
warning UI and explicit Core Model fallback persistence; it does not change RAM
reserve arithmetic, model generation defaults, parser behavior or vision support.
The vMLX pin remains `5b0c8e6b8b29a7ead21fe785688bc0621580cc62`.

SOURCE EVIDENCE: `CoreModelService.swift:204` borrows the existing residency
owner for utility requests; `ModelRuntime.swift:1273` protects API ownership and
active leases at chat close, `:2448` refreshes saved policies, and `:2463` arms
idle release after leases drain. `AppConfiguration.swift:77` encodes explicit
Core Model null so legacy migration cannot overwrite Use chat model.

LIVE EVIDENCE: fresh Release binary SHA256
`fb9c7d4828fea3845633385902a28e98940e4b7dca0d7723bf3b19f518c1a06c`;
[native proof and limitations](https://github.com/osaurus-ai/osaurus/pull/2771#issuecomment-5691166970).
CI35045206418: seven CI jobs passed plus the separate release-draft check;
Core XCTest400 total/8 skipped/0 failures, Swift Testing passed, Evals harness350/350.

- Native Settings: default30-second idle unloaded while focused; next request
  reloaded. Keep Loaded ON saved, survived relaunch and remained resident46.9s
  after close. Saving OFF rearmed an already-resident model without generation.
  Core Use chat model and titles/suggestions ON persisted through relaunch.
- Actual Coordinator, RAM Safety ON/Handoff ON/coexistence OFF, local batch1 and
  same-model ceiling1: three fresh SysAdmin chats followed by a fresh sequential
  SysAdmin/Writer chat, without restart, with utilities OFF and again ON. All10
  minimal child envelopes returned exactly the requested codes,16.4–34.9tok/s;
  parent follow-ups completed. This is not proof on physical16GiB hardware.
- Utility-on close released residency at the next0.219s sample, before its
  original deadline. A real API request96.849tok/s retained its API deadline
  after chat close. An active Writer story stayed leased until completion,
 88.8tok/s; reopened contextual follow-up83.4tok/s. Native Stop unlocked input
  and a new request completed80.8tok/s. Cancellation's partial child still
  incorrectly returned ok=true with missing usage: separate #2752 remains needed.
- Two Qwen3-0.6B handoffs performed unload/load/run/unload/restore, but task
  fidelity failed: bare-code child inputs produced unrelated answers7.5/5.7tok/s
  and the parent fabricated HANDOFF-OK. Three cache-control prompts in the same
  history also unnecessarily delegated bare codes. None counts as child fidelity
  proof. Matched pre-change native attribution is pending.
- SSD integration: saved .005% (191MB), real quota popup, one-click clear of
 165,982,920 indexed bytes while preserving an unindexed sentinel, then a cold
  response80.1tok/s. Cache OFF was reflected in active runtime telemetry;
  cache restored afterward. Visuals remain private, not in the repository.
- Full current AgentLoop36/7/4 (pass/fail/skip), Frontier20/19/0; total56/26/4.
  Pre-idle baseline a6ad602 AgentLoop33/10/4, Frontier23/16/0; also56/26/4.
  Five cases failed only in each build. Equal totals do not establish no
  regression; targeted matched repeats are running with original assertions.
  The same Gemma judges prose; file/tool assertions are retained, not replaced
  with judge opinions. Missing throughput in tool-only steps remains unqualified.
- Current CacheProof14/14 scored cases. Seven length-stopped turns and six
  non-hybrid conditional assertions skipped: not complete answer-coherency or
  hybrid-companion proof. Effective Gemma topology3 KV+12 rotating layers,
  disk-backed restore, TurboQuant layer count0, paged RAM OFF.

Models: OsaurusAI/gemma-4-E2B-it-8bit revision
`433003a1e3fbfd10819ad15179d5e3c4d02d7ea7`, T1/top-p.95/top-k64/min-p0,
parent16384/child2048 tokens; main adapter enable_thinking=false, not native
reasoning proof. Qwen3-0.6B-8bit revision
`11de96878523501bcaa86104e3c186de07ff9068`, unchanged bundle/settings.

Private artifacts under `/Users/eric/vmlx-private-evidence/ornith-vision-2026-09-14`:
`idle-utility-run2-receipt.json`, `idle-utility-run3-receipt.json`,
`idle-utility-run3-final-history.json`, native `idle-utility-run3-*.png/.ax.txt`,
`idle-utility-full-baseline-comparison.json`,
`evals-idle-utility-3f2294c96-agent-full`, `evals-idle-baseline-a6ad-agent-full`,
`evals-idle-utility-3f2294c96-cache`. Full run logs:
`SWIFTTEST_IdleUtilityAgent0915__194536.log`,
`SWIFTTEST_IdleBaselineAgent0915__195755.log`,
`SWIFTTEST_IdleUtilityCache0915__201408.log`.

Private guards: user-approved24GiB reclaimable-RAM floor, normal pressure,
1GiB swap-growth limit,28GiB owned physical-footprint cap,1800-second timeout
and process-identity cleanup. Existing swap is observational. Native peak3.18GiB,
current full eval2.68GiB, baseline2.30GiB, cache1.76GiB; no resource aborts and
zero owned processes at cleanup. Critical swap emulation was sampled631times
and excluded from telemetry. This is an M5 Max128GiB host, not M4/16GiB proof.
No macOS swap or app admission policy is changed by these test guards.

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
