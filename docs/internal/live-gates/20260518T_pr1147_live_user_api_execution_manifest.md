# PR 1147 Live User/API Execution Manifest

Timestamp: 2026-05-18 14:52 PDT

Scope: consolidated `vmlx-swift` switch live proof for Osaurus PR #1147.

This is an execution manifest, not a pass report. A row is green only when the
artifact folder named here contains real app/API output, cache counters, timing,
memory, and no-leak review. File-level census, source tests, or a load-only row
can close only their own subcheck.

## Source Anchors to Verify During Live Rows

These source files are the wiring that every live row must exercise:

| Surface | Source anchor | Live proof required |
|---|---|---|
| Model load and vmlx ownership | `Packages/OsaurusCore/Services/ModelRuntime.swift` | `LoadConfiguration.default`, vmlx-owned cache coordinator, typed events, no app-side generic DSV4 cache forcing. |
| Batch/VLM adapter | `Packages/OsaurusCore/Services/ModelRuntime/MLXBatchAdapter.swift` | Chat builder preserves image/video/audio parts, assistant reasoning, tool calls, and tool-result ids into vmlx input. |
| Event mapping | `Packages/OsaurusCore/Services/ModelRuntime/GenerationEventMapper.swift` | Reasoning, text, tool-call, usage, and terminal events stay in separate UI/API channels. |
| Bundle defaults | `Packages/OsaurusCore/Services/LocalGenerationDefaults.swift` | Omitted sampler fields resolve from `jang_config.json > chat.sampling_defaults`, then `generation_config.json`, including native `top_k`. |
| Media capability detection | `Packages/OsaurusCore/Models/Configuration/ModelMediaCapabilities.swift` | Qwen/Gemma/ZAYA/Nemotron image, video, and audio controls match real bundle capability. |
| Family/profile split | `Packages/OsaurusCore/Models/Configuration/ModelFamilyNames.swift` and `ModelManager.swift` | DSV4, MiniMax, Ling, ZAYA-VL, Nemotron, Qwen, Gemma, Hy3 profiles do not inherit stale reasoning/parser/cache settings. |
| HTTP adapters | `Packages/OsaurusCore/Networking/HTTPHandler.swift` | `/v1/chat/completions`, `/v1/responses`, `/v1/messages`, `/api/chat`, `/api/generate` all preserve media, tools, reasoning, streaming terminal frames, and usage. |
| Old library removal | `Packages/OsaurusCore/Package.swift` plus SwiftPM lockfiles | Active inference uses the single `vmlx-swift` dependency and VMLX-prefixed Tokenizers/Jinja products. |

## Required Artifact Shape

Every live model folder must live under:

`docs/internal/live-gates/pr1147/<model-slug>/`

Each folder must include:

- `bundle_census.json`: copied from the file-level census for the exact bundle.
- `ui_model_picker.log` or screenshot: model path, served name, capability
  badges, MTP/VLM/reasoning/parser/cache labels.
- `ui_chat_settings.log` or screenshot: visible/default controls after model
  selection and after saved-setting reload.
- `ui_server_settings_cli_preview.log`: cache, batching, sleep/wake, generation
  defaults, tools, reasoning, VLM, MTP, and CLI preview.
- `health_before_after.json`: before/after load, after turn 1, after turn 2,
  and after sleep/wake if applicable.
- `cache_stats_before_after.json`: prefix, paged, block-L2, SSM companion,
  DSV4 native, ZAYA CCA, media cache, and TurboQuant KV fields where valid.
- `process_memory.csv`: time, process, RSS, and Activity Monitor physical
  footprint sample points.
- `chat_ui_turns.json`: full user-visible turn sequence, token counts, tok/s,
  TTFT, stop reason, and output tail review.
- `api_routes/`: raw route output files for stream and non-stream APIs.
- `tool_reasoning_parser.json`: reasoning channel, visible content, tool-call
  schema, tool-result turn, and marker leak scan.
- `media_sequence.json`: required for VLM/omni rows.
- `carryover_inverse.json`: saved settings, family switch, cache OFF/ON, and
  route inverse results.
- `summary.md`: status, failures, root cause, and whether the row is blocked,
  partial, or pass.

## Live Family Rows

