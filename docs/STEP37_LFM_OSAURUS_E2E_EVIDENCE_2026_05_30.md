# Step 3.7 / LFM Osaurus E2E Evidence - 2026-05-30

This document records the current no-sign Osaurus app proof for the Step/LFM
vMLX pin. It deliberately separates proven rows from partial rows.

## Code State

- vMLX pin: `60b888659e1196995fa57f7af91d982e5948a680`.
- vMLX fixes:
  - Current pin `60b888659e1196995fa57f7af91d982e5948a680` includes the
    prior Step runtime/cache work plus the LFM required-tool thinking-tail fix.
  - LFM required-tool fallback closes the native thinking rail only when
    `tool_choice` is explicit required/named, so required tool turns do not
    spend the output budget in hidden reasoning before emitting a call. Optional
    tools remain optional.
  - Step tool-call parser support for Step XML and narrow schema-gated bare
    `name({"arg": ...})` calls on reasoning/content rails.
  - Step required-tool fallback closes the native thinking rail before the
    explicit function-call contract so `tool_choice: required` does not remain
    trapped in hidden reasoning.
- Osaurus fix: local JANGTQ sidecar preflight accepts bundles that declare
  `format: "jangtq"` with `jangtq_runtime.safetensors` even when
  `weight_format` is absent.
- Osaurus fix: Step JANGTQ_K sidecar preflight uses the sidecar sentinel
  directly instead of blocking request load on external-bundle `jang_config.json`
  reads. This preserves the sidecar requirement and lets pinned vMLX own Step
  parser/template semantics.
- Osaurus fix: SwiftTransformers local-tokenizer loading routes Step sentinel
  templates through the Step fallback, disables Step thinking only for explicit
  required tool choice, and preserves normal optional-tool behavior otherwise.
- Osaurus cache policy: engine-selected TurboQuant KV remains topology-gated.
  Full simple-KV models can use TurboQuant KV. Step 3.7 is the explicit mixed
  full-attention + SWA exception: vMLX converts only `KVCacheSimple`
  full-attention layers to TurboQuant KV and preserves `RotatingKVCache`
  sliding layers for disk-backed restore. LFM SSM/Mamba hybrid cache still uses
  native KV plus disk-backed restore and SSM companion state.

## No-Sign / No-Keychain Boundary

- App build:
  `/tmp/osaurus-1310-60b888-nosign-dd/Build/Products/Release/osaurus.app`.
- Build path used `scripts/live-proof/build-keychain-free-osaurus.sh`.
- Xcode build settings included `CODE_SIGNING_ALLOWED=NO`,
  `CODE_SIGNING_REQUIRED=NO`, empty `CODE_SIGN_IDENTITY`, and
  `AD_HOC_CODE_SIGNING_ALLOWED=NO`.
- The only seal was the script's local ad-hoc seal with no signing identity,
  no notary, no `security` command, and no password/keychain prompt.
- Live app launches used `OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1`, isolated
  `OSAURUS_TEST_ROOT`, and explicit `OSU_MODELS_DIR`.

## 2026-05-31 Current-Head Proof: LFM2.5 JANG_2L

- Osaurus worktree head at proof time:
  `ff7b5ff9b70cb8ff23fe9b4c0a63c9f4071b0489` plus local repin/docs to vMLX
  `60b888659e1196995fa57f7af91d982e5948a680`.
- Built app:
  `/tmp/osaurus-1310-60b888-nosign-dd/Build/Products/Release/osaurus.app`.
- Launch root:
  `/tmp/osaurus-1310-60b888-live-root-20260531-031451`.
- Model root: `/tmp/osaurus-step37-localmeta-modelroot`.
- Served model id: `lfm2.5-8b-a1b-jang_2l`.
- Cold strict artifact:
  `/tmp/osaurus-1310-60b888-final-lfm-jang2l-20260531-031510/lfm2.5-8b-a1b-jang_2l_summary.json`.
