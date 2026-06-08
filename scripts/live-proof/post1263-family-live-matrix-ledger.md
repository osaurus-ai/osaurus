# Post-1263 production family live matrix ledger

This ledger tracks the follow-on production matrix work after the Gemma reasoning-tool routing PR head.
It is intentionally live-proof oriented: source tests are useful, but a row is not promoted unless the no-sign Osaurus app path proves chat/tool/cache behavior.

## Required proof shape

Each promoted row needs current-head evidence for:

- no-sign Release app path and commit head
- model id from `/v1/models`
- multi-turn chat through `/v1/chat/completions`
- required `line_count` tool call with exact multiline arguments on turn 1
- tool-result follow-up with visible answer and no protocol leak
- second required `line_count` tool call with exact multiline arguments after assistant/tool history
- no raw family protocol leakage in `content` or `reasoning_content`
- token/s recorded for generation turns, or explicitly recorded as unavailable/zero-token tool turn
- `/admin/cache-stats` topology captured for the model
- architecture-specific cache evidence, not generic load success

## Architecture cache requirements

- Full KV models: prefix/L2 disk reuse; `engineSelected` may choose TurboQuant KV by default only for proven/simple full-KV topology rows and must record the effective KV mode.
- Qwen/Ling/Nemotron hybrid SSM/Mamba: KV plus SSM/companion state proof; TurboQuant KV is not a substitute.
- ZAYA/CCA/VL: CCA companion/pooling proof, VL media payload where applicable, and cache salt isolation.
- DSV4: CSA/HSA/SWA hybrid-pool topology plus disk restore/hit proof; TurboQuant KV is not a substitute.
- Gemma rotating/SWA: rotating topology plus disk restore/reuse proof; no Zyphra/Gemma XML leak from reasoning or content.
- HY3/Hunyuan/MiMo-style SWA/CCA paths: run only against an actual local model id and require topology-specific companion or SWA proof.
- MiMo V2.5: expected source topology is 9 full-attention KV layers plus 39 SWA rotating layers. Prefix/L2 disk proof is required; TurboQuant KV is allowed only for full-attention `KVCacheSimple` layers when explicitly enabled and must not replace SWA rotating state.

## Historical starting boundary

- Base head at creation: `3b2a4f38fdbc08d5a195cf40689414dc469ab5f2`.
- vMLX pin at creation: `531439a05bb3c5334aa551a07481fc5234644329`.
- MiMo-aware vMLX pin once staged for this branch: `d69a12168fe6d5c89cb2756ca478f0ea7e18c7d3`.
- PR `#1266` head after ZAYA VL history-media fix: `229e51fdbc1adb282f4e861ba4ce1209befe480b`.
- vMLX pin after ZAYA VL history-media fix: `0c39f5a8bd68b5316f5e56e5bd94cc67b8fe8704`.
- `#1263` is still open on GitHub at creation time; this PR is stacked rather than post-merge until GitHub state changes.
- Do not merge by agent.
- Do not apply forced-behavior fixes, hidden sampler overrides, forced thinking/tool wrappers, or broad parser masks to make rows look green.

## Current #1268 merge boundary

### 2026-05-28 10:28 PDT Nemotron Omni MXFP4 live red row

- Current Osaurus PR head checked before this row: `a1d101d6f22dfff41052c1af33975c25663175cd`; CI was green for `shellcheck`, `swiftlint`, `test-cli`, `test-core`, and `update_release_draft` before this documentation update.
- No-sign app path: `build/DerivedData-pr1268-release-nosign-695d5869/Build/Products/Release/osaurus.app`; app was healthy and cache counters were reset before the run.
- Cold artifact: `/tmp/osaurus-pr1268-a1d101d6-nemotron-omni-mxfp4-tool-cache-20260528-102745`.
  - `nemotron-omni-nano-mxfp4-crack` turn 1 returned one structured `line_count` call with exact `red\ngreen\nblue` arguments and no visible protocol leak.
  - Turn 2 returned visible answer `Three lines were counted.` with no extra tool call and no protocol leak.
  - Turn 3 returned one structured `line_count` call with exact `one\ntwo` arguments and no visible protocol leak.
  - Cache topology showed 29 layers, 6 KV layers, 23 Mamba/SSM layers, `requires_ssm_companion_state: true`, `companion=ssm`, TurboQuant KV layer count 0, and disk-backed restore required.
  - This cold row still failed strict cache promotion because disk L2 hits stayed 0 while misses/stores moved.
- Immediate repeat artifact: `/tmp/osaurus-pr1268-a1d101d6-nemotron-omni-mxfp4-tool-cache-repeat-20260528-102806`.
  - Turn 1 and turn 2 repeated the structured tool call and visible answer behavior.
  - Turn 3 failed: `tool_choice: "required"` returned visible content `Two lines were counted.` with `finish_reason: "stop"` instead of a structured `tool_calls` finish.
  - All three repeat responses reported the same `prefix_hash` even though prompt history changed.
  - The after-snapshot had no Nemotron model cache entry and no requested model resident, so repeat topology/cache evidence is not green.
- Verdict: Nemo/Nemotron Omni MXFP4 is red/partial for repeat required-tool/cache behavior. Do not fix this with prompt coercion or synthetic required-tool system text; root-cause the template/cache/tool-choice path.

### 2026-05-28 10:34 PDT ZAYA text JANGTQ4 live red row

- Current Osaurus PR head checked before this row: `c9fdc4c38ee53f748805d89c0312a9c61ecf1662`.
- No-sign app path: `build/DerivedData-pr1268-release-nosign-695d5869/Build/Products/Release/osaurus.app`.
- Artifact: `/tmp/osaurus-pr1268-c9fdc4c3-zaya-text-jangtq4-tool-cache-20260528-103322`.
- `zaya1-8b-jangtq4` turn 1 returned one structured `line_count` call with exact `red\ngreen\nblue` arguments and no visible protocol leak.
- Turn 2 returned visible answer `3 lines were counted.` with no extra tool call and no protocol leak.
- Turn 3 returned a structured `line_count` call with no visible protocol leak, but the argument was ` ... ` instead of exact `one\ntwo`.
- Cache topology showed 80 layers, 40 KV layers, 40 ZAYA CCA layers, `companion=zaya-cca`, `requires_disk_backed_restore: true`, `requires_ssm_companion_state: true`, and TurboQuant KV layer count 0.
- This row failed strict promotion because `turn3_args_exact` was false and disk L2 hits stayed 0 while misses/stores moved.
- Verdict: ZAYA text JANGTQ4 is red/partial for multi-turn required-tool argument fidelity and repeat L2 reuse. Do not hide the ` ... ` argument with parser repair; root-cause template/history/cache behavior.

### 2026-05-28 10:35 PDT Ling JANGTQ2 live parser/tool green, cache partial row

- Current Osaurus PR head checked before this row: `3a46be1f783a504aac284c489ed81f34d34d0809`.
- No-sign app path: `build/DerivedData-pr1268-release-nosign-695d5869/Build/Products/Release/osaurus.app`.
- Artifact: `/tmp/osaurus-pr1268-3a46be1f-ling-jangtq2-tool-cache-20260528-103538`.
- `ling-2.6-flash-jangtq2-crack` turn 1 returned one structured `line_count` call with exact `red\ngreen\nblue` arguments and no visible protocol leak.
- Turn 2 returned visible answer `The tool counted 3 lines.` with no extra tool call and no protocol leak.
- Turn 3 returned one structured `line_count` call with exact `one\ntwo` arguments and no visible protocol leak.
- Cache topology showed 32 layers, 4 KV layers, 28 arrays/SSM layers, `companion=ssm`, disk-backed restore required, and TurboQuant KV layer count 0.
- This row is green for parser/tool/history behavior but still cache-partial because disk L2 hits stayed 0 while misses/stores moved.