| Family row | Local bundle examples | UI defaults and visuals | Live user sequence | API sequence | Cache/memory proof | Parser/no-leak proof |
|---|---|---|---|---|---|---|
| DSV4 Flash | `/Users/eric/models/JANGQ/DeepSeek-V4-Flash-JANGTQ-K` | Reasoning default `instruct`; `max` selectable and passed unchanged; native DSV4 cache copy visible; block size fixed/disabled at 256; generic q4/q8 KV and JIT hidden/disabled; pool quant visible. | Cold T1, follow-up T2, long/growing chat T3, stop/retry, switch away/back. | Chat, Responses, Messages where mapped, Ollama; DSML tools on/off. | `DeepseekV4Cache`, SWA+CSA+HSA, pool quant, native cache stats, TTFT, tok/s, footprint, L2 bytes when valid. | DSML tool calls structured, tool result ordered, no DSML/instruct markers in visible text, no forced think close or sampler guard. |
| Qwen VL / Qwen3.6 MTP VL | `/Users/eric/models/JANGQ/Qwen3.6-27B-MXFP4-MTP`, MXFP8/35B variants, non-MTP CRACK controls | Qwen reasoning maps to `enable_thinking`; VLM controls only when processor files exist; MTP visible only from real `mtp.*` tensors plus valid `vmlx_mtp_tuning.json`. | Image+text T1, text-only T2, different-image T3, video row, save/relaunch, MTP on/off when valid. | Chat/Responses stream and non-stream with media parts, omitted sampler fields, explicit `chat_template_kwargs`, native `top_k`. | Qwen3VLProcessor, MRoPE/media salt nil on T2, repeated media hit, different media miss, prefix/paged/L2, MTP effective depth, tok/s, footprint. | `<think>` separated, Qwen tool XML parsed into `tool_calls`, tool result ordered, no stale DSV4/Ling parser. |
| Gemma4 / Gemma VLM | `/Users/eric/models/dealign.ai/Gemma-4-26B-A4B-it-JANG_4M-CRACK` | Harmony controls only for Harmony-capable models; media controls only after real VLM detection; Gemma3n text evidence must not enable VLM controls. | Image+text, text-only follow-up, video/image switch if supported, settings save/reload, code/math prompt with enough tokens to catch loops. | Chat/Responses/Messages where mapped; tool-call row for Gemma parser, stream and non-stream. | Sliding-window or heterogeneous cache topology visible; no app-forced global max KV; prefix/paged/L2, TTFT, RSS/footprint. | Harmony analysis/final split preserved, Gemma tool card structured, no Harmony/Gemma marker leak. |
| Gemma3n text | `/Users/eric/models/mlx-community/gemma-3n-E2B-it-4bit` | Text-only unless a separate live media proof exists. | Multi-turn math, code, UTF literal, reasoning on/off hidden if unsupported, cache on/off. | Chat/Responses stream and non-stream. | Prefix/paged/L2 disk counters, TTFT, tok/s, footprint. | UTF drift is red until root-caused; do not mask with sampler clamps. |
| ZAYA / ZAYA-VL | `/Users/eric/models/JANGQ/ZAYA1-VL-8B-JANGTQ4`, `/Users/eric/models/Osaurus/ZAYA1-VL-8B-MXFP4` | Default no-thinking unless explicitly supported; ZAYA-VL media controls require real VL bundle; direct-mode red rows stay red. | Image/video grounded T1, text-only resume T2, different media T3, switch text-only and back, saved-thinking isolation. | Chat/Responses with media, tools only if capability detected. | ZayaCCACache/path-dependent media state, media salt hit/miss, prefix/paged/L2 where valid, tok/s target watch, footprint. | No stale Qwen/DSV4 thinking, no CCA state attached to wrong media, no parser marker leak. |
| Nemotron Omni / Parakeet / RADIO | `/Users/eric/models/dealign.ai/Nemotron-Omni-Nano-*` | Audio/video/image controls only with omni capability files/runtime; live-voice status separate from text-only readiness. | Audio/pre-encode T1, text-only T2, image/video T3 where supported, repeated-video hit, sleep/wake. | Chat/Responses with media, Messages when mapped, unsupported-media clean error. | Parakeet pre-encode, RADIO/vision evidence, media salt, repeated-media alias, path-dependent stats, TTFT, tok/s, footprint. | Nemotron tool parser structured, no XML marker leak, no reasoning-only short-budget false pass. |
| MiniMax | `/Users/eric/models/dealign.ai/MiniMax-M2.7-*` | Reasoning UI visible for reasoning-capable MiniMax; MTP hidden unless real MTP tensors exist. | Multi-turn reasoning, tool-call card, save/relaunch, switch from DSV4/Qwen and verify no stale parser. | Chat/Responses tools on/off, second turn tool result, terminal usage. | Prefix/paged/L2/TurboQuant KV status when valid, no permanent overlay, tok/s, footprint. | MiniMax reasoning rail separate, MiniMax XML/JSON parser selected from base architecture, no forced close/repetition penalty. |
| Ling / Hy3 / hybrid SSM | `/Users/eric/models/dealign.ai/Ling-2.6-flash-*`, `/Users/eric/models/JANGQ/Hy3-preview-*` | Non-reasoning or family-specific controls only; stale Qwen thinking hidden/ignored; SSM rederive status explicit. | Long prompt T1, prefix-overlap T2, prefix-mismatch T3, stop/retry, cancel cleanup. | Chat/Responses with tools on/off where supported, omitted/explicit sampler defaults. | SSM companion hits/misses/stores, no KV-only unsafe hit, paged/L2, rederive status, TTFT, footprint. | GLM/Hunyuan/Ling markers do not leak; tool result order preserved. |
| GLM / GPT-OSS / Mistral / other local parsers | Local only when present | Parser and reasoning controls from base architecture, not display name. | One UI row per local family with saved-setting isolation and enough output tokens to catch leaks/loops. | Chat/Responses/Messages/Ollama where applicable, tool result follow-up. | Declared dense/sliding/hybrid topology, cache stats, TTFT, tok/s, RSS. | Harmony, bracket-think, GLM/Hunyuan, Mistral, JSON, and tool sentinels do not leak. |