- Warm strict cache-hit artifact:
  `/tmp/osaurus-1310-60b888-final-lfm-jang2l-warm1024-20260531-031546/lfm2.5-8b-a1b-jang_2l_summary.json`.

Behavior proven on the warm strict cache-hit row:

- Overall verdict: `passed=true`, `failed_checks=[]`.
- Turn 1 required tool call finished as `tool_calls`.
- Turn 1 exact tool args: `{"text":"red\ngreen\nblue"}`.
- Turn 2 produced visible answer: `Three lines were counted.`
- Turn 2 had no tool call, no protocol leak, and no length-stop fake pass.
- Turn 3 required tool call after history finished as `tool_calls`.
- Turn 3 exact tool args: `{"text":"one\ntwo"}`.
- No visible content leaked on tool-call turns.
- App `/health` after the row was healthy with no in-flight request.
- Visible generation throughput was recorded: 351 completion tokens in
  4.090642167 seconds, about 85.81 tok/s.

Cache/topology proven on the warm strict cache-hit row:

- 24 total layers.
- 6 KV layers.
- 18 Mamba/SSM companion layers.
- `companion=ssm`.
- `requires_disk_backed_restore=true`.
- `requires_ssm_companion_state=true`.
- Paged cache incompatible for this hybrid row.
- `turbo_quant_kv_layer_count=0`.
- Warm row delta: `disk_l2_hits +1`, `ssm_companion_hits +1`,
  `companion_hits +1`, and `disk_l2_stores +4`.

Superseded failed warm attempt:

- `/tmp/osaurus-1310-60b888-final-lfm-jang2l-warm-20260531-031528`
  proved the same cache-hit deltas but failed turn 2 at `finish=length` under a
  512-token cap. The 1024-token warm row above supersedes it and is the current
  merge-readiness artifact.

## 2026-05-31 Current-Head Proof: Step 3.7 JANG_2L

- Strict artifact:
  `/tmp/osaurus-1310-60b888-final-step-jang2l-20260531-031601/step-3.7-flash-jang_2l_summary.json`.
- Overall verdict: `passed=true`, `failed_checks=[]`.
- Turn 1 required tool call:
  `line_count`, exact args `text == "red\ngreen\nblue"`, no visible content,
  no protocol leak.
- Turn 2 no-tool answer:
  visible answer `Three lines were counted.`, no tool call, no protocol leak,
  `finish=stop`, token/s recorded.
- Turn 3 required tool call after tool-result history:
  `line_count`, exact args `text == "one\ntwo"`, no visible content,
  no protocol leak.
- Health after row:
  `status=healthy`, no in-flight requests, model resident.
- Cache topology:
  45 layers, 12 KV layers, 33 rotating KV layers,
  `requires_disk_backed_restore=true`, paged-incompatible, and
  `turbo_quant_compressions=2`.
- Visible generation throughput was recorded: 6 completion tokens in
  0.745120167 seconds, about 8.05 tok/s.

## Proven Live Row: LFM2.5 MXFP4

- Model id: `lfm2.5-8b-a1b-mxfp4`.
- Model root: `/tmp/osaurus-e2e-lfm-one`.
- Final warm artifact:
  `/tmp/osaurus-lfm-finalapp-warm-2048-20260530-145426`.
- Harness:
  `scripts/live-proof/run-local-family-multiturn-tool-cache-proof.py`.
- Required evidence: `cache_topology`, `requires_disk_backed_restore`,
  `ssm_companion_cache`, `companion_cache`, and `disk_l2_hits`.
- Result: `passed: true`, `failed_checks: []`.

Behavior proven:

- Turn 1 required tool call finished as `tool_calls`.
- Turn 1 exact tool args: `{"text":"red\ngreen\nblue"}`.
- Turn 2 produced visible answer: `Three lines were counted.`
- Turn 2 had no tool call, no protocol leak, and no length-stop fake pass.
- Turn 3 required tool call after history finished as `tool_calls`.
- Turn 3 exact tool args: `{"text":"one\ntwo"}`.
- No visible content leaked on tool-call turns.
- App `/health` after the row was healthy with no in-flight request.
- Visible generation throughput was recorded: 118 completion tokens in
  1.598719583 seconds, about 73.81 tok/s.