### 2026-05-28 10:37 PDT MiniMax M2.7 small JANGTQ live green row

- Current Osaurus PR head checked before this row: `0bba84c9bc8d1b60a872d29bd28e9af3aee586dd`.
- No-sign app path: `build/DerivedData-pr1268-release-nosign-695d5869/Build/Products/Release/osaurus.app`.
- Artifact: `/tmp/osaurus-pr1268-0bba84c9-minimax-small-jangtq-tool-cache-20260528-103659`.
- `minimax-m2.7-small-jangtq` turn 1 returned one structured `line_count` call with exact `red\ngreen\nblue` arguments and no visible protocol leak.
- Turn 2 returned visible answer `There were three lines counted.` with no extra tool call and no protocol leak.
- Turn 3 returned one structured `line_count` call with exact `one\ntwo` arguments and no visible protocol leak.
- Cache topology showed 62 full-KV layers, no SSM/CCA companion requirement, disk L2 hit `+1`, disk L2 misses `+5`, disk L2 stores `+3`, and TurboQuant KV layer count 0.
- Verdict: MiniMax M2.7 small JANGTQ is green for this parser/tool/history/cache row. Sibling JANG/JANGTQ-K and speed/RAM rows still need separate proof.

### 2026-05-28 10:38 PDT Gemma4 JANG_4M live red row

- Current Osaurus PR head checked before this row: `213d0ffd823a4c61181b308aa6b5c24a2fd4b194`.
- No-sign app path: `build/DerivedData-pr1268-release-nosign-695d5869/Build/Products/Release/osaurus.app`.
- Artifact: `/tmp/osaurus-pr1268-213d0ffd-gemma4-jang4m-tool-cache-20260528-103834`.
- `gemma-4-26b-a4b-it-jang_4m-crack` turn 1 failed required-tool behavior: `finish_reason` was `stop`, visible content was empty, and `reasoning_content` was `thought<tool_call|>` instead of a structured `tool_calls` response.
- Cache topology was still detected correctly: 30 layers, 5 KV layers, 25 rotating KV layers, disk-backed restore required, TurboQuant KV layer count 0.
- This row failed before tool-result history could be tested, and disk L2 hits stayed 0.
- Verdict: Gemma4 JANG_4M is red for required-tool parser/output behavior on this app/API row. Do not hide this with reasoning parser output repair or forced close-token biasing.

### 2026-05-28 10:40 PDT Qwen 27B MXFP4 CRACK MTP live parser/tool green, cache partial row

- Current Osaurus PR head checked before this row: `2ac8d31f87f4d82ab9de9f8e4188bdab8800bb71`.
- No-sign app path: `build/DerivedData-pr1268-release-nosign-695d5869/Build/Products/Release/osaurus.app`.
- Artifact: `/tmp/osaurus-pr1268-2ac8d31f-qwen27-mxfp4-crack-mtp-tool-cache-20260528-103947`.
- `qwen3.6-27b-mxfp4-crack-mtp` turn 1 returned one structured `line_count` call with exact `red\ngreen\nblue` arguments and no visible protocol leak.
- Turn 2 returned visible answer `3 lines were counted.` with no extra tool call and no protocol leak.
- Turn 3 returned one structured `line_count` call with exact `one\ntwo` arguments and no visible protocol leak.
- Cache topology showed 64 layers, 16 KV layers, 48 Mamba/SSM layers, `companion=ssm`, disk-backed restore required, and TurboQuant KV layer count 0.
- This row is green for parser/tool/history behavior but cache-partial because disk L2 hits stayed 0 while misses/stores moved.

### 2026-05-28 10:41 PDT ZAYA-VL JANGTQ4 red image media/cache green row

- Current Osaurus PR head checked before this row: `b780e33737cbf51d3045c97c694a8ee7104caebb`.
- No-sign app path: `build/DerivedData-pr1268-release-nosign-695d5869/Build/Products/Release/osaurus.app`.
- Artifact: `/tmp/osaurus-pr1268-b780e337-zaya-vl-jangtq4-red-media-cache-20260528-104101`.
- Harness generated a real 64x64 red PNG and sent it as an OpenAI image content part.
- First response was `Red`, `finish_reason: "stop"`, no protocol leak, token rate about 0.155 tok/s.
- Repeat response was `Red`, stable `prefix_hash`, no protocol leak, token rate about 2.30 tok/s.
- Cache topology showed 40 ZAYA CCA layers, `companion=zaya-cca`, disk-backed restore required, TurboQuant KV layer count 0.
- Repeat cache counters showed disk L2 hit `+1`; ZAYA CCA companion miss `+1` was recorded, so companion-hit depth remains partial even though media repeat L2 proof is green.

### 2026-05-28 10:52 PDT DSV4 JANGTQ-K live red row

- Current Osaurus PR head checked before this row: `50b38bc8b2b4b4ee8b639d16c798de19782cc75d`.
- No-sign app path: `build/DerivedData-pr1268-release-nosign-695d5869/Build/Products/Release/osaurus.app`.
- Artifact: `/tmp/osaurus-pr1268-50b38bc8-dsv4-jangtq-k-tool-cache-20260528-104417`.
- `deepseek-v4-flash-jangtq-k` turn 1 took 517.5 seconds and ended with `finish_reason: "length"` instead of a structured tool call.
- Visible content was empty, but `reasoning_content` looped over line-count interpretation of `red\ngreen\nblue` and never emitted DSML.
- Cache topology was still detected correctly: 43 layers, 41 hybrid-pool layers, 2 rotating KV layers, disk-backed restore required, TurboQuant KV layer count 0.
- This row failed before tool-result history could be tested, and disk L2 hits stayed 0.
- Verdict: DSV4 JANGTQ-K is red under the generic required-tool harness. DSV4 JANGTQ2 remains the green production proof row under explicit `reasoning_effort: instruct` and `max_tokens: 256`; do not infer sibling readiness.

### 2026-05-28 10:57 PDT DSV4 JANGTQ-K explicit instruct tool-call green row

- Current Osaurus PR head checked before this row: `be665ebf425104bd52e5b02cbe823080f7bf64ed`.
- No-sign app path: `build/DerivedData-pr1268-release-nosign-695d5869/Build/Products/Release/osaurus.app`.
- Artifact: `/tmp/osaurus-pr1268-be665ebf-dsv4-jangtq-k-explicit-instruct-tool-20260528-105634`.
- Request used `reasoning_effort: "instruct"`, `max_tokens: 256`, `tool_choice: "required"`, and the `line_count` schema.
- Result: one structured `line_count` tool call with exact `red\ngreen\nblue` arguments, `finish_reason: "tool_calls"`, no visible content, and no DSML/protocol leak.
- Verdict: DSV4 JANGTQ-K is green for a single explicit-control required-tool call, while the generic required-tool harness remains red and multi-turn/cache repeat proof is still incomplete for this sibling.

### 2026-05-28 10:09 PDT current coordination boundary

