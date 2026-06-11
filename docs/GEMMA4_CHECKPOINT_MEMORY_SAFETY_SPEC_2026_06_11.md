# Gemma 4 Checkpoint And Memory Safety Spec - 2026-06-11

This document is the tracked team-facing checkpoint for the Gemma 4 QAT
MXFP4/JANG_4M release lane and the memory-safety settings contract. Private
raw artifacts and wider family notes remain under `.agents/`; this file records
what can be shared in the repo without pretending unproven rows are complete.

## Current Release Boundary

Status: `PARTIAL RELEASE CHECKPOINT`.

Gemma 4 text/chat/tool/cache behavior is usable on the current main app build
for a checkpoint. Audio/video generation and full all-family Sentry closure are
not complete. Memory-safety controls now have manual UI save proof on PR #1462.

Current app proof baseline:

- Osaurus commit: `0f5f060ca7e0660cea0a5d095012e1d60ebc58c8`
- vMLX Swift pin: `ef025f2556978d033131f745c00dd8128c8d5151`
- Built app: `build/DerivedData-gemma-current-main-0f5f060-20260610-210706/Build/Products/Release/osaurus.app`
- Build log: `.agents/gemma-final/artifacts/osaurus-main-0f5f060-live-e2e-build-20260610-210706.log`

## Gemma 4 Live Proof

Current-main live Osaurus API proof passed for all ten local Gemma 4 text rows:

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

Current-main weird-character replay also passed for each row with default
settings and with `thinking: disabled`.

Representative current-main speed from API-reported token/s:

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

Representative current-main repeat-cache proof passed for E2B MXFP4 and
JANG_4M: repeated identical prompts kept a stable prefix hash and produced a
repeat disk L2 hit.

## Gemma Media And Reasoning Boundary

Representative image proof passed on current main for:

- `gemma-4-12b-it-qat-mxfp4`
- `gemma-4-12b-it-qat-jang_4m`

Both answered a red PNG as `Red`, repeated the answer consistently, kept stable
prefix/cache behavior, and kept the server healthy.

Audio/video are not claimed as generation features. Current live behavior is a
typed refusal boundary:

- Audio returns HTTP 400: `Gemma4 audio input is not enabled because native audio routing still needs live model proof.`
- Video returns HTTP 400 when the bundle does not advertise video.

Reasoning behavior is bundle/API driven:

- Default and explicit disabled reasoning rows produced visible answers without
  protocol leakage.
- High reasoning passed with sufficient output budget (`max_tokens=256`) and
  kept reasoning in `reasoning_content`.
- High reasoning with too-small output budgets can length-stop with
  reasoning-only output and must not be promoted as a clean UX row.

## Memory Safety Settings Contract

The runtime contract exists, is visible, and has PR #1462 manual UI save proof.

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

Changed-setting proof is currently `FIXED for PR #1462 UI/app/API application`.

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

Live proof now shows:

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
hybrid SSM companion plus disk L2 hits. Native MTP acceleration remains partial
because the local bundles report preserved MTP weights but no production
`vmlx_mtp_tuning.json`.

MiMo V2.5 JANGTQ_2 remains partial: required tool-call arguments passed and
cache topology matched the bundle, but the visible tool-result follow-up
answered the line count incorrectly. Do not mark MiMo release-green until
tool-result grounding is fixed and live proof passes.

Nex N2 remains a follow-up lane. Existing evidence shows useful topology proof
but slow or blocked rows; do not block the Gemma checkpoint on N2 unless a
shared runtime change regresses Gemma.

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
