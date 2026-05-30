# vmlx-swift Osaurus Live Matrix - 2026-05-18

This is the Osaurus-side checklist for switching local inference to the
consolidated `vmlx-swift` package. It is deliberately stricter than a compile
or package pin. A row is not production-clear until the same model path has
real UI and API evidence, multi-turn coherency, cache proof, timing, memory,
and parser-leak checks.

This document is also the place to record rows that are not clear yet. Do not turn red rows into hidden sampler defaults, fake repetition penalties, forced reasoning close tokens, or app-side parser repairs.

Current completion status is tracked in the PR coordination channel, not in
repo-local live-gate artifacts. The user's requested VL/cache/UI/API/parser/
defaults/carryover proof still requires real Osaurus app/API evidence before a
row is production-clear.

## 2026-05-30 LFM2.5 JANG_2L final required-tool and warm cache pass

- Osaurus PR head at check: `ccc57314f928801ded7d7fe6f0affcb758ee6432`.
- vMLX main / Osaurus pin: `84c8bb653a50cd48b4af7f5cdce04d3f16e6ed95`.
- No-sign app path: `build/DerivedData-pr1268-lfm25-final-nosign-ccc57314/Build/Products/Release/osaurus.app`.
- Launch boundary: app was launched keychain-free with `OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1`, `OSAURUS_TEST_ROOT=/tmp/osaurus-pr1268-ccc57314-lfm25-final-ui-root`, and `OSU_MODELS_DIR=/Users/eric/.mlxstudio/models`.
- Cold artifact: `/tmp/osaurus-pr1268-ccc57314-lfm25-final-cold-20260530-010521`.
- Warm artifact: `/tmp/osaurus-pr1268-ccc57314-lfm25-final-warm-20260530-010538`.
- Model: `lfm2.5-8b-a1b-jang_2l`.
- Result: cold and warm strict three-turn required/none/required rows passed. Turn 1 produced exact structured `line_count` args `red\ngreen\nblue`; turn 2 produced a visible answer and no tool call; turn 3 produced exact structured `line_count` args `one\ntwo`. Tool-call turns had no visible content, no protocol marker leaked, no visible `<think>` block leaked, no incoherent loop occurred, no length-stop fake pass occurred, and `/health` stayed healthy with no in-flight request after each row.
- Topology/cache result: 24 layers, 6 KV layers, 18 Mamba/SSM companion layers, `companion=ssm`, disk-backed restore required, SSM companion state required, paged-cache incompatible, block disk L2 enabled, and TurboQuant KV layer count 0. Cold proved topology and disk-backed restore with `disk_l2_misses 2` and `disk_l2_stores 4`. Warm proved actual reuse with `disk_l2_hits +1`, `ssm_companion_hits +1`, and `companion_hits +1`.
- Token/s: cold visible follow-up emitted 287 completion tokens at 249.27 tok/s; warm visible follow-up emitted 126 completion tokens at 228.25 tok/s. OpenAI-compatible structured tool-call turns emitted zero completion tokens.
- Source/guard boundary: vMLX focused tests passed for the LFM content-mode closed-thinking parser, LFM2 escaped required-tool fallback, and LFM2 parser JSON shape before the Osaurus repin. Osaurus `RuntimePolicySourceTests/vmlxPinIncludesRuntimeHardening`, `SwiftTransformersTokenizerLoaderTests/lfm2LocalTokenizerUsesStrictRequiredToolFallback`, `assert-tool-choice-required-routing.sh`, `assert-server-settings-runtime-wiring.sh`, `assert-keychain-free-proof-path.sh`, `assert-osaurus-no-forced-behavior-pr.sh`, `assert-osaurus-vmlx-pr-readiness.sh`, `assert-osaurus-pr-hygiene.sh`, and `git diff --check` passed against the `84c8bb653a50cd48b4af7f5cdce04d3f16e6ed95` vMLX pin before this app build.
- Verdict: LFM2.5 JANG_2L is green for the current PR-head no-sign Osaurus app row: multi-turn required-tool behavior, reasoning separation, parser leak prevention, hybrid SSM topology, disk L2 reuse, and SSM companion cache reuse. This does not promote LFM MXFP4/MXFP8 siblings or broad prompt contexts.

## 2026-05-29 LFM2.5 JANG_2L current-head cold pass and warm-cache partial

- Osaurus PR head at check: `662de08d1bc52bd7d5ae91ab6d8a1d6e246fb062`.
- vMLX main / Osaurus pin: `5035d62454531c7d9bdbdbbd4b3cdc54077470e8`.
- No-sign app path: `build/DerivedData-pr1268-lfm25-nosign-662de08d/Build/Products/Release/osaurus.app`.
- Launch boundary: app was launched keychain-free with `OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1`, `OSAURUS_TEST_ROOT=/tmp/osaurus-pr1268-662de08d-lfm25-ui-root-mlxstudio`, and `OSU_MODELS_DIR=/Users/eric/.mlxstudio/models`.
- Cold artifact: `/tmp/osaurus-pr1268-662de08d-lfm25-jang2l-tool-cache-cold-20260529-121517`.
- Warm artifact: `/tmp/osaurus-pr1268-662de08d-lfm25-jang2l-tool-cache-warm-20260529-121535`.
- Model: `lfm2.5-8b-a1b-jang_2l`.
- Cold result: the strict three-turn required/none/required harness passed. Turn 1 produced exact structured `line_count` args `red\ngreen\nblue`; turn 2 answered visibly with `There were 3 lines counted.` and no tool call; turn 3 produced exact structured `line_count` args `one\ntwo`. No protocol marker leaked, tool-call turns had no visible content, no length-stop fake pass occurred, and the app remained healthy with no in-flight request after the row. The plain answer turn still carried separate `reasoning_content`, but visible content was clean.
- Cold topology/cache result: 24 layers, 6 KV layers, 18 Mamba/SSM companion layers, `companion=ssm`, disk-backed restore required, SSM companion state required, paged-cache incompatible, block disk L2 enabled, and TurboQuant KV layer count 0. This row proves cache topology and disk-backed restore, not warm reuse; it recorded `disk_l2_misses 2`, `disk_l2_stores 4`, `disk_l2_hits 0`, `ssm_companion_hits 0`, and `companion_hits 0`.
- Cold token/s: visible follow-up emitted 164 completion tokens at 183.81 tok/s; OpenAI-compatible structured tool-call turns emitted zero completion tokens.
- Warm result: cache reuse was proven with `disk_l2_hits +1`, `ssm_companion_hits +1`, and `companion_hits +1` on the same LFM hybrid topology. Turn 1 remained exact, turn 2 answered visibly, and turn 3 still returned a structured `line_count` call with no visible/protocol leak, but `turn3_args_exact` failed because the `text` argument included extra native-call reasoning text after `one\ntwo`.
- Guard refresh: `RuntimePolicySourceTests/vmlxPinIncludesRuntimeHardening`, `SwiftTransformersTokenizerLoaderTests/lfm2LocalTokenizerUsesStrictRequiredToolFallback`, `assert-tool-choice-required-routing.sh`, `assert-server-settings-runtime-wiring.sh`, `assert-keychain-free-proof-path.sh`, `assert-osaurus-no-forced-behavior-pr.sh`, `assert-osaurus-vmlx-pr-readiness.sh`, `assert-osaurus-pr-hygiene.sh`, and `git diff --check` passed against the `5035d62454531c7d9bdbdbbd4b3cdc54077470e8` vMLX pin before this live run. vMLX focused tests also passed for the LFM stale reasoning stamp, LFM2 parser escaped newlines, and LFM2 required-template fallback.
- Verdict: LFM2.5 JANG_2L is green for the current-head cold Osaurus no-sign app row and green for warm L2/SSM companion cache-hit evidence, but partial for warm repeat exact argument fidelity. MXFP4/MXFP8 live rows, broader tools, and broader prompt contexts remain follow-up coverage.

## 2026-05-29 LFM2.5 JANG_2L superseded repeat required-tool red rows

- Osaurus PR head at check: `5535b681c939aba0b96b717c424243f60fc305b2`.
- vMLX main / Osaurus pin: `6a7b291709f6cf1b6db17928e1096c9007fbd1d0`.
- Red repeat artifact at `max_tokens: 768`: `/tmp/osaurus-pr1268-5535b681-lfm25-jang2l-tool-cache-warm-20260529-105641`.
- Red larger-budget artifact at `max_tokens: 2048`: `/tmp/osaurus-pr1268-5535b681-lfm25-jang2l-tool-cache-2048-20260529-105717`.
- 768 result: turn 1 ended `finish_reason: "length"` with no structured tool call and no visible content. The response spent the budget in untagged `reasoning_content`, reasoning about the tool-call format. Turn 2 and turn 3 were skipped because no valid tool call existed.
- 2048 result: turn 1 ended `finish_reason: "stop"` but produced visible native-looking text `[ line_count("red\ngreen\nb\nblue") ]` instead of an API `tool_calls` object. It leaked protocol-shaped text into visible content, omitted the required `text=` keyword argument, and corrupted the exact text argument. Turn 2 and turn 3 were skipped.
- Cache/topology result: both red rows still showed the 24-layer LFM hybrid topology with 6 KV layers, 18 Mamba/SSM companion layers, disk-backed restore required, and TurboQuant KV layer count 0. They did not prove warm disk L2 or SSM companion hits (`disk_l2_hits 0`, `ssm_companion_hits 0`, `companion_hits 0`).
- Caller-control check: a manual repeat request with explicit `enable_thinking:false` still produced untagged reasoning and `finish_reason: "length"`, so this is not cleared by a caller-side thinking disable.
- Verdict: these red rows are superseded for the length-stop/no-tool-call failure mode by the later `5035d62454531c7d9bdbdbbd4b3cdc54077470e8` vMLX pin and current-head cold pass, but they remain useful regression evidence. LFM2.5 is still not production-clear globally because the current-head warm cache row proves L2/SSM hits but still fails exact turn 3 argument fidelity, and MXFP4/MXFP8 live rows remain unproven.

## 2026-05-28 Nemotron Omni MXFP4 repeat required-tool red row