- Current Osaurus PR: `#1268`, head `80e8749144d50b9783c5cc37a84b1cb03b8fdfa4`, open, not draft, mergeable, not merged by agent.
- Current vMLX main and Osaurus pin: `76e55f59935f22c3bb2f28055ae8ecebd2e7a355`; verified local vMLX worktree and `osaurus-ai/vmlx-swift` main match.
- GitHub checks on `80e87491`: `shellcheck`, `swiftlint`, `test-cli`, `test-core`, and `update_release_draft` all passed.
- Only `#1268` remains open from the `#1247` through `#1268` runtime stack. Keep Osaurus fixes in this one PR until the user manually merges it.
- Source cache policy remains `engineSelected` with topology gating: prefix cache, paged KV, block-disk L2, and SSM rederive default on; proven simple full-KV rows may use TurboQuant KV by default, while DSV4, ZAYA/ZAYA-VL, Gemma rotating, Qwen/Ling/Nemotron/HY3-style hybrid and CCA/SSM/path-dependent rows stay native/fp16 unless exact topology proof promotes them.
- Current no-sign app observation: `build/DerivedData-pr1268-release-nosign-695d5869/Build/Products/Release/osaurus.app` is healthy with `deepseek-v4-flash-jangtq2` resident, no in-flight requests, and DSV4 cache topology still 43 layers / 41 hybrid-pool / 2 rotating / TurboQuant KV 0.
- Fresh DSV4 `/v1/messages` tool-result repeat-cache artifact: `/tmp/osaurus-pr1268-80e87491-dsv4-messages-tool-result-repeat-cache-20260528-100913`. Two repeated tool-result follow-up requests returned visible answer `The line count is 3.`, `stop_reason: "end_turn"`, no extra tool call, and disk L2 hits moved from 0 to 1 on the second turn. This proves Messages tool-result follow-up repeat L2 reuse for this surface only; Responses repeat-cache and active-tool DSV4 repeat-cache coverage remain partial.
- Fresh DSV4 `/v1/responses` tool-result repeat-cache artifact: `/tmp/osaurus-pr1268-a1d101d6-dsv4-responses-tool-result-repeat-cache-clean-20260528-102858`. With DSV4 already resident, two repeated Responses tool-result follow-up requests returned visible line-count answers, no function/tool item, no DSML/tool-marker leak, and disk L2 hits moved `+1` on each repeat with no new misses. This proves Responses tool-result follow-up repeat L2 reuse for this surface only; active-tool DSV4 repeat-cache coverage and omitted-control rows remain partial.
- No agent should merge Osaurus without explicit user approval. vMLX main is managed directly and contains the runtime fixes consumed by this PR.

### 2026-05-28 09:03 PDT checked proof boundary

- Current Osaurus PR: `#1268`, open, not draft, mergeable, not merged by agent. The checked code/proof boundary is Osaurus app build `695d5869ea9821732649bffb3789469568e6db55` plus documentation correction `8d3ce5d15156e5c6a5dc3f04601b02442dfd2c3a`; verify the live GitHub PR head and CI before merge because documentation-only commits can advance after this line.
- Current vMLX main and Osaurus pin: `76e55f59935f22c3bb2f28055ae8ecebd2e7a355`; verified present on `osaurus-ai/vmlx-swift` main.
- Current CI must be checked on the live PR head; do not reuse older green-status lines after another documentation-only head commit.
- Code-equivalent no-sign/keychain-free app from `695d5869` launched at `build/DerivedData-pr1268-release-nosign-695d5869/Build/Products/Release/osaurus.app` and `/health` returned healthy with `OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1`.
- Final source guard on `695d5869` passed: migrated cache defaults use `liveKVCodec: .engineSelected`, `ModelRuntime.shouldUseTurboQuantByDefault` remains the topology gate, and DSV4/ZAYA/ZAYA-VL/hybrid topologies are not defaulted into generic TurboQuant KV.
- Final source policy keeps the no-forced-behavior contract: no DSV4 hidden repetition-penalty doc, no forced sampler defaults, no parser output repair, no forced reasoning tags, and required/named local tool choice still flows through the template context.
- DSV4 required-tool proof that is green: `/tmp/osaurus-pr1268-ad233f70-dsv4-required-repeat-instruct-max256-20260528-085603`, five turns, explicit `reasoning_effort: "instruct"`, explicit `max_tokens: 256`, exact multiline args, no visible DSML leak, no reasoning leakage, resident model, disk L2 stores.
- DSV4 `/v1/responses` required-tool proof that is green: `/tmp/osaurus-pr1268-5f358de5-dsv4-responses-required-20260528-091946`, non-streaming Responses request, explicit `reasoning.effort: "instruct"`, explicit `max_output_tokens: 256`, exactly one `function_call` output item for `line_count`, exact multiline args, no visible DSML/tool-marker leak, and healthy resident DSV4 after the request. This row proves Responses route/tool-parser parity only; cache counters stayed at zero, so it is not a DSV4 disk-hit proof.
- DSV4 `/v1/responses` streaming required-tool proof that is green: `/tmp/osaurus-pr1268-7a7d2273-dsv4-responses-stream-required-20260528-093541`, streaming Responses request, explicit `reasoning.effort: "instruct"`, explicit `max_output_tokens: 256`, reasoning summary events emitted before the final structured `function_call`, final `line_count` arguments exactly `red\ngreen\nblue`, no visible DSML/tool-marker leak, DSV4 topology stayed 43 layers / 41 hybrid-pool / 2 rotating / TurboQuant KV 0, and disk L2 stores moved `+1`. This proves streaming Responses tool-parser/event parity and store behavior, not repeat disk-hit reuse.
- DSV4 `/v1/responses` tool-result follow-up repeat-cache proof that is green: `/tmp/osaurus-pr1268-a1d101d6-dsv4-responses-tool-result-repeat-cache-clean-20260528-102858`, two identical Responses tool-result follow-up requests, both HTTP 200 with visible line-count answers, no extra function/tool item, no visible DSML/tool-marker leak, DSV4 topology stayed 43 layers / 41 hybrid-pool / 2 rotating / TurboQuant KV 0, and each repeat produced `disk_l2_hits +1` with no new disk L2 misses. This is a repeat disk-hit proof for the Responses tool-result follow-up surface only.
- DSV4 `/v1/messages` required-tool proof that is green: `/tmp/osaurus-pr1268-7a7d2273-dsv4-messages-required-20260528-093706`, Anthropic-compatible Messages request, explicit `max_tokens: 256`, required `line_count` tool choice, HTTP 200, exactly one `tool_use` content item, exact multiline args, `stop_reason: "tool_use"`, no visible DSML/tool-marker leak, and healthy resident DSV4 after the request. This row proves Messages route/tool-parser parity only; disk L2 stores moved but this is not a repeat disk-hit proof.
- DSV4 `/v1/messages` tool-result follow-up proof that is green: `/tmp/osaurus-pr1268-f7343290-dsv4-messages-tool-result-20260528-095315`, prior assistant `tool_use` plus user `tool_result`, HTTP 200, visible answer `The line count is 3.`, `stop_reason: "end_turn"`, no extra tool call, no visible DSML/tool-marker leak, and healthy resident DSV4 after the request. This row proves Messages tool-result follow-up parity only; disk L2 stores/misses moved but this is not a repeat disk-hit proof.
- DSV4 `/v1/messages` tool-result follow-up repeat-cache proof that is green: `/tmp/osaurus-pr1268-80e87491-dsv4-messages-tool-result-repeat-cache-20260528-100913`, two identical Messages tool-result follow-up requests, both HTTP 200 with visible answer `The line count is 3.`, `stop_reason: "end_turn"`, no extra tool call, no visible DSML/tool-marker leak, and turn 2 produced `disk_l2_hits +1` with no new disk L2 misses. This is a repeat disk-hit proof for the Messages tool-result follow-up surface only.
- DSV4 rows that are not green: `/tmp/osaurus-pr1268-695d5869-dsv4-required-repeat-20260528-084132` timed out on turns 4-5 without `max_tokens` and left lingering inflight requests; `/tmp/osaurus-pr1268-ad233f70-dsv4-required-repeat-max256-20260528-085227` had one whitespace-drift tool argument and one `finish_reason: length` reasoning turn when DSV4 reasoning controls were omitted.
- This is a checked consolidation boundary, not a blanket production-clear claim for every architecture row. Nemo Omni audio/video, HY3/Hunyuan import/live rows, Ling long-prompt/runtime crash work, ZAYA CCA companion-hit depth, `/v1/responses`/`/v1/messages` parity, UI screenshots, full saved-settings carryover, and omitted-reasoning DSV4 behavior remain follow-on matrix work unless fixed in this PR.
- No agent should merge Osaurus without explicit user approval. vMLX main is managed directly and contains the runtime fixes consumed by this PR.

