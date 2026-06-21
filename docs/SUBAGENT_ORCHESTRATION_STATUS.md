# Local Subagent Orchestration — Status, Design & Test Plan

Branch: `feat/image-generation-vmlxflux`. Last updated 2026-06-20.

This is the single source of truth for the "orchestrator spawns subagent jobs"
feature: **local text/coding subagent**, **image generation**, and **image edit**,
with model handoff when the orchestrator is a local model.

---

## ⚠️ CHANGE OF PLANS (2026-06-20) — generalize to a portable subagent machine

The plan evolved from three hardcoded tools (`local_delegate`, `image_generate`,
`image_edit`) to ONE general, user-configurable primitive: **`spawn(name,
query)`** — "a portable subagent machine: input → output, aliased behind a
tool-call name," piggybacking on the existing **Agent personas** (`AgentManager`).
Users configure a named agent ("sparky") with its own local/remote model, prompt,
and tools; the orchestrator calls it by alias. Gated by a **per-agent `spawnable`
flag, default OFF** (tpae). `spawn` is a general PROCESS-spawning framework — text
agents, image gen/edit, and a future local-only **privacy loop** are all KINDS. Canonical design:
[`SUBAGENT_PORTABLE_DESIGN.md`](SUBAGENT_PORTABLE_DESIGN.md). Operational lifecycle,
cache/tokenizer/image nuances, and progress indicators are documented there too.

What this means for the work below:
- The `local_delegate` + image coordinators we built are NOT thrown away — they
  become the FIRST concrete cases of `spawn` and contribute the reusable
  parts (`ChatResidencyHandoff`, `AgentToolLoop` runner, the per-job coordinators).
