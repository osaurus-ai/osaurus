# Subagent Orchestration — Team Spec, Wiring & Usage

Audience: osaurus contributors. Companion to
[`SUBAGENT_ORCHESTRATION_STATUS.md`](SUBAGENT_ORCHESTRATION_STATUS.md) (status +
test matrix) and [`NATIVE_SWIFT_IMAGE_AGENT_JOB_FLOW.md`](NATIVE_SWIFT_IMAGE_AGENT_JOB_FLOW.md)
(image-flow detail). This file is the spec + wiring contract.

---

## 1. What it is

A chat turn's **orchestrator** model (local OR cloud) can spawn a bounded
**subagent job** and fold the result back into the turn. Three job kinds:

| Tool | Subagent | Engine |
|------|----------|--------|
| `local_delegate` | local text/coding model (user-assigned) | `AgentToolLoop` on the local model |
| `image_generate` | local image model | `ImageGenerationService` → vMLXFlux |
| `image_edit` | local image model | `ImageGenerationService` → vMLXFlux |

Design follows the shipped primitives — `AgentToolLoop`
(`Services/Chat/AgentToolLoop.swift`), `sandbox_reduce`
(`Tools/SandboxReduceTool.swift`, see `docs/REDUCTION_SUBAGENT.md`), and the
Computer Use Subagent (`ComputerUse/Loop/ComputerUseLoop.swift`, PR #1578). New
loops are **modular** and reuse `AgentToolLoop`; they do not re-implement a loop.

---

## 2. Model handoff contract (the core requirement)

```
Orchestrator = LOCAL model:
  1. orchestrator emits the subagent tool call (job spec)
  2. Coordinator: snapshot orchestrator (provider + model + gen config + history)
  3. unload orchestrator model            (MetalGate "load:<m>" exclusive)
  4. load subagent/task model             (MetalGate "load:<sub>" exclusive)
  5. run job                              (text: AgentToolLoop / image: vMLXFlux,
                                           each MetalGate-exclusive)
  6. unload subagent model
  7. reload orchestrator model            (same model + defaults, no tricks)
  8. return compact result → orchestrator continues the turn

Orchestrator = CLOUD/API model:
  - skip steps 2–4, 6–7 (orchestrator never resident). Run the local subagent,
    return the compact result. Privacy filter still applies to cloud calls; the
    subagent prompt/work stays local.
```

All handoff toggles + model assignments are user settings (see §5). Defaults
must be safe for < 24 GB RAM and respect Memory Safety settings.

**Why the handoff is now safe:** main's `MetalGate` (owner-keyed mutual
exclusion) treats **model load** as an exclusive GPU producer
(`enterModelLoad`/`exitModelLoad`), so unload→load→reload can never overlap an
in-flight generation or image eval. This is also the fix for the model-switch
`SIGABRT` (`MTLCommandBuffer addCompletedHandler` abort, task #34).

---

## 3. Components & wiring (file → responsibility → contract)

### Orchestration loop (reuse, don't reinvent)
- `Services/Chat/AgentToolLoop.swift` — canonical loop driver.
  - `AgentToolLoop.run(...) -> RunResult` (see `AgentLoopHooks`, `AgentLoopPolicy`,
    `AgentLoopBudget`). The text subagent runs a **bounded** `AgentToolLoop`
    (capped iterations/tokens/turns) on the assigned local model.
  - Mirror `ComputerUseLoop`'s adoption pattern for the new `LocalDelegateLoop`.

### Tools (orchestrator-facing surface)
- `Tools/NativeImageTools.swift` — `image_generate` / `image_edit`. Args: `prompt`,
  `negative_prompt?`, `source_artifact_id|source_image_path` (edit), `size?`,
  `steps?`, `guidance?`, `seed?`, `model:"auto"|<id>`. Resolves the model **before**
  the permission prompt and before reading edit sources.
- `Tools/LocalTextDelegateTool.swift` — `local_delegate`. Args: `task`,
  `mode:coding|analysis|summarize|other`, `context_refs?`, `allowed_tools?`,
  `max_tokens?`, `max_turns?`, `model?`. Resolves the delegate model before the ask.
- `Tools/ToolRegistry.swift` — gates `local_delegate` + `image_*` behind the
  Agent Delegation settings (add/remove from the outbound tool payload).
- `Tools/AgentDelegationApprovalArguments.swift` — injects resolved job + model
  facts into the permission-prompt payload.

### Coordinators (own handoff + RAM + permission + result)
- `Services/AgentDelegation/NativeImageJobCoordinator.swift` — image jobs.
  Snapshot → unload-if-local → run vMLXFlux → unload → restore. `NativeImageJob
  ModelResolver` rejects stale/incomplete/wrong-kind models **before** residency
  is touched.
- **`LocalDelegateCoordinator` (TODO)** — text peer of the above; owns the
  orchestrator handoff for `local_delegate`.

### Runtime primitives (reused)
- `Services/ModelRuntime.swift` — `enterModelLoad`/`exitModelLoad`-wrapped load +
  the unload path used for handoff.
- `Services/ModelRuntime/MetalGate.swift` — `enterGeneration` / `enterEmbedding` /
  `enterModelLoad` / **`enterImageGeneration`** (added on this branch). Every GPU
  producer acquires an exclusive (or shared same-owner) lane.
- `Services/ModelRuntime/ImageGenerationService.swift` — the only `vMLXFlux`
  import; generate/edit/upscale events, held in MetalGate's image lane.

### Config & settings
- `AgentDelegationConfiguration` — load policy (`agent_single_residency`),
  per-job permission (`ask`/`deny`/`always_allow`), budgets, model assignments.
- Settings panel (TODO) — orchestrator model assignment + per-job subagent model
  assignment + handoff toggles; persisted; see
  `docs/superpowers/plans/2026-06-18-agent-delegation-settings.md`.

---

## 4. Data flow (one image job, local orchestrator)

```
/v1/chat (local orchestrator) → tool_call image_generate{prompt,…}
  → ToolRegistry dispatch → NativeImageTools.imageGenerate
    → resolve model (strict) → permission prompt (resolved model shown)
    → NativeImageJobCoordinator:
        snapshot orchestrator → ModelRuntime.unload(orchestrator)
        → ImageGenerationService.generate (MetalGate.enterImageGeneration)
            → vMLXFlux event stream → artifact written
          ImageGenerationService done (exitImageGeneration)
        → unload image model → ModelRuntime.load(orchestrator)
    → tool result {artifact_id, model, dims, steps, seed, elapsed, residency}
  → orchestrator turn continues, chat renders the image card
```

`local_delegate` is the same shape with `AgentToolLoop` in place of
`ImageGenerationService`, returning a text digest instead of an artifact.

---

## 5. Usage

### As an end user
- Assign the **orchestrator model** (the main chat model) in settings.
- Assign **subagent models**: a local text/coding model, and image gen/edit
  models. Toggle whether a local orchestrator should unload/reload around jobs
  (cloud orchestrators ignore this).
- Set per-job permission: ask / deny / always-allow. The prompt shows the
  resolved target model and lets you switch models before approving.

### As a model (tool schema)
- The orchestrator sees `local_delegate`, `image_generate`, `image_edit` only
  when enabled in settings. `model:"auto"` picks the user-assigned model; an
  explicit id overrides. A short catalog error is returned if no compatible
  local model is installed.

### As a contributor
- New subagent kinds = new tool + new coordinator + reuse `AgentToolLoop`. Do not
  add recursive agents, helper LLMs, or shell workers in a coordinator — it is
  normal Swift service code that drives one bounded job.

---

## 6. Needs (to ship) — see STATUS doc §4–§5 for the full list + test matrix
- `LocalDelegateCoordinator` + text handoff loop on `AgentToolLoop`.
- Cloud-orchestrator no-handoff path + the user toggle.
- Settings panel: orchestrator + per-job model assignment + toggles, persisted.
- Live permission prompts; progress UI on the agent-triggered path.
- RAM-safety preflight/refusal for < 24 GB.
- **Full §5 e2e matrix on the dev app** (none passed yet): local/cloud × {image
  gen, image edit, text delegate}, handoff-then-multiturn coherence, permission
  ask/deny/always, settings persistence, multi-job stress, looping/incoherency
  scan. CI green is not sufficient.
```