### 2026-05-28 07:20 PDT final PR merge boundary

- Current Osaurus PR: `#1268`, head `13f7fd9455006d55242d77375a5c9dcf2841266c`, open, not draft, mergeable, not merged by agent.
- Current vMLX main and Osaurus pin: `cc3f5f4dc1317ffa09c46050ba0847f495887747`; verified present on `osaurus-ai/vmlx-swift` main.
- GitHub checks on `13f7fd94`: `shellcheck`, `swiftlint`, `test-cli`, `test-core`, and `update_release_draft` all passed.
- Final local source/hygiene guard on `13f7fd94` passed: keychain-free proof path, no hidden sampler defaults, no forced behavior, OpenResponses/cache wiring, server-settings runtime wiring, reasoning routing, HTTP cancellation, required tool-choice routing, model tool/capability surfaces, vMLX pin/checkout readiness, and PR artifact hygiene.
- Final no-sign/keychain-free app from `13f7fd94` launched at `build/DerivedData-pr1268-release-nosign-13f7fd94/Build/Products/Release/osaurus.app` and `/health` returned healthy.
- Gemma3n required-tool handling is a support-boundary fix, not a promotion: vMLX no longer infers tool support from Gemma3n `model_type`, and Osaurus blocks known unsupported Gemma3n tool requests before decode.
- Default cache policy is `engineSelected` with topology gating: proven simple full-KV rows may default to TurboQuant KV; DSV4, ZAYA/ZAYA-VL, Gemma rotating, and hybrid SSM/companion-cache rows stay native/fp16 unless explicitly overridden or separately proven safe.
- No agent should merge Osaurus without explicit user approval. vMLX main is managed directly and contains the runtime fixes consumed by this PR.

### 2026-05-28 06:16 PDT runtime-proof boundary

- Current Osaurus PR: `#1268`, open, not draft, mergeable, not merged by agent.
- Current vMLX main and Osaurus pin: `cc3f5f4dc1317ffa09c46050ba0847f495887747`; verified present on `osaurus-ai/vmlx-swift` main.
- Runtime-proof head `2a2a6d4b039e61fd9338c42287fa9b35798328cb`: `shellcheck`, `swiftlint`, `test-cli`, `test-core`, and `update_release_draft` all passed.
- Only `#1268` remains open from the `#1247` through `#1268` runtime stack; older related PRs are consolidated/superseded rather than separate merge targets.
- No-sign/keychain-free DSV4 app proof is recorded in `POST1266-LIVE-FAMILY-CACHE-MATRIX.md` for the `1503be2f` runtime commit that sits directly below the documentation-only proof boundary.
- Source guards passed after the documentation-only proof boundary: PR hygiene, vMLX pin/checkout readiness, keychain-free proof path, no hidden sampler defaults, no forced behavior, OpenResponses/cache wiring, server-settings runtime wiring, reasoning routing, HTTP cancellation, required tool-choice routing, and model tool/capability surfaces.
- Default cache policy is `engineSelected` with topology gating: proven full-KV rows may default to TurboQuant KV; DSV4, ZAYA/ZAYA-VL, Gemma rotating, and hybrid SSM/companion-cache rows stay native/fp16 unless explicitly overridden or separately proven safe.
- No agent should merge Osaurus without explicit user approval. vMLX main is managed directly and contains the runtime fixes consumed by this PR.

### Historical boundary notes

- Current Osaurus PR: `#1268`, head `395cc49479101fc0a9e0fa01d4ce25095c55dfa6` before this ledger-only correction.
- Current vMLX main and Osaurus pin: `de07006a2426f482d3c16adea5644c0803efb2cd`.
- GitHub status at 2026-05-28 03:22 PDT for head `395cc494`: PR open, not draft, mergeable, not merged; `shellcheck`, `swiftlint`, `test-cli`, and `update_release_draft` passed; `test-core` was still running at the time of this ledger update.
- Only `#1268` remains open from the `#1247` through `#1268` runtime stack; older related work has been consolidated rather than kept as separate merge targets.
- Exact-head no-sign Release app proof is refreshed for `395cc494`: `/Users/eric/osaurus-pr1268-live/build/DerivedData-pr1268-release-nosign-395cc494/Build/Products/Release/osaurus.app`, built with signing disabled and vMLX checkout `de07006a2426f482d3c16adea5644c0803efb2cd`.
- Exact-head source guard is refreshed for `395cc494`: `RuntimePolicySourceTests/vmlxPinIncludesRuntimeHardening` passed against the vMLX main pin `de07006a2426f482d3c16adea5644c0803efb2cd`.
- Focused vMLX proof for the open DSV4 action-rail fix passed before repin: `DeepseekV4ChatTemplateFallbackFocusedTests` ran 29 tests with 0 failures against vMLX `bd6c6808`.
- Exact-head no-sign live model proof is intentionally not promoted as complete for every family on `86304f7e`. Nemo Omni, Ling, ZAYA, DSV4, Qwen, MiniMax, and HY3/Hunyuan need follow-on exact-head rows before claiming the broader post-merge runtime matrix is complete.
- MiMo V2.5 is explicitly excluded from the current merge gate because the current local MiMo lane is not working/imported enough for a meaningful Osaurus live row.
- TurboQuant/`engineSelected` is the default live-KV policy, but it is resolved per loaded model topology rather than applied globally. Proven full-KV rows may default to TurboQuant KV; DSV4, ZAYA/ZAYA-VL, Gemma rotating, and hybrid SSM/companion-cache rows stay native/fp16 unless explicitly overridden or separately proven safe.
- No agent should merge Osaurus without explicit user approval. vMLX main is managed directly and already contains the no-forced-thinking fix required by this PR.

## Row status ledger

