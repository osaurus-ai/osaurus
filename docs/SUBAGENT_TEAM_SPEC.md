# Spawn — Team Spec, Wiring & Usage

Audience: osaurus contributors. **Canonical design + operational nuances:**
[`SUBAGENT_PORTABLE_DESIGN.md`](SUBAGENT_PORTABLE_DESIGN.md). **Status/TODO + test
matrix:** [`SUBAGENT_ORCHESTRATION_STATUS.md`](SUBAGENT_ORCHESTRATION_STATUS.md).
This file is the spec + wiring contract for the current build.

> **Unified framework (2026-06-25).** All four nested sub-agent paths now run through
> one shared host — `SubagentSession` (`Subagent/SubagentSession.swift`) + a
> `SubagentKind` protocol (`Subagent/SubagentKind.swift`, kinds in `Subagent/Kinds/`).
> Tool surface: **`local_delegate` removed (folded into `spawn`)**, and
> **`image_generate` + `image_edit` merged into one `image` tool** (`source_paths` ⇒
> edit). Renames: `AgentDelegationConfiguration` → `SubagentConfiguration`,
> store → `SubagentConfigurationStore`, the handoff → `ResidencyHandoff`. The §4 paths
> below have been updated to the shipped types.

> **Per-agent settings (2026-06-26).** Image models, permissions, and budgets are now
> **per-agent** — configured in each agent's **Sub-agents** tab (custom agents store them
> on `AgentSettings`; the **main chat** edits the global `SubagentConfiguration` from its
> own un-hidden tab). Global Settings → Spawn is **system-only** (master enable · handoff ·
> RAM-safety · image load policy). The kinds read effective settings through pure resolvers
> (`SubagentToolVisibility.effectiveImageModel` / `effectivePermission` / `effectiveBudgets`,
> default→global / custom→`AgentSettings`). The in-prompt first-use image-model picker is
> gone (model lives in the tab). §2/§4/§6 below reflect this.

> **No master switch + no Spawn tab (2026-06-26, supersedes every "master switch /
> `agentDelegationEnabled` / global enable / Settings → Spawn tab" reference below,
> including §2's gate #1 and §4's `agentDelegationExcludedToolNames`).** The global
> enable flag is **deleted** — in a per-agent world it was a redundant second gate.
> Gating is now **only** per-agent: a custom agent via `AgentSettings`, the main chat
> via its `SubagentConfiguration` pool / image switch. Off-by-default +
> invisible-at-baseline hold because every agent ships disabled. `ToolRegistry`'s base
> schema **always** carries the delegation family (a superset); `resolveTools` does all
> the narrowing. The **dedicated Spawn sidebar tab + `SpawnSettingsView` are deleted**;
> the three shared runtime knobs (Local Orchestrator Handoff — now **default ON** —
> RAM-Safety Preflight, Image Load Policy) live in a **"Sub-agents" card in the general
> Settings tab** (`SubagentSettingsSection` hosted by `ConfigurationView`). Read "master
> enable / Settings → Spawn" below as "Settings → Sub-agents card, no master enable."

---

## 1. What it is

A chat turn's **orchestrator** model (local OR cloud) can run a bounded nested
**sub-agent** behind a tool call and fold its result back into the turn — input →
output, the orchestrator never sees the sub-agent transcript (only the digest/artifact).

Sub-agents are a **general framework**, not a fixed set of tools. Each **KIND**
conforms to `SubagentKind` and runs through `SubagentSession`, sharing one lifecycle
(scope ids → recursion guard → resolve → permission → [handoff] → run → compact
result → defer-cleanup):

