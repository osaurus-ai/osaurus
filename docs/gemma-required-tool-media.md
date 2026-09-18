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
no sampler, template, RAM admission or tool-execution policy. A companion
engine correction is pinned below for the separate history loss found live.

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

## App correction and separate engine history failure

At app `530c2f12e8afd815c8d578fceeb73460b5443bec`, binary
`63699d39b89c09e671928fb177746f47efccdcff2f3950638798ab4fe990fecd`,
202 tests in 15 suites completed without failures. All eight single-image
complete/streamed auto/named/required API rows retained media and returned the
observed shapes/word, 90.18–92.19 tok/s. Native first-image `file_write` and
`file_read` continuation completed visibly.

The subsequent native image turn failed before decode: the engine removed an
earlier image message while preparing both images, leaving one placeholder
for two images (maskedScatter 860160 values/430080 positions). Six paired
history requests also isolated loss/mismatch to required/named tool selection.
This originates in May 27 engine commits `2be648a3`/`447d2a07`, not #2805's MCP
correction or this app's full-message preservation.

Engine PR #479, pin `29e681dfc25e0afa114fcde4a886d77ecc244323`, removes those
two destructive VLM/text adapters. Its regression-only baseline failed 18/33
cases; the correction passed all 33 plus the selected parser/media/cache tests
(82 Swift Testing tests, 12 XCTest cases), repeated. Both old scalar-system and
structured tool-result handling remain. Four app pin sites and two pin tripwires
are updated together; other dependencies are unchanged.

Full baseline catalogs at `530c2f12`: AgentLoop 40 passed/10 failed/2 errored/
4 skipped of 56; Frontier 23 passed/16 failed/3 errored of 42. Every nonpass and
rubric was reviewed in `EVAL-REVIEW-530.md`; these are not corrected-head results
and not an all-pass claim. The 128GB host is not 16GB RAM qualification.

## Combined live checkpoint — scope and limits

Tested app source `6267660b2811b7e8bdc13573ef88039d3501e61e`, engine
`29e681dfc25e0afa114fcde4a886d77ecc244323`; development app binary SHA256
`3f7f49e4b2e980c506c56b8553ccff772062477ce210416c2f96b306e65a31e8`.
The same E2B8bit bundle/defaults above were used; MTP/thinking off. Focused
app tests completed 314 tests in 17 suites with zero failures. Engine paired
82 Swift Testing and 12 XCTest results are documented in #479.

Native UI17 executed first-image file_write, file_read grounded in its result,
a second image followed by another required write, reopened-history read,
actual Chrome DevTools new_page/screenshot, then required file_write grounded
in that returned screenshot. All 13 generations had normal stops, settled
tool cards, unlocked input, correct saved sentences and 80.95–87.90 tok/s.
Image counts/slots were 1/280, 2/560 and 3/840. Four automatic continuations
explicitly accepted disk checkpoints; required-tool turns retained the existing
fresh-cache guard. Effective fp16 KV, 3 full plus 12 rotating layers, paged RAM
off and TurboQuant KV layer count zero. Store logs are not fsync durability.

Fourteen paired API rows (complete/stream auto/named/required and earlier or
two-image history) returned valid tool calls at 89.61–92.08 tok/s. Eleven
captions were correct; three duplicate-image rows invented a black square,
also observed in baseline automatic mode. Those three are not visual-fidelity
passes, and API-returned test tools were not executed.

Full corrected-head catalogs: AgentLoop **41 passed /10 failed /1 errored /
4 skipped of56**, Frontier **16 passed /22 failed /4 errored of42**. All
nonpasses and rubrics reviewed in private `EVAL-REVIEW-626.md`. Retained
failures include empty final after executed tools, malformed arguments,
copying file-display line numbers, unfinished work and failed generated tests;
some deterministic/rubric misses are format/judge limitations. Frontier's
lower aggregate versus baseline is retained, not explained away or claimed as
a causal regression. Unseeded scores do not establish model-wide quality.

Proof receipts: `RUN17-REVIEW.md`, `run17-gemma-history-native-evidence/`,
`run17-required-media-matrix/`, `run17-media-history-probe/`, both
`eval-6267660b2811b7e8bdc13573ef88039d3501e61e-*` catalog sets,
`run17-measurements.jsonl`, `run18-measurements.jsonl` and the original
`SWIFTTEST_GemmaHistory*` guards.
UI18 normal quit/zero survivors at20:13:12; isolated settings restored.
Kernel lifetime peak was 3,257,338,616 bytes for native UI17 and
4,584,770,488 bytes for full Frontier UI18; swap stayed1.81GiB. This128GB
machine does not qualify16GB behavior, video/audio or the reporter's freeze.

All seven app CI checks completed at6267660b (CLI retry after dependency-fetch
I/O failure). Engine #479 macOS/CUDA jobs were still queued at this checkpoint;
four Linux builds passed and the pre-existing advisory full-tree formatter
failed. CI is not described as universally green. Further model-quality,
RAM/SSD, swallowed-prefill-error and discovery issues remain separate TODOs.
This docs-only checkpoint records acceptance evidence, not a release or a
claim that every Gemma workflow is fixed.

Private evidence root:
`/Users/eric/vmlx-private-evidence/handoff-parity-2026-09-16/implementation`.
Baseline artifacts: `run13-required-media-probe`, `run13.oslog`,
`REQUIRED-TOOL-MEDIA-ROOT-CAUSE.md`;
`required-media-tests-2ce88a89fa1e7d0794e4d845e348c15c11acdfc6-red1.log`
(SHA256 `dd227576b7d77729e1f847634a6d398e68850f37dc769e85939ee5d1cd8970fe`),
matching xcresult and `required-media-red1-supervisor.stdout`.
The red run exited 65 with zero owned survivors, peak tracked footprint 8.85 GiB,
swap unchanged at 1.81 GiB, and original resource guards retained.