- Osaurus head at check: `a1d101d6f22dfff41052c1af33975c25663175cd`.
- vMLX main / Osaurus pin: `76e55f59935f22c3bb2f28055ae8ecebd2e7a355`.
- No-sign app path: `build/DerivedData-pr1268-release-nosign-695d5869/Build/Products/Release/osaurus.app`.
- Cold artifact: `/tmp/osaurus-pr1268-a1d101d6-nemotron-omni-mxfp4-tool-cache-20260528-102745`.
- Repeat artifact: `/tmp/osaurus-pr1268-a1d101d6-nemotron-omni-mxfp4-tool-cache-repeat-20260528-102806`.
- Cold result: first required `line_count` call, tool-result follow-up answer, and second required `line_count` call were structured and leak-free; topology showed 29 layers with 23 Mamba/SSM layers, `companion=ssm`, disk-backed restore required, and TurboQuant KV layer count 0.
- Repeat result: turn 3 failed because `tool_choice: "required"` produced visible text `Two lines were counted.` with `finish_reason: "stop"` instead of a structured tool call; all three repeat responses reported the same `prefix_hash`, and the after-snapshot no longer had Nemotron resident.
- Verdict: Nemotron Omni MXFP4 remains red/partial for repeat required-tool/cache behavior. This must not be hidden with prompt coercion or parser repair.

## 2026-05-28 Nemotron Omni MXFP4 repeat required-tool and warm cache proof

- Osaurus head at check: `10df987c5d58518a3be4d589ae5d1d942d59a9ce`.
- vMLX main / Osaurus pin: `d83b22b3d0350aa45b5b853dd4838ea34af47497`.
- Initial selected-row artifact: `/tmp/osaurus-pr1268-10df987c-nemotron-mxfp4-required-tool-repeat-20260528-131627`.
- Cold strict artifact: `/tmp/osaurus-pr1268-10df987c-nemotron-omni-mxfp4-required-cache-20260528-131529`.
- Warm strict artifact: `/tmp/osaurus-pr1268-10df987c-nemotron-omni-mxfp4-required-cache-warm-20260528-131559`.
- Model: `nemotron-omni-nano-mxfp4-crack`.
- Result: turn 1 produced a structured `line_count` call with exact `red\ngreen\nblue`; turn 2 answered visibly with `The count is 3.`; turn 3 repeated `tool_choice: "required"` and produced a structured `line_count` call with exact `one\ntwo`; no protocol markers leaked into visible content.
- Warm cache result: `disk_l2_hits +1`, `ssm_companion_hits +1`, and `companion_hits +1`; topology remains 29 layers with 6 KV and 23 Mamba/SSM layers, SSM companion state, disk-backed restore required, and TurboQuant KV 0.
- Verdict: the vMLX `d83b22b3` repin clears the previous MXFP4 repeat-required-tool behavior and the warm strict row proves text-path disk/SSM companion cache reuse. Media/audio/video rows remain unproven.

## 2026-05-28 Nemotron Omni JANGTQ4 required-tool repeat green, cache partial row

- Osaurus head at check: `7fa73661b1651a8ec26e49a529b386a9552bfb8d`.
- Artifact: `/tmp/osaurus-pr1268-nemotron-jangtq4-required-tool-repeat-20260528-123917`.
- Model: `nemotron-omni-nano-jangtq4-crack`.
- Result: turn 1 produced a structured `line_count` call with exact `red\ngreen\nblue`; turn 2 answered visibly with `The count is 3.`; turn 3 produced a structured `line_count` call with exact `one\ntwo`; no protocol markers leaked into visible content.
- Cache boundary: `disk_l2_misses +2` and `disk_l2_stores +3`, but `disk_l2_hits`, SSM companion hits, and SSM companion rederives stayed 0.
- Verdict: Nemotron Omni JANGTQ4 is green for this selected text/tool/history row, but cache reuse and media/audio/video behavior remain partial. This does not clear the separate MXFP4 repeat-required-tool red row.

## 2026-05-28 ZAYA text JANGTQ4 required-tool red row

- Osaurus head at check: `c9fdc4c38ee53f748805d89c0312a9c61ecf1662`.
- No-sign app path: `build/DerivedData-pr1268-release-nosign-695d5869/Build/Products/Release/osaurus.app`.
- Artifact: `/tmp/osaurus-pr1268-c9fdc4c3-zaya-text-jangtq4-tool-cache-20260528-103322`.
- Result: turn 1 produced a structured `line_count` call with exact `red\ngreen\nblue`; turn 2 answered `3 lines were counted.`; turn 3 produced a structured `line_count` call but with argument ` ... ` instead of exact `one\ntwo`.
- Topology: 80 layers, 40 KV layers, 40 ZAYA CCA layers, `companion=zaya-cca`, disk-backed restore required, TurboQuant KV layer count 0.
- Verdict: ZAYA text JANGTQ4 remains red/partial for multi-turn required-tool argument fidelity and repeat L2 reuse. This must not be hidden with parser repair.

## 2026-05-28 ZAYA text JANGTQ4 current-head confidence flake and rerun

- Osaurus PR head at check: `2e48e1e7c14cd73b67a83aa70c3af0276ae75c29`.
- vMLX main / Osaurus pin: `d83b22b3d0350aa45b5b853dd4838ea34af47497`.
- Failed confidence artifact: `/tmp/osaurus-pr1268-2e48e1e7-confidence-zaya-ling-20260528-172807`.
- Passing rerun artifact: `/tmp/osaurus-pr1268-2e48e1e7-confidence-zaya-rerun-20260528-173145`.
- Model: `zaya1-8b-jangtq4`.
- Failed-row result: the same strict three-turn required/none/required harness produced exact turn 1 `line_count` args `red\ngreen\nblue`, visible turn 2 answer `There were 3 lines counted.`, and one structured turn 3 `line_count` call, but turn 3 args were `{"text":"..."}` instead of exact `one\ntwo`. The failure was `turn3_args_exact` only.
- Failed-row parser/leak result: no protocol marker leaked, no incoherent visible loop occurred, no hidden visible content appeared on tool-call turns, and the parser still returned structured `tool_calls`.
- Passing rerun result: immediate single-model rerun with the same harness produced exact turn 1 args `red\ngreen\nblue`, visible turn 2 answer `Three lines were counted.`, exact turn 3 args `one\ntwo`, no protocol leak, no visible loop, and healthy app state after the run.
- Topology/cache result: 80 layers, 40 KV layers, 40 ZAYA CCA layers, `companion=zaya-cca`, disk-backed restore required, and TurboQuant KV layer count 0. The rerun proves CCA topology and disk-backed restore; it does not prove CCA companion-hit reuse.
- Token/s: failed-row visible follow-up emitted 7 completion tokens at 10.34 tok/s; passing rerun visible follow-up emitted 5 completion tokens at 10.31 tok/s. Tool-call turns emitted zero completion tokens.
- Source boundary: the pinned vMLX checkout at `d83b22b3d0350aa45b5b853dd4838ea34af47497` includes explicit required/named tool-choice handling in `ChatTemplateFallbacks.zayaVLVisionToolMinimal`. This aligns ZAYA fallback behavior with the existing DSV4/Nemotron required-tool template contract; it is not parser output repair, prompt-history mutation, hidden sampling, or close-token biasing. Osaurus guard `scripts/live-proof/assert-tool-choice-required-routing.sh` requires the ZAYA text, ZAYA-VL multi-turn, and named `line_count` tokenizer regressions to stay present.
- Validation boundary: fresh vMLX focused tests on `d83b22b3d0350aa45b5b853dd4838ea34af47497` passed for `DeepseekV4ChatTemplateFallbackFocusedTests/zayaVLFallbackPreservesVisionAndTools` and `DeepseekV4ChatTemplateFallbackFocusedTests/zayaVLRequiredToolChoiceRepeatsAfterNoToolHistory` using scratch path `/tmp/vmlx-zaya-required-tool-proof-2`.
- Verdict: ZAYA text JANGTQ4 is functional and not showing the user-feared loop/leak failure in this current-head confidence pass, but it is not deterministic production-clear. Keep it partial/flaky until stronger live proof clears the argument-fidelity flake. Do not hide this with parser repair, prompt coercion, or hidden sampler/default changes.

## 2026-05-28 ZAYA text and Ling JANGTQ current PR-head confidence pass

- Osaurus PR head at check: `939c275563c841939bc34f36619d8aeb532ed56c`.
- vMLX main / Osaurus pin: `d83b22b3d0350aa45b5b853dd4838ea34af47497`.
- Artifact: `/tmp/osaurus-pr1268-939c2755-confidence-zaya-ling-20260528-232831`.
- Models: `zaya1-8b-jangtq4` and `ling-2.6-flash-jangtq2-crack`.
- ZAYA result: the strict three-turn required/none/required harness passed. Turn 1 produced exact structured `line_count` args `red\ngreen\nblue`; turn 2 answered visibly with `Three lines were counted.` and no tool call; turn 3 produced exact structured `line_count` args `one\ntwo`. No protocol marker leaked, no incoherent visible loop occurred, no hidden visible content appeared on tool-call turns, and the app remained healthy with no in-flight request after the row.
- ZAYA topology/cache result: 80 layers, 40 KV layers, 40 ZAYA CCA layers, `companion=zaya-cca`, disk-backed restore required, and TurboQuant KV layer count 0. This row proves topology and disk-backed restore but not CCA companion-hit reuse; it recorded disk L2 misses/stores with `disk_l2_hits 0`.
- ZAYA token/s: visible follow-up emitted 5 completion tokens at 8.64 tok/s; OpenAI-compatible structured tool-call turns emitted zero completion tokens.
- Ling result: the same harness passed with exact `red\ngreen\nblue` and `one\ntwo` structured `line_count` arguments, visible turn 2 answer, no protocol leak, no length stop, and healthy app state after the row.
- Ling topology/cache result: 32 layers, 4 KV layers, 28 arrays/SSM companion layers, `companion=ssm`, disk-backed restore required, and TurboQuant KV layer count 0. This row proves topology and disk-backed restore; earlier warm rows remain the cache-hit proof for Ling because this short row recorded `disk_l2_hits 0`.
- Guard refresh: `assert-tool-choice-required-routing.sh`, `assert-server-settings-runtime-wiring.sh`, `assert-keychain-free-proof-path.sh`, `assert-osaurus-no-forced-behavior-pr.sh`, `assert-osaurus-vmlx-pr-readiness.sh`, and `assert-osaurus-pr-hygiene.sh` passed on this PR head. These cover ZAYA required/named tokenizer regressions, server settings UI/runtime wiring, keychain-free proof paths, no hidden sampler/default/forced-behavior repairs, vMLX pin/checkout readiness, Responses/cache source wiring, chat reasoning/UI routing, HTTP cancellation, model tool/capability surfaces, and PR hygiene.
- UI visual boundary: the no-sign app at `build/DerivedData/Build/Products/Release/osaurus.app` was running and `/health` was healthy, but Computer Use UI inspection failed before reading the app with tool configuration error `unknown variant default, expected fast or flex in service_tier`. This row therefore has live API/app proof plus source UI guards, not a fresh visual screenshot.
- Verdict: ZAYA text and Ling JANGTQ2 are green for this current PR-head focused multi-turn required-tool/parser/topology confidence row. ZAYA CCA companion-hit depth, broader direct-mode/statistical repeat confidence, and broader media/video/UI visual proof remain separate partial rows.

