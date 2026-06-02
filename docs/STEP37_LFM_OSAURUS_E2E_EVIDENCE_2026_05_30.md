# Step 3.7 / LFM Osaurus E2E Evidence - 2026-05-30

This document records the no-sign Osaurus app proof for the Step/LFM lane and
later bounded MiniMax/ZAYA additions. It deliberately separates proven rows
from partial rows.

## Code State

- Final local Osaurus PR head before the final vMLX repin commit:
  `1bc3202c0ccc36f791d27ef7ce7943eba0b691b8`.
- Final local vMLX pin after the Step bare XML function-envelope parser fix:
  `25f8111552005fdc6ef12cd2c8298a782d4e2052`.
- Final no-sign app:
  `build/DerivedData-post1314-step-parser-25f8111/Build/Products/Release/osaurus.app`.
- Final Step JANG_2L artifact:
  `/tmp/osaurus-post1314-25f8111-step-jang2l-final-20260601-191743/step-3.7-flash-jang_2l_summary.json`.
- Final Step JANG_K warm disk-L2 artifact:
  `/tmp/osaurus-post1314-25f8111-step-jangk-restart-l2-20260601-192211/step-3.7-flash-jang_k_summary.json`.
- Final Step JANG_K parser-only cold artifact:
  `/tmp/osaurus-post1314-25f8111-step-jangk-final-20260601-191716/step-3.7-flash-jang_k_summary.json`.
- Final Step verdict: both JANG_2L and JANG_K pass the strict no-sign Osaurus
  app required/none/required multi-turn `line_count` harness with exact turn 1
  args `red\ngreen\nblue`, exact turn 3 args `one\ntwo`, visible no-tool
  follow-up, no protocol leak, no incoherent loop, no length-stop fake pass,
  token/s recorded for visible generation, healthy `/health`, 45-layer mixed
  topology with 12 KV and 33 rotating KV layers, disk-backed restore required,
  paged-incompatible, and `turbo_quant_kv_layer_count=0`. The JANG_K restart
  row additionally proves disk L2 restore with `block_disk_hits +1`,
  `block_disk_misses 0`, and `block_disk_stores +5`.
- The final vMLX fix is narrow parser repair for a Step-native bare XML
  function envelope beginning with `<function=line_count>` after tool history.
  It does not add hidden sampler defaults, repetition penalties, close-token
  biasing, synthetic reasoning tags, or fake prompt coercion.
- Current Osaurus PR head after the latest Step proof-boundary refresh:
  `9804bb474ad73cd107a493ccaba2e9b3f5c964c1`.
- Earlier Osaurus PR head after Step proof-harness hardening:
  `31911e2319b324250bca3f3660a75d2d182e55a9`.
- Earlier Osaurus PR head after the ZAYA evidence refresh:
  `dceaf9edf85ffe0d20a0b142b6dbe585b4874828`.
- Previous local vMLX pin after the Step required-template refresh:
  `eb116ef735d9445cfac30b6a3346ff162483122e`.
- Previous final vMLX pin in Osaurus before the current refresh:
  `3043cc98d7c2a0fd9df34376e6b42beec5517516`.
- Historical Step/LFM vMLX proof pin used by the first rows in this file:
  `60b888659e1196995fa57f7af91d982e5948a680`.
- vMLX fixes:
  - The historical `60b888659e1196995fa57f7af91d982e5948a680` pin includes the
    Step runtime/cache work plus the LFM required-tool thinking-tail fix used
    by the first proof rows.
  - LFM required-tool fallback closes the native thinking rail only when
    `tool_choice` is explicit required/named, so required tool turns do not
    spend the output budget in hidden reasoning before emitting a call. Optional
    tools remain optional.
  - Step tool-call parser support for Step XML and narrow schema-gated bare
    `name({"arg": ...})` calls on reasoning/content rails.
  - Step required-tool fallback closes the native thinking rail before the
    explicit function-call contract so `tool_choice: required` does not remain
    trapped in hidden reasoning.
  - The current `eb116ef...` vMLX refresh tightens the Step fallback for
    explicit `tool_choice: required` after history: the final current-turn user
    value is repeated as the exact native Step XML tool call shape, so a later
    required call cannot legally reuse the previous `red/green/blue` argument
    or emit prose instead of the tool call.
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
  Full simple-KV models can use TurboQuant KV. Step 3.7 is now conservative
  native/fp16 by default in Osaurus because current no-sign app rows prove
  mixed full-attention + SWA disk-backed topology but do not prove warm
  tool-history TurboQuant-KV stability. LFM SSM/Mamba hybrid cache still uses
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

