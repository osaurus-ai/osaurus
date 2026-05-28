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
