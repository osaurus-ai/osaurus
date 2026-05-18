# PR 1147 Component Edge-Case Matrix

Timestamp: 2026-05-18 14:48 PDT

Scope: Osaurus PR #1147 real-user live gate for the consolidated
`vmlx-swift` engine package.

This file is a checklist, not a pass report. A row is green only when the named
artifact exists under `docs/internal/live-gates/pr1147/<model-slug>/` and shows
real chat-app or HTTP behavior with output review, cache counters, timing,
memory, and parser/no-leak evidence. Source-policy tests, bundle census, and
metadata routes can close only their own subchecks.

## Current Evidence Boundary

| Area | Current status | Evidence | Still required |
|---|---|---|---|
| Bundle census | PASS for file-level metadata | `pr1147/bundle-census/` | Live app/API proof for every selected bundle. |
| Keychain-safe app launch | PASS for metadata launch path | `20260518T_pr1147_keychain_safe_launch.md` | Reuse for model rows; do not use fake `HOME`. |
| Metadata routes | PARTIAL | `http-route-probe-metadata-20260518Tpost-cache-stats/` | Generation routes with loaded models, stream tails, usage, and cache stats. |
| `/admin/cache-stats` route existence | PASS cold route | `get_admin_cache-stats.body` shows empty `models` and zero counters | Loaded-model cache-hit, L2 write, SSM rederive, and media-cache rows. |
| ZAYA-VL live sequence | FAIL / PARTIAL | `pr1147/zaya1-vl-8b-mxfp4/vlm-sequence-20260518T1504/review.md` plus `ChatEngineTests.openResponsesRequest_preservesInputImageIntoChatRequest` | Root-cause blue-image stale red answer, rerun source-fixed Responses image grounding live, fix or hide unsupported video exposure, and rerun cache proof with non-immediate residency or stream-time snapshots. |
| Model production readiness | NOT COMPLETE | Manifest and this matrix | Real visible multi-turn output, no loops/leaks, TTFT, tok/s, RSS, physical footprint, and per-topology cache proof. |

## Source-To-Artifact Wiring

| Source surface | What it owns | Artifact proof required |
|---|---|---|
| `ModelOptions.swift` | Reasoning UI controls and defaults: DSV4 `instruct/high/max`, Qwen/Nemotron/ZAYA disable-thinking toggles, Hy3 `no_think/low/high`, Ling no exposed thinking control. | `ui_chat_settings.log`, `carryover_inverse.json`, and route payload summaries showing selected values enter only valid model families. |
| `ModelMediaCapabilities.swift` | Chat-composer media controls: Qwen/Holo image+video, Gemma image-only unless bundle proves more, Nemotron Omni image+video+audio, ZAYA-VL image/video by real bundle capability. | `ui_chat_settings.log`, `media_sequence.json`, and unsupported-media row proving controls match capability and errors are clean. |
| `LocalGenerationDefaults.swift` | Omitted sampler defaults: `jang_config.json > chat.sampling_defaults` first, then `generation_config.json`, including native `top_k`. | Route payload/resolved-default logs for omitted fields and explicit override logs showing no hidden temp/top-p/top-k/min-p/repetition guards. |
| `MLXBatchAdapter.swift` | Chat history, media parts, assistant reasoning, tool calls, and tool-result ids passed into vmlx input. | `chat_ui_turns.json`, `tool_reasoning_parser.json`, and route artifacts for chat, responses, messages, and Ollama where supported. |
| `GenerationEventMapper.swift` | Channel separation: reasoning deltas, visible content, tool calls, usage, terminal frames. | Stream artifacts with first/last frames, final usage, no reasoning/tool marker leakage into visible content. |
| `ModelRuntime.swift` | vmlx load configuration, loaded model ownership, cache coordinator snapshot, process lifecycle. | `health_before_after.json`, `cache_stats_before_after.json`, `process_memory.csv`, sleep/wake and cancel rows. |
| `HTTPHandler.swift` | OpenAI, Responses, Anthropic Messages, Ollama, health, cache stats, streaming and non-streaming route behavior. | `api_routes/` with stream and non-stream rows, status, content type, first/last frame, terminal usage, and errors. |
| SwiftPM package graph | One consolidated `vmlx-swift` inference dependency with VMLX-prefixed Jinja/Tokenizers products. | Final zombie-code sweep after live rows; no active old `vmlx-swift-lm`, standalone `Jinja`, standalone `swift-transformers`, or old `mlx-swift` inference path. |

