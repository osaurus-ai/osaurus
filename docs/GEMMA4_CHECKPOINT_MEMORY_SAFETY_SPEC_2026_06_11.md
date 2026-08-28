# Gemma 4 Checkpoint And Memory Safety Spec - 2026-06-11

This document is the tracked team-facing checkpoint for the Gemma 4 QAT
MXFP4/JANG_4M release lane and the memory-safety settings contract. Private
raw artifacts and wider family notes remain under `.agents/`; this file records
what can be shared in the repo without pretending unproven rows are complete.

## Current Release Boundary

Status: `PARTIAL RELEASE CHECKPOINT`.

Gemma 4 text/chat/tool/cache behavior is usable on the current PR #1465 app
build for a checkpoint. Gemma4 audio generation remains a real runtime gap:
the bundles advertise `audio_config`/audio modality metadata, but the pinned
vMLX Gemma4 runtime drops `audio_tower.*` / `embed_audio.*` weights and has no
audio module wired. Video generation and full all-family Sentry closure are not
complete. Memory-safety controls have API/admin proof on PR #1465 and prior
manual UI save proof on PR #1462.

Current PR #1465 proof baseline:

- Osaurus PR: `#1465`
- Osaurus proof/code branch: `codex/request-cancel-model-admission` (PR head is authoritative)
- vMLX Swift pin: `76047f3b4492d4fae316267a30fba55163b1c5cd`
- GitHub checks: `test-core`, `test-cli`, `swiftlint`, `shellcheck`, and
  `update_release_draft` were green on the previous pushed PR head; recheck after each new push.
- External-root proof after macOS disk access approval:
  `.agents/gemma-final/artifacts/pr1465-external-root-post-disk-approval-vmlx_76047f3-20260611-071401/SUMMARY.json`
- Post-notification-approval tool/cache proof after macOS disk approval:
  `.agents/gemma-final/artifacts/pr1465-post-notification-approval-e2b-tool-cache-vmlx_76047f3-20260611-083237/POST_APPROVAL_SUMMARY.json`
- External-root all-ten proof after macOS disk access approval:
  `.agents/gemma-final/artifacts/pr1465-external-root-all10-direct-parent-vmlx_76047f3-20260611-105825/tool-cache-all10/SUMMARY.json`

## Gemma 4 Live Proof

Current PR #1465 live Osaurus API proof passed for all ten local Gemma 4 text
rows:

- `gemma-4-e2b-it-qat-mxfp4`
- `gemma-4-e2b-it-qat-jang_4m`
- `gemma-4-e4b-it-qat-mxfp4`
- `gemma-4-e4b-it-qat-jang_4m`
- `gemma-4-12b-it-qat-mxfp4`
- `gemma-4-12b-it-qat-jang_4m`
- `gemma-4-26b-a4b-it-qat-mxfp4`
- `gemma-4-26b-a4b-it-qat-jang_4m`
- `gemma-4-31b-it-qat-mxfp4`
- `gemma-4-31b-it-qat-jang_4m`

Each row passed the live multi-turn required-tool harness:

- First required `line_count` tool call used exact multiline argument
  `red\ngreen\nblue`.
- The visible follow-up acknowledged the tool result.
- A later required `line_count` call after conversation history used exact
  argument `one\ntwo`.
- No tool protocol, reasoning protocol, replacement-character, or C0/C1 control
  leakage was observed.
- Cache topology matched Gemma rotating/full KV with disk-backed restore.

Current PR #1465 weird-character replay also passed for each row with default
settings and with thinking disabled.

Representative release-speed proof from API-reported token/s:

| Row | Default | Thinking Disabled |
| --- | ---: | ---: |
| E2B MXFP4 | 110.53 | 109.96 |
| E2B JANG_4M | 101.52 | 103.53 |
| E4B MXFP4 | 71.53 | 71.96 |
| E4B JANG_4M | 64.97 | 64.29 |
| 12B MXFP4 | 45.97 | 45.85 |
| 12B JANG_4M | 38.86 | 38.34 |
| 26B MXFP4 | 87.66 | 86.03 |
| 26B JANG_4M | 74.22 | 75.38 |
| 31B MXFP4 | 21.73 | 21.62 |
| 31B JANG_4M | 16.98 | 16.83 |

Current PR #1465 all-ten text/tool/cache artifact:
`.agents/gemma-final/artifacts/pr1465-gemma-42fd-debug-all10-live-20260611-051547/tool-cache-all10/SUMMARY.json`.

