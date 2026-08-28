# Step 3.7 Osaurus E2E Evidence - 2026-05-30

Current vMLX pin: `25f8111552005fdc6ef12cd2c8298a782d4e2052`

This note records the final no-sign Osaurus proof for the Step 3.7 lane. It does
not claim LFM, MXFP4/MXFP8, or VL rows unless explicitly listed below.

## 2026-06-01 Final Step Parser/Cache Refresh

Final no-sign app:
`build/DerivedData-post1314-step-parser-25f8111/Build/Products/Release/osaurus.app`.

Launch/proof boundary:

- Built with `scripts/live-proof/build-keychain-free-osaurus.sh`.
- Build settings included `CODE_SIGNING_ALLOWED=NO`,
  `CODE_SIGNING_REQUIRED=NO`, `CODE_SIGN_IDENTITY=`, and
  `AD_HOC_CODE_SIGNING_ALLOWED=NO`.
- Final seal was local ad-hoc only with `/usr/bin/codesign --sign -
  --timestamp=none`; no identity, certificate, notary, `security` command, or
  password/keychain prompt was used.
- Launched through LaunchServices with `launchctl` env:
  `OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1`,
  `OSAURUS_TEST_ROOT=/tmp/osaurus-post1314-step-final-root/state-open`, and
  `OSU_MODELS_DIR=/tmp/osaurus-post1314-step-final-root/models`.
- `/v1/models` served `step-3.7-flash-jang_2l` and
  `step-3.7-flash-jang_k`.

Final strict Step JANG_2L artifact:
`/tmp/osaurus-post1314-25f8111-step-jang2l-final-20260601-191743/step-3.7-flash-jang_2l_summary.json`.

Final strict Step JANG_K artifact with warm disk-L2 restore:
`/tmp/osaurus-post1314-25f8111-step-jangk-restart-l2-20260601-192211/step-3.7-flash-jang_k_summary.json`.

Both final rows reported `passed=true`, `failed_checks=[]`. They prove strict
required/none/required multi-turn `line_count` behavior through the real
Osaurus app path: exact turn 1 args `red\ngreen\nblue`, exact turn 3 args
`one\ntwo`, visible no-tool follow-up, no protocol leak, no incoherent loop, no
length-stop fake pass, healthy `/health` after the row, and token/s recorded
for the visible generation turn. Topology is 45 layers with 12 KV layers and 33
rotating KV layers, `requires_disk_backed_restore=true`, paged-incompatible,
and `turbo_quant_kv_layer_count=0`. The final JANG_K restart row proves disk L2
restore with `block_disk_hits +1`, `block_disk_misses 0`, and
`block_disk_stores +5`.

The final vMLX fix is narrow: Step JANG_K emitted a Step-native bare XML
function envelope beginning with `<function=line_count>` after tool history.
The parser now buffers and parses that envelope. This is not a sampler,
repetition-penalty, close-token, synthetic reasoning, or prompt-coercion fix.

## Build and launch

- Build path:
  `/tmp/osaurus-step37-pr/build/DerivedData-step37-nosign-discoveryfix/Build/Products/Release/osaurus.app`
- Build command used the keychain-free wrapper:
  `scripts/live-proof/build-keychain-free-osaurus.sh`
- Signing settings observed:
  `CODE_SIGNING_ALLOWED=NO`, `CODE_SIGNING_REQUIRED=NO`,
  `CODE_SIGN_IDENTITY=`, `AD_HOC_CODE_SIGNING_ALLOWED=NO`.
- The post-build bundle seal was local ad-hoc only:
  `/usr/bin/codesign --sign - --timestamp=none`.
- Runtime launch used:
  `OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1`,
  fresh `OSAURUS_TEST_ROOT`, and
  `OSU_MODELS_DIR=/tmp/osaurus-step37-modelroot-jang-and-tqk`.
- Served model ids:
  `step-3.7-flash-jang_2l` and `step-3.7-flash-jangtq_k`.

No `security`, `notarytool`, Developer ID signing, or password/keychain prompt
was used in this proof lane.

## Live TurboQuant and L2 proof

Artifact:
`/tmp/osaurus-step37-tqdiag-430481c-live-20260530-203554/summary.json`

