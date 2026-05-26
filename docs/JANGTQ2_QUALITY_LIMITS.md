# JANGTQ2 (2-bit codebook) — systematic quality limits

**Status:** Tracked. Not a fixable osaurus runtime bug — these are the
empirical limits of 2-bit codebook quantization documented in
`~/jang/research/JANGTQ-BENCHMARKING-NUANCES-2026-04-25.md` and confirmed
across multiple model families. This doc consolidates the cross-family
findings so reviewers, users, and future PRs can see the whole picture
in one place.

## Summary

The JANGTQ2 quant tier (2-bit codebook for routed-expert weights, 8-bit
affine for attention / embed / lm_head) is a memory-tier choice with a
documented quality floor:

* **Empirical coherence ceiling around 2–3 k output tokens.** Beyond
  that, the residual stream accumulates 2-bit codebook noise and the
  model collapses into one of a small set of failure modes:
  * Markdown-header repetition (`### 1.1.1 ### 1.1.2 …`)
  * Short-phrase loops (`I'm sorry I'm sorry …`, `2+2 2+2 …`)
  * Off-topic hallucinated tasks (the 2026-05-07 ZAYA "build a REST API
    from a JSON file" loop is exactly this pattern)
  * CJK punctuation / emoji garbage
* **Worse on long verbose output**: per-token character-level noise
  compounds linearly across the residual stream. Code (FIM mode) is
  more stable than free-form chat at the same token count.
* **Greedy thinking-mode runs ARE the worst case**. `T=0.0` on a
  reasoning-template family compounds noise into a deterministic
  collapse. Heavy chat preambles that nudge the model toward thinking
  trip the same failure even when the host clamps `enable_thinking=false`
  (the model can still emit hidden `<think>` content).

## What's NOT the bug (known false leads)

* The `§410` metadata bug (`bits=2` overrides 8-bit attention with the
  routed-width kernel). Verified on every JANGTQ2 bundle the user has
  by inspecting `config.json["quantization"]["bits"] == 8`. Already
  fixed at converter time per `~/jang/research/LING-RUNTIME-ARCHITECTURE.md`
  §9.
* The `§422` nested-`text_config` resolution bug (Qwen3.6 / Holo3 read
  default `2` because Swift checked the wrong fallback). Resolved
  upstream in vmlx + HF bundle metadata; ZAYA configs are flat (no
  `text_config` wrapper) so the bug doesn't apply.
* The osaurus-side wiring in PR #1147 is topology- and family-specific:
  Ling defaults `disableThinking=true` to emit the upstream Bailing
  "detailed thinking off" directive, but explicit `disableThinking=false`
  and positive reasoning requests are preserved as real opt-ins. Osaurus no
  longer merges Ling `.reasoning` into visible content or suppresses
  unclosed-reasoning flags; if a no-thinking row emits reasoning, that row
  stays red for template/parser/runtime root cause. ZAYA keeps the family
  matcher only for hybrid cache topology and default-off prompt context,
  while explicit `disableThinking=false` is preserved as a real reasoning
  opt-in. The shared pieces are eager `setHybrid(true)` and SSM re-derive
  disable.

## Cross-family JANGTQ2 status (osaurus catalog as of 2026-05-07)

| Bundle | Status | Failure mode at long-prompt chat |
|---|---|---|
| `ling-2.6-flash-jangtq2-crack` | OK on long prompts as of vmlx pin `b9da180`; the 2–3 k coherence ceiling below still applies | Pre-`b9da180`: `EXC_BAD_ACCESS` in vmlx's `BailingLinearAttention.recurrentGLA` Metal Gather kernel during prefill at ≥ ~2 k tokens. `b9da180` ports `recurrentGLA` to a fused Metal kernel with a singleton kernel manager — pipeline state is now process-scoped instead of request-local, so the lifetime window is closed. See `LING_JANGTQ2_LONG_PROMPT_CRASH.md`. The 2-bit-codebook coherence ceiling at the bottom of this doc is a separate, model-side limit and remains. |
| `zaya1-8b-jangtq2` | **Degenerates** | Reasoning-mode loop (e.g. "build a REST API from a JSON file" repeated 30+ times) once cumulative output crosses the 2–3 k ceiling. Confirmed 2026-05-07: 3419-token preamble + `enable_thinking=false` → 75 s of looping content before user cancelled. Bundle metadata is correct (`bits=8`, `routed_expert_bits=2`); the failure is the codebook precision floor under heavy chat preambles. |
| `nemotron-omni-nano-jangtq4-crack` | OK (4-bit, not affected) | — |
| `zaya1-8b-jangtq4` | OK (4-bit, not affected) | — |
| `*-jangtq` (no numeric suffix, e.g. `deepseek-v4-flash-jangtq`, `kimi-k2.6-small-jangtq`) | Per-bundle (typically JANGTQ4) | Not the 2-bit tier; unaffected by this class of issue. |
| `*-mxfp4` / `*-MXFP4` (e.g. `ling-2.6-flash-mxfp4-crack`, `zaya1-8b-mxfp4`) | OK (4-bit affine) | Stable on the same prompts that break the JANGTQ2 variant. Recommended for chat. |

## Recommendations

1. **Don't ship JANGTQ2 as a default chat tier.** Use MXFP4 or JANGTQ4
   for any agent profile that loads heavy system prompts.
2. **Document the limit in the picker UI** when JANGTQ2 is selected
   (out of scope for this PR — note it for the picker work).
3. **Don't blanket-apply `repetition_penalty`**. Per
   `JANGTQ-BENCHMARKING-NUANCES-2026-04-25.md`, the JANG team's
   guidance is to verify the issue isn't fixed by raising
   `max_tokens` first; opaque sampler reshaping can mask actual
   model behavior. Leave the knob to user override.
4. **For users who must run JANGTQ2** (memory-bound machines): keep
   the chat preamble tight and bound `max_tokens` under 1500. See
   `PROMPT_BLOAT_FOLLOWUP.md` for the prompt-construction trace that
   shows where the chat UI's 3500-token preamble comes from.

## What this PR does NOT change

* No osaurus-side per-bundle override of sampler params — JANG
  guidance explicitly warns against masking model behavior with
  `repetition_penalty` / `min_p` / `top_k` defaults.
* No osaurus-side `max_tokens` cap for JANGTQ2 — leaving the knob to
  user / API caller, with the doc above as the rationale for picking
  a sensible value.
* No Ling reasoning-merge remains in Osaurus: Ling defaults to
  `enable_thinking=false` through profile policy, explicit opt-in reaches
  vmlx, and any reasoning stream remains on the reasoning channel. ZAYA is
  reasoning-capable; osaurus must trust its bundle stamps, default
  `enable_thinking=false` for short chat UX, and preserve explicit opt-in
  requests (`disableThinking=false`) as real reasoning-channel output.

## Pointers to follow-up surface

* ✅ Closed in vmlx pin `b9da180`: `BailingLinearAttention.recurrentGLA`
  2-bit Metal pipeline-state lifetime. Fused Metal kernel + singleton
  kernel manager. See `LING_JANGTQ2_LONG_PROMPT_CRASH.md` for the
  pre-fix crash trace; the doc is retained for archival reference.
* ✅ Closed in vmlx pin `b9da180`: `coordinator.storeAfterGeneration`
  now runs AFTER `.info` is yielded, not before. Osaurus defaults
  `enableSSMReDerive: true` so hybrid SSM/linear-attention cache rows
  restore companion state by default.
* Osaurus prompt-bloat reduction (lazy tool schemas) — see
  `PROMPT_BLOAT_FOLLOWUP.md`. Most impactful single change to make
  JANGTQ2 useful again on chat workloads (since the 3500-token
  preamble pushes cumulative output past the coherence ceiling).
