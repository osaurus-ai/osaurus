# Post-1266 live family cache/tool matrix

This document is the live evidence ledger for PR `#1268`, the consolidated
post-1266 Osaurus/vMLX family runtime cache/tool matrix PR. Older runtime PRs
must not be merged separately; their current replacement is PR `#1268`.

## Required proof buckets

Each promoted row needs current Osaurus app/API evidence from an unsigned/no-sign app launched keychain-free:

- Model ID is present in `/v1/models`.
- Chat payload does not inject sampler overrides unless the request explicitly asks for them.
- Turn 1 emits a structured `line_count` tool call with exact multiline arguments and no visible protocol leak.
- Turn 2 consumes the tool result and emits visible assistant text with no reasoning/protocol leak.
- Turn 3 emits a second structured tool call after assistant/tool history and no visible protocol leak.
- `/health` remains healthy before and after the row.
- `/admin/cache-stats` is captured before and after the row.
- Cache result is topology-specific: full-attention KV/prefix/L2, hybrid SSM companion state, ZAYA CCA/VL media salts, DSV4 CSA/HSA/SWA state, and any architecture-specific disk persistence.
- Token/s must be recorded when emitted by the runtime. If the OpenAI-compatible API response does not emit token/s, the row must say so instead of inventing a value.

## Harness

Use:

```sh
scripts/live-proof/run-post1266-family-cache-tool-matrix.py --inventory-only
scripts/live-proof/run-post1266-family-cache-tool-matrix.py --model 'nemotron|nemo'
scripts/live-proof/run-post1266-family-cache-tool-matrix.py --model 'ling'
scripts/live-proof/run-post1266-family-cache-tool-matrix.py --model 'zaya'
scripts/live-proof/run-post1266-family-cache-tool-matrix.py --model 'deepseek-v4|dsv4'
scripts/live-proof/run-post1266-family-cache-tool-matrix.py --model 'qwen'
scripts/live-proof/run-post1266-family-cache-tool-matrix.py --model 'gemma'
scripts/live-proof/run-post1266-family-cache-tool-matrix.py --model 'hy3|hunyuan'
```

The harness writes raw requests, raw responses, health, cache stats, durations, and per-row `SUMMARY.json` artifacts. It classifies rows as `pass`, `pass_with_cache_boundary`, `fail`, or `error`.
Default family selection skips internal model IDs beginning with `_`; explicit `--model` patterns can still target them for diagnostics.

## Current boundaries

- This is not a merge instruction.
- Do not broaden parser stripping to hide bad model output.
- Do not add forced thinking tags, hidden repetition penalties, synthetic sampler defaults, or template coercion.
- Do not enable TurboQuant KV broadly unless the specific topology row proves it safe.

## Live artifacts

## 2026-05-27 current-head boundary

Current Osaurus head: `19871f5fa3d3ad1d777d02195380725a67f9fb59`.
Current vMLX pin: `bdd43452f86566574f3ea8c1a68a0993b7e25192`.

This head includes the Nemotron required-tool tail/template fix and the DSV4
multiline required-tool fix. The current-head no-sign app was built from
`/Users/eric/osaurus-pr1268-live` with signing disabled and launched with
`OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1`.

Current no-sign build path:
`/Users/eric/osaurus-pr1268-live/build/DerivedData-pr1268-release-nosign-19871f5f`.

Current-head Nemotron rerun:

- Cold artifact: `/Users/eric/osaurus-pr1268-live/live-artifacts/osaurus-post1266-live-family-cache-matrix-20260527T225816Z`
- Warm artifact: `/Users/eric/osaurus-pr1268-live/live-artifacts/osaurus-post1266-live-family-cache-matrix-20260527T225904Z`
- Model: `nemotron-omni-nano-jangtq-crack`
- Classification: `pass`
- Source/runtime fix: vMLX `bdd43452f86566574f3ea8c1a68a0993b7e25192` removes the late required-tool system tail that previously leaked `system` into multiline tool arguments.
- Turn 1 required `line_count`: pass, exact multiline args.
- Turn 2 visible answer after tool result: pass, `Three lines were counted.`, no protocol/reasoning leak.
- Turn 3 second required `line_count`: pass.
- Cache topology: `layers=29`, `kvLayers=6`, `mambaLayers=23`, `companion=ssm`, `restore=disk-backed`.
- Warm cache delta: `disk_l2_hits +3`, `disk_l2_stores +4`, `companion_hits +3`, and `ssm_companion_hits +3`.
- TurboQuant KV layer count: `0`.
- Token/s: not emitted by the OpenAI-compatible response; durations and usage artifacts are recorded.

Current-head Ling rerun:

- Artifact: `/Users/eric/osaurus-pr1268-live/live-artifacts/osaurus-post1266-live-family-cache-matrix-20260527T230017Z`
- Model: `ling-2.6-flash-jangtq2-crack`
- Classification: `pass`
- Turn 1 required `line_count`: pass, exact multiline args.
- Turn 2 visible answer after tool result: pass, `Three lines were counted.`, no protocol/reasoning leak.
- Turn 3 second required `line_count`: pass.
- Cache topology: `layers=32`, `kvLayers=4`, `arraysLayers=28`, `companion=ssm`, `restore=disk-backed`.
- Cache delta: `disk_l2_hits +1`, `disk_l2_misses +6`, `disk_l2_stores +3`, `companion_hits +1`, `ssm_companion_hits +1`.
- TurboQuant KV layer count: `0`.
- Token/s: not emitted by the OpenAI-compatible response; durations and usage artifacts are recorded.

Current-head DSV4 JANGTQ2 rerun:

- Artifact: `/Users/eric/osaurus-pr1268-live/live-artifacts/osaurus-post1266-live-family-cache-matrix-20260527T225647Z`
- Model: `deepseek-v4-flash-jangtq2`
- Classification: `pass_with_cache_boundary`
- Turn 1 required `line_count`: pass, exact multiline args.
- Turn 2 visible answer after tool result: pass, no protocol/reasoning leak.
- Turn 3 second required `line_count`: pass. This closes the earlier literal `one\\ntwo` multiline-argument failure.
- Cache topology: `layers=43`, `rotatingLayers=2`, `rotatingWrapperLayers=41`, `hybridPoolLayers=41`, `restore=disk-backed`.
- Cache delta: `disk_l2_misses +10`, `disk_l2_stores +4`; delayed refresh still showed `disk_l2_hits +0`.
- TurboQuant KV layer count: `0`.
- Boundary: DSV4 CSA/HSA/SWA disk-backed pool restore/stores are visible, but cache hit is not proven in this short row.
- Token/s: not emitted by the OpenAI-compatible response; durations and usage artifacts are recorded.

Current-head ZAYA text rerun:

- Cold artifact: `/Users/eric/osaurus-pr1268-live/live-artifacts/osaurus-post1266-live-family-cache-matrix-20260527T230106Z`
- Warm artifact: `/Users/eric/osaurus-pr1268-live/live-artifacts/osaurus-post1266-live-family-cache-matrix-20260527T230305Z`
- Model: `zaya1-8b-jangtq4`
- Classification: `pass_with_cache_boundary`
- Turn 1 required `line_count`: pass, exact multiline args.
- Turn 2 visible answer after tool result: pass, `There were 3 lines counted.`, no protocol/reasoning leak.
- Turn 3 second required `line_count`: pass. This closes the earlier abbreviated `one\ntw...` argument failure on this bundle.
- Cache topology: `layers=80`, `kvLayers=40`, `zayaCCALayers=40`, `companion=zaya-cca`, `restore=disk-backed`.
- Warm cache delta: `disk_l2_hits +3`, `disk_l2_misses +8`, `disk_l2_stores +4`, but `zaya_cca_companion_hits +0` and `zaya_cca_companion_misses +3`.
- TurboQuant KV layer count: `0`.
- Boundary: ZAYA text tool behavior is now passing; ZAYA CCA companion-hit reuse is still not proven.
- Token/s: not emitted by the OpenAI-compatible response; durations and usage artifacts are recorded.

