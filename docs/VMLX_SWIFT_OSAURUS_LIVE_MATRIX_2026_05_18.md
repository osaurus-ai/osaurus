# vmlx-swift Osaurus Live Matrix - 2026-05-18

This is the Osaurus-side checklist for switching local inference to the
consolidated `vmlx-swift` package. It is deliberately stricter than a compile
or package pin. A row is not production-clear until the same model path has
real UI and API evidence, multi-turn coherency, cache proof, timing, memory,
and parser-leak checks.

This document is also the place to record rows that are not clear yet. Do not turn red rows into hidden sampler defaults, fake repetition penalties, forced reasoning close tokens, or app-side parser repairs.

## Evidence Standard

Each live row needs an artifact folder with:

- exact local model path and resolved model id;
- `config.json`, `generation_config.json`, `tokenizer_config.json`,
  `chat_template.jinja`, JANG metadata, MTP tensor/tuning status, and VLM
  processor facts when present;
- UI path proof from the Osaurus chat app: model picker, chat settings, server
  settings, visible defaults, saved-setting reload, stop button, and stream
  finalization;
- API path proof for `/v1/chat/completions` stream and non-stream,
  `/v1/responses` stream and non-stream, and any applicable Anthropic/Ollama
  compatibility route;
- request payload and response body excerpts showing visible content,
  `reasoning_content`, `tool_calls`, stop reason, token counts, and token/s;
- cache stats before and after each turn: prefix, paged, block L2 disk, SSM companion, path-dependent cache state, and media salt;
- TTFT, prompt time, decode tok/s, RSS, Activity Monitor physical footprint
  when available, and disk-cache bytes written;
- three-turn chat proof: cold first turn, same-chat follow-up, model switch or
  media switch, then a return to the original model/session;
- explicit ON/OFF inverse rows for reasoning, tools, streaming, prefix cache,
  paged cache, block L2, and media attachment where the family supports them;
- no leaked `<think>`, DSML, Harmony, Gemma4, Qwen tool XML, GLM/Hunyuan,
  MiniMax, or Nemotron tool markers in visible `.chunk` content.

Passing unit tests can support a row, but they do not replace live proof.

Status words in this file are strict:

- `source-wired`: static code or unit tests cover the routing contract.
- `vmlx-live`: the consolidated engine has a live artifact outside Osaurus.
- `osaurus-live`: the packaged/current Osaurus UI or HTTP route has a live
  artifact with cache, speed, memory, and visible output.
- `production-clear`: all required `osaurus-live` artifacts exist for the row.

Do not promote `source-wired` or `vmlx-live` to `production-clear`.

## Prompt-to-Artifact Checklist

Every live row must map a user-visible behavior to a concrete artifact path. A
single model load, a single API route, or a unit test does not cover the row.

