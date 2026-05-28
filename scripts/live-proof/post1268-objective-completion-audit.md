# PR 1268 objective completion audit

Checked at: 2026-05-28 10:10 PDT

Current boundary:

- Osaurus PR: `#1268`
- Current checked Osaurus head after this refresh: `a1d101d6f22dfff41052c1af33975c25663175cd`
- Last green Osaurus head before this documentation/proof refresh: `80e8749144d50b9783c5cc37a84b1cb03b8fdfa4`
- vMLX main / Osaurus pin: `76e55f59935f22c3bb2f28055ae8ecebd2e7a355`
- Osaurus merge policy: do not merge by agent
- vMLX merge policy: vMLX is agent-managed and is already on main
- CI boundary: `a1d101d6f22dfff41052c1af33975c25663175cd` is green for `shellcheck`, `swiftlint`, `test-cli`, `test-core`, and `update_release_draft`; re-check the live PR head after any later documentation-only push
- No-sign app proof boundary: code-equivalent build `695d5869ea9821732649bffb3789469568e6db55`
- Current app observation at this audit refresh: no-sign build `DerivedData-pr1268-release-nosign-695d5869` is healthy with `deepseek-v4-flash-jangtq2` resident, no in-flight requests, and DSV4 cache topology still 43 layers / 41 hybrid-pool / 2 rotating / TurboQuant KV 0.
- Fresh Nemotron Omni MXFP4 row is red/partial, not production-clear: `/tmp/osaurus-pr1268-a1d101d6-nemotron-omni-mxfp4-tool-cache-20260528-102745` proves cold structured `line_count` tool turns, visible tool-result answer, no protocol leakage, 29-layer topology with 23 Mamba/SSM layers, and SSM companion topology; however it records no disk L2 hit. The immediate repeat `/tmp/osaurus-pr1268-a1d101d6-nemotron-omni-mxfp4-tool-cache-repeat-20260528-102806` fails turn 3 because `tool_choice: "required"` returns visible text `Two lines were counted.` instead of a structured tool call, all three responses report the same `prefix_hash`, and the requested model is no longer resident by the after-snapshot. Treat Nemo Omni MXFP4 required-tool repeat/cache behavior as red until root-caused without prompt coercion.
- Fresh ZAYA text JANGTQ4 row is red/partial, not production-clear: `/tmp/osaurus-pr1268-c9fdc4c3-zaya-text-jangtq4-tool-cache-20260528-103322` proves first structured `line_count`, visible tool-result answer, ZAYA CCA topology, disk-backed restore requirement, and no protocol leakage; however turn 3 emitted a structured `line_count` call with argument ` ... ` instead of exact `one\ntwo`, and disk L2 hits stayed 0. Treat ZAYA text required-tool argument fidelity and repeat-cache proof as red until root-caused without parser repair.

This file is a completion audit against the full runtime objective. It is not a
marketing summary. A row marked partial means the PR documents or implements
real progress, but the full requested end state is not proven for every family
or surface.

## Objective audit

