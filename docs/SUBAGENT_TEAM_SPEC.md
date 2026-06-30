# Spawn — Team Spec, Wiring & Usage

Audience: osaurus contributors. **Canonical design + operational nuances:**
[`SUBAGENT_PORTABLE_DESIGN.md`](SUBAGENT_PORTABLE_DESIGN.md). **Status/TODO + test
matrix:** [`SUBAGENT_ORCHESTRATION_STATUS.md`](SUBAGENT_ORCHESTRATION_STATUS.md).
This file is the spec + wiring contract for the current build.

> **Unified framework (2026-06-25).** All four nested subagent paths now run through
> one shared host — `SubagentSession` (`Subagent/SubagentSession.swift`) + a
> `SubagentKind` protocol (`Subagent/SubagentKind.swift`, kinds in `Subagent/Kinds/`).
> Tool surface: **`local_delegate` removed (folded into `spawn`)**, and
> **`image_generate` + `image_edit` merged into one `image` tool** (`source_paths` ⇒
> edit). Renames: `AgentDelegationConfiguration` → `SubagentConfiguration`,
> store → `SubagentConfigurationStore`, the handoff → `ResidencyHandoff`. The §4 paths
> below have been updated to the shipped types.

> **Per-agent settings (2026-06-26).** Image models, permissions, and budgets are now
> **per-agent** — configured in each agent's **Subagents** tab (custom agents store them
> on `AgentSettings`; the **main chat** edits the global `SubagentConfiguration` from its
> own un-hidden tab). Global Settings → Spawn is **system-only** (master enable · handoff ·
> RAM-safety · image load policy). The kinds read effective settings through pure resolvers
> (`SubagentToolVisibility.effectiveImageModel` / `effectivePermission` / `effectiveBudgets`,
> default→global / custom→`AgentSettings`). The in-prompt first-use image-model picker is
> gone (model lives in the tab). §2/§4/§6 below reflect this.

> **Standard subagent model picker (2026-06-27).** Picking the model a subagent
> runs on is now a **standard axis** of the framework, not a per-kind special case.
> A per-capability override — `subagentModelOverrides[capabilityId]` on
> `AgentSettings` (custom agents) / `SubagentConfiguration` (main chat), a
> `[capabilityId: modelId]` map mirroring `subagentPermissions` — supersedes the
> kind's default model source. One resolver reads it:
> `SubagentToolVisibility.effectiveSubagentModel(capabilityId:isDefault:config:settings:)`
> (blank/absent → inherit). Scope: `computer_use` gets a picker; `spawn` gets an
> optional override that supersedes the agent's model (the `spawn_agent` path —
> `spawn_model` targets a chosen model id directly); `image` keeps its own gen/edit
> pickers.
>
> **Hardening (2026-06-27).** The three chat-driven kinds now share ONE
> resolution path, `Subagent/SubagentModelResolution.swift`, instead of repeating
> the lookup/fallback/residency block inline:
> - **Precedence** (`pickModel`, pure): eval seam > an *available* per-agent
>   override > the kind default; blank/whitespace entries are treated as absent.
> - **Availability fallback** (`availableOverride`, `@MainActor`): a stored
>   override that is no longer installed locally / not in the
>   `ModelPickerItemCache` resolves to `nil` so the kind inherits its default
>   instead of hard-failing on a deleted model (a cold cache trusts the id).
> - **Eval-bypasses-residency invariant**: when the eval seam forces a model the
>   decision is always `(isLocal: false, plan: .none)`, so a deterministic lane
>   never depends on live GPU residency.
> - **Residency**: it then calls the shared residency layer
>   (`Subagent/SubagentResidency.swift`) — when the resolved model is a DIFFERENT
>   local bundle than the resident chat model it unloads/reloads exactly like
>   `spawn` (reject-before-evict if Local Orchestrator Handoff is off).
>
> The picker is **registry-driven**: `SubagentCapability.supportsModelOverride`
> (true for `computer_use` / `spawn`; false for `image`) makes
> AgentsView render the standard override row automatically, with the empty-tag
> label derived from `modelSource` ("Use the agent's model" for `spawn`, else
> "Inherit parent model"). A new chat-driven kind gets a picker by only flipping
> the flag. `image` sets it false because it owns its own model system (separate
> gen/edit ids via `effectiveImageModel`, readiness + "first ready" fallback,
> coordinator-owned residency) and is NOT a `SubagentModelResolution` client.
> Pickers live in each agent's **Subagents** tab. §1's table + the
> `modelSource` note below reflect this.

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
> RAM-Safety Preflight, Image Load Policy) live in a **"Subagents" card in the general
> Settings tab** (`SubagentSettingsSection` hosted by `ConfigurationView`). Read "master
> enable / Settings → Spawn" below as "Settings → Subagents card, no master enable."

