---
title: Settings Overview
summary: Where every setting lives, and which ones the assistant can change for you.
order: 120
---

# Settings Overview

Osaurus settings live in the Management window (⌘⇧M). Type a name in the sidebar search to jump to a control. The built-in assistant uses the same catalog via `osaurus_help` `{action: find}` — it will quote a breadcrumb, not invent a path.

Ask the assistant to change declarative settings in chat (`osaurus_config`); each change shows a one-tap approval card first (see the Declarative Configuration topic).

## What the assistant can change in chat

- The Orchestrator (itself): display name, model, temperature, max output tokens, persona (system prompt).
- Memory: enabled, budget tokens, retention days.
- Agents: create/update custom agents, capability toggles, which agent new chats open with (`new_chat_agent`).
- Tools: global enablement and permission policies.
- Delegation: allowed subagents (custom agents and teammates' shared agents as `Name@Workspace`), per-workspace auto-join, spawn permissions, and the per-subagent limits (tokens, turns, seconds, local/remote parallelism).
- Plus everything else the declarative document covers: models, providers, MCP servers, plugins, commands, knowledge collections, channel routing, schedules, watchers, and web-search providers.

## What lives only in the Settings UI

- Server: port, expose to network, generation defaults, batching/concurrency, prefix/paged-KV/disk cache, **Context Window Cap**, KV retention, memory safety, model exposure. (Port and exposure changes restart the server; cache changes unload loaded models.)
- Orchestrator: Settings → Orchestrator holds Identity, Model & Generation (with the **Model readiness** row), **Working Folder**, Subagents (**Allowed subagents**, **Create starter agents**, **Permission**, **Permission for shared (workspace) agents**, **Limits**, **Advanced**, Local Models & Memory), and the **Delegations** list (Sent / Received). The working folder, model override, RAM-safety helpers and the Delegations list are UI-only; the rest is also declarative (`default_agent`, `delegation`).
- Chat behavior: compaction model, clipboard monitoring, smooth streaming, thinking display, chat titles, follow-ups. **Not** the context window — that is Server → Cache.
- App: start at login, hide dock icon, appearance, global hotkey, notifications/toasts.
- Voice: speech-to-text models, dictation, wake phrase, text-to-speech engine and voice.
- Themes: theme gallery, custom theme editor, import/export.
- Computer Use / Browser / Sandbox: autonomy presets, app allowlists, resources.
- Permissions: macOS TCC grants (Accessibility, Screen Recording, …). Tool Auto/Ask/Deny policies live on the Tools tab.
- Identity, Storage (encryption/backup), Privacy, Channels credentials.
- Secrets of any kind (API keys, tokens) are always entered in native secure fields, never chat.

## Common names that are different controls

| You might say | Actual control | Path |
|---|---|---|
| Context window / context budget / context length | Context Window Cap (tokens) | ⌘⇧M → Server → Settings → Cache → Context & KV Policy |
| Context budget (in chat) | Context Budget popover | Chat composer — read-only; Open Context Window Cap jumps to Server → Cache |
| Memory budget / token budget (memories) | Memory Budget | ⌘⇧M → Memory → Configuration |
| Max tokens (reply length) | Max Output Tokens | ⌘⇧M → Orchestrator → Model & Generation |
| Subagent limits / "agents end too fast" | Limits (Max output tokens per subagent, Max turns per subagent, Time limit per subagent) | ⌘⇧M → Orchestrator → Subagents → Limits |
| Orchestrator folder / file access | Working Folder | ⌘⇧M → Orchestrator → Working Folder (or the chat Folder chip) |
| Ask before delegating | Permission / Permission for shared (workspace) agents | ⌘⇧M → Orchestrator → Subagents → Permission |
| Max tokens (API defaults) | Generation Defaults → Max Tokens | ⌘⇧M → Server → Settings → Sampling Defaults |
| KV / cache window | KV Retention Override | Same Cache panel as the context cap |
| Tool permissions | Could be Tools catalog, Chat folder tools, or macOS Permissions — ask `find` |

Unknown-Model Metadata Fallback on the same Cache panel does **not** constrain local models. Use Context Window Cap to lower the window.

## Delegation memory checks

**Swap local models for subagents**, under Settings → Orchestrator → Local
Models & Memory, is shared by custom agents and the Orchestrator. It applies
to local text delegation (including batches, background and resumed children),
Browser Use, Computer Use and dedicated AppleScript calls. On swaps the exact
invoking model out and restores it after the child. AppleScript's separate
keep-warm policy can defer that restoration for back-to-back calls; changing
the swap or warm setting settles the previous lease before the next run.

Off keeps the exact invoking model resident for the child's lifetime, including
under Server Strict. Only that job's newly loaded child is cleaned up afterward;
an already-resident shared target is not evicted. Memory checks may refuse a child,
but never fall back to evicting the parent. The redundant experimental coexistence
switch was removed; its old configuration key is retained only for compatibility.
If the parent was already unloaded, Off does not reload it. Same-model
and remote children do not need a swap. Image jobs have their own load policy;
independent scheduled/watch jobs and background helpers do not gain permission
to evict unrelated chat models from this switch.

Settings → Orchestrator → **Local Models & Memory** → **Check memory before delegating**
is one shared setting for the Orchestrator and all custom agents, not a per-agent override.
It defaults to On. It budgets child state, reuses already-resident weights, and can
split a batch or refuse a child under low headroom or elevated memory pressure.
Reclamation waits for active GPU work to drain and then takes a fresh host sample;
another delay cannot guarantee that the OS pressure or available bytes will change.

Off bypasses delegation RAM admission and before/after-handoff memory preflights,
including warning/critical pressure and unavailable estimates. Allocation failures
or crashes remain possible. Permissions, model ownership, cancellation and explicit
concurrency limits still apply. Server → **Memory Safety** load budgets are separate;
**No Automatic Limits (Dangerous)** removes automatic load caps there, while explicit
advanced overrides remain in force. Disabling the delegation check does not silently
rewrite those server settings. Decisions report `ram_safety_enabled`; when false,
`ram_slots` is diagnostic and does not limit the admitted capacity.

## Speculative decoding

Native MTP starts **Off**. Selecting a compatible local model shows **Speculative
Depth** in the model picker's options after its configuration and weight headers
are inspected; sending a request or loading weights is not required. Choose
**Auto** or a maximum depth of **1–3** to opt in. The runtime can lower that depth
or use ordinary decoding when speculation does not help. Sampling settings remain
independent. Models without an executable MTP head do not advertise these controls.

The same global setting lives under Server → Settings → **Speculative Decoding**
and applies to Chat and API requests. Saved explicit choices survive model
selection and relaunch. Old defaults are turned off only when the app recorded
that it chose them automatically. An explicitly selected DFlash 2 drafter is a
separate opt-in; remove its folder selection to stop using it.

Force On requires verified bundle tuning unless an eligible manual depth is selected in Chat. If the bundle cannot honor that selection, Chat and API requests report a policy error; they do not silently change to ordinary decoding. A selected DFlash 2 drafter remains a separate explicit setting.

## Local model memory

Server → Settings → Model Memory contains **Keep Model Loaded** (off by
default) and **Unload After** (30 seconds by default). Models load when you
send a request. With Keep Model Loaded off, idle weights unload after the
timeout, or immediately when their last chat window closes. Active requests
finish first; another open window or active background/API request is protected.
Closing a chat does not shorten an unrelated API client's timeout.

Enable Keep Model Loaded to retain weights across idle time and window close.
Manual unload, model switching, changing settings that require a reload, and
quitting can still unload them. Saving a residency change also updates models
already idle in memory. This setting is UI-only, not declarative chat config.
An older 15-minute default migrates once to 30 seconds; other saved durations
and explicit Keep Model Loaded choices remain unchanged.

macOS manages swap. Osaurus no longer shows swap warnings or requires a
“Use Anyway” confirmation. Actual model-load failures still appear normally.

## Management sidebar

General, Chat, Voice, Themes, Credits, Workspaces, Identity, Permissions, Privacy, Local Models, Cloud Models, Media, Orchestrator, Agents, Channels, Web Search, Knowledge, Memory, Tools, Skills, Commands, Schedules, Watchers, Computer Use, Browser Use, Server, Sandbox, Insights.

## Where settings are stored

Config JSON lives under `~/.osaurus/config/` (`server.json`, `server-runtime.json`, `chat.json`, `default-agent.json`, `agent-delegation.json`, `memory.json`, …). Secrets live in the macOS Keychain.

### SSD cache limit notice

The chat composer shows **SSD cache limit reached** when the active disk cache
reaches its effective Disk Cache Size limit or removes older entries to make room.
It uses the runtime quota, including the limit calculated from the configured SSD
percentage. The notice appears once per cache directory and limit per app launch.
**Clear SSD Cache** removes indexed conversation cache files and their linked
companion data in one click; **Dismiss** closes the notice. Clearing can make the
next reply slower while cached data rebuilds. The same clear action is available
under Management → Server → Settings → Cache. Chats and model weights are preserved.