| Requirement | Current status | Evidence | Remaining work |
|---|---|---|---|
| One Osaurus consolidation PR | Green | `#1268` is the only open PR in the `#1247`-`#1268` consolidation range; older PRs are merged or closed/superseded. | Keep future fixes in `#1268` until merge; do not reopen duplicate family PRs. |
| Do not merge Osaurus by agent | Green | `#1268` remains open, not draft, mergeable, and unmerged. | Human merge only. |
| vMLX main fully updated with current fixes | Green for current pin | `osaurus-ai/vmlx-swift` main and Osaurus pin are `76e55f59935f22c3bb2f28055ae8ecebd2e7a355`. | Any new vMLX fix must land on vMLX main first, then #1268 must repin. |
| No fake runtime guards or prompt coercion | Green for source policy | Source guards preserve no forced reasoning tags, no hidden sampler clamps, no parser output repair, no DSV4 forced repetition guard, and no required-tool prompt coercion. | Keep investigating runtime causes instead of adding decode/template disguises. |
| Model generation config considered | Partial | Source policy requires omitted sampler fields to come from bundle config rather than synthetic Osaurus defaults. | DSV4 lacks `max_new_tokens` in bundle config; omitted max-token behavior remains not green. |
| Max output token behavior | Partial | DSV4 required-tool proof passes with explicit `max_tokens: 256`. | Decide/fix omitted DSV4 max-token behavior without inventing model-incorrect defaults. |
| Max context behavior | Partial | Matrix docs require context/default coverage and long-prompt rows. | Long-prompt/cache rows are not complete for Ling, HY3, all Qwen/Gemma/ZAYA/Nemotron variants. |
| TurboQuant KV defaults | Partial | `engineSelected` is topology-gated; proven compatible full-KV rows may use TurboQuant by default, while DSV4/ZAYA/ZAYA-VL/Gemma rotating/hybrid rows stay native unless proven. | Broader TurboQuant encode/decode safety still needs per-topology proof before broad default expansion. |
| Hybrid SSM async rederive | Partial | SSM rederive is enabled by default and documented for Qwen, Ling, and Nemotron SSM rows with companion-hit proof in selected artifacts. | Not every hybrid family/sibling has current-head companion-hit proof. |
| CCA companion cache behavior | Partial | ZAYA/ZAYA-VL rows prove CCA topology and selected disk L2 media reuse. | ZAYA CCA companion-hit depth remains unproven and must not be relabeled as generic SSM proof. |
| DSV4 Flash DSML parser and cache topology | Partial/green under explicit controls | Green artifact `/tmp/osaurus-pr1268-ad233f70-dsv4-required-repeat-instruct-max256-20260528-085603` proves 5/5 required `line_count` turns with exact args, no DSML leak, no reasoning leakage, DSV4 43-layer hybrid topology, TurboQuant KV 0, disk L2 stores. Responses route artifact `/tmp/osaurus-pr1268-5f358de5-dsv4-responses-required-20260528-091946` proves one non-streaming `/v1/responses` `function_call` with exact args and no DSML leak under explicit controls. Streaming Responses artifact `/tmp/osaurus-pr1268-7a7d2273-dsv4-responses-stream-required-20260528-093541` proves reasoning-summary events plus final structured function-call event with exact args, no DSML leak, DSV4 topology preserved, and disk L2 stores +1. Responses repeat artifact `/tmp/osaurus-pr1268-a1d101d6-dsv4-responses-tool-result-repeat-cache-clean-20260528-102858` proves two `/v1/responses` tool-result follow-ups with visible line-count answers, no marker leak, DSV4 topology preserved, and `disk_l2_hits +1` on each repeat with no new misses. Messages artifact `/tmp/osaurus-pr1268-7a7d2273-dsv4-messages-required-20260528-093706` proves one Anthropic-compatible `/v1/messages` `tool_use` with exact args and no DSML leak. Messages follow-up artifact `/tmp/osaurus-pr1268-f7343290-dsv4-messages-tool-result-20260528-095315` proves tool-result history renders to a normal visible answer without another tool call or DSML leak. Repeat artifact `/tmp/osaurus-pr1268-80e87491-dsv4-messages-tool-result-repeat-cache-20260528-100913` proves Messages tool-result follow-up repeat cache reuse with `disk_l2_hits +1` on turn 2. | Omitted reasoning/max rows are red/partial; active-tool DSV4 repeat-cache coverage remains surface-specific. |
| Multi-turn tool calls do not leak | Partial | DSV4, Gemma4, Ling, Nemotron, MiniMax, Qwen, and ZAYA selected rows document multi-turn `line_count` behavior without protocol leakage. | Not all tools and all API surfaces are exhaustively proven; broader tool matrix remains. |
| Proper parser recognition | Partial | Source/parser tests cover DSV4 DSML, DSV4 JSON fallbacks, ZAYA XML line breaks, Gemma4 multiline tool envelopes, and routing guards. | GLM/GPT-OSS/Mistral/other parser-family rows remain checklist items. |
| Prefix cache and L2 disk cache | Partial | Current rows document topology, disk stores, and selected warm hits for several families. DSV4 Responses and Messages tool-result follow-ups now have repeat `disk_l2_hits +1` rows. | DSV4 active-tool disk restore/hit semantics, ZAYA CCA depth, and full family repeat-cache rows remain incomplete. |
| Responses/cache endpoint behavior | Partial | Source guards cover OpenResponses/cache wiring; DSV4 non-streaming `/v1/responses`, streaming `/v1/responses`, `/v1/messages` required tool-use, and tool-result follow-up proofs are green for parser/event/history parity under explicit controls. Responses and Messages tool-result repeat rows prove `disk_l2_hits +1` for those surfaces. | Cache proof is still not blanket across every endpoint/tool surface or omitted-control mode. |
| VL/video/media processing | Partial | ZAYA-VL has real red PNG media rows and repeat disk L2 proof; Nemo structural media paths are documented. | Nemo audio/video live rows, Qwen/Gemma VL/video rows, media cache salts, and UI screenshots remain. |
| Matmul/Hadamard/2D/3D/runtime kernel concerns | Not fully audited in #1268 | vMLX source is on main and CI/osaurus source guards are green. | No current artifact proves every kernel/path concern across all target models; keep as runtime follow-up unless a concrete regression appears. |
| Runtime speed | Deferred | The objective explicitly makes speed last; selected rows include timing/token evidence where generated. | Do not promote speed claims until functional/parser/cache rows are green per family. |
| Keychain-free development proof | Green for live-proof path | Use no-sign/keychain-free scripts and app launch with `OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1`; current no-sign app proof is healthy. | Default `make app`, `make test`, `make ci-test`, signing/release/notarization/plugin signing paths are not keychain-safe proof paths. |