> **Spawn split + model pool, `sandbox_reduce` removed (2026-06-28, supersedes the
> single-`spawn`-tool and every `sandbox_reduce` reference below).** The one
> `spawn(agent, input)` tool is replaced by **two sibling tools** sharing the one
> `spawn` capability + `TextSubagentKind`: **`spawn_agent(input, agent)`** (run a
> spawnable agent on ITS prompt + model) and **`spawn_model(input, model)`** (run a
> bare spawnable model id with NO agent/system prompt). Each tool gates
> **independently** on its own non-empty pool, so an agent with only models sees just
> `spawn_model`. Alongside the agent pool, agents now have a user-configurable
> **spawnable-MODEL pool** — `spawnableModelNames` + a per-model `spawnableModelNotes`
> sidecar (a `[modelId: note]` map of "when/how to use it" hints) — on both
> `SubagentConfiguration` (main chat) and `AgentSettings` (custom agents), with the
> same execution-time allow-list check (`SubagentToolVisibility.spawnModelAllowed`,
> exact/trimmed match, reject-before-evict). When either spawn tool is visible the
> composer injects a **dynamic `spawn` guidance block** (a dedicated `.static` section
> in `SystemPromptComposer.appendGatedSections`, HTTP-parity) built from
> `SpawnDescriptors.resolve` → `SystemPromptTemplates.spawnGuidance`, enumerating the
> reachable agents (description · model · local/remote) and models (display name ·
> local/remote · provider · size/quant · the user's note). **`sandbox_reduce` (kind,
> tool, eval suites, `REDUCTION_SUBAGENT.md`) is deleted** — it wasn't earning its
> context cost; `computer_use` + `spawn` are the chat-driven kinds. The `spawn`
> selection UI in AgentsView is now a **selected-first** view (removable chips/rows +
> a searchable, grouped "Add" popover; models show a local/remote badge + an inline
> note field). §1/§2/§4/§6 below read in light of this.

---

## 1. What it is

A chat turn's **orchestrator** model (local OR cloud) can run a bounded nested
**subagent** behind a tool call and fold its result back into the turn — input →
output, the orchestrator never sees the subagent transcript (only the digest/artifact).

Subagents are a **general framework**, not a fixed set of tools. Each **KIND**
conforms to `SubagentKind` and runs through `SubagentSession`, sharing one lifecycle
(scope ids → recursion guard → resolve → permission → [handoff] → run → compact
result → defer-cleanup):

| Kind | Tool(s) | Runner | Returns | `modelSource` → handoff |
|------|------|--------|---------|--------------------------|
| `TextSubagentKind` | `spawn_agent` + `spawn_model` | `AgentSubagentRunner` → `AgentToolLoop` on the agent's model (`spawn_agent`) or a bare spawnable model id, no agent (`spawn_model`) | text digest | `.agent` default (+ optional `spawn` override for `spawn_agent`; `spawn_model` runs the chosen id); a DIFFERENT local model unloads/reloads the local orchestrator via the shared `SubagentResidency` layer |
| `ImageSubagentKind` | `image` | `NativeImageJobCoordinator` → `ImageGenerationService` (vMLXFlux); `source_paths` ⇒ edit | artifact | `.dedicatedConfigured` — the coordinator owns image-model residency (kind keeps the passthrough default) |
| `ComputerUseKind` | `computer_use` | `ComputerUseLoop` (+ per-action confirm gate) | summary | `.inheritsParent` default (+ optional `computer_use` override); a DIFFERENT local model unloads/reloads via the shared `SubagentResidency` layer |
| privacy loop · code exec · browser · … | — | their own kind | their result | future |