## 2026-05-28 Ling JANGTQ2 required-tool and SSM cache green row

- Osaurus head at check: `722f138ff933a93fae226e6fb687c648fd3419a1`.
- vMLX pin: `d83b22b3d0350aa45b5b853dd4838ea34af47497`.
- No-sign app path: `/Users/eric/osaurus-pr1268-live/build/DerivedData/Build/Products/Release/osaurus.app`.
- Cold artifact: `/tmp/osaurus-pr1268-722f138f-ling-jangtq2-required-cache-cold-20260528-142834`.
- Warm artifact: `/tmp/osaurus-pr1268-722f138f-ling-jangtq2-required-cache-warm-20260528-142907`.
- Result: cold and warm rows produced exact structured `line_count` args `red\ngreen\nblue` on turn 1 and exact structured `line_count` args `one\ntwo` on turn 3 after assistant/tool history; both tool turns returned `content=null` with no visible protocol leakage, and both tool-result follow-ups returned visible line-count answers with `finish_reason: "stop"`.
- Cache result: warm row proved `disk_l2_hits +1`, `ssm_companion_hits +1`, and `companion_hits +1`; cold row proved stores/topology without falsely claiming hits.
- Topology: 32 layers, 4 KV layers, 28 arrays/SSM companion layers, `companion=ssm`, disk-backed restore required, TurboQuant KV layer count 0.
- Token/s: visible follow-up emitted 10 completion tokens at 11.14 tok/s cold and 5 completion tokens at 7.43 tok/s warm; OpenAI-compatible structured tool-call turns emitted zero completion tokens.
- Verdict: Ling JANGTQ2 is green for required-tool parsing, assistant/tool history replay, visible tool-result finalization, disk L2 reuse, and SSM companion cache reuse. The older cache-partial artifact `/tmp/osaurus-pr1268-3a46be1f-ling-jangtq2-tool-cache-20260528-103538` is superseded. Ling MXFP4 remains a separate blocked/red row below.

## 2026-05-28 Ling JANGTQ2 current-head confidence row

- Osaurus PR head at check: `2e48e1e7c14cd73b67a83aa70c3af0276ae75c29`.
- vMLX main / Osaurus pin: `d83b22b3d0350aa45b5b853dd4838ea34af47497`.
- Artifact: `/tmp/osaurus-pr1268-2e48e1e7-confidence-zaya-ling-20260528-172807`.
- Model: `ling-2.6-flash-jangtq2-crack`.
- Result: the strict three-turn required/none/required harness passed on current head. Turn 1 produced exact structured `line_count` args `red\ngreen\nblue`; turn 2 answered visibly with `Three lines were counted.` and no tool call; turn 3 produced exact structured `line_count` args `one\ntwo`.
- Parser/leak result: no protocol marker leaked, no hidden reasoning-only visible output occurred, and all tool-call turns stayed structured with `finish_reason: "tool_calls"`.
- Topology/cache result: 32 layers, 4 KV layers, 28 arrays/SSM companion layers, `companion=ssm`, disk-backed restore required, and TurboQuant KV layer count 0. The current-head confidence row proves topology and disk-backed restore, but does not replace the earlier warm row for actual `disk_l2_hits +1`, `ssm_companion_hits +1`, and `companion_hits +1`.
- Token/s: visible follow-up emitted 5 completion tokens at 6.96 tok/s; OpenAI-compatible structured tool-call turns emitted zero completion tokens.
- Verdict: Ling JANGTQ2 remains green for current-head required-tool/history/parser behavior without prompt coercion, parser repair, or hidden sampler defaults.

## 2026-05-28 Ling MXFP4 current-head timeout/app-exit blocked row

- Osaurus head at check: `270300f70e9eacc95aa4204ea8cfeead53ca3a46`.
- No-sign app path: `build/DerivedData-pr1268-release-nosign-695d5869/Build/Products/Release/osaurus.app`.
- Artifact: `/tmp/osaurus-pr1268-270300f7-ling-mxfp4-tool-cache-20260528-111408`.
- Result: first required `line_count` request timed out client-side before a response artifact was written. Immediately after, `/health` showed `ling-2.6-flash-mxfp4-crack` loaded with one in-flight request and zero cache movement; a later health check found port `1337` unavailable and no `osaurus` process remained for that app path.
- Topology before the app disappeared: 32 layers, 4 KV layers, 28 arrays/SSM companion layers, `companion=ssm`, disk-backed restore required, TurboQuant KV layer count 0.
- Verdict: Ling MXFP4 is blocked/red for this current-head proof attempt. The artifact proves timeout/app-exit behavior, not model correctness; do not promote Ling MXFP4 until a clean no-sign app repeat produces structured tools, visible tool-result answer, no leaks, and SSM/L2 cache evidence.

## 2026-05-28 MiniMax M2.7 small JANGTQ required-tool green row

- Osaurus head at check: `0bba84c9bc8d1b60a872d29bd28e9af3aee586dd`.
- No-sign app path: `build/DerivedData-pr1268-release-nosign-695d5869/Build/Products/Release/osaurus.app`.
- Artifact: `/tmp/osaurus-pr1268-0bba84c9-minimax-small-jangtq-tool-cache-20260528-103659`.
- Result: turn 1 produced exact structured `line_count` args `red\ngreen\nblue`; turn 2 answered `There were three lines counted.`; turn 3 produced exact structured `line_count` args `one\ntwo`; no protocol leakage appeared.
- Topology: 62 full-KV layers, no SSM/CCA companion requirement, disk L2 hit `+1`, TurboQuant KV layer count 0.
- Verdict: MiniMax M2.7 small JANGTQ is green for this parser/tool/history/cache row. Sibling JANG/JANGTQ-K, speed, RAM, and MiMo-adjacent rows remain separate.

## 2026-05-28 Gemma4 JANG_4M required-tool red row

- Osaurus head at check: `213d0ffd823a4c61181b308aa6b5c24a2fd4b194`.
- No-sign app path: `build/DerivedData-pr1268-release-nosign-695d5869/Build/Products/Release/osaurus.app`.
- Artifact: `/tmp/osaurus-pr1268-213d0ffd-gemma4-jang4m-tool-cache-20260528-103834`.
- Result: turn 1 failed required-tool behavior with `finish_reason: "stop"`, empty visible content, and `reasoning_content: "thought<tool_call|>"` instead of a structured `tool_calls` response.
- Topology: 30 layers, 5 KV layers, 25 rotating KV layers, disk-backed restore required, TurboQuant KV layer count 0.
- Verdict: Gemma4 JANG_4M is red for required-tool parser/output behavior on this row. This must not be hidden with reasoning parser output repair or forced close-token biasing.

## 2026-05-28 Gemma4 JANG_4M no-thinking default required-tool green row

- Osaurus worktree state: dirty follow-up patch on top of `270300f70e9eacc95aa4204ea8cfeead53ca3a46`, adding Gemma-family `enable_thinking=false` default for ordinary local API requests while preserving explicit thinking opt-in.
- No-sign app path: `build/DerivedData-pr1268-gemma-default-nosign/Build/Products/Release/osaurus.app`.
- Primary artifacts: `/tmp/osaurus-pr1268-gemma-default-gemma4-jang4m-tool-cache-20260528-112756`, `/tmp/osaurus-pr1268-gemma-default-gemma4-jang4m-tool-cache-repeat-20260528-112822`, and focused check `/tmp/osaurus-pr1268-dirty-gemma-default-gemma4-tool-cache-20260528-112946`.
- Result: required `line_count` calls before and after tool-result history were structured with exact multiline args; the tool-result follow-up answered visibly with no extra tool call; no Harmony/Gemma/tool markers leaked.
- Topology: 30 layers, 5 KV layers, 25 rotating KV layers, disk-backed restore required, TurboQuant KV layer count 0; warm proof records `disk_l2_hits +1`, and the focused check stayed healthy with no in-flight request after the proof.
- Verdict: Gemma4 JANG_4M is green for this required-tool/history row when ordinary local API requests default to the closed/no-thinking rail. This is model-option/template wiring, not parser output repair; explicit thinking mode, media/video, Gemma3n, and unrelated Gemma siblings remain separate.

## 2026-05-28 Qwen 27B MXFP4 CRACK MTP required-tool parser green, cache partial row

- Osaurus head at check: `2ac8d31f87f4d82ab9de9f8e4188bdab8800bb71`.
- No-sign app path: `build/DerivedData-pr1268-release-nosign-695d5869/Build/Products/Release/osaurus.app`.
- Artifact: `/tmp/osaurus-pr1268-2ac8d31f-qwen27-mxfp4-crack-mtp-tool-cache-20260528-103947`.
- Result: turn 1 produced exact structured `line_count` args `red\ngreen\nblue`; turn 2 answered `3 lines were counted.`; turn 3 produced exact structured `line_count` args `one\ntwo`; no protocol leakage appeared.
- Topology: 64 layers, 16 KV layers, 48 Mamba/SSM layers, `companion=ssm`, disk-backed restore required, TurboQuant KV layer count 0.
- Verdict: Qwen 27B MXFP4 CRACK MTP is green for this parser/tool/history row, but cache proof remains partial because disk L2 hits stayed 0 while misses/stores moved.

## 2026-05-28 Qwen 27B MXFP4 thinking/tool screenshot repro boundary

- User screenshot: Qwen3.6 27B MXFP4 with Thinking enabled, repeated file tools, large visible context (`~54k / 262k tokens`), and a later thinking-channel `!!!!!!!!` loop.
- Two-tool artifact: `/tmp/osaurus-pr1268-qwen27-mxfp4-thinking-tool-repro-20260528-114825`.
  - Model: `qwen3.6-27b-mxfp4-crack`.
  - Request shape: OpenAI chat completions, `enable_thinking=true`, `reasoning_effort=high`, required `line_count`, then tool result history, then final answer.
  - Result: two structured required tool calls, coherent final answer, no `!!!!!!!!` loop, no parser/tool marker leak.
  - Topology: 64 layers, 16 KV layers, 48 Mamba/SSM layers, `companion=ssm`, disk-backed restore required, TurboQuant KV layer count 0; disk L2 stores moved but hits stayed 0.
- Five-tool artifact: `/tmp/osaurus-pr1268-qwen27-mxfp4-thinking-5tool-repro-20260528-114944`.
  - Result: five structured required tool calls and a coherent final answer; no `!!!!!!!!` loop and no parser/tool marker leak.
  - Boundary: turn 1 argument became `red\n\ngreen\nblue` instead of exact `red\ngreen\nblue`, so this row is not an exact-argument promotion even though the line count stayed correct.
  - Cache boundary: `disk_l2_stores +10`, but `disk_l2_hits`, SSM companion hits, and companion rederives stayed 0.
