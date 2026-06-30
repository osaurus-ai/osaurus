# Spawn / Image-Gen / Edit / Delegation — Production Readiness

Living assessment. Updated as stress tests + fixes land. Honest status only —
"ready" requires live proof, not code-reading.

> **Unified-architecture rename (2026-06-25).** The dated assessments + capability
> matrix below predate the subagent unification and still use the old surface:
> `local_delegate` is **removed** (folded into `spawn`) and `image_generate` +
> `image_edit` are merged into one **`image`** tool (`source_paths` ⇒ edit); config is
> `SubagentConfiguration` / `SubagentSettingsSection`. The crash/GPU/handoff proofs
> below remain valid for the underlying behavior — the engine paths are unchanged; only
> the tool/config names changed. Re-run the live readiness matrix against the new tool
> surface before re-asserting "ready" (the `make app` + four-path re-verify in
> SUBAGENT_ORCHESTRATION_STATUS.md). Canonical architecture:
> SUBAGENT_ORCHESTRATION_STATUS.md → "Unified Subagent Architecture".

## Cohesion pass + production gate (2026-06-23)

A full settings/agent-loop cohesion audit (3 parallel reviewers) found the two-tool
separation, per-tool default-model resolution (agent path AND direct `/images` API),
the shared GPU-drain, and the agent-loop steering all already cohesive. It surfaced
**three wiring gaps, now fixed** (commit "Wire up 3 delegation-settings cohesion gaps"):

1. **`spawnableAgentNames` had no UI** → `spawn` was unreachable from Settings (the
   How-It-Works blurb advertised it and `SpawnTool` pointed at a control that didn't
   exist). Added a "Spawnable Agents" subsection (per-persona toggles). **Live A/B
   proven**: with the list populated, `spawn` is in the model's injected tool set;
   emptied, `spawn` drops out while `image_generate`/`image_edit`/`local_delegate`
   remain — i.e. availability is gated precisely by the field the UI now writes.
2. **`ramSafetyPreflightEnabled` was dropped by `.normalized`** → turning the RAM-safety
   preflight OFF was silently reverted on every save/load (the store normalizes on both).
   Now preserved through normalize. Regression test added (runs in CI `test-core`).
3. **`budgets.maxToolCalls` was a no-op UI knob** → spawned subagents are text-only
   (`AgentSubagentRunner` passes `tools:nil`), so nothing could enforce it. Removed the
   stepper; field kept reserved/forward-compat.

**Live stress on the rebuilt binary (fresh dev app, :1337), 0 crashes throughout (6→6):**
- Direct `/v1/images/generations`: 5/5 (17–31s), real PNGs, process alive.
- Direct `/v1/images/edits`: 3/3 (Qwen-Image-Edit, ~224s each — slow but clean), real PNGs.
- Agent-loop `image_generate` (tool-driven via `/agents/run`): fired + PNG + coherent text.
- Context pass-off: follow-up turn recalled the image coherently, no spurious re-gen.
- Existing persisted config (carrying the old `maxToolCalls`) loads cleanly → back-compat.

Residuals unchanged and still bound "production quality" (see CONVERGED HONEST STATE):
one-turn chained gen→edit is non-deterministic and sustained back-to-back churn can crash
in MLX `CommandEncoder` — both need a vmlx/residency-level change, NOT more osaurus drains.
Reliable product paths remain: direct `/images` API + separate-turn editing.

## ⛔ CRITICAL crash found + fixed (stress-proving now): image→model-load concurrent-GPU
Stress testing surfaced a **real SIGABRT crash** — `MTLReleaseAssertionFailure` in
`-[IOGPUMetalCommandBuffer setCurrentCommandEncoder:]` — on the **image→model-load**
handoff (e.g. image_edit completes → chat model reloads to summarize). The exclusive
image MetalGate was released (`ImageGenerationService.exitImageGeneration`) **before**
vMLXFlux's async Metal tail (VAE decode/teardown) drained, so the next exclusive
producer (`enterModelLoad`) raced the in-flight command buffer.

This is the **reverse direction** of the BatchEngine drain shipped in vmlx PR #82
(which fixed chat→image). **Fix applied + STRESS-PROVEN** (osaurus, ImageGenerationService):
the same `MLXCacheIOLock`/`Stream.gpu.synchronize` drain barrier right before
`exitImageGeneration`, covering success/cancel/error paths (commit on feat branch).

**Proof:** post-fix stress of 6 back-to-back image→model-reload handoffs (the exact
crash trigger) → **6/6 process survived, 0 crashes, 6/6 PNGs, all responses coherent**,
no new crash report. Pre-fix the same handoff reliably SIGABRT'd. The drain lives in the
**shared** image-job wrapper, so image_generate AND image_edit both go through it (build
closure differs; enter/drain/exit identical).

**EDIT-PATH CONFIRMED:** direct `/images/edits` (real Qwen-Image-Edit, produced an edited
PNG) immediately followed by a chat model-load — the EXACT original crash scenario — →
process ALIVE, chat clean ("Hello."), no new crash report. Crash closed on both gen and
edit handoffs. ✅ **#89 fixed + proven.**