## 2026-06-01 Current-Head Repair: Step 3.7 JANG_2L Osaurus App Path

- Osaurus fix:
  `MLXBatchAdapter.shouldEnableCompiledBatchDecode` now keeps Step 3.7 off the
  single-slot compiled batch-decode trace, matching the proven vMLX BatchEngine
  route. This is a runtime route fix, not prompt coercion, parser repair,
  hidden sampling, or repetition rescue.
- Focused test:
  `MLXBatchAdapterTests/compiledBatchDecodeDisabledForKnownUnsafeSoloModels`
  passed after the Step exception was added.
- Guard:
  `assert-osaurus-no-forced-behavior-pr.sh` passed after the patch.
- No-sign app:
  `build/DerivedData-step37-uncompiled-fix-b1f8b8f1/Build/Products/Release/osaurus.app`.
- Keychain/signing boundary:
  built through `scripts/live-proof/build-keychain-free-osaurus.sh`, with
  `CODE_SIGNING_ALLOWED=NO`, `CODE_SIGNING_REQUIRED=NO`,
  `CODE_SIGN_IDENTITY=`, `AD_HOC_CODE_SIGNING_ALLOWED=NO`, and only a local
  ad-hoc seal. The live run used `OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1`, a
  fresh `OSAURUS_TEST_ROOT`, and a model root containing only
  `Step-3.7-Flash-JANG_2L`.
- Smoke artifact:
  `/tmp/osaurus-post1314-step37-compiled-off-20260601-012207`. Cold two-token
  request returned `\nok` in 19.56s including load; immediate resident two-token
  request returned `\nok` in 0.148s.
- Strict cold/topology artifact:
  `/tmp/osaurus-post1314-step37-compiled-off-tool-cache-20260601-012335/step-3.7-flash-jang_2l_summary.json`.
- Strict warm disk-L2 artifact:
  `/tmp/osaurus-post1314-step37-compiled-off-warm-cache-20260601-012404/step-3.7-flash-jang_2l_summary.json`.
- Final verdict:
  both strict rows passed with `failed_checks=[]`. Turn 1 produced exact
  `line_count` args `red\ngreen\nblue`; turn 2 answered visibly
  `Three lines were counted.` with `finish=stop`, no tool call, no protocol
  leak, and no length-stop fake pass; turn 3 produced exact `line_count` args
  `one\ntwo` after assistant/tool history. The warm row proved disk reuse with
  `block_disk_hits=1`, no new misses, and `block_disk_stores=5`.
- Topology:
  45 layers, 12 KV layers, 33 rotating KV layers,
  `requires_disk_backed_restore=true`, paged-incompatible, and
  `turbo_quant_kv_layer_count=0`.
- Boundary:
  this promotes Step JANG_2L only for the listed pre-`eb116ef...` artifacts.
  Step JANG_K is not claimed by this repair row; current non-empty CRACK
  bundles exist, but the fresh `eb116ef...` attempts below timed out before
  producing a green live row. Step JANGTQ_K is not claimed by this repair row.

## 2026-06-01 Current Refresh: Step Required-Template Pin `eb116ef`

- vMLX main pin:
  `eb116ef735d9445cfac30b6a3346ff162483122e`.
- Osaurus no-sign app:
  `build/DerivedData-post1314-step-template-eb116ef/Build/Products/Release/osaurus.app`.
- Source proof:
  `Step37ParserDispatchTests` passed in vMLX before the pin was updated.
  `SwiftTransformersTokenizerLoaderTests/step37LocalTokenizerUsesRequiredToolFallbackAndClosesThinkingRail`
  passed in Osaurus against the pinned checkout. `RuntimePolicySourceTests`
  passed 75/75 against the same pin. The vMLX readiness, PR hygiene,
  server-settings/runtime, tool-choice, keychain-free, and no-forced-behavior
  guards also passed.
- No-sign/keychain boundary:
  the app was built with `CODE_SIGNING_ALLOWED=NO`,
  `CODE_SIGNING_REQUIRED=NO`, `CODE_SIGN_IDENTITY=`, and
  `AD_HOC_CODE_SIGNING_ALLOWED=NO`, then launched with
  `OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1`, fresh `OSAURUS_TEST_ROOT`, and
  explicit `OSU_MODELS_DIR`.
