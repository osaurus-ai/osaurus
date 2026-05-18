# PR 1147 Forced Behavior Audit

Timestamp: 2026-05-18 15:45 PDT

Scope: source-level triage for hidden output-shaping behavior in the Osaurus
`vmlx-swift` switch. This is not live model proof and does not make any family
production-clear.

## Rule

All user-facing local model rows must be coherent through the real runtime
path. A row cannot pass because Osaurus secretly changes sampling, injects a
repetition penalty, forces or closes reasoning, repairs parser output, changes
logits, or activates a fake fallback path. The only allowed generation defaults
are:

- the model bundle metadata, especially `generation_config.json` and
  `jang_config.json`;
- explicit user or API kwargs on that request;
- engine fallback defaults only after metadata is absent, with the resolved
  values logged in the artifact.

Every source hit below needs live route evidence before release. If it affects
normal chat output, fix the real template, tokenizer, decode, cache, parser, or
model-family routing issue instead of hiding it in the app.

## Source Hits

| ID | Source | Surface | Why it appears to exist | Current judgement | Required proof or fix |
|---|---|---|---|---|---|
| FBA-001 | `PreflightCapabilitySearch.defaultLLM`, lines 804-814 | Background tool-ranking LLM call sets `temperature: 0.0`, `maxTokens: 256`, and `reasoningEffort=no_think`. | Keeps capability preflight deterministic and inside the short tool-ranking timeout. | Not evidence of model-chat coherence. Allowed only if isolated from user chat prompts, cache keys, and live model rows. | Add/attach a preflight artifact proving this path is background-only. If it enters a user-visible chat request or shared cache key, replace it with a dedicated non-user selector path. |
| FBA-002 | `GenerativeGreetingService`, lines 215-243 | Background greeting generation sets `reasoningEffort=no_think` and retries once at a cooler temperature. | Keeps optional greeting text short and structured. | Background-only candidate, but still output shaping. It cannot be counted as a model production pass. | Prove greeting requests are not reused for chat-route evidence or model cache proof. If they share normal chat cache scope, split the path. |
| FBA-003 | `ChatEngine.dispatch`, lines 91-101 and 135-142 | Maps explicit OpenAI `frequency_penalty > 0` to MLX `repetitionPenalty = 1.0 + fp`. | Bridges a user/API-requested knob; `presence_penalty` has no MLX analog and remains raw metadata. | Allowed only when the request supplied `frequency_penalty`. It must never appear for omitted fields. | Route rows with omitted sampler fields must show `repetitionPenalty=nil`; explicit `frequency_penalty` rows must show the exact mapping and not masquerade as a hidden default. |
| FBA-004 | `ChatEngine.dispatch`, lines 115-133 | Converts Hy3 `enable_thinking` / `reasoning_effort` into native `reasoningEffort`; generic families get `disableThinking`. | Keeps request payloads aligned with family-specific chat-template contracts. | Conditional. This is request-driven mapping, not decode repair, but unknown or stale values must not silently poison another family. | Live reasoning off/on/max rows per family plus saved-setting carryover proof. Consider API validation for invalid reasoning strings instead of silent fallback. |
| FBA-005 | `MLXBatchAdapter.additionalContext`, lines 468-488 | DSV4 defaults to `instruct`; `high` and `max` pass through as reasoning modes. | DSV4 uses a dedicated encoder rather than a generic `enable_thinking` Jinja path. | Conditional. It is a family renderer contract, but it must not be used to hide DSV4 max/tool/cache failures. | DSV4 live rows must prove `instruct`, `high`, and `max` behavior with no sampler/repetition guard, no forced close repair, DSML tools, and native cache stats. |
| FBA-006 | Pre-fix: `MLXBatchAdapter.additionalContext` Ling branch and `GenerationEventMapper` reasoning merge/suppression. Current source: Ling profile default-off toggle, adapter honors explicit opt-in, mapper keeps `.reasoning` separate. | Hy3 effort bridge remains a native-template mapping; Ling no longer force-clamps all requests, no longer merges `.reasoning` as visible content, and no longer suppresses unclosed-reasoning flags. | Ling/Bailing uses `enable_thinking` to choose the upstream detailed-thinking directive. Defaults off are valid UI policy only if explicit user/API opt-in reaches vmlx and parser output is not repaired in Osaurus. | Source hit fixed; still not production-clear. Fresh vmlx Ling no-guard row is coherent, and Osaurus focused tests prove the old fake merge/clamp behavior is gone. | Artifact: `/Users/eric/vmlx-swift/docs/internal/live-gates/20260518T_ling_jangtq2_forced_behavior_refresh/no_guard_sampling.log`. Tests: `MLXBatchAdapterTests`, `GenerationEventMapperTests`, `ModelProfileRegistryTests` red-to-green. Still requires Osaurus app/API long-output, cache, Hy3, and saved-setting carryover rows before production-clear. |
| FBA-007 | `SwiftTransformersTokenizerLoader`, lines 110-145 | MiniMax no-thinking uses a minimal fallback template; `[MODEL_SETTINGS]` templates derive `reasoning_effort` from `enable_thinking`; DSV4 sentinel removes stale effort when thinking is false. | Bridges model-specific template kwargs and shields known tokenizer/template incompatibilities. | Conditional. Prompt construction fixes can be valid, but they must not repair generated output or override explicit user/API efforts. | Prompt-dump artifacts must show explicit user/API `reasoning_effort` wins. If MiniMax requires the fallback for normal operation, move the fix into vmlx/template assets and prove reasoning on/off coherence live. |
| FBA-008 | `ModelOptions.swift`, lines 147-188, 228-328, 333-378, 381-459, and 630-665 | Family defaults expose no-thinking or native reasoning controls for DSV4, Qwen, Nemotron, Laguna, Hy3, Ling, ZAYA, AutoThinking, and Venice. | Mirrors family template defaults or product-scoped UI controls. | Conditional. UI defaults are allowed only when they reflect the bundle/template contract and explicit opt-in works. | Live UI/API rows must prove default/off/on/max as applicable, no stale carryover across families, and no hidden forced reasoning rail when the user opts in. |
| FBA-009 | `MLXBatchAdapter.effectiveGenerationSettings`, lines 63-90 | Uses metadata defaults, then runtime fallback values such as temperature `0.7`, `topK=0`, and `minP=0`. | Provides an engine value when request and bundle metadata are absent. | Conditional. This is not a family-specific guard if metadata lookup is proven first. | Omitted-sampler artifacts must log `jang_config.json` / `generation_config.json` values first, then fallback only when absent. No family may get a hidden temperature, top-k, min-p, or repetition floor. |
| FBA-010 | `LocalReasoningCapability`, lines 70-88 and 91-126 | Detects reasoning support from templates or JANG config; DSV4 uses JANG config when no Jinja template is present. | Prevents reasoning deltas from being coerced to content when a bundle advertises reasoning outside a standard template. | Allowed as capability detection, not output repair, if it is file-backed and reflected in UI/API settings. | Bundle census plus prompt-dump proof must show the detected source. A missing capability must remain unsupported rather than guessed from model name. |

