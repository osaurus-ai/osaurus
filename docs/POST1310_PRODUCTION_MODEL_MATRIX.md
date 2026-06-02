# Post-1310 Production Model Matrix

Date: 2026-06-01

Final updated-branch Osaurus PR head after GitHub "update branch" and the
runtime top-p projection source-guard repair:
`5f7c108ac055dd1b99d03cef7663a14763c7dbac`.

Final updated-branch no-sign app:
`build/DerivedData-post1314-final-5f7c108a/Build/Products/Release/osaurus.app`.

Final updated-branch live proof used `OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1`, a
fresh `OSAURUS_TEST_ROOT=/tmp/osaurus-post1314-final-5f7c108a-live-open-20260601-222454/state`,
and `OSU_MODELS_DIR=/tmp/osaurus-post1314-step-final-root/models`. The app was
launched through LaunchServices after setting those env vars with `launchctl`.
The proof lane did not invoke `security`, notarytool, Developer ID signing,
signing identities, or a password/keychain prompt. The app stayed healthy after
the final rows with no in-flight requests.

Final updated-branch served model ids:
`step-3.7-flash-jang_2l` and `step-3.7-flash-jang_k`.

Final updated-branch Step JANG_K parser/topology artifact:
`/tmp/osaurus-post1314-final-5f7c108a-jangk-20260601-222508/step-3.7-flash-jang_k_summary.json`.

Final updated-branch Step JANG_K restart/L2-hit artifact:
`/tmp/osaurus-post1314-final-5f7c108a-jangk-l2hit-20260601-222546/step-3.7-flash-jang_k_summary.json`.

Final updated-branch Step JANG_2L parser/topology artifact:
`/tmp/osaurus-post1314-final-5f7c108a-jang2l-20260601-222604/step-3.7-flash-jang_2l_summary.json`.

These updated-branch rows supersede the older `25f8111...` app proof directly
below. On the exact `5f7c108a...` app, Step JANG_K and Step JANG_2L both pass
the strict required/none/required multi-turn tool harness with exact
`line_count` arguments on turn 1 (`red\ngreen\nblue`) and turn 3 (`one\ntwo`),
visible no-tool follow-up answers, no protocol leaks, no incoherent loop, no
length-stop fake pass, and token/s recorded for visible generation. Both rows
report the expected Step mixed cache topology: 45 layers, 12 KV layers, 33
rotating KV layers, `requires_disk_backed_restore=true`,
`paged_incompatible=true`, and `turbo_quant_kv_layer_count=0`. The JANG_K
restart row proves actual disk L2 reuse with `block_disk_hits=1`,
`block_disk_misses=0`, and `block_disk_stores=5`.

Current local Osaurus PR head before the final vMLX repin commit:
`1bc3202c0ccc36f791d27ef7ce7943eba0b691b8`.

Current local vMLX pin after the final Step XML parser fix:
`25f8111552005fdc6ef12cd2c8298a782d4e2052`.

Final no-sign app built for the current pin:
`build/DerivedData-post1314-step-parser-25f8111/Build/Products/Release/osaurus.app`.

Final Step 3.7 live proof used `OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1`,
isolated `OSAURUS_TEST_ROOT=/tmp/osaurus-post1314-step-final-root/state-open`,
and `OSU_MODELS_DIR=/tmp/osaurus-post1314-step-final-root/models`. The app was
launched through LaunchServices with those env vars set by `launchctl`; no
`security`, notary, Developer ID signing, signing identity, or password/keychain
prompt was used. The app stayed healthy after the final rows.

Final Step JANG_K parser/cache artifact:
`/tmp/osaurus-post1314-25f8111-step-jangk-restart-l2-20260601-192211/step-3.7-flash-jang_k_summary.json`.

Final Step JANG_2L tool/topology artifact:
`/tmp/osaurus-post1314-25f8111-step-jang2l-final-20260601-191743/step-3.7-flash-jang_2l_summary.json`.

Final Step JANG_K parser-only cold artifact before restart/L2:
`/tmp/osaurus-post1314-25f8111-step-jangk-final-20260601-191716/step-3.7-flash-jang_k_summary.json`.

