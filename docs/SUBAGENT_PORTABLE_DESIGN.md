# Spawn — Portable Process-Spawning Framework

> Direction (team, 2026-06-20): "create a portable subagent machine. subagent is
> input → output, aliased behind a tool-call name. `spawn('sparky', 'do x')`,
> and the user configures sparky with specific local/remote model settings.
> Piggyback on the agents system. → general sub-process spawning modules."

This generalizes the current hardcoded `local_delegate` / `image_*` tools into one
configurable primitive. Almost everything needed already exists.

> **Implemented (2026-06-25).** This design shipped as the unified `Subagent*`
> framework. The `Spawnable` kind protocol below is **`SubagentKind`**
> (`Subagent/SubagentKind.swift`); the shared lifecycle (resolve → [handoff] → run →
> result, with scope ids, recursion guard, feed, and compact result) is the
> **`SubagentSession`** host (`Subagent/SubagentSession.swift`). Three kinds ship:
> `TextSubagentKind` (the spawn family — `spawn_agent` + `spawn_model`),
> `ImageSubagentKind` (one `image` tool, `source_paths` ⇒
> edit), `ComputerUseKind`. Surface changes from this doc:
> **`local_delegate` is removed (folded into `spawn`)** and **`image_generate` +
> `image_edit` are merged into `image`**; the handoff is **`ResidencyHandoff`** and the
> config/store/section are renamed `AgentDelegation*` → `Subagent*` (the
> `agentDelegationEnabled` / `Agent.spawnDelegationEnabled` flag names were kept). The
> §0/§4 "built (as `local_delegate`)" rows and the §5 "keep it as an alias for
> back-compat" note are superseded — pre-release, so there are no back-compat shims.
> The **privacy loop** and other future kinds remain valid: add one `SubagentKind` +
> one `SubagentCapabilityRegistry` entry. See SUBAGENT_TEAM_SPEC.md §4 for the shipped
> wiring.
>
> **Registry is the SSOT (2026-06-25 unification).** The `SubagentCapability`
> descriptor in `SubagentCapabilityRegistry` is the single per-kind value every
> surface reads — `resolveTools` + `ToolRegistry` gating, the AgentsView per-agent
> toggle, the live-feed header + tool chip (`displayLabel`/`iconName`), and the
> system-prompt guidance loop — and each kind's `capability` returns its own entry,
> so kind and descriptor are literally one object. The descriptor adds a
> **`modelSource`** axis — `.dedicatedConfigured` (image: own configured default +
> coordinator-owned residency), `.agent` (spawn: a chosen agent's local/remote
> model; the kind runs the residency handoff), `.inheritsParent` (computer_use:
> the parent model is the DEFAULT) — that documents the local-vs-remote
> model axis a future dedicated model-backed kind (e.g. an AppleScript generator)
> drops into. The vestigial `needsHandoff` protocol field is gone: intent is expressed
> by `modelSource`, and the actual swap is whether the kind overrides `makeHandoff()`
> (default `PassthroughHandoff`).
>
> **Standard model picker + shared residency (2026-06-27).** `modelSource` is the
> kind's **default** source only; picking the model a subagent runs on is now a
> standard, override-aware axis. A per-capability override map —
> `subagentModelOverrides[capabilityId]` on `AgentSettings` (custom) /
> `SubagentConfiguration` (main chat), read by the single resolver
> `SubagentToolVisibility.effectiveSubagentModel(...)` — supersedes the default for
> `computer_use` and `spawn` (the `spawn_agent` path; `spawn_model` resolves an
> explicit `requestedModel` target instead). The two chat-driven kinds share
> ONE resolution path, **`Subagent/SubagentModelResolution.swift`**, instead of
> repeating the lookup/fallback/residency block: a pure
> `pickModel(eval, availableOverride, default)` (precedence eval seam > available
> override > kind default, blanks-as-absent, unit-testable), a
> `@MainActor availableOverride(_:)` that **falls back to the default** when the
> stored override is no longer installed / not in `ModelPickerItemCache` (cold cache
> ⇒ trust the id) so a deleted model never hard-fails, and a live `resolve(...)`
> that enforces the **eval-bypasses-residency invariant** (eval seam ⇒
> `(isLocal:false, plan:.none)`, so deterministic lanes never depend on live GPU
> residency) then delegates the swap to `Subagent/SubagentResidency.swift`. That
> residency layer — a pure `decidePlan(...)` (no GPU, unit-testable) + a live
> `resolve(...)` wrapper — implements "different local model than the resident chat
> model ⇒ unload/reload, reject-before-evict when the handoff is off." So the
> **resolved** model (not the static `modelSource`) drives the handoff:
> `computer_use` keeps `.inheritsParent` (preserving the registry
> assertions) yet vends a real `ResidencyHandoff` when an override selects a different
> local model. The picker is **registry-driven** via
> `SubagentCapability.supportsModelOverride` (true for `computer_use` / `spawn`):
> AgentsView renders the standard override row for any capability
> with the flag set, with the empty-tag label derived from `modelSource`. `image`
> sets `supportsModelOverride = false` and is **deliberately divergent** — it owns
> its own model system (separate gen/edit ids via `effectiveImageModel`, readiness +
> "first ready" fallback, coordinator-owned residency) and is NOT a
> `SubagentModelResolution` client. **Add-a-kind recipe:** (1) add a
> `SubagentCapability` to the registry's `all` (set `supportsModelOverride = true`
> for a chat-driven kind to get the picker for free), (2) write the `SubagentKind`
> conformer that returns it and resolves through `SubagentModelResolution.resolve`,
> (3) add a thin tool that builds the kind and calls `SubagentSession.run`. Per-kind
> permission lives in `SubagentPermissionDefaults`, now a `[kindId: policy]` map keyed
> by `capability.id` (legacy top-level `spawn`/`image` keys migrate on decode), so a
> new permissioned kind needs no new config field — it reads/writes its own id.
>
> **IA reorg + per-capability per-agent split (2026-06-25).** The per-agent subagent
> controls moved out of the crowded Configure → Features list into a dedicated
> **`DetailTab.subagents`** ("Subagents") tab, rendered registry-driven (one card per
> `SubagentCapabilityRegistry.perAgentToggleFlags` entry, config inline in a
> DisclosureGroup); the tab is hidden for the Default agent. Each capability is now
> **independently per-agent**: `image` got its own `PerAgentFlag.image` /
> `AgentSettings.imageEnabled` (it no longer rides the spawn flag), and `spawn` got a
> per-agent `AgentSettings.spawnableAgentNames` allow-list. The §0.2 "per-agent
> `spawnable` flag" below is therefore now a **per-agent toggle + per-agent target
> list** for custom agents. The **Default agent stays governed by global Settings**:
> `SubagentConfiguration` keeps the system fields plus the Default-only
> `imageDelegationEnabled` + `spawnableAgentNames` (its pool). The Default-vs-custom
> resolution per capability lives in `SubagentToolVisibility` (`spawnAgentAvailable` /
> `spawnModelAvailable` / `imageAvailable` / `spawnTargetAllowed` / `spawnModelAllowed` /
> `visibleDelegationToolNames`), all ANDed with
> the master switch; `ToolRegistry`'s base schema applies only the master gate so the
> base set is a superset narrowed where the agent is known. Global Settings → Spawn is
> split into **System** + **Main Chat (Default Agent)** blocks.
>
> **Full per-agent settings + unified main-chat tab (2026-06-26, supersedes the two
> sentences above about the hidden Default tab + the split Spawn page).** The split made
> the *enable* per-agent but left each capability's **model / permission / budget** in
> global Settings. This pass moves them per-agent too: new `AgentSettings` fields
> `imageGenerationModelId` / `imageEditModelId` / `subagentPermissions` /
> `subagentBudgets`, read live at the kind through pure resolvers
> (`SubagentToolVisibility.effectiveImageModel` / `effectivePermission` /
> `effectiveBudgets`: Default → global config, custom → `AgentSettings`). The Subagents
> tab is **un-hidden for the Default agent** and renders Spawn + Image cards bound to the
> global `SubagentConfiguration` (a UI move — the main chat's settings still persist
> there), so the main chat is consistent with custom agents. Global Settings → Spawn is
> now **system-only** (master enable · handoff · RAM-safety · image load policy). The
> in-prompt first-use image-model picker (see §8.1 phase 3) is removed — the model is
> chosen in the tab, so the prompt is a plain allow/deny/always.
>
> **Master switch removed + Spawn tab folded into Settings (2026-06-26, supersedes
> every "master switch" / "global enable" / "Settings → Spawn tab" mention above and
> in §0.2).** There is **no global `agentDelegationEnabled` flag anymore** — it was a
> redundant second gate in a per-agent world. Each agent (and the main chat) ships
> with spawn off / image off / an empty pool, so **off-by-default + invisible-at-
> baseline now holds purely from the per-agent defaults**; the per-agent opt-in (a
> custom agent's `AgentSettings`, the main chat's `SubagentConfiguration` pool / image
> switch) is the **only** gate. `SubagentToolVisibility.{spawnAgent,spawnModel,image}Available` /
> `spawnTargetAllowed` / `spawnModelAllowed` no longer AND a master flag, and `ToolRegistry`'s base schema
> always carries the delegation family (a superset narrowed per-agent in
> `resolveTools`). The **dedicated "Spawn" sidebar tab + `SpawnSettingsView` are
> deleted**; the three remaining shared runtime knobs (Local Orchestrator Handoff,
> RAM-Safety Preflight, Image Load Policy) live in a small **"Subagents" card inside
> the general Settings tab** (`SubagentSettingsSection` hosted by `ConfigurationView`).
> **Local Orchestrator Handoff now defaults ON** (RAM-Safety preflight guards it) so
> enabling a capability on a local-model agent works without hunting for a second
> toggle. The §0 "Feature flag" two-gate list below is reduced to gate #2 only.
>
> **Spawn split into two tools + spawnable-model pool + guidance, `sandbox_reduce`
> removed (2026-06-28, supersedes the single-`spawn(name, input)` primitive and every
> `sandbox_reduce` reference above + below).** The `spawn` capability now vends **two
> sibling tools** off one `TextSubagentKind` (a `Target` enum), each with a single
> required target so the JSON Schema is enforceable (no unrepresentable "one of agent
> OR model"): **`spawn_agent(input, agent)`** runs a spawnable agent on ITS prompt +
> model (the original behavior), and **`spawn_model(input, model)`** runs a bare
> spawnable model id with NO agent/system prompt — the "delegate to a model, local
> or remote, in any direction" half of the original direction. Each tool is gated
> **independently** on its own non-empty pool (`SubagentToolVisibility.spawnAgentAvailable`
> / `spawnModelAvailable`; execution-time `spawnTargetAllowed` / `spawnModelAllowed`,
> reject-before-evict). The **spawnable-MODEL pool** is a new user-configurable
> allow-list — `spawnableModelNames` + a `spawnableModelNotes` `[modelId: note]` sidecar
> of "when/how to use it" hints — added to both `SubagentConfiguration` (main chat) and
> `AgentSettings` (custom agents), normalized on decode (trim/dedupe; notes pruned to
> live ids). When either spawn tool is visible the composer injects a **dynamic spawn
> guidance block** (a dedicated `.static` section in
> `SystemPromptComposer.appendGatedSections`, mirrored on the HTTP path) built from
> **`Subagent/SpawnDescriptors.swift`** (`@MainActor resolve` → `SpawnAgentDescriptor` /
> `SpawnModelDescriptor`) and rendered by `SystemPromptTemplates.spawnGuidance`,
> enumerating each reachable agent (description · model · local/remote) and model
> (display name · local/remote · provider · size/quant · the user's note) so the
> orchestrator knows what it can actually reach. `SubagentModelResolution.resolve`
> gained a **`requestedModel`** slot (ranked above the per-agent override + default but
> still run through the live residency decision, NOT the eval bypass) for the
> `spawn_model` explicit target. **`sandbox_reduce` (kind, tool, eval suites,
> `REDUCTION_SUBAGENT.md`) is deleted** — low value for its context cost; the
> chat-driven kinds are now `computer_use` + `spawn`. The AgentsView spawn card is a
> **selected-first** UI (removable chips/rows + a searchable grouped "Add" popover;
> models show a local/remote badge + inline note). The §0 generic-vs-aliased `spawn`
> sketch below is realized as this two-tool split.

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
- Permission: ask/deny/always, resolved **per launching agent** via
  `SubagentToolVisibility.effectivePermission` (custom → `AgentSettings.subagentPermissions`;
  Default → global `SubagentConfiguration.permissionDefaults`), keyed by `capability.id`.
- Budgets: tokens/turns/elapsed, resolved **per launching agent** via
  `effectiveBudgets` (custom → `AgentSettings.subagentBudgets`; Default → global
  `SubagentConfiguration.budgets`).

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
| 3 | `permission` | permission policy | ask/deny/always (the policy is the agent's own `effectivePermission`); the prompt shows the *resolved* model. (The first-use in-prompt model picker was removed 2026-06-26 — the model is set in the agent's Subagents tab.) | denied |
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
