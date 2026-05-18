# PR 1147 Completion Audit - vmlx-swift Switch

Timestamp: 2026-05-18 13:53 PDT

PR: https://github.com/osaurus-ai/osaurus/pull/1147

Head at audit: `67a24031`

This is a completion audit for the Osaurus switch to consolidated
`vmlx-swift`. It is intentionally not a production-clear report. The current
state is source-wired plus checklist-locked; the required real-user live matrix
is still open until artifact folders are attached for each row below.

## Objective Restated

The PR is production-ready only when Osaurus proves, through the chat app and
HTTP APIs, that consolidated `vmlx-swift` handles each local model family with:

- correct model discovery from files and weights, not names;
- correct UI defaults, visible controls, and saved-setting isolation;
- correct request construction for chat UI, `/v1/chat/completions`,
  `/v1/responses`, `/v1/messages`, `/api/chat`, and `/api/generate`;
- default cache stack behavior with prefix, paged, block L2, SSM companion,
  DSV4 native cache, ZAYA CCA, media cache, and TurboQuant KV declared active
  or N-A per topology;
- ON/OFF inverse rows for reasoning, tools, streaming, prefix cache, paged
  cache, block L2, VLM/media, MTP, sleep/wake, and diagnostic flags where
  valid;
- multi-turn visible coherency, no loops, no parser/tag leakage, and no
  hidden sampler or reasoning guard;
- TTFT, tok/s, RSS, Activity Monitor physical footprint, cache stats, and L2
  bytes for each live row;
- old standalone inference libraries removed from active Osaurus inference
  paths.

## Prompt-to-Artifact Completion Map

| Requirement | Current evidence | Missing before production-clear |
|---|---|---|
| Qwen VL / Qwen3.6 MTP VL through UI and APIs | Live matrix names Qwen3VLProcessor, MRoPE, media salt, video frame rows, native `top_k`, `chat_template_kwargs`, and `vmlx_mtp_tuning.json`. Local model census confirms Qwen3.6 MTP/VL bundles and processor files exist. | Osaurus chat-app image+text T1, text-only T2, different-image T3, repeated-media hit, video row, `/v1/chat/completions`, `/v1/responses`, saved settings, cache stats, TTFT/tok/s/RSS/footprint artifacts. |
| Gemma VL / Gemma reasoning | Live matrix separates Gemma4 VLM/Harmony from Gemma3n text-only partial evidence and requires media controls only after real detection. | Osaurus Gemma4 image/video/text rows, Harmony no-leak route rows, Gemma tool cards, cache stats, and a root cause for Gemma3n UTF drift before any production-clear text claim. |
| ZAYA / ZAYA-VL | Live matrix requires ZayaCCACache/path-dependent media state, no stale thinking carryover, no sampler clamp, and separate ZAYA-VL media rows. Local census confirms ZAYA text and VL variants plus ZAYA VL processor files. | Osaurus ZAYA-VL image/video/text-only resume rows, CCA cache proof, speed target watch, no cross-session media state reuse, and root-cause closure for current red ZAYA direct-mode rows. |
| Nemotron Omni / Parakeet / RADIO | Live matrix names Parakeet pre-encode, RADIO/vision facts, live voice chunk stability, repeated-video alias, and no reasoning-only short-budget false pass. Local census confirms Nemotron Omni variants and processor files. | Osaurus app/API audio/video/image/text-only resume rows, live voice resident pre-encode, cache stats, TTFT/tok/s/RSS/footprint, and unsupported-media error proof. |
| DSV4 Flash renderer and runtime | Source-policy tests pin native DSV4 cache copy, SWA+CSA+HSA, fixed/disabled block size 256, generic q4/q8 disabled, pool quant visible, JIT disabled, model metadata defaults, and invalid CLI flags omitted. | Final Osaurus UI screenshot/log and API artifacts proving those exact rendered settings, DSML tool rows, `reasoning_effort=max` pass-through, native cache stats, long/growing-chat behavior, TTFT/tok/s/footprint. |
| MiniMax reasoning/tools | Live matrix requires reasoning channel separation, MiniMax tool parser, no MTP from CRACK/name, cache stats, and no forced close or repetition penalty. | Osaurus UI/API multi-turn reasoning and tool-result artifacts with stream terminal usage and cache proof. |
| Ling / Hy3 / hybrid SSM | Live matrix requires stale Qwen thinking ignored, hybrid cache topology, SSM companion hits/misses/stores, and no KV-only unsafe hit. | Osaurus long-prompt, prefix-overlap, prefix-mismatch, API tool rows, re-derive status, cache stats, and TTFT/footprint artifacts. |
| GLM / GPT-OSS / Mistral / parser families | Live matrix requires parser from base architecture, no marker leakage, and tools only where supported. | Live local model rows when models are present; no production claim without artifacts. |
| Generation defaults and top-k | Live matrix requires UI defaults and omitted HTTP sampler fields to resolve from `generation_config.json` / `jang_config.json`, including native `top_k`. Local census confirms generation config files across target families. | Per-model resolved-kwargs logs from Osaurus UI and every API route; explicit sampler override proof; no hidden temperature/top-p/top-k/repetition floors. |
| Settings carryover and cache-key isolation | Live matrix names reasoning carryover, DSV4 `max` carryover, media carryover, cache OFF/ON restoration, tool/coding context carryover, and generation defaults. | App relaunch and cross-family switch artifacts proving stale reasoning/cache/media/tool settings do not enter another model's request or cache key. |
| Old-library and zombie-code removal | Source-policy tests assert consolidated `vmlx-swift` package pins and VMLX-prefixed imports for tokenizers/Jinja, plus no active old inference package names in current runtime source/docs. | Full final PR audit after all live rows to ensure no new old-library import or CLI path was introduced. |