- Step JANG_K CRACK-v5 direct probe:
  `/tmp/osaurus-post1314-step37-jangk-crackv5-eb116ef-direct1-20260601-125242`
  timed out after 180s before returning turn 1. The strict harness attempt
  `/tmp/osaurus-post1314-step37-jangk-crackv5-eb116ef-cold-20260601-124101`
  was stopped after running past the useful proof window with one in-flight
  request. Both attempts ran while a separate Step CRACK process was consuming
  about 74 GB RSS, but neither is a pass.
- Current Osaurus PR head after the stale Step cache-mode test fix:
  `eda7ac94cd78b54846db850a44fa7f1f2dcacb4d`.
- Current Osaurus PR head after Step proof-harness hardening:
  `31911e2319b324250bca3f3660a75d2d182e55a9`.
  This follow-up added two proof-quality guards: the live multi-turn harness
  writes request JSON before network calls and emits failed per-model summaries
  on exceptions/timeouts, and
  `MLXBatchAdapterTests/additionalContext_threadsRequiredToolChoiceToLocalTemplates`
  explicitly covers `Step-3.7-Flash-JANG_2L` required-tool context. The focused
  source test passed. A fresh no-sign app full-harness attempt at
  `/tmp/osaurus-post1314-31911e23-step-jang2l-full-20260601-140154` was stopped
  after turn 1 remained in flight under the separate 74 GB Step CRACK-v8 job;
  it records the pre-call request/health/cache files and is a blocked
  contested-machine artifact, not a green or red model verdict.
- Current Osaurus PR head after the latest Step proof-boundary refresh:
  `9804bb474ad73cd107a493ccaba2e9b3f5c964c1`.
  Source guards `assert-osaurus-vmlx-pr-readiness.sh`,
  `assert-osaurus-no-forced-behavior-pr.sh`, and
  `assert-tool-choice-required-routing.sh` passed on the same `eb116ef...`
  vMLX pin. A fresh no-sign app run used
  `OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1`, a fresh `OSAURUS_TEST_ROOT`, and a
  one-model root containing `Step-3.7-Flash-JANG_2L`; `/v1/models` served
  `step-3.7-flash-jang_2l`. Artifact
  `/tmp/osaurus-post1314-9804bb47-step-jang2l-full-20260601-140957` was
  stopped after more than five minutes with `/health` still healthy, one
  in-flight request, no turn-1 response artifact, and the external
  `Step-3.7-Flash-JANG_K-CRACK-v8` job still consuming about 74 GB RSS. The
  artifact contains an explicit failed `SUMMARY.json`; treat it as
  resource-blocked, not as a parser/coherency failure and not as a green row.
  Isolation artifact
  `/tmp/osaurus-post1314-920fa406-step-probe-20260601-141746` then sent a tiny
  plain chat request (`Reply with ok.`, `max_tokens=8`, no tools) through the
  same no-sign app and one-model root. It also stayed in flight with an empty
  response while the app remained healthy. Sample
  `/tmp/osaurus-post1314-920fa406-step-plain-sample.txt` showed
  `TokenIterator.next()` waiting in
  `mlx::core::scheduler::Scheduler::wait_for_one()`, so the current blocked
  row is below Osaurus chat/autodetect/tool-parser wiring.
- GitHub CI on `eda7ac94` passed:
  `shellcheck`, `swiftlint`, `test-cli`, `test-core`, and
  `update_release_draft`.
- Current Step JANG_2L strict partial artifact:
  `/tmp/osaurus-post1314-eda7ac94-step-jang2l-20260601-132614`.
  This no-sign app row used `OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1`, a fresh
  `OSAURUS_TEST_ROOT`, and explicit `OSU_MODELS_DIR`; `/v1/models` served
  `step-3.7-flash-jang_2l`. The full harness did not finish and has no
  summary JSON because it was stopped after running too long under the separate
  Step CRACK workload. The completed turn files are still useful evidence:
  turn 1 returned exact structured `line_count` args `red\ngreen\nblue` with
  `finish_reason=tool_calls`, zero completion tokens, and no visible prose;
  turn 2 returned visible content `Three lines were counted.` with
  `finish_reason=stop`, no tool call, and no protocol leak.