- Cold row: HTTP 200, `finish=stop`, no protocol leak, no length stop.
- Cold row deltas: `turbo_quant_compressions +1`, `disk_l2_misses +2`,
  `disk_l2_stores +1`.
- Warm row: HTTP 200, `finish=stop`, no protocol leak, no length stop.
- Warm row deltas: `turbo_quant_compressions +1`, `disk_l2_hits +1`,
  `disk_l2_stores +1`.
- Visible generation token/s was recorded in the artifact.

This proves the Osaurus app sees live TurboQuant compression diagnostics from
the pinned vMLX runtime and reuses the disk L2 block store on a repeated prefix.

## Live multi-turn tool proof

Artifact:
`/tmp/osaurus-step37-final-430481c-step-jang2l-tool-20260530-204607/step-3.7-flash-jang_2l_summary.json`

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
  `requires_disk_backed_restore=true`, paged-incompatible.
- Batch diagnostics after row:
  `turbo_quant_compressions=4`, `disk_l2_hits=1`,
  `disk_l2_stores=7`.

This proves Step 3.7 JANG_2L through the real Osaurus app path for strict
required/none/required multi-turn tool behavior, no loop/leak/length-stop fake
pass, disk-backed restore topology, and live TurboQuant/L2 diagnostics.

## Live Step JANGTQ_K tool/cache proof

Cold artifact:
`/tmp/osaurus-step37-discoveryfix-430481c-step-jangtqk-tool-20260530-221008/step-3.7-flash-jangtq_k_summary.json`

Warm artifact:
`/tmp/osaurus-step37-discoveryfix-430481c-step-jangtqk-warm-20260530-221128/step-3.7-flash-jangtq_k_summary.json`

- Overall verdict: both rows reported `passed=true`, `failed_checks=[]`.
- Turn 1 required tool call:
  `line_count`, exact args `text == "red\ngreen\nblue"`, no visible content,
  no protocol leak.
- Turn 2 no-tool answer:
  visible answer, no tool call, no protocol leak, `finish=stop`, token/s
  recorded.
- Turn 3 required tool call after tool-result history:
  `line_count`, exact args `text == "one\ntwo"`, no visible content,
  no protocol leak.
- Health after rows:
  `status=healthy`, no in-flight requests, model resident.
- Cache topology:
  45 layers, 12 KV layers, 33 rotating KV layers,
  `requires_disk_backed_restore=true`, paged-incompatible,
  `turbo_quant_kv_layer_count=0`.
- Cold row cache:
  `disk_l2_misses +2`, `disk_l2_stores +5`.
- Warm row cache:
  `disk_l2_hits +1`, `disk_l2_misses +0`, `disk_l2_stores +5`.
- Warm visible generation rate:
  2 completion tokens in 0.436365625 seconds, about 4.58 tok/s. Required
  tool-call turns emitted zero completion tokens by design.

This proves Step 3.7 JANGTQ_K through the real Osaurus app path for strict
required/none/required multi-turn tool behavior, no loop/leak/length-stop fake
pass, disk-backed restore topology, rotating KV detection, and warm L2 reuse.

## Source and readiness guards

The following passed after repinning Osaurus to vMLX
`60b888659e1196995fa57f7af91d982e5948a680`:

- `git diff --check`
- `RuntimePolicySourceTests/vmlxPinIncludesRuntimeHardening`
- `MLXBatchAdapterTests/cacheKVModeTagTracksEffectiveCoordinatorPolicy`
- `scripts/live-proof/assert-server-settings-runtime-wiring.sh`
- `scripts/live-proof/assert-keychain-free-proof-path.sh`
- `scripts/live-proof/assert-osaurus-vmlx-pr-readiness.sh`
- `scripts/live-proof/assert-osaurus-no-forced-behavior-pr.sh`
- `scripts/live-proof/assert-osaurus-pr-hygiene.sh`
- `scripts/live-proof/assert-tool-choice-required-routing.sh`

The guards cover vMLX pin surfaces, runtime settings save/invalidation,
topology-gated engine-selected TurboQuant policy, block L2 settings, MTP
auto-detect settings, keychain-free proof paths, no hidden sampler or forced
behavior repairs, reasoning/UI routing, tool-choice routing, HTTP cancellation,
and PR hygiene.

