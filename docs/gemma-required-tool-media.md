# Gemma explicit tool choice: preserve user media

## Scope and predecessor

`ModelRuntime.applyForcedToolChoiceDirective` augments the last user message
for Gemma requests with explicit required/named tool selection. The June 12
implementation (`518f6a60a5`) reconstructed that message with only role, text
and tool-call fields, discarding its media parts and in-process metadata.
Both complete and streamed local tool responses use this helper before
`mapOpenAIChatToMLX`. Native Chat's `ChatToolChoicePolicy.resolve` can request
required tool selection when the user explicitly names an available tool.

This is separate from #2805's typed MCP tool-result attachment conversion.
The correction preserves the earlier tool-selection wording, family gate,
schema filtering, cache-selection policy and text-only behavior. It changes
no sampler, template, RAM admission, engine pin or tool-execution policy.

The original message's ordered media/text parts, local audio sample alignment,
tool-call fields, reasoning metadata and Responses carriers survive. The same
existing directive suffix is added to flattened text and, when present, the
content-parts array. Other messages are unchanged.

## Reproduced baseline

App source `37cfacbf00da61641eab0a964a0a0836b7cda43f`, engine
`8ba593aff16c13cf526211b8477c0a037f0122af`, isolated app SHA256
`3be94334a6c03fe58e805eed804616422b1f4890409aa077c8b648356b4d9792`.
The affected helper is unchanged from main `4a329449` in this app.

Gemma E2B 8-bit snapshot `433003a1e3fbfd10819ad15179d5e3c4d02d7ea7`
received the same 3,344-byte image and request, changing only `tool_choice`.
The automatic arm prepared one image and 365 prompt tokens, returning the
actual red circle, blue square, green triangle and BIRCH at 92.8234 tok/s.
Named/required arms prepared zero images and 102 prompt tokens, returning
incorrect/generic descriptions at 96.1306/93.6379 tok/s. All returned HTTP 200
and normal tool-call stops. This proves missing payload, not a speed result or
reproduction of the reporter's machine freeze. Synthetic returned tools were
not executed. The diagnostic 256-output-token ceiling was not reached;
sampling was left at bundle defaults (temperature 1, top-p .95, top-k 64).

Expected-red test-only source `2ce88a89fa1e7d0794e4d845e348c15c11acdfc6`
compiled and completed with four failing methods/eight parameterized cases,
30 assertions, and five passing methods/nine cases. Failures reproduced image,
video/audio and opaque-field loss; the text/no-op cases passed. The unmodified
production helper also mapped an image-only request to zero MLX images.

## Remaining verification

The correction is implemented but not yet qualified. Required before merge:
current-source focused regressions (including the earlier file/MCP image and
MLX adapter contracts), matched automatic/named/required image API requests in
complete and streaming modes, actual native image/tool/history UI and follow-up,
full AgentLoop/AgentLoopFrontier with every non-pass attributed, and exact-head
CI. Audio/video metadata tests do not prove Gemma audio/video processing.

Private evidence root:
`/Users/eric/vmlx-private-evidence/handoff-parity-2026-09-16/implementation`.
Baseline artifacts: `run13-required-media-probe`, `run13.oslog`,
`REQUIRED-TOOL-MEDIA-ROOT-CAUSE.md`;
`required-media-tests-2ce88a89fa1e7d0794e4d845e348c15c11acdfc6-red1.log`
(SHA256 `dd227576b7d77729e1f847634a6d398e68850f37dc769e85939ee5d1cd8970fe`),
matching xcresult and `required-media-red1-supervisor.stdout`.
The red run exited 65 with zero owned survivors, peak tracked footprint 8.85 GiB,
swap unchanged at 1.81 GiB, and original resource guards retained.