| Row | Status | Artifact | Notes |
| --- | --- | --- | --- |
| Gemma 4 26B JANG_4M | #1268 current-head API pass, rotating-KV topology proven | current row `/tmp/osaurus-pr1268-5442b551-gemma4-jang4m-required-tool-20260528-032556`; old row `/tmp/osaurus-pr1263-3b2a4f38-gemma4-current-head-proof-20260527-074030/SUMMARY.json` | current row used no-sign Release app runtime-equivalent to `5442b551` pinned to vMLX main `bd6c6808`. Turn 1 exact required `line_count` args `red\ngreen\nblue`, `content=null`, no protocol leak; turn 2 visible `Three lines were counted.`, finish `stop`, no historical `!!!!!!!!`/loop behavior; turn 3 exact required `line_count` args `one\ntwo` after assistant/tool history. Cache topology captured: 30 layers, 5 KV, 25 rotating KV, disk-backed restore required, TurboQuant KV 0. |
| Nemo Omni MXFP4 | warm pass | `/tmp/osaurus-pr1264-c66a0913-nemotron-mxfp4-warm-20260527-075223/SUMMARY.json` | exact multi-turn `line_count`, no assistant-header/protocol leak, `disk_l2_hits +3`, `ssm_companion_hits +3`, 29 layers with 6 KV + 23 Mamba, TurboQuant KV 0 |
| Nemo Omni JANGTQ | #1268 current-head API pass, SSM topology proven | current row `/tmp/osaurus-pr1268-5442b551-nemotron-omni-jangtq-required-tool-20260528-032357`; old warm row `/tmp/osaurus-pr1264-c66a0913-nemotron-jangtq-warm-20260527-075247/SUMMARY.json` | current row used no-sign Release app runtime-equivalent to `5442b551` pinned to vMLX main `bd6c6808`. Turn 1 exact required `line_count` args `red\ngreen\nblue`, `content=null`, no assistant-header/protocol leak; turn 2 visible `Three lines were counted.`, finish `stop`, no loop; turn 3 exact required `line_count` args `one\ntwo` after assistant/tool history. Cache topology captured: 29 layers, 6 KV, 23 Mamba/SSM layers, `companion=ssm`, disk-backed restore required, TurboQuant KV 0. |
| Nemo Omni JANGTQ4 | warm pass | `/tmp/osaurus-pr1264-c66a0913-nemotron-jangtq4-warm-20260527-075313/SUMMARY.json` | exact multi-turn `line_count`, no assistant-header/protocol leak, `disk_l2_hits +3`, `ssm_companion_hits +3`, 29 layers with 6 KV + 23 Mamba, TurboQuant KV 0 |
| Ling JANGTQ2 | #1268 current-head API pass, SSM cache-hit proof | current row `/tmp/osaurus-pr1268-5442b551-ling-jangtq2-required-tool-20260528-032430`; old row `/tmp/osaurus-pr1264-009688d3-ling-jangtq2-20260527-075413/SUMMARY.json` | current row used no-sign Release app runtime-equivalent to `5442b551` pinned to vMLX main `bd6c6808`. Turn 1 exact required `line_count` args `red\ngreen\nblue`, `content=null`, no protocol leak; turn 2 visible `The text was counted as having 3 lines.`, finish `stop`, no loop; turn 3 exact required `line_count` args `one\ntwo` after assistant/tool history. Cache topology captured: 32 layers, 4 KV, 28 array/SSM layers, `companion=ssm`, disk-backed restore required, TurboQuant KV 0. This row proved cache hits: `disk_l2_hits=1`, `ssm_companion_hits=1`, and `companion_hits=1`. |
| Ling MXFP4 | pass | `/tmp/osaurus-pr1264-009688d3-ling-mxfp4-20260527-075431/SUMMARY.json` | exact multi-turn `line_count`, no protocol leak, `disk_l2_hits +1`, `ssm_companion_hits +1`, 32 layers with 4 KV + 28 arrays/SSM, TurboQuant KV 0 |
| ZAYA text JANGTQ_K | #1268 exact-head API pass, CCA topology proven | current row `/tmp/osaurus-pr1268-395cc494-zaya-text-required-tool-20260528-032135`; older cold row `/tmp/osaurus-pr1264-0c3c2200-zaya-text-jangtq4-20260527-083745/zaya-text-jangtq4/zaya1-8b-jangtq4_summary.json`; older warm proof `/tmp/osaurus-pr1264-0c3c2200-zaya-text-jangtq4-warm-20260527-083815/zaya-text-jangtq4/zaya1-8b-jangtq4_summary.json` | current row used no-sign Release app at `395cc494` pinned to vMLX main `bd6c6808`. Turn 1 exact required `line_count` args `red\ngreen\nblue`, `content=null`, no protocol leak; turn 2 visible `One short sentence: There were 3 lines counted.`, finish `stop`, no loop; turn 3 exact required `line_count` args `one\ntwo` after assistant/tool history. Cache topology captured: 80 layers, 40 KV, 40 ZAYA CCA companion layers, `companion=zaya-cca`, disk-backed restore required, TurboQuant KV 0. |
| ZAYA VL JANGTQ4 | #1268 current-head media pass, repeat L2 proof | current media row `/tmp/osaurus-pr1268-5442b551-zaya-vl-jangtq4-media-cache-20260528-032750`; blocked diagnostic row `/tmp/osaurus-pr1268-5442b551-zaya-vl-jangtq-k-media-cache-20260528-032732`; old fixed proof `/tmp/osaurus-pr1266-274ee7e4-zaya-vl-history-media-proof-rerun-20260527-104601/SUMMARY.json` | current row used no-sign Release app runtime-equivalent to `5442b551` pinned to vMLX main `bd6c6808`, with a real generated 64x64 red PNG `image_url` data URL. First and repeat calls both answered `Red`, both stopped normally, no protocol leak, stable prefix hash `6e340b9cffb37a989ca544e6bb780a2c`, and repeat disk L2 hit proved (`repeat_disk_l2_hit=true`, `disk_l2_hits=1`). Cache topology captured: 40 ZAYA CCA layers, `companion=zaya-cca`, disk-backed restore required, TurboQuant KV 0. The attempted `zaya1-vl-8b-jangtq_k` row correctly returned HTTP 400 because that diagnostic artifact has a known first-token fidelity failure; use JANGTQ4/MXFP4 for production serving. |
| DSV4 JANGTQ2 | #1268 exact-head API pass, DSV4 topology proven | current row `/tmp/osaurus-pr1268-395cc494-dsv4-required-tool-20260528-031952`; old warm row `/tmp/osaurus-pr1264-c2108825-dsv4-jangtq2-warm-20260527-075623/SUMMARY.json` | current row used no-sign Release app at `395cc494` pinned to vMLX main `bd6c6808`. Turn 1 exact required `line_count` args `red\ngreen\nblue`, `content=null`, no DSML/protocol leak; turn 2 visible `The tool counted 3 lines, as shown in the output: {"lines": 3}.`, finish `stop`, no loop; turn 3 exact required `line_count` args `one\ntwo` after assistant/tool history. Cache topology captured: 43 layers, 41 hybrid-pool/rotating-wrapper layers, 2 rotating KV layers, disk-backed restore required, TurboQuant KV 0. Disk L2 stores/misses moved (`stores +5`, `misses +10`); this exact-head row proves topology and tool behavior, while warm disk-hit depth remains represented by the older warm row. |
| DSV4 JANGTQ-K | warm pass | `/tmp/osaurus-pr1264-c2108825-dsv4-jangtq-k-warm-20260527-075727/SUMMARY.json` | exact multi-turn `line_count`, no DSML/protocol leak, 43 layers with 41 hybrid-pool/rotating-wrapper + 2 rotating KV, `disk_l2_hits +1`, TurboQuant KV 0 |
| Qwen 27B MXFP4 MTP | #1268 current-head API pass, SSM topology proven | current row `/tmp/osaurus-pr1268-5442b551-qwen27-mxfp4-mtp-required-tool-20260528-032520`; old cold fixed-behavior row `/tmp/osaurus-pr1264-42c8ae95-qwen27-mxfp4-mtp-20260527-083311/qwen27-mxfp4-mtp/qwen3.6-27b-mxfp4-crack-mtp_summary.json`; old warm proof `/tmp/osaurus-pr1264-42c8ae95-qwen27-mxfp4-mtp-warm-20260527-083324/qwen27-mxfp4-mtp/qwen3.6-27b-mxfp4-crack-mtp_summary.json`; prior red repro `/tmp/osaurus-pr1264-current-qwen27-repro-20260527-080759` | current row used no-sign Release app runtime-equivalent to `5442b551` pinned to vMLX main `bd6c6808`. Turn 1 exact required `line_count` args `red\ngreen\nblue`, `content=null`, no protocol leak; turn 2 visible `3 lines were counted.`, finish `stop`, no reasoning-only/length-stop loop; turn 3 exact required `line_count` args `one\ntwo` after assistant/tool history. Cache topology captured: 64 layers, 16 KV, 48 Mamba/SSM layers, `companion=ssm`, disk-backed restore required, TurboQuant KV 0. Current row proves topology/tool behavior; older warm row remains the disk-hit depth proof. |
| Qwen 35B MXFP4 MTP | warm pass | cold row `/tmp/osaurus-pr1264-0d4d9fe0-qwen35-mxfp4-mtp-20260527-083615/qwen35-mxfp4-mtp/qwen3.6-35b-a3b-mxfp4-crack-mtp_summary.json`; warm proof `/tmp/osaurus-pr1264-0d4d9fe0-qwen35-mxfp4-mtp-warm-20260527-083629/qwen35-mxfp4-mtp/qwen3.6-35b-a3b-mxfp4-crack-mtp_summary.json` | same Qwen local no-thinking default path as 27B: turn2 visible `3 lines were counted.`, stop finish, no protocol leak, turn1/turn3 exact `line_count` tool calls. Cold row stored L2 but had no hits; immediate warm row passed with `disk_l2_hits +2`, `ssm_companion_hits +2`, 40 layers with 10 KV + 30 Mamba, TurboQuant KV 0 |
| MiniMax M2.7 Small JANGTQ | #1268 latest-head API pass, full-KV disk-L2 proof | cold row `/tmp/osaurus-pr1264-e32cf51b-minimax-m27-small-jangtq-20260527-083940/minimax-m27-small-jangtq/minimax-m2.7-small-jangtq_summary.json`; warm row `/tmp/osaurus-pr1264-e32cf51b-minimax-m27-small-jangtq-warm-20260527-084010/minimax-m27-small-jangtq/minimax-m2.7-small-jangtq_summary.json`; latest-head pass `/tmp/osaurus-pr1268-23f0c39-minimax-small-jangtq-20260528-073239`; current-head store probe `/tmp/osaurus-pr1264-4369301f-minimax-small-jangtq-l2-20260527-090719/SUMMARY.json`; second relaunch crash/disconnect probe `/tmp/osaurus-pr1264-4369301f-minimax-small-jangtq-second-l2-20260527-090830/SUMMARY.json` | latest-head row passes exact multi-turn `line_count`, no protocol leak, visible post-tool answer `Three lines were counted.`, 62 full-KV layers, TurboQuant KV 0, and disk-L2 hit proof `disk_l2_hits +1` with `disk_l2_misses +7` and `disk_l2_stores +5`. Older failed and partial probes remain listed as superseded diagnostics. |
| MiniMax M2.7 JANGTQ_K | #1268 current-head API pass, full-KV cache proof | current row `/tmp/osaurus-pr1268-5442b551-minimax-jangtq-k-required-tool-20260528-032630`; old cold row `/tmp/osaurus-pr1264-aa5f44d8-minimax-m27-jangtq-k-crack-20260527-084805/minimax-m27-jangtq-k-crack/minimax-m2.7-jangtq_k-crack_summary.json`; old warm row `/tmp/osaurus-pr1264-aa5f44d8-minimax-m27-jangtq-k-crack-warm-20260527-084845/minimax-m27-jangtq-k-crack/minimax-m2.7-jangtq_k-crack_summary.json` | current row used no-sign Release app runtime-equivalent to `5442b551` pinned to vMLX main `bd6c6808`. Turn 1 exact required `line_count` args `red\ngreen\nblue`, `content=null`, no protocol leak; turn 2 visible `The text had 3 lines.`, finish `stop`, no loop; turn 3 exact required `line_count` args `one\ntwo` after assistant/tool history. Cache topology captured: 62 full-KV layers, paged/prefix cache enabled, TurboQuant KV 0. Current row proved `paged_hits=2` and `prefix_hits=2`; disk L2 stored new blocks but did not hit on this row. |
| MiniMax M2.7 JANG_K | pass | cold row `/tmp/osaurus-pr1264-31a3ba86-minimax-m27-jang-k-crack-20260527-085022/minimax-m27-jang-k-crack/minimax-m2.7-jang_k-crack_summary.json`; warm row `/tmp/osaurus-pr1264-31a3ba86-minimax-m27-jang-k-crack-warm-20260527-085056/minimax-m27-jang-k-crack/minimax-m2.7-jang_k-crack_summary.json`; current-head clean-start proof `/tmp/osaurus-pr1264-4369301f-minimax-jang-k-store-20260527-090636/SUMMARY.json` | exact multi-turn `line_count`, no protocol leak, visible post-tool answer, 62 full-KV layers, TurboQuant KV 0. Current-head clean-start proof began with no loaded model and passed with `disk_l2_hits +2`, `disk_l2_misses 0`, `disk_l2_stores +7`, turn2 visible `Three lines were counted.`, and 39.45 tok/s on the visible answer |
| MiMo V2.5 | excluded from current #1268 merge gate | prior source note `/Users/eric/jang`: `uv run --project jang-tools pytest -q jang-tools/tests/mimo_v2_contract_test.py`; vMLX `d69a12168fe6d5c89cb2756ca478f0ea7e18c7d3` | Current user decision is to forget MiMo for this PR because it is not working right now. Keep the old topology note only as future context: expected `mimo_v2_flash` topology is 9 full-attention `KVCacheSimple` layers plus 39 SWA `RotatingKVCache` layers, with TurboQuant KV limited to full-attention KV layers only. Do not block #1268 on MiMo live proof, and do not claim MiMo is production-ready. |
| HY3/Hunyuan local rows | live blocked | `/v1/models` on the current `775e785e` no-sign app did not list `hy3`/`hunyuan`; raw source bundle exists at `/Volumes/EricsLLMDrive/sources/Hy3-preview` with `config.json`, tokenizer files, and 112 safetensor shards | live Osaurus proof is blocked by missing imported model id, not by a completed runtime row. Do not infer HY3/CAA/CCA behavior from ZAYA, MiniMax, or MiMo source guards |