These final rows supersede the older `eb116ef...` Step proof boundary below:
Step JANG_K and Step JANG_2L both pass the strict required/none/required
multi-turn tool harness on the final app, with exact `line_count` arguments on
turn 1 and turn 3, visible no-tool follow-up, no protocol leak, no incoherent
loop, no length-stop fake pass, token/s recorded for the visible generation
turn, healthy `/health` after the row, 45-layer mixed topology with 12 KV layers
and 33 rotating KV layers, `requires_disk_backed_restore=true`,
paged-incompatible, and `turbo_quant_kv_layer_count=0`. The restart/L2 JANG_K
row additionally proves actual disk L2 restore with `block_disk_hits +1`,
`block_disk_misses 0`, and `block_disk_stores +5`.

The vMLX fix is narrow and parser-boundary-specific: Step emitted a native bare
XML function envelope beginning with `<function=line_count>` after tool history.
`StepToolCallParser` now buffers and parses that Step-native envelope without
adding sampler defaults, repetition penalties, close-token bias, synthetic
reasoning tags, or template coercion. Focused vMLX test
`Step37ParserDispatchTests/stepParserAcceptsBareXMLFunctionEnvelopeAfterHistory`
passed before the pin was updated.

Earlier Osaurus PR head after the Step proof-boundary refresh:
`9804bb474ad73cd107a493ccaba2e9b3f5c964c1`.

Earlier Osaurus PR head after Step proof-harness hardening:
`31911e2319b324250bca3f3660a75d2d182e55a9`.

Earlier Osaurus PR head after the ZAYA evidence refresh:
`dceaf9edf85ffe0d20a0b142b6dbe585b4874828`.

Osaurus PR head used for the Qwen/Nemotron proof before the later Ling,
MiniMax, Step, and ZAYA evidence refreshes:
`63f8ee52ef44eb2a988594d2065ffaf70a07024a`.

Live no-sign app proofs were run from this PR worktree as the matrix was built
up across several commits. Individual artifact paths below are the source of
truth for the exact live rows and the row-specific PR head where listed.

Previous local vMLX pin in Osaurus after the Step required-template refresh:
`eb116ef735d9445cfac30b6a3346ff162483122e`.

Previous fully pushed/CI-green PR head used `3043cc98d7c2a0fd9df34376e6b42beec5517516`.
Rows below keep their original artifact paths and proof boundaries; do not
reinterpret older live rows as fresh proof for the `eb116ef...` pin unless a
current artifact explicitly says so.

No-sign app used for live proof:
`/tmp/osaurus-post1314-nosign-3043cc98/Build/Products/Release/osaurus.app`

Previous no-sign app built for the `eb116ef...` refresh:
`build/DerivedData-post1314-step-template-eb116ef/Build/Products/Release/osaurus.app`

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

Final `25f8111...` Step refresh served these ids from the no-sign
keychain-free app root:

- `step-3.7-flash-jang_2l`
- `step-3.7-flash-jang_k`

`Step-3.7-Flash-JANG_K` is promoted by the final `25f8111...` refresh for this
strict Osaurus app lane. The earlier `eb116ef...` JANG_K timeout/leak boundary
is superseded by the final parser/cache artifact listed above.

## Source and Guard Coverage

Passed on the final vMLX pin:

- vMLX focused LFM fallback tests: `DeepseekV4ChatTemplateFallbackFocusedTests/lfm2`.
- vMLX focused LFM parser tests:
  `ToolTests/lfm2ProcessorAcceptsObservedFunctionlineRequiredToolOutput`,
  `ToolTests/lfm2ProcessorAcceptsObservedFunctionNameArgTagOutput`, and
  `ToolTests/lfm2ParserDoesNotCoercePlainCodeFenceIntoToolCall`.