Current-head Gemma3n E2B rerun:

- Artifact: `/Users/eric/osaurus-pr1268-live/live-artifacts/osaurus-post1266-live-family-cache-matrix-20260527T230811Z`
- Model: `gemma-3n-e2b-it-4bit`
- Classification: `fail`
- Failure: first required-tool turn emitted visible prose (`Okay, I understand...`) and no structured tool call.
- Cache delta before failure: `disk_l2_stores +3`.
- Boundary: do not promote Gemma3n required-tool support from Gemma4 evidence; this remains a source/template/model-family investigation item.
- Token/s: not emitted by the OpenAI-compatible response; duration and usage artifacts are recorded.

Current classification boundary to preserve:

- Pass rows: Nemotron Omni, Ling, Qwen35, Gemma4 26B, MiniMax direct-rail.
- Partial rows: DSV4 JANGTQ2 cache-hit proof, ZAYA text CCA companion hit, ZAYA-VL CCA companion hit.
- Fail/unavailable rows: Gemma3n required-tool live fail, HY3 missing from `/v1/models`.
- TurboQuant KV is engine-selected by default but topology-gated: proven full-KV rows may resolve to TurboQuant, while hybrid/rotating/CCA/DSV4 rows remain native/fp16 unless explicitly overridden. Current hybrid/companion pass rows record TurboQuant KV as `0` or absent rather than proving broad TurboQuant safety.

## 2026-05-27 13:04 PDT - Exact-head keychain-free app refresh

Current Osaurus head: `a1ae123fa989b65063605c56b5c2ae38326ba099`.
No-sign Release app:
`/tmp/osaurus-post1266-live-family-cache-matrix/build/DerivedData-pr1268-release-nosign-a1ae123f/Build/Products/Release/osaurus.app`.

Launch mode:

- `OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1`
- No signing, notarization, `security`, or certificate lookup path.
- `/health` was healthy before and after the Ling row.

Inventory artifact:

- `/tmp/osaurus-post1266-live-family-cache-matrix-20260527T200403Z`
- Inventory count: `43`
- Selected default matrix rows: Nemotron Omni, Ling, ZAYA text, DSV4 JANG, Qwen, Gemma3n, MiniMax.
- HY3/Hunyuan remains unavailable in current `/v1/models`; `--model 'hy3|hunyuan'` selected no rows.

Exact-head Ling artifact:

- `/tmp/osaurus-post1266-live-family-cache-matrix-20260527T200411Z`
- Model: `ling-2.6-flash-jangtq2-crack`
- Classification: `pass`
- Turn 1 required `line_count`: pass, exact `alpha\nbeta\ngamma`.
- Turn 2 visible answer after tool result: `Three lines were counted.`, no protocol/reasoning leak.
- Turn 3 second required `line_count`: pass, exact `one\ntwo`.
- Cache topology: `layers=32`, `kvLayers=4`, `arraysLayers=28`, `companion=ssm`, `restore=disk-backed`.
- Cache delta: `disk_l2_hits +1`, `disk_l2_misses +6`, `disk_l2_stores +4`, `companion_hits +1`, `ssm_companion_hits +1`.
- TurboQuant KV layer count: `0`.
- Token/s: not emitted by the OpenAI-compatible response; durations and usage artifacts are recorded.

### Nemotron Omni Nano JANGTQ CRACK

- Artifact: `/tmp/osaurus-pr1268-live-nemotron-rerun-20260527-111029`
- Model: `nemotron-omni-nano-jangtq-crack`
- Classification: `pass`
- Turn 1 required `line_count`: pass, exact `alpha\nbeta\ngamma`
- Turn 2 visible answer after tool result: pass, no protocol/reasoning leak
- Turn 3 second required `line_count`: pass, exact `one\ntwo`
- Cache delta: `disk_l2_hits +3`, `disk_l2_stores +3`, `companion_hits +3`, `ssm_companion_hits +3`
- Token/s: not emitted by the OpenAI-compatible response; durations and usage artifacts are recorded

### Ling 2.6 Flash JANGTQ2 CRACK

- Artifact: `/tmp/osaurus-pr1268-live-ling-20260527-111100`
- Model: `ling-2.6-flash-jangtq2-crack`
- Classification: `pass`
- Turn 1 required `line_count`: pass, exact `alpha\nbeta\ngamma`
- Turn 2 visible answer after tool result: pass, no protocol/reasoning leak
- Turn 3 second required `line_count`: pass, exact `one\ntwo`
- Cache delta: `disk_l2_hits +1`, `disk_l2_stores +3`, `companion_hits +1`, `ssm_companion_hits +1`
- Token/s: not emitted by the OpenAI-compatible response; durations and usage artifacts are recorded

### ZAYA text JANGTQ4

- Artifact: `/tmp/osaurus-pr1268-live-zaya-text-20260527-111115`
- Model: `zaya1-8b-jangtq4`
- Classification: `fail`
- Failure: first required `line_count` turn returned visible `rmat:\n\n`, no structured tool call, and stopped by length.
- Boundary: do not infer ZAYA text tool support from ZAYA-VL proof.

Refresh after required-tool harness cap correction:

- Direct probe: `/tmp/osaurus-pr1268-zaya-text-token-budget-probe-20260527-1204`
- Full rerun: `/tmp/osaurus-pr1268-live-zaya-text-required768-20260527-1208`
- Classification remains `fail` / partial, but for a narrower reason:
  - Turn 1 required `line_count`: pass, exact `alpha\nbeta\ngamma`.
  - Turn 2 visible answer after tool result: pass, no protocol/reasoning leak.
  - Turn 3 second required `line_count`: structured tool call emitted, but argument was abbreviated as `one\ntw...` instead of exact `one\ntwo`.
- Cache delta on the full rerun: `disk_l2_hits +3`, `disk_l2_stores +4`, `zaya_cca_companion_hits +0`, `zaya_cca_companion_misses +3`.
- Boundary: current evidence no longer supports a broad "missing ZAYA text tool schema" diagnosis; it supports an exact-argument reliability issue after tool history plus unproven ZAYA CCA companion-hit reuse.

### ZAYA-VL JANGTQ4

- Artifact: `/tmp/osaurus-pr1268-live-zaya-vl-topology-strict-20260527-111224`
- Model: `zaya1-vl-8b-jangtq4`
- Classification: `pass_with_cache_boundary`
- Turn 1 required `line_count`: pass, exact `alpha\nbeta\ngamma`
- Turn 2 visible answer after tool result: pass, no protocol/reasoning leak
- Turn 3 second required `line_count`: pass, exact `one\ntwo`
- Cache delta: `disk_l2_hits +3`, `disk_l2_stores +4`, but `zaya_cca_companion_hits +0` and `zaya_cca_companion_misses +3`
- Boundary: ZAYA CCA companion hit is not proven in this row.
- Token/s: not emitted by the OpenAI-compatible response; durations and usage artifacts are recorded

