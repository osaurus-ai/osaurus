# Spawn / Image-Gen Orchestration — Product Requirements
Owner: Eric. Last updated 2026-06-21. SSOT for the user-facing feature.
(Engineering status/log lives in SUBAGENT_ORCHESTRATION_STATUS.md.)

## 1. Vision — spawn is a TOOL every main chat can use
The main osaurus chat model — **cloud OR local** — can call `spawn`-class tools to
run a bounded sub-process, get a compact result back, and continue its own turn:
- **spawn image gen / edit** → `image_generate` / `image_edit` (vMLXFlux engine).
- **spawn text model / coder** → `local_delegate` (bounded helper on a chosen local
  model) and `spawn(agent,input)` (a named persona sub-agent).
Spawn tools join the SAME tool surface the chat already uses, alongside computer-use,
file, and capability tools — so the model reaches for them naturally. They must be
present as callable **schemas** in the chat's `<tools>` block, not just a prompt hint.

## 2. RAM-safety flow (the core nuance)
- **Local orchestrator** (the active chat model is a local MLX model):
  "auto-smart-unload" toggle ON → unload the current chat model → load the spawn
  model (text or image) → run the job → unload the spawn model → **reload the original
  chat model and continue the turn coherently** (KV warm-rebuilds from transcript / L2
  disk cache). Single-residency, so only one model touches the GPU at a time (avoids
  the model-churn Metal SIGABRT, #34).
  - Toggle OFF → refuse local→local spawn (don't double-reside) unless the spawn model
    == the chat model (run inline, no unload).
  - **Refuse-before-evict preflight**: if the spawn model won't fit once the chat model
    is freed, reject the job instead of stranding the user with nothing loaded.
- **Cloud / API orchestrator**: auto-unload is **N/A** — nothing is resident to unload.
  The spawn model loads (single residency), runs, unloads; the cloud chat continues
  with no reload. Permissions + preflight still apply to the spawn model load.

## 3. The four surfaces (UI / settings)
1. **Image Gen / Edit panel** — ✅ BUILT (`ImageGenerationPanelView`, compile-verified;
   visual live-check pending). Direct manual generation/edit UI: prompt + negative +
   size + seed (+ source-image picker for edit) → live progress (loadingModel → step
   bar) → result card with Reveal / Save-As. Driven directly by `ImageGenerationService`
   (manual panels keep their own loading behavior — no chat handoff). Launched from
   `ImageModelDetailView`'s footer for ready `imageGen`/`imageEdit` bundles (Models →
   Images tab → tap a model → Generate / Edit).
2. **Default-model settings** — ✅ DONE. Pickers for the default **text-delegate**,
   **image-gen**, and **image-edit** models. Scans the model folders (LLM root +
   `~/models/image`), persists to `agent-delegation.json`, survives restart, shows
   "(unavailable)" for a saved id no longer present.
3. **Spawn settings + usage + info page** — ✅ DONE as the "How It Works" subsection in
   `AgentDelegationSettingsSection` (what spawn is + local-vs-cloud flow + exposed tool
   list), alongside the permission model (ask / deny / always per job type), load policy,
   default models, and budgets. (osaurus settings are scrolling SECTIONS, not separate
   windows — so the "info page" lives as the top subsection of this section.)
4. **RAM Safety** — ✅ DONE. The refuse-before-evict preflight toggle ("Memory Safety"
   subsection) + the per-job load policy (handoff on/off) all bind the SAME single
   `AgentDelegationConfiguration` → `agent-delegation.json`. Because there is one backing
   store and one section, the spawn and RAM-safety views are **synced by construction**
   (osaurus has no separate tabs to desync).

## 4. Cohesion (reuse, don't reinvent)
- Spawn/image/delegate tools register in the existing `ToolRegistry`, gated by the
  existing `AgentDelegation` config, and flow through the existing chat + agent-run
  tool surfaces (`resolveTools` / `enrichWithAgentContext`).
- Permissions reuse `AgentDelegationPermissionDefaults` (ask/deny/always).
- The handoff reuses `ChatResidencyHandoff` + `ModelRuntime.unload/preload`.
- Reuse the existing model pickers, settings components (`SettingsToggle`,
  `SettingsSubsection`), and the computer-use / capabilities tooling already shipped.
- The same flow must work whether the spawn is triggered from the main chat UI, the
  `/agents/{id}/run` HTTP surface, or a cloud orchestrator.

## 5. Live matrix (dev-built app, read every response; same rigor as the model matrices)
- **A. Image jobs**: `image_generate` (DONE — flux PNG), `image_edit` round-trip,
  cancel/failure → image unloads + orchestrator restored, cloud-orchestrator variant.
- **B. Text/coder spawn**: `local_delegate` (coding/analysis) compact-result; `spawn`
  persona; local-orchestrator unload→delegate→reload.
- **C. Handoff coherence**: 6+ turn session with a spawn interleaved mid-conversation;
  KV/reasoning/tool/session intact after reload; no garbage/reset.
- **D. Permissions + settings**: ask/deny/always proven live; toggling a job type
  adds/removes its tool from the outbound payload; model assignments + RAM-safety
  settings persist across restart; RAM-Safety tab ⇄ Spawn tab stay synced.
- **E. RAM safety**: refuse-before-evict proven (a tight case actually rejects);
  multi-job stress (back-to-back image + text) with no leak / Metal / SSM crash.
- **F. Models**: 1 cloud + 1 local orchestrator; a local coder model; image models
  (z-image-turbo, flux-schnell, qwen-image, qwen-image-edit, ideogram).