| ID | Requirement | Required artifact evidence | Current status |
|---|---|---|---|
| A1 | Bundle census and autodetect | JSON/text artifact with `config.json`, `generation_config.json`, `tokenizer_config.json`, chat template source, JANG/JANGTQ sidecars, real `mtp.*` tensor count, `vmlx_mtp_tuning.json`, VLM processor files, and detected family/parser/cache topology. | Partly `vmlx-live`; Osaurus artifact still pending per model. |
| A2 | App launch and model picker | Screenshot/log proving the model appears with correct name/path, VLM/audio/video badges, MTP status from tuning, parser family, cache topology, and no stale saved profile. | Pending `osaurus-live`. |
| A3 | Chat settings visual defaults | Screenshot/log for defaults after selecting the model: DSV4 `instruct` selected, DSV4 `max` selectable and passed as `reasoning_effort=max`, Qwen no-thinking default where applicable, ZAYA/Nemotron no-thinking defaults, MiniMax reasoning channel, Gemma Harmony controls, and no controls for unsupported features. | Source-wired for profiles; pending UI proof. |
| A4 | Server settings and CLI preview | Screenshot/log of cache, batching, sleep/wake, generation, tool, reasoning, VLM, and MTP sections; CLI preview omits topology-invalid flags and shows metadata-derived defaults including native `top_k`. | DSV4 checklist source-locked; pending final UI/CLI artifact. |
| A5 | Chat UI default cache stack | Three-turn chat from the app using default cache stack: cold T1, T2 follow-up with prefix/paged/L2/path-dependent cache stats, T3 model/media switch, then return to original session. Include TTFT, tok/s, RSS, Activity Monitor physical footprint, and visible coherent output. | Pending `osaurus-live`. |
| A6 | `/v1/chat/completions` | Stream and non-stream HTTP artifacts with omitted sampler fields, explicit sampler fields, tools on/off, reasoning on/off, media where supported, terminal usage, `[DONE]`, no raw parser markers, and cache stats around each turn. | Pending `osaurus-live`. |
| A7 | `/v1/responses` | Same sequence as A6 plus prior-response/session continuity and reasoning response shape; prove no route-specific loss of cache scope, tool calls, or reasoning deltas. | Pending `osaurus-live`. |
| A8 | `/v1/messages` | Anthropic stream/non-stream artifacts for applicable families with thinking/tool-use mapping, media content, terminal tail, and no raw `<think>`, Harmony, DSML, Qwen XML, MiniMax, GLM/Hunyuan, or Nemotron tags in visible text. | Pending `osaurus-live`. |
| A9 | Ollama compatibility | `/api/chat` and `/api/generate` stream/non-stream artifacts with omitted/supplied options, proper final tail frame, no hidden sampler defaults, and no stale saved reasoning setting entering the request. | Pending `osaurus-live`. |
| A10 | VLM/omni media cache sequence | Image+text T1, text-only T2 with media-salt nil/absent, different-image T3, video frame row when supported, unsupported-media error, repeated media cache hit/alias, and audio/Parakeet pre-encode when applicable. | Source-wired for media preservation; pending live Qwen/Gemma/ZAYA/Nemotron rows. |
| A11 | Tool context injection and parser split | First turn with tools, structured `tool_calls`; second turn with `tool_result`; third visible answer. Prove no plaintext tool schema/result leak, no cache-key drift from tool history, and parser family matches base architecture. | DSV4 `vmlx-live`; remaining families pending Osaurus API/UI rows. |
| A12 | Reasoning inverse and leak checks | For each reasoning family, run off/default/on/max or native efforts. Capture reasoning channel, visible content, final tail, token counts, and prove unsupported families hide/ignore stale settings instead of sending invalid fields. | Source-wired for profiles; pending live rows. |
| A13 | Cache inverse checks | Prefix, paged, block L2, SSM companion, path-dependent media/CCA/DSV4 caches ON by default where valid; OFF rows do not crash; ON again restores counters/hits. Include disk bytes and max-GB enforcement for L2. | Pending `osaurus-live`. |
| A14 | Batch and scheduler | Single-user chat uses max batch size 1; same-model concurrent API requests hit continuous batching; different-model sessions stay isolated; cancel drains in-flight stats and leaves no zombie Swift engine. | Source-wired for adapter behavior; pending live concurrency/cancel rows. |
| A15 | JANG/JANGTQ/TurboQuant path | Loader derives real quant/cache metadata from sidecars and weights, not names. Artifacts show JANG/JANGTQ format, TurboQuant KV encode/decode status when valid, and no permanent overlay or name-only MTP claim. | Partly `vmlx-live`; Osaurus health/settings proof pending. |
| A16 | UI persistence and cross-model carryover | Save settings, quit/reopen, switch across Qwen, DSV4, Ling/non-reasoning, VLM, and text-only models. Prove saved reasoning/cache/media settings are scoped correctly and do not slow or poison another session. | Pending `osaurus-live`. |
| A17 | Startup, sleep/wake, and memory | Load from app, deep sleep, wake, generate without disk reload when expected, record Activity Monitor physical footprint and RAM drop/recovery, then repeat cache hit checks. | Pending `osaurus-live`. |
| A18 | Visual state and errors | Screenshots/logs for model loading/ready/generating/error/sleeping, unsupported media, model load failure, mid-stream cancel, and parser/tool errors rendered cleanly without stack traces. | Pending `osaurus-live`. |

## Cross-Layer Gates

