# Post-1310 Production Model Matrix

Date: 2026-05-31

Osaurus PR head containing this evidence:
`a59e5a4079aaddce18ec868342c2c3ebfe21e111`.

The live no-sign app proof was run from the same local PR worktree after the
final vMLX pin and LFM no-rail changes were applied, before those local changes
were committed as `a59e5a4079aaddce18ec868342c2c3ebfe21e111`.

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

Fresh bounded retry artifact:
`/tmp/osaurus-post1314-step37-jang2l-bounded-20260531-175434`

The row was started against the final app and loaded
`step-3.7-flash-jang_2l`, but it stayed in-flight for several minutes without
writing a turn response summary. The request and app were killed to clear the
machine. Therefore this final matrix does not claim Step 3.7 JANG_2L live
tool/cache readiness.

The fresh bounded retry reached runtime as well: `/health` reported
`current_model=step-3.7-flash-jang_2l`, `loaded=["step-3.7-flash-jang_2l"]`,
and `inflight={"step-3.7-flash-jang_2l":1}` while the app consumed CPU. The
strict harness timed out waiting for the first `/v1/chat/completions` response
after 300 seconds, before any turn response JSON was written. This is a current
Step decode/runtime latency or hang blocker, not a tool-parser pass.

Older Step 3.7 artifacts from earlier local work showed strict tool behavior and
L2 reuse but very poor no-sign Osaurus decode speed. Those older rows are not
used as final-head merge proof.

## LFM2.5 MXFP4 and MXFP8

Current final-head verdict: green for the same strict no-sign Osaurus app
multi-turn tool/cache scope as JANG_2L.

MXFP4 cold artifact:
`/tmp/osaurus-post1314-lfm-mxfp4-cold-20260531-175253/lfm2.5-8b-a1b-mxfp4_summary.json`

MXFP4 warm artifact:
`/tmp/osaurus-post1314-lfm-mxfp4-warm-20260531-175323/lfm2.5-8b-a1b-mxfp4_summary.json`

MXFP8 cold artifact:
`/tmp/osaurus-post1314-lfm-mxfp8-cold-20260531-175341/lfm2.5-8b-a1b-mxfp8_summary.json`

MXFP8 warm artifact:
`/tmp/osaurus-post1314-lfm-mxfp8-warm-20260531-175405/lfm2.5-8b-a1b-mxfp8_summary.json`

Confirmed for both MXFP4 and MXFP8:

- Turn 1 required tool call: exact `line_count` args `red\ngreen\nblue`.
- Turn 2 no-tool answer: visible coherent answer, no unexpected tool call, no
  protocol leak, no length-stop fake pass.
- Turn 3 required tool after assistant/tool history: exact `line_count` args
  `one\ntwo`.
- Topology: 24 layers, 6 KV layers, 18 Mamba/SSM companion layers,
  `requires_disk_backed_restore=true`, `requires_ssm_companion_state=true`,
  `companion=ssm`, `turbo_quant_kv_layer_count=0`.
- MXFP4 warm reuse proof: `block_disk_hits=1`, `ssm_companion_hits=1`, and
  `companion_hits=1`; visible answer speed was 123 tokens in 1.377s, about
  89.3 tok/s.
- MXFP8 warm reuse proof: `block_disk_hits=1`, `ssm_companion_hits=1`, and
  `companion_hits=1`; visible answer speed was 128 tokens in 2.299s, about
  55.7 tok/s.

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

## Expanded Family Boundary

An expanded no-sign app launch served additional local model ids when pointed at
`/tmp/osaurus-post1314-expanded-modelroot`: `qwen3.6-35b-a3b-jangtq-crack`,
`nemotron-omni-nano-jangtq-crack`, `ling-2.6-flash-jangtq2-crack`,
`gemma-4-26b-a4b-it-jang_4m-crack`, and `minimax-m2.7-small-jangtq`.
Those rows are not promoted by this PR evidence.

The Qwen35 strict harness attempt
`/tmp/osaurus-post1314-expanded-qwen35-cold-20260531-174411` did not reach model
decode. The app accepted the HTTP connection but `/health` continued to report
no loaded model and no in-flight request. A process sample at
`/tmp/osaurus-sample-qwen-stall.txt` showed both the model picker rebuild and
the chat request blocked in metadata/capability reads:
`VLMDetection.isVLM`, `ModelMediaCapabilities.from(directory:modelId:)`, and
`Data(contentsOf:)`/`_fcntl_overlay_open`. A single-model Qwen LaunchServices
retry reproduced the same metadata-read stall; sample:
`/tmp/osaurus-sample-qwen-single-stall.txt`.

Shell reads of the same Qwen and Nemotron `config.json` files from
`/Volumes/EricsLLMDrive` were instantaneous, so this is recorded as a current
no-sign app external-drive metadata access/capability detection blocker, not a
Qwen parser, reasoning, cache, or decode verdict. ZAYA was not found in the
local model search roots used for this pass.

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