## Per-Family Live Matrix

| Family | Bundle examples | Required UI defaults | Required media and turn sequence | Cache and scheduler proof | Parser/reasoning/tool proof | Red-row rule |
|---|---|---|---|---|---|---|
| DSV4 Flash | `JANGQ/DeepSeek-V4-Flash-JANGTQ-K`, `JANGQ/DeepSeek-V4-Flash-JANGTQ2` | Reasoning mode defaults to `instruct`; `Reasoning` maps to high; `Max` passes `reasoning_effort=max`; native DSV4 cache copy, SWA+CSA+HSA, pool quant visible; block size fixed/disabled at 256; generic q4/q8 and JIT controls disabled. | Text T1, prefix-follow-up T2, long/growing chat T3, stop/retry, switch away/back. | `DeepseekV4Cache`; DSV4-native cache stats; generic paged marked N-A when `pagedIncompatible=true`; L2 bytes and hit counters if valid; TTFT/tok/s/RSS/physical footprint. | DSML tools on/off; tool result ordering; visible text has no raw DSML or instruct markers; no forced think close; no sampler/repetition guard. | Any loop, `reasoning_effort=max` downgrade, generic cache misuse, or DSML leak is FAIL. |
| Qwen3.6 MTP/VL | `Qwen3.6-27B-MXFP4-MTP`, `Qwen3.6-27B-MXFP8-MTP`, `Qwen3.6-35B-A3B-MXFP4-MTP`, `Qwen3.6-35B-A3B-MXFP8-MTP`, `Qwen3.6-27B-JANG_4M-MTP` | Disable Thinking default ON; VLM controls only when processor files exist; MTP shown only when real `mtp.*` tensors and valid `vmlx_mtp_tuning.json` allow it. | Image+text T1, text-only T2 with media salt nil/absent, same image repeat hit, different image miss, video-frame row, saved/relaunch row, MTP on/off row where valid. | Qwen3VLProcessor, MRoPE, prefix/paged/block-L2, media cache alias, effective MTP depth from tuning, accepted tokens per verify, TTFT/tok/s/RSS/physical footprint. | `<think>` split when ON, no thinking when OFF, Qwen tool XML into `tool_calls`, tool result preserved, no stale DSV4/Ling parser. | CRACK/name-only MTP activation is FAIL; ignored `vmlx_mtp_tuning.json` is FAIL; video path without cache/memory proof is PARTIAL. |
| Qwen non-MTP control | Qwen3.6 CRACK or MXFP CRACK rows with no `mtp.*` tensor evidence | Thinking behavior from profile; MTP hidden/disabled with explicit `no mtp tensor evidence`. | Text multi-turn plus image/video only when real VLM processor evidence exists. | Prefix/paged/L2 proof without MTP; no MTP speed claim. | Qwen reasoning/tool parser separation. | Any MTP auto-enable from display name is FAIL. |
| Gemma4 / Gemma VLM | `dealign.ai/Gemma-4-26B-A4B-it-JANG_4M-CRACK` | Gemma VLM media controls only after real capability; Harmony/Gemma reasoning controls only when capability exists; Gemma3n text evidence must not enable Gemma4 VLM controls. | Image+text, text-only follow-up, image switch, video only if bundle/runtime proves support, long code/math output to catch loops. | Sliding-window or heterogeneous cache topology surfaced; prefix/paged/L2 counters; no app-forced global KV shape; TTFT/tok/s/RSS/physical footprint. | Harmony/thought/final separation where valid; Gemma tool card structured; no raw Harmony/Gemma markers in visible text. | Gemma3n UTF drift and any looping stay red until root-caused; no sampler clamp. |
| Gemma3n text | `mlx-community/gemma-3n-E2B-it-4bit` | Text-only unless a separate media-capability proof exists; unsupported reasoning hidden. | Multi-turn math, code, literal UTF, cache on/off. | Prefix/paged/L2 counters, TTFT/tok/s/RSS/physical footprint. | No unsupported reasoning field; no marker leakage. | UTF drift or incoherence is FAIL/PARTIAL, never repaired in UI output. |
| ZAYA / ZAYA-VL | `JANGQ/ZAYA1-VL-8B-JANGTQ4`, `JANGQ/ZAYA1-VL-8B-JANGTQ_K`, `Osaurus/ZAYA1-VL-8B-MXFP4`, text ZAYA controls | Default no-thinking unless supported; ZAYA-VL media controls require real VL bundle; text and VL profiles cannot share stale thinking/media state. | Image/video grounded T1, text-only T2, different media T3, text-only model switch and back, saved-thinking isolation. | ZayaCCACache/path-dependent media state, media salt hit/miss, prefix/paged/L2 where valid, speed target watch, memory footprint. | No stale Qwen/DSV4 parser; no CCA state attached to wrong media; tools only if capability says yes. | Known ZAYA direct-mode math red row remains red until root-caused; do not hide with temp/top-k/repetition/forced thinking. |
| Nemotron Omni / Parakeet / RADIO | `dealign.ai/Nemotron-Omni-Nano-*` | Audio/video/image controls only with Omni sidecar/runtime; live voice state separate from text-only readiness; no media reasoning UI unless grounded media-thinking row exists. | Audio/pre-encode T1, image T1, video T1, text-only T2, repeated-video hit, unsupported-media error, sleep/wake. | Parakeet pre-encode reuse, RADIO/vision evidence, media salt, raw-to-effective media cache alias, repeated-media hit, TTFT/tok/s/RSS/physical footprint. | Nemotron tool parser structured; no XML marker leak; no reasoning-only short-budget false pass. | Media row that only proves text path is PARTIAL; reasoning-only max-token output is FAIL. |
| MiniMax | `MiniMax-M2.7-JANGTQ_K-CRACK`, `MiniMax-M2.7-JANG_K-CRACK`, `MiniMax-M2.7-Small-JANGTQ` | Reasoning UI visible for reasoning-capable MiniMax; MTP hidden unless real `mtp.*` tensors exist. | Multi-turn reasoning, tool call card, save/relaunch, switch from DSV4/Qwen and verify no stale parser. | Prefix/paged/L2/TurboQuant KV where valid, B=1 and B=2 when feasible, no permanent overlay, tok/s/RSS/physical footprint. | MiniMax reasoning rail separate; MiniMax XML/JSON parser selected from base architecture; tool result second turn. | No forced close tag, repetition penalty, or name-only MTP. |
| Ling / Hy3 hybrid SSM | `Ling-2.6-flash-*`, `Hy3-preview-*` | Ling exposes no generic thinking control; Hy3 exposes `no_think/low/high`; stale Qwen thinking ignored. | Long prompt T1, prefix-overlap T2, prefix-mismatch T3, cancel/stop/retry. | SSM companion hits/misses/rederives, no KV-only unsafe hit, paged/L2, async rederive status, TTFT/tok/s/RSS/physical footprint. | GLM/Hunyuan/Ling markers do not leak; tool result order preserved when tools are supported. | Any KV-only hit without SSM companion state is FAIL. |
| GLM / GPT-OSS / Mistral / local parser families | Present local bundles only | Parser/reasoning controls from base architecture, not display name. | One UI row per present family with enough output tokens to catch leaks and loops. | Declared dense/sliding/hybrid topology, prefix/paged/L2, TTFT/tok/s/RSS. | Harmony, bracket-think, GLM/Hunyuan, Mistral, JSON, and tool sentinels stay out of visible content. | N-A only when bundle path is absent and the path checked is recorded. |
| Kimi | Excluded for this PR unless user re-adds it | N-A | N-A | N-A | N-A | Do not spend this PR budget on Kimi. |

