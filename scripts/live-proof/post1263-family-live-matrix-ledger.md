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