| Gate | Required proof | Current status |
|---|---|---|
| Model discovery | Osaurus detects family, VLM/audio/video support, parser profile, MTP from real tensors plus `vmlx_mtp_tuning.json`, and bundle generation defaults. | Partly source-tested; live UI/API matrix pending. |
| Generation defaults | UI/API requests with no sampler fields use model metadata first, then engine fallback; no hidden temperature/top-p/top-k/repetition floors. | Partly proven in vmlx artifacts; final Osaurus UI/API rows pending. |
| Reasoning settings | Saved settings and per-request overrides map to the correct family field: `enable_thinking`, `reasoning_effort`, `no_think`, DSV4 `instruct`/`max`, or no control. | Source-tested in Osaurus; live app setting persistence still pending. |
| Parser split | Reasoning goes only to reasoning UI/API channels, tools only to structured tool calls, final text only to visible content. | Parser source tests exist; family live API matrix pending. |
| Media processing | Image/video/audio payloads survive chat builder, preprocessing, vmlx input, media salt, cache storage, and API adapters. | Source-tested for preservation; live Qwen/Gemma/ZAYA/Nemotron app/API rows pending. |
| Cache stack | Prefix/paged/L2/SSM/DSV4/ZAYA path-dependent cache stats are captured before and after multi-turn runs. | vmlx artifacts exist for some families; Osaurus UI/API proof pending. |
| Batch/scheduler | Default single-user chat uses max batch size 1; same-model concurrent requests hit vmlx continuous batching; cancellation drains terminal stats. | Source-tested; live app/API concurrency row pending. |
| Settings renderer | Server settings and CLI preview show only topology-valid controls and omit invalid flags. | DSV4 checklist locked; other families still need final UI pass. |
| Tool integration | Tool schema injection, tool-call parsing, and second turn with tool result work for each parser family without cache-breaking prompt drift. | DSV4 live vmlx row passed; remaining families need live API rows. |

## Route-Specific Live Gate

Each route below must be tested with the same default cache stack that a normal
Osaurus user gets after selecting the model. Do not disable a cache layer just to
make a row pass unless the row is explicitly an inverse test.

| Route or surface | Required live sequence | Cache and parser evidence |
|---|---|---|
| Chat UI route | Open app, select model, inspect settings defaults, send T1 cold prompt, T2 follow-up, T3 model/media switch, Stop/Retry once, quit/reopen and resume. | Visible answer, reasoning pane state, tool card if used, token/s, TTFT, Activity Monitor physical footprint, cache stats before/after each turn. |
| `/v1/chat/completions` | Stream and non-stream with no sampler fields, tools on/off, reasoning on/off, media where supported. | SSE `[DONE]`, usage, structured `tool_calls`, no parser marker leakage, metadata generation defaults, prefix/paged/L2/SSM/media-salt stats. |
| `/v1/responses` | Stream and non-stream, standard and reasoning request, previous response/session continuity. | Same cache key and parser behavior as chat completions, no route-specific loss of reasoning/tool events, terminal usage emitted. |
| `/v1/messages` | Anthropic stream and non-stream for reasoning and media-capable families. | Thinking/tool-use mapping preserved without leaking raw `<think>`, Harmony, DSML, Qwen XML, Hunyuan, MiniMax, or Nemotron tags. |
| `/api/chat` and `/api/generate` | Ollama stream and non-stream, explicit `stream=false`, model options omitted and supplied. | Proper Ollama tail frame, no hidden app-level sampler defaults, no stale saved reasoning setting entering the request. |
| Server settings UI | Change batching/cache/sleep/generation/tool/reasoning settings, save, reset, relaunch. | Settings visible only when topology-valid; saved values are scoped to the right model family and do not alter cache scope for another family. |

## UI Settings Contract

The final Osaurus UI must show defaults from runtime metadata, not stale saved
values from a previous model. Required checks:

- DSV4: default visible mode is `instruct`; selecting `max` sends
  `reasoning_effort=max` unchanged to vmlx; generic q4/q8 KV, JIT,
  speculative model, and MLLM flags are hidden or omitted because they are
  invalid for the DSV4 topology. The renderer row must also prove native DSV4
  cache copy is present, paged block size is fixed/disabled at 256 when runtime
  metadata reports it, pool quant state is visible, generation defaults come
  from `generation_config.json` or `jang_config.json`, and CLI preview omits
  `--kv-cache-quantization`, `--enable-jit`, `--is-mllm`, and
  `--speculative-model`.
