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

- Full KV models: prefix/L2 disk reuse, and TurboQuant KV only when explicitly enabled and proven for the row.
- Qwen/Ling/Nemotron hybrid SSM/Mamba: KV plus SSM/companion state proof; TurboQuant KV is not a substitute.
- ZAYA/CCA/VL: CCA companion/pooling proof, VL media payload where applicable, and cache salt isolation.
- DSV4: CSA/HSA/SWA hybrid-pool topology plus disk restore/hit proof; TurboQuant KV is not a substitute.
- Gemma rotating/SWA: rotating topology plus disk restore/reuse proof; no Zyphra/Gemma XML leak from reasoning or content.
- HY3/Hunyuan/MiMo-style SWA/CCA paths: run only against an actual local model id and require topology-specific companion or SWA proof.
- MiMo V2.5: expected source topology is 9 full-attention KV layers plus 39 SWA rotating layers. Prefix/L2 disk proof is required; TurboQuant KV is allowed only for full-attention `KVCacheSimple` layers when explicitly enabled and must not replace SWA rotating state.

## Current starting boundary

- Base head at creation: `3b2a4f38fdbc08d5a195cf40689414dc469ab5f2`.
- vMLX pin at creation: `531439a05bb3c5334aa551a07481fc5234644329`.
- Current MiMo-aware vMLX pin staged for this branch: `d69a12168fe6d5c89cb2756ca478f0ea7e18c7d3`.
- Current PR `#1266` head after ZAYA VL history-media fix: `229e51fdbc1adb282f4e861ba4ce1209befe480b`.
- Current vMLX pin after ZAYA VL history-media fix: `0c39f5a8bd68b5316f5e56e5bd94cc67b8fe8704`.
- `#1263` is still open on GitHub at creation time; this PR is stacked rather than post-merge until GitHub state changes.
- Do not merge by agent.
- Do not apply forced-behavior fixes, hidden sampler overrides, forced thinking/tool wrappers, or broad parser masks to make rows look green.

## Current #1268 merge boundary

- Current Osaurus PR: `#1268`, head `8c3f1356b274542aa2ab2fb73be44202141ab7d7`.
- Current vMLX main and Osaurus pin: `e2327f5ee52bacbae08eb9f3b3fa74709d74af07`.
- GitHub status at 2026-05-28 00:26 PDT: PR open, not draft, mergeable, not merged; `shellcheck`, `swiftlint`, `test-cli`, `test-core`, and `update_release_draft` all passed.
- Only `#1268` remains open from the `#1247` through `#1268` runtime stack; older related work has been consolidated rather than kept as separate merge targets.
- Exact-head no-sign Release proof exists for Gemma 4 26B JANG_4M at `8c3f1356` and vMLX `e2327f5`.
- The remaining all-family matrix is intentionally not promoted as complete on this PR head. Nemo Omni, Ling, ZAYA, DSV4, Qwen, MiniMax, and HY3/Hunyuan need follow-on exact-head rows before claiming the broader post-merge runtime matrix is complete.
- MiMo V2.5 is explicitly excluded from the current merge gate because the current local MiMo lane is not working/imported enough for a meaningful Osaurus live row.
- TurboQuant/`engineSelected` remains explicit opt-in. Native/fp16 is the default and the legacy migration does not silently flip users into TurboQuant KV.

## Row status ledger

