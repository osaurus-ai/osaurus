# Model issues triage — MiniMax M2.7 / VL / Zaya-CCA (in progress)

Status doc for three reported issues. Reproduction is engine-level (RunBench) +
code analysis — the live osaurus **UI** path is blocked on the Codex Computer Use
TCC grant (Accessibility + Screen Recording), so GUI-driven repro is unavailable.

Legend: 🔴 not started · 🟡 investigating · 🟢 root-caused · ✅ fixed+proven

---

## Issue 1 — MiniMax M2.7 JANGTQ small: CRASH on decode (JANGTQ quant bit-width mis-inference)  🟢 root-caused

- **Model:** `OsaurusAI/MiniMax-M2.7-Small-JANGTQ` (36G MoE, downloaded).
- **LIVE REPRO (RunBench, vmlx itself):** crashes on the first forward:
  ```
  [JangLoader] config-metadata mismatch patched in-memory: declared (bits=8, gs=32)
               -> shape-inferred (bits=16, gs=32), 62 per-layer overrides applied.
  Fatal error: [quantized_matmul] Last dimension (..., 3072) does not match the
               expanded quantized matrix (1536, 8192) ... group_size=32, bits=16
  ```
- **Root cause:** the JANG shape-walk **mis-infers `bits=16`** (not a real quant width)
  for 62 MoE layers, overriding the declared `bits=8`. The wrong bit width expands the
  packed weight to the wrong shape → `quantized_matmul` dimension mismatch → hard crash.
  This is the `bits x group_size` shape-ambiguity class (packed dim is consistent with
  multiple (bits, gs) pairs; the walk picks 16 first). ENGINE bug in vmlx-swift
  (`Load.swift` JANG shape walk / `inferBitWidthAndGroupSize`), NOT a template/reasoning/
  cache issue and NOT the osaurus enable_thinking policy (my initial hypothesis — refuted
  by the live crash, which is quant-matmul, thinking-independent).
- **Note:** reproduces in vmlx RunBench, so "works in vmlx" was probably a different M2.7
  variant (JANGTQ / JANGTQ_K), not this Small JANGTQ upload.
- **Next:** root-cause why the walk picks 16 (should honor declared bits=8 or exclude 16
  from `bitWidthsUsed` for packed-weight inference); fix in vmlx main; re-run decode to
  prove coherent; then live UI multiturn.
