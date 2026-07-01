# vmlx-swift → osaurus model integration: considerations & data flow

How osaurus consumes a vmlx-swift model end to end, and the per-model
considerations for the models added/fixed in this sweep
(`hunyuan_v1_dense`, Rampart PII) plus the Mistral chat path.

## The generic load → infer pipeline (osaurus side)

A model directory is `config.json` + weights (`*.safetensors`) + tokenizer
files (+ optional chat template). osaurus loads it through vmlx:

1. **Dispatch by `model_type`.** `config.json.model_type` is matched against
   `LLMModelFactory` / `VLMModelFactory` registries
   (`Libraries/MLXLLM/LLMModelFactory.swift`, `Libraries/MLXVLM/VLMModelFactory.swift`).
   Unknown type → `Unsupported model type: …` (this is exactly what #358 hit).
2. **Build the Swift module tree.** The registered `Configuration` is decoded
   from `config.json`; the model is constructed. `@ModuleInfo(key:)` paths must
   match the safetensors tensor names exactly.
3. **Apply quantization.** `Libraries/MLXLMCommon/Load.swift` reads the
   `quantization` block from `config.json` and quantizes the matching
   Linear/Embedding layers **before** loading weights:
   - Standard MLX models → affine `{group_size, bits}` from `config.json`.
   - JANG models → per-layer bit widths inferred from tensor shapes.
   - This is automatic on the LLM/VLM path — a registered model does **not**
     hand-roll quantization. (Contrast: the standalone RampartPII library has
     its own loader and must call `quantize()` itself — see below.)
4. **Load + verify weights.** `model.update(parameters:, verify:)` — a key or
   shape mismatch throws (`UpdateError.mismatchedSize` / `unhandledKeys`).
5. **Tokenizer.** The HF tokenizer (`tokenizer.json` / `tokenizer_config.json`,
   `vocab.txt`, `special_tokens_map.json`) is loaded via `VMLXTokenizers`.
6. **Chat template (jinja).** Rendered through `VMLXJinja`. Source precedence:
   - inline `tokenizer_config.json.chat_template`, else
   - a standalone **`chat_template.jinja`** sidecar (JangLoader fallback,
     vmlx #82), else
   - **`chat_template.json`** (Mistral/Pixtral VLMs ship the template only here,
     with `[IMG]` markers — vmlx #85), else
   - a code fallback in `ChatTemplates/ChatTemplateFallbacks.swift`.
   `JangLoader.isVisionChatTemplate` / `genericJsonTemplate` pick the right
   path; mis-selection leaks raw control tokens (e.g. `<|im_start|>`).
7. **Generation.** osaurus drives `BatchEngine.generate(...)`; stop tokens come
   from the tokenizer/template (EOS / turn-boundary). A wrong stop-token id is a
   classic **loop** cause — generation never halts.

osaurus's own knobs layer on top: KV-cache mode (TurboQuant off by default),
prefix cache, paged KV, memory-safety plan, reasoning toggle (top-level
`enable_thinking` request field, not `chat_template_kwargs`).

**To pick up a new vmlx model, osaurus only needs a pin bump** (Package.swift +
Package.resolved) — *if* the model is reachable through an already-consumed
product (MLXLLM/MLXVLM). A model in a **new** product (RampartPII) also needs an
explicit dependency + a consumer.

---

## `hunyuan_v1_dense` (LLM — works via repin)

| Layer | Consideration |
|---|---|
| Dispatch | `model_type = hunyuan_v1_dense` registered in `LLMModelFactory` (vmlx main `0b709a44`). |
| Architecture | Llama-style dense GQA + **two deltas**: per-head `query_layernorm`/`key_layernorm` applied **after** RoPE (opposite order from `hy_v3`); `DynamicNTKAlphaRoPE` = plain RoPE with base rescaled by `alpha^(d/(d-2))` from `rope_scaling.alpha`. |
| Embeddings | Standard word embeddings; `tie_word_embeddings = true` → no `lm_head`, `sanitize` pops `lm_head.weight`, logits via `embed_tokens.asLinear`. |
| Quant | Affine (e.g. 8-bit/gs64) — **auto-applied** by `Load.swift` from `config.json.quantization`. No model-side quant code. |
| Tokenizer | Standard HF tokenizer. |
| Chat template | Ships as a **standalone `chat_template.jinja`** (no inline template in `tokenizer_config.json`) → relies on the JangLoader sidecar fallback (vmlx #82). Reasoning models need `max_tokens ≥ ~400` or they truncate inside `<think>`. |
| osaurus wiring | **Pin bump only.** Loads + chats through the existing LLM path. Proven: deterministic load+decode, EN→FR / EN→zh translations correct. |

## Rampart PII (token classifier — needs a consumer, not a chat model)

| Layer | Consideration |
|---|---|
| Dispatch | **Not** an LLM/VLM. Standalone `RampartPII` library + `RampartSmoke` exe (vmlx main `8c2101fe`). `model_type = bert`, but consumed directly, not via the factories. |
| Architecture | Encoder-only BERT (6-layer, hidden 384, 12 heads) token classifier: embeddings (word+pos+token_type → LayerNorm), post-LN attention (exact-erf GELU, `1/√head_dim`, additive mask), classifier head on the full sequence output (no pooler). 35 BIO labels. |
| Quant | **4-bit affine** (`config.json.quantization` gs64/4bit). The library has its **own** loader, so it must call `quantize(model:groupSize:bits:)` itself before `update()` — this was the #98 blocker I fixed; LayerNorms are skipped automatically. |
| Tokenizer | **Custom offset-aware WordPiece** over `vocab.txt` (not the HF tokenizer pipeline). Char offsets index into `Array(text)`; body hard-capped at `maxLength-1` (my fix) to avoid position-embedding OOB. |
| Chat template | **None** — it's a classifier, not a generator. Input is raw text; output is `[PIISpan]` (type, text, char range, score) + a `redact()` helper. |
| Scope caveat | **Neural-only.** The reference `demo.py` *unions* the model with a deterministic `pii_rules.py` regex/checksum layer (EMAIL/URL/IP/SSN/CREDIT_CARD — classes the model is weak on). Reliable structured-PII redaction in osaurus would want that rule layer added on top. |
| osaurus wiring | Pin bump **does not** expose it. Needs (a) `.product(name: "RampartPII", package: "vmlx-swift")` added to the OsaurusCore target, and (b) a consumer surface (e.g. a redaction/guard pass over prompts or tool I/O). Flagged as a follow-up — not wired in this PR. |

## Mistral chat (text + VLM) — looping/incoherence

Tracked separately in this sweep (see PR description / `FIX_SWEEP_TRIAGE.md`).
Key surfaces that drive Mistral coherence:
- **Chat template version** (V3 `[INST]` / V7 / V13 `[SYSTEM_PROMPT]`) selection
  and **single-BOS** invariant — double-BOS or an unclosed `[INST]` turn causes
  incoherence/looping (cf. the Laguna missing-BOS chat-garbage precedent, #77).
- **Special-token detection** must use a round-trip (`convertIdToToken(id)==t`),
  **not** `convertTokenToId(t) != nil` (returns the `<unk>` id for any absent
  token — the documented pitfall).
- **Stop/EOS token id** — a wrong stop id means generation never halts → loop.
- Template source: Mistral/Pixtral VLMs ship the template in `chat_template.json`
  with `[IMG]` markers (vmlx #85), not inline.

**Fixed (vmlx-swift #100, in the repin):** the chat-template family-detection
used `convertTokenToId("<|im_end|>") != nil` (and other sentinels) as an
existence test — but `convertTokenToId` returns the `<unk>` id for *absent*
tokens, so it was non-nil even for Mistral (which has no `<|im_end|>`). A
tool-bearing Mistral request therefore matched the Nemotron/Gemma reroute and was
fed a **ChatML/Gemma** prompt (`<|im_start|>`/`<|turn>`/`<think>`/`<tool_call>`) —
tokens it lacks — so it went incoherent and never stopped (looping). Since
osaurus agent use always injects tools, this hit essentially every Mistral chat.
Fixed by round-tripping every sentinel check (`convertIdToToken(convertTokenToId(t)) == t`).
Proven via `BENCH_TEMPLATE_SMOKE`: tool cases now render native
`[SYSTEM_PROMPT]…[AVAILABLE_TOOLS]…[INST]…[/INST]` with no ChatML markers.
