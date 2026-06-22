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

## UI automation verification (loop 2026-06-21)
Established a working macOS UI-automation harness for the dev app (no MCP/Playwright):
**System Events** (clicks + accessibility-tree text reads), **screencapture** (visual),
and a custom **Swift scroll helper** (`/tmp/scroll.swift` → CGEvent scroll, needed for
the sidebar). Prereq: quit the conflicting production `/Applications/osaurus.app` so the
process name + `osaurus://` aren't ambiguous. Verified by screenshot + accessibility text:
- **Spawn sidebar tab** renders (wand.and.stars icon, between Computer Use and Privacy).
- **Spawn & Delegation page** (`SpawnSettingsView`) renders fully: header, How It Works
  (4 bullets), Availability, Cloud Cost Saver (Local Orchestrator Handoff ON + delegate
  picker), Image Jobs (Enable Chat Image Jobs ON + Default Image Generator picker).
- **Spawn settings text** read verbatim from the a11y tree — matches the source strings.
- **Agents** and **Models** (On Device / Catalog / Images sub-tabs) tabs navigated.
**Codex computer-use** (the proper tool — `codex exec` + bundled `computer-use` plugin,
model gpt-5.3-codex-spark) then drove the two surfaces my AppleScript couldn't reach, and
PASSED both:
- **Per-agent toggle (agent editor → Sparky → Features):** title `Spawn & Delegation`,
  description read verbatim ("Let this agent spawn helper jobs and sub-agents. Give the
  agent the spawn / local_delegate / image_generate / image_edit tools …"), state ON.
- **Image panel (Models → Images → FLUX.1 Schnell → Generate):** panel opened with Prompt,
  Negative prompt (optional), Size (512² / 1,024²), Seed (random), Generate, Close.
So ALL FOUR UI surfaces are render-verified. (Lesson: use Codex computer-use for GUI
automation, not hand-rolled AppleScript — it reads the a11y tree + vision and navigates
cards reliably.)
A **live functional** pass (toggle ON→chat spawns image w/ load-unload handoff; toggle
OFF→blocked; panel actually generates) is running via Codex computer-use.

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

## Main-chat spawn — WORKING (Codex live, 2026-06-21)
Piece #1 (commit, surfacing) landed: the **main/default local chat now calls `image_generate`
and renders the image INLINE**. Codex computer-use PASS on the default chat:
- main chat invoked `image_generate {"prompt":"a single red apple..."}`,
- FLUX ran to completion (`[flux] image shape=[1,3,1024,1024]`, new PNG),
- the result rendered as a **first-class inline image card** in the chat ("Native image
  generation result from FLUX.1-schnell-mflux-4bit", Open-in-Finder action).
So the target flow (local main chat → spawn image → tool shown → bg gen → image inline) works.
Piece #3 (inline render via `processNativeImageToolResult`) was already wired — confirmed live.

### Remaining
- **Intermittent mid-gen cancellation (reliability).** On some runs the chat-triggered image
  job is cancelled (FLUX stops at `step0`) and the tool returns `"image generation finished
  without a result"`, so the chat model then refuses. Root: image cancellation is **soft** —
  the drive suppresses the result and finishes `.cancelled` when the consuming/parent task is
  cancelled; the native-chat residency handoff (unloading the chat model mid-turn) can trip
  that parent cancel as a self-inflicted race (agent-run's turn-task survives it). Fix
  direction: decouple the chat-triggered image job from incidental parent-task cancellation
  (honor only explicit `cancelledJobIDs`), and/or yield produced images even on a soft cancel.
- **Piece #2 — first-use permission + model picker** (still to build): on first spawn, show the
  standard Yes/No/Always tool-permission prompt extended with a spawn-model picker; persist the
  choice to `AgentDelegationConfiguration`; the Spawn settings page reflects it.

## Default-off + coherence (Eric 2026-06-21)
- **Default OFF / invisible at baseline** — confirmed: `AgentDelegationConfiguration.agentDelegationEnabled` ships `false`; every family gate (`imageDelegationActive`, `anyAgentSpawnable`, `textDelegationToolAvailable`) and the system-prompt image-capability hint are gated on it, and the piece-#1 main-chat surfacing is too. So until the user flips the Agent Delegation toggle there is zero trace — no tools, no hints, no prompts. (Test config forces it on for testing only.)
- **Coherence across the unload/reload handoff — Codex live PASS.** 5-turn native default chat with an image spawn interleaved (turn 2 unloads then reloads the chat model): memory survived the reload (turn 3 recalled "Eric"/"7"), and turns 3–5 were coherent with NO looping, NO incoherency, and NO leaked tags/special tokens. The KV-rebuild-from-transcript handoff is seamless for the conversation.
- **Persona refusal fix.** That same run also showed the Default "Osaurus configuration agent" persona can intermittently refuse image requests ("I'm text-only / no image tool") even though `image_generate` is in its schema. Added `SystemPromptTemplates.imageGenerationGuidance` — an authoritative, schema-gated directive (only renders when `image_generate` actually resolved) telling the model it CAN/SHOULD call the tool and must not claim it can't. Mirrors the `computerUseGuidance` pattern (KV-cache stable).

## Objective stress-test campaign (Eric 2026-06-22) — 4 bugs found via SQLite transcript mining

Method: instead of trusting the (unreliable) Codex GUI observations, mined the chat-history SQLite directly — every tool-call arg, tool result, assistant content, and `thinking` field is ground truth. Detected refusals, loops (repeated n-grams), tag/channel-marker leaks, prompt-passing fidelity, and image pass-off across all image/spawn sessions. Cross-checked with a controlled Codex matrix (fresh chats, pinned default model) on both a corrupt and a valid config.

**BUG A — `tool/` prefix namespace collision (default-agent refusals).** The capabilities manifest lists deferred tools to the model as `tool/<name>` (`SystemPromptTemplates:491`). gemma-4 sometimes copies that prefix verbatim and calls `tool/image_generate` → `tool_not_found`; the default agent then can't self-heal (`capabilities_load` is gated off for it) and gives up with a persona refusal. FIX: `ToolRegistry.execute` now strips a `tool/` prefix and re-resolves when the bare name is registered (mirrors `CapabilityTools` precedent). Proven from transcript (session 20:48).

**BUG B — "image generation finished without a result."** Pre-existing cancellation cascade; the 3 failing sessions (21:16–21:30) all predate the `Task.detached` hardening commit `b2fe2cdc` (21:52). Confirmed resolved by timestamp; post-fix sessions pass off cleanly.

**BUG C — gemma-4 degenerates into a `<|channel>thought` loop after the image handoff.** Objective: a post-image turn produced 97KB of looped channel-markers (empty user-visible text). Root contributor PROVEN: the native image tool result fed back to the model was 9,028 bytes including a 27-entry `progress` telemetry array (queued/running events × every step) — pure noise the model never needs. FIX: dropped `progress` from `NativeImageJobCoordinator.toolPayload` (the bridge reads only `job_id`/`images`; the UI gets progress via NotificationCenter). Result size 9028 → **762 bytes**; channel-loops in the valid-config re-run: **0**.

**BUG D — one invalid permission value silently disables the ENTIRE delegation config (the real root cause of the intermittency).** `AgentDelegationConfiguration.init(from:)` decoded `permissionDefaults` (and the load/sharing-policy enums) with `decodeIfPresent`, which THROWS on a single invalid enum raw value → the whole config init throws → silent fallback to all-defaults (`agentDelegationEnabled=false`) → `image_generate` never surfaces → model refuses/degenerates. Surfaced when a hand-edited `imageGenerate:"alwaysAllow"` (camelCase) failed to match the enum's `"always_allow"`. The fragility is general (any rename/migration/hand-edit). FIX: lenient per-field `AgentDelegationPermissionDefaults.init(from:)` + `(try?)` on every enum field in the main init — invalid/absent → safe default, never nuke the config. Proven: config-load errors 14+ → **0**.

### Valid-config re-run (objective, 6 fresh default-agent sessions)
- tool fired: **every session** (was 0 under the corrupt config) · refusals: **0** (was 3) · channel-loops: **0** (was 1) · img-result size: **762 B** (was 9028).
- Memory across the unload/reload handoff preserved (Case 3c: "Your name is Eric and your favorite number is 7").
- Sequential images, resume-normal-chat-after-image, and image+describe all coherent — no looping, no tag leaks.
- Prompt-passing fidelity verified clean across all fired sessions (e.g. "a single red apple on a white background", "a blue car") — no corruption/context-bleed into the spawned model.
- 1/6 transient: the cold-start first request hit "Stopped before completing" (retryable) — UI turn-cancel path (`ChatView.markUnfinishedToolCallsInterrupted`), a Codex-interaction artifact, not a feature defect; the 5 subsequent requests succeeded.

## All-paths coherence sweep (Eric /loop 2026-06-22) — image_edit + text-spawn + spawn

Objective SQLite verification (default agent, gemma-4-12b) of the remaining delegation paths, emphasis on generated-output coherence + context pass-off across the model load/unload handoffs. Note: the Codex GUI cancels slow heavy-model turns (starting a new chat / impatience mid-generation aborts the turn → "Stopped before completing", retryable — a test artifact, not a defect). Fixed by patient single-flow Codex prompts (wait up to 2-3 min, never click/navigate mid-generation).

- **local_delegate (text spawn) — PASS.** "write a haiku via your local delegate" → qwen3-4b returned 3 distinct coherent lines into chat; then "what's my favorite color + city?" correctly recalled "teal / Denver" — context preserved across the delegate model load/unload. 0 loops, 0 tag/channel leaks. Result lean (397 B).
- **image_edit — PASS (two handoffs).** generate banana (FLUX) → edit to blue background (Qwen-Image-Edit-mflux-q4) → "what did you change?" → "I changed the background color from white to bright blue while preserving the yellow banana." Edited image rendered inline; context survived BOTH the gen and edit handoffs. 0 loops, 0 leaks. Edit result lean (669 B — the BUG C progress-slim covers image_edit too).
- **spawn — PASS.** spawn(Sparky) → handoff:true → coherent agent intro. 0 leaks.

Net: all four delegation tools (image_generate, image_edit, local_delegate, spawn) produce coherent generated output with NO looping, NO incoherency, NO tag/channel leaks, and clean context pass-off across every handoff.

**BUG E — agent-run vs native-chat delegation surface split (fix landed).** `HTTPHandler.enrichWithAgentContext` gated delegation-spec injection purely on the per-agent `spawnDelegationEnabled` (false for the default agent), while native chat surfaces delegation tools to the default agent on the GLOBAL `agentDelegationEnabled` (piece #1). So `/agents/default/run` silently lacked the delegation tools even with delegation globally on — a real HTTP-API vs chat-UI behaviour split. Fixed to mirror native chat (default agent → global flag; custom agent → per-agent flag). Native-chat non-regression proven (the image_edit/text-spawn/spawn runs above all ran on the BUG E binary). NOTE: full HTTP E2E of the default-agent injection is currently blocked by a separate agent-run context-window overflow on the default (config) agent — tracked as a follow-up; native chat is unaffected.

## Toggle-combination matrix (Eric /loop 2026-06-22) — all gates isolate, no clashes

Deterministic sweep: for each config, restart and read the resolved default-agent delegation-tool set at native resolveTools time (temporary probe, since removed). Config loaded cleanly every time (errs=0 — BUG D lenient decode holds).

| Config | global | image | text | spawnable | Resolved delegation tools |
|--------|--------|-------|------|-----------|---------------------------|
| all-on     | on  | on  | on  | [Sparky,Echo] | image_generate, image_edit, local_delegate, spawn |
| image-off  | on  | OFF | on  | [Sparky,Echo] | local_delegate, spawn |
| text-off   | on  | on  | OFF | [Sparky,Echo] | image_generate, image_edit, spawn |
| spawn-off  | on  | on  | on  | []            | image_generate, image_edit, local_delegate |
| global-off | OFF | on  | on  | [Sparky,Echo] | (none) |

Each gate removes exactly its own tool family and nothing else; `global-off` is the master kill (all delegation tools gone — also the live-proven root of the BUG D intermittency); no toggle interferes with another. The feature is default-off and invisible at baseline, and every combination behaves as specified.

## Known limitation (NOT introduced by this branch): default-agent /agents/{id}/run overflow

`POST /agents/default/run` returns `.overBudget` ("Context window cannot fit this request even after compaction") even for a trivial "hi". Verified PRE-EXISTING: reproduces on the clean binary independent of the BUG E change, and the "hi" overflow was observed before BUG E was even built. The native chat path for the default agent is UNAFFECTED (all the image/edit/delegate/spawn coherence proofs above ran through native chat). Root cause not yet fully verified — likely the heavyweight agent-run enrichment (default config-agent persona + manifest) against the conservative memory-safety window cap (server-runtime memorySafety.slider=2). Tracked as a separate follow-up; deliberately NOT speculatively fixed in this feature branch (would need dedicated investigation per the verify-before-fixing rule). It only gates the HTTP-API E2E of BUG E's default-agent injection, not the chat feature.

## BUG F — default-agent agent-run model not resolving → spurious context overflow (fixed)

The earlier "known limitation" (#74) is now root-caused and fixed. Verified at runtime via instrumentation:
`[AGENTBUDGET] model=default window=4096 sysChars=9937 toolTokens=1433 effBudget=3481 totalReserved=4787 → historyBudget=0 → .overBudget`.

Root cause: in `/agents/{id}/run`, when `req.model == "default"` and `AgentManager.effectiveModel(for: agentId)` returns nil (the default agent has no pinned model — true on a fresh install, and in this test env), `model` stayed the literal string `"default"`. `AgentLoopBudget.resolveContextWindow("default")` finds no ModelInfo for "default" and collapses the window to the tiny chat-config fallback (4096). The default agent's own system prompt (~2.5k tok) + tools (1433) + response reservation then exceed the 0.85·4096 effective budget, tripping `.overBudget` on even a one-word "hi". Largely a test-config artifact (production users have a configured default model), but a real robustness gap.

Fix: when `effectiveModel` is nil, fall back to the currently-loaded model (`ModelRuntime.cachedModelSummaries().first{ $0.isCurrent }`) — the same model /health reports — instead of the literal "default". Verified post-fix: `model=osaurusai--gemma-4-12b-it-qat-mxfp4 window=128000 effBudget=108800 historyBudget=100787` and the agent-run generated a coherent response (no overflow). This also unblocks the HTTP E2E of BUG E's default-agent delegation injection.

Minor adjacent note (not fixed, harmless): the resolved window came back 128000 (the fallbackContextWindow) rather than gemma's real 262144, i.e. `ModelInfo.load` didn't resolve the lowercased model id to the on-disk dir (case mismatch). Both values are far larger than any prompt here, so it has no functional impact on this path; logged for a future ModelInfo id-normalisation pass.