Cache/topology proven:

- 24 total layers.
- 6 KV layers.
- 18 Mamba/SSM companion layers.
- `companion=ssm`.
- `requires_disk_backed_restore=true`.
- `requires_ssm_companion_state=true`.
- Paged cache incompatible for this hybrid row.
- `turbo_quant_kv_layer_count=0`.
- Warm row delta: `disk_l2_hits +1`, `ssm_companion_hits +1`,
  `companion_hits +1`, and `block_disk_stores +4`.

Boundary:

- The same LFM row can fail with too-small explicit max-token caps. A cold
  run using `--max-tokens 256` failed with `finish=length` before a tool call.
  The green row used explicit `--max-tokens 2048`; this is recorded as a
  request budget requirement, not hidden runtime behavior.
- This row proves LFM2.5 MXFP4. It does not prove LFM MXFP8 or LFM JANG_2L.

## Proven Live Row: Step 3.7 JANGTQ_K

- Model id: `step-3.7-flash-jangtq_k`.
- Model root: `/tmp/osaurus-step37-modelroot-jang-and-tqk`.
- Cold artifact:
  `/tmp/osaurus-step37-discoveryfix-430481c-step-jangtqk-tool-20260530-221008`.
- Cold summary:
  `/tmp/osaurus-step37-discoveryfix-430481c-step-jangtqk-tool-20260530-221008/step-3.7-flash-jangtq_k_summary.json`.
- Warm artifact:
  `/tmp/osaurus-step37-discoveryfix-430481c-step-jangtqk-warm-20260530-221128`.
- Warm summary:
  `/tmp/osaurus-step37-discoveryfix-430481c-step-jangtqk-warm-20260530-221128/step-3.7-flash-jangtq_k_summary.json`.
- Harness:
  `scripts/live-proof/run-local-family-multiturn-tool-cache-proof.py`.
- Required evidence: cold row required `cache_topology`,
  `requires_disk_backed_restore`, and `rotating_kv_layer_count`; warm row also
  required `disk_l2_hits`.
- Result: both rows reported `passed: true`, `failed_checks: []`.

Behavior proven:

- Turn 1 required tool call finished as `tool_calls`.
- Turn 1 exact tool args: `{"text":"red\ngreen\nblue"}`.
- Turn 1 had `content=null`, no reasoning leak, and no visible protocol leak.
- Turn 2 produced visible answers with no tool call. The latest warm row
  answered `3`.
- Turn 2 had no tool call, no reasoning leak, no protocol leak, and no
  length-stop fake pass.
- Turn 3 required tool call after assistant/tool history finished as
  `tool_calls`.
- Turn 3 exact tool args: `{"text":"one\ntwo"}`.
- Turn 3 had no visible content leak and no protocol leak.
- App `/health` after the row was healthy, resident on
  `step-3.7-flash-jangtq_k`, and had no in-flight request.
- Token/s was recorded. The latest warm row visible turn 2 produced 2
  completion tokens in 0.436365625 seconds, about 4.58 tok/s. Required
  tool-call turns emitted zero completion tokens by design.

Cache/topology proven:

- 45 total layers.
- 12 full KV layers.
- 33 rotating/sliding KV layers.
- `requires_disk_backed_restore=true`.
- Paged cache incompatible for this rotating hybrid row.
- `turbo_quant_kv_layer_count=0`.
- Cold row delta: `block_disk_misses +2`, `block_disk_stores +5`,
  `block_disk_hits +0`.
- Warm row delta: `block_disk_hits +1`, `block_disk_misses +0`,
  `block_disk_stores +5`.

Boundary:

- This row proves Step JANGTQ_K required-tool parsing, reasoning separation,
  multi-turn tool-result history, no visible loop, no length-stop fake pass,
  and rotating/topology detection through the real no-sign Osaurus app.