## Required Live Sequences

### VLM / Omni Sequence

For Qwen3.6 VL/MTP, Gemma VLM, ZAYA-VL, and Nemotron Omni:

1. Launch app with `scripts/pr1147_keychain_safe_app_launch.sh`.
2. Select exact model in UI; capture model picker and chat settings visuals.
3. Record `/health` and `/admin/cache-stats` before load.
4. Turn 1: image+text, or audio/video for Omni where valid. Capture visible answer, reasoning channel, token counts, TTFT, tok/s, RSS, physical footprint, and cache stats.
5. Turn 2: text-only same session. Confirm media salt is nil/absent and longest-prefix resume/prefix-cache behavior is topology-valid.
6. Turn 3: different image/video. Confirm new media miss and correct grounding.
7. Repeat original media. Confirm media cache hit or explicit N-A with reason.
8. Run `/v1/chat/completions` stream and non-stream and `/v1/responses` stream and non-stream with the same media shape.
9. Run unsupported-media inverse on a text-only model and confirm clean 400/422-style error, not a hang or stack trace.

Cache-proof VLM rows must record the app/server idle-residency mode. Immediate
unload can remove the model from `ModelRuntime.cachedModelSummaries()` before a
non-streaming after-snapshot runs, so empty `/health.loaded` and
`/admin/cache-stats.models` are not cache-hit evidence. Use non-immediate
residency or stream-time snapshots before the generation lease releases.