| Kind | Tool | Runner | Returns | `modelSource` → handoff |
|------|------|--------|---------|--------------------------|
| `TextSubagentKind` | `spawn` | `AgentSubagentRunner` → `AgentToolLoop` on a persona's model | text digest | `.persona` — a local persona model unloads/reloads the local orchestrator (the kind's `makeHandoff()` vends a `ResidencyHandoff`) |
| `ImageSubagentKind` | `image` | `NativeImageJobCoordinator` → `ImageGenerationService` (vMLXFlux); `source_paths` ⇒ edit | artifact | `.dedicatedConfigured` — the coordinator owns image-model residency (kind keeps the passthrough default) |
| `ComputerUseKind` | `computer_use` | `ComputerUseLoop` (+ per-action confirm gate) | summary | `.inheritsParent` — no swap (passthrough) |
| `SandboxReduceKind` | `sandbox_reduce` | `AgentToolLoop` with a read/search/exec allowlist | digest | `.inheritsParent` — no swap (passthrough) |
| privacy loop · code exec · browser · … | — | their own kind | their result | future |

> **`modelSource` axis.** A kind declares how it resolves the model it runs:
> `.dedicatedConfigured` (own configured default + coordinator-owned residency),
> `.persona` (a chosen persona's local/remote model; the kind runs the residency
> handoff), or `.inheritsParent` (reuses the parent agent's model, no residency
> change). It documents the local-vs-remote axis a future dedicated model-backed
> kind (e.g. an AppleScript generator) slots into, and matches whether the kind
> overrides `makeHandoff()`.

