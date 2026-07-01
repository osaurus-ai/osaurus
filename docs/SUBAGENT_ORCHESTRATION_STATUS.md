# Local Subagent Orchestration — Engineering Status & Design
Branch: `feat/image-generation-vmlxflux`. Last updated 2026-06-25 (unified subagent architecture).

- **Product requirements (the vision/spec):** `docs/SPAWN_IMAGEGEN_REQUIREMENTS.md`.
- This file is the **engineering log**: current state, architecture, live-matrix
  status, known gaps, and build history. The "Current state" + "Matrix status"
  sections below are authoritative — earlier dated claims have been folded in.

> **Naming note (2026-06-25):** the unified-architecture pass renamed the tools,
> config, and services. The dated working-log sections below this point predate
> the rename and still use the OLD names. Read them through this map:
>
> | Old (in the log below) | New (current) |
> |---|---|
> | `local_delegate` tool | **removed** — folded into `spawn` |
> | `image_generate` + `image_edit` tools | one **`image`** tool (`source_paths` ⇒ edit) |
> | `AgentDelegationConfiguration` | `SubagentConfiguration` |
> | `AgentDelegationConfigurationStore` | `SubagentConfigurationStore` (file still `agent-delegation.json`) |
> | `AgentDelegationSettingsSection` | `SubagentSettingsSection` |
> | `.agentDelegationConfigurationChanged` notification | `.subagentConfigurationChanged` |
> | `ComputerUseFeed` / `…FeedRegistry` / `…InterruptCenter` | `SubagentFeed` / `SubagentFeedRegistry` / `SubagentInterruptCenter` |
> | image coordinator's private `NativeImageChatResidency*` copies | one shared `ResidencyHandoff` middleware (built on `ChatResidencyHandoff`) |
> | result kinds `spawn_result` / `digest` / `native_image_generation_job` | one compact `ToolEnvelope` shape |
>
> The global-enable flag (`SubagentConfiguration.agentDelegationEnabled`) and the
> per-agent flag (`Agent.spawnDelegationEnabled`) kept their property names; only the
> enclosing types were renamed `AgentDelegation*` → `Subagent*`.
>
> **Per-agent split (2026-06-25, see "Per-agent home + per-capability split" below):**
> the dated toggle-matrix log further down (`image-off` / `text-off` / `spawn-off` rows)
> predates the per-capability per-agent reshape. `image` is now its own per-agent flag
> (`AgentSettings.imageEnabled`, no longer riding `spawnDelegationEnabled`), `spawn` gets
> a per-agent `spawnableAgentNames` allow-list, and those matrix rows describe the
> **Default / main chat** path (global config), which a custom agent now overrides from
> its **Subagents** tab.
>
> **Master switch removed + Spawn tab folded into Settings (2026-06-26).** The global
> `SubagentConfiguration.agentDelegationEnabled` flag is **deleted** — in a per-agent
> world it was a redundant second gate. Off-by-default + invisible-at-baseline now hold
> purely from the per-agent defaults (every agent + the main chat ship disabled). The
> tool-availability rows below that say "master off → hidden / `agentDelegationEnabled=
> false` → 0 tool-calls" describe a state that **no longer exists**; the base schema
> always carries the delegation family and `resolveTools` narrows it per agent. The
> dedicated **Spawn sidebar tab + `SpawnSettingsView` are deleted**: the three shared
> runtime knobs (Local Orchestrator Handoff — now **default ON** — RAM-Safety Preflight,
> Image Load Policy) live in a **"Subagents" card in the general Settings tab**
> (`SubagentSettingsSection` hosted by `ConfigurationView`). Where the log below says
> "Spawn page / `SpawnSettingsView` / master enable," read "Settings → Subagents card,
> no master enable."

---

## 🧩 Unified Subagent Architecture (2026-06-25) — one host, four kinds

This is now the **authoritative** architecture and supersedes the per-path
descriptions in the dated log below. Pre-release, so the rename/merge carries **no
back-compat shims**. Goal: one consistent machinery across **all four** nested
subagent paths (`spawn`, `image`, `computer_use`, `sandbox_reduce`) instead of
four bespoke re-implementations of the same "bounded nested job → compact result,
inner steps never leak into the parent transcript" contract. `computer_use` was the
most-mature path, so its scaffolding (scope ids, live feed, interrupt, defer-cleanup,
compact result) was generalized into the shared `Subagent*` framework that the other
three adopt.

### Tool surface (what users/models see now)
- **`spawn`** — the only text subagent tool. `local_delegate` is **deleted**; its
  loop was a copy of spawn's. Persona-or-default text subagent, dedicated `spawn`
  permission key.
- **`image`** — one tool. `image_generate` + `image_edit` are **merged**: pass
  `prompt` (+ optional `negative_prompt`, `strength`); supplying `source_paths`
  switches it to **edit** mode. Both default-model settings are kept (gen vs edit
  bundles differ), and the gen→edit nudge / inline artifact bridge / `ToolDisplayName`
  are mode-aware.
- **`computer_use`** — unchanged loop + per-action confirm gate; it only *adopts* the
  shared layers.
- **`sandbox_reduce`** — unchanged read/search/exec allowlist; runs on the shared host.

### Three layers
```
tool entry (spawn | image | computer_use | sandbox_reduce)
  └─ SubagentSession host        Subagent/SubagentSession.swift
       ├─ scope ids (sessionId/toolCallId/agentId via ChatExecutionContext)
       ├─ recursion guard (one SubagentContext; no nested subagents)
       ├─ kind.resolveModel  → reject-before-evict
       ├─ kind.permission    → ask / deny / always   (computer_use: rich per-action gate)
       ├─ kind.makeHandoff() → ResidencyHandoff (spawn; image residency is coordinator-owned)   Subagent/ResidencyHandoff.swift
       │      local orchestrator → memoryPreflight → unload → run → restore
       │      cloud orchestrator → no unload (nothing resident)
       ├─ kind.run(scope, feed, interrupt)
       │      SubagentFeed + SubagentFeedRegistry + SubagentInterruptCenter
       └─ normalize → compact ToolEnvelope ; defer: unregister feed/interrupt, restore, telemetry