### Reasoning / Parser Sequence

For every family with reasoning or tool support:

1. Reasoning OFF/default/ON/max where valid.
2. Verify request payload fields: `enable_thinking`, `reasoning_effort`, or `chat_template_kwargs` must match the family contract.
3. Stream and non-stream route review: reasoning appears only in reasoning channel; visible text has no `<think>`, Harmony, DSML, Qwen XML, MiniMax XML, Gemma, Mistral, or GLM sentinels unless they are intentionally visible model content.
4. Tool OFF with omitted `tools` and `tools=[]`: no parser activation and no injected schema.
5. Tool ON with `tool_choice=auto`: structured `tool_calls`, no raw schema leak into content.
6. Second turn with tool result: order preserved and visible answer coherent.
7. Coding/tool context injection: enable coding context/tool search, switch to a no-tools or different-parser model, and prove no stale schema/result enters the request or cache key.

### Cache / Memory Sequence

For each representative attention/cache topology:

1. Prefix cache OFF: repeated prompt has no prefix hit and remains coherent.
2. Prefix cache ON: repeated/prefix-overlap turn shows hit counter increment and lower TTFT.
3. Paged KV OFF/ON: disabled row has no stale allocated/shared blocks; enabled row allocates/reuses blocks where topology-valid.
4. Block L2 OFF/ON: disabled row writes no cache files; enabled row records L2 bytes, hits/stores, and configured max-GB behavior.
5. Hybrid SSM: prefix hit is accepted only with matching SSM companion state or explicit rederive; no KV-only unsafe hit.
6. DSV4: generic paged counters can be N-A only when native DSV4 cache owns the path; native stats and pool quant must be visible.
7. Media cache: nil/absent salt on text-only turn, same-media hit, different-media miss, raw-to-effective alias for EVS/video rows.
8. Memory: record RSS and Activity Monitor physical footprint before load, after load, after each turn, after cache hit, after sleep, and after wake.

### Startup / Lifecycle Sequence

1. Process inventory before launching: no stray PR Osaurus or Swift engine jobs.
2. Keychain-safe app launch only; fake `HOME` artifacts are invalid.
3. `/health`, `/v1/models`, `/models`, `/tags`, `/mcp/health`, `/admin/cache-stats` metadata probe.
4. Load one model through UI; verify tray/status and model-ready state.
5. Mid-stream cancel: request stops, in-flight returns to zero, no zombie request.
6. Sleep/wake: memory drops; wake generates without invalid cache reuse.
7. Quit app; listener gone; no orphaned Swift engine.

## Saved-Setting And Cache-Key Inverses

| Switch | Required proof |
|---|---|
| Qwen thinking to Ling/Hy3 | Enable Qwen thinking, quit/reopen, switch to Ling and Hy3. Ling sends no thinking field; Hy3 sends only its native `reasoning_effort` value. |
| DSV4 `max` to other families | Set DSV4 Max, switch to Qwen/Gemma/ZAYA/Nemotron, then back. Only DSV4 retains/passes `max`; others do not inherit it. |
| VLM to text-only | Start with image/video, switch to text-only model/session. No media salt, media cache key, processor state, or image placeholder enters text-only request. |
| Text-only back to VLM | Return to VLM. Media controls and processor path restore only for that model; prior text cache does not attach to media turn. |
| Cache OFF/ON | Disable prefix/paged/L2, run a turn, switch models, re-enable. Counters restore only on valid topology and do not reuse stale disabled-state cache. |
| Tool/coding context | Enable coding prompt/tool schema injection, switch to no-tools model. No tool schema, tool result id, or coding context leaks into visible output or cache key. |
| Sampler defaults | Omitted sampler fields resolve from bundle files; explicit request fields override exactly. OFF rows must not silently alter sampler defaults. |
| Forced behavior audit | Search source, settings previews, prompt dumps, and live output for forced sampler defaults, forced repetition penalties, forced reasoning rail selection, forced `</think>` close tokens, token/logit shaping, or parser output repair. Any hit must record why it was built, prove whether it still fires, and be replaced by a real template/decode/tokenizer/cache/root-cause fix or left as a red row. |
| MTP | Non-MTP bundles show disabled with `no mtp tensor evidence`; valid Qwen bundles use tuning file depth; blocked tuning stays off. |

