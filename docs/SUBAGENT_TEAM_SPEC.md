# Spawn — Team Spec, Wiring & Usage

Audience: osaurus contributors. **Canonical design + operational nuances:**
[`SUBAGENT_PORTABLE_DESIGN.md`](SUBAGENT_PORTABLE_DESIGN.md). **Status/TODO + test
matrix:** [`SUBAGENT_ORCHESTRATION_STATUS.md`](SUBAGENT_ORCHESTRATION_STATUS.md).
This file is the spec + wiring contract for the current build.

---

## 1. What it is

A chat turn's **orchestrator** model (local OR cloud) can **`spawn`** a bounded
subprocess behind an alias and fold its result back into the turn — input → output,
the orchestrator never sees the subprocess transcript (only the digest/artifact).

`spawn` is a **general process-spawning framework**, not a fixed set of tools. Each
**KIND** registers a runner that shares one lifecycle (resolve → [handoff] → run →
result):

| Kind | Runner | Returns | Status |
|------|--------|---------|--------|
| text/coding agent | `AgentToolLoop` on a user-configured Agent persona's model | text digest | built (`local_delegate`; generalizing to `spawn`) |
| image generate | `ImageGenerationService` → vMLXFlux | artifact | built |
| image edit | `ImageGenerationService` → vMLXFlux | artifact | built |
| privacy loop | local-only model, sensitive-in → result-only | scrubbed result | planned |
| code exec / browser / … | their own runner | their result | future |

Reuse, don't reinvent: `AgentToolLoop` (`Services/Chat/AgentToolLoop.swift`),
`sandbox_reduce` (`docs/REDUCTION_SUBAGENT.md`), Computer Use Subagent (PR #1578).

## 2. Gating — DEFAULT OFF, two switches

1. **Global:** `AgentDelegationConfiguration.agentDelegationEnabled`.
2. **Per-agent:** `Agent.spawnable` (default `false`). A persona is reachable via
   `spawn` ONLY when its owner marks it spawnable. A model can never reach an
   arbitrary local model — only opted-in agents.

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

### Dispatch / runner
- **`Tools/SpawnTool.swift`** — the `spawn(agent, input)` tool. Resolves the named
  Agent persona, checks both gates, resolves the model, and runs it. (Being built.)
- **`Services/AgentDelegation/AgentSubagentRunner.swift`** — shared bounded runner:
  resolve model → `ChatResidencyHandoff` (if local handoff) → `AgentToolLoop.run`
  with the persona's prompt/model/tools → compact envelope. Both `spawn` and
  `local_delegate` call it. (Being built — extracted from `LocalTextDelegateTool`.)
- `Services/AgentDelegation/ChatResidencyHandoff.swift` — wait-idle → unload
  resident chat models → reload. The reusable handoff core.
- `Services/Chat/AgentToolLoop.swift` — the bounded loop driver (reused).

### Image kinds (engine-specific, same handoff/progress)
- `Tools/NativeImageTools.swift` — `image_generate` / `image_edit`.
- `Services/AgentDelegation/NativeImageJobCoordinator.swift` — image handoff +
  vMLXFlux + progress; `NativeImageJobModelResolver` (strict, pre-residency).
- `Services/ModelRuntime/ImageGenerationService.swift` — the only `vMLXFlux` import,
  held in `MetalGate("image")`.

### Personas / config / runtime (reused, existing)
- `Models/Agent/Agent.swift` + `Managers/AgentManager.swift` — persona name/model
  (local or remote)/prompt/tool-policy; `effectiveModel(for:)`. **New: `spawnable`.**
- `Models/AgentDelegation/AgentDelegationConfiguration.swift` — global enable, load
  policy, permission (ask/deny/always), budgets, the local-handoff toggle.
- `Services/ModelRuntime.swift` — load/unload/`preload`/`cachedModelSummaries`, the
  model-fit refusal; `Services/ModelRuntime/MetalGate.swift` — GPU owner-keyed gate.

### Surfacing
- `Tools/ToolRegistry.swift` — exposes `spawn` (and image tools) only when the gates
  pass; an `agent` enum of spawnable personas. Optional alias tools
  (`configure_osaurus(input)` = sugar for `spawn("configure_osaurus", input)`).

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
  (local/remote), prompt, tools. Set per-job permission (ask/deny/always) + the
  "Local Orchestrator Handoff" toggle + budgets in Agent Delegation settings.
- **Model:** sees `spawn` (and any alias tools) only when enabled. `spawn("sparky",
  "do x y z")`. Image: `image_generate` / `image_edit` when enabled.
- **Contributor:** a new KIND = a runner that implements resolve→[handoff]→run→
  result; plug into the dispatch. Do NOT add recursive agents, helper LLMs, or
  shell workers inside a coordinator — it is normal Swift service code driving one
  bounded job.
