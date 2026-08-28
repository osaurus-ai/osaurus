# Ling JANGTQ2 + long prompt — vmlx Metal crash

**Status:** ✅ **Fixed in vmlx pin `b9da180`** (this PR).
`BailingLinearAttention.recurrentGLA` now ports to a fused Metal kernel
(`bailing_recurrent_gla` via a singleton `BailingGLAKernelManager`),
running the recurrent loop in one Metal command instead of dispatching
`L * layers` small MLX graphs. The pipeline state is owned at
process-init scope by the singleton, so it cannot be released between
prefill steps — the lifetime window that the codebook `Gather` op was
hitting at ~2 k tokens is closed.

The reference path (`recurrentGLAReference`) is preserved for unusual
head dimensions (`D % 32 != 0`); production Ling/Bailing bundles all
satisfy `D % 32 == 0` so they take the fused-kernel path.

Original symptom + repro retained below for archival reference and so
future regressions on the same surface can compare diagnostic shape.

## Symptom

`Ling-2.6-flash-JANGTQ2-CRACK` (and any other JANGTQ2 / 2-bit Ling
bundle) crashes the host process with `EXC_BAD_ACCESS` during prompt
prefill when the system prompt + user message exceeds ~2 k tokens.

Repro distilled:

| Prompt size | Result |
|---|---|
| 37 tokens (`hi`) | Streams "Hello! How can I help you today?" cleanly. |
| 855 tokens (small preamble) | Streams correctly, ~9 s end-to-end. |
| 2962 tokens (UI-equivalent preamble) | `EXC_BAD_ACCESS` at decode-step 0. |

Reproduces deterministically on the same bundle / prompt combination.
The same prompt against the same model in the `MXFP4` quant tier
streams without issue.

## Crash signature (`~/Library/Logs/DiagnosticReports/osaurus-...ips`)

```
exception:
  type: EXC_BAD_ACCESS
  signal: SIGSEGV
  subtype: KERN_INVALID_ADDRESS at 0x00000000000a30d2

triggered thread (com.apple.root.user-initiated-qos.cooperative):
  libobjc.A.dylib!objc_msgSend
  osaurus!NS::Object::sendMessage<…, MTL::ComputePipelineState const*>(…)
  osaurus!MTL::ComputeCommandEncoder::setComputePipelineState(…)
  osaurus!mlx::core::metal::CommandEncoder::set_compute_pipeline_state(…)
  osaurus!mlx::core::Gather::eval_gpu(…)
  osaurus!mlx::core::eval_impl(…, bool)
  osaurus!mlx_eval / MLX evaluator entry
  osaurus!recurrentGLA(q:k:v:g:scale:h:)
  osaurus!BailingLinearAttention.callAsFunction(_:cache:offset:)
  osaurus!BailingDecoderLayer.callAsFunction(_:attnMask:cache:offset:)
  osaurus!BailingHybridLanguageModel.callAsFunction(_:cache:)
  osaurus!BatchEngine.stepPrefill(slotIndex:)
```

Translation: vmlx's `recurrentGLA` kernel (the gated-linear-attention
recurrent path used by Ling's hybrid linear-attention layers) is
issuing a Metal `Gather` op whose compute pipeline state is `nil` (or
freed) at the moment the encoder tries to bind it. ObjC's
`objc_msgSend` then dereferences a low pointer and traps.

The bug is in the kernel-state lifetime, not the Swift wiring above
it. `BailingLinearAttention` is identical between the bundle's
JANGTQ2 (2-bit) and JANGTQ4 / MXFP4 variants — but only the 2-bit
variant trips the failure, which points at a 2-bit codebook code path
inside `recurrentGLA` (or the `Gather` op vmlx schedules to gather
codebook entries on Metal).

## Why this is not the bump PR's responsibility

* The crash repros at every prior pin osaurus has shipped — long-prompt
  Ling JANGTQ2 has never been validated end-to-end. The 88fc352 bump
  fixes BailingHybrid B>1 RoPE / per-slot offsets and the prompt-tail
  derivation; both unblock single-turn and multi-turn correctness but
  neither touches the `recurrentGLA` kernel state.
* Ling MXFP4 / JANGTQ4 (4-bit) variants stream the same long prompt
  cleanly. The codebook tier is the discriminator.
* Historical note: the original osaurus-side stream-wiring fixes included
  a Ling `enable_thinking=false` clamp and reasoning merge. PR #1147 has
  since replaced that with default-off profile policy, explicit opt-in, and
  reasoning-channel preservation. The crash investigated here is still
  downstream of the osaurus call path and remains separate from that
  app-side policy cleanup.

## Workarounds for users

1. **Use Ling MXFP4 or JANGTQ4** for any chat with non-trivial system
   prompts. Both are stable at ~3 k-token preambles.
2. If JANGTQ2 must be used (e.g. memory-bound machine), keep the
   request prompt tight: send minimal system prompt and rely on tools
   instead of inline tool-schema bloat (see `PROMPT_BLOAT_FOLLOWUP.md`).

## Pointers for the vmlx-side fix author

* `Libraries/MLXLLM/Models/BailingHybrid.swift`'s
  `BailingLinearAttention` — the `recurrentGLA` callee is the immediate
  caller; check whether the JANGTQ2 codebook gather schedules a
  `Gather` op that captures a stale `MTL::ComputePipelineState`.
* `Libraries/MLXLMCommon/BatchEngine/BatchEngine.swift:stepPrefill` —
  the path that calls `LanguageModel.prepare(_:cache:windowSize:)` on
  hybrid models. If the kernel state lifetime is request-local, prefill
  may be losing the state across the prompt segments it batches.
* `mlx-swift`'s `Gather::eval_gpu` (C++) is the immediate dereference
  site. Likely the failing pointer is a cached `MTLComputePipelineState
  *` that's been released before the encoder enqueues the dispatch.
* Suggested first probe: enable Metal API validation
  (`-MetalCaptureEnabled YES` on the scheme, or
  `setenv("MTL_DEBUG_LAYER", "1", 1)` early in `applicationDidFinishLaunching`)
  and re-run the 2962-token Ling JANGTQ2 prompt; the validator should
  flag the lifetime violation before SIGSEGV.