### 2026-05-28 07:02 PDT Gemma3n unsupported-tool boundary tightened

- Current local worktree head before commit: `319bfeb06ae082f0a77b48c992bcd93bb3e8e04a`, pinned to vMLX main `cc3f5f4dc1317ffa09c46050ba0847f495887747`.
- Fresh no-sign Release app from that head was launched keychain-free from `build/DerivedData-pr1268-release-nosign-319bfeb0/Build/Products/Release/osaurus.app` with `OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1`.
- Fresh inventory artifact: `/tmp/osaurus-pr1268-319bfeb0-current-inventory-20260528-065436`, 43 models visible.
- Fresh DSV4 JANGTQ2 artifact: `/tmp/osaurus-pr1268-319bfeb0-dsv4-jangtq2-20260528-065445`.
  - Turn 1 required `line_count`: pass.
  - Turn 2 visible answer after tool result: pass, no DSML/protocol leak.
  - Turn 3 second required tool after assistant/tool history: pass.
  - DSV4 topology: 43 layers, 41 hybrid-pool/rotating-wrapper layers, 2 rotating layers, disk-backed restore required, TurboQuant KV 0.
  - Boundary remains: disk L2 stores/misses moved but no current-row hit was proven.
- Fresh Gemma3n boundary artifact before the Osaurus-side guard: `/tmp/osaurus-pr1268-319bfeb0-gemma3n-boundary-20260528-065603`.
  - Classification: fail/unsupported for required tools.
  - Failure shape: visible `<|tool>model:model` fragments and missing structured tool call.
- Follow-up source fix in this worktree blocks known unsupported Gemma3n local tool requests in `MLXService.validateRuntimePolicy` before decode and updates the tokenizer fallback so Gemma3n does not synthesize required-tool declarations/instructions.
- Focused validation after source fix:
  - `MLXServiceRuntimePolicyTests`: 7/7 passed.
  - `SwiftTransformersTokenizerLoaderTests/gemma3nLocalTokenizerDoesNotInventRequiredToolContractFromFallback`: passed.