- **Fix (vmlx-swift #103, in the repin):** filter shape-walk candidate bits to the valid affine set {2,3,4,5,6,8} so the fp16 sentinel `16` cannot be selected; qkv_proj re-resolves to (8,64). PROVEN at engine level: M2.7-Small now loads + decodes coherently ("288 - 17 = 271"), no crash.
- **Status:** 🟢 engine-fixed + proven via RunBench. NOT yet "fixed" per acceptance rule — pending live dev-app UI multiturn (tools/reasoning on-off), which is TCC-blocked on Automation -> System Events.


## Issue 2 — VL models: engine vision path WORKS; bug (if any) is osaurus image-plumbing  🟢 partially root-caused

- **Model tested LIVE:** `ZAYA1-VL-8B-JANGTQ4` (`model_type zaya1_vl`, qwen2_5_vl vision tower).
- **Engine vision path WORKS (BENCH_VL_BATCH_CHAT = osaurus's BatchEngine path):** Turn 1
  correctly described the synthesized image — "a gradient square with a blue top-left corner,
  a red bottom-left corner, and a red top-right corner" — stop=stop, 29 tokens; Turn 2 answered
  "blue" correctly. The `EXIT=1` was only a bench MEMORY-gate assertion (footprint 118% of model
  size), NOT a vision/coherence failure.
- **So "VL broken in osaurus" is NOT the vision model.** Since the engine sees + describes images
  and stops correctly on the osaurus path, the real suspect is the **osaurus-side image plumbing**
  (UI/request -> `processedImages` -> `LMInput` at MLXBatchAdapter.swift:587) or a *specific* VL
  family — pinned only by a LIVE image-send through osaurus (UI or the running dev app).
- **Separate real bug found:** the **TokenIterator** VL path (BENCH_VL, NOT osaurus) does NOT stop
  on EOS id 262143 (`<|im_end|>`) -> spams `<|im_end|>` / degenerates to token 262143. osaurus uses
  BatchEngine (which stops correctly), so this is real but off the osaurus hot path. Worth fixing.
- **Status:** 🟢 engine vision proven-good; needs live osaurus image-send to confirm/deny the
  plumbing bug + identify which VL model is actually broken.


## Issue 3 — Zaya/AppleScript: marker leak (engine gap) + tool-format-context degeneration  🟢 root-caused (both)

- **Model:** `Osaurus-AppleScript-8B-JANG_4M` (`model_type zaya`, affine, tie_word_embeddings, eos `<|im_end|>`, `<zyphra_tool_call>`=101/`</zyphra_tool_call>`=102 special; `<function=`/`<parameter=` are plain BPE).
- **Marker leak — PROVEN engine gap, FIX IMPLEMENTED:** orphan closing tags (`</parameter></function></zyphra_tool_call>`) with no matching opener stream as literal text (the tool-call state machine only strips after matching an OPEN tag). Fix = `orphanStripTags` registry on `ToolCallParser` + orphan-run strip in `ToolCallProcessor` (vmlx branch `fix/orphan-tool-closer-strip`, +tests incl. chunk-split and embedded-marker cases; scoped to the format's OWN closers so tag-looking prose like `</div>` still flushes). Same robustness class as the Gemma `<channel|>` leak.
- **Degeneration (`<pad>`/gibberish) — REPRODUCED through the REAL osaurus AppleScriptLoop** (eval harness `apple_script` live lane, 7-step numbered procedure, `OSAURUS_APPLESCRIPT_TRACE=1`): after 2–4 tool turns the next step's FIRST content token is `<pad>`, followed by off-task text and the orphan-closer run. Trigger point is run-dependent (prompt 1206 tokens in one run, 1467 in another; 1231/1373 clean elsewhere) — content/stochasticity-dependent, not a token-count threshold.
- **Cache tiers RULED OUT (A/B):** `OSAURUS_EVALS_KV_REGIME=memory-only` (disk-L2 redirected to unwritable sentinel; run shows `KV +0hit/+0miss`, no L2 line — every step a full fresh prefill) still degenerates, even one turn EARLIER than the disk-L2 baseline (`L2 +5hit/+8store`). CCA companion restore/prefix reuse cannot be the trigger when zero reuse occurs.
- **Precision/NaN RULED OUT, sampling tail CONFIRMED (A/B):** identical task with an explicit, case-declared `samplingTemperature: 0` through the same loop ran **12 steps to a 2320-token tool-format prompt with ZERO pads/leaks/gibberish** — every step a well-formed tool call. NaN-corrupted logits would make greedy argmax pick index 0 (`<pad>`) even more reliably than sampling; it never did. The degeneration is the bundle-default **temperature 1.0 / top_p 0.95** sampling tail over a fine-tune whose post-tool-turn distribution keeps junk continuations (including `<pad>`, which a clean SFT should rank ~zero) inside the top_p mass — i.e. **fine-tune training-data defect (pad contamination / thin long-tool-transcript coverage), model-side, not an engine bug**.
- **Greedy weakness (same fine-tune, separate symptom):** at temp 0 the model loops the SAME batched script verbatim every step (and later drops its own `logNames` definition), never advancing the plan — multi-step brittleness either way. Per non-negotiables: no repetition-penalty rescue, no synthetic sampler defaults; the fix belongs in the fine-tune/bundle (`generation_config`) upstream.
- **Repro artifacts:** `/tmp/issue3-trace-baseline-diskl2.log`, `/tmp/issue3-trace-memonly.log`, `/tmp/issue3-trace-greedy.log` (+ run logs `/tmp/issue3-run{2,3,4}*.log`); case JSONs in `/tmp/issue3-repro/`, `/tmp/issue3-greedy/`.
- **Status:** 🟢 leak = engine gap with implemented+tested strip (vmlx worktree, pending PR/repin); 🟢 degeneration = model-side sampling-tail defect of the AppleScript 8B fine-tune, isolated with cache and precision ruled out through the real loop. Engine masking of visible text beyond the protocol-marker strip is explicitly NOT applied.


---

## Cross-cutting notes
- Same `convertTokenToId` unk-pitfall class already bit Mistral (fixed #100/#101);
  re-check MiniMax/Zaya reroute detection for the same pattern.
- The marker-leak class (`</...>` in visible text) previously hit Gemma-4
  (`<channel|>` leak, osaurus #44) — the Zaya `zyphra_tool_call` leak may be the
  same missing-strip pattern for a different family.

---

## Live dev-app (osaurus API) results — build on pin d103e0cc

Built the osaurus dev app on the fixed pin and drove its local API (port 1337):

- **Issue 2 — Zaya VL WORKS end-to-end through osaurus.** Sent a real base64 image to
  `zaya1-vl-8b-jangtq4`: it processed the image and described it correctly ("a blend of
  blue, green, yellow, and pink hues…"), `finish=stop`, no error. So Zaya VL image-sending
  is fine through the dev app. "Some VL models not working" must be a DIFFERENT VL family
  (Mistral3/Pixtral/Gemma-4 VLM — not downloaded) — need the specific broken model named.
  (Note: model ids are lowercased/de-org-prefixed, e.g. `zaya1-vl-8b-jangtq4`.)
- **Issue 3 — single-turn tool context is CLEAN through osaurus.** `osaurus-applescript-8b-jang_4m`
  with a tool + a 1-step tool-result context produced a coherent `run_applescript` tool call
  (valid AppleScript), `finish=tool_calls`, NO `<pad>`, NO `</zyphra_tool_call>`/`</parameter>`
  leak. So the degeneration + marker leak require the FULL multi-step agent loop (tpae had
  scripts_run=5) — the accumulated long tool-transcript is the trigger, confirmed not a
  single-turn issue. The marker-leak strip would be a symptom guard; the real fix is the
  degeneration root cause, which needs a faithful 5+ step loop repro to trace.
- **Issue 1 — JANGTQ crash fix is IN this dev build** (pin d103e0cc); MiniMax-M2.7-Small now
  loads (proven in RunBench). Live multiturn UI confirm pending computer-use.

## VL wiring cross-check (vmlx-swift ↔ osaurus) — architecturally sound

Systematic cross-check of the full VL matrix (per user request — "plenty of models have VL like qwen"):

- **vmlx dispatch (VLMModelFactory):** 21 VL model_types — `qwen2_vl`, `qwen2_5_vl`,
  `qwen3_vl`, `qwen3_5`, `qwen3_5_moe`, `mistral3`, `ministral3`, `pixtral`, `gemma3`,
  `gemma4`, `gemma4_unified`, `diffusion_gemma`, `idefics3`, `smolvlm`, `llava_qwen2`,
  `paligemma`, `fastvlm`, `glm_ocr`, `lfm2_vl`, `nemotron_h_omni`, `zaya1_vl`.
- **Processors:** every dispatch type has a registered processor (Qwen2VL/Qwen2_5_VL/
  Qwen3VL/Pixtral/Mistral3/Gemma3/Gemma4/Idefics3/SmolVLM/FastVLM/PaliGemma/Glm46V/
  Lfm2Vl/NemotronHOmni/Zaya1VL). No missing processor.
- **Detection:** `VLMTypeRegistry.supportedModelTypes = Set(_creators.keys)` — DERIVED
  from the factory, so detection can never drift from dispatch. osaurus `VLMDetection.isVLM`
  delegates to it. Complete for all 21.
- **osaurus image gate:** `supportsVision = VLMDetection.isVLM(modelId)` (HTTPHandler
  4293/4433) — uses the correct architecture-based detection; images forwarded via
  `MLXBatchAdapter.processedImages` (587). Sound.
- **Caveat (fragile parallel, UI-only):** `ModelMediaCapabilities` uses NAME-substring
  matching (imageOnlyPatterns) and defaults unmatched names to `.textOnly` — BUT it's for
  the composer/UI capability display and has an `fallbackSupportsImages` (isVLM) rescue in
  `composerCapabilities`; it does NOT gate request-path image forwarding. Still, it's a
  drift risk worth converting to architecture-based detection.
- **Conclusion:** no whole-family VL wiring gap. "Some VL models not working" is therefore
  **model-specific runtime** (e.g. the Mistral3/Pixtral image-token round-trip already fixed
  in vmlx #101, or a specific processor/config), NOT a detection/dispatch/processor gap.
  Zaya VL is proven working live through the dev app. **Need the specific failing VL model
  named** (Qwen VL? Gemma-4 VLM? Mistral3?) to reproduce + fix the model-specific cause.