## Local Model Census Snapshot

This snapshot is from `/Users/eric/models` at audit time. It is only a census,
not runtime proof.

Text / VLM / omni families found:

- DSV4: `/Users/eric/models/JANGQ/DeepSeek-V4-Flash-JANGTQ-K`,
  `/Users/eric/models/JANGQ/DeepSeek-V4-Flash-JANGTQ2`
- Qwen3.6 MTP/VL: `/Users/eric/models/JANGQ/Qwen3.6-27B-JANG_4M-MTP`,
  `/Users/eric/models/JANGQ/Qwen3.6-27B-MXFP4-MTP`,
  `/Users/eric/models/JANGQ/Qwen3.6-27B-MXFP8-MTP`,
  `/Users/eric/models/JANGQ/Qwen3.6-35B-A3B-MXFP4-MTP`,
  `/Users/eric/models/JANGQ/Qwen3.6-35B-A3B-MXFP8-MTP`
- Qwen3.6 non-MTP/CRACK/VL: `/Users/eric/models/dealign.ai/Qwen3.6-27B-JANG_4M-CRACK`,
  `/Users/eric/models/dealign.ai/Qwen3.6-27B-MXFP4-CRACK`,
  `/Users/eric/models/dealign.ai/Qwen3.6-35B-A3B-JANGTQ-CRACK`
- Gemma: `/Users/eric/models/dealign.ai/Gemma-4-26B-A4B-it-JANG_4M-CRACK`,
  `/Users/eric/models/mlx-community/gemma-3n-E2B-it-4bit`
- ZAYA: `/Users/eric/models/JANGQ/ZAYA1-8B-JANGTQ4`,
  `/Users/eric/models/JANGQ/ZAYA1-8B-JANGTQ_K`,
  `/Users/eric/models/JANGQ/ZAYA1-VL-8B-JANGTQ4`,
  `/Users/eric/models/JANGQ/ZAYA1-VL-8B-JANGTQ_K`,
  `/Users/eric/models/Osaurus/ZAYA1-8B-MXFP4`,
  `/Users/eric/models/Osaurus/ZAYA1-VL-8B-MXFP4`