## Family status snapshot

| Family | Status | Boundary |
|---|---|---|
| DSV4 JANGTQ2/K | Partial | Explicit `reasoning_effort: "instruct"` plus `max_tokens: 256` tool row is green; omitted controls remain not green. |
| Qwen 27B/35B MTP | Partial/green selected rows | Selected SSM/MTP tool/cache rows pass; not every Qwen sibling is production-clear. |
| Gemma4 | Partial | Selected Gemma4 tool/topology rows pass; Gemma3n tool support remains blocked/unsupported and Gemma4 sibling coverage is not blanket. |
| MiniMax | Partial/green selected rows | Selected MiniMax M2.7 JANG/JANGTQ tool/cache rows pass; MiMo is excluded. |
| MiMo | Red/excluded | No meaningful Osaurus live row because current local MiMo lane is not working/imported enough. |
| Ling/Bailing | Partial/red | Ling selected SSM rows pass; Bailing availability and long-prompt/runtime rows remain incomplete. |
| ZAYA text | Red/partial | Current JANGTQ4 row proves CCA topology and leak-free structured tool envelopes, but turn 3 argument fidelity failed with ` ... ` and disk L2 hits stayed 0; direct-mode and companion-hit depth are not production-clear. |
| ZAYA VL | Partial | Real image/media rows pass for selected artifacts; CCA companion-hit depth and sibling coverage remain. |
| Nemotron Omni | Red/partial | MXFP4 cold row proves first structured tool turn, tool-result answer, second structured tool turn, no protocol leak, and SSM topology, but repeat row ignored required tool choice on turn 3 and did not produce disk L2 reuse proof; audio/video/resume rows also remain. |
| HY3/Hunyuan | Red | No imported local model id/live Osaurus row at the current boundary. |

## Merge interpretation

If #1268 is merged after the live PR head is green, the truthful interpretation is:

- vMLX main is updated and Osaurus is pinned to it.
- The Osaurus consolidation branch is green and contains the current source
  guards, no-sign proof harnesses, and documented live matrix evidence.
- The PR does not prove every listed model family, cache topology, parser,
  media path, or endpoint fully production-clear.
- Remaining red/partial rows must stay visible and move forward in the same
  matrix discipline: no fake guards, no hidden defaults, no prompt coercion,
  and no load-only proof.
