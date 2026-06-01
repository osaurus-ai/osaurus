# Post-1310 Production Model Matrix

Date: 2026-05-31

Osaurus PR head used for the Qwen/Nemotron proof before this final Ling doc
refresh:
`63f8ee52ef44eb2a988594d2065ffaf70a07024a`.

The live no-sign app proof was run from the same local PR worktree after the
final vMLX pin and LFM no-rail changes were applied, before those local changes
were pushed to the PR branch. Individual artifact paths below are the source of
truth for the exact live rows.

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
- vMLX focused Step 3.7 source guard:
  `Step37ParserDispatchTests` passed 11/11 on the pinned vMLX checkout. It
  covers Step parser aliases, Qwen-style reasoning aliases, multiline XML tool
  argument extraction, Step JANG capability routing, assistant-tail thinking
  fallback behavior, native XML required-tool fallback rendering, Step3p7
  wrapper config decoding, mixed full/sliding cache topology, TurboQuant KV only
  for full-attention layers, JANGTQ per-layer group-size inheritance, and NVFP4
  attention side-tensor sanitization.
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

## Live Endpoint Smoke

Current PR head: `43970ed1ffcc9cae01a07efa3897a2b652dcf61c`.

Qwen endpoint artifact:
`/tmp/osaurus-post1314-qwen-endpoint-smoke-20260531-193244/endpoint-smoke/SUMMARY.json`

The Qwen endpoint smoke used the same no-sign app build with
`OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1`, a fresh `OSAURUS_TEST_ROOT`, and local
model root `/tmp/osaurus-post1314-qwen-endpoint-smoke-20260531-193244/models`.
Served model id: `qwen3.6-35b-a3b-jangtq-crack`.

Passed live endpoints:

- OpenAI-compatible `/v1/chat/completions`, non-streaming.
- OpenAI-compatible `/v1/chat/completions`, SSE streaming.
- OpenResponses `/v1/responses`, non-streaming.
- OpenResponses `/v1/responses`, SSE streaming.
- Anthropic Messages `/v1/messages`, non-streaming.
- Ollama `/api/chat`, non-streaming.
- Ollama `/api/generate`, non-streaming.

Every passed endpoint returned visible text, had no protocol marker leakage, did
not length-stop into a fake pass, and did not loop. App health after the row was
healthy with no in-flight request. Cache telemetry after the endpoint row showed
`disk_l2_hits=2`, `ssm_companion_hits=2`, and `companion_hits=2` for the Qwen
hybrid topology: 40 layers, 10 KV layers, 30 Mamba/SSM companion layers,
`requires_disk_backed_restore=true`, `requires_ssm_companion_state=true`, and
`turbo_quant_kv_layer_count=0`.

LFM endpoint boundary artifact:
`/tmp/osaurus-post1314-endpoint-smoke-ls-20260531-192859/endpoint-smoke-256/SUMMARY.json`

The same endpoint smoke against `lfm2.5-8b-a1b-jang_2l` is not promoted as a
full endpoint-visible-chat proof: OpenAI streaming, OpenResponses
non-streaming/streaming, and Ollama chat produced visible text without protocol
leaks, but OpenAI non-streaming and Ollama generate spent the output budget on
reasoning/empty visible output. This is recorded as a model/rail behavior
boundary, not hidden or counted as a pass. LFM remains promoted by the stricter
multi-turn tool/cache rows below, where required tool turns close the reasoning
rail and follow-up tool-result turns produce visible answers.

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

Fresh LaunchServices no-sign retry artifact:
`/tmp/osaurus-post1314-step37-open-20260531-200006`

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

The LaunchServices retry used the no-sign app with `OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1`,
a fresh `OSAURUS_TEST_ROOT`, and a model root containing only
`Step-3.7-Flash-JANG_2L`. `/v1/models` served `step-3.7-flash-jang_2l`; the
strict required/none/required harness then timed out on turn 1 after 420
seconds, before any response summary was written. `/health` at timeout remained
healthy with `current_model=step-3.7-flash-jang_2l` and
`inflight={"step-3.7-flash-jang_2l":1}`. `/admin/cache-stats` reported the live
Step topology as 45 layers, 12 KV layers, 33 rotating KV layers,
`requires_disk_backed_restore=true`, `is_paged_incompatible=true`, and
`turbo_quant_kv_layer_count=0`; cache counters stayed zero because generation
never completed. The captured process sample points at `generateLoopTask` /
`TokenIterator.next`, so the live blocker is decode/runtime progress, not model
discovery, source parser dispatch, or a signing/keychain issue.

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
The external-drive model-root path itself is not promoted by this PR evidence.

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
no-sign app external-drive metadata access/capability detection blocker.