- This is a support-boundary fix, not a promotion. Gemma3n remains unsupported for required tool calling until a native/stamped Gemma3n tool contract exists and passes live multi-turn proof.

### 2026-05-28 07:21 PDT latest-head DSV4/ZAYA repeat-cache probes

Current Osaurus head: `13f7fd9455006d55242d77375a5c9dcf2841266c`.
Current vMLX main pin: `cc3f5f4dc1317ffa09c46050ba0847f495887747`.
No-sign/keychain-free app: `/Users/eric/osaurus-pr1268-live/build/DerivedData-pr1268-release-nosign-13f7fd94/Build/Products/Release/osaurus.app`.

DSV4 repeat-cache artifact:

- `/tmp/osaurus-pr1268-13f7fd94-dsv4-repeat-cache-20260528-071614`
- Model: `deepseek-v4-flash-jangtq2`.
- Three identical required `line_count` requests all passed with exact args `red\ngreen\nblue`, `finish_reason=tool_calls`, and no visible content/protocol leak.
- Topology stayed DSV4 hybrid-pool: 43 layers, 41 hybrid-pool/rotating-wrapper layers, 2 rotating layers, disk-backed restore required, TurboQuant KV 0.
- Cache boundary: disk L2 hits stayed `0`; misses/stores moved (`misses 2 -> 4 -> 6`, `stores 0 -> 1 -> 2`). This proves the prior third-repeat tool-routing failure is not reproducing on `13f7fd94`, but it still does not prove DSV4 warm disk-hit readiness.

ZAYA CCA repeat-cache artifact:

- `/tmp/osaurus-pr1268-13f7fd94-zaya-cca-repeat-cache-20260528-071813`
- Model: `zaya1-8b-jangtq4`.
- Three identical required `line_count` requests all passed with exact args `red\ngreen\nblue`, `finish_reason=tool_calls`, and no visible content/protocol leak.
- Topology: 80 layers, 40 KV layers, 40 ZAYA CCA layers, `companion=zaya-cca`, disk-backed restore required, TurboQuant KV 0.
- Disk L2 reuse is proven in this row: turn 2 `disk_hits +1`, turn 3 `disk_hits +1`.
- CCA companion-hit reuse is still not proven: `zaya_cca_companion_hits` remained `0`, while `zaya_cca_companion_misses` increased on turns 2 and 3. Keep the row classified as behavior-pass/disk-reuse-pass with CCA companion-hit boundary.

### 2026-05-28 07:33 PDT MiniMax Small JANGTQ promoted on latest-head app path

- Artifact: `/tmp/osaurus-pr1268-23f0c39-minimax-small-jangtq-20260528-073239`.
- `minimax-m2.7-small-jangtq` now passes the current app/API row: turn 1 required `line_count`, visible post-tool answer, and turn 3 second required `line_count` after assistant/tool history.
- Visible answer: `Three lines were counted.`
- Cache delta: `disk_l2_hits +1`, `disk_l2_misses +7`, `disk_l2_stores +5`.
- Topology: 62 full-KV layers, no SSM/Mamba, no CCA companion, no rotating layers, TurboQuant KV 0.
- This supersedes the prior partial classification for MiniMax Small JANGTQ on the current no-sign app path. The row is now behavior-pass plus disk-L2-hit-pass.
- Missing-family inventory artifact: `/tmp/osaurus-pr1268-23f0c39-missing-family-inventory-20260528-073227`.
- `bailing`, `hy3`, and `hunyuan` selected zero rows from the current `/v1/models` inventory, so those remain import/model-availability blocked rather than runtime-proven.

### 2026-05-28 07:37 PDT Gemma4 latest-head rotating-KV proof

- Artifact: `/tmp/osaurus-pr1268-77236bc4-gemma4-jang4m-20260528-073742`.
- `gemma-4-26b-a4b-it-jang_4m-crack` passes the current app/API row: turn 1 required `line_count`, visible post-tool answer, and turn 3 second required `line_count` after assistant/tool history.
- Visible answer: `There were 3 lines counted.`
- Cache delta: `disk_l2_hits +0`, `disk_l2_misses +2`, `disk_l2_stores +4`.
- Topology: 30 layers, 5 KV layers, 25 rotating KV layers, disk-backed restore required, TurboQuant KV 0.
- Keep Gemma4 classified as behavior-pass/rotating-topology-pass with a disk-hit boundary. Do not claim warm rotating-state disk-hit reuse from this row.

### 2026-05-28 11:28 PDT Gemma4 local API default rail and L2 proof

- Source fix: `MLXBatchAdapter.additionalContext` now routes Gemma-family local API requests to `enable_thinking=false` when the request omits reasoning/thinking options, matching the existing Gemma UI profile default without parser-side output repair or prompt coercion.
- Explicit opt-in is preserved: `disableThinking=false` and positive `reasoningEffort` still produce `enable_thinking=true`; direct/off efforts such as `no_think` keep `enable_thinking=false`.
- Focused Swift tests passed before live proof:
  - `MLXBatchAdapterTests/additionalContext_defaultsGemma4ThinkingOffButHonorsExplicitOptIn`
  - `RuntimePolicySourceTests`
  - `MLXBatchAdapterTests`
- No-sign app build: `/Users/eric/osaurus-pr1268-live/build/DerivedData-pr1268-gemma-default-nosign/Build/Products/Release/osaurus.app`, built with signing disabled and launched through `scripts/live-proof/open-keychain-free-osaurus.sh` with `OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1`.
- Cold artifact: `/tmp/osaurus-pr1268-gemma-default-gemma4-jang4m-tool-cache-20260528-112756`.
  - Turn 1 required `line_count`: exact args `red\ngreen\nblue`, `finish_reason=tool_calls`, no visible content, no protocol leak.
  - Turn 2 after tool result: visible `3 lines were counted.`, no tool calls, no protocol leak.
  - Turn 3 required `line_count` after assistant/tool history: exact args `one\ntwo`, no visible content, no protocol leak.
  - Cache topology: 30 layers, 5 KV layers, 25 rotating KV layers, disk-backed restore required, TurboQuant KV 0.
  - Cold cache movement: `disk_l2_misses +2`, `disk_l2_stores +4`.
- Warm repeat artifact: `/tmp/osaurus-pr1268-gemma-default-gemma4-jang4m-tool-cache-repeat-20260528-112822`.
  - All turn/tool/history checks passed again.
  - Disk L2 reuse is now proven for this row: `disk_l2_hits +1`, `disk_l2_misses +0`, `disk_l2_stores +4`.
  - Required cache evidence passed: cache topology, disk-backed restore, rotating KV layer count, and disk L2 hit.
- Status update: Gemma4 JANG_4M is now behavior-pass, rotating-topology-pass, and disk-L2-hit-pass on the patched #1268 app path. This does not promote Gemma3n, Gemma 31B, or unrelated Gemma siblings.

### 2026-05-28 07:40 PDT DSV4 five-repeat required-tool cache boundary

- Artifact: `/tmp/osaurus-pr1268-f93929ec-dsv4-repeat-cache-20260528-074001`.
- Turns 1, 2, 4, and 5 emitted structured `line_count` tool calls with exact args `red\ngreen\nblue` and no DSML/protocol leak.
- Turn 3 emitted a structured `line_count` call, but arguments were the server validator error object for missing required property `text`.
- Disk L2 hits stayed `0`; misses reached `10`; stores reached `5`.
- Topology remained DSV4 hybrid pool: 43 layers, 41 hybrid-pool/rotating-wrapper layers, 2 rotating layers, disk-backed restore required, TurboQuant KV 0.
- Keep DSV4 JANGTQ2 classified as fresh multi-turn tool-correctness pass but repeat-cache/tool-argument-stability partial. Do not claim DSV4 repeat-cache readiness from this PR.