Initial source audit artifact:
`docs/internal/live-gates/pr1147/forced-behavior-audit-20260518T1545/REPORT.md`.
Rows from that artifact must be resolved before production-clear. In
particular, background `no_think` calls for preflight/greetings must prove they
never enter user chat cache scope; explicit `frequency_penalty` mapping must
stay request-only; MiniMax fallback/template bridges must move into real
template/runtime fixes when needed; and Ling's force-off plus reasoning merge
must remain red until live vmlx evidence proves the model path is coherent
without UI-side repair.

## Artifact Acceptance Rules

Each model folder must include:

- `ui_model_picker.log` or screenshot with model path, capabilities, MTP, VLM,
  reasoning, parser, and cache labels.
- `ui_chat_settings.log` or screenshot with default clicked/selected controls.
- `ui_server_settings_cli_preview.log` with invalid flags absent and valid
  topology settings present.
- `health_before_after.json` and `cache_stats_before_after.json` with before,
  after load, after each turn, and after sleep/wake where applicable.
- `process_memory.csv` with RSS and physical footprint.
- `chat_ui_turns.json` with visible text, reasoning text, token counts, stop
  reason, TTFT, tok/s, and output tail.
- `api_routes/` with raw route output for stream and non-stream APIs.
- `api_routes/http_route_probe.json` with unique stream/non-stream filenames
  plus before/after `/health`, `/admin/cache-stats`, and process-memory
  snapshots.
- These process-memory snapshots are diagnostics; production memory gates still
  need RSS plus Activity Monitor physical footprint review.
- `vlm-sequence/live_sequence_probe.json` from
  `scripts/pr1147_live_sequence_probe.py` for Qwen, Gemma VLM, ZAYA-VL, and
  Nemotron Omni media rows, including image+text, text-only, different-image,
  repeat-image, video, and audio turns when supported.
- `media_sequence.json` for every VLM/Omni row.
- `tool_reasoning_parser.json` for every tool/reasoning row.
- `carryover_inverse.json` for saved-setting and cache-key switches.
- `summary.md` with PASS/PARTIAL/FAIL, root cause for red rows, and exact
  artifact paths.

Do not promote:

- load-only evidence;
- file census only;
- metadata route status only;
- short output that ended at max tokens without visible answer;
- hidden sampler, EOS, repetition, or forced reasoning-close repair;
- forced sampler defaults, repetition penalties, reasoning rail rewrites,
  `</think>` close tokens, token/logit shaping, or parser output repairs that
  are not traced to bundle metadata or explicit user/API kwargs;
- name-based MTP detection;
- media path evidence that did not send real media;
- cache proof without hit/miss counters and timing/memory context.

## Open Until Proven

The following remain open until concrete artifacts exist:

- Qwen3.6 VL/MTP UI and API media rows with cache stats and MTP tuning proof.
- Gemma4 VLM and Gemma3n text rows, including the known Gemma3n UTF red row.
- ZAYA-VL media and ZAYA text direct-mode root cause. Current
  `zaya1-vl-8b-mxfp4/vlm-sequence-20260518T1504/` evidence is red because the
  blue-image turn still described red and cache proof was not collected under a
  residency mode that can keep the model visible after the request. The
  Responses generic-media source bug was traced to dropped `input_image` parts
  and fixed with a unit test, but live Responses grounding still needs a fresh
  keychain-safe rerun. ZAYA1-VL video remains intentionally unsupported until a
  real engine video processor exists; Osaurus now gates ZAYA1-VL as image-only
  so the UI/composer does not advertise a fake video path.
- Nemotron Omni audio/video/image rows through Osaurus, including Parakeet and
  RADIO evidence.
- DSV4 UI settings visuals, DSML route proof, native cache stats, and long chat.
- MiniMax reasoning/tool route proof with no forced close or sampler guard.
- Ling/Hy3 hybrid SSM rederive and no KV-only unsafe cache hit.
- All route parity rows across chat, responses, messages, Ollama chat/generate,
  streaming and non-streaming.
- Final old-library and zombie-code sweep after live rows are attached.
