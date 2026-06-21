# Local Subagent Orchestration — Engineering Status & Design
Branch: `feat/image-generation-vmlxflux`. Last updated 2026-06-21.

- **Product requirements (the vision/spec):** `docs/SPAWN_IMAGEGEN_REQUIREMENTS.md`.
- This file is the **engineering log**: current state, architecture, live-matrix
  status, known gaps, and build history. The "Current state" + "Matrix status"
  sections below are authoritative — earlier dated claims have been folded in.

---

## ✅ Current state (2026-06-21)

Spawn is a **tool** the orchestrator chat (local OR cloud) calls to run a bounded
job: image gen/edit (vMLXFlux) or a local text/coder sub-agent. Working + live-proven:

- **Image-job E2E (PASS):** orchestrator → `image_generate` → unload resident chat
  model → FLUX runs → **real PNG saved** → chat model reloads + is usable after.
  Proven 512² + 1024² (flux-schnell).
- **Delegation tools reach the orchestrator:** `enrichWithAgentContext` now injects
  the active delegation tool **schemas** (`image_generate`/`image_edit`/
  `local_delegate`/`spawn`) into the agent-run surface (commit `bb3ccb22`). Root
  cause of the earlier "tool never fired": `composeChatContext` surfaced image tools
  only as a prompt-hint capability, not a callable schema.
- **RAM-safety refuse-before-evict preflight** across image + text/spawn handoffs
  (`ChatResidencyHandoff.memoryPreflight`) + a "Memory Safety" settings toggle
  (`ramSafetyPreflightEnabled`, default on). Passed live (no false-refuse).
- **Image-model scan** finds `~/models/image` with no env/bookmark
  (`ImageGenerationService.imageModelsRoot` picks the first populated candidate).
- **Settings:** default text-delegate / image-gen / image-edit model pickers; persist
  to `agent-delegation.json`, survive restart.
- **Text-subagent matrix (run 2):** spawn inline / permission-deny / re-entrancy /
  cross-handoff coherence — all PASS. Residency-based handoff fixed the
  concurrent-GPU SIGABRT (`7cf90749`).

---

## Architecture

```
Chat turn (orchestrator: local OR cloud)
  └─ orchestrator tool call: local_delegate | spawn | image_generate | image_edit
       └─ <Job>Coordinator  (owns model handoff + RAM-safety preflight + permission)
            ├─ ChatResidencyHandoff
            │     local orchestrator → memoryPreflight → unload orchestrator
            │                        → run job → reload orchestrator
            │     cloud orchestrator → no unload (nothing resident)
            ├─ subagent runner
            │     text   → bounded AgentToolLoop on the local subagent model
            │     image  → ImageGenerationService → vMLXFlux  (MetalGate exclusive)
            └─ compact structured result → back into the orchestrator turn
```