- File-tool artifact: `/tmp/osaurus-pr1268-qwen27-mxfp4-thinking-filetool-repro-20260528-120924`.
  - Request shape: Thinking enabled, five sequential file-tool turns (`file_tree`, repeated `file_read`), then a final answer over the gathered project fixture.
  - Result: five structured tool-call turns and one coherent final answer; no `!!!!!!!!` loop and no raw tool-envelope marker leaked into ordinary assistant text.
  - Boundary: absolute `file_read` paths returned not found until the model switched to the relative `docs/runtime.md` path, so this row is not a file-tool fidelity promotion.
  - Boundary: the artifact summary flags `DSML` in the final visible answer, but that is fixture content (`DSV4 uses DSML tools`), not a DSV4 parser/protocol leak.
  - Cache boundary: `disk_l2_stores +6`, but `disk_l2_hits`, SSM companion hits, and SSM companion rederives stayed 0.
- Warm repeat artifact: `/tmp/osaurus-pr1268-qwen27-mxfp4-thinking-filetool-repeat-cache-20260528-122054`.
  - Request shape: exact repeat of the file-tool fixture final request against the resident warm Qwen model.
  - Result: no `!!!!!!!!` loop and no protocol marker leak, but the response stopped with `finish_reason: "length"`, empty visible content, and reasoning-only text instead of the coherent final answer from the cold row.
  - Cache boundary: repeat still produced `disk_l2_stores +1` with `disk_l2_hits 0`, SSM companion hits `0`, and SSM companion rederives `0`.
- Corrected named file-tool artifact: `/tmp/osaurus-pr1268-qwen27-mxfp4-thinking-filetool-named-repro-20260528-121522`.
  - Request shape: Thinking enabled, named `tool_choice` sequence over `file_tree`, `file_read`, `file_read`, `line_count`, then final no-tool answer over the same tool history.
  - Result: all four named tool turns returned exactly one structured tool call with the expected tool name, exact readable file paths, no raw tool envelope leak, and no `!!!!!!!!` loop.
  - Boundary: the final no-tool answer with `max_tokens: 1024` consumed the entire completion budget in `reasoning_content`, returned `content: ""`, and ended with `finish_reason: "length"`.
  - Cache boundary: Qwen topology was 64 layers / 16 KV / 48 Mamba, `companion=ssm`, disk-backed restore required, TurboQuant KV 0; cache counters were already warm from prior rows and the row did not prove a new disk L2 or SSM companion hit.
- Final-answer budget artifact: `/tmp/osaurus-pr1268-qwen27-mxfp4-thinking-final-budget-check-20260528-121810`.
  - Result: the same tool-result history with Thinking enabled and `max_tokens: 2048` returned visible content, no extra tool calls, and `finish_reason: "stop"`.
  - Boundary: this clears the small-budget final-answer failure as an output-budget/thinking-budget interaction, not as a parser leak or tool-history corruption.
- Exact-head final-answer repeat/cache artifact: `/tmp/osaurus-pr1268-380e7f96-qwen27-mxfp4-thinking-filetool-final-cache-2048-20260528-151216`.
  - Request shape: handcrafted file/tool history equivalent to the corrected named-tool row, Thinking enabled with `enable_thinking=true` / `reasoning_effort=high`, `tool_choice: "none"`, and explicit `max_tokens: 2048`; the same final no-tool request was sent twice against the no-sign app.
  - Result: both final-answer turns ended `finish_reason: "stop"` with visible content, no tool calls, no protocol marker leakage, and no `!!!!!!!!` loop.
  - Cache result: the warm repeat produced `disk_l2_hits +1`, `ssm_companion_hits +1`, and `companion_hits +1`.
  - Topology: 64 layers, 16 KV layers, 48 Mamba/SSM layers, `companion=ssm`, disk-backed restore required, TurboQuant KV layer count 0.
  - Token/s: first final answer emitted 537 completion tokens in 32.72s (`16.41 tok/s`); warm repeat emitted 327 completion tokens in 18.43s (`17.74 tok/s`).
- Verdict: the screenshot loop is not reproduced by the small two-tool, five-tool synthetic, corrected named file-tool, or exact-head final-answer repeat/cache rows. Qwen 27B MXFP4 Thinking+tools is green for structured named tool calls and for repeated 2048-token final answers over file/tool history with disk L2 plus SSM companion reuse. It remains partial for the original large real UI context (`~54k / 262k tokens`) and product handling of too-small thinking output budgets. Do not add hidden repetition penalties, synthetic max-token clamps, or parser repair for this.

## 2026-05-28 ZAYA-VL JANGTQ4 red image media/cache green row

- Osaurus head at check: `b780e33737cbf51d3045c97c694a8ee7104caebb`.
- No-sign app path: `build/DerivedData-pr1268-release-nosign-695d5869/Build/Products/Release/osaurus.app`.
- Artifact: `/tmp/osaurus-pr1268-b780e337-zaya-vl-jangtq4-red-media-cache-20260528-104101`.
- Payload: generated 64x64 red PNG sent as an OpenAI-compatible image content part.
- Result: first response `Red`, repeat response `Red`, stable `prefix_hash`, no protocol leakage, repeat disk L2 hit `+1`.
- Topology: 40 ZAYA CCA layers, `companion=zaya-cca`, disk-backed restore required, TurboQuant KV layer count 0.
- Verdict: ZAYA-VL JANGTQ4 is green for this image/media repeat-cache row; CCA companion-hit depth, sibling variants, and video rows remain partial.

## 2026-05-28 DSV4 JANGTQ-K required-tool red row

- Osaurus head at check: `50b38bc8b2b4b4ee8b639d16c798de19782cc75d`.
- No-sign app path: `build/DerivedData-pr1268-release-nosign-695d5869/Build/Products/Release/osaurus.app`.
- Artifact: `/tmp/osaurus-pr1268-50b38bc8-dsv4-jangtq-k-tool-cache-20260528-104417`.
- Result: turn 1 took 517.5 seconds and ended with `finish_reason: "length"` instead of a structured tool call; visible content was empty and reasoning text looped over interpreting `red\ngreen\nblue`.
- Topology: 43 layers, 41 hybrid-pool layers, 2 rotating KV layers, disk-backed restore required, TurboQuant KV layer count 0.
- Verdict: DSV4 JANGTQ-K is red under the generic required-tool harness. Do not infer readiness from the JANGTQ2 proof row.

## 2026-05-28 DSV4 JANGTQ-K explicit-control required-tool green row

- Osaurus head at check: `be665ebf425104bd52e5b02cbe823080f7bf64ed`.
- No-sign app path: `build/DerivedData-pr1268-release-nosign-695d5869/Build/Products/Release/osaurus.app`.
- Artifact: `/tmp/osaurus-pr1268-be665ebf-dsv4-jangtq-k-explicit-instruct-tool-20260528-105634`.
- Request: `/v1/chat/completions` with model `deepseek-v4-flash-jangtq-k`, `reasoning_effort: "instruct"`, `max_tokens: 256`, `tool_choice: "required"`, and the `line_count` schema.
- Result: one structured `line_count` tool call with exact `red\ngreen\nblue` arguments, `finish_reason: "tool_calls"`, no visible content, and no DSML/protocol leak.
- Verdict: DSV4 JANGTQ-K is green for a single explicit-control required-tool call. The generic harness remains red, and JANGTQ-K multi-turn/tool-result/cache-repeat proof remains incomplete.

## Evidence Standard

Each live row needs an artifact folder with:

- exact local model path and resolved model id;
- `config.json`, `generation_config.json`, `tokenizer_config.json`,
  `chat_template.jinja`, JANG metadata, MTP tensor/tuning status, and VLM
  processor facts when present;
- UI path proof from the Osaurus chat app: model picker, chat settings, server
  settings, visible defaults, saved-setting reload, stop button, and stream
  finalization;
- API path proof for `/v1/chat/completions` stream and non-stream,
  `/v1/responses` stream and non-stream, and any applicable Anthropic/Ollama
  compatibility route;
- request payload and response body excerpts showing visible content,
  `reasoning_content`, `tool_calls`, stop reason, token counts, and token/s;
- cache stats before and after each turn: prefix, paged, block L2 disk, SSM companion, path-dependent cache state, and media salt;
- TTFT, prompt time, decode tok/s, RSS, Activity Monitor physical footprint
  when available, and disk-cache bytes written;
- three-turn chat proof: cold first turn, same-chat follow-up, model switch or
  media switch, then a return to the original model/session;
- explicit ON/OFF inverse rows for reasoning, tools, streaming, prefix cache,
  paged cache, block L2, and media attachment where the family supports them;
- no leaked `<think>`, DSML, Harmony, Gemma4, Qwen tool XML, GLM/Hunyuan,
  MiniMax, or Nemotron tool markers in visible `.chunk` content.

Passing unit tests can support a row, but they do not replace live proof.

Status words in this file are strict:

- `source-wired`: static code or unit tests cover the routing contract.
- `vmlx-live`: the consolidated engine has a live artifact outside Osaurus.
- `osaurus-live`: the packaged/current Osaurus UI or HTTP route has a live
  artifact with cache, speed, memory, and visible output.
- `production-clear`: all required `osaurus-live` artifacts exist for the row.

Do not promote `source-wired` or `vmlx-live` to `production-clear`.

## Prompt-to-Artifact Checklist

Every live row must map a user-visible behavior to a concrete artifact path. A
single model load, a single API route, or a unit test does not cover the row.