- New work re-targets to: a shared `AgentSubagentRunner` (extract
  `LocalTextDelegateTool`'s body), the `spawn` tool over Agent personas, and
  auto-generated alias tools. Image gen/edit stay engine-specific but ride the
  same handoff + progress surface.
- Nothing about the model-handoff contract changes — local orchestrator unloads,
  subagent runs, orchestrator reloads; cloud orchestrator stays resident.

---

## 🔬 FIRST LIVE E2E (2026-06-20) — spawn dispatch PROVEN; concurrent-residency crash found + fixed

Drove the real agent-loop path headlessly: `POST /agents/default/run` (the built-in
tools are injected **only** through the agent-loop path via
`enrichWithAgentContext`/`composeChatContext`; the strict OpenAI `/v1/chat/completions`
path passes client tools through unchanged **by design** — so spawn is unreachable
there, which is why the earlier raw-`/v1/chat` smoke test only ever saw the model
*hallucinate* a spawn call). Test root `/tmp/osaurus-spawn-test`, orchestrator
`qwen3-4b-4bit`, a user agent **"Sparky"** (`qwen2.5-3b-instruct-4bit`) marked
spawnable in `spawnableAgentNames`.

**Proven working:**
- ✅ Orchestrator emits a **real** `spawn` tool_call over `/agents/default/run`
  (`osaurus_agent_tool: started/completed name:"spawn"`) — built-in tool injection +
  gating + `tool_choice:.auto` all correct.
- ✅ Persona resolution works **once the agent is materialized in `AgentStore`**.
  Gotcha: `AgentStore.loadAll` decodes with `dateDecodingStrategy = .iso8601`, so an
  authored agent JSON **must** use ISO-8601 `createdAt`/`updatedAt` strings (numeric
  seconds silently fail to decode and the agent is dropped → "agent not found").

**Crash found (now fixed) — the concurrent-residency GPU race (the task #34 edge):**
- The first different-model run **SIGABRT**ed. Crash report: thread 34 = subagent
  model load (`LLMModelFactory._load → loadWeights → convertToBFloat16 → GPU eval`,
  correctly under the exclusive `enterModelLoad` gate) racing thread 21 =
  `mlx::core::save_safetensors` (the resident orchestrator's **KV-cache disk store**,
  vendored `MLXLMCommon/KVCache.swift:1434`; SSM peer `SSMCompanionDiskStore.swift:103`)
  → Metal `"A command encoder is already encoding to this command buffer"`. Two GPU
  command encoders on MLX's shared stream at once.
- **Two defects:**
  1. **osaurus (FIXED):** `SpawnTool` gated `needsHandoff` on `parentChatModel()`
     *name resolution*, which returns **nil** on `/agents/{id}/run` (no active-agent
     default model) → `needsHandoff=false` → the subagent loaded **concurrently** with
     the still-resident orchestrator. Fix: gate on **actual residency** —
     `ModelRuntime.shared.cachedModelSummaries()`; if the subagent is local and ANY
     *other* chat model is resident, run the single-residency handoff
     (`ChatResidencyHandoff.unloadResidentChatModels`). `unload` ends with
     `Stream.gpu.synchronize()` + `Memory.clearCache()`, a full GPU barrier that
     drains the in-flight KV-cache store **before** the subagent loads. (SpawnTool.swift)
  2. **vmlx (LATENT, task #34):** the KV-cache / SSM disk-store `save_safetensors`
     eval is **not** serialized against the exclusive model-load gate. The osaurus
     handoff masks it for spawn (unload's `synchronize()` drains it), but any
     model-churn path that loads model B while model A is still flushing its cache —
     without an `unload` barrier between — can still hit this. Proper engine fix:
     route the cache-store eval through the same GPU serialization (or have
     model-load wait for pending cache-stores). Tracked as #34.

**Re-test status: ✅ CONFIRMED PASS** (rebuilt app, commit `e3e765f3`). Same
`/agents/default/run` run with the residency fix: orchestrator `qwen3-4b` →
`spawn("Sparky")` → single-residency handoff (unload orchestrator → load+run
`qwen2.5-3b` → unload → reload orchestrator) → digest relayed
("Unit testing matters because it ensures individual components…") → `finish:stop`.
**No crash; only `qwen3-4b` resident at end** (subagent cleaned up, orchestrator
restored). The concurrent-residency SIGABRT is gone. (Engine-side cache-store
GPU-gate hardening for non-`unload` churn paths remains open as the #34 edge.)

### Matrix run 2 (2026-06-20, headless `/agents/default/run`, rebuilt app)

| # | Test | Result |
|---|------|--------|
| 1 | **Same-model inline** — spawn "Echo" (`qwen3-4b` == orchestrator). `needsHandoff=false` (no *other* model resident), runs inline on the resident model. | ✅ PASS — returned "pineapple", no extra load, only `qwen3-4b` resident, no crash. |
| 2 | **Permission deny gate** — `permissionDefaults.localTextDelegate=deny`, spawn Sparky. | ✅ PASS — `SpawnTool` returned the `.rejected` "denied by Agent Delegation permission settings" envelope; no subagent loaded; orchestrator relayed it. |
| 3 | **Re-entrancy guard** — a spawned subagent cannot itself spawn. | ✅ PASS (by construction) — `AgentSubagentRunner` passes `tools: nil` (subagent has no tools), `executeTool` rejects all tool use, and `SpawnTool.execute` early-returns `.rejected` when `LocalTextDelegateContext.isActive`. Triple-guarded; not reachable in v1. |
| 4 | **Coherence across handoff** — state a fact, spawn a different-model agent (full unload/reload handoff), then require recall of the fact. | ✅ PASS (single-call variant) — orchestrator recalled BOTH Sparky's reply ("Hi") AND "teal" after the reload; coherent, no garbage, no crash. |

### ⚠️ Separate crash found (NOT spawn) — `capabilities_discover` embedding SIGSEGV

The 3-call multi-turn variant of test 4 surfaced a **different** crash: the
orchestrator chose the built-in **`capabilities_discover`** tool
(`Tools/CapabilityTools.swift`, semantic tool search) instead of spawning
directly. Its embedding pass — `Model2VecStaticEmbeddingPipeline.embedOne` →
`mlx_eval` → `Reduce::eval_gpu` → `setComputePipelineState` → `objc_msgSend` —
**SIGSEGV**'d on a freed Metal pipeline state (use-after-free / concurrent-GPU
resource race). Same *family* as the #34 cache-store race: another GPU-using
subsystem (Model2Vec embeddings behind capability discovery) not serialized
against whatever freed the Metal resources (model eviction / `Memory.clearCache`).
**Orthogonal to spawn** — a pre-existing capability-discovery/embedding path — but
a real multi-tool-session liability; harden alongside #34. osaurus already has an
embedding gate (`MetalSafeEmbedder`/`enterEmbedding`), so the fix is likely
routing capability discovery's embed through it and/or gating the freeing path.
Flagged for Eric; not fixed autonomously per directive.

---


## 0. Build & verified state (2026-06-20)

- **Branch builds GREEN** on current main: synced (`AgentToolLoop`, Computer Use
  Subagent, owner-keyed MetalGate), vmlx `d35c0744` (Qwen3/Laguna fixes), vMLXFlux
  re-added, MetalGate `enterImageGeneration` exclusive lane. Full `make app` = exit 0.
- **Verified-built in source (corrects earlier understatement):**
  - Image gen/edit: tools + `NativeImageJobCoordinator` full handoff (unload chat →
    run vMLXFlux → restore) + strict resolver + per-job permission + progress events.
  - Text subagent: `local_delegate` **runs on `AgentToolLoop.run`** with budgets +
    delegate unload-after-job + permission. **Cloud orchestrator → delegate works.**
  - Settings: `AgentDelegationSettingsSection` panel — master + per-job toggles,
    per-job subagent **model pickers**, ask/deny/always permission pickers.
- **Real remaining code gaps (not "all unbuilt"):**
  1. **Local orchestrator → text delegate handoff is REJECTED**, not wired
     (LocalTextDelegateTool line ~139: "local-to-local disabled to avoid double
     residency"). Needs the unload-orchestrator → load-delegate → reload that the
     image coordinator already does.
  2. **RAM-safety preflight** absent in both flows (no sub-24 GB refuse-before-evict).
  3. **Zero live e2e proof** (the §5 matrix).
  4. Settings persistence + "toggle removes tool from payload" unverified live.

---

## 1. Goal (Eric, 2026-06-20)

One chat model — the **orchestrator** (local OR cloud) — can submit/spawn bounded
**subagent jobs**, following osaurus's existing loop primitive. Create a **new,
modular loop with a similar API surface** to the shipped patterns:

- `AgentToolLoop` (`Services/Chat/AgentToolLoop.swift`) — the shared loop primitive.
- `sandbox_reduce` / Reduction Subagent (`docs/REDUCTION_SUBAGENT.md`).
- Computer Use Subagent (PR #1578, `ComputerUse/Loop/ComputerUseLoop.swift`).

Three subagent job types:
1. **Local text/coding subagent** — a *user-chosen local model* does bounded
   coding/analysis so a cloud orchestrator spends fewer cloud tokens.
2. **Image generation** (vMLXFlux).
3. **Image edit** (vMLXFlux).

### Orchestrator handoff rules
- **Local orchestrator:** write prompt/job → **unload the orchestrator model**
  (the model the user assigns in settings, changeable) → load the subagent/task
  model → run the job → unload the subagent → **reload the orchestrator** →
  continue the original turn.
- **Cloud/API orchestrator:** no unload/load — the orchestrator stays; the local
  subagent (text or image) still runs and returns a compact result.
- **User-toggleable** in settings (assign orchestrator model, per-job subagent
  models, and whether to do the unload/reload handoff).

---

## 2. Architecture (target)

```
Chat turn (orchestrator: local OR cloud)
  └─ orchestrator tool call: local_delegate | image_generate | image_edit
       └─ <Job>Coordinator  (owns model handoff + RAM safety + permission)
            ├─ LocalModelHandoffPolicy
            │     local orchestrator → unload orchestrator → … → reload
            │     cloud orchestrator → no-op
            ├─ subagent runner
            │     text   → bounded AgentToolLoop run on the local subagent model
            │     image  → ImageGenerationService → vMLXFlux  (MetalGate exclusive)
            └─ compact structured result → back into the orchestrator turn
```

- **New loop must reuse `AgentToolLoop`** (like `ComputerUseLoop` does) rather than
  re-implementing a tool loop. Keep each surface modular.
- **MetalGate** (main's owner-keyed redesign) already makes
  orchestrator-unload → subagent-load → reload **GPU-safe** (model load is now an
  exclusive producer; this is what fixes the model-switch SIGABRT, task #34).

---

## 3. DONE — source-wired (on this branch, commit `e85bd541` + earlier)

- **ImageGenerationService** owns the only `vMLXFlux` import; exposes
  generate/edit/upscale via Osaurus-native events. HTTP-proven for Z-Image Turbo,
  FLUX.1 Schnell, Qwen-Image, Qwen-Image-Edit, Ideogram (catalog/generate/edit/
  reject/cancel/reload). Held in MetalGate's exclusive image lane.
- **NativeImageJobCoordinator** — snapshot active chat provider/model, unload local
  chat model if resident, run image job, unload image, mark orchestrator for
  restore; progress events with session/turn/tool-call ids.
- **NativeImageJobModelResolver** (strict) — rejects requested/configured stale,
  incomplete, or wrong-kind image models BEFORE chat-model residency is touched
  (no pointless eviction).
- **NativeImageTools** — `image_generate` / `image_edit` tools; model resolved
  **before** the permission prompt and **before** reading edit source files.
- **LocalTextDelegateTool** (`local_delegate`) — source-wired text subagent tool;
  resolves the local delegate model before the permission ask.
- **AgentDelegationApprovalArguments** — surfaces the resolved job type + target
  model in the permission prompt payload.
- **ToolRegistry** — `local_delegate` gated alongside the image tools.
- **AgentDelegationConfiguration** — load policy (`agent_single_residency`),
  per-job permission policy (ask/deny/always-allow) decode + safe defaults.
- **Tests (build + unit):** NativeImageJobCoordinatorTests, AgentDelegation
  ToolAvailabilityTests, NativeImageToolArtifactBridgeTests, config-store tests —
  prove buildability, policy gating, stale-call rejection, artifact promotion.

---

## 4. NOT DONE — gaps vs the spec

- [ ] **New `AgentToolLoop`-based subagent loop.** The current work is tools +
      coordinator; it does NOT yet adopt the `AgentToolLoop` primitive the way the
      spec asks. The text subagent should run a *bounded* `AgentToolLoop` on the
      local model (modular, mirroring `ComputerUseLoop`'s adoption).
- [ ] **LocalDelegateCoordinator** — the text-subagent peer of
      NativeImageJobCoordinator (owns the orchestrator handoff for text jobs).
      `LocalTextDelegateTool` exists but the unload→subagent→reload handoff loop
      for text is not wired/closed.
- [ ] **Local-orchestrator handoff, end to end** — image side has the
      snapshot/unload/restore path source-wired but **no live RAM proof**; text
      side handoff not wired.
- [ ] **Cloud-orchestrator no-handoff path** + the user toggle for it.
- [ ] **Settings / model assignment** — user assigns the orchestrator model + the
      per-job subagent models + the handoff toggles, persisted across restart.
      Plan exists (`docs/superpowers/plans/2026-06-18-agent-delegation-settings.md`)
      but the panel + persistence are unbuilt/unproven.
- [ ] **Permission prompts live** — ask/deny/always-allow, showing the resolved
      model and allowing a model switch before approving (source-wired only).
- [ ] **Progress UI on the agent-triggered path** — events are posted; the chat
      progress row is not wired/proven for an agent-spawned job.
- [ ] **RAM-safety preflight/refusal** for sub-24 GB (respect Memory Safety
      settings; refuse before eviction when the plan won't fit).
- [ ] **SYNC WITH MAIN (in progress this session).** Branch was 29 behind main;
      merging to pick up `AgentToolLoop`, Computer Use Subagent, model-load-safe
      MetalGate, and the vmlx repin `d35c0744`. Status: pins resolved →
      `d35c0744`; MetalGate resolved to main's owner-keyed design + image lane
      re-added (`enterImageGeneration`/`exitImageGeneration`); **1 conflict left**
      (`Localizable.xcstrings`). Then must build green (expect old-API call-site
      breakage to fix), then continue feature work.

---

## 5. E2E live proof + matrix (NONE passed yet — all required before "done")

Run on the dev-built Release app, reading every response; same discipline as the
qwen/Laguna matrices (looping/incoherency/weird-char scan, RAM under Activity
Monitor). VL is N/A for the text models; image jobs are the visual axis.

### A. Image jobs
- [ ] **Local orchestrator → image_generate**: write job → unload orchestrator →
      load image model → generate → unload image → reload orchestrator → final
      answer renders an image card. Capture RAM at each phase.
- [ ] **Local orchestrator → image_edit** with a real source artifact.
- [ ] **Cloud orchestrator → image_generate / image_edit** (no orchestrator
      unload; privacy filter still applies to cloud calls; image prompt stays local).
- [ ] Cancel / failure mid-job → image engine unloads, orchestrator restored.

### B. Local text subagent
- [ ] **Cloud orchestrator → local_delegate** (coding/analysis) → compact result
      back into the cloud turn (no full local transcript leak).
- [ ] **Local orchestrator → local_delegate**: unload orchestrator → load delegate
      model → bounded AgentToolLoop run → unload → reload orchestrator → continue.

### C. Handoff correctness (regression-critical)
- [ ] After reload, the orchestrator's **multiturn continues coherently** — KV/cache,
      reasoning state, tool state, session history all intact (no garbage, no
      reset). Run a 6+ turn session that interleaves a subagent job mid-conversation.
- [ ] Reload uses the user-assigned orchestrator model and its generation/template
      defaults (no sampler/template tricks to hide latency).

### D. Permission + settings
- [ ] ask / deny / always-allow each proven live; prompt shows resolved model;
      switch-model-before-approve works.
- [ ] Settings toggle adds/removes `local_delegate` / `image_*` from the actual
      outbound tool payload; orchestrator + subagent model assignments persist
      across app restart.

### E. RAM safety / stress
- [ ] sub-24 GB preflight refusal proven (won't evict if the plan won't fit).
- [ ] multi-job stress (back-to-back image + text jobs) — no leak, no Metal/SSM
      crash (note: main's owner-keyed MetalGate should now cover the model-load
      overlap that caused the earlier SIGABRT, task #34 — verify it does).
- [ ] per-turn-varied multirun with subagent jobs interleaved; scan every response.

### F. Models to cover
- Orchestrators: 1 cloud provider + 1 local (e.g. qwen3-8b / gemma-4).
- Text subagent models: a local coding model (user-assigned).
- Image models: z-image-turbo, flux-schnell, qwen-image, qwen-image-edit, ideogram.

---

## 6. Immediate next steps (ordered)
1. Finish the main merge (resolve `Localizable.xcstrings`; commit), then **build
   green** — fix any old-MetalGate / pre-`AgentToolLoop` API breakage.
2. Wire the **text subagent on `AgentToolLoop`** + `LocalDelegateCoordinator`
   handoff; mirror `ComputerUseLoop`.
3. Settings: orchestrator + per-job subagent model assignment + handoff toggles.
4. Run the §5 matrix on the dev app; fix; document results here.

---

## 7. Gap audit + build increment (2026-06-21)

Parallel read-only audit of the whole feature surface (settings page, lifecycle).
Reconciles §0/§4 doc claims against actual code; several "NOT DONE" items are now
built (matrix run 2). Real current state:

### Built (verified)
- Settings panel: all toggles, 3 default-model pickers (text/image-gen/image-edit),
  permission pickers, load policies, budgets. Save/persist live → `agent-delegation.json`,
  survives restart.
- Prompt/task dispatch (`image_generate`/`image_edit`/`local_delegate`/`spawn`): args
  forwarded, model override resolved (requested > configured default).
- Image + text unload→job→reload handoff (`ChatResidencyHandoff` shared core);
  cancel/failure restores the orchestrator.
- Local→local text handoff: wired (settings + residency gated). Doc's old "rejected" was stale.

### Gaps found
1. **Image-model folder scan** — scanned only `<effectiveModelsDir>/image` (default
   `~/MLXModels/image`), missing manually-placed bundles under `~/models/image/`.
2. **RAM-safety preflight** — MISSING in both flows (unconditional evict-then-load).
3. `imageJobLoadPolicy.unloadImageAfterAgentJob` — dead branch (no distinct behavior).
4. Post-reload KV continuity — in-mem KV destroyed; cold/L2-warm rebuild, no snapshot.
5. cancel/failure restore is best-effort `try?` (silent if reload fails).

### This increment (built 2026-06-21)
- **GAP 1 FIXED** — `ImageGenerationService.imageModelsRoot()` now returns the first
  *populated* candidate among `<modelsDir>/image`, `~/models/image`, legacy
  `~/.mlxstudio/models/image` (env override still wins). Scan + load stay single-root +
  consistent; finds `~/models/image` with no env/bookmark.
- **GAP 2 FIXED (image + config + UI)** — new `ramSafetyPreflightEnabled` config field
  (default true) + "Memory Safety → RAM-Safety Preflight" settings toggle.
  `ChatResidencyHandoff.memoryPreflight(requiredBytes:enabled:)`: reclaimable RAM
  (free+inactive+purgeable) + resident-chat bytes vs spawn-model bytes×1.3 + 3 GB
  headroom; throws `.insufficientMemory` **before** any unload. Wired into
  `NativeImageJobCoordinator` generate + edit (model resolved before unload).

### Still TODO (next increments)
- GAP 2 text path: wire the same preflight into `LocalTextDelegateTool`/`SpawnTool`
  (needs the delegate model's on-disk size as `requiredBytes`).
- GAP 3: give `unloadImageAfterAgentJob` a distinct branch (or document the collapse).
- GAP 5: surface restore failures instead of swallowing `try?`.
- Live matrix (§5) with a tool-reliable orchestrator (qwen3-4b too weak to emit the
  image tool call — echoes instead; use a stronger local model or forced tool_choice).

### Image-job live-trigger blocker (2026-06-21)
GAP1+GAP2 committed `f9526668` (build green). But §5.A image-job E2E remains
UN-live-proven because the headless trigger doesn't fire: on `/agents/{id}/run`
(both custom `Echo` and `default`), qwen3-4b answers in prose ("Let me create the
image for you") with NO `image_generate` tool_call, even with
`tool_choice={function:image_generate}` forced. Confirmed: tool is registered
(`ToolRegistry.swift:195 NativeImageGenerateTool()`), `image_generate` is gated by
`imageDelegationActive` (true now), and `tool_choice` is plumbed
(`HTTPHandler.swift:2831,4517,4644`). So the gap is one of: (a) the forced
`tool_choice` is not rendered into the qwen3 prompt as a hard "must call" directive
on the agent-run path; (b) image_generate is not injected into THIS run's tool
payload (custom-agent tool set); (c) qwen3-4b too weak. NEXT: dump the rendered
agent-run prompt + outbound tool schema to disambiguate, and/or retest with a
stronger local tool-caller. The image coordinator + GAP2 preflight cannot be
live-exercised until the trigger fires.

### Increment 2 (2026-06-21): text/spawn RAM preflight + GAP3 reassessed
- **GAP 2 text path DONE**: `ChatResidencyHandoff.estimatedChatModelBytes(named:)`
  (catalog size estimate, dir-size fallback) + `memoryPreflight` now wired into
  `LocalTextDelegateTool` and `SpawnTool` before their `unloadResidentChatModels`
  call → refuse-before-evict on the text/spawn handoff too.
- **GAP 3 REASSESSED — not a bug**: `imageJobLoadPolicy.unloadImageAfterAgentJob`
  IS implemented (chat-unload iff `agentSingleResidency`; image-unload iff
  `!manualPanelKeepsImageLoaded` → unloadImageAfterAgentJob = keep chat + unload
  image). The audit's "dead branch" was a misread; behavior is correct. (Could add
  a clarifying comment later; no functional change.)

### Image-job trigger ROOT CAUSE FOUND (2026-06-21)
Live tool-payload dump (`/agents/{id}/run`, env `OSAURUS_DUMP_AGENT_TOOLS`):
- Echo (custom agent): `composed=[]` — zero tools.
- default agent: `composed=[todo, complete, clarify, capabilities_discover,
  capabilities_load, osaurus_describe, osaurus_list, osaurus_status]` — NO
  `image_generate`, `local_delegate`, or `spawn`.
**Root cause:** `SystemPromptComposer.composeChatContext` (the agent-run/HTTP tool
surface) adds the active image tools only as a PROMPT-HINT capability
(`SystemPromptComposer.swift:1244-1260`, `ManifestCapability`) — it does NOT add
`image_generate`/`image_edit` to the callable tool **schemas**. The CHAT-surface
path uses `resolveTools` (`:~2018`, logs `image_generate_in_schema`) which DOES add
the schema. So an agent-run orchestrator is *told* it can make images but the tool
is absent from its `<tools>` block → no valid tool call possible. This is why
neither Echo nor the default agent fired `image_generate` even with forced
`tool_choice` (the spawn matrix used the chat-surface tooling, not this path).
**FIX (proposed):** in `composeChatContext`, when `imageDelegationActive` (and the
text/spawn equivalents), append the active delegation tool SCHEMAS to the composed
tool set — not just the prompt hint — mirroring `resolveTools`. Then agent-run/HTTP
orchestrators (and headless tests) can actually call `image_generate`/`image_edit`/
`local_delegate`/`spawn`. Until then, image jobs only fire from the chat-UI surface.
(Removed the temporary `OSAURUS_DUMP_AGENT_TOOLS` dump after diagnosis.)

### ★ Image-job trigger FIXED + §5.A LIVE-PROVEN (2026-06-21)
Fix `bb3ccb22`: `enrichWithAgentContext` now appends the active AgentDelegation
tool SCHEMAS (`specs(forTools: [image_generate, image_edit, local_delegate, spawn]`,
active-gated + name-deduped) to the agent-run tool surface. Agent-run-only (chat
surface unchanged). **Live E2E proven**: default agent (qwen3-4b) → `image_generate`
(forced tool_choice) → `NativeImageJobCoordinator` handoff → FLUX-schnell generate →
`generated-images/flux1-schnell-*.png` (real 512×512 RGB PNG, 258 KB). This also
exercised GAP1 (image scan resolved flux-schnell from ~/models/image) and GAP2
(RAM preflight passed with ample RAM, no false-refuse).
**§5.A image_generate: PASS.** Next: image_edit round-trip; a RAM-tight refuse case
to prove the preflight rejects; default-temp orchestrator reliability (forced
tool_choice works; a stronger model would be more natural).

### Matrix A image handoff — VERIFIED + a minor queue gap (2026-06-21)
Handoff confirmed via /health: warm chat (`qwen3-4b` resident) → `image_generate` →
chat model UNLOADED (`loaded=[]`) → FLUX runs (image not in /health.loaded; separate
engine) → after the job a fresh chat reloads `qwen3-4b` and answers normally. Two
images proven (512² apple, 1024² blue circle). So unload→image→reload works; the
orchestrator is usable after (matrix A core PASS).
**Minor gap found:** a chat request sent WHILE an image job is mid-run returns empty
content instead of QUEUEING behind the single-residency job (GPU busy → model can't
load → blank). Should wait-for-idle (the handoff already has `waitForChatIdle`) or
return a "busy, image job running" envelope. Low severity; track as a follow-up.
