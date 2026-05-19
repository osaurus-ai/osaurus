# vmlx-swift Single Package Switch

This branch starts the Osaurus migration from the old split runtime graph to one
consolidated `vmlx-swift` package.

## Dependency Contract

OsaurusCore now has one direct inference dependency:

- `https://github.com/osaurus-ai/vmlx-swift`
- revision `0218591ed6ae02bf998a6ec6f8d204a89c26a7f7`

That package is expected to export the runtime modules Osaurus previously pulled
from separate roots:

- `MLX`
- `MLXLMCommon`
- `MLXLLM`
- `MLXVLM`
- `Tokenizers`
- `Jinja`

The Osaurus manifest must not add direct inference roots for `mlx-swift`,
`vmlx-swift-lm`, `swift-transformers`, or `Jinja`. Any new runtime surface should
land in `vmlx-swift` first, then Osaurus should consume it through this single
pin.

## Transitive Module Collision Handling

Osaurus still depends on non-inference packages that bring their own tokenizer
or HTTP helper stacks:

- `VecturaKit` -> `swift-embeddings` -> `swift-transformers`
- `swift-sdk` -> `EventSource`

`vmlx-swift` vendors modules that would otherwise collide with those target
names. SwiftPM target names are package-graph global, so the vmlx package now
prefixes its vendored implementation targets internally:

- `Tokenizers` -> `VMLXTokenizers`
- `Jinja` -> `VMLXJinja`
- `EventSource` -> `VMLXEventSource`
- `HuggingFace` -> `VMLXHuggingFace`
- `Hub` -> `VMLXHub`
- `Generation` -> `VMLXGeneration`
- `Models` -> `VMLXModels`

This keeps Osaurus direct runtime imports bound to the consolidated vMLX package,
allows VecturaKit and MCP transitive modules to keep their normal module names,
and avoids Osaurus-side SwiftPM `moduleAliases` that would diverge from the
package's own public contract.

`yyjson` is intentionally not prefixed. It is a C package with public
`yyjson_*` symbols, so vendoring a second copy under a different SwiftPM target
name still links duplicate C symbols when another transitive package uses the
upstream `yyjson` package. `vmlx-swift` depends on the single upstream yyjson
product instead.

One non-inference root remains intentional: `EventSource` is declared directly
with the `AsyncHTTPClient` package trait enabled. MCP already brings this package
transitively, but without the trait SwiftPM compiles EventSource's optional
AsyncHTTPClient source after `canImport(AsyncHTTPClient)` becomes true and before
the target has declared NIO/shim dependencies. The root trait makes that dependency
contract explicit.

## MTP Policy Boundary

The pinned `vmlx-swift` revision refuses native MTP activation unless the model
bundle has both:

- real MTP tensor evidence in the weights/index; and
- usable bundle-local `vmlx_mtp_tuning.json`.

Explicit user flags cannot force MTP sidecar loading on a bundle that fails that
gate. This is intentional: MTP must be detected from the model artifact, not from
the model name, and activation must be driven by measured tuning rather than a
generic fallback.

The pinned package commit keeps the Qwen MTP gate tensor/tuning based: the
27B/35B MXFP4/MXFP8 MTP variants all require real `mtp.*` tensors and usable
`vmlx_mtp_tuning.json` before auto-launch; 27B MXFP4 selects D2, while 27B
MXFP8 and both 35B variants select D3 from their tuning files.
Those MXFP rows are the current Osaurus PR release scope. JANG_4M/JANG_2K MTP
rows may remain useful reference evidence, but they do not close the MXFP
production gate and must not auto-enable unless their own tensor/tuning/live
rows are explicitly in scope.

## Release Gate Still Required

This package switch is compile and wiring work. It is not a production claim by
itself. Before merging a full Osaurus runtime switch, run the live gate against
local models and record artifacts for:

- multi-turn text coherence and no looping;
- reasoning on/off and effort handling per family;
- tool parsing per family with tool result follow-up;
- `generation_config.json` sampling defaults without hidden guard floors;
- prefix cache, paged cache, block L2, TurboQuant KV, and SSM companion cache;
- cache-on/cache-off inverses;
- VL image/video turns with text-only resume;
- Nemotron Omni live voice input / Parakeet encoder path;
- Qwen MTP bundles with `vmlx_mtp_tuning.json`, including MTP on/off speed and
  coherence comparisons; and
- API surfaces used by Osaurus and OpenAI-compatible clients.

The full Osaurus-facing UI/API/cache/media checklist is tracked in
[`VMLX_SWIFT_OSAURUS_LIVE_MATRIX_2026_05_18.md`](VMLX_SWIFT_OSAURUS_LIVE_MATRIX_2026_05_18.md).
That matrix is the merge gate for user-facing confidence: it requires real chat
app and API rows for Qwen-VL, Gemma VLM/Gemma3n, ZAYA-VL, Nemotron Omni,
DSV4, MiniMax, Ling, Hy3, saved reasoning settings, media salt, prefix/paged/L2
cache stats, top-k/generation defaults, and parser leak checks.
The per-family execution tracker and raw live artifacts are intentionally kept
out of the repository during this PR. Record current row status in the PR
coordination channel rather than committing private live-gate artifacts.

Any incoherent output, repeated EOS loop, missing reasoning close, or cache hit
with the wrong architecture state is a runtime bug to root-cause in `vmlx-swift`.
Do not compensate in Osaurus by forcing temperature, top-p, top-k, repetition
penalty, close tokens, or parser repairs.