| ID | Requirement | Required artifact evidence | Current status |
|---|---|---|---|
| A1 | Bundle census and autodetect | JSON/text artifact with `config.json`, `generation_config.json`, `tokenizer_config.json`, chat template source, JANG/JANGTQ sidecars, real `mtp.*` tensor count, `vmlx_mtp_tuning.json`, VLM processor files, and detected family/parser/cache topology. | File-level census is not committed to this PR; live UI/API detection proof is still pending per model. |
| A2 | App launch and model picker | Screenshot/log proving the model appears with correct name/path, VLM/audio/video badges, MTP status from tuning, parser family, cache topology, and no stale saved profile. | Pending `osaurus-live`. |
| A3 | Chat settings visual defaults | Screenshot/log for defaults after selecting the model: DSV4 `instruct` selected, DSV4 `max` selectable and passed as `reasoning_effort=max`, Qwen no-thinking default where applicable, ZAYA/Nemotron no-thinking defaults, MiniMax reasoning channel, Gemma Harmony controls, and no controls for unsupported features. | Source-wired for profiles; pending UI proof. |
| A4 | Server settings and CLI preview | Screenshot/log of cache, batching, sleep/wake, generation, tool, reasoning, VLM, and MTP sections; DSV4 row must prove native DSV4 cache copy present, block size fixed/disabled at 256, generic KV q4/q8 disabled, pool quant visible, JIT disabled, generation defaults shown from `generation_config.json` / `jang_config.json` metadata including native `top_k`, and CLI preview omits topology-invalid flags: `--kv-cache-quantization`, `--enable-jit`, `--is-mllm`, and `--speculative-model`. | DSV4 checklist source-locked; pending final UI/CLI artifact. |
| A5 | Chat UI default cache stack | Three-turn chat from the app using default cache stack: cold T1, T2 follow-up with prefix/paged/L2/path-dependent cache stats, T3 model/media switch, then return to original session. Include TTFT, tok/s, RSS, Activity Monitor physical footprint, and visible coherent output. | Pending `osaurus-live`. |
| A6 | `/v1/chat/completions` | Stream and non-stream HTTP artifacts with omitted sampler fields, explicit sampler fields, tools on/off, reasoning on/off, media where supported, terminal usage, `[DONE]`, no raw parser markers, and cache stats around each turn. | Pending `osaurus-live`. |
| A7 | `/v1/responses` | Same sequence as A6 plus prior-response/session continuity and reasoning response shape; prove no route-specific loss of cache scope, tool calls, or reasoning deltas. | Pending `osaurus-live`. |
| A8 | `/v1/messages` | Anthropic stream/non-stream artifacts for applicable families with thinking/tool-use mapping, media content, terminal tail, and no raw `<think>`, Harmony, DSML, Qwen XML, MiniMax, GLM/Hunyuan, or Nemotron tags in visible text. | Pending `osaurus-live`. |
| A9 | Ollama compatibility | `/api/chat` and `/api/generate` stream/non-stream artifacts with omitted/supplied options, proper final tail frame, no hidden sampler defaults, and no stale saved reasoning setting entering the request. | Pending `osaurus-live`. |
| A10 | VLM/omni media cache sequence | Image+text T1, text-only T2 with media-salt nil/absent, different-image T3, video frame row when supported, unsupported-media error, repeated media cache hit/alias, and audio/Parakeet pre-encode when applicable. | Source-wired for media preservation; pending live Qwen/Gemma/ZAYA/Nemotron rows. |
| A11 | Tool context injection and parser split | First turn with tools, structured `tool_calls`; second turn with `tool_result`; third visible answer. Prove no plaintext tool schema/result leak, no cache-key drift from tool history, and parser family matches base architecture. | DSV4 `vmlx-live`; remaining families pending Osaurus API/UI rows. |
| A12 | Reasoning inverse and leak checks | For each reasoning family, run off/default/on/max or native efforts. Capture reasoning channel, visible content, final tail, token counts, and prove unsupported families hide/ignore stale settings instead of sending invalid fields. | Source-wired for profiles; pending live rows. |
| A13 | Cache inverse checks | Prefix, paged, block L2, SSM companion, path-dependent media/CCA/DSV4 caches ON by default where valid; OFF rows do not crash; ON again restores counters/hits. Include disk bytes and max-GB enforcement for L2. | Pending `osaurus-live`. |
| A14 | Batch and scheduler | Single-user chat uses max batch size 1; same-model concurrent API requests hit continuous batching; different-model sessions stay isolated; cancel drains in-flight stats and leaves no zombie Swift engine. | Source-wired for adapter behavior; pending live concurrency/cancel rows. |
| A15 | JANG/JANGTQ/TurboQuant path | Loader derives real quant/cache metadata from sidecars and weights, not names. Artifacts show JANG/JANGTQ format, TurboQuant KV encode/decode status when valid, and no permanent overlay or name-only MTP claim. | Partly `vmlx-live`; Osaurus health/settings proof pending. |
| A16 | UI persistence and cross-model carryover | Save settings, quit/reopen, switch across Qwen, DSV4, Ling/non-reasoning, VLM, and text-only models. Prove saved reasoning/cache/media settings are scoped correctly and do not slow or poison another session. | Pending `osaurus-live`. |
| A17 | Startup, sleep/wake, and memory | Load from app, deep sleep, wake, generate without disk reload when expected, record Activity Monitor physical footprint and RAM drop/recovery, then repeat cache hit checks. | Pending `osaurus-live`. |
| A18 | Visual state and errors | Screenshots/logs for model loading/ready/generating/error/sleeping, unsupported media, model load failure, mid-stream cancel, and parser/tool errors rendered cleanly without stack traces. | Pending `osaurus-live`. |

## Cross-Layer Gates

| Gate | Required proof | Current status |
|---|---|---|
| Model discovery | Osaurus detects family, VLM/audio/video support, parser profile, MTP from real tensors plus `vmlx_mtp_tuning.json`, and bundle generation defaults. | File-level bundle census exists; live UI/API matrix pending. |
| Generation defaults | UI/API requests with no sampler fields use model metadata first, then engine fallback; no hidden temperature/top-p/top-k/repetition floors. | Partly proven in vmlx artifacts; final Osaurus UI/API rows pending. |
| Reasoning settings | Saved settings and per-request overrides map to the correct family field: `enable_thinking`, `reasoning_effort`, `no_think`, DSV4 `instruct`/`max`, or no control. | Source-tested in Osaurus; live app setting persistence still pending. |
| Parser split | Reasoning goes only to reasoning UI/API channels, tools only to structured tool calls, final text only to visible content. | Parser source tests exist; family live API matrix pending. |
| Media processing | Image/video/audio payloads survive chat builder, preprocessing, vmlx input, media salt, cache storage, and API adapters. | Source-tested for preservation; live Qwen/Gemma/ZAYA/Nemotron app/API rows pending. |
| Cache stack | Prefix/paged/L2/SSM/DSV4/ZAYA path-dependent cache stats are captured before and after multi-turn runs. | vmlx artifacts exist for some families; Osaurus UI/API proof pending. |
| Batch/scheduler | Default single-user chat uses max batch size 1; same-model concurrent requests hit vmlx continuous batching; cancellation drains terminal stats. | Source-tested; live app/API concurrency row pending. |
| Settings renderer | Server settings and CLI preview show only topology-valid controls and omit invalid flags. | DSV4 checklist locked; other families still need final UI pass. |
| Tool integration | Tool schema injection, tool-call parsing, and second turn with tool result work for each parser family without cache-breaking prompt drift. | DSV4 live vmlx row passed; remaining families need live API rows. |

## Function-Level Live Checklist

These rows are the minimum subitems every model-family row must account for.
They are deliberately written at the function and wiring level so the final
gate cannot pass by showing one coherent answer while a hidden setting,
unsupported cache, or old-library path is still active.

| ID | Function or wiring surface | Required live/user-path proof |
|---|---|---|
| F1 | Model detection and metadata | Exact bundle path, family, parser, VLM/audio/video support, JANG/JANGTQ sidecars, MTP tensor count, `vmlx_mtp_tuning.json`, `generation_config.json`, `top_k`, and `jang_config.json` are captured before load. MTP is enabled only from real `mtp.*` weights plus tuning, never from the model name. |
| F2 | UI defaults and saved settings | Chat settings and server settings screenshots/logs prove DSV4 `instruct` default, DSV4 `max` pass-through, no-thinking defaults for Qwen/ZAYA/Nemotron/Ling where applicable, Gemma Harmony controls, tool/reasoning parser selection, cache controls, and saved-setting reload. Switching families must not carry stale reasoning, cache, media, or parser settings into the new request or cache key. |
| F3 | Request construction | Chat UI, `/v1/chat/completions`, `/v1/responses`, `/v1/messages`, `/api/chat`, and `/api/generate` all show omitted sampler fields resolving from model metadata, explicit sampler fields preserved, native `top_k` applied, tools injected only in tool-capable turns, and media/content parts preserved through adapters. |
| F4 | VL/video/audio preprocessing | Qwen-VL/Qwen3.6 MTP-VL uses Qwen3VLProcessor and MRoPE; Gemma VLM uses the Gemma media path; ZAYA-VL preserves CCA/path-dependent media state; Nemotron Omni uses Parakeet/RADIO. Artifacts include image size, video frame count, audio/pre-encode facts, media token count, media salt, repeated-media cache alias, and clean unsupported-media error. |
| F5 | Media cache boundaries | Multi-turn media rows prove image+text T1, text-only T2 with media-salt nil/absent, different-image T3 cache miss, repeated-media hit, restart/unload restore, and no cross-model or cross-session media-state reuse. |
| F6 | Cache stack and memory | Prefix, paged, block L2, SSM companion, DSV4 native cache, ZAYA CCA, media cache, and TurboQuant KV status are each recorded as active or N-A. Rows include cache stats before/after turns, L2 max-GB enforcement, TTFT delta, tok/s, RSS, Activity Monitor physical footprint, and disk bytes written. |
| F7 | Cache inverses | Prefix, paged, block L2, SSM companion, media cache, TurboQuant KV, reasoning, tools, streaming, VLM force-off, sleep/wake, and JIT/diagnostic flags each have ON/OFF rows where valid. OFF must not crash or silently change sampler defaults; ON must restore counters/kernel/cache topology. |
| F8 | Scheduler and process lifecycle | Single-user UI chat uses the local-chat default batch shape; same-model concurrent API calls exercise continuous batching; different-model sessions remain isolated; cancel/stop drains in-flight stats; sleep/wake restores a usable model; no zombie Swift engine, stale listener, or orphaned Metal context remains. |
| F9 | Parser and channel separation | Reasoning parser, tool parser, and visible content are checked separately for each family. No `<think>`, DSML, Harmony, Gemma4, Qwen XML, MiniMax XML, GLM/Hunyuan, Nemotron, JSON tool schema, or tool result marker may leak into visible `.chunk` content. Tool-call turns must produce structured `tool_calls`; second-turn `tool_result` must preserve ordering and cache scope. |
| F10 | Old-library and zombie-code sweep | Package pins, source imports, comments, CLI previews, and runtime logs prove Osaurus is using consolidated `vmlx-swift` modules for MLX, MLXLLM, MLXVLM, MLXLMCommon, VMLXTokenizers, and VMLXJinja. No active local inference path may import or pin old `vmlx-swift-lm`, standalone `mlx-swift`, standalone `swift-transformers`, or standalone `Jinja`. |
| F11 | No fake runtime guards | Failures must stay red until root-caused. Rows may not pass because of forced repetition penalties, hidden temperature/top-p/top-k floors, forced reasoning close tags, parser repairs, fake cache fallback, name-only MTP, permanent overlays, or length-cap-only success. |
| F12 | Forced behavior audit | Source and live rows must search for output-shaping patches: forced sampler defaults, forced repetition penalties, forced reasoning rail selection, forced `</think>` close tokens, token/logit biasing, and parser output repair. If any exist, the artifact must state why it was originally added, prove whether it still fires, and replace it with a real template/decode/tokenizer/cache/root-cause fix or leave the model row red. The only allowed generation defaults are bundle metadata (`generation_config.json` / `jang_config.json`) or explicit user/API kwargs. |