### DSV4 plain affine JANG

- Artifact: `/tmp/osaurus-pr1268-live-dsv4-jang-20260527-111317`
- Model: `deepseek-v4-flash-jang`
- Classification: `error`
- Result: Osaurus correctly refused the plain affine DSV4 JANG bundle and directed use of JANGTQ2/JANGTQ-K instead.
- Boundary: this is a production guard, not a live chat pass.

### DSV4 Flash JANGTQ2

- Artifact: `/tmp/osaurus-pr1268-live-dsv4-jangtq2-multiline-20260527-111419`
- Model: `deepseek-v4-flash-jangtq2`
- Classification: `fail`
- Turn 1 required `line_count`: pass, exact `alpha\nbeta\ngamma`
- Turn 2 visible answer after tool result: pass, no protocol/reasoning leak
- Turn 3 second required `line_count`: failed; argument came back as literal `one\\ntwo` instead of `one\ntwo`
- Cache delta: `disk_l2_misses +17`, `disk_l2_stores +4`, no cache hit proven in this short row
- Boundary: do not normalize `\\n` broadly as a fake fix; root cause needs DSV4 tool-history/schema-path investigation.

### Qwen 3.5 35B A3B 4-bit

- Artifact: `/tmp/osaurus-pr1268-live-qwen35-rerun-20260527-111520`
- Model: `qwen3.5-35b-a3b-4bit`
- Classification: `pass`
- Turn 1 required `line_count`: pass, exact `alpha\nbeta\ngamma`
- Turn 2 visible answer after tool result: pass, no protocol/reasoning leak
- Turn 3 second required `line_count`: pass, exact `one\ntwo`
- Cache delta: `disk_l2_hits +3`, `disk_l2_stores +4`, `companion_hits +3`, `ssm_companion_hits +3`
- Token/s: not emitted by the OpenAI-compatible response; durations and usage artifacts are recorded

### Gemma 3n E2B 4-bit

- Artifact: `/tmp/osaurus-pr1268-live-gemma3n-e2b-20260527-111528`
- Model: `gemma-3n-e2b-it-4bit`
- Classification: `fail`
- Failure: first required tool turn emitted visible tag-like text and no structured tool call.
- Boundary: do not infer Gemma 3n support from Gemma 4 support.

Refresh after Gemma3n fallback prompt correction:

- Source/tests commit: `0292f08ae1a492b02f49dee0eda35b8faab22a17`
- Live artifact: `/tmp/osaurus-pr1268-gemma3n-live-1a5b64d3-20260527-124255`
- Rebuilt no-sign Release app health showed `gemma-3n-e2b-it-4bit` loaded/resident.
- Classification remains `fail`.
- Failure: first required `line_count` turn emitted visible prose (`Okay, I understand...`) and no structured tool call.
- Boundary: the fallback now renders a concrete Gemma-style required-tool contract in source tests, but the live model row still does not satisfy required tool calling. Do not promote Gemma3n required-tool support in this PR.

### Gemma 4 26B A4B JANG_4M CRACK

- Artifact: `/tmp/osaurus-pr1268-live-gemma4-26b-rerun-20260527-111555`
- Model: `gemma-4-26b-a4b-it-jang_4m-crack`
- Classification: `pass`
- Turn 1 required `line_count`: pass, exact `alpha\nbeta\ngamma`
- Turn 2 visible answer after tool result: pass, no protocol/reasoning leak
- Turn 3 second required `line_count`: pass, exact `one\ntwo`
- Cache delta: `disk_l2_hits +1`, `disk_l2_stores +4`
- Token/s: not emitted by the OpenAI-compatible response; durations and usage artifacts are recorded

### MiniMax M2.7 JANG_K CRACK

- Artifact: `/tmp/osaurus-pr1268-live-minimax-m27-20260527-111602`
- Model: `minimax-m2.7-jang_k-crack`
- Classification: `fail`
- Turn 1 required `line_count`: pass
- Turn 2 visible answer after tool result: failed; response was hidden reasoning only with blank visible content and length stop
- Turn 3 second required `line_count`: failed; no structured tool call
- Cache delta: `paged_hits +2`, `prefix_hits +2`, `disk_l2_stores +6`
- Boundary: cache path proves activity, but chat/tool multi-turn behavior is not production-ready.

## 2026-05-27 11:41 PDT - MiniMax direct-rail rerun on rebuilt PR #1268 app

Current Osaurus head: `2659487918aa77038efa752f3c60295016d6adab`.
No-sign Release app: `/tmp/osaurus-post1266-live-family-cache-matrix/build/DerivedData-pr1268-release-nosign-minimax-26594879/Build/Products/Release/osaurus.app`.
Launch root: `/tmp/osaurus-pr1268-release-open-minimax-20260527-114043`.

Focused source guard before rebuild:

- `MLXBatchAdapterTests/additionalContext_defaultsMiniMaxThinkingOffButHonorsExplicitOptIn`: passed.

Live artifact:

- `/tmp/osaurus-pr1268-live-minimax-m27-after-direct-20260527-114108`

Result:

- `minimax-m2.7-jang_k-crack`: `pass`
- Turn 1 required `line_count`: structured tool call, exact args.
- Turn 2 after tool result: visible answer `The line_count tool counted 3 lines.`, no hidden-reasoning-only blank response.
- Turn 3 second required `line_count`: structured tool call.
- Cache topology: 62 KV layers, no TurboQuant KV, paged cache enabled, disk L2 enabled.
- Cache proof delta: `paged_hits +2`, `prefix_hits +2`, `disk_l2_stores +5`, `disk_l2_misses +4`.
- OpenAI-compatible response still does not emit token/s; duration and usage are recorded in the artifact.

Interpretation:

- The MiniMax post-tool hidden-reasoning failure from `/tmp/osaurus-pr1268-live-minimax-m27-20260527-111602` is fixed for this app path by defaulting MiniMax local chat to the direct/no-thinking rail while preserving explicit reasoning opt-in.
- This is family/template context wiring, not a sampler override, repetition penalty, or output-suppression fix.

Still not fixed by this row:

- `zaya1-8b-jangtq4` text required-tool turn now passes with the corrected proof cap, but the multi-turn exact-argument row remains partial because turn 3 returned `one\ntw...` instead of exact `one\ntwo`.
- `zaya1-vl-8b-jangtq4` tool path passed but CCA companion cache hit remains unproven.
- `deepseek-v4-flash-jangtq2` still has second-turn newline escaping mismatch on `one\ntwo`.
- `gemma-3n-e2b-it-4bit` still leaks tag-like tool text on first required tool.
- HY3/Hunyuan is still unavailable in current `/v1/models` inventory.

## 2026-05-27 16:00 PDT - Current-head PR #1268 DSV4 rerun and dev-launch correction

Current Osaurus head: `19871f5fa3d3ad1d777d02195380725a67f9fb59`.
Current vMLX pin: `f84b0dbd00a87e4722f7b3c700938a40e261c399`.

## 2026-05-27 16:15 PDT - Current-head continuation: Gemma3n and ZAYA-VL remain red

Current Osaurus head at this continuation: `82ba13af4bdd6091156946d04a84796401d1adc3`.
Current vMLX pin: `f84b0dbd00a87e4722f7b3c700938a40e261c399`.

Gemma3n E2B required-tool isolation:

- Matrix artifact: `/tmp/osaurus-post1266-live-family-cache-matrix-20260527T230811Z`.
- Named-tool isolation artifact: `/tmp/osaurus-pr1268-gemma3n-named-toolchoice-20260527T161410Z`.
- Model: `gemma-3n-e2b-it-4bit`.
- Result: fail.
- Required and named `line_count` requests both returned visible prose explaining the function-call grammar instead of a structured tool call.
- Cache/RAM boundary: app stayed healthy, TurboQuant KV remained 0, and swap stayed essentially unused. This is a template/model-family required-tool failure, not a low-memory or TurboQuant regression.
- Do not infer Gemma3n required-tool support from Gemma4 evidence. Do not hide this with output stripping, hidden sampler changes, or prompt coercion.

ZAYA-VL required-tool isolation:

- Matrix artifact: `/tmp/osaurus-post1266-zaya-vl-current-20260527T231442Z`.
- Fresh single-turn isolation artifact: `/tmp/osaurus-pr1268-zaya-vl-direct-second-20260527T231530Z`.
- Named-history isolation artifact: `/tmp/osaurus-pr1268-zaya-vl-history-named-20260527T231530Z`.
- Model: `zaya1-vl-8b-jangtq4`.
- Result: fail.
- Matrix turn 1 required `line_count` passed exactly and turn 2 visible answer returned `3 lines.`.
- Matrix turn 3 after assistant/tool history stopped with empty assistant content and no structured tool call.
- After that row, a fresh required `line_count` request also stopped with empty assistant content and zero completion tokens.
- Cache topology was `layers=40`, `zayaCCALayers=40`, `companion=zaya-cca`, `restore=disk-backed`, with TurboQuant KV 0.
- Cache counters moved (`disk_l2_misses +8`, `disk_l2_stores +5`) but no disk hit or ZAYA CCA companion hit was proven.
- App stayed healthy and swap stayed essentially unused. This is a required-tool/runtime-cache boundary for the VL bundle; it is not a proof of ZAYA-VL production readiness.

Build/launch findings:

- `scripts/live-proof/build-keychain-free-osaurus.sh` built Release with Xcode signing disabled.
- Direct binary launch through `launch-keychain-free-osaurus.sh` was blocked by macOS policy on this machine (`AppleSystemPolicy` refused the raw unsigned bundle).
- The workable keychain-free UI path is:
  - build with Xcode signing disabled,
  - apply local ad-hoc bundle sealing with `/usr/bin/codesign --sign - --timestamp=none`,
  - launch foreground UI through `open-keychain-free-osaurus.sh`, which sets `OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1` and `OSAURUS_TEST_ROOT` via `launchctl setenv` before `open -n`.
- This uses no signing identity, certificate, notarization, `security(1)`, or login Keychain item.

Focused DSV4 app row:

- Artifact: `/tmp/osaurus-pr1268-live-dsv4-jangtq2-clean-19871f5f-20260527-160007`
- Model: `deepseek-v4-flash-jangtq2`
- Classification: `pass_with_cache_boundary`
- Turn 1 required `line_count`: pass, exact `alpha\nbeta\ngamma`
- Turn 2 visible answer after tool result: pass, no protocol/reasoning leak
- Turn 3 second required `line_count`: pass, exact `one\ntwo`
- No sampler overrides in script payloads.
- Boundary: this short rerun did not prove DSV4 cache-hit counters; `/admin/cache-stats` did not retain a DSV4 model row at summary capture. Use earlier warm DSV4 artifacts for disk L2 hit proof until a fresh current-head cache-hit rerun is captured.
- Additional boundary: this row proves the OpenAI-compatible app/server tool path. Do not promote it as signed/notarized release proof while `CodeSigningHelper.xpc` remains active.

## 2026-05-28 04:24 PDT - Current-head ZAYA-VL media required-tool proof after vMLX main repin

Current Osaurus head: `2b4f576dbe1159054677eaee3e9d2467ff396da1`.
Current vMLX pin: `d3d76b4c11c1f3e83e787f0464120087167c1609`.
No-sign Release app: `/Users/eric/osaurus-pr1268-live/build/DerivedData-pr1268-release-nosign-2b4f576d/Build/Products/Release/osaurus.app`.
Launch mode: `OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1`, `OSAURUS_TEST_ROOT=/tmp/osaurus-pr1268-2b4f576d-keychain-free-open-20260528-042237`.

ZAYA-VL media required-tool row:

- Artifact: `/tmp/osaurus-pr1268-2b4f576d-zaya-vl-media-tool-multiturn-20260528-042420`
- Model: `zaya1-vl-8b-jangtq4`
- Classification: `pass`
- Turn 1 required `line_count` with 56x56 red PNG: structured tool call, exact args `alpha\nbeta\ngamma`.
- Turn 2 after tool result: visible answer `The line count is 3. The dominant image color is red.`
- No `value_1`, no `example_function_name`, no DSML/protocol leak.
- Cache topology: `layers=40`, `zayaCCALayers=40`, `companion=zaya-cca`, `restore=disk-backed`, TurboQuant KV layer count `0`.
- Cache counters: `disk_l2_misses=4`, `disk_l2_stores=3`; no ZAYA CCA companion hit was required for this short row.

Invalid payload boundary:

- Artifact: `/tmp/osaurus-pr1268-2b4f576d-zaya-vl-media-tool-errorbody-20260528-042348`
- The earlier 1x1 PNG request failed correctly with `Height: 1 must be larger than factor: 28`; this was a test-payload issue, not the duplicate ZAYA media placeholder regression.

## 2026-05-28 04:34 PDT - ZAYA-VL repeated media required-tool cache-hit proof

Current Osaurus head: `b681ea663c511cdeb45a97a20a2b050ea51cd40f`.
Current vMLX pin: `d3d76b4c11c1f3e83e787f0464120087167c1609`.
Live app: `/Users/eric/osaurus-pr1268-live/build/DerivedData-pr1268-release-nosign-2b4f576d/Build/Products/Release/osaurus.app`.

Artifact:

- `/tmp/osaurus-pr1268-b681ea66-zaya-vl-repeat-cache-hit-20260528-043444`

Result:

- Model: `zaya1-vl-8b-jangtq4`
- Classification: `pass_with_cache_boundary`
- Repeated media required `line_count`: structured tool call, exact args `alpha\nbeta\ngamma`.
- Cache delta from `/admin/cache-stats`: `disk_l2_hits +1`, `disk_l2_misses +3`, `zaya_cca_companion_misses +1`.
- Cache topology: `layers=40`, `zayaCCALayers=40`, `companion=zaya-cca`, `restore=disk-backed`, TurboQuant KV layer count `0`.
- Boundary: this proves disk L2 reuse on the ZAYA-VL media/tool row and companion-cache accounting, but not a ZAYA CCA companion hit. Do not claim ZAYA CCA hit reuse until a row records `zaya_cca_companion_hits > 0`.

## 2026-05-28 05:49 PDT - DSV4 required-tool action-rail proof after vMLX main update

Current Osaurus head: `bbc4338532010adabf0fd1773ef0e66f712beabb`.
Runtime-equivalent no-sign Release app: `/Users/eric/osaurus-pr1268-live/build/DerivedData-pr1268-094bf705-nosign/Build/Products/Release/osaurus.app`.
Current vMLX main pin: `d3d76b4c11c1f3e83e787f0464120087167c1609`.
Launch mode: `OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1`, `OSAURUS_TEST_ROOT=/tmp/osaurus-pr1268-bbc43385-keychain-free-dsv4-20260528-054718`.