Copying the Qwen and Nemotron bundles into `/Users/eric/.mlxstudio/models`
removed that metadata access blocker and let the same no-sign app reach real
runtime/decode. Those local-storage rows are promoted below.

### Qwen3.6 35B A3B JANGTQ

Local copy used for proof:
`/Users/eric/.mlxstudio/models/dealignai/Qwen3.6-35B-A3B-JANGTQ-CRACK`

Cold artifact:
`/tmp/osaurus-post1314-qwen35-local-cold-20260531-181616/qwen3.6-35b-a3b-jangtq-crack_summary.json`

Warm artifact:
`/tmp/osaurus-post1314-qwen35-local-warm-20260531-181632/qwen3.6-35b-a3b-jangtq-crack_summary.json`

Verdict: green for strict no-sign Osaurus app multi-turn tool/cache scope.

- Turn 1 required tool call: exact `line_count` args `red\ngreen\nblue`.
- Turn 2 no-tool answer: visible coherent answer, no unexpected tool call, no
  protocol leak, no length-stop fake pass.
- Turn 3 required tool after assistant/tool history: exact `line_count` args
  `one\ntwo`.
- Topology: 40 layers, 10 KV layers, 30 Mamba/SSM companion layers,
  `requires_disk_backed_restore=true`, `requires_ssm_companion_state=true`,
  `companion=ssm`, `turbo_quant_kv_layer_count=0`.
- Warm reuse proof: `block_disk_hits=1`, `ssm_companion_hits=1`, and
  `companion_hits=1`; visible answer speed was 9 tokens in 0.741s, about
  12.1 tok/s.

### Nemotron Omni Nano JANGTQ

Local copy used for proof:
`/Users/eric/.mlxstudio/models/dealignai/Nemotron-Omni-Nano-JANGTQ-CRACK`

Cold artifact:
`/tmp/osaurus-post1314-nemo-local-cold-20260531-181738/nemotron-omni-nano-jangtq-crack_summary.json`

Warm artifact:
`/tmp/osaurus-post1314-nemo-local-warm-20260531-181754/nemotron-omni-nano-jangtq-crack_summary.json`

Verdict: green for strict no-sign Osaurus app multi-turn tool/cache scope.

- Turn 1 required tool call: exact `line_count` args `red\ngreen\nblue`.
- Turn 2 no-tool answer: visible coherent answer, no unexpected tool call, no
  protocol leak, no assistant-header loop, no length-stop fake pass.
- Turn 3 required tool after assistant/tool history: exact `line_count` args
  `one\ntwo`.
- Topology: 29 layers, 6 KV layers, 23 Mamba/SSM companion layers,
  `requires_disk_backed_restore=true`, `requires_ssm_companion_state=true`,
  `companion=ssm`, `turbo_quant_kv_layer_count=0`.
- Warm reuse proof: `block_disk_hits=1`, `ssm_companion_hits=1`, and
  `companion_hits=1`; visible answer speed was 6 tokens in 0.391s, about
  15.4 tok/s.

### Ling 2.6 Flash JANGTQ2

Local copy used for proof:
`/Users/eric/.mlxstudio/models/dealignai/Ling-2.6-flash-JANGTQ2-CRACK`

Cold artifact:
`/tmp/osaurus-post1314-ling-local-cold-20260531-183358/ling-2.6-flash-jangtq2-crack_summary.json`

Warm artifact:
`/tmp/osaurus-post1314-ling-local-warm-20260531-183610/ling-2.6-flash-jangtq2-crack_summary.json`

Verdict: green for strict no-sign Osaurus app multi-turn tool/cache scope.

- Turn 1 required tool call: exact `line_count` args `red\ngreen\nblue`.
- Turn 2 no-tool answer: visible coherent answer, no unexpected tool call, no
  protocol leak, no length-stop fake pass.
- Turn 3 required tool after assistant/tool history: exact `line_count` args
  `one\ntwo`.
- Topology: 32 layers, 4 KV layers, 28 arrays/SSM companion layers,
  `requires_disk_backed_restore=true`, `requires_ssm_companion_state=true`,
  `companion=ssm`, `turbo_quant_kv_layer_count=0`.
- Warm reuse proof: `block_disk_hits=1`, `ssm_companion_hits=1`, and
  `companion_hits=1`; visible answer speed was 10 tokens in 1.171s, about
  8.5 tok/s.

### Gemma 4 26B A4B it JANG_4M

Local copy used for proof:
`/Users/eric/.mlxstudio/models/dealignai/Gemma-4-26B-A4B-it-JANG_4M-CRACK`

Cold text/tool artifact:
`/tmp/osaurus-post1314-gemma26-local-cold-20260531-185325/gemma-4-26b-a4b-it-jang_4m-crack_summary.json`