## Route-Specific Live Gate

Each route below must be tested with the same default cache stack that a normal
Osaurus user gets after selecting the model. Do not disable a cache layer just to
make a row pass unless the row is explicitly an inverse test.

| Route or surface | Required live sequence | Cache and parser evidence |
|---|---|---|
| Chat UI route | Open app, select model, inspect settings defaults, send T1 cold prompt, T2 follow-up, T3 model/media switch, Stop/Retry once, quit/reopen and resume. | Visible answer, reasoning pane state, tool card if used, token/s, TTFT, Activity Monitor physical footprint, cache stats before/after each turn. |
| `/v1/chat/completions` | Stream and non-stream with no sampler fields, tools on/off, reasoning on/off, media where supported. | SSE `[DONE]`, usage, structured `tool_calls`, no parser marker leakage, metadata generation defaults, prefix/paged/L2/SSM/media-salt stats. |
| `/v1/responses` | Stream and non-stream, standard and reasoning request, previous response/session continuity. | Same cache key and parser behavior as chat completions, no route-specific loss of reasoning/tool events, terminal usage emitted. |
| `/v1/messages` | Anthropic stream and non-stream for reasoning and media-capable families. | Thinking/tool-use mapping preserved without leaking raw `<think>`, Harmony, DSML, Qwen XML, Hunyuan, MiniMax, or Nemotron tags. |
| `/api/chat` and `/api/generate` | Ollama stream and non-stream, explicit `stream=false`, model options omitted and supplied. | Proper Ollama tail frame, no hidden app-level sampler defaults, no stale saved reasoning setting entering the request. |
| Server settings UI | Change batching/cache/sleep/generation/tool/reasoning settings, save, reset, relaunch. | Settings visible only when topology-valid; saved values are scoped to the right model family and do not alter cache scope for another family. |

## UI Settings Contract

The final Osaurus UI must show defaults from runtime metadata, not stale saved
values from a previous model. Required checks:

- DSV4: default visible mode is `instruct`; selecting `max` sends
  `reasoning_effort=max` unchanged to vmlx; generic q4/q8 KV, JIT,
  speculative model, and MLLM flags are hidden or omitted because they are
  invalid for the DSV4 topology. The renderer row must also prove native DSV4
  cache copy is present, paged block size is fixed/disabled at 256 when runtime
  metadata reports it, pool quant state is visible, generation defaults come
  from `generation_config.json` or `jang_config.json`, and CLI preview omits
  `--kv-cache-quantization`, `--enable-jit`, `--is-mllm`, and
  `--speculative-model`.
- Qwen reasoning/VL: default no-thinking where the profile says so, explicit
  opt-in sets `enable_thinking=true`, and Qwen-VL image/video rows use media
  salt without reusing a text-only cache entry.
- MiniMax: reasoning-capable profile must keep reasoning deltas out of visible
  content and preserve structured tool calls. If a row is reasoning-only at a
  short budget, record that as a budget/product row, not a forced close fix.
- Gemma 4 / Gemma3n: Gemma4 Harmony reasoning and Gemma tool calls must not
  leak markers. Gemma3n E2B text proof does not imply vision/audio proof.
- ZAYA / ZAYA-VL: default no-thinking stays off unless explicitly enabled.
  Current ZAYA direct-mode math evidence is not production-clear; do not hide
  it with sampler clamps. ZAYA-VL needs separate image and video rows.
- Nemotron Omni: default no-thinking for chat, explicit opt-in honored, audio
  and video payloads stay attached to the turn that supplied them, and
  pre-encoded Parakeet/RADIO paths do not poison text-only follow-ups.
- Ling/Hy3/Laguna/GLM/GPT-OSS/Mistral: settings must match the family parser
  and reasoning protocol rather than inheriting Qwen or DSV4 controls.

Saved settings migration checks:

1. Start with a Qwen reasoning model, enable thinking, quit/reopen, confirm the
   setting persists for the same model.
2. Switch to Ling or a non-reasoning profile, confirm stale Qwen thinking
   options are hidden or ignored and do not enter cache scope.
3. Switch to DSV4, set `max`, send one request, then switch away and back.
   Confirm `max` is preserved only for DSV4 and no other family sees that
   effort string.
4. Switch from a VLM chat to a text-only model, then back to VLM. Confirm media
   salt and cached media state do not carry across models or sessions.

## Media and Cache Turn Sequence

Run this exact sequence for every VLM/omni family that has a local bundle:

1. T1 image plus text: capture media token count, media salt, cache miss, TTFT,
   visible grounded answer, and no parser marker leakage.
2. T2 text-only same chat: capture media salt absent or nil, prefix/cache reuse
   where topology allows it, and visible answer grounded only in prior history.
3. T3 different image: capture different media salt and no reuse of the T1
   image cache state.
4. T4 unsupported media type: UI rejects before submit or API returns a clean
   structured error, not a hang or 500.
5. T5 restart app or unload/reload model: repeat T2/T3 and prove block L2 and
   path-dependent companion caches restore only when the cache key is valid.

For video, include frame count, resize target, EVS/effective prompt token
count, post-prepare cache key alias, and repeated-video cache hit proof. For
audio, include Parakeet/pre-encoded embedding evidence and live-voice chunk
stability when Nemotron Omni is resident.

## Architecture and Cache Topology Checklist

Every model row must declare which cache layers are expected to be active and
which layers are intentionally N-A. A missing counter is a failure unless the
model legitimately cannot exercise that layer.

| Architecture or feature | Default Osaurus behavior | Live proof required |
|---|---|---|
| Dense/global attention text | Prefix cache, paged cache, and block L2 disk default on when enabled by settings. | T2 prefix hit, paged block allocation or hit counter, L2 disk bytes/stores/hits, lower TTFT than T1. |
| Sliding-window attention | Engine-selected rotating/sliding cache, no app-forced global `maxKVSize`. | Health/settings show sliding-window topology; long prompt does not broadcast-shape crash; cache reuse remains coherent. |
| DSV4 Flash SWA+CSA+HSA | Native `DeepseekV4Cache`; generic paged counters may be zero when `pagedIncompatible=true`; generic KV q4/q8 and JIT disabled in UI. | Native DSV4 cache copy, fixed 256 block display row, pool quant visible, DSML tools, reasoning `instruct` and `max`, growing-chat disk restore. |
| Qwen VL / Qwen3.6 MTP VL | Qwen3VLProcessor, MRoPE/media salt, MTP only from `mtp.*` tensors plus `vmlx_mtp_tuning.json`. | Image+text, text-only media-salt nil, different image miss, video frame row, MTP on/off speed/coherence/cache row, status UI shows tuning depth. |
| Gemma4/Gemma3n | Gemma4 Harmony parser and Gemma VLM path; Gemma3n text proof does not imply media support. | Harmony reasoning separated, Gemma tool cards structured, image/video rows for Gemma4, Gemma3n media controls hidden unless live media proof exists. |
| ZAYA / ZAYA-VL CCA | ZayaCCACache/path-dependent CCA state; default no-thinking unless explicitly enabled. | CCA cache state present, image/video turns grounded, direct-mode red rows not hidden by sampler clamps, no stale thinking option from Qwen/DSV4. |
| Nemotron Omni | Parakeet audio encoder, RADIO vision, video/audio placeholders, media salt and SSM companion isolation. | Live voice pre-encode, audio/video/image/text-only resume, repeated-video cache alias, Parakeet/RADIO evidence, no reasoning-only short-budget false pass. |
| Hybrid SSM / linear attention | SSM companion cache and optional re-derive only when profitable for the workflow. | SSM hits/misses/stores, no KV-only unsafe hit, coherent multi-turn after prefix mismatch, re-derive status and TTFT captured. |
| JANG/JANGTQ/TurboQuant | Loader derives real bit metadata from bundle sidecars; no name-only MTP/JANGTQ claims. | JANG/JANGTQ format, TurboQuant KV encode/decode status when enabled, no shape-inferred metadata hidden from logs, no permanent overlay unless explicit diagnostic. |

## Per-Family UI/API Execution Matrix

This matrix is the real-user checklist for the Osaurus chat app and HTTP
routes. It exists so a future pass cannot say "VL works" or "reasoning works"
without showing the same behavior through UI selection, saved settings,
request construction, vmlx execution, cache stats, and visible output.

