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

## Model Matrix

| Model path or family | Runtime class/topology | Current evidence | Required before production-clear |
|---|---|---|---|
| `/Users/eric/models/JANGQ/DeepSeek-V4-Flash-JANGTQ-K` | DSV4 Flash, SWA+CSA+HSA `DeepseekV4Cache`, DSML tools | vmlx live DSV4 tool-call and growing-cache artifacts; Osaurus docs/tests lock no app-side DSV4 cache forcing. | Final Osaurus UI renderer screenshot/log, API chat/responses rows, DSV4 settings CLI preview, cache stats, and `reasoning_effort=max` app proof. |
| `/Users/eric/models/dealign.ai/Qwen3.6-35B-A3B-JANGTQ-CRACK` | Qwen3.6 MoE VL, Qwen3VLProcessor, path-dependent cache | vmlx live prod/cache/VL/media-salt artifacts exist. | Osaurus app chat + API rows for image/text/video, reasoning on/off, generation defaults, saved settings, and cache stats. |
| `/Users/eric/models/JANGQ/Qwen3.6-27B-MXFP4-MTP` and MXFP8/35B variants | Qwen MTP/VL only when tensors plus `vmlx_mtp_tuning.json` are valid | vmlx source/tests require tuning and fail closed without it. | Osaurus status UI/API must show MTP off/on reason, use `vmlx_mtp_tuning.json`, and prove MTP on/off speed/coherence/cache rows. |
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