Artifact:

- `/tmp/osaurus-pr1268-bbc43385-dsv4-required-action-proof-20260528-054910`

Result:

- PASS: `deepseek-v4-flash-jangtq2` required `line_count` routed to a structured tool call with exact multiline argument `alpha\nbeta\ngamma`.
- PASS: tool-result follow-up returned visible final answer `The line count of the given text is 3.` with no DSML/protocol leakage.
- PASS: second required `line_count` after prior tool history routed to a structured tool call with exact multiline argument `one\ntwo`.
- PASS: no turn timed out. Durations were 21.119s, 2.962s, and 19.786s.
- PASS: health after run was healthy, resident model `deepseek-v4-flash-jangtq2`, no inflight requests.

Cache/topology after run:

- `disk_l2_misses`: 12.
- `disk_l2_stores`: 5.
- `disk_l2_hits`: 0 for this fresh-root run.
- DSV4 topology: 43 layers, 41 `hybridPoolLayers`, 41 `rotatingWrapperLayers`, 2 `rotatingLayers`, `restore=disk-backed`, TurboQuant KV layers 0.

Boundary:

- This proves the prior DSV4 required-tool multi-turn timeout/leak class is fixed by routing fallback required-tool prompts through the native DSV4 action rail.
- It does not claim a warm repeat cache-hit row for DSV4; this run was a fresh-root correctness proof.

## 2026-05-28 06:01 PDT - Current-head DSV4 proof after nonstreaming cancellation commit

Current Osaurus head: `1503be2f096f6fa5746178c27d65f7e6d805b525`.
No-sign Release app: `/Users/eric/osaurus-pr1268-live/build/DerivedData-pr1268-1503be2f-nosign/Build/Products/Release/osaurus.app`.
Current vMLX main pin: `d3d76b4c11c1f3e83e787f0464120087167c1609`.
Launch mode: `OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1`, `OSAURUS_TEST_ROOT=/tmp/osaurus-pr1268-1503be2f-keychain-free-dsv4-20260528-060116`.

Artifact:

- `/tmp/osaurus-pr1268-1503be2f-dsv4-required-action-proof-20260528-060148`

Result:

- PASS: no-sign Release build completed for current runtime head and vMLX `d3d76b4`.
- PASS: `deepseek-v4-flash-jangtq2` required `line_count` routed to a structured tool call with exact multiline argument `alpha\nbeta\ngamma`.
- PASS: tool-result follow-up returned visible final answer `The line count of the given text is 3.` with no DSML/protocol leakage.
- PASS: second required `line_count` after prior tool history routed to a structured tool call with exact multiline argument `one\ntwo`.
- PASS: no turn timed out. Durations were 24.319s, 3.281s, and 23.519s.
- PASS: health after run was healthy, resident model `deepseek-v4-flash-jangtq2`, no inflight requests.

Cache/topology after run:

- `disk_l2_misses`: 10.
- `disk_l2_stores`: 4.
- `disk_l2_hits`: 0 for this fresh-root correctness run.
- DSV4 topology: 43 layers, 41 `hybridPoolLayers`, 41 `rotatingWrapperLayers`, 2 `rotatingLayers`, `restore=disk-backed`, TurboQuant KV layers 0.

Boundary:

- This supersedes the prior `bbc43385` DSV4 artifact for current-head readiness because `1503be2f` added nonstreaming abandoned-request cancellation after that run.
- It still does not claim a warm repeat DSV4 cache-hit row; it proves current-head required-tool multi-turn correctness and topology safety.

## 2026-05-28 06:21 PDT - Current-head DSV4 repeat-cache boundary

Current Osaurus head: `2a2a6d4b039e61fd9338c42287fa9b35798328cb`.
No-sign Release app: `/Users/eric/osaurus-pr1268-live/build/DerivedData-pr1268-1503be2f-nosign/Build/Products/Release/osaurus.app`.
Current vMLX main pin: `d3d76b4c11c1f3e83e787f0464120087167c1609`.

Artifact:

- `/tmp/osaurus-pr1268-2a2a6d4b-dsv4-repeat-cache-proof-20260528-062120`

Result:

- Seed request: required `line_count`, exact multiline argument `red\ngreen\nblue`, no visible content, duration 25.425s.
- Second identical request: required `line_count`, exact multiline argument `red\ngreen\nblue`, no visible content, duration 15.035s.
- Third identical request after the second request stored L2 state: FAILED. It returned hidden reasoning only with `finish_reason=length`, no structured tool call, and no visible assistant content.

Cache evidence:

- Seed delta: `disk_l2_misses +2`, `disk_l2_stores +0`, `disk_l2_hits +0`.
- Second-request delta: `disk_l2_misses +2`, `disk_l2_stores +1`, `disk_l2_hits +0`.
- After third failure: aggregate `disk_l2_misses=7`, `disk_l2_stores=3`, `disk_l2_hits=0`.
- Topology remained DSV4 hybrid pool: 43 layers, 41 `hybridPoolLayers`, 41 `rotatingWrapperLayers`, 2 `rotatingLayers`, `restore=disk-backed`, TurboQuant KV layers 0.

Boundary:

- Do not claim DSV4 warm disk-L2 cache-hit readiness from the current proof set.
- Current-head DSV4 required-tool correctness is proven for the multi-turn fresh correctness row above, but repeated identical required-tool cache reuse still needs root-cause work. The third-repeat failure suggests DSV4 disk-backed hybrid-pool reuse/store timing or prompt/cache boundary interaction can still break required-tool routing.

## 2026-05-28 06:28 PDT - Sidecar audit boundaries for Gemma3n and ZAYA CCA

Current Osaurus head before this note: `72005cef9a292adab0709f3d23a02c17a3ba79c5`.
Current vMLX main pin: `d3d76b4c11c1f3e83e787f0464120087167c1609`.

Gemma3n required-tool boundary:

- `gemma-3n-e2b-it-4bit` still has a live required/named tool-call failure in the ledger; it emits visible prose and no structured tool call.
- Source audit shows Osaurus passes `tool_choice` and schema through `ModelRuntime.makeTokenizerTools(...)` and `MLXBatchAdapter.additionalContext(...)`.
- Pinned vMLX maps Gemma3/Gemma3n model types to `ToolCallFormat.gemma`, whose parser expects `<start_function_call>call:name{...}<end_function_call>`.
- The generic Gemma missing-template fallback is Gemma4/Zyphra-oriented. Therefore the next safe step is source-only render/parser verification for the exact Gemma3n E2B bundle path before any live fix.
- Do not hide this with Osaurus-side prompt injection, output stripping, hidden sampler/repetition guards, or fake reasoning wrappers. If render and parser are correct but the model still emits prose, keep Gemma3n required-tool support partial/unsupported for this PR.

ZAYA/ZAYA-VL CCA companion-hit boundary:

- Current pinned vMLX intentionally does not store `ZayaCCACache` into the generic `SSMStateCache` hit path, and disk format-v2 ZAYA CCA payload reuse is rejected without a proven companion boundary.
- Therefore `zaya_cca_companion_hits=0` is expected for the current proof set; disk L2 hits plus `zaya_cca_companion_misses` prove disk/media accounting, not CCA companion hit reuse.
- The smallest safe future fix is a dedicated ZAYA CCA disk-restore hit/miss counter or an exact-boundary ZAYA CCA disk-restore proof path. Do not re-label generic SSM hits as CCA hits, and do not claim prefix/growing-history CCA reuse until separately designed and proven.