| Row | Status | Artifact | Notes |
| --- | --- | --- | --- |
| Gemma 4 26B JANG_4M | #1268 exact-head API pass, cache-hit depth partial | old row `/tmp/osaurus-pr1263-3b2a4f38-gemma4-current-head-proof-20260527-074030/SUMMARY.json`; current row `/tmp/osaurus-pr1268-8c3f1356-gemma-4-26b-a4b-it-jang_4m-crack-strict-tool-cache-20260528T072041Z/SUMMARY.json` | current row used no-sign Release app at `8c3f1356` pinned to vMLX `e2327f5`. Turn 1 exact required `line_count` args `red\ngreen\nblue`, `content=null`, no protocol leak; turn 2 visible `The text contains 3 lines.`, finish `stop`, no loop; turn 3 exact required `line_count` args `one\ntwo` after assistant/tool history. Cache topology captured: 30 layers, 5 KV, 25 rotating KV, disk-backed restore required, TurboQuant KV 0. Cold row moved stores/misses but did not prove disk L2 hits, so cache-hit depth remains partial. |
| Nemo Omni MXFP4 | warm pass | `/tmp/osaurus-pr1264-c66a0913-nemotron-mxfp4-warm-20260527-075223/SUMMARY.json` | exact multi-turn `line_count`, no assistant-header/protocol leak, `disk_l2_hits +3`, `ssm_companion_hits +3`, 29 layers with 6 KV + 23 Mamba, TurboQuant KV 0 |
| Nemo Omni JANGTQ | warm pass | `/tmp/osaurus-pr1264-c66a0913-nemotron-jangtq-warm-20260527-075247/SUMMARY.json` | exact multi-turn `line_count`, no assistant-header/protocol leak, `disk_l2_hits +3`, `ssm_companion_hits +3`, 29 layers with 6 KV + 23 Mamba, TurboQuant KV 0 |
| Nemo Omni JANGTQ4 | warm pass | `/tmp/osaurus-pr1264-c66a0913-nemotron-jangtq4-warm-20260527-075313/SUMMARY.json` | exact multi-turn `line_count`, no assistant-header/protocol leak, `disk_l2_hits +3`, `ssm_companion_hits +3`, 29 layers with 6 KV + 23 Mamba, TurboQuant KV 0 |
| Ling JANGTQ2 | pass | `/tmp/osaurus-pr1264-009688d3-ling-jangtq2-20260527-075413/SUMMARY.json` | exact multi-turn `line_count`, no protocol leak, `disk_l2_hits +1`, `ssm_companion_hits +1`, 32 layers with 4 KV + 28 arrays/SSM, TurboQuant KV 0 |
| Ling MXFP4 | pass | `/tmp/osaurus-pr1264-009688d3-ling-mxfp4-20260527-075431/SUMMARY.json` | exact multi-turn `line_count`, no protocol leak, `disk_l2_hits +1`, `ssm_companion_hits +1`, 32 layers with 4 KV + 28 arrays/SSM, TurboQuant KV 0 |
| ZAYA text JANGTQ4 | warm pass | cold row `/tmp/osaurus-pr1264-0c3c2200-zaya-text-jangtq4-20260527-083745/zaya-text-jangtq4/zaya1-8b-jangtq4_summary.json`; warm proof `/tmp/osaurus-pr1264-0c3c2200-zaya-text-jangtq4-warm-20260527-083815/zaya-text-jangtq4/zaya1-8b-jangtq4_summary.json` | exact multi-turn `line_count`, no protocol leak, visible post-tool answer, 80 layers with 40 KV + 40 ZAYA CCA, disk-backed restore required, `disk_l2_hits +3`, ZAYA CCA companion cache surface present with misses on warm row, TurboQuant KV 0 |
| ZAYA VL JANGTQ4 | current-head pass, CCA-hit depth partial | failed rows: `/tmp/osaurus-pr1264-4431acb8-zaya-vl-jangtq4-20260527-084334/SUMMARY.json`, `/tmp/osaurus-pr1264-zaya-vl-tool-isolation-20260527-084436/SUMMARY.json`, `/tmp/osaurus-pr1266-current-head-zaya-vl-proof-20260527-101620`; old warm proof: `/tmp/osaurus-pr1265-775e785e-zaya-vl-multiturn-tool-warm-cache-20260527-100158/SUMMARY.json`; current-head fixed proof: `/tmp/osaurus-pr1266-274ee7e4-zaya-vl-history-media-proof-rerun-20260527-104601/SUMMARY.json` | current tree `229e51fd` is tree-identical to the tested no-sign Release build at `274ee7e4`, with vMLX `0c39f5a8bd68b5316f5e56e5bd94cc67b8fe8704`. The fixed proof uses a real 64x64 red `image_url`, required `line_count` with exact `alpha\nbeta\ngamma`, visible answer `In the image, there are 3 lines and the dominant color is red.`, and a second required `line_count` with exact `one\ntwo` after image/tool/assistant history. The prior current-head HTTP 500 `Number of placeholder tokens does not match number of frames` is fixed by dropping stale historical images only when the rendered ZAYA prompt has zero image placeholders; nonzero mismatches still throw. Cache topology remains `zayaCCALayers=40`, `companion=zaya-cca`, disk-backed restore required, TurboQuant KV 0. Current short proof moved disk L2 stores/misses (`stores 1->5`, `misses 2->10`) but did not prove current-head disk hits; old warm row proved `disk_l2_hits +3`. Do not promote as CCA companion-hit proof yet: `zaya_cca_companion_hits` stayed 0. |
| DSV4 JANGTQ2 | warm pass | `/tmp/osaurus-pr1264-c2108825-dsv4-jangtq2-warm-20260527-075623/SUMMARY.json` | exact multi-turn `line_count`, no DSML/protocol leak, 43 layers with 41 hybrid-pool/rotating-wrapper + 2 rotating KV, `disk_l2_hits +1`, TurboQuant KV 0 |
| DSV4 JANGTQ-K | warm pass | `/tmp/osaurus-pr1264-c2108825-dsv4-jangtq-k-warm-20260527-075727/SUMMARY.json` | exact multi-turn `line_count`, no DSML/protocol leak, 43 layers with 41 hybrid-pool/rotating-wrapper + 2 rotating KV, `disk_l2_hits +1`, TurboQuant KV 0 |
| Qwen 27B MXFP4 MTP | warm pass | cold fixed-behavior row `/tmp/osaurus-pr1264-42c8ae95-qwen27-mxfp4-mtp-20260527-083311/qwen27-mxfp4-mtp/qwen3.6-27b-mxfp4-crack-mtp_summary.json`; warm proof `/tmp/osaurus-pr1264-42c8ae95-qwen27-mxfp4-mtp-warm-20260527-083324/qwen27-mxfp4-mtp/qwen3.6-27b-mxfp4-crack-mtp_summary.json`; prior red repro `/tmp/osaurus-pr1264-current-qwen27-repro-20260527-080759` | `42c8ae95` with vMLX `54bbf805c756b28f12136f24b6794f87069136e7` fixes the reasoning-only length-stop after tool history: turn2 visible `3 lines were counted.`, stop finish, no protocol leak, turn1/turn3 exact `line_count` tool calls. Cold row stored L2 (`disk_l2_stores +4`) but had no hits; immediate warm row passed with `disk_l2_hits +3`, `ssm_companion_hits +3`, 64 layers with 16 KV + 48 Mamba, TurboQuant KV 0 |
| Qwen 35B MXFP4 MTP | warm pass | cold row `/tmp/osaurus-pr1264-0d4d9fe0-qwen35-mxfp4-mtp-20260527-083615/qwen35-mxfp4-mtp/qwen3.6-35b-a3b-mxfp4-crack-mtp_summary.json`; warm proof `/tmp/osaurus-pr1264-0d4d9fe0-qwen35-mxfp4-mtp-warm-20260527-083629/qwen35-mxfp4-mtp/qwen3.6-35b-a3b-mxfp4-crack-mtp_summary.json` | same Qwen local no-thinking default path as 27B: turn2 visible `3 lines were counted.`, stop finish, no protocol leak, turn1/turn3 exact `line_count` tool calls. Cold row stored L2 but had no hits; immediate warm row passed with `disk_l2_hits +2`, `ssm_companion_hits +2`, 40 layers with 10 KV + 30 Mamba, TurboQuant KV 0 |
| MiniMax M2.7 Small JANGTQ | partial | cold row `/tmp/osaurus-pr1264-e32cf51b-minimax-m27-small-jangtq-20260527-083940/minimax-m27-small-jangtq/minimax-m2.7-small-jangtq_summary.json`; warm row `/tmp/osaurus-pr1264-e32cf51b-minimax-m27-small-jangtq-warm-20260527-084010/minimax-m27-small-jangtq/minimax-m2.7-small-jangtq_summary.json`; current-head store probe `/tmp/osaurus-pr1264-4369301f-minimax-small-jangtq-l2-20260527-090719/SUMMARY.json`; second relaunch crash/disconnect probe `/tmp/osaurus-pr1264-4369301f-minimax-small-jangtq-second-l2-20260527-090830/SUMMARY.json` | exact multi-turn `line_count`, no protocol leak, visible post-tool answer on the completed rows, 62 full-KV layers, TurboQuant KV 0, warm `paged_hits`/`prefix_hits`; not promoted. First current-head probe passed behavior but missed disk L2 (`disk_l2_hits 0`, `disk_l2_misses +8`, `disk_l2_stores +7`). Second clean relaunch started with no resident model and completed turn1, then the app disconnected during turn2 and stopped serving before final cache stats; no crash report was written under `~/Library/Logs/DiagnosticReports` at check time |
| MiniMax M2.7 JANGTQ_K | pass | cold row `/tmp/osaurus-pr1264-aa5f44d8-minimax-m27-jangtq-k-crack-20260527-084805/minimax-m27-jangtq-k-crack/minimax-m2.7-jangtq_k-crack_summary.json`; warm row `/tmp/osaurus-pr1264-aa5f44d8-minimax-m27-jangtq-k-crack-warm-20260527-084845/minimax-m27-jangtq-k-crack/minimax-m2.7-jangtq_k-crack_summary.json`; first current-head relaunch probe `/tmp/osaurus-pr1264-4369301f-minimax-jangtq-k-post-relaunch-l2-20260527-090104/SUMMARY.json`; second current-head relaunch proof `/tmp/osaurus-pr1264-4369301f-minimax-jangtq-k-second-relaunch-l2-20260527-090508/SUMMARY.json` | exact multi-turn `line_count`, no protocol leak, visible post-tool answer, 62 full-KV layers, TurboQuant KV 0. Immediate warm rows proved `paged_hits`/`prefix_hits`. The first current-head relaunch missed older disk entries and stored new current-head entries; the second relaunch started from no resident model and passed with `disk_l2_hits +2`, `disk_l2_misses 0`, `disk_l2_stores +7`, turn2 visible `3 lines were counted.`, and 35.50 tok/s on the visible answer |
| MiniMax M2.7 JANG_K | pass | cold row `/tmp/osaurus-pr1264-31a3ba86-minimax-m27-jang-k-crack-20260527-085022/minimax-m27-jang-k-crack/minimax-m2.7-jang_k-crack_summary.json`; warm row `/tmp/osaurus-pr1264-31a3ba86-minimax-m27-jang-k-crack-warm-20260527-085056/minimax-m27-jang-k-crack/minimax-m2.7-jang_k-crack_summary.json`; current-head clean-start proof `/tmp/osaurus-pr1264-4369301f-minimax-jang-k-store-20260527-090636/SUMMARY.json` | exact multi-turn `line_count`, no protocol leak, visible post-tool answer, 62 full-KV layers, TurboQuant KV 0. Current-head clean-start proof began with no loaded model and passed with `disk_l2_hits +2`, `disk_l2_misses 0`, `disk_l2_stores +7`, turn2 visible `Three lines were counted.`, and 39.45 tok/s on the visible answer |
| MiMo V2.5 | excluded from current #1268 merge gate | prior source note `/Users/eric/jang`: `uv run --project jang-tools pytest -q jang-tools/tests/mimo_v2_contract_test.py`; vMLX `d69a12168fe6d5c89cb2756ca478f0ea7e18c7d3` | Current user decision is to forget MiMo for this PR because it is not working right now. Keep the old topology note only as future context: expected `mimo_v2_flash` topology is 9 full-attention `KVCacheSimple` layers plus 39 SWA `RotatingKVCache` layers, with TurboQuant KV limited to full-attention KV layers only. Do not block #1268 on MiMo live proof, and do not claim MiMo is production-ready. |
| HY3/Hunyuan local rows | live blocked | `/v1/models` on the current `775e785e` no-sign app did not list `hy3`/`hunyuan`; raw source bundle exists at `/Volumes/EricsLLMDrive/sources/Hy3-preview` with `config.json`, tokenizer files, and 112 safetensor shards | live Osaurus proof is blocked by missing imported model id, not by a completed runtime row. Do not infer HY3/CAA/CCA behavior from ZAYA, MiniMax, or MiMo source guards |
