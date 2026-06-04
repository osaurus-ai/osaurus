# Gemma 4 12B PR #1333 runtime proof ledger

Date: 2026-06-03 PDT

Scope: Osaurus PR #1333 proof app, branch
`codex/main-gemma4-ci-proof-b965375f`, vMLX pin
`454f16efe6b867bc33cb74d6d5cb554227949445`.

This ledger is a proof index, not a blanket production claim. The current
runtime rows prove tool calling, cache reuse, Responses API routing, and
MXFP4/MXFP8 image routing. JANG_4M image quality remains partial/red.

## Fixed / green

- No hidden behavior repair:
  - `assert-chat-reasoning-delta-routing.sh`
  - `assert-chat-ui-reasoning-routing.sh`
  - `assert-no-hidden-local-sampler-defaults.sh`
  - `assert-osaurus-no-forced-behavior-pr.sh`
  - `assert-tool-choice-required-routing.sh`
  - `assert-model-tool-capability-surfaces.sh`
  - `assert-vmlx-gemma4-parser-fix-wired.sh`
- Required tool calling and repeated prompt cache:
  - `/tmp/osaurus-gemma4-main-repeat-tool-cache-final-20260603-193519`
  - `/tmp/osaurus-gemma4-main-repeat-tool-cache-final-rest-20260603-193635`
- Auto tool selection:
  - `/tmp/osaurus-gemma4-main-auto-tool-final-20260603-193954`
- Streaming reasoning leak check:
  - `/tmp/osaurus-gemma4-main-stream-reasoning-final-20260603-193707`
- `/v1/responses` non-streaming and streaming tool-call events:
  - `/tmp/osaurus-gemma4-main-responses-api-final-20260603-194234`
- `/v1/responses` `previous_response_id` plus `function_call_output` reuse:
  - `/tmp/osaurus-gemma4-main-responses-previous-final-20260603-194528`
- MXFP4/MXFP8 image routing/cache:
  - `/tmp/osaurus-gemma4-main-vlm-final-gemma-4-12b-it-mxfp4-20260603-193723`
  - `/tmp/osaurus-gemma4-main-vlm-final-gemma-4-12b-it-mxfp8-20260603-193729`

## Cache / TurboQuant policy

Live Gemma 4 12B topology is 48 layers: 8 full KV layers and 40 rotating KV
layers, with disk-backed restore required.

Expected live cache state:

- `turbo_quant_kv_layer_count = 0`
- `compilable_turbo_quant_kv_layer_count = 0`
- `quantized_kv_layer_count = 0`
- `turbo_quant_compressions = 0`

This is intentional. Engine-selected TurboQuant is off by default for Gemma and
rotating/SWA topologies. Disk-backed L2 restore is the proven cache path for
these rows. `RuntimePolicySourceTests/cacheConfigEnablesSSMReDerive` now
explicitly guards Gemma in that source policy.

## Reasoning selector policy

Gemma 4 does not expose the chat UI Thinking chip in this PR. That is
intentional current policy, not a missing UI wire:

- `Gemma4RuntimeProfile` exposes no `thinkingOption`.
- `FloatingInputCard` renders `thinkingToggleChip` only when the selected model
  profile exposes a `thinkingOption`.
- `ModelProfileRegistryTests/gemma4_noChatThinkingToggle` passed.

The API path still preserves explicit `enable_thinking` controls; the UI chip
remains hidden until explicit Gemma 4 thinking is production-clean.

## Media capability boundary

Gemma 4 12B is image-only in the current pinned runtime. Audio/video request
plumbing is covered generally, but Gemma 4 unified requires audio/video inputs
to be nil:

- `ModelMediaCapabilitiesMCDCTests` passed and classifies Gemma 3 / 4 as
  image-only.
- `MultimodalContentPartTests` passed for audio/video request decoding and
  mapping generally.
- `assert-vmlx-gemma4-parser-fix-wired.sh` passed and confirms the Gemma 4
  image boundary.

## Partial / red

JANG_4M image color quality is not production-green.

Artifacts:

- `/tmp/osaurus-gemma4-main-vlm-final-gemma-4-12b-it-jang_4m-20260603-193737`
- `/tmp/osaurus-gemma4-main-vlm-jang-repeat-final-1-20260603-194751`
- `/tmp/osaurus-gemma4-main-vlm-jang-repeat-final-2-20260603-194757`
- `/tmp/osaurus-gemma4-main-vlm-jang-repeat-final-3-20260603-194801`
- `/tmp/osaurus-gemma4-main-vlm-jang-repeat-final-4-20260603-194804`
- `/tmp/osaurus-gemma4-main-vlm-jang-repeat-final-5-20260603-194807`
- `/tmp/osaurus-gemma4-main-vlm-prompt-diagnostic-20260603-195151`
- `/tmp/osaurus-gemma4-main-vlm-color-matrix-20260603-195218`

Observed behavior:

- MXFP4 answered red/green/blue correctly in the color matrix.
- JANG_4M mapped red to `Black`, green to `Green`, and blue to `Black`.
- JANG_4M has `Gemma4UnifiedProcessor`, `vision_embedder`, and `embed_vision`
  weights present.
- JANG_4M metadata declares multimodal embedders as fp16 passthrough / early
  fusion.

Classification: JANG_4M image failure is current-bundle artifact/model behavior
under the live runtime, not an Osaurus image routing/cache failure. Do not hide
this with prompt coercion, sampler overrides, parser repair, or forced behavior.