Reuse, don't reinvent: `AgentToolLoop` (`Services/Chat/AgentToolLoop.swift`),
`sandbox_reduce` (`docs/REDUCTION_SUBAGENT.md`), Computer Use Subagent (PR #1578).
**Add a kind = one descriptor + one kind + one thin tool, register, done:**
1. **Descriptor** — add a `SubagentCapability` to `SubagentCapabilityRegistry`
   (`id`, `toolNames`, `gate`, optional `perAgentFlag`, `modelSource`,
   `displayLabel`, `iconName`, optional `guidance*`) and append it to `all`. This
   one value drives gating, the per-agent toggle, the feed header + tool chip, and
   the prompt guidance — every surface reads it, so there is no second list to edit.
2. **Kind** — one `SubagentKind` conformer in `Subagent/Kinds/` whose `capability`
   returns that registry entry (so kind and descriptor are one value); implement
   `resolveModel` / `permission` / `run`, and override `makeHandoff()` only if it
   swaps models.
3. **Tool** — a thin tool that parses args, builds the kind, and calls
   `SubagentSession.run(_:tool:)`.

## 2. Gating — DEFAULT OFF, master switch + per-capability, per-agent resolution

1. **Master (global):** `SubagentConfiguration.agentDelegationEnabled` — the one
   system-wide switch. With it off, the whole delegation family is hidden for everyone;
   `ToolRegistry`'s base schema applies ONLY this master gate (no agent context), so the
   base set stays a superset and the per-agent narrowing happens where the agent is known.
2. **Per-capability, resolved per agent** by `SubagentToolVisibility` (each ANDed with
   the master switch):
   - **`spawn`** — *Default / main chat:* governed by the global pool
     (`SubagentConfiguration.spawnableAgentNames`, edited in the main chat's Sub-agents
     tab); visible when the pool is non-empty. *Custom agent:* its own
     `AgentSettings.spawnDelegationEnabled` **and** a non-empty per-agent
     `AgentSettings.spawnableAgentNames` (its Sub-agents tab) — nothing to spawn ⇒ hidden.
   - **`image`** — *Default / main chat:* the global `imageDelegationEnabled` switch.
     *Custom agent:* its own `AgentSettings.imageEnabled` toggle.
   - **`computer_use`** — authoritative per-agent flag (`AgentSettings.computerUseEnabled`),
     stripped in both auto + manual mode; the Default agent never enables it.

Spawn *targets* are validated again at execution time (`TextSubagentKind.resolveModel` →
`SubagentToolVisibility.spawnTargetAllowed`): the Default agent checks the global pool, a
custom agent its OWN allow-list. A model can never reach an arbitrary local model — only
opted-in agents, scoped to the launching agent.

Both the native chat composer (`SystemPromptComposer.resolveTools`) and the HTTP
agent-run surface (`HTTPHandler.enrichWithAgentContext`) resolve the visible sub-agent
tool set through the SAME `SubagentToolVisibility.visibleDelegationToolNames` resolver, so
the two surfaces can never drift (the BUG E regression guard).

## 3. Model-handoff contract

```
Orchestrator = LOCAL model, subagent model is a DIFFERENT local model:
  wait for chat idle → unload orchestrator → load subagent → run → unload subagent
  → reload orchestrator → return result. (single-residency)
Orchestrator = CLOUD/API  → no unload/reload (nothing resident); run subagent, return.
Subagent model == orchestrator model → no swap; run in place.
Subagent model is REMOTE → run remote; no local handoff.
```

Safe because main's owner-keyed `MetalGate` makes **model load** an exclusive GPU
producer (`enterModelLoad`/`exitModelLoad`) — unload→load→reload never overlaps an
in-flight generation/eval (also the fix for the model-switch SIGABRT, task #34).
RAM safety = single-residency + `ModelRuntime.load`'s model-fit refusal +
restore-on-failure (orchestrator never left unloaded).

## 4. Components & wiring (current)

### Shared host & framework (`Subagent/`)
- **`Subagent/SubagentSession.swift`** — the host every sub-agent tool funnels
  through: resolves scope ids (`sessionId`/`toolCallId`/`agentId` via
  `ChatExecutionContext`), holds the recursion guard (`SubagentContext`), registers a
  feed + interrupt token, runs the kind, normalizes to a compact `ToolEnvelope`, and
  `defer`s cleanup + telemetry. A scripted seam (`ScriptedSubagentKind`) drives the
  whole lifecycle model-free in tests/evals.
- **`Subagent/SubagentKind.swift`** + **`Subagent/Kinds/`** — the `SubagentKind`
  protocol (`capability`, `resolveModel`, `permission`, `run`, and an optional
  `makeHandoff()` that defaults to passthrough) and its conformers:
  `TextSubagentKind`, `ImageSubagentKind`, `ComputerUseKind`, `SandboxReduceKind`.
  Each kind's `capability` IS its `SubagentCapabilityRegistry` entry, so kind and
  descriptor are one value. (`needsHandoff` is gone — intent is the descriptor's
  `modelSource`, and the actual swap is whether the kind overrides `makeHandoff()`.)
- **`Subagent/ResidencyHandoff.swift`** — the optional handoff middleware
  (`SubagentHandoff`); only model-swapping kinds override `makeHandoff()` to vend a
  real `ResidencyHandoff` (today `spawn`, via its `.persona` model source). It builds
  on `Services/AgentDelegation/ChatResidencyHandoff.swift` (wait-idle → unload
  resident chat models → memoryPreflight → reload). Kinds that keep the
  `PassthroughHandoff` default (`computer_use`, `sandbox_reduce`, and `image` —
  whose coordinator owns its own residency) skip it.
- **`Subagent/SubagentFeed.swift`** — `SubagentFeed` / `SubagentActivityEvent` /
  `SubagentFeedRegistry` / `SubagentInterruptCenter`: one live progress + interrupt
  surface for all kinds (text spawn included). `NativeToolCallGroupView` binds it.
- **`Subagent/SubagentCapabilityRegistry.swift`** — the per-kind `SubagentCapability`
  descriptor (SSOT): `id` + `toolNames` + `gate` (+ `perAgentFlag`) + `modelSource` +
  `displayLabel`/`iconName` + `guidance*`. Drives `resolveTools`/`ToolRegistry`
  gating, the AgentsView per-agent toggle, the feed header + tool chip, and the
  prompt guidance loop, plus the `SubagentToolVisibility` resolver shared by the
  composer and the HTTP surface.

### Dispatch / runners
- **`Tools/SpawnTool.swift`** — the `spawn(agent, input)` tool → `TextSubagentKind`.
  Resolves the named Agent persona, checks the gates, resolves the model, runs it.
- **`Services/AgentDelegation/AgentSubagentRunner.swift`** — shared bounded text
  runner: resolve model → handoff (if local) → `AgentToolLoop.run` with the persona's
  prompt/model/tools → compact envelope. Used by `TextSubagentKind` (`local_delegate`
  is gone — its body lived here and is now spawn's only path).
- **`Tools/SandboxReduceTool.swift`** — the `sandbox_reduce` tool → `SandboxReduceKind`
  (read/search/exec allowlist on `AgentToolLoop`, `modelSource = .inheritsParent` →
  passthrough handoff).
- `Services/Chat/AgentToolLoop.swift` — the bounded loop driver (reused).

### Image kind (engine-specific, same handoff/progress)
- `Tools/NativeImageTools.swift` — the unified **`image`** tool (`ImageTool`);
  `source_paths` ⇒ edit. → `ImageSubagentKind`.
- `Services/AgentDelegation/NativeImageJobCoordinator.swift` — image handoff +
  vMLXFlux + progress; `NativeImageJobModelResolver` (strict, pre-residency). Its old
  private residency copies are deleted in favor of `ResidencyHandoff`.
- `Services/ModelRuntime/ImageGenerationService.swift` — the only `vMLXFlux` import,
  held in `MetalGate("image")`.

### Computer-use kind
- `ComputerUse/Tool/ComputerUseTool.swift` + `ComputerUse/Loop/ComputerUseLoop.swift`
  → `ComputerUseKind` (`modelSource = .inheritsParent` → passthrough handoff, host
  permission `.auto`; keeps its own per-action confirm gate). Adopts the shared
  feed/registry + compact-result contract.

### Personas / config / runtime (reused, existing)
- `Models/Agent/Agent.swift` + `Managers/AgentManager.swift` — persona name/model
  (local or remote)/prompt/tool-policy; `effectiveModel(for:)`. Per-agent sub-agent
  fields on `AgentSettings` (custom agents): `computerUseEnabled` + `computerUseCeiling`,
  `spawnDelegationEnabled` + `spawnableAgentNames` (this agent's own spawn allow-list),
  `imageEnabled` (image is its own per-agent toggle, no longer riding the spawn flag),
  and — added 2026-06-26 — `imageGenerationModelId` / `imageEditModelId` (`String?`),
  `subagentPermissions` (`SubagentPermissionDefaults`), and `subagentBudgets`
  (`SubagentBudgets`). `effectiveCapabilities(for:)` carries `imageEnabled` +
  `spawnableAgentNames` through to the snapshot the visibility resolvers read; the model /
  permission / budget fields are read live at the kind via the effective-settings
  resolvers (below).
- `Models/AgentDelegation/SubagentConfiguration.swift` + `SubagentConfigurationStore.swift`
  — the **system + Default/main-chat** config: master `agentDelegationEnabled`,
  local-handoff toggle, RAM-safety preflight, image load policy, plus the **Default /
  main-chat** values: default image gen/edit models, per-kind permission
  (`SubagentPermissionDefaults` is a `[kindId: policy]` map keyed by `capability.id`,
  ask/deny/always — a kind absent from the map defaults to `.ask`, so a new permissioned
  kind needs no new struct field), budgets, `imageDelegationEnabled`, and
  `spawnableAgentNames` (the main chat's pool). These also back the REST `/v1/images`
  default. Custom agents override the model / permission / budget values from their own
  `AgentSettings`. Persists to `agent-delegation.json`; broadcasts
  `.subagentConfigurationChanged`.
- `Subagent/SubagentCapabilityRegistry.swift` — `SubagentToolVisibility` also hosts the
  pure **effective-settings resolvers** (`effectiveImageModel` / `effectivePermission` /
  `effectiveBudgets`): **Default → global `SubagentConfiguration`; custom →
  `AgentSettings`** (nil image model → first-ready fallback; missing permission → `.ask`).
  Each kind reads these so the Default-vs-custom branch lives in one tested place.
- `Services/ModelRuntime.swift` — load/unload/`preload`/`cachedModelSummaries`, the
  model-fit refusal; `Services/ModelRuntime/MetalGate.swift` — GPU owner-keyed gate.

### Surfacing
- `Tools/ToolRegistry.swift` — `agentDelegationExcludedToolNames()` applies ONLY the
  master gate to the base schema (so the base set is a superset); per-agent narrowing of
  `spawn` / `image` happens downstream in `resolveTools` / the HTTP path. The delegation
  tool-name sets are DERIVED from `SubagentCapabilityRegistry` (no hand-maintained list).
- `Views/Agent/AgentsView.swift` — per-agent sub-agent controls live in the dedicated
  **`DetailTab.subagents`** ("Sub-agents") tab, rendered registry-driven (one card per
  `SubagentCapabilityRegistry.perAgentToggleFlags` entry: `computer_use` →
  autonomy-ceiling, `spawn` → per-agent spawnable checklist + permission picker + budget
  steppers, `image` → gen/edit model pickers + permission picker) with each card's config
  in an inline DisclosureGroup. The tab is **shown for the Default agent too** (2026-06-26):
  it renders only the Spawn + Image cards (no `computer_use`), bound to the global
  `SubagentConfiguration` via `SubagentConfigurationStore` (the main chat's settings still
  live there). Custom-agent cards write `AgentSettings` via `debouncedSave()`; the main
  chat saves the global config directly.
- `Views/Settings/SubagentSettingsSection.swift` — the global Spawn tab is **system-only**
  (2026-06-26): master enable, Local Orchestrator Handoff, RAM-Safety preflight, Image
  Load Policy, and the "How it works" explainer. The Main Chat block and the per-agent
  image-model / permission / budget controls moved to the main chat's Sub-agents tab. It
  still binds the one store and syncs via `.subagentConfigurationChanged`;
  `SettingsSearchIndex` indexes the slimmed layout.

## 5. Lifecycle & progress (summary; full detail in DESIGN §8)

`received → resolving_model → permission → waiting_for_chat_idle →
unloading_chat_models → loading_subagent → running → unloading_subagent →
restoring_chat_models → done`. Every phase emits a progress event so the UI shows
the swap ("Unloading… / Loading sparky… / Running… / Reloading…"), never a frozen
turn. Cache: orchestrator KV/prefix dropped on unload (cold resume; L2 block-disk
survives for a warm resume); per-model tokenizer/template; image jobs surface a
denoise step counter (k/N). Re-entrancy: a subprocess cannot `spawn`.

## 6. Usage

- **User:** open an agent's **Sub-agents** tab to configure its sub-agents end-to-end —
  toggle `computer_use` / `spawn` / `image`, pick which personas `spawn` may call (its own
  allow-list), set the `spawn` permission + budgets, and pick the `image` gen/edit models +
  permission. The **main chat (Default agent)** has the same tab (Spawn + Image cards). Only
  true system controls — master enable, "Local Orchestrator Handoff", RAM-Safety, and Image
  Load Policy — live in Settings → Spawn.
- **Model:** sees `spawn` (and any alias tools) only when enabled. `spawn("sparky",
  "do x y z")`. Image: one `image` tool — `image({"prompt": …})` to generate, add
  `source_paths` to edit.
- **Contributor:** a new KIND = one `SubagentCapability` descriptor in
  `SubagentCapabilityRegistry` (the SSOT that drives gating + the per-agent toggle +
  the feed/chip display + the prompt guidance) + one `SubagentKind` conformer in
  `Subagent/Kinds/` whose `capability` returns that descriptor and that implements
  `resolveModel` / `permission` / `run` (override `makeHandoff()` only if it swaps
  models) + one thin tool that builds the kind and calls `SubagentSession.run`. The
  host gives you scope ids, recursion guard, feed/interrupt, the (optional) handoff,
  and the compact-result envelope for free. A dedicated model-backed kind (e.g. an
  AppleScript generator on a local or remote model) is exactly this recipe with
  `modelSource = .dedicatedConfigured` or `.persona`. Do NOT add recursive agents,
  helper LLMs, or shell workers inside a kind — it is normal Swift service code
  driving one bounded job.