## Inverse Rows

Each inverse row must include an OFF run, an ON-again run, and a statement about
whether the layer is topology-valid for the selected model.

| Inverse | OFF proof | ON-again proof |
|---|---|---|
| Reasoning | Unsupported families send no stale `enable_thinking`, `reasoning_effort`, or parser field; supported families with OFF produce no visible/private reasoning leak. | Supported families put reasoning only in reasoning channel, not visible content. |
| Tools | `tools=[]` and omitted tools do not invoke parser or inject schema. | Tool call is structured, second turn tool result is handled, no raw schema leak. |
| Streaming | `stream=false` returns one JSON object with finish reason and usage. | SSE/Ollama stream ends with proper terminal frame and usage. |
| Prefix cache | Disabled row has no second-turn prefix hit and still coherent output. | Enabled row has lower TTFT/hit counters on repeated/prefix-overlap turn. |
| Paged KV | Disabled row shows topology-safe fallback and no stale block counters. | Enabled row allocates or reuses blocks where valid. |
| Block L2 disk | Disabled row writes no new L2 cache bytes. | Enabled row writes/hits bytes and honors configured max size. |
| VLM/media | Text-only or force-off row rejects media cleanly. | Supported model accepts media and media salt/cache behaves per turn. |
| MTP | Non-MTP bundles show disabled with reason `no mtp tensor evidence` or blocked tuning; no CRACK/name-only enable. | Valid Qwen MTP bundles use `vmlx_mtp_tuning.json` depth and report effective speed/coherence/cache. |
| Sleep/wake | Sleep disabled keeps model resident per policy. | Deep sleep frees memory and wake generates without invalid cache reuse. |
| Diagnostic flags | Invalid generic flags are absent for DSV4 and VLM/MTP where topology owns the setting. | Valid topology-specific settings display and apply only to the owning family. |

## Request Construction Checks

For every model row and every supported route:

1. Omit sampler fields and capture resolved parameters. They must come from
   `jang_config.json > chat.sampling_defaults` first, then
   `generation_config.json`. Native `top_k` must not be dropped.
2. Send explicit sampler fields and prove they are preserved exactly. No
   hidden temperature, top-p, top-k, min-p, repetition, or EOS guard may be
   added to hide bad output.
3. Send family reasoning OFF/default/ON/max where applicable. Unsupported
   families must hide/ignore the setting and not include it in cache scope.
4. Send tool OFF/ON/tool-result rows. Tool schemas and tool results must be
   part of prompt construction only for tool-capable rows.
5. For VLM/omni rows, send image, text-only follow-up, different image, repeat
   image, video if supported, and audio if supported.
6. Capture the final request payload or sanitized structured summary so saved
   settings and route adapters can be audited without secrets.

## UI and Saved-Setting Carryover Checks

Run these in the chat app after a keychain-safe launch:

1. Select Qwen, enable thinking, quit/reopen, switch to Ling/non-reasoning.
   No stale thinking field, reasoning parser, or cache-key component may enter
   the request.
2. Select DSV4, set `reasoning_effort=max`, send a request, switch to
   Qwen/Gemma/ZAYA/Nemotron, then back. Only DSV4 may retain/pass `max`.
3. Start a VLM chat with image/video, switch to text-only, then back to VLM.
   Media salt/cache state must not cross model/session boundaries.
4. Disable prefix/paged/L2 for an inverse row, switch models, return, enable
   again, and prove counters/hits restore only on valid topology.
5. Run tool/coding context injection, switch to no-tools model, and prove no
   tool schema/result marker appears in visible content or cache scope.
6. Inspect send/stop/retry/edit/copy, thinking panel collapse, tool-call card,
   media preview, unsupported-media error, token/s/usage display, sleep/wake,
   and model load/error/ready/generating visual states.

## Current Status

- `docs/internal/live-gates/pr1147/bundle-census/` closes file-level bundle
  census only.
- `scripts/pr1147_http_route_probe.py` is available for route capture but is
  not model proof by itself.
- `docs/internal/live-gates/20260518T_pr1147_keychain_safe_launch.md` is
  mandatory before app/API live gates. Fake-`HOME` direct binary launches are
  invalid.
- No row in this manifest is production-clear until its model folder contains
  the required live artifacts and `summary.md` says PASS with concrete output,
  cache, timing, memory, and no-leak evidence.