- Qwen reasoning/VL: default no-thinking where the profile says so, explicit
  opt-in sets `enable_thinking=true`, and Qwen-VL image/video rows use media
  salt without reusing a text-only cache entry.
- MiniMax: reasoning-capable profile must keep reasoning deltas out of visible
  content and preserve structured tool calls. If a row is reasoning-only at a
  short budget, record that as a budget/product row, not a forced close fix.
- Gemma 4 / Gemma3n: Gemma4 Harmony reasoning and Gemma tool calls must not
  leak markers. Gemma3n E2B text proof does not imply vision/audio proof.
- ZAYA / ZAYA-VL: default no-thinking stays off unless explicitly enabled.
  Current ZAYA direct-mode math evidence is not production-clear; do not hide
  it with sampler clamps. ZAYA-VL needs separate image and video rows.
- Nemotron Omni: default no-thinking for chat, explicit opt-in honored, audio
  and video payloads stay attached to the turn that supplied them, and
  pre-encoded Parakeet/RADIO paths do not poison text-only follow-ups.
- Ling/Hy3/Laguna/GLM/GPT-OSS/Mistral: settings must match the family parser
  and reasoning protocol rather than inheriting Qwen or DSV4 controls.

Saved settings migration checks:

1. Start with a Qwen reasoning model, enable thinking, quit/reopen, confirm the
   setting persists for the same model.
2. Switch to Ling or a non-reasoning profile, confirm stale Qwen thinking
   options are hidden or ignored and do not enter cache scope.
3. Switch to DSV4, set `max`, send one request, then switch away and back.
   Confirm `max` is preserved only for DSV4 and no other family sees that
   effort string.
4. Switch from a VLM chat to a text-only model, then back to VLM. Confirm media
   salt and cached media state do not carry across models or sessions.

## Media and Cache Turn Sequence

Run this exact sequence for every VLM/omni family that has a local bundle:

1. T1 image plus text: capture media token count, media salt, cache miss, TTFT,
   visible grounded answer, and no parser marker leakage.
2. T2 text-only same chat: capture media salt absent or nil, prefix/cache reuse
   where topology allows it, and visible answer grounded only in prior history.
3. T3 different image: capture different media salt and no reuse of the T1
   image cache state.
4. T4 unsupported media type: UI rejects before submit or API returns a clean
   structured error, not a hang or 500.
5. T5 restart app or unload/reload model: repeat T2/T3 and prove block L2 and
   path-dependent companion caches restore only when the cache key is valid.

For video, include frame count, resize target, EVS/effective prompt token
count, post-prepare cache key alias, and repeated-video cache hit proof. For
audio, include Parakeet/pre-encoded embedding evidence and live-voice chunk
stability when Nemotron Omni is resident.

## Architecture and Cache Topology Checklist

Every model row must declare which cache layers are expected to be active and
which layers are intentionally N-A. A missing counter is a failure unless the
model legitimately cannot exercise that layer.