- The warm row proves disk L2 reuse for this Step JANGTQ_K path with
  `disk_l2_hits +1`.
- The current live rows record `turbo_quant_kv_layer_count=0` for Step
  JANGTQ_K, while batch diagnostics record TurboQuant compression events. Treat
  this as tool/reasoning/topology/disk-L2 proof, not as a claim that all Step
  rotating layers use TurboQuant KV.

## 2026-05-31 Current-Head Retest Boundary

- App:
  `/private/tmp/osaurus-step37-full-pr/build/DerivedData-step37-hostfix-nosign-17c8b5ec/Build/Products/Release/osaurus.app`.
- Launch path: LaunchServices with `launchctl setenv
  OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS 1`, isolated `OSAURUS_TEST_ROOT`, and
  `OSU_MODELS_DIR=/tmp/osaurus-step37-localmeta-modelroot`.
- No `security`, `notarytool`, Developer ID signing, or password/keychain
  prompt was used. The only signing-sensitive process observed was the
  long-lived system `CodeSigningHelper.xpc`, not a validation/build lane.
- `step-3.7-flash-jang_2l` one-turn `tool_choice: required` stream returned
  `line_count` with exact arguments `{"text":"red\ngreen\nblue"}` and
  `finish_reason=tool_calls`.
- `step-3.7-flash-jangtq_k` one-turn `tool_choice: required` stream returned
  `line_count` with exact arguments `{"text":"red\ngreen\nblue"}` and
  `finish_reason=tool_calls`.
- `/health` after the JANGTQ_K row was healthy, had no in-flight request, and
  had `step-3.7-flash-jangtq_k` resident.
- `/admin/cache-stats` after the JANGTQ_K row reported the expected Step
  topology: 45 layers, 12 KV layers, 33 rotating KV layers,
  `requires_disk_backed_restore=true`, paged-incompatible, and
  `turbo_quant_kv_layer_count=0`.
- This current-head retest ran concurrently with a separate Step MLX job using
  the device, so first-token latency was about 13-14 minutes per one-turn row.
  It confirms current app/tool/topology wiring but does not replace the
  2026-05-30 full three-turn and warm L2 proof artifacts above.

## Current Step TurboQuant KV Policy Proof

- The current vMLX pin `60b888659e1196995fa57f7af91d982e5948a680` includes the
  Step cache construction fix from the earlier pinned history: when
  `GenerateParameters.kvMode = .turboQuant`, full-attention layers remain
  `KVCacheSimple` even when Osaurus also supplies `defaultMaxKVSize`. Without
  this, Step full-attention layers became bounded `RotatingKVCache` instances
  and the TurboQuant hook had no eligible layers.
- Focused vMLX coverage now pins both sides of the Step contract:
  `Step37ParserDispatchTests/stepCacheTopologyKeepsFullAttentionTQCompatible`
  and
  `Step37ParserDispatchTests/stepTurboQuantKVContractCoversOnlyFullAttentionLayers`.
- That test proves the vMLX TurboQuant hook is constrained to `KVCacheSimple`
  full-attention layers and explicitly preserves `RotatingKVCache`,
  `DeepseekV4Cache`, `MambaCache`, and `CacheList` paths.
- Osaurus `ModelRuntime.shouldUseTurboQuantByDefault` now enables
  engine-selected TurboQuant only for Step topologies with KV layers and no
  Mamba/arrays/hybrid-pool/rotating-wrapper/ZAYA-CCA companion state. The guard
  still keeps DSV4, ZAYA/ZAYA-VL, Gemma, SSM/CCA/hybrid-pool families, and
  unknown path-dependent topologies native by default.
- Focused Osaurus tests now expect `turbo(3,3)` for known Step JANG_2L and
  Step JANGTQ_K topology tags, and source guards pin the Step exception text.
- Boundary: this is a source/topology and focused-test proof for the policy
  itself. The no-sign app artifacts above are the measured live evidence for
  Step tool behavior, token/s, topology, and warm disk-L2 reuse.