- vMLX focused Step 3.7 source guard:
  `Step37ParserDispatchTests` passed on the pinned vMLX checkout. It
  covers Step parser aliases, Qwen-style reasoning aliases, multiline XML tool
  argument extraction, Step JANG capability routing, assistant-tail thinking
  fallback behavior, native XML required-tool fallback rendering, exact
  current-turn required-tool value repetition after history, Step3p7
  wrapper config decoding, mixed full/sliding cache topology, TurboQuant KV only
  for full-attention layers, JANGTQ per-layer group-size inheritance, and NVFP4
  attention side-tensor sanitization, and the final bare
  `<function=line_count>` XML envelope observed from Step JANG_K after tool
  history.
- Osaurus source tests:
  `RuntimePolicySourceTests/vmlxPinIncludesRuntimeHardening` passed on the
  `25f8111...` pin, earlier `RuntimePolicySourceTests` passed 75/75 on the
  `eb116ef...` pin, and
  `SwiftTransformersTokenizerLoaderTests/step37LocalTokenizerUsesRequiredToolFallbackAndClosesThinkingRail`
  passed on the same pin. Earlier LFM tokenizer/source guards remain covered by
  the previous proof rows.
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

PR head used for this Qwen endpoint artifact:
`43970ed1ffcc9cae01a07efa3897a2b652dcf61c`.

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

Historical final-head verdict before the `eb116ef...` refresh: green for strict no-sign Osaurus app
multi-turn required/none/required tool behavior, no visible protocol leakage,
no incoherent loop, no length-stop fake pass on the accepted rows, Step mixed
KV/rotating topology, disk-backed restore requirement, and warm disk-L2 reuse.

Current `31911e23` / vMLX `eb116ef...` refresh boundary: source, tokenizer,
readiness, and no-forced-behavior checks passed. A fresh no-sign app
strict Step JANG_2L row ran while another Step CRACK process was consuming about
74 GB RSS and did not finish the full three-turn harness, so there is no single
current-head `*_summary.json` green row. The partial strict artifact
`/tmp/osaurus-post1314-eda7ac94-step-jang2l-20260601-132614` did complete turn 1
and turn 2: turn 1 produced exact structured `line_count` args
`red\ngreen\nblue`, `finish_reason=tool_calls`, no visible prose, and zero
completion tokens; turn 2 answered visibly with `Three lines were counted.` and
no tool call or protocol leak. Because turn 3 was missing from that harness, a
focused no-sign app direct turn-3 probe
`/tmp/osaurus-post1314-eda7ac94-step-jang2l-turn3-direct-20260601-134409`
replayed the same assistant/tool history and passed with exact structured
`line_count` args `one\ntwo`, `finish=tool_calls`, no visible prose, and zero
completion tokens in 3.83s. `/health` after the direct row was healthy with no
in-flight request. `/admin/cache-stats` showed 45 layers, 12 KV layers,
33 rotating KV layers, `requires_disk_backed_restore=true`, paged-incompatible,
`turbo_quant_kv_layer_count=0`, and `disk_l2_stores=1`; this current refresh
does not claim a fresh warm disk-L2 hit.

The `31911e23` refresh also hardens the live proof harness itself: request JSON
is now written before each network call, and harness exceptions/timeouts produce
a per-model failed summary instead of an ambiguous partial directory. The
focused source test
`MLXBatchAdapterTests/additionalContext_threadsRequiredToolChoiceToLocalTemplates`
now explicitly covers `Step-3.7-Flash-JANG_2L`, proving that required tool
choice reaches vMLX and disables thinking for this model id as well as the
Step JANG_K spelling. A fresh current-head no-sign app attempt at
`/tmp/osaurus-post1314-31911e23-step-jang2l-full-20260601-140154` was stopped
after turn 1 stayed in flight under the same external 74 GB Step CRACK-v8 job;
it has the pre-call request/health/cache artifacts but no response and is not a
model pass or fail.