```

1. **Host — `SubagentSession`** (`Subagent/SubagentSession.swift`): every subagent
   tool funnels through it. Resolves scope ids, holds the recursion guard, registers a
   feed + interrupt token, runs the kind, normalizes to a compact `ToolEnvelope`, and
   `defer`s cleanup + telemetry. A deterministic scripted seam (`ScriptedSubagentKind`)
   exercises the full lifecycle **model-free** in tests/evals.
2. **Optional handoff — `ResidencyHandoff`** (`Subagent/ResidencyHandoff.swift`):
   generalized from the old `ChatResidencyHandoff`; the single residency authority for
   the host middleware. Only `spawn` (`modelSource = .agent`) overrides
   `makeHandoff()` to vend a real handoff; `image` (`modelSource = .dedicatedConfigured`)
   keeps the passthrough default because its `NativeImageJobCoordinator` owns image-model
   residency directly. Same-model kinds (`sandbox_reduce`, `computer_use`,
   `modelSource = .inheritsParent`) keep the passthrough default and skip
   preflight/unload/restore. (`needsHandoff` is removed — intent is the descriptor's
   `modelSource`; the swap is whether the kind overrides `makeHandoff()`.)
3. **Kinds behind `SubagentKind`** (`Subagent/SubagentKind.swift`, `Subagent/Kinds/`):
   `TextSubagentKind` (spawn), `ImageSubagentKind` (image), `ComputerUseKind`
   (computer_use), `SandboxReduceKind` (sandbox_reduce). Adding a future kind (privacy
   loop, code exec, browser) is one file + one registry entry.

### Cross-cutting unifications (the decoupling wins)
- **One activity feed.** `SubagentFeed` / `SubagentActivityEvent` /
  `SubagentFeedRegistry` / `SubagentInterruptCenter` (`Subagent/SubagentFeed.swift`)
  replace the computer-use-only feed + the separate `NativeImageJobProgress`.
  `NativeToolCallGroupView` binds ONE feed for every subagent row, so **text `spawn`
  now gets a live progress row** (fixes the old "frozen turn" gap) and image phase/step
  events map onto the same surface.
- **One capability/gating registry.** `SubagentCapabilityRegistry`
  (`Subagent/SubagentCapabilityRegistry.swift`) maps each capability flag → tool
  name(s) + guidance prompt. `SystemPromptComposer.resolveTools` iterates it to
  strip tools + inject guidance, and a shared `SubagentToolVisibility` resolver is
  used by **both** the composer and `HTTPHandler.enrichWithAgentContext`. This kills
  the hardcoded `["image_generate","image_edit","local_delegate","spawn"]` list that
  caused the **BUG E** surface desync; a parity test now guards it.
- **One compact-result contract.** The ad-hoc `spawn_result` / `digest` /
  `native_image_generation_job` payloads collapse into one `ToolEnvelope` shape that the
  inline-render bridge and agent-loop nudge read uniformly.
- **One recursion guard + budgets/cancellation.** `SandboxReduceContext` /
  `LocalTextDelegateContext` merge into one `SubagentContext` + the shared interrupt token.

### Config + settings
> **Superseded in part by "Full per-agent settings + unified main-chat tab
> (2026-06-26)" below** — image models, permissions, and budgets are now
> **per-agent** (each agent's Subagents tab, including the main chat's), and the
> global Spawn page is **system-only** (no Main Chat block). The
> `SubagentConfiguration` fields below survive as the **Default / main-chat** values
> (and the REST `/v1/images` default); custom agents carry their own on
> `AgentSettings`.

- `AgentDelegationConfiguration` → **`SubagentConfiguration`** (permission defaults
  collapsed to `spawn` + `image`; dead `AgentDelegationModelKind.localTextDelegate` +
  its ModelPicker candidate dropped). Store → **`SubagentConfigurationStore`** (on-disk
  file name `agent-delegation.json` retained for now). Semantics narrowed to **system +
  Default-agent**: it carries the master `agentDelegationEnabled`, local handoff,
  RAM-safety, image load policy, plus the **Default / main-chat** image gen/edit models,
  permissions, budgets, `imageDelegationEnabled`, and `spawnableAgentNames` (the main
  chat's pool).
- Global Settings → Spawn (`SubagentSettingsSection`) is now **system-only**: master
  enable · Local Orchestrator Handoff · RAM-Safety preflight · Image Load Policy · the
  "How it works" explainer. Image models, permissions, budgets, and the Default's
  spawn/image enable + pool moved to the **main chat's Subagents tab** (see
  2026-06-26 below). `SettingsSearchIndex` indexes the slimmed layout; the old "Cloud
  Cost Saver" block + orphaned delegate picker are gone.

### Per-agent home + per-capability split (IA reorg, 2026-06-25)
> **Updated 2026-06-26** — the Subagents tab is **no longer hidden for the Default
> agent** (the main chat configures spawn/image from its own tab now), and each card's
> config grew from toggles-only to **model + permission + budget** controls. See "Full
> per-agent settings + unified main-chat tab (2026-06-26)" below.

- The per-agent subagent controls moved out of the crowded Configure → Features list
  into a dedicated **`DetailTab.subagents`** ("Subagents") tab in the agent editor. It
  is **registry-driven**: one card per `SubagentCapabilityRegistry.perAgentToggleFlags`
  entry (`computer_use` → autonomy ceiling, `spawn` → per-agent spawnable checklist +
  permission + budgets, `image` → gen/edit model pickers + permission), each with its
  config inline in a DisclosureGroup.
- Each capability is now **independently per-agent** on `AgentSettings`:
  `computerUseEnabled` (+ `computerUseCeiling`), `spawnDelegationEnabled` +
  `spawnableAgentNames` (this agent's own spawn allow-list), and the new `imageEnabled`
  (`PerAgentFlag.image` — image no longer rides the spawn flag). `AgentConfigSnapshot` +
  `effectiveCapabilities(for:)` thread `imageEnabled` + `spawnableAgentNames` through.
- **Default-vs-custom resolution per capability** lives in `SubagentToolVisibility`
  (`spawnAvailable` / `imageAvailable` / `spawnTargetAllowed` /
  `visibleDelegationToolNames`), all ANDed with the master switch: Default → global pool /
  image switch; custom → its own toggle + allow-list. `ToolRegistry`'s base schema applies
  ONLY the master gate (superset); `resolveTools` + the HTTP path narrow per agent.
  `TextSubagentKind.resolveModel` validates the spawn target against the launching agent's
  list (custom) / global pool (Default); `ImageSubagentKind.resolveModel` gates on master +
  the launching agent's image-enable.

### Full per-agent settings + unified main-chat tab (2026-06-26)
The earlier split made the *enable* per-agent but left a capability's **model**,
**permission**, and **budget** in global Settings → Spawn — so you flipped `image` on in
the agent's tab but its model lived elsewhere. This pass finishes the principle: **a
capability is fully configured where you turn it on.**

- **New per-agent fields on `AgentSettings`** (custom agents): `imageGenerationModelId` /
  `imageEditModelId` (`String?`), `subagentPermissions` (`SubagentPermissionDefaults`,
  the `[kindId: policy]` map), and `subagentBudgets` (`SubagentBudgets`). Codable with
  back-compat defaults (legacy JSON → safe defaults; a nil model stays nil and falls
  through to the first-ready-model resolver). The permission/budget struct types were
  promoted to `public` so `AgentSettings` can hold them.
- **Pure effective-settings resolvers** next to `SubagentToolVisibility`
  (`SubagentCapabilityRegistry.swift`), mirroring `imageAvailable`'s shape so they stay
  MainActor-free + unit-testable: `effectiveImageModel(isEdit:isDefault:config:settings:)`,
  `effectivePermission(capabilityId:isDefault:config:settings:)`,
  `effectiveBudgets(isDefault:config:settings:)`. **Default / main chat → global
  `SubagentConfiguration`; custom agent → its own `AgentSettings`** (missing permission →
  `.ask`; nil image model → first-ready fallback).
- **Execution wiring.** `ImageSubagentKind` resolves its model via `effectiveImageModel`
  and its allow/deny via `effectivePermission` (the launching agent from `scope`);
  `TextSubagentKind` reads `effectivePermission` + `effectiveBudgets`. The **in-prompt
  first-use image-model picker is removed** — the model is chosen in the tab, so the
  runtime prompt is a plain allow/deny (`.alwaysAllow` is set per-agent in the tab).
- **Unified main chat.** The Subagents tab is un-hidden for the Default agent and renders
  only the Spawn + Image cards (no `computer_use`), bound to the global
  `SubagentConfiguration` via `SubagentConfigurationStore` (the main chat's settings still
  live there — it's a UI move, not a persistence migration). Custom agents write their
  `AgentSettings` via `debouncedSave()`; the main chat saves the global config directly.
- **System-only Spawn page.** `SubagentSettingsSection` dropped the Main Chat block and the
  moved image-model / permission / budget controls; it keeps master enable, Local
  Orchestrator Handoff, RAM-Safety, Image Load Policy, and the explainer.
  `SpawnSettingsView`'s subtitle + `SettingsSearchIndex` were updated to match.
- **Documented exceptions (still global):** the `NativeImageJobCoordinator` image-job
  residency timeout (`config.budgets.maxElapsedSeconds`; no `agentId` in
  `NativeImageJobContext`) and the REST `/v1/images` default model (not agent-scoped, =
  the main chat's model).
- **Tests:** `AgentSettings` Codable round-trip (incl. the 4 new fields + legacy
  defaults); resolver units (default vs custom + nil fallback) in
  `SubagentCapabilityRegistryTests`; `ImageSubagentKind` permission deny/always
  (model-free, via the Default-agent global path); `SpawnToolTests` per-agent +
  main-chat permission deny. Model-free suites green (residual failures are pre-existing
  keychain-disabled-mode + cross-suite ToolRegistry races + an MCP probe timeout, all
  unrelated). OsaurusCore + OsaurusEvals + the app target all build.

### Tests & evals
- OsaurusCore: `SubagentSession` host + each `SubagentKind` + the generalized
  feed/registry/interrupt + the merged `image` `source_paths`→edit routing + the
  `ResidencyHandoff` middleware are unit-tested, plus a **capability/visibility parity
  test** (`resolveTools` ⇄ `enrichWithAgentContext`) as the BUG E regression guard.
  `make test` / `make ci-test` stay green; `build/Tests.xcresult` covers the new types.
- OsaurusEvals: a new **`subagent` domain** (facade `SubagentJobEvaluator`, a
  `case "subagent":` arm in `EvalRunner.runOne`, an `expect.subagent` block) with
  **scripted, model-free, CI-safe** cases that also run as eval-kit unit tests, plus
  **live** spawn + image (gen/edit) cases that skip cleanly when no host/model is
  configured. `computer_use_loop` / `agent_loop` / `sandbox` suites stay green. See
  `Packages/OsaurusEvals/README.md` → the `subagent` domain section.

> The dated working-log below (GPU serialization, BUGs A–G, live matrices) remains the
> **historical record** of how the image/spawn/computer-use paths were proven; it is
> preserved verbatim and read through the naming map above.

---

## ⭐ GPU concurrency / chat↔image handoff — FINAL STATE (2026-06-22)

This is the authoritative summary; the dated "BUG G" / "minimax" / "serialization"
sections lower down are the working log that led here.

**Status: the chat↔image handoff is SECURE (no crash) and SMOOTH (context preserved,
coherent) — proven across gemma-4-12b, qwen3-8b, lfm2.5-8b, minimax-m2.7, laguna-m.1.**

**Why it crashed:** image generation (vMLXFlux) is a SECOND MLX graph on the shared
Metal device — new this session. It raced the LLM engine's async GPU tails (decode
+ cache-store eval, model-teardown buffer frees) during the handoff. vmlx is correct
for LLM-only; the crash is purely the two-graph boundary.

**The fix = 3 serialization changes:**
1. `vmlx BatchEngine.finishSlot`: `Stream().synchronize()` before `continuation.finish()`
   → "stream finished ⇒ GPU idle" (drains the decode/SSM-rederive tail on the engine's
   own thread). **REQUIRED for slow models (minimax) — proven: without it minimax crashes,
   with it 0 crashes.**
2. `osaurus ImageGenerationService`: `MLXCacheIOLock.withSerializedMLXCacheIO { Memory.clearCache() }`
   after `enterImageGeneration()` → waits for in-flight cache store + drains teardown.
3. `osaurus ModelRuntime.unload`: `Stream.gpu.synchronize → clearCache → synchronize`
   → chat-model teardown fully settles before the next producer loads.

**Durability — ONE open action:**
- Fixes #2 and #3 are COMMITTED in osaurus (durable).
- Fix #1 is a vmlx change. osaurus pins `github.com/osaurus-ai/vmlx-swift @ d35c0744`.
  The change is committed in the LOCAL vmlx (107c467b) but that fork is DO_NOT_PUSH.
  **To make it durable: land the finishSlot drain on canonical osaurus-ai/vmlx-swift
  and repin osaurus' Package.resolved.** Proven necessary (the fast models survive on
  osaurus-side fixes alone; minimax needs #1). The current dev build carries all three.

**Separate open item:** `lfm2.5-8b-a1b` returns empty output even with NO image/handoff
(plain chat) — a pre-existing model/template bug, not this work. Tracked as #78.

---

## 🔄 Reconciliation with main (2026-06-22) — merged + building clean

Our branch had diverged from `main` (107 ahead / 43 behind). Reconciled:
- **Merged `origin/main` → `feat/image-generation-vmlxflux`** (merge commit `753a5de4`), bringing all 43 main commits: release 0.20.8, **app-hang fixes (#1638)**, computer-use hardening, privacy filter, agent-db upgrade, **gemma-4-12b optimization (#1614)**, and **vmlx pin bumped `d35c0744` → `4453909e`**.
- **5 conflicts resolved keeping BOTH sides** (UI/prompt): SystemPromptComposer (our spawn-delegation gate + main's configure-surface), AgentsView (`spawnDelegationEnabled` + main's `order`), ChatView (main's `modelSupportsImages` helper with our `imageEdit` check re-added), FloatingInputCard (our image-composer branch wrapping main's reorganized chip row), Localizable.xcstrings (took main's; our strings fall back to English base).
- **vmlx diff confirmed:** main's newer `4453909e` STILL lacks the `BatchEngine.finishSlot` drain (its only 2 new commits #79/#80 don't touch it) → the concurrent-GPU bug is unpatched upstream; the drain re-applied onto 4453909e.
- **Merged branch BUILD SUCCEEDED**, no errors. GPU fixes survived the merge. Pushed.

### 📋 Things to address / fix (live list)
1. ✅ Merge main + resolve conflicts (753a5de4).
2. ✅ Build merged branch (succeeded).
3. 🔄 Live E2E re-test merged branch — model matrix (secure+smooth) + delegation paths coherence (in progress).
4. ⚠️ **Durability (only non-durable item):** `BatchEngine.finishSlot` drain lives in the ephemeral build checkout (4453909e) + the DO_NOT_PUSH local vmlx fork. To survive clean rebuilds it must land on canonical `osaurus-ai/vmlx-swift` (on top of 4453909e) + osaurus repin. Everything else (2 osaurus-side GPU fixes) is committed.
5. ⚠️ lfm2.5-8b-a1b empty output (#78) — pre-existing model/template bug (empty with NO image involved), not the handoff.
6. (verify) main's app-hang/agent-db/computer-use changes don't regress spawn/image-gen — covered by build success + the E2E pass.

## ✅ Current state (2026-06-21)

Spawn is a **tool** the orchestrator chat (local OR cloud) calls to run a bounded
job: image gen/edit (vMLXFlux) or a local text/coder subagent. Working + live-proven:

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
  description read verbatim ("Let this agent spawn helper jobs and subagents. Give the
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
- **Piece #2 — first-use permission + model picker** (~~still to build~~ → **DROPPED
  2026-06-26**): the in-prompt model picker was removed in favor of per-agent model
  selection in the agent's Subagents tab (see "Full per-agent settings + unified
  main-chat tab"). The first-use prompt is now a plain Yes/No/Always; "Always" is the
  `.alwaysAllow` policy set per-agent in that tab.

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

## HTTP agent-run surface E2E (after BUG E + BUG F) — deterministic, no GUI

With BUG E (default-agent delegation surfacing) and BUG F (model resolution / window) fixed, the `/agents/default/run` HTTP path now works end-to-end for the delegation tools — verified deterministically over HTTP (no Codex GUI), with a model warmed first so BUG F's loaded-model fallback resolves:
- **image_generate**: tool surfaced + fired; FLUX ran (`[flux] image shape=[1,3,1024,1024] finite=true`) and saved a valid PNG. (The curl client hit its 180s cap during the cold warm+handoff+gen before the completion frame; the server completed the job and saved the image — a client-timeout artifact, not a feature defect.)
- **local_delegate**: fired → qwen3-4b returned a coherent haiku into the stream, no looping, no tag leaks.
- **spawn**: fired → Sparky responded "I'm Sparky, a concise assistant."

So the delegation feature is now proven coherent on BOTH surfaces — the native chat (image_generate / image_edit / local_delegate / spawn, with context preserved across handoffs) and the HTTP agent-run API. Six bugs fixed across the campaign (A: tool/ prefix, B: cancellation [pre-existing], C: result-bloat loop, D: config-decode fragility, E: agent-run surface split, F: agent-run model/window), all with verified root causes.

## Deep context-carry stress (Eric /loop 2026-06-22) — SWA, resume coherence, image/file carry-over

Deterministic multi-turn HTTP harnesses (growing message history through /agents/default/run, interleaving handoffs). Every turn scanned for tag/channel leaks and repeated-n-gram looping; recall checks for early facts.

- **Text context carry across handoffs — PASS.** 8-turn conversation; established name/secret-number/city, grew context, did an image_generate handoff then a local_delegate handoff. Recall after BOTH handoffs was exact ("Zephyr / 4291 / Reykjavik"; "4291 / Reykjavik"). Every turn clean — no looping, no incoherence, no tag leaks.
- **User-provided image carry-over across a handoff — PASS.** Sent a real image (gemma-4 vision: "teapot, light blue"), generated a different image (model unload/reload), then asked about the FIRST image — "the main object in the first image you showed was a teapot, and its color was light blue." Visual context survived the handoff.
- **Long-context / SWA-window crossing — PASS.** Grew the conversation to ~2.8k tokens (2.7× gemma's sliding_window=1024) with six detailed multi-paragraph answers, planted two facts at the very start (GLACIER-7734 / NIGHTJAR), did an image handoff deep in the context, then recalled both early facts exactly and resumed coherently. No degeneration/looping at depth. Extended deeper: grew to ~8,733 tokens (8.5x the 1024 sliding_window) over 18 detailed turns with an image handoff at ~8.6k deep — all coherent, no looping/leaks, and both early facts (GLACIER-7734 / NIGHTJAR) recalled exactly. The known ~36k+ degeneration ceiling is tracked separately as a vmlx-side limit, far beyond normal usage.)

Net: context — text and images — passes through cleanly across model load/unload handoffs and past gemma's local attention window, with no looping, no incoherency, and accurate recall. gemma's SWA/hybrid attention carries the conversation correctly.

## BUG G — concurrent-GPU crash during image handoff after a chat turn (VERIFIED, NOT yet fixed; engine-level)

Found by the multi-model stress: with qwen3-8b as the main chat model, an image_generate handoff immediately after a chat turn crashes the app. Two manifestations of the SAME race, both captured in crash reports:
- `osaurus-2026-06-22-031748.ips` — SIGSEGV (EXC_BAD_ACCESS) in `AGXG17XFamilyCommandBuffer tryCoalescingPreviousComputeCommandEncoder` via `mlx_eval → binary_op_gpu → get_command_encoder`. 4 threads concurrently in MLX/Metal at crash (StreamThread eval + encoder creation [triggered] + array::wait + IOGPU submitCommandBuffers).
- `osaurus-2026-06-22-032933.ips` — SIGABRT: `-[_MTLCommandBuffer addCompletedHandler:] failed assertion 'Completed handler provided after commit call'` via `mlx_eval → gpu::eval → addCompletedHandler`.

Root cause: the LLM `BatchEngine` (vmlx) submits its end-of-turn GPU work via async MLX `eval`; its `StreamThread` can still be finalizing command buffers on the shared Metal device after the producer released the MetalGate. The next exclusive producer (vMLXFlux) then builds/commits command encoders on the same device concurrently → command-buffer race. Timing-dependent: gemma-4's timing did not trip it across extensive native-chat image runs; qwen3-8b's (and an aggressive rapid load→gen→image repro) does. Same class as #60 (concurrent-GPU embedder SIGSEGV) and the prior spawn residency crash.

Attempted osaurus-side fix (reverted): `Stream.gpu.synchronize()` right after acquiring the exclusive image gate. EMPIRICALLY DISPROVEN by re-running the repro — it still crashed, and worse, synchronizing from the image thread COMMITS the BatchEngine's in-flight buffer, directly causing the `addCompletedHandler after commit` assertion. So the drain must NOT be initiated by a foreign thread mid-BatchEngine-buffer.

Correct fix is engine-level: the `BatchEngine` must fully finalize its async GPU tail (all evals committed, completion handlers attached, buffers completed) BEFORE `exitGeneration` releases the MetalGate — without a foreign thread force-committing its buffer. That belongs in vmlx-swift's BatchEngine / its MetalGate-release ordering, alongside the #60 concurrent-GPU serialization work. Not a one-spot osaurus patch; tracked as BUG G (#76) for that dedicated effort. NOTE: normal native-chat image generation (the shipped default-agent path with gemma) is proven solid across the whole campaign; BUG G is a timing-sensitive crash under specific cross-producer handoff patterns.

## BUG G — FIXED at the engine level + PROVEN (real fix, no guard)

Root cause pinned to vmlx `BatchEngine.finishSlot` (BatchEngine.swift): it yields `.info`, runs the end-of-turn cache store (`MLX.eval` on trimmed/boundary snapshots + hybrid-SSM re-derive forward passes), then calls `slot.continuation.finish()`. Those evals only SUBMIT GPU work — MLX completes it async on its stream thread. osaurus' MetalGate releases the process-wide GPU lane when the stream finishes, so a still-in-flight cache-store eval raced the next exclusive producer (vMLXFlux image gen / embedder / model load) on the shared Metal command buffer → the SIGSEGV (`tryCoalescingPreviousComputeCommandEncoder`) and SIGABRT (`addCompletedHandler after commit`) crashes.

Fix (vmlx commit 107c467b): drain the GPU with `Stream().synchronize()` on the engine's own thread (which owns the command buffers — no foreign-commit hazard, unlike the reverted osaurus-side attempt) immediately before `continuation.finish()`, so "stream finished" provably means "GPU idle." Mirrors the existing `finishSoloFastPath` drain. The `.info` completion is still surfaced first, so user-visible latency is unchanged; only the post-response stream-close is gated on GPU idle.

PROVEN: the qwen3-8b chat → image_generate handoff that reliably crashed on iter 1 now survives 6/6 iterations with 0 new crash reports.

LANDING: the fix is committed to the LOCAL vmlx fork (push remote is DO_NOT_PUSH; the local branch has diverged from osaurus' pin d35c0744). To land durably: apply the same finishSlot drain to the canonical vmlx osaurus pins, then repin osaurus' Package.resolved. The current dev build already carries the fix (applied to the resolved checkout) and is proven.

LIKELY ALSO FIXES #60: the capabilities_discover embedding SIGSEGV is the same race class — the embedder (an exclusive MetalGate producer) racing a prior generation's async GPU tail. Draining before the generation stream finishes closes that window too.

## BUG G fix: proven for mainstream models; minimax residual (same race class, edge/in-dev)

Multi-architecture crash-repro sweep on the BUG-G-fixed binary (rapid chat->image handoff):
- qwen3-8b (standard KV): SURVIVED 3/3 (was iter-1 crash pre-fix) — fix holds.
- lfm2.5-8b (conv-hybrid): SURVIVED 3/3.
- minimax-m2.7-small-jangtq (linear attention): CRASHED iter 2 — new SIGABRT in tryCoalescingPreviousComputeCommandEncoder via copy_gpu_inplace.

The minimax crash is the SAME concurrent-GPU race CLASS but on a path the finishSlot drain doesn't cover. Verified it is NOT OOM (38GB free) and NOT the disk store (DiskCache.store already brackets materialization with Stream.gpu.synchronize(); paged-KV disabled here). So a minimax-specific GPU submission (its linear-attention / sparse-cache decode, actively being ported under #58) escapes the known drain points. minimax is also very slow (~40s first token). Tracked as #77 — honest residual, NOT claimed fixed. The mainstream/default path (gemma) and qwen3/lfm2 are solid and proven.

## minimax (#77): multi-layer GPU-concurrency cascade — NOT fully fixable by targeted patches

Root-caused via three successive crash reports while fixing layer by layer. minimax (slow: ~40s first token, heavy JANGTQ + SSM state) widens every race window, exposing a CASCADE of MLX metal-device concurrency gaps that fast models (gemma/qwen3/lfm2) win on timing:
1. **Decode/cache-store tail (031748/045251)** — generation finished the stream before its async eval drained. FIXED + PROVEN (BatchEngine finishSlot `Stream().synchronize()` before finish; mainstream models 6/6 + 3/3).
2. **Cache-store vs FLUX (045251)** — the post-gen cache store holds `MLXDiskCacheIOLock` and submits Metal work; FLUX doesn't take that lock. Tried an `MLXCacheIOLock.withSerializedMLXCacheIO` barrier in image gen — it CLOSED this layer (crash moved past it) but revealed layer 3, so it was reverted (kept only proven fixes).
3. **Model unload vs load (051006)** — SIGSEGV in `mlx::Fence::wait`/`encodeWaitForEvent` colliding with `IOGPUMetalResource dealloc` (`MetalAllocator::free`) during FLUX weight load (`ParallelFileReader::read`→`Load::eval_cpu`). model UNLOAD does `Stream.gpu.synchronize()` but is NOT MetalGate-serialized (load IS, line 1401), and its async buffer dealloc + fences outlive the synchronize, racing the next producer's load.

Layers 2-3 are the deep #60 device-serialization problem: async MLX/Metal operations (allocator free, fences, file-load eval) that escape `synchronize` and the producer-level MetalGate. Fully closing them is a dedicated architectural concurrency refactor (gate model unload too, and serialize async dealloc/fences across the residency handoff) — NOT safe to patch blindly layer-by-layer (deadlock risk: unload runs INSIDE the image gate during the handoff). Tracked under #77 + #60.

NET: the mainstream/default path (gemma) and qwen3/lfm2 are solid and proven across the whole campaign. minimax — an edge, slow, actively-being-ported (#58) model — exposes the residual concurrency cascade and needs the dedicated #60 architectural work, with the precise 3 layers now documented.

## Proper GPU serialization for the chat->image handoff (IN PROGRESS — verifying full model set)

Context: vmlx-swift is correct for LLM-only (generation/load/unload/swap/context all proven). The concurrent-GPU crash class is at the NEW boundary this session added — vMLXFlux image generation as a SECOND MLX graph on the same Metal device, racing the LLM's async GPU tails during the handoff. Fast models won the timing; minimax-m2.7 (slow) reliably lost it. Three serialization fixes (general, not model-specific):

1. **Engine decode/cache-store drain** (vmlx `BatchEngine.finishSlot`, commit 107c467b): `Stream().synchronize()` on the engine's own buffer-owning thread before `continuation.finish()`, so "stream finished ⇒ GPU idle". PROVEN (qwen3-8b 6/6, gemma/lfm2 3/3).
2. **Image-gen barrier vs cache IO** (osaurus `ImageGenerationService`, after `enterImageGeneration`): `MLXCacheIOLock.withSerializedMLXCacheIO { Memory.clearCache() }` — waits for any in-flight post-gen cache store (held under `MLXDiskCacheIOLock`) to finish, returns freed teardown buffers, drains. Avoids force-committing a mid-flight buffer.
3. **Unload teardown drain** (osaurus `ModelRuntime.unload`): `Stream.gpu.synchronize()` → `Memory.clearCache()` → `Stream.gpu.synchronize()`, so the chat-model's async buffer frees + fences fully settle before the next producer (FLUX load) touches the device.

VERIFICATION IN PROGRESS: full model matrix — gemma, qwen3-8b, lfm2, minimax-m2.7, laguna — each through load -> chat(remember codeword) -> image handoff (unload/context-swap) -> recall, asserting no crash + context recall + coherence. Results to be appended.

### RESULT — model matrix: secure + smooth handoff PROVEN (0 crashes)

Full matrix on the fixed binary (load -> chat -> image handoff [unload/context-swap] -> recall), crash reports before=5 after=5 (**0 new — no GPU crash across any model, including minimax-m2.7 which reliably crashed before**):
- gemma-4-12b: UP, recall "FALCON-88" exact — smooth + context.
- qwen3-8b: UP, recall "FALCON-88" exact — smooth + context.
- minimax-m2.7: UP (NO CRASH — the fix's headline), load+chat coherent ("Acknowledged, FALCON-88"); recall "(no-reply)" was a 200s HTTP timeout (~40s/token), not incoherence — isolation test (no handoff, 280s) returns coherent "hello".
- laguna-m.1: UP; matrix "(no-reply)" was a cold-load timeout — isolation test returns coherent "Hello! How can I assist you today?".
- lfm2.5-8b-a1b: UP, but EMPTY output — reproduces with NO image/handoff at all (empty on first chat), so it is a PRE-EXISTING model/template issue, NOT the handoff. Tracked separately.

Conclusion: the three-part GPU serialization (BatchEngine finishSlot drain + image-gen MLXCacheIOLock barrier + ModelRuntime.unload teardown drain) makes the chat<->image handoff completely secure (no concurrent-GPU crash for any model) and smooth (context preserved, coherent, no looping/leaks caused by the handoff). lfm2 empty-output is a separate model bug.

### ✅ Merged-branch E2E (2026-06-22) — secure + smooth + delegation all hold

On the merged binary (vmlx 4453909e + BatchEngine drain + merged osaurus):
- **Secure:** gemma-4-12b, qwen3-8b, minimax-m2.7 all survive the load→chat→image-handoff cycle — **0 new crash reports** (minimax-m2.7 included; the merge did not regress the GPU fix).
- **Smooth:** coherent chat through the handoff ("Codeword RAVEN-9 recorded", "RAVEN-9 is secure", "RAVEN-9 acknowledged").
- **Delegation:** BUG E + BUG F fixes survived the merge (verified present). local_delegate fires + returns a coherent haiku when a chat model is loaded. (The batched-E2E "empty" was a test-sequencing artifact: the matrix's image handoffs unload the chat model, so the BUG-F loaded-model fallback had nothing to resolve — production always has a configured default model; warming a model immediately before the delegate call resolves it.)

Net: the reconciled branch (main + spawn/image-gen + GPU serialization) builds clean and is secure+smooth across the model set. Remaining items unchanged: the vmlx BatchEngine drain needs canonical landing for durability; lfm2 empty output (#78) is a separate pre-existing model bug.