- Current Step JANG_2L direct turn-3 artifact:
  `/tmp/osaurus-post1314-eda7ac94-step-jang2l-turn3-direct-20260601-134409`.
  This focused no-sign app probe replayed the same assistant/tool history and
  sent the missing required turn. It passed with exact structured
  `line_count` args `one\ntwo`, `finish=tool_calls`, one tool call,
  no visible prose, zero completion tokens, and 3.83s elapsed.
- Current Step JANG_2L topology/cache after the direct row:
  `/tmp/osaurus-post1314-step-turn3-cache-after.json` reported 45 layers,
  12 KV layers, 33 rotating KV layers, `requires_disk_backed_restore=true`,
  paged-incompatible, `turbo_quant_kv_layer_count=0`, and `disk_l2_stores=1`.
  This current refresh does not claim a fresh warm disk-L2 hit; the older
  pre-`eb116ef...` warm artifacts above remain the warm L2-hit proof.
- Current verdict:
  `eb116ef...` source/wiring is green, CI is green at `eda7ac94`, and current
  no-sign app evidence covers Step JANG_2L required-tool turn 1, visible no-tool
  turn 2, and required-tool-after-history turn 3 without protocol leakage or
  fake sampler/prompt fixes. Because the current full harness was split by the
  long-running turn-2 path under machine contention, do not overstate this as a
  single green current-head `*_summary.json` row. Step JANG_K remains blocked by
  timeout/slow decode and is not promoted by this refresh.

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

## Historical Proven Live Row: Step 3.7 JANGTQ_K

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
- This section is retained as historical Step JANGTQ_K evidence. The June 1
  repair section above promotes Step JANG_2L only, and does not add a new
  current-head Step JANGTQ_K proof.

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

## Historical Step TurboQuant KV Policy Proof

- The earlier vMLX pin `60b888659e1196995fa57f7af91d982e5948a680` included the
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
- Osaurus `ModelRuntime.shouldUseTurboQuantByDefault` now keeps Step 3.7
  native/fp16 by default until a current warm tool-history TurboQuant-KV row is
  green. The guard still keeps DSV4, ZAYA/ZAYA-VL, Gemma,
  SSM/CCA/hybrid-pool families, and unknown path-dependent topologies native by
  default.
- Focused Osaurus source tests pin the current Step native/fp16 policy text.
- Boundary: this is a source/topology and focused-test proof for the policy
  itself. The no-sign app artifacts above are the measured live evidence for
  Step tool behavior, token/s, topology, and warm disk-L2 reuse.

## 2026-06-01 Current-Head MiniMax Full-KV Policy Probe

- Osaurus PR head: `497a52dad9c7c98df407ee3b855216401d9d2d71`.
- No-sign app:
  `build/DerivedData-minimax-policy-probe-497a52da/Build/Products/Release/osaurus.app`.
- Model:
  `/Users/eric/.mlxstudio/models/JANGQ-AI/MiniMax-M2.7-Small-JANGTQ`,
  served as `minimax-m2.7-small-jangtq`.
- Native-KV cold smoke artifact:
  `/tmp/osaurus-post1314-minimax-native-ls-probe-20260601-024219/native-smoke.json`.
  The app returned exact visible `ok` in 21.68 seconds including load and stayed
  healthy with the model resident.
- Native-KV strict tool/topology artifact:
  `/tmp/osaurus-post1314-minimax-native-tool-cache-20260601-024325/minimax-m2.7-small-jangtq_summary.json`.
  The strict required/none/required harness passed with exact `line_count` args
  `red\ngreen\nblue` and `one\ntwo`, visible turn 2 answer, no protocol leak, no
  visible content on tool-call turns, no length-stop fake pass, and healthy
  `/health` after the row. Token/s on the visible turn was 5.99. Topology was
  62 full KV layers, no rotating/SSM/ZAYA companion layers,
  `requires_disk_backed_restore=false`, `turbo_quant_kv_layer_count=0`, and the
  row recorded paged/prefix hits.
- Native-KV warm disk-L2 boundary artifact:
  `/tmp/osaurus-post1314-minimax-native-warm-disk-20260601-024352/minimax-m2.7-small-jangtq_summary.json`.
  The tool/coherency checks passed again, but the row failed only
  `cache_evidence_disk_l2_hits` because the resident native path reused
  prefix/paged memory caches and `block_disk_hits` stayed 0.