- Nemotron Omni: `/Users/eric/models/dealign.ai/Nemotron-Omni-Nano-JANGTQ-CRACK`,
  `/Users/eric/models/dealign.ai/Nemotron-Omni-Nano-JANGTQ4-CRACK`,
  `/Users/eric/models/dealign.ai/Nemotron-Omni-Nano-MXFP4-CRACK`
- MiniMax: `/Users/eric/models/dealign.ai/MiniMax-M2.7-JANGTQ_K-CRACK`,
  `/Users/eric/models/dealign.ai/MiniMax-M2.7-JANG_K-CRACK`,
  `/Users/eric/models/JANGQ/MiniMax-M2.7-Small-JANGTQ`
- Ling/Hy3: `/Users/eric/models/dealign.ai/Ling-2.6-flash-JANGTQ2-CRACK`,
  `/Users/eric/models/dealign.ai/Ling-2.6-flash-MXFP4-CRACK`,
  `/Users/eric/models/JANGQ/Hy3-preview-JANGTQ`,
  `/Users/eric/models/JANGQ/Hy3-preview-JANGTQ_K`

Processor/tuning facts found:

- Qwen3.6 MTP/VL bundles have `preprocessor_config.json`,
  `video_preprocessor_config.json`, and `vmlx_mtp_tuning.json`.
- Qwen3.6 27B MXFP4 MTP tuning selects best depth 2 and explicitly says not to
  force D3 by default.
- Qwen3.6 27B JANG_4M, 27B MXFP8, 35B MXFP4, and 35B MXFP8 MTP tuning selects
  best depth 3 from validated output-equivalent rows.
- Qwen3.6 35B JANG_2K MTP tuning is blocked and must not auto-enable.
- ZAYA-VL and Nemotron Omni variants have VLM processor files where listed
  above.

## Live Artifact Contract

For each model row, use a folder under:

`docs/internal/live-gates/pr1147/<model-slug>/`

Each folder must contain:

- `bundle_census.json`
- `ui_model_picker.log` or screenshot reference
- `ui_chat_settings.log` or screenshot reference
- `ui_server_settings_cli_preview.log`
- `chat_ui_turns.json`
- `chat_completions_stream.jsonl`
- `chat_completions_nonstream.json`
- `responses_stream.jsonl`
- `responses_nonstream.json`
- `messages_stream.jsonl` and `messages_nonstream.json` when supported
- `ollama_chat_generate.json` when supported
- `cache_stats_before_after.json`
- `health_before_after.json`
- `process_memory.csv`
- `media_sequence.json` for VLM/omni rows
- `tool_reasoning_parser.json` for tool/reasoning rows
- `carryover_inverse.json`
- `summary.md`

The first required artifact can be collected without launching a model:

```sh
python3 scripts/pr1147_collect_bundle_census.py \
  --models-root /Users/eric/models \
  --output-dir docs/internal/live-gates/pr1147/bundle-census
```

That helper only reads local metadata and safetensors index files. It fails
closed for native MTP: `auto_enable` can become true only when real `mtp.*`
tensor evidence and a validated, unblocked `vmlx_mtp_tuning.json` are both
present.

Executed for this checkpoint:

- aggregate: `docs/internal/live-gates/pr1147/bundle-census/bundle_census.json`
- table: `docs/internal/live-gates/pr1147/bundle-census/summary.md`
- per-bundle files:
  `docs/internal/live-gates/pr1147/bundle-census/<model-slug>/bundle_census.json`

This closes the file-level census artifact only. It does not close live UI,
HTTP, cache-hit, coherency, media, parser, or memory proof.

## Current Audit Outcome

Not complete.

The PR currently has strong source-policy gates, documented model-family
contracts, and startup/server binding proof. It does not yet have the full live
Osaurus app/API artifact set for Qwen VL, Gemma VLM, ZAYA-VL, Nemotron Omni,
DSV4, MiniMax, Ling, Hy3, and other parser families. Do not undraft or call the
switch production-ready until those artifact folders exist and pass with real
visible output, cache stats, timing, memory, and no parser/tag leakage.
