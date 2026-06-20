# Local Subagent Orchestration — Status, Design & Test Plan

Branch: `feat/image-generation-vmlxflux`. Last updated 2026-06-20.

This is the single source of truth for the "orchestrator spawns subagent jobs"
feature: **local text/coding subagent**, **image generation**, and **image edit**,
with model handoff when the orchestrator is a local model.

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