## Release Gate Consequence

The PR remains blocked from production-clear until this audit is paired with
live artifacts for every model family in the main matrix:

- omitted sampler fields resolve from bundle metadata or documented engine
  fallback, not family guard code;
- explicit sampler kwargs are preserved exactly and are not injected when
  omitted;
- reasoning off/on/max or native efforts work naturally for DSV4, Qwen,
  Gemma, MiniMax, Nemotron, ZAYA, Hy3, Ling, GLM/GPT-OSS/Mistral where local;
- no `</think>` close token is forced;
- no parser output is repaired into a pass;
- no token/logit bias is applied to hide loops or EOS repetition;
- cache, scheduler, VL, MTP, and tool rows still pass after any forced behavior
  is removed or proven background-only.

The first Ling fake-merge source hit is now closed at the Osaurus source/test
level: vmlx produced coherent visible Ling output without sampler or reasoning
repair, and Osaurus no longer converts Ling reasoning into visible content.
The family remains not production-clear until the app/API Ling and Hy3 rows add
long-output, cache, SSM, memory, and saved-setting carryover artifacts.

Hy3 also has fresh vmlx-only evidence in
`/Users/eric/vmlx-swift/docs/internal/live-gates/20260518T_hy3_jangtq_no_guard_refresh/`.
The important contract finding is that generic `enable_thinking=true` is not a
Hy3 thinking control: the prompt tail remains `reasoning_effort:no_think`.
Native `reasoning_effort=low/high` rows route reasoning deltas cleanly and stop
normally. Osaurus must keep Hy3 on the native effort bridge, and the app/API row
still needs route, cache, memory, tools, and saved-setting proof.