## 2026-05-31 Current-Head Retest

The current retest used the rebuilt no-sign app:
`/tmp/osaurus-1310-60b888-nosign-dd/Build/Products/Release/osaurus.app`.

The launch used `scripts/live-proof/open-keychain-free-osaurus.sh` with
`OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1`, isolated
`OSAURUS_TEST_ROOT=/tmp/osaurus-1310-60b888-live-root-20260531-031451`, and
`OSU_MODELS_DIR=/tmp/osaurus-step37-localmeta-modelroot`.

LFM2.5 JANG_2L:

- Cold strict artifact:
  `/tmp/osaurus-1310-60b888-final-lfm-jang2l-20260531-031510/lfm2.5-8b-a1b-jang_2l_summary.json`.
- Warm strict cache-hit artifact:
  `/tmp/osaurus-1310-60b888-final-lfm-jang2l-warm1024-20260531-031546/lfm2.5-8b-a1b-jang_2l_summary.json`.
- Warm verdict: `passed=true`, `failed_checks=[]`.
- Turn 1 and turn 3 produced exact `line_count` tool calls with
  `red\ngreen\nblue` and `one\ntwo` respectively.
- Turn 2 produced visible answer `Three lines were counted.`, no tool call, no
  protocol leak, and no length-stop fake pass.
- Topology/cache: 24 layers, 6 KV layers, 18 Mamba/SSM companion layers,
  `requires_disk_backed_restore=true`, `requires_ssm_companion_state=true`,
  `turbo_quant_kv_layer_count=0`, and warm deltas `disk_l2_hits +1`,
  `ssm_companion_hits +1`, `companion_hits +1`.
- Visible generation rate: 351 completion tokens in 4.090642167 seconds, about
  85.81 tok/s.

Step 3.7 JANG_2L:

- Strict artifact:
  `/tmp/osaurus-1310-60b888-final-step-jang2l-20260531-031601/step-3.7-flash-jang_2l_summary.json`.
- Verdict: `passed=true`, `failed_checks=[]`.
- Turn 1 and turn 3 produced exact `line_count` tool calls with
  `red\ngreen\nblue` and `one\ntwo` respectively.
- Turn 2 produced visible answer `Three lines were counted.`, no tool call, no
  protocol leak, and no length-stop fake pass.
- Topology/cache: 45 layers, 12 KV layers, 33 rotating KV layers,
  `requires_disk_backed_restore=true`, paged-incompatible, and
  `turbo_quant_compressions=2`.
- Visible generation rate: 6 completion tokens in 0.745120167 seconds, about
  8.05 tok/s.

## Boundaries

- Step 3.7 JANG_2L is green for this PR lane.
- Step JANGTQ_K is green for this PR lane, including a warm `disk_l2_hits +1`
  row.
- 2026-05-31 retest boundary: a fresh no-sign, LaunchServices-launched,
  keychain-disabled app at
  `/private/tmp/osaurus-step37-full-pr/build/DerivedData-step37-hostfix-nosign-17c8b5ec/Build/Products/Release/osaurus.app`
  confirmed one-turn `tool_choice: required` behavior for
  `step-3.7-flash-jang_2l` and `step-3.7-flash-jangtq_k`. Both streamed exact
  `line_count` tool calls with args `{"text":"red\ngreen\nblue"}` and
  `finish_reason=tool_calls`; `/health` was healthy with no in-flight request
  after the rows. The retest ran while a separate Step MLX job was consuming the
  device, so first-token latency was about 13 minutes per row. Treat the
  2026-05-30 artifacts above as the full JANGTQ_K multi-turn/warm-cache proof.
- LFM2.5 JANG_2L is green for this PR lane on the rebuilt 60b888 app, including
  strict required/none/required tools and warm `disk_l2_hits +1`,
  `ssm_companion_hits +1`, and `companion_hits +1`.
- MXFP4/MXFP8 sibling bundles are not claimed by this proof.
- VL/media rows are not claimed by this proof.
- The Step topology is mixed full KV plus rotating KV. The runtime policy only
  permits TurboQuant KV for the compatible full-KV portion through the vMLX
  engine-selected path and keeps disk-backed restore for the architecture.