Current PR #1465 external-root all-ten text/tool/cache artifact after macOS
disk access approval:
`.agents/gemma-final/artifacts/pr1465-external-root-all10-direct-parent-vmlx_76047f3-20260611-105825/tool-cache-all10/SUMMARY.json`.

The external-root run launched the PR-built Debug app directly with
`OSU_MODELS_DIR=/Volumes/EricsLLMDrive/jangq-ai`, confirmed all ten Gemma rows
were listed by `/v1/models`, then reran the same multi-turn required-tool/cache
harness. All ten rows passed exact tool arguments, tool-result grounding,
second required tool call after history, no protocol leakage, healthy server
state, Safe Auto memory-safety telemetry, bundle defaults
`temperature=1`, `top_k=64`, `top_p=0.95`, and Gemma rotating/full KV with
disk-backed restore. Every row still reported `turbo_quant_kv_layer_count=0`.

Current PR #1465 no-weird-character/tool-leak artifact:
`.agents/gemma-final/artifacts/pr1465-gemma-42fd-debug-all10-live-20260611-051547/no-weird-chars-tool-leak-all10.json`.

Current PR #1465 issue #1432 replay artifact:
`.agents/gemma-final/artifacts/pr1465-gemma-42fd-debug-all10-live-20260611-051547/issue1432-ai-short-paragraph-all10-corrected-eval.json`.

Representative repeat-cache proof passed for E2B MXFP4 and JANG_4M: repeated
identical prompts kept a stable prefix hash and produced a repeat disk L2 hit.

## Gemma Media And Reasoning Boundary

All-ten Gemma image/VL routing proof passed on current PR #1465:

- Artifact:
  `.agents/gemma-final/artifacts/pr1465-gemma-all-media-vl-audio-video-vmlx_76047f3-20260611-065406/SUMMARY.json`

Earlier representative image proof also passed for:

- `gemma-4-12b-it-qat-mxfp4`
- `gemma-4-12b-it-qat-jang_4m`

Both answered a red PNG as `Red`, repeated the answer consistently, kept stable
prefix/cache behavior, and kept the server healthy.

Audio/video are not claimed as generation features. Current live behavior is a
typed refusal boundary:

- Audio returns HTTP 400: `Gemma4 audio input is not enabled because the pinned vMLX Gemma4 runtime does not wire audio_tower/embed_audio yet.`
- Video returns HTTP 400 when the bundle does not advertise video.
- Current root-cause refusal proof artifact:
  `.agents/gemma-final/artifacts/pr1465-gemma-audio-rootcause-refusal-vmlx_76047f3-20260611-093714/SUMMARY.json`

Reasoning behavior is bundle/API driven:

- Default and explicit disabled reasoning rows produced visible answers without
  protocol leakage.
- High reasoning passed with sufficient output budget (`max_tokens=256`) and
  kept reasoning in `reasoning_content`.
- High reasoning with too-small output budgets can length-stop with
  reasoning-only output and must not be promoted as a clean UX row.

## Memory Safety Settings Contract

The runtime contract exists, is visible, and has PR #1465 API/admin proof plus
PR #1462 manual UI save proof.

Current default resolved plan visible in `/admin/cache-stats.memory_safety`:

- `mode=safe_auto`
- `slider=2`
- `load_configuration.memory_limit = fraction 0.7`
- `load_configuration.max_resident_bytes = absolute 134217728`
- `load_configuration.use_mmap_safetensors = true`
- `load_configuration.jang_press_policy.kind = disabled`
- `cache.prefix_enabled = true`
- `cache.block_disk_enabled = true`
- `cache.paged_kv_enabled = true`
- `cache.live_kv_codec = engine_selected`
- `cache.default_max_kv_size = 65536`
- `cache.enable_ssm_rederive = true`
- `concurrency.max_concurrent_sequences = 1`

The model load path consumes the resolved plan:

- `ModelRuntime.resolveMemorySafetyLoadPlan(...)` resolves the plan.
- `memorySafetyPlan.loadConfiguration` is passed to `loadModelContainer(...)`.
- `/admin/cache-stats.memory_safety.memory_status` exposes the live runtime
  `MemoryStatus`, including actual `memory_limit`, `cache_limit`,
  `physical_memory`, and `current_rss`.

Important display rule:

- Show both the resolved plan and the observed runtime memory status.
- If they differ, treat the observed runtime status as the current applied MLX
  state and the resolved plan as the requested policy.

## Settings Control Surface

Changed-setting proof is currently `FIXED for PR #1465 API/admin application`
and `FIXED for PR #1462 manual UI application`.

