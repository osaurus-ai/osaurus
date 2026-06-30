# Spawn / Image-Gen Orchestration — Product Requirements
Owner: Eric. Last updated 2026-06-25. SSOT for the user-facing feature.
(Engineering status/log lives in SUBAGENT_ORCHESTRATION_STATUS.md.)

> **Unified surface (2026-06-25).** The subagent paths were unified onto one shared
> `SubagentSession` host + `SubagentKind` framework (see
> SUBAGENT_ORCHESTRATION_STATUS.md → "Unified Subagent Architecture"). The tool
> surface changed: **`local_delegate` is removed (folded into `spawn`)** and
> **`image_generate` + `image_edit` are merged into one `image` tool** (passing
> `source_paths` switches it to edit). Config/services renamed
> `AgentDelegation*` → `Subagent*` (`SubagentConfiguration`,
> `SubagentConfigurationStore`, `SubagentSettingsSection`; the residency middleware is
> now `ResidencyHandoff`). Sections below predate the rename and use the old names —
> read them through that map.

> **Per-agent settings + unified main-chat tab (2026-06-26).** Image models,
> permissions, and budgets are now **per-agent**, configured in each agent's **Subagents
> tab** — including the **main chat**, which gets the same tab (Spawn + Image cards) bound
> to the global config. A capability is now **fully configured where you turn it on**:
> you pick the `image` gen/edit model, the `spawn`/`image` permission, and `spawn` budgets
> right next to the enable toggle. This **supersedes**: §3.2 "Default-model settings" and
> §3.3's permission/model/budget controls (those are no longer a global page — Settings →
> Spawn is now **system-only**: master enable · handoff · RAM-safety · image load policy),
> and the **"First-use permission popup" model-picker** (UX spec item 4 / the "To build"
> list) — the model lives in the tab, so the first-use prompt is a plain
> allow/deny/always. Custom agents persist to `AgentSettings`; the main chat keeps using
> the global `SubagentConfiguration` (also the REST `/v1/images` default), edited from its
> own tab.

## 1. Vision — spawn is a TOOL every main chat can use
The main osaurus chat model — **cloud OR local** — can call subagent tools to
run a bounded sub-process, get a compact result back, and continue its own turn:
- **image gen / edit** → one `image` tool (vMLXFlux engine); `source_paths` ⇒ edit.
- **text model / coder** → `spawn(agent,input)` (a named persona subagent, or the
  default text model when no persona is given).
Subagent tools join the SAME tool surface the chat already uses, alongside computer-use,
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
3. **Spawn settings + usage + info page** — ✅ DONE as a dedicated **sidebar page**
   (`SpawnSettingsView`, ManagementTab `.spawn`, next to Computer Use). Hosts the "How It
   Works" usage/info (what spawn is + local-vs-cloud flow + exposed tool list) + the full
   `AgentDelegationSettingsSection` (permission model ask/deny/always per job type, load
   policy, default models, budgets). The same section also still renders inside the
   Settings tab; both bind one store and sync via `.agentDelegationConfigurationChanged`.
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

---

## Spawn UX — full spec (Eric, 2026-06-21) — the target flow

The live Codex computer-use test caught that the **main/default chat cannot spawn end-to-end**
(default agent is locked to an 8-tool baseline + a "configure Osaurus" persona that refuses;
the delegation tools are built-in but filtered out for the default agent). The HTTP agent-run
path works because `enrichWithAgentContext` injects the delegation specs; the native chat
(`ChatView` → `composeChatContext` → `resolveTools`) does not. Required end state:

1. **Main chat can spawn.** A LOCAL main/default chat model can call the spawn/image/text
   delegation tools. (Master gate = the global Agent Delegation switch, on by default.)
   - Cloud/API main chat → nothing to unload; the local spawn job still runs and returns.
   - Local main chat → the spawn runs in the background (load/unload single-residency handoff).
2. **Tool-use is shown.** The chat shows a tool-usage row ("spawn" / image_generate used) while
   the bg job runs (loading/unloading/generating progress).
3. **Result returns inline.** When the bg job finishes, the **generated image renders inline in
   the main chat** (and text-gen results return to the chat).
4. **First-use permission popup.** The FIRST time a user triggers spawn, show the standard
   osaurus tool-permission prompt (Yes / No / **Always Allow**). **Within that same first-time
   prompt**, let the user pick the **spawned model** — the image-gen model OR the text-gen model
   (whichever the spawn is). After choosing, the Spawn settings panel **reflects** the chosen
   default model + the permission decision.
5. **Settings reflect choices.** The Spawn settings page (`SpawnSettingsView`) shows the
   chosen default image / text spawn model + the per-job permission state, synced with what was
   picked in the first-use prompt.

### Current state vs. target
- ✅ Built/proven: image gen/edit engine + handoff + RAM-safety (HTTP matrix); the 4 UI surfaces
  render (Codex-verified); per-agent toggle for CUSTOM agents; default-model pickers + Memory
  Safety in `SpawnSettingsView`; permission defaults (ask/deny/always) exist in config.
- ❌ To build for the spec above:
  - Surface delegation tools to the **main/default chat** (not just custom agents) under the
    global gate (resolveTools default-agent allow-list + composeChatContext for the native chat).
  - **First-use permission prompt + model picker** (extend the tool-permission dialog to carry a
    spawn-model selection on first use; persist to `AgentDelegationConfiguration`
    defaultImage/TextModelId + permissionDefaults).
  - **Inline image render** in the native chat when a chat-triggered image job completes
    (`NativeImageJobProgressCenter` → ChatView image card), confirmed live.