The `9804bb47` refresh reran the cheap production source guards and another
fresh no-sign app attempt without touching signing/keychain paths:
`assert-osaurus-vmlx-pr-readiness.sh`,
`assert-osaurus-no-forced-behavior-pr.sh`, and
`assert-tool-choice-required-routing.sh` passed on the `eb116ef...` pin. The
no-sign app at
`build/DerivedData-post1314-step-template-eb116ef/Build/Products/Release/osaurus.app`
was launched with `OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1`, a fresh
`OSAURUS_TEST_ROOT`, and a model root containing only
`Step-3.7-Flash-JANG_2L`; `/v1/models` served `step-3.7-flash-jang_2l`.
Artifact `/tmp/osaurus-post1314-9804bb47-step-jang2l-full-20260601-140957`
was stopped after more than five minutes with `/health` still healthy, one
in-flight request, no turn-1 response artifact, and the external
`Step-3.7-Flash-JANG_K-CRACK-v8` job still consuming about 74 GB RSS. The
artifact now contains an explicit failed `SUMMARY.json`. This is recorded as a
resource-blocked current-head attempt, not a model pass and not a model
coherency/parser failure.

Additional isolation artifact:
`/tmp/osaurus-post1314-920fa406-step-probe-20260601-141746`. The same no-sign
app and one-model root served `step-3.7-flash-jang_2l`; a tiny plain chat
request (`Reply with ok.`, `max_tokens=8`, no tools) also stayed in flight with
an empty response file under the active external Step CRACK-v8 job. Sample
`/tmp/osaurus-post1314-920fa406-step-plain-sample.txt` showed the request inside
`TokenIterator.next()` / `mlx::core::scheduler::Scheduler::wait_for_one()`.
That isolates the current live blocker below chat/autodetect/tool-parser
wiring: plain decode cannot complete on this machine while the external Step
job owns the memory/GPU lane.

Final fix boundary:

- Osaurus disables the single-slot compiled batch-decode trace for Step 3.7 in
  `MLXBatchAdapter.shouldEnableCompiledBatchDecode`. This is a narrow runtime
  route fix, not a prompt, parser, sampler, or repetition-penalty workaround.
- Focused test:
  `MLXBatchAdapterTests/compiledBatchDecodeDisabledForKnownUnsafeSoloModels`
  passed with Step JANG_2L and Step JANGTQ_K pinned as explicit exceptions.
- Source guard:
  `assert-osaurus-no-forced-behavior-pr.sh` passed after the patch, including
  the no hidden sampler/default, no forced reasoning, no parser repair, and no
  decode close/open-token bias checks.

No-sign app used for the final Step proof:
`build/DerivedData-step37-uncompiled-fix-b1f8b8f1/Build/Products/Release/osaurus.app`

Keychain/signing boundary for the final Step proof:

- Built with `scripts/live-proof/build-keychain-free-osaurus.sh`.
- Build settings included `CODE_SIGNING_ALLOWED=NO`,
  `CODE_SIGNING_REQUIRED=NO`, `CODE_SIGN_IDENTITY=`, and
  `AD_HOC_CODE_SIGNING_ALLOWED=NO`.
- Final seal was local ad-hoc only.
- Launched with `OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1`, a fresh
  `OSAURUS_TEST_ROOT`, and `OSU_MODELS_DIR` pointing at a root containing only
  `Step-3.7-Flash-JANG_2L`.
- `/v1/models` served the exact id `step-3.7-flash-jang_2l`.

Final smoke artifact:
`/tmp/osaurus-post1314-step37-compiled-off-20260601-012207`

The final smoke proved the old resident-speed blocker was removed on the patched
app path: cold two-token request returned `\nok` in 19.56s including load, and
the immediately following resident two-token request returned `\nok` in 0.148s.

Final strict cold/tool/topology artifact:
`/tmp/osaurus-post1314-step37-compiled-off-tool-cache-20260601-012335/step-3.7-flash-jang_2l_summary.json`

Final warm disk-L2 artifact:
`/tmp/osaurus-post1314-step37-compiled-off-warm-cache-20260601-012404/step-3.7-flash-jang_2l_summary.json`

Confirmed in both accepted strict rows:

- Turn 1 required tool call: exact `line_count` args
  `red\ngreen\nblue`, no visible content, no protocol leak.
- Turn 2 no-tool answer: visible coherent answer
  `Three lines were counted.`, no tool call, no protocol leak,
  `finish=stop`, no length-stop fake pass.
- Turn 3 required tool after assistant/tool history: exact `line_count` args
  `one\ntwo`, no visible content, no protocol leak.