Forced behavior cleanup is part of the switch, not a follow-up. Search for any
forced sampler default, repetition penalty, reasoning rail rewrite, forced `</think>` close,
token/logit shaping, or parser output repair. For every hit, record why it was
originally added, prove whether it still affects live output, and replace it
with the real template, decode, tokenizer, cache, or model-family fix. If the
real fix is not known yet, leave the row red; do not promote the guard as
production behavior.

## DSV4 Tool-Calling Boundary

DSV4-Flash bundles without a `tokenizer_config.json` chat template route through
the `vmlx-swift` DSV4 fallback. That fallback must render:

- top-level OpenAI `tools[]` as DSV4 DSML schema instructions;
- previous assistant `message.tool_calls` as `<｜DSML｜tool_calls>` history;
- `role=tool` outputs merged into the next user turn as
  `<tool_result>...</tool_result>` followed by the user's text in the same
  `<｜User｜>` block, matching DSV4's Python encoder; and
- original OpenAI tool-call ids so the next tool result can correlate with the
  correct assistant call.

Osaurus only bridges OpenAI chat messages into `MLXLMCommon.Chat.Message`; it
must not stringify assistant tool calls into prompt text or repair DSV4 output
after the fact. The parser/template behavior belongs in `vmlx-swift`, while
Osaurus preserves structured ids, arguments, and tool-result content across the
bridge.

DSV4 reasoning mode selection follows the same rule. `reasoningEffort=max`
is passed through to `vmlx-swift` as `reasoning_effort: "max"` with thinking
enabled. Osaurus must not downgrade it to `"high"` behind an environment flag;
if max-mode output is incoherent, that is an engine/runtime issue to reproduce
and fix in `vmlx-swift`.

## DSV4 Settings Renderer Gate

The Osaurus server settings panel and CLI preview must treat DSV4 as a
dedicated cache/runtime topology. Before this PR can be treated as production
ready, the final renderer needs a row proving all of:

- native DSV4 cache copy is present and displayed as the active
  SWA+CSA+HSA / `DeepseekV4Cache` topology;
- paged block-size control is fixed/disabled at 256 for DSV4 when active
  runtime metadata reports that value, and no
  generic paged block-size override is passed back to vmlx for DSV4;
- generic KV q4/q8 controls are disabled for DSV4 unless an operator
  deliberately selects the diagnostic `DSV4_KV_MODE=tq` path;
- DSV4 pool quant state is visible in settings/capabilities instead of hidden
  behind an implicit launch env;
- JIT is disabled for DSV4 in the production renderer;
- generation defaults shown in the UI come from model metadata
  (`generation_config.json` / `jang_config.json`) before explicit user
  overrides; and
- CLI preview omits topology-invalid flags: `--kv-cache-quantization`,
  `--enable-jit`, `--is-mllm`, and `--speculative-model`.

These checks are renderer/settings contract checks. They must not be converted
into fake sampler clamps, forced repetition penalties, or generic cache
fallbacks.

Live DSV4 tool-call proof on 2026-05-18 used
`DeepSeek-V4-Flash-JANGTQ-K` through `BENCH_BATCH_TOOLCALL=1`. Pre-fix raw
decode produced a valid DSML envelope with an abbreviated invoke close
`</｜DSML｜inv>`, which the strict parser dropped, yielding blank visible text
and zero `.toolCall` events. The pinned `vmlx-swift` revision now accepts that
observed DSV4 variant in the DSML parser. Post-fix live output emitted one
structured `get_weather({"location":"Tokyo"})` call, no raw DSML marker leakage
in `.chunk`, and no reasoning leakage. The same `BatchEngine.generate` proof is
kept with the private coordination artifacts rather than committed to this PR.

## Fresh Engine Process Rows

After explicit approval to run live model processes, the pinned vMLX checkout
was rebuilt in release mode and re-tested with fresh process rows under:

```text
docs/local/live-model-matrix/20260518T_fresh_user_allowed_process_rows/
```

Current results relevant to Osaurus wiring:

- `dsv4_dsml_toolcall_fresh.log`: `DeepSeek-V4-Flash-JANGTQ-K` loads through
  the vMLX `BatchEngine`, reports `Tool format: dsml`, emits one structured
  `get_weather({"location":"Tokyo"})` event, stops normally, and leaks no raw
  DSML or reasoning marker into visible `.chunk` text.
- `gemma3n_e2b_prod_default_cache_fresh.log`: the local Gemma3n E2B text path
  passes 7/7 with bundle generation defaults (`temp=0.600 topP=0.950 topK=64
  rep=nil`), no reasoning parser, no loop, about 122 tok/s, and disk L2 stats
  `hits=1,misses=21,stores=21`. This is text-only proof; Gemma3n vision/audio
  support is not claimed.
- `gemma4_e2b_prod_default_cache_fresh.log`: the Osaurus-local Gemma4 E2B row
  is retained as a red default-sampling artifact. It passes 6/7 without loop or
  crash, but at bundle defaults (`temp=1.000 topP=0.950 topK=64 rep=nil`) the
  UTF-8 inclusion prompt produced coherent Chinese with `你好` and omitted the
  literal `cafe`/`café` token. The paired
  `gemma4_e2b_prod_greedy_cache_fresh.log` passes 7/7 with explicit greedy
  parameters and no repetition penalty. Osaurus must not turn that into a hidden
  default sampler clamp; it is a visible validation/default-temperature caveat.