> **`modelSource` axis (the DEFAULT source, not the final model).** A kind declares
> how it DEFAULTS to sourcing its model: `.dedicatedConfigured` (own configured
> default + coordinator-owned residency), `.agent` (a chosen agent's
> local/remote model), or `.inheritsParent` (reuses the parent agent's model). It
> documents the local-vs-remote axis a future dedicated model-backed kind (e.g. an
> AppleScript generator) slots into. The **resolved** model is now override-aware
> (`effectiveSubagentModel` > the `modelSource` default), and the handoff is driven
> by that resolved model through the shared `SubagentResidency` layer — NOT by the
> static `modelSource`. So `computer_use` keeps `.inheritsParent`
> (its default, preserving the registry assertions) yet now vends a
> `ResidencyHandoff` when an override picks a different local model.

Reuse, don't reinvent: `AgentToolLoop` (`Services/Chat/AgentToolLoop.swift`),
Computer Use Subagent (PR #1578).
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
   - **`spawn`** (two tools, each gated independently on its OWN pool) —
     **`spawn_agent`** is visible iff the AGENT pool is non-empty; **`spawn_model`** iff
     the MODEL pool is non-empty. *Default / main chat:* the global pools
     (`SubagentConfiguration.spawnableAgentNames` / `.spawnableModelNames`, edited in
     the main chat's Subagents tab). *Custom agent:* its own
     `AgentSettings.spawnDelegationEnabled` **and** a non-empty per-agent pool of the
     matching kind (`AgentSettings.spawnableAgentNames` / `.spawnableModelNames`, its
     Subagents tab) — nothing to spawn ⇒ that tool hidden (both empty ⇒ neither).
   - **`image`** — *Default / main chat:* the global `imageDelegationEnabled` switch.
     *Custom agent:* its own `AgentSettings.imageEnabled` toggle.
   - **`computer_use`** — authoritative per-agent flag (`AgentSettings.computerUseEnabled`),
     stripped in both auto + manual mode; the Default agent never enables it.

Spawn *targets* are validated again at execution time (`TextSubagentKind.resolveModel`):
`spawn_agent` checks `SubagentToolVisibility.spawnTargetAllowed` (agent names,
case-insensitive) and `spawn_model` checks `spawnModelAllowed` (model ids, exact/trimmed),
each before any residency handoff (reject-before-evict). The Default agent checks the
global pool, a custom agent its OWN allow-list. A model can never reach an arbitrary
agent or local model — only opted-in targets, scoped to the launching agent.

Both the native chat composer (`SystemPromptComposer.resolveTools`) and the HTTP
agent-run surface (`HTTPHandler.enrichWithAgentContext`) resolve the visible subagent
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
- **`Subagent/SubagentSession.swift`** — the host every subagent tool funnels
  through: resolves scope ids (`sessionId`/`toolCallId`/`agentId` via
  `ChatExecutionContext`), holds the recursion guard (`SubagentContext`), registers a
  feed + interrupt token, runs the kind, normalizes to a compact `ToolEnvelope`, and
  `defer`s cleanup + telemetry. A scripted seam (`ScriptedSubagentKind`) drives the
  whole lifecycle model-free in tests/evals.
- **`Subagent/SubagentKind.swift`** + **`Subagent/Kinds/`** — the `SubagentKind`
  protocol (`capability`, `resolveModel`, `permission`, `run`, and an optional
  `makeHandoff()` that defaults to passthrough) and its conformers:
  `TextSubagentKind` (both spawn tools), `ImageSubagentKind`, `ComputerUseKind`.
  Each kind's `capability` IS its `SubagentCapabilityRegistry` entry, so kind and
  descriptor are one value. (`needsHandoff` is gone — intent is the descriptor's
  `modelSource`, and the actual swap is whether the kind overrides `makeHandoff()`.)
- **`Subagent/ResidencyHandoff.swift`** — the optional handoff middleware
  (`SubagentHandoff`); model-swapping kinds override `makeHandoff()` to vend a real
  `ResidencyHandoff`. Today every chat-driven kind (`spawn`, `computer_use`) can,
  because the model is override-aware. It builds on
  `Services/AgentDelegation/ChatResidencyHandoff.swift` (wait-idle → unload resident
  chat models → memoryPreflight → reload). A kind vends `PassthroughHandoff` when no
  swap is needed (parent/agent model, a remote override, or the same local model
  already resident); `image` keeps the passthrough default (its coordinator owns
  image-model residency).
- **`Subagent/SubagentResidency.swift`** — the **shared residency decision** every
  chat-driven kind uses (extracted from `TextSubagentKind`'s old inline block). A
  pure `decidePlan(...)` (no `ModelRuntime`/`ModelManager`, so unit-testable with no
  GPU) encodes the control flow — remote ⇒ none, same-as-resident ⇒ none,
  different-local + handoff-off ⇒ `throw .denied` (reject-before-evict), different-
  local + handoff-on ⇒ unload plan — and a live `resolve(...)` wrapper reads the
  installed bundle + resident chat models and feeds it. `handoff(for:)` maps the
  resolved plan onto the middleware (a real `ResidencyHandoff` or `PassthroughHandoff`).
- **`Subagent/SubagentModelResolution.swift`** — the **shared model-resolution
  path** for the chat-driven kinds (`spawn`, `computer_use`), so
  they no longer repeat the override-lookup → default → residency block inline. A
  pure `pickModel(eval, availableOverride, default)` (eval > available override >
  default, blanks-as-absent; unit-testable), a `@MainActor availableOverride(_:)`
  that drops a stored override that's no longer installed / not in
  `ModelPickerItemCache` (cold cache ⇒ trust the id) so a deleted model gracefully
  inherits the default, and a live `resolve(...)` that folds in the per-agent
  override + an optional **`requestedModel`** (the `spawn_model` explicit target —
  ranked above the override + default, but still run through the live residency
  decision, NOT the eval bypass) + the **eval-bypasses-residency** invariant (eval
  seam ⇒ `(isLocal:false, plan:.none)`) then calls `SubagentResidency.resolve`.
  Returns `(model, decision)`; the kind stores `decision.plan` for `makeHandoff()`.
  `image` is NOT a client (own model system).
- **`Subagent/SubagentFeed.swift`** — `SubagentFeed` / `SubagentActivityEvent` /
  `SubagentFeedRegistry` / `SubagentInterruptCenter`: one live progress + interrupt
  surface for all kinds (text spawn included). `NativeToolCallGroupView` binds it.
- **`Subagent/SubagentCapabilityRegistry.swift`** — the per-kind `SubagentCapability`
  descriptor (SSOT): `id` + `toolNames` + `gate` (+ `perAgentFlag`) + `modelSource` +
  `supportsModelOverride` + `displayLabel`/`iconName` + `guidance*`. Drives
  `resolveTools`/`ToolRegistry` gating, the AgentsView per-agent toggle + the
  registry-driven model-override row (`supportsModelOverride`; `capability(forPerAgentFlag:)`
  maps a toggle to its descriptor), the feed header + tool chip, and the prompt
  guidance loop, plus the `SubagentToolVisibility` resolver shared by the composer
  and the HTTP surface. `supportsModelOverride` is true for `computer_use` / `spawn`
  and false for `image` (which owns its own gen/edit model
  system, so it is not a `SubagentModelResolution` client). The single `spawn`
  capability carries BOTH tool names (`toolNames == ["spawn_agent", "spawn_model"]`).
- **`Subagent/SpawnDescriptors.swift`** — `SpawnAgentDescriptor` /
  `SpawnModelDescriptor` value types + a `@MainActor SpawnDescriptors.resolve` that
  turns the launching agent's spawnable AGENT names + MODEL ids (+ the user's
  per-model notes) into render-ready descriptors (locality, provider, size/quant,
  vision, agent description, note) for the dynamic guidance block. Pure values
  except the resolver, which reads `AgentManager` + `ModelPickerItemCache`.

### Dispatch / runners
- **`Tools/SpawnAgentTool.swift`** — the `spawn_agent(input, agent)` tool →
  `TextSubagentKind` in `.agent` mode. Resolves the named spawnable Agent
  (its prompt + model), checks the gates, resolves the model, runs it.
- **`Tools/SpawnModelTool.swift`** — the `spawn_model(input, model)` tool →
  `TextSubagentKind` in `.model` mode. Runs a bare spawnable model id with NO
  agent/system prompt, gated by the model pool (`spawnModelAllowed`). Both tools
  set `bypassRegistryTimeout` (the nested loop owns its deadline).
- **`Services/AgentDelegation/AgentSubagentRunner.swift`** — shared bounded text
  runner: resolve model → handoff (if local) → `AgentToolLoop.run` with the agent's
  prompt/model/tools → compact envelope. Used by `TextSubagentKind` (`local_delegate`
  is gone — its body lived here and is now spawn's only path).
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
  → `ComputerUseKind` (`modelSource = .inheritsParent` default + optional
  `computer_use` override → shared `SubagentResidency` handoff; the `VisionContext`
  is recomputed from the RESOLVED model so screenshot escalation tracks the chosen
  model; host permission `.auto`; keeps its own per-action confirm gate). Adopts the
  shared feed/registry + compact-result contract.

### Agents / config / runtime (reused, existing)
- `Models/Agent/Agent.swift` + `Managers/AgentManager.swift` — agent name/model
  (local or remote)/prompt/tool-policy; `effectiveModel(for:)`. Per-agent subagent
  fields on `AgentSettings` (custom agents): `computerUseEnabled` + `computerUseCeiling`,
  `spawnDelegationEnabled` + `spawnableAgentNames` (its `spawn_agent` allow-list) +
  `spawnableModelNames` + `spawnableModelNotes` (its `spawn_model` allow-list + the
  per-model `[modelId: note]` usage hints),
  `imageEnabled` (image is its own per-agent toggle, no longer riding the spawn flag),
  and — added 2026-06-26 — `imageGenerationModelId` / `imageEditModelId` (`String?`),
  `subagentPermissions` (`SubagentPermissionDefaults`), and `subagentBudgets`
  (`SubagentBudgets`); added 2026-06-27 — `subagentModelOverrides`
  (`[capabilityId: modelId]`, the per-capability model picker, mirroring
  `subagentPermissions`). `effectiveCapabilities(for:)` carries `imageEnabled` +
  `spawnableAgentNames` + `spawnableModelNames` + `spawnableModelNotes` through to the
  snapshot the visibility resolvers + the guidance builder read; the model /
  permission / budget fields are read live at the kind via the effective-settings
  resolvers (below).
- `Models/AgentDelegation/SubagentConfiguration.swift` + `SubagentConfigurationStore.swift`
  — the **system + Default/main-chat** config: master `agentDelegationEnabled`,
  local-handoff toggle, RAM-safety preflight, image load policy, plus the **Default /
  main-chat** values: default image gen/edit models, per-kind permission
  (`SubagentPermissionDefaults` is a `[kindId: policy]` map keyed by `capability.id`,
  ask/deny/always — a kind absent from the map defaults to `.ask`, so a new permissioned
  kind needs no new struct field), budgets, `imageDelegationEnabled`,
  `spawnableAgentNames` (the main chat's `spawn_agent` pool), — added 2026-06-28 —
  `spawnableModelNames` + `spawnableModelNotes` (the main chat's `spawn_model` pool +
  per-model usage notes; both normalized to drop blanks, notes pruned to live ids),
  and — added 2026-06-27 —
  `subagentModelOverrides` (the main chat's `[capabilityId: modelId]` map, used by
  `spawn_agent`; normalized to drop blanks). These also back the REST `/v1/images`
  default. Custom agents override the model / permission / budget values from their own
  `AgentSettings`. Persists to `agent-delegation.json`; broadcasts
  `.subagentConfigurationChanged`.
- `Subagent/SubagentCapabilityRegistry.swift` — `SubagentToolVisibility` also hosts the
  pure **effective-settings resolvers** (`effectiveImageModel` / `effectivePermission` /
  `effectiveBudgets` / `effectiveSubagentModel`): **Default → global
  `SubagentConfiguration`; custom → `AgentSettings`** (nil image model → first-ready
  fallback; missing permission → `.ask`; blank/absent model override → inherit). Each
  kind reads these so the Default-vs-custom branch lives in one tested place.
- `Services/ModelRuntime.swift` — load/unload/`preload`/`cachedModelSummaries`, the
  model-fit refusal; `Services/ModelRuntime/MetalGate.swift` — GPU owner-keyed gate.

### Surfacing
- `Tools/ToolRegistry.swift` — `agentDelegationExcludedToolNames()` applies ONLY the
  master gate to the base schema (so the base set is a superset); per-agent narrowing of
  `spawn` / `image` happens downstream in `resolveTools` / the HTTP path. The delegation
  tool-name sets are DERIVED from `SubagentCapabilityRegistry` (no hand-maintained list).
- `Views/Agent/AgentsView.swift` — per-agent subagent controls live in the dedicated
  **`DetailTab.subagents`** ("Subagents") tab, rendered registry-driven (one card per
  `SubagentCapabilityRegistry.perAgentToggleFlags` entry: `computer_use` → autonomy
  ceiling, `spawn` → permission picker + budget steppers + **two selected-first
  pickers** (spawnable agents + spawnable models), `image` → gen/edit model pickers +
  permission picker) with each card's config in an inline panel. Each spawn picker
  shows the current selection as removable chips/rows with an **"Add" button** that
  opens a searchable, grouped multi-select popover (`SearchField` + `FlowLayout`);
  spawnable-model rows carry a local/remote badge + an inline **note** field
  (`spawnableModelNotes`). The standard model-override row is rendered **generically**
  above each card's kind-specific config whenever its descriptor sets
  `supportsModelOverride` (resolved via `capability(forPerAgentFlag:)`), so the
  per-kind arms no longer hand-wire it — a new chat-driven kind gets the picker for
  free. One `subagentModelOverrideRow(_ capability:)` draws it (chat candidates from
  `pickerItems.chatModelCandidates`; the empty-tag label is derived from `modelSource` —
  "Use the agent's model" for `spawn`, else "Inherit parent model"). The tab is
  **shown for the Default agent too** (2026-06-26):
  it renders only the Spawn + Image cards (no `computer_use`), bound to the global
  `SubagentConfiguration` via `SubagentConfigurationStore` (the main chat's settings still
  live there). Custom-agent cards write `AgentSettings` via `debouncedSave()`; the main
  chat saves the global config directly.
- `Views/Settings/SubagentSettingsSection.swift` — the global Spawn tab is **system-only**
  (2026-06-26): master enable, Local Orchestrator Handoff, RAM-Safety preflight, Image
  Load Policy, and the "How it works" explainer. The Main Chat block and the per-agent
  image-model / permission / budget controls moved to the main chat's Subagents tab. It
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

- **User:** open an agent's **Subagents** tab to configure its subagents end-to-end —
  toggle `computer_use` / `spawn` / `image`, pick which agents `spawn_agent` may call
  AND which models `spawn_model` may run (two selected-first pickers; each spawnable
  model can carry a "when/how to use it" note), set the `spawn` permission + budgets, and
  pick the `image` gen/edit models + permission. The **main chat (Default agent)** has the
  same tab (Spawn + Image cards). Only true system controls — master enable, "Local
  Orchestrator Handoff", RAM-Safety, and Image Load Policy — live in Settings → Spawn.
- **Model:** sees `spawn_agent` (when an agent pool exists) and/or `spawn_model` (when a
  model pool exists) only when enabled, plus a dynamic **spawn guidance** block listing
  the reachable agents + models (locality/provider/size + the user's note). Call
  `spawn_agent({"agent": "sparky", "input": "do x y z"})` to delegate to an agent, or
  `spawn_model({"model": "qwen3-4b-4bit", "input": "do x y z"})` to run a bare model with
  no agent. Image: one `image` tool — `image({"prompt": …})` to generate, add
  `source_paths` to edit.
- **Contributor:** a new KIND = one `SubagentCapability` descriptor in
  `SubagentCapabilityRegistry` (the SSOT that drives gating + the per-agent toggle +
  the feed/chip display + the prompt guidance) + one `SubagentKind` conformer in
  `Subagent/Kinds/` whose `capability` returns that descriptor and that implements
  `resolveModel` / `permission` / `run` (override `makeHandoff()` only if it swaps
  models) + one thin tool that builds the kind and calls `SubagentSession.run`. The
  host gives you scope ids, recursion guard, feed/interrupt, the (optional) handoff,
  and the compact-result envelope for free. A chat-driven kind also gets the standard
  per-agent model picker for free by setting `supportsModelOverride = true` and
  resolving through `SubagentModelResolution.resolve(...)` (precedence + availability
  fallback + the eval-bypasses-residency invariant + the shared residency handoff); a
  dedicated model-backed kind (e.g. an AppleScript generator on a local or remote model)
  is exactly this recipe with `modelSource = .dedicatedConfigured` or `.agent`. Do NOT
  add recursive agents, helper LLMs, or shell workers inside a kind — it is normal Swift
  service code driving one bounded job.