- Warm visible answer speed: 6 completion tokens in 0.510s, about
  11.77 tok/s.
- Topology: 45 layers, 12 KV layers, 33 rotating KV layers,
  `requires_disk_backed_restore=true`, paged-incompatible, and
  `turbo_quant_kv_layer_count=0`.
- Warm reuse proof: `block_disk_hits=1`, no new block-disk misses, and
  `block_disk_stores=5`.
- App health after rows: healthy, no in-flight request, requested model
  resident and current.

Boundary: the older final proof promotes `Step-3.7-Flash-JANG_2L` only for that
pre-`eb116ef...` app artifact. It does not promote the current `eb116ef...`
refresh live row, `Step-3.7-Flash-JANG_K`, or `Step-3.7-Flash-JANGTQ_K`.

Superseded failed/partial artifacts are retained below for traceability.

Attempted artifact directory:
`/tmp/osaurus-post1314-step37-jang2l-3043cc98-cold-20260531-170148`

Fresh bounded retry artifact:
`/tmp/osaurus-post1314-step37-jang2l-bounded-20260531-175434`

Fresh LaunchServices no-sign retry artifact:
`/tmp/osaurus-post1314-step37-open-20260531-200006`

Fresh tiny no-tool sanity artifact:
`/tmp/osaurus-post1314-step37-simple-20260531-202306`

Fresh resident-speed split artifact:
`/tmp/osaurus-post1314-step37-resident-20260531-204840`

Step JANGTQ_K bounded artifact:
`/tmp/osaurus-post1314-step37-jangtqk-resident-20260531-205347`

The superseded pre-fix row was started against the final app and loaded
`step-3.7-flash-jang_2l`, but it stayed in-flight for several minutes without
writing a turn response summary. The request and app were killed to clear the
machine. This is retained as the observed failure before the compiled
batch-decode exclusion, not as the current verdict.

The superseded bounded retry reached runtime as well: `/health` reported
`current_model=step-3.7-flash-jang_2l`, `loaded=["step-3.7-flash-jang_2l"]`,
and `inflight={"step-3.7-flash-jang_2l":1}` while the app consumed CPU. The
strict harness timed out waiting for the first `/v1/chat/completions` response
after 300 seconds, before any turn response JSON was written. This is a pre-fix
Step decode/runtime latency or hang artifact, not a tool-parser pass.

The superseded LaunchServices retry used the no-sign app with `OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1`,
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
`TokenIterator.next`, so that artifact isolated decode/runtime progress rather
than model discovery, source parser dispatch, or signing/keychain.

A superseded tiny no-tool sanity request against the same no-sign app path did complete:
`Reply with exactly: ok` returned visible content `ok`, `finish_reason=stop`,
and healthy `/health` with no in-flight request afterward. However, it took
118.09 seconds to emit 2 completion tokens from a 5-token prompt. This proves the
pre-fix Step 3.7 JANG_2L path was not completely dead, but also confirmed
unacceptable live decode/runtime speed before the compiled batch-decode
exclusion. It was not a prompt/tool parser leak and was not solved by extending
tool-harness timeouts.

The superseded resident-speed split removed the ambiguity that this was only a
cold-load artifact. Using the same no-sign app, `OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1`,
a fresh `OSAURUS_TEST_ROOT`, and a model root containing only
`Step-3.7-Flash-JANG_2L`, two consecutive two-token requests were sent through
`/v1/chat/completions`. The cold request returned `\nok` in 92.86s with
`finish_reason=length`; the immediately following resident request returned the
same two visible tokens in 70.54s with `finish_reason=length`. `/health` after
the row was healthy with no in-flight request, and `/admin/cache-stats` showed
`disk_l2_hits=1`, `disk_l2_misses=2`, `disk_l2_stores=4`, 45 layers, 12 KV
layers, 33 rotating KV layers, `requires_disk_backed_restore=true`, and
`turbo_quant_kv_layer_count=0`. This proves the problem is not model discovery,
server endpoint routing, keychain/signing, or the first cold load alone. It is
superseded by the June 1 final smoke, where resident two-token generation took
0.148s.