## 2026-05-28 06:39 PDT - Gemma3n tool-support heuristic corrected in vMLX main

Current vMLX main pin: `cc3f5f4dc1317ffa09c46050ba0847f495887747`.

Gemma3n required-tool boundary correction:

- Local bundle inspected: `/Users/eric/models/mlx-community/gemma-3n-E2B-it-4bit`.
- `config.json`, `tokenizer_config.json`, `generation_config.json`, and `chat_template.jinja` contain no tool, tool_choice, function-call, `<start_function_call>`, or tool-call markers.
- vMLX main commit `cc3f5f4` stops inferring Gemma3n tool support from `model_type` alone. Plain `gemma3n`, `gemma3n_text`, and `gemma-3n-e2b-it` now resolve to no tool parser unless an explicit bundle/JANG tool-parser stamp opts in.
- Focused vMLX validation: `swift test --scratch-path /tmp/vmlx-gemma3n-tool-heuristic-build --filter gemma3nModelTypeDoesNotInventToolSupport --jobs 1 --no-parallel` passed with 1 test.
- This does not make Gemma3n required-tool calling work; it prevents a false-positive support claim. Keep the live Gemma3n required-tool row partial/unsupported until a native/stamped Gemma3n tool contract exists and passes live multi-turn proof.

## 2026-05-28 07:02 PDT - Current-head DSV4 proof and Gemma3n unsupported-tool guard

Current local head before commit: `319bfeb06ae082f0a77b48c992bcd93bb3e8e04a`.
Current vMLX main pin: `cc3f5f4dc1317ffa09c46050ba0847f495887747`.
No-sign/keychain-free app: `/Users/eric/osaurus-pr1268-live/build/DerivedData-pr1268-release-nosign-319bfeb0/Build/Products/Release/osaurus.app`.

Artifacts:

- Inventory: `/tmp/osaurus-pr1268-319bfeb0-current-inventory-20260528-065436`.
- DSV4 JANGTQ2: `/tmp/osaurus-pr1268-319bfeb0-dsv4-jangtq2-20260528-065445`.
- Gemma3n unsupported boundary before guard: `/tmp/osaurus-pr1268-319bfeb0-gemma3n-boundary-20260528-065603`.

DSV4 result:

- PASS: required `line_count` routed to a structured tool call.
- PASS: tool-result follow-up produced visible answer with no DSML/protocol leakage.
- PASS: second required tool call after assistant/tool history routed to a structured tool call.
- Cache topology: 43 layers, 41 hybrid-pool/rotating-wrapper layers, 2 rotating layers, disk-backed restore required, TurboQuant KV layers 0.
- Boundary: stores/misses moved, but no disk L2 hit was proven in this short fresh row.

Gemma3n result and fix:

- Before the Osaurus-side guard, `gemma-3n-e2b-it-4bit` failed required-tool live proof by emitting visible `<|tool>model:model` fragments and no structured tool call.
- This is not a parser success case. vMLX main `cc3f5f4` correctly stops inferring Gemma3n tool support from `model_type` alone.
- Osaurus now blocks known unsupported Gemma3n local tool requests in `MLXService.validateRuntimePolicy` before decode and prevents the SwiftTransformers tokenizer fallback from injecting Gemma required-tool declarations/instructions for Gemma3n.
- Focused validation after source fix:
  - `MLXServiceRuntimePolicyTests`: 7/7 passed.
  - `SwiftTransformersTokenizerLoaderTests/gemma3nLocalTokenizerDoesNotInventRequiredToolContractFromFallback`: passed.
- Gemma3n remains unsupported for required tool calling until a native/stamped Gemma3n tool contract exists and passes live multi-turn proof.

## 2026-05-28 07:21 PDT - Latest-head DSV4 and ZAYA repeat-cache probes

Current Osaurus head: `13f7fd9455006d55242d77375a5c9dcf2841266c`.
Current vMLX main pin: `cc3f5f4dc1317ffa09c46050ba0847f495887747`.
No-sign/keychain-free app: `/Users/eric/osaurus-pr1268-live/build/DerivedData-pr1268-release-nosign-13f7fd94/Build/Products/Release/osaurus.app`.

Artifacts:

- DSV4 repeat-cache: `/tmp/osaurus-pr1268-13f7fd94-dsv4-repeat-cache-20260528-071614`.
- ZAYA CCA repeat-cache: `/tmp/osaurus-pr1268-13f7fd94-zaya-cca-repeat-cache-20260528-071813`.

DSV4 result:

- PASS: three identical required `line_count` requests routed to structured tool calls with exact args `red\ngreen\nblue`.
- PASS: no visible DSML/protocol leakage on any tool turn.
- Topology: 43 layers, 41 hybrid-pool/rotating-wrapper layers, 2 rotating layers, disk-backed restore required, TurboQuant KV 0.
- Boundary: disk L2 hits stayed `0`; misses/stores moved. Latest head no longer reproduces the earlier third-repeat tool-routing failure, but DSV4 warm disk-hit readiness remains unproven.

ZAYA result:

- PASS: three identical required `line_count` requests routed to structured tool calls with exact args `red\ngreen\nblue`.
- PASS: no visible protocol leakage on any tool turn.
- PASS: disk L2 reuse moved on repeat turns (`disk_hits +1` on turn 2 and `+1` on turn 3).
- Topology: 80 layers, 40 KV layers, 40 ZAYA CCA layers, `companion=zaya-cca`, disk-backed restore required, TurboQuant KV 0.
- Boundary: ZAYA CCA companion hits stayed `0` while CCA companion misses increased. Do not claim CCA companion-hit reuse from this PR; claim behavior correctness plus disk-L2 reuse only.

## 2026-05-28 07:33 PDT - Latest-head MiniMax Small JANGTQ proof

Artifact:

- MiniMax Small JANGTQ: `/tmp/osaurus-pr1268-23f0c39-minimax-small-jangtq-20260528-073239`.

Result:

- PASS: `minimax-m2.7-small-jangtq` routed turn 1 required `line_count` to a structured tool call.
- PASS: tool-result follow-up returned visible answer `Three lines were counted.` with no protocol/reasoning leak.
- PASS: turn 3 second required `line_count` after assistant/tool history routed to a structured tool call.
- Cache delta: `disk_l2_hits +1`, `disk_l2_misses +7`, `disk_l2_stores +5`.
- Topology: 62 full-KV layers, no SSM/Mamba, no CCA companion, no rotating layers, TurboQuant KV 0.
- Classification: pass. This supersedes the earlier MiniMax Small JANGTQ partial/disconnect boundary for this current app path.

Missing-family inventory:

- Artifact: `/tmp/osaurus-pr1268-23f0c39-missing-family-inventory-20260528-073227`.
- `bailing`, `hy3`, and `hunyuan` selected zero rows from the current `/v1/models` inventory. These remain import/model-availability blocked, not runtime-proven.

## 2026-05-28 07:37 PDT - Latest-head Gemma4 rotating-KV proof

Artifact:

- Gemma4 JANG_4M: `/tmp/osaurus-pr1268-77236bc4-gemma4-jang4m-20260528-073742`.

Result:

- PASS: `gemma-4-26b-a4b-it-jang_4m-crack` routed turn 1 required `line_count` to a structured tool call with exact multiline args.
- PASS: tool-result follow-up returned visible answer `There were 3 lines counted.` with no protocol/reasoning leak.
- PASS: turn 3 second required `line_count` after assistant/tool history routed to a structured tool call with exact args.
- Cache delta: `disk_l2_hits +0`, `disk_l2_misses +2`, `disk_l2_stores +4`.
- Topology: 30 layers, 5 KV layers, 25 rotating KV layers, disk-backed restore required, TurboQuant KV 0.
- Classification: pass with cache boundary. This row proves latest-head Gemma4 tool/history behavior and rotating topology, but still does not prove warm disk-hit reuse for Gemma rotating state.

## 2026-05-28 07:40 PDT - DSV4 five-repeat required-tool cache boundary

Artifact:

- DSV4 five-repeat cache probe: `/tmp/osaurus-pr1268-f93929ec-dsv4-repeat-cache-20260528-074001`.

Result:

- Turns 1, 2, 4, and 5 routed to structured `line_count` tool calls with exact args `red\ngreen\nblue` and no DSML/protocol leakage.
- Turn 3 routed to `line_count`, but the argument payload was the validator error object: missing required property `text`.
- Disk cache counters moved monotonically but never hit: `disk_l2_hits` stayed `0`, `disk_l2_misses` reached `10`, `disk_l2_stores` reached `5`.
- Topology stayed DSV4 hybrid pool: 43 layers, 41 hybrid-pool/rotating-wrapper layers, 2 rotating layers, disk-backed restore required, TurboQuant KV 0.
- Classification: fail for repeated required-tool argument stability and still no DSV4 disk-hit proof. Keep the fresh multi-turn DSV4 correctness row, but do not claim repeat-cache readiness for DSV4 JANGTQ2.

## 2026-05-28 07:44 PDT - DSV4 named-tool repeat isolation

Artifact:

- DSV4 named `line_count` repeat probe: `/tmp/osaurus-pr1268-3ba72413-dsv4-named-repeat-20260528-074419`.

Result:

- Named OpenAI tool-choice form (`{"type":"function","function":{"name":"line_count"}}`) improved the DSV4 repeat row but did not fully fix it.
- Turns 1 through 4 routed to structured `line_count` calls with exact args `red\ngreen\nblue` and no DSML/protocol leakage.
- Turn 5 routed to `line_count`, but args changed to `red\n green\n blue`, adding spaces before later lines. This is semantically line-count-equivalent but not an exact-argument pass.
- Disk L2 hits were proven in this isolation: turn 2 `disk_l2_hits +1`, turn 3 `disk_l2_hits +1`; final counters reached `disk_l2_hits=2`, `disk_l2_misses=17`, `disk_l2_stores=9`.
- Topology stayed DSV4 hybrid pool: 43 layers, 41 hybrid-pool/rotating-wrapper layers, 2 rotating layers, disk-backed restore required, TurboQuant KV 0.
- Boundary: named tool-choice is a useful DSV4 isolation and proves disk-hit movement, but repeated required/named tool-call argument exactness is still not stable enough to claim DSV4 repeat-cache readiness.

## 2026-05-28 13:16 PDT - Nemotron Omni MXFP4 exact-head required-tool/cache proof

Artifacts:

- Cold row: `/tmp/osaurus-pr1268-10df987c-nemotron-omni-mxfp4-required-cache-20260528-131529`.
- Warm row: `/tmp/osaurus-pr1268-10df987c-nemotron-omni-mxfp4-required-cache-warm-20260528-131559`.

Build/runtime boundary:

- Osaurus head: `10df987c5d58518a3be4d589ae5d1d942d59a9ce`.
- vMLX pin: `d83b22b3d0350aa45b5b853dd4838ea34af47497`.
- No-sign Release app: `/Users/eric/osaurus-pr1268-live/build/DerivedData/Build/Products/Release/osaurus.app`.
- Launch mode: keychain-free with `OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1`.

Result:

- PASS: cold row routed turn 1 required `line_count` to a structured tool call with exact args `red\ngreen\nblue`, no visible content, and no protocol leakage.
- PASS: cold row routed turn 3 second required `line_count` after assistant/tool history to a structured tool call with exact args `one\ntwo`, no visible content, and no protocol leakage.
- PASS: cold row tool-result follow-up returned visible answer `Three lines were counted.` with `finish_reason: "stop"`.
- PASS: warm row repeated the same multi-turn behavior and proved cache reuse with `disk_l2_hits +1`, `ssm_companion_hits +1`, and `companion_hits +1`.
- Topology: 29 layers, 6 KV layers, 23 Mamba/SSM layers, `companion=ssm`, disk-backed restore required, TurboQuant KV layers 0.
- Token/s: OpenAI-compatible tool turns emitted zero completion tokens; visible answer row emitted 6 completion tokens at 16.39 tok/s cold and 18.82 tok/s warm.
- Classification: pass for Nemotron Omni MXFP4 text required-tool/history/cache proof. This supersedes the earlier MXFP4 repeat-required red row; audio/video/resume behavior remains separate unproven coverage.

## 2026-05-28 13:43 PDT - DSV4 JANGTQ2 exact-head active-tool warm cache proof

Artifacts:

- Cold row: `/tmp/osaurus-pr1268-2455c4ce-dsv4-jangtq2-required-cache-cold-20260528-131817`.
- Warm row: `/tmp/osaurus-pr1268-2455c4ce-dsv4-jangtq2-required-cache-warm-20260528-133223`.

Build/runtime boundary:

- Osaurus head: `2455c4cec48ed0d613b9741fc1ebfa91152b9711`.
- vMLX pin: `d83b22b3d0350aa45b5b853dd4838ea34af47497`.
- No-sign Release app: `/Users/eric/osaurus-pr1268-live/build/DerivedData/Build/Products/Release/osaurus.app`.
- Launch mode: keychain-free with `OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1`.

Result:

- PASS: cold and warm rows routed turn 1 required `line_count` to a structured tool call with exact args `red\ngreen\nblue`, no visible content, and no DSML/protocol leakage.
- PASS: cold and warm rows routed turn 3 second required `line_count` after assistant/tool history to a structured tool call with exact args `one\ntwo`, no visible content, and no DSML/protocol leakage.
- PASS: cold and warm tool-result follow-ups returned visible line-count answers with `finish_reason: "stop"`.
- PASS: warm row proved DSV4 active-tool disk cache reuse with `disk_l2_hits +1`, `disk_l2_misses +0`, and `disk_l2_stores +5`.
- Topology: 43 layers, 41 hybrid-pool/rotating-wrapper layers, 2 rotating KV layers, disk-backed restore required, TurboQuant KV layers 0.
- Token/s: OpenAI-compatible tool turns emitted zero completion tokens; visible answer row emitted 21 completion tokens at 0.31 tok/s cold and 18 completion tokens at 0.32 tok/s warm.
- Boundary: functional/tool/cache proof is green for JANGTQ2 under the explicit harness max-token cap, but speed remains poor and JANGTQ-K generic required-tool behavior remains red/partial.

## 2026-05-28 13:46 PDT - Qwen 27B MXFP4 CRACK MTP exact-head SSM cache proof

Artifacts:

- Cold row: `/tmp/osaurus-pr1268-d7b700ca-qwen27-mxfp4-crack-mtp-required-cache-cold-20260528-134548`.
- Warm row: `/tmp/osaurus-pr1268-d7b700ca-qwen27-mxfp4-crack-mtp-required-cache-warm-20260528-134614`.

