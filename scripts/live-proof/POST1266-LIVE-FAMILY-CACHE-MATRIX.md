# Post-1266 live family cache/tool matrix

This follow-up is stacked because PR `#1266` is still open and draft at `878cabdbd2ccf2d581c0eda4b2537478e4343feb`.

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
