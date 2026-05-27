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
