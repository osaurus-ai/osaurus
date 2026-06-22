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

## Matrix status (live, dev-built app) — loop run 2026-06-21

All proven via real HTTP on :1337 with explicit artifacts (resident-poller timelines,
app-log/NSLog values, PNG bytes, SSE final text).

| | Item | Status |
|---|---|---|
| A | `image_generate` → unload orch → PNG → reload orch → path returned | ✅ PASS (resident qwen3→[]→qwen3; real 512² PNG; final text states the real saved path) |
| A | `image_edit` round-trip | ✅ PASS — real 1024² edited PNG distinct from source |
| B | toggle enforcement (persisted-config-on-load) | ✅ PASS — `agentDelegationEnabled=false` → 0 image_generate tool-calls + model says NO_IMAGE_TOOL; baseline → tool-call + new PNG. (live raw-file edits need restart: `snapshot()` caches; UI `save()` is live) |
| C | RAM preflight — no-false-refuse @ ample RAM | ✅ PASS (C3 instrumented: req=36GB needed=50GB avail=98GB → refuse=false, job proceeds) |
| C | RAM refuse-**before**-evict @ tight | ✅ PASS (C6 forced: needed=263GB>avail → refuse=true, orchestrator STAYS resident, no PNG, graceful "insufficient RAM … ~245GB needed / ~100GB avail" returned) |
| D | text `local_delegate` context passthrough + return | ✅ PASS — sentinel `BANANA_PHONE_42` round-trips back into orchestrator final answer |
| E | context passthrough + finished-loop-returns-to-main | ✅ PASS — covered by A (real path) + D/F (sentinels) |
| F | `spawn` (persona) returns subagent digest to orchestrator | ✅ PASS — spawn(Sparky) loads Sparky's own model (qwen2.5-3b, distinct from orch), runs, sentinel `ZEBRA_TOKEN_99` returned |
| F | `spawn` cloud-orchestrator job (no unload) | 🟡 code-verified (empty residency lease when nothing resident); NOT live — no remote provider/API key configured in the test instance |
| G | cancel mid-job restores orchestrator | ✅ PASS — abort connection ~8s in; resident stayed `[]` ~48s then `qwen3` restored. (note: client-disconnect lets the in-flight image job finish, then restores ~50s — no stranding, doesn't waste GPU work; instant-abort is a possible future refinement) |
| H | 6-turn coherence w/ image+delegate interleaved | ✅ PASS — memory recall across turns (Eric/teal), image+1, delegate token relayed, no looping/degeneration, coherent final summary |

---

## Gap triage (loop run 2026-06-21 — re-verified live, no assumptions)
- **Concurrent chat during an image job** — ✅ NOT A BUG. Re-tested: a chat sent
  mid-image-job **queues correctly** behind the exclusive MetalGate image owner and
  then succeeds (HTTP 200, correct content) once the job releases — proven with a
  chat timeout > the image job (47.5s, returned "PINEAPPLE"). The earlier "empty/HTTP
  000" was just the client timing out before the ~60s job finished. No fake fix made.
  Possible future nicety: SSE keep-alive or a fast 503 "image in progress" so short
  client timeouts don't expire — but the serialization itself is correct.
- **MCP-direct `/mcp/call image_generate`** — ✅ NOT A BUG (stale). Re-tested: HTTP 200,
  full coordinator handoff (unload qwen3 → load FLUX → gen 1–20 → restore qwen3), real
  PNG. The old "no model loaded — call FluxEngine.load first" no longer reproduces;
  the MCP path now routes through `NativeImageJobCoordinator`.
- **`capabilities_discover` embedding SIGSEGV** (concurrent-GPU resource race, #34/#60
  family) — STILL OPEN; harden alongside #34 (the only remaining real gap).

## Per-agent delegation redesign (Eric 2026-06-21) — ✅ DONE (commit 34a3ed71)
Spawn/delegation is now a **per-agent feature toggle** ("Spawn & Delegation" in the
agent editor's Features section, next to Code Execution; custom agents only), mirroring
`computerUseEnabled`. The global `AgentDelegationConfiguration` still supplies DEFAULTS
(models, load policy, RAM safety, permissions, budgets); the per-agent flag is the enable
(ANDs with the global gates). **Live-proven:** agent flag OFF → 0 `image_generate`
tool-calls + no image; flag ON → tool-call + real PNG.
⚠️ Needs Eric's visual check: the "Spawn & Delegation" toggle render in the agent editor
Features section (UI not headlessly verifiable).
Implemented (mirror of the `computer_use` per-agent gate):
1. `AgentSettings.spawnDelegationEnabled: Bool = false` (+ init param + Codable
   `decodeIfPresent ?? false` + encode) — Agent.swift.
2. `AgentConfigSnapshot.spawnDelegationEnabled` (mirror `computerUseEnabled` at the
   field / init / `from(caps:)` sites).
3. `SystemPromptComposer.resolveTools`: after the `computer_use` strip (line ~1973),
   add `if !snapshot.spawnDelegationEnabled { byName.removeValue("spawn"/"local_delegate"/
   "image_generate"/"image_edit") }` — authoritative per-agent gate (AND with the global).
4. `HTTPHandler.enrichWithAgentContext`: gate the delegation-spec injection on the
   agent's `spawnDelegationEnabled` too (not just the global flags).
5. `AgentsView`: add a `featureGroup("Spawn & Delegation") { featureToggleRow(isOn:
   $spawnDelegationEnabled) }` adjacent to Code Execution + `@State` + load (≈5064) +
   debouncedSave wiring. Custom-agents pattern like Computer Use.
The existing global `AgentDelegationConfiguration` stays for DEFAULTS (model pickers,
load policy, RAM safety, permissions, budgets); the per-agent flag becomes the enable.
- **UI surfaces — built (compile-verified, awaiting visual live-check):**
  - **Manual image gen/edit panel** (`ImageGenerationPanelView`): prompt +
    negative + size + seed (+ source-image picker for edit) → live progress
    (loadingModel / step bar) → result image with Reveal / Save-As. Driven
    directly by `ImageGenerationService` (manual panels keep their own loading
    behavior — no chat handoff). Launched from `ImageModelDetailView`'s footer
    for ready `imageGen`/`imageEdit` bundles (the Models → Images tab).
  - **Spawn usage/info + settings**: now its own **sidebar page** (`SpawnSettingsView`,
    ManagementTab `.spawn`, wand.and.stars icon, sits next to Computer Use) — promoted
    out of the long Settings scroll where it was undiscoverable. The page wraps the same
    `AgentDelegationSettingsSection` (How It Works flow + default-model pickers + load
    policy + Memory Safety + permissions + budgets). Still also rendered inside Settings;
    both bind the one `AgentDelegationConfigurationStore` and listen on
    `.agentDelegationConfigurationChanged`, so they are **two-way synced**.
  - **RAM-Safety ⇄ Spawn sync**: both render the same single
    `AgentDelegationConfiguration` ("Memory Safety" subsection), so they are
    synced by construction (osaurus settings are sections, not separate tabs).
- **Still TODO (UI):** visual live-check of the panel in the dev app (UI can't be
  headless-verified); optional reachability from the chat composer / image tab toolbar.

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
- `47fabf0a` — UI surfaces: `ImageGenerationPanelView` (manual gen/edit panel)
  launched from `ImageModelDetailView`; spawn "How It Works" usage/info subsection in
  `AgentDelegationSettingsSection`. Compile-verified Release; pushed.

## Update 2026-06-21 — fresh-binary regression proof (panel engine path)
After the UI commit, restarted the dev app onto the freshly-built Release binary
(`:1337`, test root `/tmp/osaurus-spawn-test`) and drove `POST /v1/images/generations`
(FLUX.1-schnell-4bit, 512², n=1) — the EXACT `ImageGenerationService.generate` call the
new panel makes. HTTP 200 in 18s → real 512×512 8-bit RGB PNG (218 KB). So the new build
did not regress the engine path; both panel modes are covered (gen now on fresh binary,
edit earlier this session). Remaining for the panel: Eric's visual check of the SwiftUI
sheet (renders / controls / progress / Save-As) — the one thing not headlessly verifiable.

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

## Update 2026-06-21 — image_edit live-proven; MCP-direct image gap
Matrix A `image_edit`: PASS. Orchestrator (qwen3-4b, forced tool_choice, source path
given in the prompt) → `image_edit` → coordinator loaded Qwen-Image-Edit → produced a
real 1024² RGB PNG distinct from the source. So both `image_generate` and `image_edit`
fire end-to-end through the orchestrator → coordinator → vMLXFlux handoff.
Minor gap: a DIRECT `/mcp/call` to `image_generate`/`image_edit` errors "no model
loaded — call FluxEngine.load first" (the MCP bridge bypasses the coordinator that
owns the model load/handoff). MCP-direct image tools need a load step or to route
through the coordinator; the chat/agent-run tool path is correct.
