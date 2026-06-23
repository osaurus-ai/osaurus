# Spawn / Image-Gen / Edit / Delegation — Production Readiness

Living assessment. Updated as stress tests + fixes land. Honest status only —
"ready" requires live proof, not code-reading.

## ⛔ CRITICAL crash found + fixed (stress-proving now): image→model-load concurrent-GPU
Stress testing surfaced a **real SIGABRT crash** — `MTLReleaseAssertionFailure` in
`-[IOGPUMetalCommandBuffer setCurrentCommandEncoder:]` — on the **image→model-load**
handoff (e.g. image_edit completes → chat model reloads to summarize). The exclusive
image MetalGate was released (`ImageGenerationService.exitImageGeneration`) **before**
vMLXFlux's async Metal tail (VAE decode/teardown) drained, so the next exclusive
producer (`enterModelLoad`) raced the in-flight command buffer.

This is the **reverse direction** of the BatchEngine drain shipped in vmlx PR #82
(which fixed chat→image). **Fix applied** (osaurus, ImageGenerationService): the same
`MLXCacheIOLock`/`Stream.gpu.synchronize` drain barrier right before
`exitImageGeneration`, covering success/cancel/error paths. Rebuild + stress-proof in
progress. Until proven, the image path is **NOT production-ready** (intermittent crash
under repeated/chained image ops).

NOTE: earlier "app DOWN" reads via `/health` were false (the endpoint blocks during GPU
teardown); the REAL crash was confirmed via `pgrep` + the macOS crash report
(`osaurus-2026-06-22-203544.ips`).

## TL;DR
- The **dangerous** bug (concurrent-GPU crash on chat→image handoff) is **fixed + shipped**
  (vmlx PR #82, merged to canonical, osaurus repinned + rebuilt + verified).
- **Single** image_generate / image_edit / spawn / local_delegate + context pass-off:
  **proven working** in isolation across many models.
- **Chained / repeated** image ops (gen→edit in one turn, or many runs back-to-back):
  **UNDER INVESTIGATION** — a stress repro showed chained gen+edit failing (cancellation /
  empty / 0 images). This is the current #1 blocker for calling the image path
  production-grade. Root cause being isolated.
- Delegation ships **default-OFF** + per-agent opt-in → small blast radius.

## Capability matrix
| Capability | Status | Evidence |
|---|---|---|
| GPU safety on chat→image handoff | 🟢 Ready | 0 crashes / 35+ models; vmlx#82 merged |
| Single image_generate | 🟢 Ready | 6/8 drivers → real PNG, GPU-safe |
| Single image_edit | 🟢 Ready | edited artifact produced (continuous run) |
| spawn | 🟢 Ready | gemma + qwen3 relay |
| local_delegate | 🟢 Ready | 7×8=56 relayed |
| Context pass-off (recall generated image) | 🟢 Ready | coherent recall, no re-gen |
| Delegation default-off + per-agent toggle | 🟢 Ready | opt-in |
| **Chained gen→edit (one turn)** | 🔴 Investigating | stress repro: 3/3 runs failed, 0 PNGs (cancellation/empty) |
| **Repeated image load (back-to-back)** | 🔴 Investigating | same repro; isolating degradation vs chaining |
| Multi-turn DB-persisted image path | ⚪ Unverified | not tested across separate UI turns |
| Small-qwen image refusal | 🔴 Won't fix | model-level (qwen3-8b/qwen2.5-3b) |
| R4 channel-marker leak | ⚪ Non-issue | did NOT reproduce (0/3 stress runs) |
| R6 mid-word seam | ⚪ Likely non-bug | probably client-side SSE concat artifact |

## Root-cause notes (in progress)
- Chained/repeated image failure is **NOT** the agent-loop budget: the run cap is
  `ChatConfigurationStore.maxToolAttempts ?? 30` (HTTPHandler:4828), not the tight
  `maxToolCalls: 2` (that's the local_delegate sub-budget). `maxElapsedSeconds` is not
  enforced on the run. ⇒ not a clean timeout; points to a **cancellation race /
  residency-handoff** in the image job under chained/repeated load.
- Image tools correctly **bypass** the 120s registry tool-timeout
  (`NativeImageTools.bypassRegistryTimeout = true`), so single long gens (135s/156s) succeed.

## Settings already present (re: "supply a timeout setting")
- `maxElapsedSeconds`, `maxToolCalls`, `maxDelegateTurns`, `maxDelegateTokens` are
  user-facing steppers in **Settings → Agent Delegation** (`AgentDelegationSettingsSection`).
- `maxToolAttempts` (the real run cap) lives in chat config.
- There IS a budget-exhaustion message ("Tool-loop budget of N iterations exhausted
  without a final answer", HTTPHandler:5307) — but it does not point to the setting.

## ⚠️ Test-methodology correction (affects earlier reads)
- The `/health` endpoint **blocks briefly during post-image GPU teardown**
  (synchronous `Memory.clearCache` + `Stream.synchronize`), so a health probe fired
  right after a gen returns a **false "DOWN"** while the process is alive and recovers
  within seconds. Verified: after a clean single gen, `/health` read "DOWN" but `pgrep`
  showed the process alive and a retry returned healthy. **Use PNG-count + `pgrep`, not
  `/health` timing, as the liveness signal for image tests.**
- A real crash report DID appear once (20:18) — but from an **abnormal path**: killing the
  stress client mid-image-op orphaned a server-side image job, which then collided with a
  new request (two concurrent image generations). Flags a latent gap: orphaned/concurrent
  image jobs can crash (the image lane should be exclusive). Not a normal-operation crash.
- Re-establishing the chained/repeated verdict with reliable metrics now.

## Open work to reach production-grade
1. Isolate + fix the chained/repeated image cancellation (#88).
2. Make image failures return a CLEAR, actionable message (not raw "CancellationError").
3. Verify the multi-turn DB-persisted image path.
4. Stress matrix: concurrency, repeated load, RAM safety, every model.
