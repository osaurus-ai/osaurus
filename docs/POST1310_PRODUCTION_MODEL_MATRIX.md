# Post-1310 Production Model Matrix

Date: 2026-05-31

Osaurus branch head while testing: `38d10f681fd916bcad643916b4ab8b7b3c0e5e70`
with local PR changes.

vMLX pin in Osaurus: `3043cc98d7c2a0fd9df34376e6b42beec5517516`.

No-sign app used for live proof:
`/tmp/osaurus-post1314-nosign-3043cc98/Build/Products/Release/osaurus.app`

Model root used for live proof: `/tmp/osaurus-post1310-modelroot`

The app was built through `scripts/live-proof/build-keychain-free-osaurus.sh`.
The Xcode build used `CODE_SIGNING_ALLOWED=NO`, `CODE_SIGNING_REQUIRED=NO`,
`CODE_SIGN_IDENTITY=`, and `AD_HOC_CODE_SIGNING_ALLOWED=NO`. The final bundle
was sealed locally with an ad-hoc signature only: `Signature=adhoc`,
`TeamIdentifier=not set`. The live app was launched through the keychain-free
LaunchServices path with `OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1`,
`OSAURUS_TEST_ROOT`, and `OSU_MODELS_DIR` set by `launchctl`.

## Served Models

The fresh app launch served these model ids through `/v1/models`:

- `lfm2.5-8b-a1b-jang_2l`
- `lfm2.5-8b-a1b-mxfp4`
- `lfm2.5-8b-a1b-mxfp8`
- `step-3.7-flash-jang_2l`

`Step-3.7-Flash-JANG_K` is not claimed in this matrix. The only local matching
directory found earlier was empty, so it was not served by the final app model
root and was not tested.

## Source and Guard Coverage

Passed on the final vMLX pin:

- vMLX focused LFM fallback tests: `DeepseekV4ChatTemplateFallbackFocusedTests/lfm2`.
- vMLX focused LFM parser tests:
  `ToolTests/lfm2ProcessorAcceptsObservedFunctionlineRequiredToolOutput`,
  `ToolTests/lfm2ProcessorAcceptsObservedFunctionNameArgTagOutput`, and
  `ToolTests/lfm2ParserDoesNotCoercePlainCodeFenceIntoToolCall`.
- Osaurus source tests:
  `RuntimePolicySourceTests/vmlxPinIncludesRuntimeHardening` and
  `SwiftTransformersTokenizerLoaderTests/lfm2LocalTokenizerUsesStrictRequiredToolFallback`.
- Osaurus guard bundle:
  `assert-keychain-free-proof-path.sh`,
  `assert-server-settings-runtime-wiring.sh`,
  `assert-osaurus-vmlx-pr-readiness.sh`,
  `assert-osaurus-no-forced-behavior-pr.sh`, and
  `assert-osaurus-pr-hygiene.sh`.

These guards cover the vMLX pin surfaces, server settings wiring for prefix,
paged, L2 disk cache, live KV codec, TurboQuant bits, SSM rederive, MTP mode,
OpenResponses/cache source wiring, chat/OpenAI/Anthropic/OpenResponses reasoning
delta routing, tool-choice routing, no hidden sampler defaults, no forced
reasoning or close-token behavior, and keychain-free proof lanes. They are source
guards unless a live artifact is listed below.

## LFM2.5 JANG_2L

Verdict: green for the final PR scope: live no-sign Osaurus app, strict
multi-turn required/none/required tool behavior, no visible protocol leakage, no
incoherent loop, no length-stop fake pass on the accepted rows, LFM hybrid
topology, disk-backed restore requirement, and warm disk/SSM companion reuse.

Cold artifact:
`/tmp/osaurus-post1314-lfm-jang2l-3043cc98-cold-20260531-165836/lfm2.5-8b-a1b-jang_2l_summary.json`

Warm artifact with larger explicit output budget:
`/tmp/osaurus-post1314-lfm-jang2l-3043cc98-warm4096-20260531-170036/lfm2.5-8b-a1b-jang_2l_summary.json`

Warm repeat artifact at 1024 output tokens:
`/tmp/osaurus-post1314-lfm-jang2l-3043cc98-warm1024-repeat-20260531-170112/lfm2.5-8b-a1b-jang_2l_summary.json`