`Step-3.7-Flash-JANG_K` is still not claimed. Current local non-empty CRACK
bundles exist at `/Users/eric/models/dealign.ai/Step-3.7-Flash-JANG_K-CRACK`
and `/Users/eric/models/dealign.ai/Step-3.7-Flash-JANG_K-CRACK-v5`, and the
current no-sign app served `step-3.7-flash-jang_k-crack-v5`. A direct first-turn
required-tool probe at
`/tmp/osaurus-post1314-step37-jangk-crackv5-eb116ef-direct1-20260601-125242`
timed out after 180s, and the strict harness attempt
`/tmp/osaurus-post1314-step37-jangk-crackv5-eb116ef-cold-20260601-124101`
was stopped after it ran past the useful proof window with one in-flight request.
This is blocked current live proof, not a green row.

`Step-3.7-Flash-JANGTQ_K` exists locally at
`/Volumes/EricsLLMDrive/jangq-ai/Step-3.7-Flash-JANGTQ_K` and has the expected
JANGTQ_K metadata (`profile=JANGTQ_K`, 55 shards, 126 routed TQ triplets,
mixed routed expert bits gate/up/down = 2/2/4). A bounded no-sign Osaurus app
retry served `step-3.7-flash-jangtq_k`, but the first two-token chat request
timed out at 300s and the model was not resident afterward. This row is also
not promoted by this final Step JANG_2L repair proof. Prior JANG-side provenance says
JANGTQ_K is the coherent Step target, but it still needs a current Osaurus
load/runtime fix and fresh no-sign app proof before this matrix can claim it.

Older Step 3.7 artifacts from earlier local work showed strict tool behavior and
L2 reuse but very poor no-sign Osaurus decode speed. They are superseded by the
compiled-batch-decode exclusion proof above.

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
- Step JANG_2L final rows report `turbo_quant_kv_layer_count=0`.
- LFM is hybrid/paged-incompatible in these rows, so the proven behavior is
  native KV plus disk-backed restore and SSM companion cache reuse, not a forced
  global TurboQuant KV path.
- Step JANG_2L is a mixed KV/rotating topology in these rows, so the proven
  behavior is native KV/rotating cache plus disk-backed restore and disk-L2
  reuse, not a claim that Step rotating layers are using TurboQuant KV.

The server settings/source guards prove topology-gated engine-selected
TurboQuant wiring and UI/runtime settings. On the current `eb116ef...` Osaurus
patch, Step 3.7 is deliberately native/fp16 by default because its mixed
full-attention plus rotating/SWA topology has not produced a current warm
tool-history TurboQuant-KV stability proof. This is conservative runtime policy,
not a hidden sampler or prompt workaround.

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

Local copy used for proof:
`/Users/eric/.mlxstudio/models/JANGQ-AI/MiniMax-M2.7-Small-JANGTQ`

Superseded blocked attempt artifact:
`/tmp/osaurus-post1314-minimax-small-cold-20260531-185719`

Current proof artifacts:

- Native-KV cold smoke:
  `/tmp/osaurus-post1314-minimax-native-ls-probe-20260601-024219/native-smoke.json`
- Native-KV strict tool/topology:
  `/tmp/osaurus-post1314-minimax-native-tool-cache-20260601-024325/minimax-m2.7-small-jangtq_summary.json`
- Native-KV repeat with disk-L2 requirement intentionally failed only
  `cache_evidence_disk_l2_hits`:
  `/tmp/osaurus-post1314-minimax-native-warm-disk-20260601-024352/minimax-m2.7-small-jangtq_summary.json`
- Engine-selected/default strict tool/topology:
  `/tmp/osaurus-post1314-minimax-engine-selected-tool-cache-20260601-024500/minimax-m2.7-small-jangtq_summary.json`

Verdict: promoted for the current bounded MiniMax no-sign app path.