| Family or path | UI defaults and visual controls | Required chat UI proof | Required API proof | Cache and memory proof | Parser/tool/reasoning proof |
|---|---|---|---|---|---|
| DSV4 Flash | Reasoning default is `instruct`; `max` is selectable and passed unchanged as `reasoning_effort=max`; generic q4/q8 KV, JIT, MLLM, speculative, and generic block-size controls are hidden/disabled; pool quant and native cache copy are visible. | Select DSV4, inspect Chat Settings and Server Settings, run cold T1, follow-up T2, Stop/Retry, switch away/back, confirm no stale non-DSV4 reasoning setting persists. | `/v1/chat/completions`, `/v1/responses`, `/v1/messages` when mapped, and Ollama routes with DSML tools on/off and no sampler fields. | `DeepseekV4Cache`, SWA+CSA+HSA status, fixed 256 display row, pool quant, growing-chat/prefix behavior, TTFT, tok/s, RSS/physical footprint, and L2 disk bytes when valid. | DSML tool calls structured, `role=tool` result preserved, no DSML/instruct marker leakage, no forced think close, no hidden repetition/temperature guard. |
| Qwen VL / Qwen3.6 MTP VL | Qwen reasoning controls map to `enable_thinking`; no-thinking default applies where profile says so; VLM controls visible only when processor files exist; MTP visible only from real `mtp.*` tensors plus `vmlx_mtp_tuning.json`. | Image+text T1, text-only T2, different-image T3, video-frame row, MTP on/off selector/status where valid, save/relaunch and verify same-model settings only. | Chat completions and Responses stream/non-stream with media content parts, omitted sampler fields, explicit `chat_template_kwargs`, and native `top_k` from metadata. | Qwen3VLProcessor, MRoPE, media salt nil/absent on T2, different media miss, repeated media hit, prefix/paged/L2 stats, MTP depth/effective speed, tok/s and physical footprint. | `<think>` separated from visible content, Qwen tool XML parsed into structured `tool_calls`, tool result follow-up ordered correctly, no stale DSV4/Ling parser profile. |
| Gemma4 / Gemma VLM | Gemma4 Harmony reasoning controls only for Harmony-capable models; Gemma VLM/image controls visible only after real media capability detection; Gemma3n must not show media controls from text-only evidence. | Gemma4 image+text, text-only follow-up, video/image switch, settings save/reload, and code/math prompt with enough tokens to catch looping. | Chat completions, Responses, Anthropic when mapped, and tool-call row for Gemma parser with stream/non-stream. | Sliding-window/heterogeneous cache topology visible; no app-forced global `maxKVSize`; prefix/paged/L2 counters and long-prompt non-crash proof; RSS and TTFT. | Harmony analysis/final split preserved, Gemma tool cards structured, no Harmony/Gemma marker leakage, Gemma3n UTF drift remains red until root-caused. |
| ZAYA / ZAYA-VL | Default no-thinking unless explicitly enabled; ZAYA-VL media controls require real ZAYA VLM bundle; direct-mode red rows remain visible and are not hidden by sampler clamps. | ZAYA-VL image/video turns grounded, text-only resume, switch to text-only model and back, saved-thinking isolation, and visible speed/coherence row. | Chat completions and Responses stream/non-stream with media; tools only if parser capability is detected; no default tool parser guessed from marketing name. | ZayaCCACache/path-dependent media state, media salt/miss/hit, prefix/paged/L2 where topology allows, physical footprint, tok/s target watch, no cross-session CCA reuse. | No stale Qwen/DSV4 thinking setting, no CCA state attached to wrong media turn, no parser marker leakage, red incoherent row remains root-cause work. |
| Nemotron Omni / Parakeet / RADIO | Default no-thinking for normal chat; explicit opt-in honored; audio/video/image controls visible only when omni capability files and runtime path are present; live-voice status is separate from text-only readiness. | Audio/pre-encode T1, text-only T2, image/video T3 where supported, repeated-video/media hit, live streaming voice chunk stability, sleep/wake and resume. | Chat completions and Responses with media; `/v1/messages` thinking/tool-use when mapped; clean unsupported-media API error; no audio/video data dropped by adapters. | Parakeet pre-encode facts, RADIO/vision facts, media salt, repeated-media alias, SSM/path-dependent companion stats if applicable, disk bytes, TTFT, tok/s, physical footprint. | Nemotron tool parser structured, no Nemotron XML marker leakage, no reasoning-only short-budget false pass, audio/video placeholders cannot poison text-only follow-ups. |
| MiniMax | Reasoning UI visible for reasoning-capable MiniMax; MTP hidden unless real MTP tensors exist; no MTP claim from CRACK or name. | Multi-turn reasoning chat, tool-call card, save/relaunch, switch from DSV4/Qwen and verify no stale parser/reasoning field. | Chat completions/Responses tools on/off, second turn with tool result, streaming terminal usage. | Prefix/paged/L2/TurboQuant KV status when enabled, no permanent overlay, tok/s and footprint, cache-on/off inverse. | MiniMax reasoning channel kept out of visible text, MiniMax XML/JSON parser selected from base architecture, no forced close or repetition penalty. |
| Ling / Hy3 / hybrid SSM | Ling defaults thinking off but preserves explicit opt-in through `enable_thinking`; Hy3/Hunyuan controls match their parser; SSM re-derive policy shown as Osaurus disabled for mutating-prefix chat unless explicitly testing inverse. | Long-prompt T1, prefix-overlap T2, prefix-mismatch T3, stale Qwen thinking setting ignored, stop/retry and cancel cleanup. | Chat completions/Responses with tools on/off where supported; route-specific sampler defaults and native `top_k` preserved. | SSM companion hits/misses/stores, no KV-only unsafe hit, paged/L2 stats, re-derive status, TTFT, physical footprint. | GLM/Hunyuan/Ling markers do not leak; Ling reasoning stays on reasoning channel; tool result ordering preserved; no hidden non-thinking clamp beyond documented profile default. |
| GLM / GPT-OSS / Mistral / other parser families | Reasoning selector and tool parser must come from base architecture, not display name; unsupported controls hidden; coding prompt with tool schema injection shown only for tool-capable rows. | One UI row per local family with saved-setting isolation and enough output tokens to catch leak/loop. | Chat completions, Responses, Messages/Ollama where applicable, tool-result follow-up, explicit and omitted sampler fields. | Dense/sliding/hybrid cache topology declared as active or N-A, cache stats before/after, TTFT/tok/s/RSS. | Harmony, bracket-think, GLM/Hunyuan, Mistral, JSON, and tool-result sentinels never leak into visible content. |

## Settings Carryover and Cache-Key Failure Modes

These are explicit inverse rows, not nice-to-have manual notes:

1. Reasoning carryover: enable Qwen thinking, quit/reopen, switch to Ling or a
   non-reasoning row, and prove no `enable_thinking`, `reasoning_effort`, or
   stale reasoning parser enters the request or cache key.
2. DSV4 carryover: set DSV4 `max`, switch to a Qwen/Gemma/ZAYA/Nemotron row,
   then back to DSV4. Only DSV4 may retain `max`; other families must send
   their own native field or no field.
3. Media carryover: run VLM image+text, switch to a text-only model, then back.
   Text-only requests must have media salt absent and must not reuse media or
   path-dependent CCA/SSM state.
4. Cache mode carryover: disable prefix/paged/L2 for an inverse row, switch
   models, then re-enable. OFF must not silently alter sampler defaults; ON
   must restore hit counters, disk bytes, and topology-specific cache status.
5. Tool/coding context carryover: run a tool-capable coding prompt with tool
   schema injection and a second-turn tool result, switch to a no-tools row,
   and prove no tool schema, result marker, or tool parser profile leaks into
   visible content or cache scope.
6. Generation defaults: for every model row, compare UI defaults, HTTP omitted
   sampler fields, and vmlx resolved kwargs against `generation_config.json`
   and `jang_config.json`. Native `top_k` must apply when present, and absent
   values must fall through to engine defaults without family-specific guard
   floors.
7. Forced behavior audit: search source, settings previews, prompt dumps, and
   live output for forced sampler defaults, repetition penalties, reasoning rail
   rewrites, forced `</think>` close tokens, token/logit biasing, and parser
   output repair. Any hit must include a root-cause note explaining why it was
   built, an artifact proving whether it still affects the row, and a real fix
   path. Do not count a row green because the app reshaped the model output.

## Model Matrix

| Model path or family | Runtime class/topology | Current evidence | Required before production-clear |
|---|---|---|---|
| `/Users/eric/models/JANGQ/DeepSeek-V4-Flash-JANGTQ-K` | DSV4 Flash, SWA+CSA+HSA `DeepseekV4Cache`, DSML tools | vMLX main `76e55f59935f22c3bb2f28055ae8ecebd2e7a355` skips disk-backed path-dependent cache restore for active tool requests. Osaurus #1268 code-equivalent app build `695d5869` proof artifact `/tmp/osaurus-pr1268-ad233f70-dsv4-required-repeat-instruct-max256-20260528-085603`: 5/5 DSV4 JANGTQ2 required `line_count` repeats passed with explicit `reasoning_effort: "instruct"` and `max_tokens: 256`; each turn produced one structured tool call, exact `red\\ngreen\\nblue` args, no visible DSML leak, no reasoning leakage, no `_error`; topology showed 43 layers, 41 hybrid pool, 2 rotating, TurboQuant KV 0, disk L2 stores. Exact-head #1268 artifacts `/tmp/osaurus-pr1268-2455c4ce-dsv4-jangtq2-required-cache-cold-20260528-131817` and `/tmp/osaurus-pr1268-2455c4ce-dsv4-jangtq2-required-cache-warm-20260528-133223` prove JANGTQ2 multi-turn `line_count` exact args after tool history, no DSML/protocol leak, 43-layer hybrid-pool/rotating topology, and warm `disk_l2_hits +1`; timings remain slow. JANGTQ-K generic required-tool artifact `/tmp/osaurus-pr1268-50b38bc8-dsv4-jangtq-k-tool-cache-20260528-104417` is red with a length-stop reasoning loop and no DSML call. JANGTQ-K explicit-control artifact `/tmp/osaurus-pr1268-be665ebf-dsv4-jangtq-k-explicit-instruct-tool-20260528-105634` is green for one required `line_count` call with exact args and no DSML leak. Omitted max-token / omitted reasoning-control rows are documented as not green. | Final Osaurus UI renderer screenshot/log, `/v1/responses` and `/v1/messages` rows if mapped, DSV4 settings CLI preview, `reasoning_effort=max` app proof, JANGTQ-K multi-turn/cache repeat proof, speed work, and a decision/fix for omitted DSV4 reasoning controls. |
| `/Users/eric/models/dealign.ai/Qwen3.6-35B-A3B-JANGTQ-CRACK` | Qwen3.6 MoE VL, Qwen3VLProcessor, path-dependent cache | vmlx live prod/cache/VL/media-salt artifacts exist. | Osaurus app chat + API rows for image/text/video, reasoning on/off, generation defaults, saved settings, and cache stats. |
| `/Users/eric/models/JANGQ/Qwen3.6-27B-MXFP4-MTP` and MXFP8/35B variants | Qwen MTP/VL only when tensors plus `vmlx_mtp_tuning.json` are valid | vmlx source/tests require tuning and fail closed without it; fresh census proves 27B MXFP4 selects D2, 27B MXFP8/35B variants select D3, all from tensor/tuning evidence. Exact-head Osaurus artifacts `/tmp/osaurus-pr1268-d7b700ca-qwen27-mxfp4-crack-mtp-required-cache-cold-20260528-134548` and `/tmp/osaurus-pr1268-d7b700ca-qwen27-mxfp4-crack-mtp-required-cache-warm-20260528-134614` prove Qwen 27B MXFP4 CRACK MTP required multi-turn `line_count`, exact args, no protocol leak, 64-layer topology with 48 Mamba/SSM and 16 KV layers, and warm `disk_l2_hits +1`, `ssm_companion_hits +1`, `companion_hits +1`. Exact-head artifact `/tmp/osaurus-pr1268-380e7f96-qwen27-mxfp4-thinking-filetool-final-cache-2048-20260528-151216` proves Qwen Thinking final answers over file/tool history at explicit 2048 output budget with visible `stop` answers, no loop/leak/tool calls, and warm disk/SSM companion hits. | Osaurus status UI/API must show MTP off/on reason, use `vmlx_mtp_tuning.json`, and prove MTP on/off speed/coherence/cache rows. Original large-context UI screenshot behavior remains separate partial coverage. |
| `/Users/eric/models/dealign.ai/Gemma-4-26B-A4B-it-JANG_4M-CRACK` | Gemma4 VLM/Harmony reasoning/tool parser | vmlx parser/source contracts exist. | Live Osaurus image/text/video rows, Harmony no-leak API rows, Gemma settings defaults, and cache stats. |
| `/Users/eric/models/mlx-community/gemma-3n-E2B-it-4bit` | Gemma3n text row in current artifacts | vmlx production BatchEngine probe is partial: math/reasoning-on/off/cache rows are coherent at about 120 tok/s and ~2.7 GiB RSS with disk L2 hits/stores, but the UTF literal row fails at bundle defaults and greedy diagnostics. | Do not call Gemma3n production-clear until the UTF drift is root-caused. If exposed as VL/audio, add media rows first; otherwise UI must not overclaim media capability. |
| `/Users/eric/models/JANGQ/ZAYA1-VL-8B-JANGTQ4` and `/Users/eric/models/Osaurus/ZAYA1-VL-8B-MXFP4` | ZAYA-VL CCA/path-dependent cache | Source profiles default thinking off; ZAYA text direct-mode is currently not production-clear. Exact-head ZAYA text artifacts `/tmp/osaurus-pr1268-04dbc2cd-zaya-text-jangtq4-required-cache-cold-20260528-134803` and `/tmp/osaurus-pr1268-04dbc2cd-zaya-text-jangtq4-required-cache-warm-20260528-135005` prove required multi-turn `line_count`, exact args, no protocol leak, 80-layer topology with 40 KV and 40 CCA layers, and warm `disk_l2_hits +1`; CCA companion hits remain 0. | Separate ZAYA-VL media rows, CCA companion-hit depth, no stale thinking setting, speed target, and no sampler workaround. |
| `/Users/eric/models/dealign.ai/Nemotron-Omni-Nano-*` | Nemotron Omni text/image/audio/video, Parakeet/RADIO, media placeholders | Prior PR docs and vmlx artifacts cover structural paths with caveats. | Final Osaurus app/API audio/video/image/text-only resume rows, live voice resident pre-encode, repeated-video cache alias, and no reasoning-only short-budget false pass. |
| `/Users/eric/models/dealign.ai/MiniMax-M2.7-*` | MiniMax reasoning/tool parser, JANG/JANGTQ | vmlx fresh rows pass for some bundles; MTP must not be assumed from name. | Osaurus API tool result row, UI reasoning behavior, cache stats, and no visible reasoning leak. |
| `/Users/eric/models/dealign.ai/Ling-2.6-flash-*` | Bailing/Ling hybrid linear attention, GLM-style tools | vmlx fresh no-guard row passes; Osaurus source now defaults thinking off but honors explicit opt-in and keeps reasoning separate. | Osaurus UI/API no-thinking and opt-in rows, long-prompt TTFT/cache stats, and stale settings isolation. |
| `/Users/eric/models/JANGQ/Hy3-preview-*` | Hy3/Hunyuan reasoning/tools, hybrid cache | vmlx fresh row passes but cold TTFT remains a watch item. | Osaurus UI/API reasoning/tool rows, cache stats, and performance threshold review. |
| GLM/GPT-OSS/Mistral families when local | Harmony/think/bracket parser variants | Parser aliases are source-tested. | Live local model rows before claiming support in the switch PR. |