The app exposes memory-safety status through `/admin/cache-stats.memory_safety`
and now exposes a Server Settings section that edits
`VMLXServerRuntimeSettings.memorySafety`. The section persists through the
existing Server Settings save path, which calls `ServerController.saveRuntimeSettings(_:)`
and updates `ServerRuntimeSettingsStore.snapshot()`.

`/admin/cache-stats` remains read-only; it is the status surface, not the
mutation surface.

The Server Settings section persists:

- `memorySafety.mode`
- `memorySafety.slider`
- `memorySafety.allowExperimentalMLXPress`
- `memorySafety.failClosedWhenEstimateUnknown`
- `memorySafety.customPhysicalMemoryFraction`
- `memorySafety.customAllocatorCacheBytes`
- `memorySafety.customDefaultMaxKVSize`
- `memorySafety.customMaxConcurrentSequences`

Current PR #1465 API/admin live proof shows:

1. `GET /admin/runtime-settings` returns the persisted vMLX runtime settings.
2. `PUT /admin/runtime-settings` persists valid generation, cache,
   memory-safety, media, MTP, and concurrency settings.
3. Network mutations are rejected from this endpoint because they can restart or
   rebind the HTTP server.
4. Cache/media/MTP changes clear loaded models when needed, and
   generation/concurrency changes invalidate runtime config.
5. Generation/concurrency, prefix cache, dependent paged KV/block disk, and
   Strict memory safety were toggled through the API/admin surface.
6. Each changed state was followed by live Gemma chat, health, cache/status
   telemetry, and restore-original confirmation.

Artifact:
`.agents/gemma-final/artifacts/pr1465-gemma-runtime-settings-endpoint-live-vmlx_76047f3-20260611-060337/SUMMARY.json`.

Prior PR #1462 UI proof shows:

1. The user changes and saves the setting through the Server Settings UI.
2. `/admin/cache-stats.memory_safety` shows the changed mode/slider.
3. The next model load uses the changed `load_configuration`.
4. If a reload is required, the UI says the setting takes effect on next load.
5. Gemma chat/tool/cache/weird-character proof still passes after the change.

Current PR #1462 app/API proof:

- Artifact root: `.agents/gemma-final/artifacts/memory-safety-apply-pr1462-20260610-220637`
- Built app: `/Users/eric/Library/Developer/Xcode/DerivedData/osaurus-fknwhdrdztffeoffkagufseezytr/Build/Products/Debug/osaurus.app`
- Default isolated launch reported Safe Auto through `/admin/cache-stats.memory_safety`:
  `mode=safe_auto slider=2 load_cap=0.7 allocator_cap=absolute(134217728) max_concurrent=1 kv_cap=65536`.
- Changed isolated launch reported Strict through `/admin/cache-stats.memory_safety`:
  `mode=strict slider=3 load_cap=0.6 allocator_cap=absolute(67108864) max_concurrent=1 kv_cap=4096`.
- Live `gemma-4-e2b-it-qat-mxfp4` chat under the changed Strict plan answered
  exactly `memory safety applied`, stopped normally, and reported
  `29.1005` completion token/s for the three-token response.
- The loaded E2B cache row kept Gemma's expected topology: 15 layers, 3 KV
  layers, 12 rotating KV layers, disk-backed restore required, block disk
  enabled, MLXPress disabled, and TurboQuant KV layer count 0.

Current PR #1462 manual UI proof:

- Artifact root: `.agents/gemma-final/artifacts/memory-safety-ui-proof-pr1462-20260610-221751`
- The PR-built Debug app exposed Server Settings -> Memory Safety.
- The UI was changed to `mode=strict`, `slider=3`, then saved and reported
  `Settings saved successfully` / `All changes saved`.
- `/admin/cache-stats.memory_safety` after the UI save reported
  `mode=strict slider=3 load_cap=0.6 allocator_cap=absolute(134217728) max_concurrent=1 kv_cap=65536`.
- A live `gemma-4-e2b-it-qat-mxfp4` chat after the UI save answered exactly
  `ui memory safety applied`, stopped normally, and reported `28.8658`
  completion token/s in `usage.tokens_per_second`.
- The status endpoint after that generation still reported the same Strict
  plan, `use_mmap_safetensors=true`, `jang_press_policy.kind=disabled`,
  `paged_kv_enabled=true`, `block_disk_enabled=true`, and
  `max_concurrent_sequences=1`.
