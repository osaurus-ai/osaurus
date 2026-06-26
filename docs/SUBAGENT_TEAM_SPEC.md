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

---

## 1. What it is

A chat turn's **orchestrator** model (local OR cloud) can run a bounded nested
**sub-agent** behind a tool call and fold its result back into the turn — input →
output, the orchestrator never sees the sub-agent transcript (only the digest/artifact).

Sub-agents are a **general framework**, not a fixed set of tools. Each **KIND**
conforms to `SubagentKind` and runs through `SubagentSession`, sharing one lifecycle
(scope ids → recursion guard → resolve → permission → [handoff] → run → compact
result → defer-cleanup):

| Kind | Tool | Runner | Returns | needsHandoff |
|------|------|--------|---------|--------------|
| `TextSubagentKind` | `spawn` | `AgentSubagentRunner` → `AgentToolLoop` on a persona's model | text digest | yes |
| `ImageSubagentKind` | `image` | `NativeImageJobCoordinator` → `ImageGenerationService` (vMLXFlux); `source_paths` ⇒ edit | artifact | yes |
| `ComputerUseKind` | `computer_use` | `ComputerUseLoop` (+ per-action confirm gate) | summary | no |
| `SandboxReduceKind` | `sandbox_reduce` | `AgentToolLoop` with a read/search/exec allowlist | digest | no |
| privacy loop · code exec · browser · … | — | their own kind | their result | future |

Reuse, don't reinvent: `AgentToolLoop` (`Services/Chat/AgentToolLoop.swift`),
`sandbox_reduce` (`docs/REDUCTION_SUBAGENT.md`), Computer Use Subagent (PR #1578).
A new kind = one file in `Subagent/Kinds/` + one registry entry in
`SubagentCapabilityRegistry` — nothing else to touch.

## 2. Gating — DEFAULT OFF, two switches

1. **Global:** `SubagentConfiguration.agentDelegationEnabled` (the flag kept its name
   through the type rename).
2. **Per-agent:** `Agent.spawnDelegationEnabled` (default `false`) — whether THIS agent
   may use the sub-agent tools at all. Spawn *targets* are gated separately by
   `SubagentConfiguration.spawnableAgentNames`: a persona is reachable via `spawn` ONLY
   when its owner lists it spawnable. A model can never reach an arbitrary local model —
   only opted-in agents.

Both the native chat composer (`SystemPromptComposer.resolveTools`) and the HTTP
agent-run surface (`HTTPHandler.enrichWithAgentContext`) resolve the visible sub-agent
tool set through the SAME `SubagentToolVisibility` resolver, so the two surfaces can
never drift (the BUG E regression guard).

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
  protocol (`needsHandoff`, `resolveModel`, `permission`, `run`) and its conformers:
  `TextSubagentKind`, `ImageSubagentKind`, `ComputerUseKind`, `SandboxReduceKind`.
- **`Subagent/ResidencyHandoff.swift`** — the optional handoff middleware
  (`SubagentHandoff`); only `needsHandoff = true` kinds (`spawn`, `image`) use it. It
  builds on `Services/AgentDelegation/ChatResidencyHandoff.swift` (wait-idle → unload
  resident chat models → memoryPreflight → reload). Same-model kinds skip it.
- **`Subagent/SubagentFeed.swift`** — `SubagentFeed` / `SubagentActivityEvent` /
  `SubagentFeedRegistry` / `SubagentInterruptCenter`: one live progress + interrupt
  surface for all kinds (text spawn included). `NativeToolCallGroupView` binds it.
- **`Subagent/SubagentCapabilityRegistry.swift`** — capability flag → tool name(s) +
  guidance prompt, plus the `SubagentToolVisibility` resolver shared by the composer
  and the HTTP surface.

### Dispatch / runners
- **`Tools/SpawnTool.swift`** — the `spawn(agent, input)` tool → `TextSubagentKind`.
  Resolves the named Agent persona, checks the gates, resolves the model, runs it.
- **`Services/AgentDelegation/AgentSubagentRunner.swift`** — shared bounded text
  runner: resolve model → handoff (if local) → `AgentToolLoop.run` with the persona's
  prompt/model/tools → compact envelope. Used by `TextSubagentKind` (`local_delegate`
  is gone — its body lived here and is now spawn's only path).
- **`Tools/SandboxReduceTool.swift`** — the `sandbox_reduce` tool → `SandboxReduceKind`
  (read/search/exec allowlist on `AgentToolLoop`, `needsHandoff = false`).
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
  → `ComputerUseKind` (`needsHandoff = false`, host permission `.auto`; keeps its own
  per-action confirm gate). Adopts the shared feed/registry + compact-result contract.

### Personas / config / runtime (reused, existing)
- `Models/Agent/Agent.swift` + `Managers/AgentManager.swift` — persona name/model
  (local or remote)/prompt/tool-policy; `effectiveModel(for:)`; per-agent
  `spawnDelegationEnabled`.
- `Models/AgentDelegation/SubagentConfiguration.swift` + `SubagentConfigurationStore.swift`
  — global enable, load policy, permission (`spawn`/`image` ask/deny/always), budgets,
  the local-handoff toggle, RAM-safety preflight. Persists to `agent-delegation.json`;
  broadcasts `.subagentConfigurationChanged`.
- `Services/ModelRuntime.swift` — load/unload/`preload`/`cachedModelSummaries`, the
  model-fit refusal; `Services/ModelRuntime/MetalGate.swift` — GPU owner-keyed gate.

### Surfacing
- `Tools/ToolRegistry.swift` — exposes `spawn` / `image` (and `computer_use`,
  `sandbox_reduce`) only when the gates pass; an `agent` enum of spawnable personas.
  Optional alias tools (`configure_osaurus(input)` = sugar for
  `spawn("configure_osaurus", input)`).
- `Views/Settings/SubagentSettingsSection.swift` + the `SpawnSettingsView` sidebar page
  render the grouped settings; both bind the one store and sync via
  `.subagentConfigurationChanged`.

## 5. Lifecycle & progress (summary; full detail in DESIGN §8)

`received → resolving_model → permission → waiting_for_chat_idle →
unloading_chat_models → loading_subagent → running → unloading_subagent →
restoring_chat_models → done`. Every phase emits a progress event so the UI shows
the swap ("Unloading… / Loading sparky… / Running… / Reloading…"), never a frozen
turn. Cache: orchestrator KV/prefix dropped on unload (cold resume; L2 block-disk
survives for a warm resume); per-model tokenizer/template; image jobs surface a
denoise step counter (k/N). Re-entrancy: a subprocess cannot `spawn`.

## 6. Usage

- **User:** mark an Agent **spawnable** in its editor; it gets its own model
  (local/remote), prompt, tools. Set per-job permission (`spawn`/`image`
  ask/deny/always) + the "Local Orchestrator Handoff" toggle + budgets in the Spawn &
  Sub-agents settings.
- **Model:** sees `spawn` (and any alias tools) only when enabled. `spawn("sparky",
  "do x y z")`. Image: one `image` tool — `image({"prompt": …})` to generate, add
  `source_paths` to edit.
- **Contributor:** a new KIND = one `SubagentKind` conformer in `Subagent/Kinds/`
  (`needsHandoff` / `resolveModel` / `permission` / `run`) + one entry in
  `SubagentCapabilityRegistry`; the `SubagentSession` host gives you scope ids,
  recursion guard, feed/interrupt, handoff, and the compact-result envelope for free.
  Do NOT add recursive agents, helper LLMs, or shell workers inside a kind — it is
  normal Swift service code driving one bounded job.