Kimi is intentionally excluded from this matrix for now per current scope.

## API and UI Completion Checklist

- `/v1/chat/completions`: stream and non-stream, text and media, tools on/off,
  reasoning on/off, terminal `[DONE]`, usage, and no marker leakage.
- `/v1/responses`: stream and non-stream, standard and reasoning, prior
  response/session continuity, same cache boundaries as chat.
- `/v1/messages`: Anthropic stream and non-stream for reasoning-capable rows,
  including thinking deltas and tool-use mapping when supported.
- `/api/chat` and `/api/generate`: Ollama stream and non-stream, correct tail
  frame, no hidden app-level sampler defaults.
- Chat UI: send/stop/retry/edit/copy, thinking panel collapse, tool-call card,
  image/video/audio attachment preview, unsupported-media rejection, token/s,
  TTFT, and terminal state.
- Server settings UI: host/port/auth, batching, prefix cache, paged cache, L2
  disk cache, sleep/wake, generation defaults, tool parser, reasoning parser,
  VLM force-off only when not auto-detected, and MTP status from tuning.
- Model switch: two simultaneous sessions with different models, same-model
  continuous batching, no cross-model cache poisoning, and saved settings scoped
  to the correct model family.

## Open Items

- Current #1268 boundary: the branch is pinned to vMLX main
  `d83b22b3d0350aa45b5b853dd4838ea34af47497`, open, not draft,
  mergeable, and not merged by agent. The live GitHub PR head can advance by
  documentation-only commits; always verify the current PR head and CI before
  merge instead of embedding a moving head SHA as final proof. Current-head
  proof artifacts are listed in the family rows above, including Nemotron
  MXFP4, DSV4 JANGTQ2, Qwen 27B MXFP4 CRACK MTP, and ZAYA text JANGTQ4. This
  is a consolidation boundary, not a blanket production-clear claim for every
  architecture row.
- The final Osaurus app has not yet run the full UI/API matrix for Qwen-VL,
  Gemma VLM, ZAYA-VL, Nemotron Omni, DSV4, MiniMax, Ling, Hy3, and the parser
  families listed above.
- Gemma3n E2B has a fresh vmlx production-path partial row: no loop in the
  math/cache turns, but a UTF literal prompt drifts into unrelated Chinese
  text. Treat it as an open runtime/tokenizer/template investigation, not a
  sampler-default workaround.
- DSV4 now has live Osaurus required-tool repeat proof from #1268 head
  `ad233f70` / code-equivalent app build `695d5869` with explicit
  `reasoning_effort: "instruct"` and `max_tokens: 256`:
  `/tmp/osaurus-pr1268-ad233f70-dsv4-required-repeat-instruct-max256-20260528-085603`.
  Five turns passed with exact multiline args, no visible DSML leak, no
  reasoning leakage, and resident DSV4 cache topology showing disk L2 stores.
  `/v1/responses` now has a focused non-streaming route proof at
  `/tmp/osaurus-pr1268-5f358de5-dsv4-responses-required-20260528-091946`:
  explicit `reasoning.effort: "instruct"`, explicit `max_output_tokens: 256`,
  one `function_call` output item for `line_count`, exact multiline args, and no
  visible DSML/tool-marker leak. Cache counters stayed zero in that row, so this
  proves Responses tool-parser parity only, not DSV4 disk-hit reuse.
  Streaming `/v1/responses` also has a focused route proof at
  `/tmp/osaurus-pr1268-7a7d2273-dsv4-responses-stream-required-20260528-093541`:
  reasoning summary events arrived before the final structured `function_call`,
  the final `line_count` arguments were exact, no DSML/tool-marker leak was
  visible, DSV4 topology stayed 43 layers / 41 hybrid-pool / 2 rotating /
  TurboQuant KV 0, and disk L2 stores moved `+1`. This proves streaming
  Responses event/tool parity and store behavior, not repeat disk-hit reuse.
  Responses tool-result follow-up repeat-cache proof is green at
  `/tmp/osaurus-pr1268-a1d101d6-dsv4-responses-tool-result-repeat-cache-clean-20260528-102858`:
  with DSV4 already resident, two identical `/v1/responses` tool-result
  follow-ups returned visible line-count answers, no extra function/tool item,
  no DSML/tool-marker leak, and each repeat produced `disk_l2_hits +1` with no
  new misses. This is a repeat disk-hit proof for the Responses tool-result
  follow-up surface only.
  `/v1/messages` now has a focused Anthropic-compatible route proof at
  `/tmp/osaurus-pr1268-7a7d2273-dsv4-messages-required-20260528-093706`:
  explicit `max_tokens: 256`, required `line_count` tool choice, HTTP 200, one
  `tool_use` content item, exact multiline args, `stop_reason: "tool_use"`, no
  visible DSML/tool-marker leak, and healthy resident DSV4 after the request.
  This proves Messages tool-parser parity only; disk L2 stores moved but this is
  not a repeat disk-hit proof.
  `/v1/messages` tool-result follow-up is also green at
  `/tmp/osaurus-pr1268-f7343290-dsv4-messages-tool-result-20260528-095315`:
  prior assistant `tool_use` plus user `tool_result` rendered correctly, the
  model answered `The line count is 3.`, `stop_reason: "end_turn"`, no extra
  tool call, no DSML/tool-marker leak, and resident DSV4 stayed healthy with
  the same 43-layer hybrid topology. This proves Messages tool-result follow-up
  parity, not repeat disk-hit reuse.
  Immediate repeat of the same Messages tool-result follow-up is green at
  `/tmp/osaurus-pr1268-80e87491-dsv4-messages-tool-result-repeat-cache-20260528-100913`:
  both turns answered `The line count is 3.`, no extra tool calls, no
  DSML/tool-marker leak, and turn 2 produced `disk_l2_hits +1` with no new
  misses. This is a repeat disk-hit proof for the Messages tool-result follow-up
  surface only.
  Two broader rows are explicitly not green: omitted `max_tokens` timed out and
  left lingering inflight requests
  (`/tmp/osaurus-pr1268-695d5869-dsv4-required-repeat-20260528-084132`), and
  omitted DSV4 reasoning controls produced one whitespace-drift tool argument
  plus one reasoning-to-length turn
  (`/tmp/osaurus-pr1268-ad233f70-dsv4-required-repeat-max256-20260528-085227`).
  The active tool path intentionally produced disk stores but no disk hits after
  vMLX `76e55f5`, because disk-backed path-dependent restore is skipped for
  active tool requests. The final settings renderer still needs visible UI/CLI
  evidence and `reasoning_effort=max` app proof.
- ZAYA text direct mode remains a real red row. Do not call ZAYA production
  clear until the prompt/runtime issue is root-caused or the product explicitly
  defaults to a proven coherent mode without a hidden sampler/parser fix.
- Gemma4 JANG_4M has a follow-up green required-tool/history row via the
  Gemma-family `enable_thinking=false` local API default:
  `/tmp/osaurus-pr1268-gemma-default-gemma4-jang4m-tool-cache-repeat-20260528-112822`.
  This fixes the prior `thought<tool_call|>` row without parser output repair,
  but explicit thinking mode, media/video, Gemma3n, and sibling coverage remain
  separate.
- Nemotron Omni video/audio cache behavior has focused and live vmlx evidence,
  but Osaurus app/API rows still need to prove the same path through ChatView,
  HTTP adapters, saved settings, and cache stats.
- This matrix should be updated with artifact paths as each live row is run.