Confirmed:

- Turn 1 required tool call: exact `line_count` args `red\ngreen\nblue`.
- Turn 2 no-tool answer: visible coherent answer, no tool call, no protocol
  leak, no length-stop fake pass.
- Turn 3 required tool after assistant/tool history: exact `line_count` args
  `one\ntwo`.
- Cold visible answer speed: 166 completion tokens in 1.960s, about
  84.7 tok/s.
- Warm 4096 visible answer speed: 218 completion tokens in 3.126s, about
  69.7 tok/s.
- Warm 1024 repeat visible answer speed: 126 completion tokens in 1.515s,
  about 83.1 tok/s.
- Topology: 24 layers, 6 KV layers, 18 Mamba/SSM companion layers,
  `requires_disk_backed_restore=true`, `requires_ssm_companion_state=true`,
  `companion=ssm`, `turbo_quant_kv_layer_count=0`.
- Warm reuse proof: `block_disk_hits=1`, `ssm_companion_hits=1`, and
  `companion_hits=1` in both accepted warm rows.
- App health after accepted rows: healthy, no in-flight request, requested model
  resident and current.

Rejected intermediate artifact:
`/tmp/osaurus-post1314-lfm-jang2l-3043cc98-warm-20260531-165903/lfm2.5-8b-a1b-jang_2l_summary.json`

That row failed on turn 1 with `finish_reason=length`, hidden reasoning, no tool
call, and no disk L2 hit. It is recorded here so the matrix does not hide the
bad run. It is superseded by the subsequent warm 4096 and warm 1024 repeat rows,
which both passed exact tool behavior and cache-hit checks on the same app
session.

## Step 3.7 Flash JANG_2L

Current final-head verdict: not promoted by this matrix.

Attempted artifact directory:
`/tmp/osaurus-post1314-step37-jang2l-3043cc98-cold-20260531-170148`

The row was started against the final app and loaded
`step-3.7-flash-jang_2l`, but it stayed in-flight for several minutes without
writing a turn response summary. The request and app were killed to clear the
machine. Therefore this final matrix does not claim Step 3.7 JANG_2L live
tool/cache readiness.

Older Step 3.7 artifacts from earlier local work showed strict tool behavior and
L2 reuse but very poor no-sign Osaurus decode speed. Those older rows are not
used as final-head merge proof.

## LFM2.5 MXFP4 and MXFP8

Current final-head verdict: not promoted by this final rerun.

Older artifacts existed for MXFP4/MXFP8 strict tool rows, but they were not
rerun after the final `3043cc98...` vMLX pin and no-rail LFM change. This matrix
does not claim sibling MXFP4/MXFP8 warm cache production readiness.

## TurboQuant KV Boundary

This matrix does not prove TurboQuant KV for Step or LFM.

- LFM JANG_2L topology reports `turbo_quant_kv_layer_count=0`.
- Step JANG_2L was not promoted by the final live row.
- LFM is hybrid/paged-incompatible in these rows, so the proven behavior is
  native KV plus disk-backed restore and SSM companion cache reuse, not a forced
  global TurboQuant KV path.

The server settings/source guards prove topology-gated engine-selected
TurboQuant wiring and UI/runtime settings; they do not prove live TurboQuant KV
for LFM.

## API and UI Boundary

The live artifacts above use the real OpenAI-compatible `/v1/chat/completions`,
`/health`, `/v1/models`, and `/admin/cache-stats` surfaces through the no-sign
app. Source guards cover OpenResponses, OpenAI SSE reasoning deltas, Anthropic
thinking deltas, Ollama/OpenAI logging nil-default behavior, server panel
settings wiring, HTTP cancellation, tool-choice routing, and chat UI reasoning
routing.

No fresh visual UI screenshot was captured in this final pass, and no live
Ollama/Anthropic/OpenResponses endpoint E2E row was run here. Do not describe
those as live-proven; describe them as source-guarded unless a later artifact is
added.

## VL Boundary

No VL/media row was run in this final matrix. VL correctness remains outside
this PR's live proof unless a separate real-media live artifact is added.