Warm disk-hit text/tool artifact:
`/tmp/osaurus-post1314-gemma26-local-warm-hit-20260531-185438/gemma-4-26b-a4b-it-jang_4m-crack_summary.json`

Real-media VL artifact:
`/tmp/osaurus-post1314-gemma26-vl-red-20260531-185459/SUMMARY.json`

Verdict: green for strict no-sign Osaurus app text/tool/cache scope and for a
real single-image VL/cache row. One earlier warm text/tool rerun is recorded as
flaky below and is not hidden.

- Turn 1 required tool call: exact `line_count` args `red\ngreen\nblue`.
- Turn 2 no-tool answer: visible coherent answer, no unexpected tool call, no
  protocol leak, no length-stop fake pass.
- Turn 3 required tool after assistant/tool history: exact `line_count` args
  `one\ntwo`.
- Topology: 30 layers, 5 full KV layers, 25 rotating/sliding KV layers,
  `requires_disk_backed_restore=true`, `requires_ssm_companion_state=false`,
  `turbo_quant_kv_layer_count=0`.
- Warm text/tool reuse proof: `block_disk_hits=1`; visible answer speed was
  7 tokens in 0.506s, about 13.8 tok/s.
- VL proof used a generated 64x64 red PNG data URL through
  `/v1/chat/completions`. First and repeat responses were `Red`, both stopped
  normally, prefix hash stayed `6e340b9cffb37a989ca544e6bb780a2c`, repeat
  `disk_l2_hits=1`, no protocol marker leaked, and the app was healthy with no
  in-flight request after the row.
- VL token rates: first response 1 token in 3.700s, repeat response 1 token in
  1.000s.

Rejected Gemma warm artifact:
`/tmp/osaurus-post1314-gemma26-local-warm-20260531-185343/gemma-4-26b-a4b-it-jang_4m-crack_summary.json`

That row failed turn 1 with `finish_reason=stop`, no structured tool call, no
disk L2 hit, and `reasoning_content="thought<tool_call|>"`. A subsequent warm
repeat and the strict warm-hit row both passed exact tool behavior and disk L2
reuse, so Gemma is promoted for the accepted rows, but the flake remains
recorded for future repeat-depth work.

### MiniMax M2.7 Small JANGTQ

Local copy used for attempted proof:
`/Users/eric/.mlxstudio/models/jangq-ai/MiniMax-M2.7-Small-JANGTQ`

Attempt artifact:
`/tmp/osaurus-post1314-minimax-small-cold-20260531-185719`

Verdict: blocked for live no-sign Osaurus app readiness in this matrix.

The no-sign app served `minimax-m2.7-small-jangtq` and reached runtime. During
the strict required-tool harness, `/health` reported
`current_model=minimax-m2.7-small-jangtq`, `loaded=["minimax-m2.7-small-jangtq"]`,
and `inflight={"minimax-m2.7-small-jangtq":1}`. `/admin/cache-stats` reported
62 KV layers and no rotating/SSM/ZAYA companion layers. The row then remained
inside the MLX generation path for more than ten minutes without writing the
first response JSON. The sampled stack in
`sample-minimax-live.txt` shows `generateLoopTask`, `TokenIterator.next`,
`TokenIterator.step`, `maybeQuantizeCacheForStep`, and MLX/Metal evaluation.

The row was stopped deliberately to avoid wasting the machine on a non-usable
decode/performance path. This is not a parser pass and not a cache proof. The
fact that the topology is full KV also means the original command's
`requires_disk_backed_restore` expectation was not the right MiniMax cache gate;
a future MiniMax retry should use the correct full-KV cache/TurboQuant
expectation and a bounded first-token/decode-speed gate.

ZAYA was not found in the local model search roots used for this pass.

## API and UI Boundary

The live artifacts above use the real OpenAI-compatible `/v1/chat/completions`,
`/health`, `/v1/models`, and `/admin/cache-stats` surfaces through the no-sign
app. The Qwen endpoint smoke above additionally proves live
OpenAI-compatible chat, OpenResponses, Anthropic Messages, Ollama chat, and
Ollama generate behavior through the no-sign app on the current PR head. Source
guards cover OpenAI SSE reasoning deltas, Anthropic thinking deltas,
Ollama/OpenAI logging nil-default behavior, server panel settings wiring, HTTP
cancellation, tool-choice routing, and chat UI reasoning routing.

No fresh visual UI screenshot was captured in this final pass. Do not describe
non-Qwen endpoint behavior as live-proven unless a later artifact is added; the
LFM endpoint smoke is intentionally recorded above as a mixed/boundary row.

## VL Boundary

Gemma 4 26B has one real-media red-image VL/cache artifact listed above. No
other VL/video/audio family is live-proven in this final matrix. Nemotron Omni
is proven here only on the text/tool path, not with image/audio media.