- Nuance: this UI proof preserved the existing Cache page per-session window
  override, so Strict reported `kv_cap=65536`. The earlier isolated app/API
  proof without that override reported `kv_cap=4096`. This is intentional
  user-setting precedence, not a hidden hardcoded RAM rule.

Do not substitute cache toggles for the memory-safety slider. Cache controls are
real settings, but they do not prove the memory-safety contract is user
controllable.

## RAM Policy

Do not add hardcoded RAM rejection rules to make a release look safe. Memory
policy must be a user-visible setting with typed warnings or graceful refusal
before unsafe load paths.

Allowed behavior:

- Advisory feasibility status.
- Graceful typed refusal when a strict user-selected policy cannot be satisfied.
- Graceful typed refusal for Gemma4 audio until the vMLX Gemma4 runtime wires
  the real audio tower/embed path; do not infer audio support from bundle
  metadata alone.
- Clear UI/status warnings when estimates are unknown or over budget.
- Conservative defaults that preserve model behavior.

Forbidden behavior:

- Silent sampler changes.
- Forced thinking or parser stripping to hide output bugs.
- Arbitrary hardcoded physical-memory percentages that block otherwise valid
  user choices.
- Catch-after-crash wrappers for process-fatal MLX/Metal failures.

## Adjacent Rows

Qwen MTP MXFP4 27B and 35B have current-main live chat/tool/cache proof with
hybrid SSM companion plus disk L2 hits. PR #1465 replay artifact:
`.agents/gemma-final/artifacts/pr1465-qwen-mtp-tool-cache-20260611-002516`.
Native MTP acceleration remains partial because the local bundles report
preserved MTP weights but no production `vmlx_mtp_tuning.json`; do not force
greedy sampling or fake native MTP activation.

MiMo V2.5 JANGTQ_2 is fixed for the shared text/tool-result regression on PR
#1465: first required tool call preserved exact args, the ordinary tool-result
follow-up answered `3 lines were counted.`, a second required tool call after
history preserved exact args, no parser/protocol markers leaked, and cache
telemetry showed 9 KV plus 39 rotating layers with disk L2. Artifact:
`.agents/gemma-final/artifacts/pr1465-mimo-tool-history-fix-live-vmlx_76047f3-20260611-073345/SUMMARY.json`.
MiMo image/audio/video requests are also live-proven as typed HTTP 400 refusal
boundaries that preserve server health and do not load the 79G bundle. Artifact:
`.agents/gemma-final/artifacts/pr1465-mimo-media-refusal-vmlx_76047f3-20260611-091152/SUMMARY.json`.
This does not claim MiMo VL/audio/video generation.

Nex N2 remains a follow-up lane. Existing evidence shows useful topology proof
but slow or blocked rows; do not block the Gemma checkpoint on N2 unless a
shared runtime change regresses Gemma.

After macOS disk notification approval, the currently available roots still do
not expose a launchable `nex-n2-pro-jangtq2` runtime bundle. Current inventory:

- `/Users/eric/.mlxstudio/models` does not list `nex-n2-pro-jangtq2`.
- `/Volumes/EricsLLMDrive/jangq-ai/sources/Nex-N2-Pro` is the source bundle,
  not the JANGTQ runtime id.
- `/Users/eric/jang/build/n2-jangtq2-vmlx-control-20260610` contains only cache
  DB files and `server.log`, with no config/tokenizer/safetensors runtime
  bundle files.
- Other `/Users/eric/jang/build/n2-*` directories are analysis/proof/smoke
  outputs, not launchable Osaurus model bundles.

Current N2 JANGTQ status is `BLOCKED` on bundle availability/discovery. The next
gate is to place or build a real launchable runtime bundle, then run the same
Osaurus live `/v1/models`, load, multi-turn tool, no-leak, token/s, topology
cache, and health proof used for Gemma.

## Required Release Checkers

Before final checkpoint release, run:

```sh
scripts/live-proof/assert-osaurus-pr-hygiene.sh
scripts/live-proof/assert-osaurus-vmlx-pr-readiness.sh
scripts/live-proof/assert-no-hidden-local-sampler-defaults.sh
scripts/live-proof/assert-osaurus-no-forced-behavior-pr.sh
scripts/live-proof/assert-openresponses-cache-proof-wiring.sh
scripts/live-proof/assert-server-settings-runtime-wiring.sh
scripts/live-proof/assert-tool-choice-required-routing.sh
scripts/live-proof/assert-model-tool-capability-surfaces.sh
```

Then run live Osaurus app/API proof, not only source tests, for any model row
claimed fixed.
