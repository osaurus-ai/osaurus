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


## Issue 2 — Some VL models not working in osaurus (send images live)  🟡

- **Models:** Zaya VL (`OsaurusAI/ZAYA1-VL-8B-JANGTQ4`), plus Mistral3/Pixtral VL.
- **Claim:** some VL models don't work; need to test VL + sending images live.
- **Relevant recent change:** I just round-trip-guarded the Mistral3/Pixtral
  **image-token** resolution (vmlx #101 F2) — if the image placeholder id was
  wrong, image embeddings expand into the wrong positions → broken vision. Check
  whether other VL families (Zaya, Gemma-4 VLM) have the same or related issues.
- **Repro plan:** RunBench `BENCH_VL=1` / `BENCH_VL_BATCH_CHAT` (loads model +
  synthesizes a 224×224 image + runs the vision path + multi-turn cache reuse) per
  VL family. This is the engine-level equivalent of "sending an image".
- **Status:** Zaya VL downloading; VL smoke pending.

## Issue 3 — Zaya CCA cache incoherent + AppleScript model marker leak / `<pad>`  🟡

- **Models:** `OsaurusAI/Osaurus-AppleScript-8B-JANG_4M` (Zaya-family — emits
  `zyphra_tool_call`), Zaya-CCA (`OsaurusAI/ZAYA1-8B-JANGTQ2`). Downloading.
- **Observed (from tpae):** the AppleScript summary was:
  `"<pad>\nThe script launched Music. … If Music plays, you can clicking
  everywhere.\n</parameter>\n</function>\n</zyphra_tool_call>"`
  — i.e. (a) **`<pad>` leak** (numeric/long-context degeneration or a cache issue),
  (b) **tool-call closing markers `</parameter></function></zyphra_tool_call>`
  leaking into the visible summary** (the Zaya `zyphra_tool_call` strip isn't
  removing the closing envelope), and (c) semantic **incoherence**.
- **Hypotheses:**
  1. **Marker leak** — the Zaya XML tool-call parser (`zyphra_tool_call`) isn't
     stripping the closing tags from the assistant text on this model, OR the
     summary is assembled from a raw buffer that still has them.
  2. **`<pad>` / incoherence** — Zaya CCA (cross-context attention) cache behaving
     wrong (the user's suspicion), OR fine-tune quality, OR a long-context numeric
     issue like the Gemma `<pad>` class.
- **Repro plan:** RunBench decode on the AppleScript model with a tool-bearing
  prompt; inspect raw tokens vs decoded text; check the Zaya parser strip + the
  CCA cache path. Separate "cache" from "fine-tune" by testing a short vs long
  context and greedy vs sampled.
- **Status:** models downloading; repro pending.

---

## Cross-cutting notes
- Same `convertTokenToId` unk-pitfall class already bit Mistral (fixed #100/#101);
  re-check MiniMax/Zaya reroute detection for the same pattern.
- The marker-leak class (`</...>` in visible text) previously hit Gemma-4
  (`<channel|>` leak, osaurus #44) — the Zaya `zyphra_tool_call` leak may be the
  same missing-strip pattern for a different family.
