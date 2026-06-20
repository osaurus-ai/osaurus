# Portable Subagent Machine — `call_agent` Design

> Direction (team, 2026-06-20): "create a portable subagent machine. subagent is
> input → output, aliased behind a tool-call name. `call_agent('sparky', 'do x')`,
> and the user configures sparky with specific local/remote model settings.
> Piggyback on the agents system. → general sub-process spawning modules."

This generalizes the current hardcoded `local_delegate` / `image_*` tools into one
configurable primitive. Almost everything needed already exists.

---

## 1. The machine

A subagent is just **input → output behind an alias**:

```
call_agent(name: "sparky", query: "user wants to add an MCP config")
  → resolve persona "sparky"  (AgentManager — already user-configurable)
  → resolve its model         (local OR remote/provider)
  → [if local model & local orchestrator] ChatResidencyHandoff: unload orchestrator
  → bounded AgentToolLoop run (persona systemPrompt + model + tool policy, query)
  → [reload orchestrator]
  → compact result string → orchestrator turn continues
```

The orchestrator never sees the subagent's transcript — only the digest. Same
contract as `sandbox_reduce` and the `local_delegate` we just built; this is the
generic version.

## 2. Piggyback on the agents system (already there)

An `Agent` persona (`Models/Agent/Agent.swift`, managed by `AgentManager`) already
carries exactly what a subagent needs:

| Need | Existing field |
|------|----------------|
| alias / name | `Agent.name` |
| model (local or remote) | `Agent.defaultModel` → `AgentManager.effectiveModel(for:)` |
| prompt | `Agent.systemPrompt` |
| tool policy | `Agent.toolSelectionMode` + `manualToolNames` + `toolsEnabled` |
| temperature | `Agent.temperature` |
| identity | `Agent.id` |

So "user configures sparky with specific local/remote model settings" = **the
existing Agent editor**. No new config store — a subagent *is* an Agent persona
marked callable.

## 3. Surfacing — two shapes, both cheap

1. **Generic:** one `call_agent` tool with `name` constrained to an enum of the
   user's callable agents, plus a free `query`. The model picks the agent.
2. **Aliased:** auto-generate a named tool per callable agent —
   `configure_osaurus(query)` is sugar for `call_agent("configure_osaurus", query)`.
   Eric's "alias behind a tool-call name." Lets users *pre-configure and inject as
   context*: each alias appears in the schema with the agent's description.

Both compile down to the same runner. Start with #1 (generic), add #2 (alias tools)
as a thin schema-generation layer over the same dispatch.

## 4. Reuse map (what's built vs new)

| Piece | Status |
|-------|--------|
| Bounded loop runner | ✅ `AgentToolLoop.run` |
| Local-orchestrator handoff (unload→load→reload) | ✅ `ChatResidencyHandoff` (this branch) |
| Per-persona model/prompt/tools | ✅ `Agent` + `AgentManager` |
| Compact-result envelope + budgets + permission | ✅ `LocalTextDelegateTool` (becomes a special case of `call_agent`) |
| Model-fit RAM refusal | ✅ inside `ModelRuntime.load` |
| **`call_agent` tool + persona→loop dispatch** | 🔴 new (small — wires the above together) |
| **"callable" flag + alias-tool schema generation** | 🔴 new |
| **Handoff for remote vs local vs same-model** | 🟡 generalize the 3 cases (local→handoff, remote→none, same-model→none) |

## 5. The runner (generalize `LocalTextDelegateTool`)

```
func runAgent(name, query):
    persona = AgentManager.shared.agent(named: name)            // 404 if unknown/not callable
    model   = AgentManager.shared.effectiveModel(for: persona.id)
    isLocal = ModelManager.findInstalledModel(named: model) != nil
    orchestratorIsLocal = parentUsesLocalModel()
    sameAsOrchestrator  = (model == activeChatModel)

    lease = .empty
    if isLocal && orchestratorIsLocal && !sameAsOrchestrator && handoffEnabled:
        lease = ChatResidencyHandoff.unloadResidentChatModels(...)
    defer-ish: ChatResidencyHandoff.restore(lease)   // on every exit
    result = AgentToolLoop.run(systemPrompt: persona.systemPrompt,
                               model: model, toolPolicy: persona.toolPolicy,
                               input: query, budgets: ...)
    return compactEnvelope(result)
```

- `local_delegate` = `call_agent` against an implicit "default local delegate"
  persona; keep it as an alias for back-compat.
- **Image gen/edit stay specific** (they're a different engine — vMLXFlux, not an
  AgentToolLoop text run) but route through the *same* handoff
  (`NativeImageJobCoordinator` already does). Optionally expose them as callable
  "agents" later for a uniform surface.

## 6. Safety / contracts (unchanged, reused)
- Single-residency handoff + `ModelRuntime` load-refusal = RAM safety.
- Re-entrancy guard: a subagent cannot call `call_agent` (mirror
  `LocalTextDelegateContext.isActive`).
- Permission: per-callable-agent ask/deny/always (extend AgentDelegation
  permission defaults, keyed by agent or job kind).
- Budgets: tokens/turns/elapsed from AgentDelegation settings.

## 7. Build order
1. `call_agent` tool + `AgentSubagentRunner` (generalize `LocalTextDelegateTool`'s
   body; both call it). Generic enum-of-agents surface.
2. Mark agents "callable"; generate alias tools (`configure_osaurus`, `sparky`).
3. Generalize the handoff cases (local/remote/same-model).
4. Permission + budgets per callable agent.
5. e2e matrix (per SUBAGENT_ORCHESTRATION_STATUS.md §5) extended: cloud/local
   orchestrator × {generic call_agent, aliased tool} × {local, remote subagent
   model}, handoff-then-multiturn coherence, RAM.