Also discovered: the **direct `/images/edits` + `/images/generations` HTTP API works
reliably** (accepts `file://` / data-url / base64 sources) and bypasses model
tool-selection flakiness — a robust path for image edit independent of how well the chat
model calls the tool.

NOTE: earlier "app DOWN" reads via `/health` were false (the endpoint blocks during GPU
teardown); the REAL crash was confirmed via `pgrep` + the macOS crash report
(`osaurus-2026-06-22-203544.ips`).

## TL;DR
- The **dangerous** bug (concurrent-GPU crash on chat→image handoff) is **fixed + shipped**
  (vmlx PR #82, merged to canonical, osaurus repinned + rebuilt + verified).
- **Single** image_generate / image_edit / spawn / local_delegate + context pass-off:
  **proven working** in isolation across many models.
- **Repeated** image ops (many runs back-to-back): **FIXED + PROVEN** — the failures were
  the #89 GPU crash (image→model-load drain), now closed; 6/6 handoffs survive.
- **Chained gen→edit in ONE turn**: **PARTIAL / non-deterministic** (superseded — see
  "CONVERGED HONEST STATE" at the bottom). The tool-prompt re-injection fixes made the edit
  CHAIN correctly when the flow doesn't hang; but the image→model-reload→generation handoff
  has a pre-existing non-deterministic STALL (sometimes 1 gen + hang, no edit). Reliable
  edit = direct API or a separate turn.
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
| **Repeated image load (back-to-back)** | 🟢 Ready (post-fix) | 6/6 handoffs, 0 crashes after #89 drain fix |
| image_edit (direct API or model-driven) | 🟢 Ready | direct /images/edits → real edited PNG; handoff crash-free |
| **Chained gen→edit (ONE turn, model-driven)** | 🟡 Non-deterministic | edit chains when the flow doesn't hang (3 re-injection fixes #88), but a pre-existing image→reload→generation STALL fires intermittently (1 gen, no edit, ~450s). Reliable = direct API / separate turn. See CONVERGED HONEST STATE |
| **Sustained back-to-back chained churn** | 🔴 Crashes | MLX `CommandEncoder` race under pathological rapid churn (beyond real usage); osaurus drains didn't fix, comprehensive attempt deadlocked (#92 reverted) |
| Multi-turn DB-persisted image path | ⚪ Unverified | not tested across separate UI turns (direct image_edit with explicit path works) |
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

---

## CONVERGED HONEST STATE (after extensive GPU/chained-edit hardening)

### Solid + proven (real usage)
- Single `image_generate` (6/8 driver models), single `image_edit` (direct API or explicit
  source path), `spawn`, `local_delegate`, context pass-off — all work.
- Two separate tools with per-tool default models settable in Settings; direct
  `/images/{generations,edits}` API falls back to those defaults (model now optional).
- Concurrent-GPU crash fixes for the SINGLE handoffs: chat→image (vmlx #82, merged) and
  image→model-load (#89) — proven (6/6 + direct edit→reload). #91 (model-load drain) kept.

### Reverted (made things worse)
- #92 comprehensive GPU-drain fix: its new MetalGate `modelUnload` lane **deadlocked** with
  the `agent_single_residency` handoff (image job holds the image gate, then triggers the
  chat-model unload which waits on that gate → 350s stall). Reverted.

### Remaining residuals (NOT fixed by drain whack-a-mole — need a different approach)
1. **One-turn chained gen→edit is non-deterministic.** After `image_generate` + the chat-model
   reload, gemma's iteration-2 generation SOMETIMES hangs (1 gen, no edit, ~450s timeout) and
   SOMETIMES fires the edit. This is a pre-existing hang in the image→reload→generation
   handoff, present before any of this session's GPU work; the nudge fixes only improved the
   tool-selection for the cases that DON'T hang. Drains/reverts did not change it.
2. **Sustained back-to-back churn crashes.** 4 chained runs with no settling → EXC_BAD_ACCESS
   in `mlx::core::metal::CommandEncoder` creation (MLX command-buffer race under pathological
   rapid model churn). Beyond real usage.

### Reliable paths (recommend for product)
- Image **edit** via the direct `/images/edits` API or as a **separate turn** with an explicit
  path — both proven reliable, bypass the non-deterministic one-turn handoff.
- One chained request at a time (avoid rapid back-to-back churn).

### Honest recommendation
The one-turn-chained-edit hang + the churn crash are NOT solvable by more osaurus-side
MetalGate drains (this session proved that — multiple drain rounds either didn't help or
deadlocked). They need a different approach: a vmlx/MLX-level look at the image→model-reload
generation hang, and/or a residency-handoff redesign (e.g. keep the chat model resident
during the image job instead of unload/reload, or a global image-job serialize-with-settle).
That is a design decision for the next session, not autonomous drain iteration.