## Partial / Blocked Rows

Step JANG_2L:

- Superseded older partial attempts with the final artifact
  `/tmp/osaurus-step37-final-430481c-step-jang2l-tool-20260530-204607/step-3.7-flash-jang_2l_summary.json`,
  which reports `passed: true` and `failed_checks: []` for strict
  required/none/required multi-turn tool behavior.
- Current-head 2026-05-31 smoke also confirmed one-turn required-tool behavior
  through the no-sign app while the device was contended by a separate Step MLX
  job. Treat the final 2026-05-30 artifact as the full matrix proof and the
  2026-05-31 row as current-head smoke confirmation.

Step JANGTQ_K:

- The earlier red row
  `/tmp/osaurus-step37-jangtqk-open-proof-20260530-151428` failed because the
  native Step template kept the required-tool contract inside hidden thinking.
- The final row above supersedes that red artifact for required-tool behavior.
- Warm disk-L2 hit reuse is proven by
  `/tmp/osaurus-step37-discoveryfix-430481c-step-jangtqk-warm-20260530-221128/step-3.7-flash-jangtq_k_summary.json`,
  which reports `passed: true`, `failed_checks: []`, and `block_disk_hits +1`.

Step JANGTQ2:

- No local Step JANGTQ2 bundle was found. Do not claim Step JANGTQ2 proof.

VL/media:

- No fresh real media row was run for this PR evidence. Do not claim VL proof
  from the Step/LFM rows.

## Source And Guard Verification

Focused Swift tests passed:

- `ModelRuntimeFindDirectoryTests/jangtq_formatStampWithSidecar_passes`
- `ModelRuntimeFindDirectoryTests/shardedSymlinkLayoutResolvesFromBoundedSentinel`
- `ModelManagerTests/scanLocalModels_detectsShardedIndexWithoutListingAllWeights`
- `ModelMediaCapabilitiesMCDCTests/step37TextRuntimeDoesNotAdvertiseMedia`
- `MLXServiceRuntimePolicyTests/stepToolSupportDoesNotRequireBundleMetadataPreflight`
- `MLXModelTests/step37DownloadedModelIsTextOnlyForPickerEvenWithVisionConfig`
- `EnsureJANGTQSidecarTests/stepJANGTQUsesSidecarSentinelWithoutMetadataFetch`
- `EnsureJANGTQSidecarTests/stepJANGTQMissingSidecarFailsWithoutAutoFetch`
- `RuntimePolicySourceTests/vmlxPinIncludesRuntimeHardening`
- `SwiftTransformersTokenizerLoaderTests/step37LocalTokenizerUsesRequiredToolFallbackAndClosesThinkingRail`
- `MLXBatchAdapterTests/additionalContext_threadsRequiredToolChoiceToLocalTemplates`
- `MLXBatchAdapterTests/cacheKVModeTagTracksEffectiveCoordinatorPolicy`

Guard scripts passed:

- `scripts/live-proof/assert-tool-choice-required-routing.sh`
- `scripts/live-proof/assert-keychain-free-proof-path.sh`
- `scripts/live-proof/assert-server-settings-runtime-wiring.sh`
- `scripts/live-proof/assert-osaurus-no-forced-behavior-pr.sh`
- `scripts/live-proof/assert-osaurus-vmlx-pr-readiness.sh`
- `scripts/live-proof/assert-osaurus-pr-hygiene.sh`
- `scripts/live-proof/assert-chat-reasoning-delta-routing.sh`
- `scripts/live-proof/assert-chat-ui-reasoning-routing.sh`
- `scripts/live-proof/assert-http-channel-load-cancellation.sh`
- `scripts/live-proof/assert-model-tool-capability-surfaces.sh`

No fake-fix boundary:

- No hidden sampler defaults, forced repetition penalty, close-token bias,
  forced thinking/reasoning behavior, or broad parser repair was used for the
  live proof.