- Engine-selected/default strict tool/topology artifact:
  `/tmp/osaurus-post1314-minimax-engine-selected-tool-cache-20260601-024500/minimax-m2.7-small-jangtq_summary.json`.
  This default path passed the strict tool harness with exact args, visible turn
  2 answer, no leak/loop/length fake, and healthy state. It recorded
  `block_disk_hits +1`, `turbo_quant_compressions=3`, 62 full KV layers, and
  `is_paged_incompatible=true` for the selected path.
- Verdict: MiniMax M2.7 Small JANGTQ is no longer blocked in this matrix for the
  bounded no-sign app path. It is promoted for text/tool/coherency plus
  engine-selected full-KV cache reuse. MiniMax VL/audio is not claimed.

## 2026-06-01 Current-Head ZAYA1 Text/VL JANGTQ4 Proof

- Osaurus PR head: `6aa8aa17ee83d82f6c04ca2ff69bdb2af14b59c9`.
- No-sign app:
  `build/DerivedData-zaya-proof-6aa8aa17/Build/Products/Release/osaurus.app`.
- Models:
  `/Users/eric/models/JANGQ/ZAYA1-8B-JANGTQ4`, served as
  `zaya1-8b-jangtq4`, and `/Users/eric/models/JANGQ/ZAYA1-VL-8B-JANGTQ4`,
  served as `zaya1-vl-8b-jangtq4`.
- Text cold strict tool/topology artifact:
  `/tmp/osaurus-post1314-zaya-text-jangtq4-current-20260601-032237/zaya1-8b-jangtq4_summary.json`.
- Text warm disk-L2 artifact:
  `/tmp/osaurus-post1314-zaya-text-jangtq4-warmdisk-20260601-032427/zaya1-8b-jangtq4_summary.json`.
- VL red-image artifact:
  `/tmp/osaurus-post1314-zaya-vl-jangtq4-red-current-20260601-032534/SUMMARY.json`.
- The text rows passed exact strict required/none/required multi-turn tool
  behavior: turn 1 `line_count` args `red\ngreen\nblue`, turn 2 visible
  coherent answer, turn 3 `line_count` args `one\ntwo`, no protocol leakage, no
  visible content on tool-call turns, no length-stop fake pass, and healthy
  `/health` after the row.
- The warm text row restarted the same app against the same cache directory and
  recorded `block_disk_hits +1`. It reported 80 layers, 40 KV layers, 40 ZAYA
  CCA layers, `companion=zaya-cca`, disk-backed restore required,
  paged-incompatible, and `turbo_quant_kv_layer_count=0`.
- The VL row used a real generated 64x64 red PNG data URL. First and repeat
  responses were `Red`, prefix hash stayed
  `6e340b9cffb37a989ca544e6bb780a2c`, repeat `disk_l2_hits=1`, no protocol
  leakage occurred, and `/health` stayed healthy. The VL topology reported
  40 ZAYA CCA layers, disk-backed restore, and no TurboQuant KV layers.
- Boundary: ZAYA CCA topology/presence is proven, but CCA companion-hit reuse is
  not promoted because these rows recorded CCA companion misses rather than
  hits. ZAYA MXFP4 siblings were found locally but were not run in this evidence.

## Partial / Blocked Rows

Step JANG_2L:

- Superseded older partial attempts with the June 1 final artifacts
  `/tmp/osaurus-post1314-step37-compiled-off-tool-cache-20260601-012335/step-3.7-flash-jang_2l_summary.json`
  and
  `/tmp/osaurus-post1314-step37-compiled-off-warm-cache-20260601-012404/step-3.7-flash-jang_2l_summary.json`,
  which report `passed: true` and `failed_checks: []` for strict
  required/none/required multi-turn tool behavior plus warm disk-L2 reuse.
- The older artifact
  `/tmp/osaurus-step37-final-430481c-step-jang2l-tool-20260530-204607/step-3.7-flash-jang_2l_summary.json`,
  also reported `passed: true`, but it is no longer the current final proof.
- Current-head 2026-05-31 smoke also confirmed one-turn required-tool behavior
  through the no-sign app while the device was contended by a separate Step MLX
  job. Treat the June 1 artifacts above as the current full matrix proof.

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

- Fresh ZAYA1-VL and prior Gemma 4 26B red-image rows are recorded in
  `docs/POST1310_PRODUCTION_MODEL_MATRIX.md`. Do not claim broader
  video/audio/VL coverage from the Step/LFM rows.

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