| Architecture or feature | Default Osaurus behavior | Live proof required |
|---|---|---|
| Dense/global attention text | Prefix cache, paged cache, and block L2 disk default on when enabled by settings. | T2 prefix hit, paged block allocation or hit counter, L2 disk bytes/stores/hits, lower TTFT than T1. |
| Sliding-window attention | Engine-selected rotating/sliding cache, no app-forced global `maxKVSize`. | Health/settings show sliding-window topology; long prompt does not broadcast-shape crash; cache reuse remains coherent. |
| DSV4 Flash SWA+CSA+HSA | Native `DeepseekV4Cache`; generic paged counters may be zero when `pagedIncompatible=true`; generic KV q4/q8 and JIT disabled in UI. | Native DSV4 cache copy, fixed 256 block display row, pool quant visible, DSML tools, reasoning `instruct` and `max`, growing-chat disk restore. |
| Qwen VL / Qwen3.6 MTP VL | Qwen3VLProcessor, MRoPE/media salt, MTP only from `mtp.*` tensors plus `vmlx_mtp_tuning.json`. | Image+text, text-only media-salt nil, different image miss, video frame row, MTP on/off speed/coherence/cache row, status UI shows tuning depth. |
| Gemma4/Gemma3n | Gemma4 Harmony parser and Gemma VLM path; Gemma3n text proof does not imply media support. | Harmony reasoning separated, Gemma tool cards structured, image/video rows for Gemma4, Gemma3n media controls hidden unless live media proof exists. |
| ZAYA / ZAYA-VL CCA | ZayaCCACache/path-dependent CCA state; default no-thinking unless explicitly enabled. | CCA cache state present, image/video turns grounded, direct-mode red rows not hidden by sampler clamps, no stale thinking option from Qwen/DSV4. |
| Nemotron Omni | Parakeet audio encoder, RADIO vision, video/audio placeholders, media salt and SSM companion isolation. | Live voice pre-encode, audio/video/image/text-only resume, repeated-video cache alias, Parakeet/RADIO evidence, no reasoning-only short-budget false pass. |
| Hybrid SSM / linear attention | SSM companion cache and optional re-derive only when profitable for the workflow. | SSM hits/misses/stores, no KV-only unsafe hit, coherent multi-turn after prefix mismatch, re-derive status and TTFT captured. |
| JANG/JANGTQ/TurboQuant | Loader derives real bit metadata from bundle sidecars; no name-only MTP/JANGTQ claims. | JANG/JANGTQ format, TurboQuant KV encode/decode status when enabled, no shape-inferred metadata hidden from logs, no permanent overlay unless explicit diagnostic. |

## Model Matrix

| Model path or family | Runtime class/topology | Current evidence | Required before production-clear |
|---|---|---|---|
| `/Users/eric/models/JANGQ/DeepSeek-V4-Flash-JANGTQ-K` | DSV4 Flash, SWA+CSA+HSA `DeepseekV4Cache`, DSML tools | vmlx live DSV4 tool-call and growing-cache artifacts; Osaurus docs/tests lock no app-side DSV4 cache forcing. | Final Osaurus UI renderer screenshot/log, API chat/responses rows, DSV4 settings CLI preview, cache stats, and `reasoning_effort=max` app proof. |
| `/Users/eric/models/dealign.ai/Qwen3.6-35B-A3B-JANGTQ-CRACK` | Qwen3.6 MoE VL, Qwen3VLProcessor, path-dependent cache | vmlx live prod/cache/VL/media-salt artifacts exist. | Osaurus app chat + API rows for image/text/video, reasoning on/off, generation defaults, saved settings, and cache stats. |
| `/Users/eric/models/JANGQ/Qwen3.6-27B-MXFP4-MTP` and MXFP8/35B variants | Qwen MTP/VL only when tensors plus `vmlx_mtp_tuning.json` are valid | vmlx source/tests require tuning and fail closed without it; fresh census proves 27B MXFP4 selects D2, 27B MXFP8/35B variants select D3, all from tensor/tuning evidence. | Osaurus status UI/API must show MTP off/on reason, use `vmlx_mtp_tuning.json`, and prove MTP on/off speed/coherence/cache rows. |
| `/Users/eric/models/dealign.ai/Gemma-4-26B-A4B-it-JANG_4M-CRACK` | Gemma4 VLM/Harmony reasoning/tool parser | vmlx parser/source contracts exist. | Live Osaurus image/text/video rows, Harmony no-leak API rows, Gemma settings defaults, and cache stats. |
| `/Users/eric/models/mlx-community/gemma-3n-E2B-it-4bit` | Gemma3n text row in current artifacts | vmlx production BatchEngine probe is partial: math/reasoning-on/off/cache rows are coherent at about 120 tok/s and ~2.7 GiB RSS with disk L2 hits/stores, but the UTF literal row fails at bundle defaults and greedy diagnostics. | Do not call Gemma3n production-clear until the UTF drift is root-caused. If exposed as VL/audio, add media rows first; otherwise UI must not overclaim media capability. |
| `/Users/eric/models/JANGQ/ZAYA1-VL-8B-JANGTQ4` and `/Users/eric/models/Osaurus/ZAYA1-VL-8B-MXFP4` | ZAYA-VL CCA/path-dependent cache | Source profiles default thinking off; ZAYA text direct-mode is currently not production-clear. | Separate ZAYA-VL media rows, CCA cache stats, no stale thinking setting, speed target, and no sampler workaround. |
| `/Users/eric/models/dealign.ai/Nemotron-Omni-Nano-*` | Nemotron Omni text/image/audio/video, Parakeet/RADIO, media placeholders | Prior PR docs and vmlx artifacts cover structural paths with caveats. | Final Osaurus app/API audio/video/image/text-only resume rows, live voice resident pre-encode, repeated-video cache alias, and no reasoning-only short-budget false pass. |
| `/Users/eric/models/dealign.ai/MiniMax-M2.7-*` | MiniMax reasoning/tool parser, JANG/JANGTQ | vmlx fresh rows pass for some bundles; MTP must not be assumed from name. | Osaurus API tool result row, UI reasoning behavior, cache stats, and no visible reasoning leak. |
| `/Users/eric/models/dealign.ai/Ling-2.6-flash-*` | Bailing/Ling hybrid linear attention, GLM-style tools | vmlx fresh row passes; Osaurus profile forces non-reasoning mode by policy. | Osaurus UI/API no-thinking row, long-prompt TTFT/cache stats, and stale settings isolation. |
| `/Users/eric/models/JANGQ/Hy3-preview-*` | Hy3/Hunyuan reasoning/tools, hybrid cache | vmlx fresh row passes but cold TTFT remains a watch item. | Osaurus UI/API reasoning/tool rows, cache stats, and performance threshold review. |
| GLM/GPT-OSS/Mistral families when local | Harmony/think/bracket parser variants | Parser aliases are source-tested. | Live local model rows before claiming support in the switch PR. |