### Orchestrator handoff rules
- **Local orchestrator:** RAM preflight → unload the user-assigned orchestrator model
  → load the subagent/image model → run → unload it → reload the orchestrator →
  continue the turn. Single-residency (MetalGate exclusive load fixes the #34 SIGABRT).
- **Cloud/API orchestrator:** no unload/reload; the local subagent still runs and
  returns a compact result. Preflight + permission still apply to the subagent load.
- **User-toggleable:** orchestrator model, per-job subagent models, the unload/reload
  handoff, and the RAM-safety preflight — all in Agent Delegation settings.

---

## Matrix status (live, dev-built app)

| | Item | Status |
|---|---|---|
| A | `image_generate` → handoff → PNG | ✅ PASS |
| A | `image_edit` round-trip | ⬜ TODO (needs a source-image path the model supplies) |
| A | cancel/failure mid-job restores orchestrator | ⬜ TODO (code path present) |
| A | cloud-orchestrator image job (no unload) | ⬜ TODO |
| B | `local_delegate` / `spawn` coder live run | 🟡 schemas injected; text run 2 passed; image-of-this not re-run |
| C | unload→image→reload; chat usable after | ✅ PASS (text coherence proven run 2; 6-turn interleave TODO) |
| D | ask/deny/always live; toggle adds/removes tool; persist; RAM↔Spawn tab sync | 🟡 deny + persist PASS; ask/always + tab-sync TODO |
| E | refuse-before-evict actually rejects (tight case) | ⬜ TODO (preflight built + passes ample-RAM) |
| F | cloud + local orchestrators; coder model; z-image/flux/qwen-image/edit/ideogram | 🟡 qwen3-4b orch + flux-schnell proven |

---

## Known gaps / follow-ups
- **Concurrent chat during an image job** returns empty instead of queueing behind the
  single-residency job (should `waitForChatIdle` or return a "busy" envelope).
- **GAP 5:** `ChatResidencyHandoff.restore` is best-effort `try?` — surface a reload
  failure instead of silently leaving the orchestrator unloaded.
- **`capabilities_discover` embedding SIGSEGV** (concurrent-GPU resource race, #34
  family) — open; harden alongside #34.
- **UI surfaces still to build** (per requirements doc): dedicated image gen/edit
  panel; spawn settings + usage + info page; RAM-Safety ⇄ Spawn synced tabs.

---

## Build log
- `e85bd541` (+earlier) — source-wiring: ImageGenerationService, NativeImageJobCoordinator,
  NativeImageJobModelResolver (strict), NativeImageTools, LocalTextDelegateTool, ToolRegistry
  gating, AgentDelegationConfiguration + tests.
- `7cf90749` — residency-based handoff (gate on actual GPU residency, not orchestrator name);
  fixes the concurrent-residency SIGABRT on `/agents/{id}/run`.
- `929a274a` — text-subagent matrix run 2 recorded (all pass).
- `f9526668` (2026-06-21) — image scan finds `~/models/image`; RAM preflight (image path);
  `ramSafetyPreflightEnabled` config + "Memory Safety" settings toggle.
- `28c6b910` — RAM preflight on the text/spawn handoff (`estimatedChatModelBytes`).
- `bb3ccb22` — inject active delegation tool schemas into the agent-run surface
  (the image-job trigger fix). Agent-run-only; chat surface unchanged.
- `140d0398` — matrix A image handoff verified (unload→image→reload).

---

## DONE — source-wired (reference)
- **ImageGenerationService** owns the only `vMLXFlux` import; generate/edit/upscale via
  native events; HTTP-proven for Z-Image Turbo, FLUX.1 Schnell, Qwen-Image,
  Qwen-Image-Edit, Ideogram; held in MetalGate's exclusive image lane.
- **NativeImageJobCoordinator** — model resolved before unload, RAM preflight, chat
  unload if resident, run image, unload image, restore orchestrator; progress events.
- **NativeImageJobModelResolver** (strict) — rejects stale/incomplete/wrong-kind image
  models before any chat-model eviction.
- **NativeImageTools** (`image_generate`/`image_edit`), **LocalTextDelegateTool**
  (`local_delegate`), **SpawnTool** (`spawn`) — model resolved + RAM preflight before
  the permission ask / unload.
- **AgentDelegationConfiguration** — load policies, per-job permission policies
  (ask/deny/always), default model ids, `ramSafetyPreflightEnabled`; persisted via
  `AgentDelegationConfigurationStore` (`agent-delegation.json`).
- **Tests:** NativeImageJobCoordinatorTests, AgentDelegationToolAvailabilityTests,
  NativeImageToolArtifactBridgeTests, config-store tests.

## Update 2026-06-21 — GAP 5 fixed
`ChatResidencyHandoff.restoreBestEffort` logs a reload failure instead of swallowing
it (`try?`); wired into SpawnTool + LocalTextDelegateTool restore paths. A
left-unloaded orchestrator after a failed restore is now diagnosable.