The current no-sign app build
`build/DerivedData-minimax-policy-probe-497a52da/Build/Products/Release/osaurus.app`
served `minimax-m2.7-small-jangtq` from a fresh keychain-free test root. A
native-KV cold smoke returned exact visible `ok` in 21.68 seconds including
load. The native-KV strict required/none/required harness then passed exact
`line_count` args for `red\ngreen\nblue` and `one\ntwo`, visible turn 2 answer,
no protocol leakage, no visible content on tool-call turns, no length-stop fake
pass, and healthy `/health` after the row. That native row reported 62 full KV
layers, no rotating/SSM/ZAYA companion layers, paged/prefix hits, and
`turbo_quant_kv_layer_count=0`.

The default `engineSelected` row also passed the strict harness with exact tool
args, visible turn 2 answer, no leak/loop/length fake, and healthy state. It
recorded `block_disk_hits +1`, `turbo_quant_compressions=3`, 62 full KV layers,
and `is_paged_incompatible=true` for the selected path. This supersedes the
older blocked MiniMax attempt, which was a stale/contended app run that stayed
inside `maybeQuantizeCacheForStep` for more than ten minutes without a response.

Boundary: the native repeat row proved prefix/paged reuse but not disk-L2 reuse
because `block_disk_hits` stayed 0 while the model remained resident. The
engine-selected/default row is the MiniMax disk-L2/TurboQuant evidence in this
matrix. MiniMax VL/audio is not claimed.

### ZAYA1 Text And VL JANGTQ4

Local copies used for proof:

- `/Users/eric/models/JANGQ/ZAYA1-8B-JANGTQ4`
- `/Users/eric/models/JANGQ/ZAYA1-VL-8B-JANGTQ4`

Current proof artifacts:

- Text cold strict tool/topology:
  `/tmp/osaurus-post1314-zaya-text-jangtq4-current-20260601-032237/zaya1-8b-jangtq4_summary.json`
- Text warm strict tool/disk-L2/topology:
  `/tmp/osaurus-post1314-zaya-text-jangtq4-warmdisk-20260601-032427/zaya1-8b-jangtq4_summary.json`
- VL red-image repeat/cache:
  `/tmp/osaurus-post1314-zaya-vl-jangtq4-red-current-20260601-032534/SUMMARY.json`

Verdict: promoted for the current bounded ZAYA no-sign app path.

The no-sign app build
`build/DerivedData-zaya-proof-6aa8aa17/Build/Products/Release/osaurus.app`
served `zaya1-8b-jangtq4` and `zaya1-vl-8b-jangtq4` from a fresh
keychain-free test root. The text cold row passed exact
required/none/required multi-turn tool behavior with `line_count` args
`red\ngreen\nblue` and `one\ntwo`, visible turn 2 answer, no protocol leakage,
no visible content on tool-call turns, no length-stop fake pass, and healthy
`/health` after the row.

The text warm row restarted the same app against the same test root and cache
directory, then required cache topology, disk-backed restore, disk-L2 reuse, and
ZAYA CCA companion topology. It passed the same exact tool checks and recorded
`block_disk_hits +1`. The row reported 80 layers, 40 KV layers, 40 ZAYA CCA
layers, `companion=zaya-cca`, `requires_disk_backed_restore=true`,
`requires_ssm_companion_state=true`, paged-incompatible, and
`turbo_quant_kv_layer_count=0`.

The VL row used a real generated 64x64 red PNG data URL through
`/v1/chat/completions` with `zaya1-vl-8b-jangtq4`. First and repeat responses
were `Red`, both stopped normally, prefix hash stayed
`6e340b9cffb37a989ca544e6bb780a2c`, repeat `disk_l2_hits=1`, no protocol marker
leaked, and the app was healthy with no in-flight request after the row. The VL
topology reported 40 ZAYA CCA layers, `companion=zaya-cca`, disk-backed restore,
and no TurboQuant KV layers.

Boundary: ZAYA CCA companion presence/topology is proven, but CCA companion-hit
reuse is not promoted here because both the text warm and VL rows recorded CCA
companion misses rather than hits. ZAYA MXFP4 siblings were discovered locally
but were not run in this PR evidence.

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

Gemma 4 26B and ZAYA1-VL JANGTQ4 each have one real-media red-image VL/cache
artifact listed above. No other VL/video/audio family is live-proven in this
final matrix. Nemotron Omni is proven here only on the text/tool path, not with
image/audio media.