Kimi is intentionally excluded from this matrix for now per current scope.

## API and UI Completion Checklist

- `/v1/chat/completions`: stream and non-stream, text and media, tools on/off,
  reasoning on/off, terminal `[DONE]`, usage, and no marker leakage.
- `/v1/responses`: stream and non-stream, standard and reasoning, prior
  response/session continuity, same cache boundaries as chat.
- `/v1/messages`: Anthropic stream and non-stream for reasoning-capable rows,
  including thinking deltas and tool-use mapping when supported.
- `/api/chat` and `/api/generate`: Ollama stream and non-stream, correct tail
  frame, no hidden app-level sampler defaults.
- Chat UI: send/stop/retry/edit/copy, thinking panel collapse, tool-call card,
  image/video/audio attachment preview, unsupported-media rejection, token/s,
  TTFT, and terminal state.
- Server settings UI: host/port/auth, batching, prefix cache, paged cache, L2
  disk cache, sleep/wake, generation defaults, tool parser, reasoning parser,
  VLM force-off only when not auto-detected, and MTP status from tuning.
- Model switch: two simultaneous sessions with different models, same-model
  continuous batching, no cross-model cache poisoning, and saved settings scoped
  to the correct model family.

## Open Items

- The final Osaurus app has not yet run the full UI/API matrix for Qwen-VL,
  Gemma VLM, ZAYA-VL, Nemotron Omni, DSV4, MiniMax, Ling, Hy3, and the parser
  families listed above.
- Gemma3n E2B has a fresh vmlx production-path partial row: no loop in the
  math/cache turns, but a UTF literal prompt drifts into unrelated Chinese
  text. Treat it as an open runtime/tokenizer/template investigation, not a
  sampler-default workaround.
- DSV4 has live vmlx tool/cache proof, but the final settings renderer still
  needs visible UI/CLI evidence.
- ZAYA text direct mode remains a real red row. Do not call ZAYA production
  clear until the prompt/runtime issue is root-caused or the product explicitly
  defaults to a proven coherent mode without a hidden sampler/parser fix.
- Nemotron Omni video/audio cache behavior has focused and live vmlx evidence,
  but Osaurus app/API rows still need to prove the same path through ChatView,
  HTTP adapters, saved settings, and cache stats.
- This matrix should be updated with artifact paths as each live row is run.