Build/runtime boundary:

- Osaurus head: `d7b700caf7b0e3b2d8e7fb66e0715136744565e2`.
- vMLX pin: `d83b22b3d0350aa45b5b853dd4838ea34af47497`.
- No-sign Release app: `/Users/eric/osaurus-pr1268-live/build/DerivedData/Build/Products/Release/osaurus.app`.
- Launch mode: keychain-free with `OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1`.

Result:

- PASS: cold and warm rows routed turn 1 required `line_count` to a structured tool call with exact args `red\ngreen\nblue`, no visible content, and no protocol leakage.
- PASS: cold and warm rows routed turn 3 second required `line_count` after assistant/tool history to a structured tool call with exact args `one\ntwo`, no visible content, and no protocol leakage.
- PASS: cold and warm tool-result follow-ups returned visible answer `3 lines were counted.` with `finish_reason: "stop"`.
- PASS: warm row proved hybrid cache reuse with `disk_l2_hits +1`, `ssm_companion_hits +1`, and `companion_hits +1`.
- Topology: 64 layers, 16 KV layers, 48 Mamba/SSM layers, `companion=ssm`, disk-backed restore required, TurboQuant KV layers 0.
- Token/s: OpenAI-compatible tool turns emitted zero completion tokens; visible answer row emitted 5 completion tokens at 6.44 tok/s cold and 5.78 tok/s warm.
- Boundary: this clears the baseline Qwen 27B MXFP4 CRACK MTP required-tool/cache row. It does not clear the separate large-context thinking/file-tool screenshot class, where prior evidence still shows a 1024-token thinking-budget length stop and no cache/SSM hit proof.

## 2026-05-28 13:51 PDT - ZAYA text JANGTQ4 exact-head required-tool/disk proof

Artifacts:

- Cold row: `/tmp/osaurus-pr1268-04dbc2cd-zaya-text-jangtq4-required-cache-cold-20260528-134803`.
- Warm row: `/tmp/osaurus-pr1268-04dbc2cd-zaya-text-jangtq4-required-cache-warm-20260528-135005`.

Build/runtime boundary:

- Osaurus head: `04dbc2cdd011a24a61fc45d32e27fd1790b92f13`.
- vMLX pin: `d83b22b3d0350aa45b5b853dd4838ea34af47497`.
- No-sign Release app: `/Users/eric/osaurus-pr1268-live/build/DerivedData/Build/Products/Release/osaurus.app`.
- Launch mode: keychain-free with `OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1`.

Result:

- PASS: cold and warm rows routed turn 1 required `line_count` to a structured tool call with exact args `red\ngreen\nblue`, no visible content, and no protocol leakage.
- PASS: cold and warm rows routed turn 3 second required `line_count` after assistant/tool history to a structured tool call with exact args `one\ntwo`, no visible content, and no protocol leakage.
- PASS: cold and warm tool-result follow-ups returned visible line-count answers with `finish_reason: "stop"`.
- PASS: warm row proved disk cache reuse with `disk_l2_hits +1`.
- Topology: 80 layers, 40 KV layers, 40 ZAYA CCA layers, `companion=zaya-cca`, disk-backed restore required, TurboQuant KV layers 0.
- Token/s: OpenAI-compatible tool turns emitted zero completion tokens; visible answer row emitted 5 completion tokens at 6.47 tok/s cold and 7 completion tokens at 11.71 tok/s warm.
- Boundary: this clears the previous ZAYA text turn-3 argument-fidelity failure and proves disk-L2 reuse. ZAYA CCA companion-hit depth remains partial because the warm row recorded `zaya_cca_companion_hits 0` and `zaya_cca_companion_misses +1`.

## 2026-05-28 14:29 PDT - Ling JANGTQ2 exact-head SSM cache proof

Artifacts:

- Cold row: `/tmp/osaurus-pr1268-722f138f-ling-jangtq2-required-cache-cold-20260528-142834`.
- Warm row: `/tmp/osaurus-pr1268-722f138f-ling-jangtq2-required-cache-warm-20260528-142907`.

Build/runtime boundary:

- Osaurus head: `722f138ff933a93fae226e6fb687c648fd3419a1`.
- vMLX pin: `d83b22b3d0350aa45b5b853dd4838ea34af47497`.
- No-sign Release app: `/Users/eric/osaurus-pr1268-live/build/DerivedData/Build/Products/Release/osaurus.app`.
- Launch mode: keychain-free with `OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1`.

Result:

- PASS: cold and warm rows routed turn 1 required `line_count` to a structured tool call with exact args `red\ngreen\nblue`, no visible content, and no protocol leakage.
- PASS: cold and warm rows routed turn 3 second required `line_count` after assistant/tool history to a structured tool call with exact args `one\ntwo`, no visible content, and no protocol leakage.
- PASS: cold and warm tool-result follow-ups returned visible line-count answers with `finish_reason: "stop"`.
- PASS: warm row proved hybrid cache reuse with `disk_l2_hits +1`, `ssm_companion_hits +1`, and `companion_hits +1`.
- Topology: 32 layers, 4 KV layers, 28 arrays/SSM companion layers, `companion=ssm`, disk-backed restore required, TurboQuant KV layers 0.
- Token/s: OpenAI-compatible tool turns emitted zero completion tokens; visible answer row emitted 10 completion tokens at 11.14 tok/s cold and 5 completion tokens at 7.43 tok/s warm.
- Boundary: this clears the Ling JANGTQ2 cache-partial row. Ling MXFP4 remains a separate timeout/app-exit red row.

## 2026-05-28 15:13 PDT - Qwen 27B MXFP4 Thinking file-tool final-answer cache proof

Artifact:

- `/tmp/osaurus-pr1268-380e7f96-qwen27-mxfp4-thinking-filetool-final-cache-2048-20260528-151216`.

Build/runtime boundary:

- Osaurus head: `380e7f9641518bb4b3a5d6baa398db63bfd76746`.
- vMLX pin: `d83b22b3d0350aa45b5b853dd4838ea34af47497`.
- No-sign Release app: `/Users/eric/osaurus-pr1268-live/build/DerivedData/Build/Products/Release/osaurus.app`.
- Launch mode: keychain-free with `OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1`.
- Model: `qwen3.6-27b-mxfp4-crack`.

Result:

- PASS: repeated the same file/tool-history final no-tool request twice with Thinking enabled, `enable_thinking=true`, `reasoning_effort=high`, `tool_choice: "none"`, and explicit `max_tokens: 2048`.
- PASS: both turns returned visible final answers with `finish_reason: "stop"`, no tool calls, no protocol leakage, and no `!!!!!!!!` loop.
- PASS: warm repeat proved hybrid cache reuse with `disk_l2_hits +1`, `ssm_companion_hits +1`, and `companion_hits +1`.
- Topology: 64 layers, 16 KV layers, 48 Mamba/SSM layers, `companion=ssm`, disk-backed restore required, TurboQuant KV layers 0.
- Token/s: first visible final answer emitted 537 completion tokens in 32.72s (`16.41 tok/s`); warm repeat emitted 327 completion tokens in 18.43s (`17.74 tok/s`).
- Boundary: this clears the previous Qwen Thinking/file-tool 2048-budget final-answer cache-hit gap. It does not reproduce or close the original large UI context screenshot at roughly `54k / 262k` tokens, and it does not justify hidden repetition penalties, parser repair, or synthetic max-token clamps.