### 2026-05-28 07:44 PDT DSV4 named-tool repeat isolation

- Artifact: `/tmp/osaurus-pr1268-3ba72413-dsv4-named-repeat-20260528-074419`.
- Named OpenAI tool-choice form improved DSV4 repeat behavior but did not fully close the row.
- Turns 1 through 4 emitted structured `line_count` calls with exact args `red\ngreen\nblue` and no DSML/protocol leak.
- Turn 5 emitted `line_count` with args `red\n green\n blue`, adding spaces before later lines, so exact argument preservation still failed.
- Disk L2 hits were proven: turn 2 `disk_l2_hits +1`, turn 3 `disk_l2_hits +1`; final counters reached `disk_l2_hits=2`, `disk_l2_misses=17`, `disk_l2_stores=9`.
- Keep DSV4 repeat-cache readiness partial: disk-hit movement is now proven in the named isolation, but exact repeated tool arguments are still unstable.

### 2026-06-07 23:16 PDT Nemotron Ultra PR #1411 live app boundary

- Osaurus PR branch: `codex/vmlx-nemotron-runtime-pin`, head
  `975aca2fceb222aa6ab9c3eddc2f0edfbef69367`.
- vMLX pin in `Package.swift` / resolved files:
  `ef15137a47fa5cda7329c840366ecc02e345d7ed`.
- No-sign app:
  `/private/tmp/osaurus-vmlx-pin-integration/build/DerivedData-nemotron-nosign-975aca2f/Build/Products/Release/osaurus.app`.
- Build proof:
  `/tmp/osaurus-nemotron-nosign-build-975aca2f-20260607-225616.log`;
  `** BUILD SUCCEEDED **`, ad-hoc signature, no keychain signing prompt.
- Private-file boundary: this PR evidence did not modify or stage `AGENTS.md`
  or `.agents/`; both are kept out of this evidence commit scope.
- Cold artifact:
  `/tmp/osaurus-nemotron-ultra-live-975aca2f-20260607-230640`.
  - Model: `nvidia-nemotron-3-ultra-550b-a55b-jangtq_1l`.
  - Turn 1 required `line_count`: exact args `red\ngreen\nblue`,
    `finish_reason=tool_calls`, no visible content, no reasoning/protocol leak.
  - Turn 2 after tool result: visible answer mentioned `Three lines`, no tool
    call and no protocol leak, but the response repeated the answer text and
    surrounding sentence fragments before stopping.
  - Turn 3 required `line_count` after tool history: exact args `one\ntwo`,
    `finish_reason=tool_calls`, no visible content, no protocol leak.
  - Topology: 60 layers, 12 KV layers, 48 Mamba layers,
    `requires_ssm_companion_state=true`, `companion=ssm`,
    disk-backed restore required, TurboQuant KV 0.
  - Cold cache movement: `disk_l2_misses +5`, `disk_l2_stores +4`,
    `disk_l2_hits +0`; cold row failed strict disk-hit promotion.
  - Token rates recorded by the harness: turn 2 `143` completion tokens in
    `216.8s`, about `0.66 tok/s`.
- Warm artifact:
  `/tmp/osaurus-nemotron-ultra-live-warm-975aca2f-20260607-231239`.
  - Tool/parser checks stayed green: turn 1 and turn 3 exact structured
    `line_count` calls, no protocol leak.
  - Warm cache proof passed: `disk_l2_hits +3`, `ssm_companion_hits +3`,
    `companion_hits +3`, and `ssm_companion_rederives +0`.
  - Turn 2 still failed readiness: `finish_reason=length`, visible content
    began with the correct answer but degraded into repeated numeric/junk text.
  - Warm token rate for turn 2: `96` completion tokens in `164.0s`, about
    `0.59 tok/s`.
- Status: Nemotron Ultra JANGTQ_1L is parser-pass, topology-pass, and warm
  hybrid SSM cache-hit-pass on this PR app path, but remains production
  `PARTIAL` for answer quality and speed on the tool-result follow-up. Do not
  promote it to release-ready from these rows, and do not hide the failure with
  sampler overrides, prompt coercion, forced reasoning/tool tags, or parser
  repair.

### 2026-06-07 23:39 PDT Nemotron Ultra PR #1411 compiled-decode boundary fix

- Osaurus PR branch: `codex/vmlx-nemotron-runtime-pin`, head
  `b7121367f5b8e33fdd0eb5f655392fd1e8db0bf2`.
- Source fix: `MLXBatchAdapter.shouldEnableCompiledBatchDecode` now refuses
  B=1 compiled batch decode for `ModelRuntime.isKnownHybridModel` families.
  This covers Nemotron-H / Qwen3.5-style hybrid SSM or linear-attention rows
  without changing dense/full-KV solo defaults.
- Focused source proof passed:
  `MLXBatchAdapterTests/compiledBatchDecodeDisabledForKnownUnsafeSoloModels`.
- No-sign app:
  `/private/tmp/osaurus-vmlx-pin-integration/build/DerivedData-nemotron-nosign-b7121367/Build/Products/Release/osaurus.app`.
- Build proof:
  `/tmp/osaurus-nemotron-nosign-build-b7121367-20260607-232638.log`;
  `** BUILD SUCCEEDED **`, ad-hoc signature, no keychain signing prompt.
- Private-file boundary: `AGENTS.md` is local skip-worktree in the active
  worktrees, and this PR commit did not modify or stage `AGENTS.md` or
  `.agents/`.
- Cold artifact:
  `/tmp/osaurus-nemotron-ultra-live-b7121367-20260607-233409`.
  - Model: `nvidia-nemotron-3-ultra-550b-a55b-jangtq_1l`.
  - Turn 1 required `line_count`: exact args `red\ngreen\nblue`,
    `finish_reason=tool_calls`, no visible content, no reasoning/protocol leak.
  - Turn 2 after tool result: clean visible answer `3 lines were counted.`,
    no tool call, no protocol leak, `finish_reason=stop`.
  - Turn 3 required `line_count` after tool history: exact args `one\ntwo`,
    `finish_reason=tool_calls`, no visible content, no protocol leak.
  - Topology: 60 layers, 12 KV layers, 48 Mamba layers,
    `requires_ssm_companion_state=true`, `companion=ssm`,
    disk-backed restore required, TurboQuant KV 0.
  - Cold cache movement: `disk_l2_misses +5`, `disk_l2_stores +4`,
    `disk_l2_hits +0`; cold row is behavior-pass/topology-pass but not
    disk-hit-promoted.
- Warm artifact:
  `/tmp/osaurus-nemotron-ultra-live-warm-b7121367-20260607-233559`.
  - Full harness result: `passed=true`.
  - Tool/parser checks all passed again: turn 1 and turn 3 exact structured
    `line_count` calls, no visible content, no reasoning/protocol leak.
  - Turn 2 after tool result: clean visible answer `There are 3 lines.`,
    no tool call, no protocol leak, `finish_reason=stop`.
  - Warm hybrid cache proof passed: `disk_l2_hits +3`,
    `ssm_companion_hits +3`, `companion_hits +3`,
    `ssm_companion_rederives +0`.
  - Token rates were still low in this short tool row: turn 2 `6` completion
    tokens in `16.25s`, about `0.37 tok/s`; this row proves correctness/cache,
    not the direct vMLX sustained decode target.
- Status: Nemotron Ultra JANGTQ_1L is now behavior-pass, parser-pass,
  topology-pass, and warm hybrid SSM cache-hit-pass on the `b7121367` no-sign
  Osaurus PR app path. Speed remains separately tracked by direct vMLX
  sustained rows; do not claim an Osaurus UI speed promotion from this short
  tool-cache harness alone.
