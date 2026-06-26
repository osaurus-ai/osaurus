# Spawn — Portable Process-Spawning Framework

> Direction (team, 2026-06-20): "create a portable subagent machine. subagent is
> input → output, aliased behind a tool-call name. `spawn('sparky', 'do x')`,
> and the user configures sparky with specific local/remote model settings.
> Piggyback on the agents system. → general sub-process spawning modules."

This generalizes the current hardcoded `local_delegate` / `image_*` tools into one
configurable primitive. Almost everything needed already exists.

---


## 0. Name, feature flag & scope (2026-06-20)

**Name:** the primitive is **`spawn(name, input)`** — "spawn a bounded process
behind an alias." (`invoke` was the alternative; `spawn` chosen because this
generalizes to MANY process kinds, not just chat agents.) Working name.

**Feature flag — DEFAULT OFF, PER AGENT (tpae):** spawning is gated two ways and
both must be on:
1. A **global** Agent Delegation / Spawn enable (`agentDelegationEnabled`, exists).
2. A **per-agent `spawnable` flag** (new `Agent` field, default `false`). A persona
   is reachable via `spawn` ONLY when its owner explicitly marks it spawnable — a
   model can never reach arbitrary local models, only ones the user opted in.

**Scope — many kinds of process spawning:** `spawn` is a general process-spawning
framework, not only text agents. Each KIND registers a runner that shares the same
lifecycle (handoff + progress + permission + budgets) but produces its own result:

| Kind | Runner | Returns | Status |
|------|--------|---------|--------|
| text/coding agent | `AgentToolLoop` on the persona's model | text digest | built (as `local_delegate`) |
| image generate | `ImageGenerationService` (vMLXFlux) | artifact | built |
| image edit | `ImageGenerationService` (vMLXFlux) | artifact | built |
| **privacy loop** | local model, sensitive-in → result-only | scrubbed result | future |
| code exec / browser / … | their own runner | their result | future |

Design the dispatch around a **`Spawnable` kind protocol** (resolve model →
[handoff] → run → result), so new kinds plug in without touching the orchestrator
or the handoff/progress machinery.

**Privacy loop (future, tpae):** a kind where a LOCAL model performs sensitive
work and returns ONLY the result — the coordinator (especially a cloud
orchestrator) never sees the sensitive input or transcript. The **spawn boundary
becomes a privacy boundary**: sensitive context stays local-only, and the digest
that crosses back is result-only/scrubbed. Builds on the existing
`PrivacyFilterPipeline` + the `compact_result_only` sharing policy.

---

## 1. The machine

A subagent is just **input → output behind an alias**:

```
spawn(name: "sparky", query: "user wants to add an MCP config")
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
| **spawnable (opt-in)** | **`Agent.spawnable` — NEW field, default `false`** |

So "user configures sparky with specific local/remote model settings" = **the
existing Agent editor**. No new config store — a subagent *is* an Agent persona
marked callable.

## 3. Surfacing — two shapes, both cheap

1. **Generic:** one `spawn` tool with `name` constrained to an enum of the
   user's callable agents, plus a free `query`. The model picks the agent.
2. **Aliased:** auto-generate a named tool per callable agent —
   `configure_osaurus(query)` is sugar for `spawn("configure_osaurus", query)`.
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
| Compact-result envelope + budgets + permission | ✅ `LocalTextDelegateTool` (becomes a special case of `spawn`) |
| Model-fit RAM refusal | ✅ inside `ModelRuntime.load` |
| **`spawn` tool + persona→loop dispatch** | 🔴 new (small — wires the above together) |
| **per-agent `spawnable` flag (default off) + alias-tool schema gen** | 🔴 new |
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

- `local_delegate` = `spawn` against an implicit "default local delegate"
  persona; keep it as an alias for back-compat.
- **Image gen/edit stay specific** (they're a different engine — vMLXFlux, not an
  AgentToolLoop text run) but route through the *same* handoff
  (`NativeImageJobCoordinator` already does). Optionally expose them as callable
  "agents" later for a uniform surface.

## 6. Safety / contracts (unchanged, reused)
- Single-residency handoff + `ModelRuntime` load-refusal = RAM safety.
- Re-entrancy guard: a subagent cannot call `spawn` (mirror
  `LocalTextDelegateContext.isActive`).
- Permission: per-callable-agent ask/deny/always (extend AgentDelegation
  permission defaults, keyed by agent or job kind).
- Budgets: tokens/turns/elapsed from AgentDelegation settings.

## 7. Build order
1. `spawn` tool + `AgentSubagentRunner` (generalize `LocalTextDelegateTool`'s
   body; both call it). Generic enum-of-agents surface.
2. Add the per-agent `spawnable` flag (default off); generate alias tools (`configure_osaurus`, `sparky`).
3. Generalize the handoff cases (local/remote/same-model).
4. Permission + budgets per callable agent.
5. e2e matrix (per SUBAGENT_ORCHESTRATION_STATUS.md §5) extended: cloud/local
   orchestrator × {generic spawn, aliased tool} × {local, remote subagent
   model}, handoff-then-multiturn coherence, RAM.

---

# 8. Operational lifecycle, progress & nuances (read before building the runner)

A subagent job is a **state machine** with explicit load/unload boundaries. Every
phase must emit a progress event (so the UI never looks frozen during a model
swap) and every failure path must restore the orchestrator. Phases below unify the
text (`AgentToolLoop`) and image (`vMLXFlux`) jobs.

## 8.1 Phase timeline (load → start → run → done → unload → restore)

| # | Phase (event id) | Owner | What happens | Can fail with |
|---|------------------|-------|--------------|---------------|
| 1 | `received` | tool dispatch | parse args, resolve agent/job | bad args |
| 2 | `resolving_model` | resolver | resolve subagent model; **reject stale/incomplete/wrong-kind BEFORE touching residency** (no pointless eviction) | model missing/incomplete |
| 3 | `permission` | permission policy | ask/deny/always; prompt shows the *resolved* model + allows switch | denied |
| 4 | `waiting_for_chat_idle` | `InferenceLoadCoordinator.waitForChatIdle` | wait for the orchestrator's in-flight generation to fully drain | chat-busy timeout |
| 5 | `unloading_chat_models` | `ChatResidencyHandoff` | unload resident orchestrator model(s) — **local orchestrator only** | — |
| 6 | `loading_subagent` | `ModelRuntime.load` / engine load | weight dequant + kernel compile under `MetalGate("load:<m>")`; **model-fit RAM refusal happens here** | won't-fit refusal |
| 7 | `running` | `AgentToolLoop` (text) / `ImageGenerationService` (image) | the job; sub-indicators below | loop/engine error, cancel, budget |
| 8 | `unloading_subagent` | runtime | unload per load policy (`unload_after_job` / `keep_warm_when_safe` / `strict_single_job`) | — |
| 9 | `restoring_chat_models` | `ChatResidencyHandoff.restore` | `ModelRuntime.preload` the orchestrator back | reload failure (surface, do not swallow) |
| 10 | `done` / `failed` / `cancelled` | tool dispatch | return compact digest (text) or artifact (image) | — |

**Invariants:**
- Phases 5 & 9 are paired: if 5 ran, 9 MUST run on every exit (success, error,
  cancel) — the orchestrator is never left unloaded. (Implemented in
  `LocalTextDelegateTool` via restore on both the success and `catch` paths.)
- Cloud orchestrator → phases 4,5,9 are no-ops (nothing resident; lease empty).
- Same-model subagent (agent uses the orchestrator's model) → no swap; skip 5/6/8/9.
- Never unload during an active generation (phase 4 gates this) — tearing down a
  KV/SSM cache mid-eval is the `MTLCommandBuffer addCompletedHandler` / SSM-cache
  crash class (task #34); `MetalGate`'s `load:<m>` exclusive owner is the backstop.

## 8.2 Cache processing across the handoff

- **Orchestrator KV cache + in-RAM prefix cache are dropped on unload (phase 5).**
  After reload (phase 9) the orchestrator resumes with a **cold cache**: the next
  turn re-prefills the conversation prefix → higher TTFT on the resume turn. This
  is expected; surface it (the resume turn shows prefill progress, not a hang).
- **L2 block-disk cache (`cache.blockDisk`) can survive the unload** (it is
  disk-backed, keyed by prefix hash). If enabled, the resume turn can hit the
  stored K,V for the unchanged prefix and skip a full re-prefill — the main
  mitigation for handoff latency. Recommend documenting "enable block-disk cache
  for snappier resume after a subagent job."
- **Prefix-cache correctness:** the resume prefix is the SAME conversation, so the
  prefix hash matches → safe reuse. Do not reuse across different models (each
  model's K,V is its own; the handoff swaps models, so the subagent never reads the
  orchestrator's cache and vice-versa).
- The **subagent's** cache is ephemeral: created on load, discarded on unload
  (bounded run). With `keep_warm_when_safe`, the subagent stays resident and keeps
  its prefix cache for back-to-back jobs (only when RAM allows).
- Must wait for chat idle (phase 4) so no cache-store eval is in flight when we
  unload — see invariant above.

## 8.3 Tokenizer & template nuances

- **Each model owns its tokenizer + chat template.** The handoff swaps models, so
  the active tokenizer/template swaps too. The subagent renders `systemPrompt +
  query` with the **subagent's** template and tokenizes with the **subagent's**
  tokenizer; the orchestrator does likewise for the returned digest.
- The digest crossing the boundary is **plain text** — re-tokenized by whoever
  reads it. No token-id is shared across models (correct; token ids are
  model-specific).
- **Template correctness is per-model and load-bearing** (lessons from the
  Laguna/Qwen3 work): a fallback/minimal chat template must emit its own BOS
  (`applyChatTemplate` tokenizes with `add_special_tokens=false`), and tool-call
  format is detected from the model's own template (`ParserResolution.toolCall` →
  `.json`/`.xmlFunction`). If the subagent uses tools, its tool-format detection
  applies independently of the orchestrator's.
- A subagent that's a heavy reasoner (e.g. VibeThinker-class) needs an adequate
  token budget or it consumes the budget in `<think>` and returns no digest —
  budgets (§6) must account for thinking.
- Re-entrancy: a subagent must not call `spawn` (mirror
  `LocalTextDelegateContext.isActive`), or tokenizer/model thrash compounds.

## 8.4 Image generation/edit process (vMLXFlux) — phases & indicators

The image job is engine-specific (not an `AgentToolLoop` text run) but rides the
SAME phase 4/5/9 handoff and the same progress center.

1. **load image model** (phase 6) — `MetalGate("image")` exclusive; weight load.
2. **text-encode** the prompt (CLIP/T5 text encoder → conditioning embeddings).
3. **edit only:** VAE-encode the source image → latents (requires the resolved
   source artifact/path; resolve & read AFTER permission, never before).
4. **denoise loop** — N steps; **each step is one MLX eval**. The **step counter
   (k / N)** is the primary progress indicator; emit a frame per step (this is the
   prefill-progress-frame pattern — block-diffusion emitting no frames was the
   frozen-counter bug, task #39).
5. **VAE-decode** latents → pixels — a heavy terminal eval; the `MetalGate("image")`
   lease is held across it (don't release on the last `.step` event).
6. **write artifact** (path/id) → unload (phase 8).
7. result is an **artifact**, surfaced as an image card (UI: image chips,
   copy/save-with-reveal toasts) — not a text digest.

Indicators to surface: phase label (`encoding` / `denoising k/N` / `decoding`),
elapsed, the resolved image model, and whether a chat model was unloaded/restored.

## 8.5 Progress status surface (so load/unload/run is visible)

- `NativeImageJobProgressCenter.post(...)` already emits phase events tagged with
  `session_id` / `assistant_turn_id` / `tool_call_id` → the chat progress row. The
  generic `spawn` runner should post the SAME-shaped events for text jobs:
  `waiting_for_chat_idle` → `unloading_chat_models` → `loading_subagent` →
  `running (iteration k)` → `unloading_subagent` → `restoring_chat_models` → `done`.
- The user must SEE the swap: "Unloading chat model… / Loading sparky… / Running… /
  Reloading chat model…", not a frozen turn. This is a hard requirement of the
  handoff — a multi-second model swap with no indicator reads as a hang.
- Tool-call json must not leak into visible content during a subagent's tool use
  (the remote UI commit "strip leaked tool-call json from assistant display content"
  handles the orchestrator side; the subagent's loop already consumes its own tool
  calls).

## 8.6 What to verify for each nuance (extends STATUS §5 matrix)
- Resume coherence: after handoff+reload, orchestrator multiturn is coherent and
  the resume turn's prefill (cold vs L2-warm) is correct — run with block-disk
  cache ON and OFF.
- Tokenizer/template: subagent on a DIFFERENT family than the orchestrator
  (e.g. local qwen3 orchestrator → gemma subagent) returns a clean digest; tools
  on the subagent parse correctly.
- Image: step counter advances (no frozen counter), edit reads the right source,
  artifact renders, MetalGate never overlaps (no SIGABRT) during a job that also
  triggers a model load.
- Progress: every phase emits an event; UI shows the swap; no frozen turn.
