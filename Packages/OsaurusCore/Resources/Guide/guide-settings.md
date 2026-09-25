---
title: Settings Overview
summary: Where every setting lives, and which ones the assistant can change for you.
order: 120
---

# Settings Overview

Settings… (⌘,) opens the Management window. Type a name in the sidebar search to jump to a control. The built-in assistant uses the same catalog via `osaurus_help` `{action: find}` — it will quote a breadcrumb, not invent a path.

Ask the assistant to change declarative settings in chat (`osaurus_config`); each change shows a one-tap approval card first (see the Declarative Configuration topic).

## Agent descriptions

Each agent has an optional **Brief description (optional)** field under Settings → Agents → the agent → Configure. It is a one-line summary of what the agent does and when to delegate to it, shown beside the agent's name wherever the Orchestrator or an agent picker lists targets. It is never required: agents with a blank description can still be saved, duplicated, and delegated to.

When the description is blank and the agent has a system prompt, Osaurus generates a summary in the background (using the configured core model, or the model already loaded for chat) and shows it as the field's placeholder. Generation never blocks a save and never loads a model on its own; it runs after a chat turn completes or when the Orchestrator builds its delegation roster. Typing your own description overrides the generated one; editing the system prompt regenerates it. Description text is routing metadata and never grants tools or permissions.

## What the assistant can change in chat

- The Orchestrator (itself): display name, model, temperature, max output tokens, persona (system prompt).
- Memory: enabled, budget tokens, retention days.
- Agents: create/update custom agents, capability toggles, which agent new chats open with (`new_chat_agent`), and which built-in **Apple Apps** a custom agent may use (`capabilities.apple_apps`, e.g. `["calendar", "reminders"]`). The Orchestrator never calls the Apple app tools itself; ask it to "give Planner access to Calendar" or "create a Mail agent" and it patches or provisions the custom agent.
- Tools: global enablement and permission policies.
- Delegation: allowed subagents (custom agents and teammates' shared agents as `Name@Workspace`), per-workspace auto-join, spawn permissions, and the per-subagent limits (tokens, turns, seconds, local/remote parallelism).
- Plus everything else the declarative document covers: models, providers, MCP servers, plugins, commands, knowledge collections, channel routing, schedules, watchers, and web-search providers.

## What lives only in the Settings UI

- Server: port, expose to network, generation defaults, batching/concurrency, prefix/paged-KV/disk cache, **Context Window Cap**, KV retention, memory safety, model exposure. (Port and exposure changes restart the server; cache topology changes unload loaded models; disk-size changes update resident quotas.)
- Orchestrator: Settings → Orchestrator holds Identity, Model & Generation (with the **Model readiness** row), **Working Folder**, Subagents (**Allowed subagents**, **Create starter agents**, **Permission**, **Permission for shared (workspace) agents**, **Limits**, **Advanced**, Local Models & Memory), and the **Delegations** list (Sent / Received). The working folder, model override, RAM-safety helpers and the Delegations list are UI-only; the rest is also declarative (`default_agent`, `delegation`).
- Chat behavior: compaction model (unset = the chat's current model summarizes; compaction runs automatically near the context limit and on demand from the **Compact conversation** button in the chat's context budget popover), clipboard monitoring, smooth streaming, thinking display, chat titles, follow-ups. **Not** the context window — that is Server → Cache.
- App: start at login, hide dock icon, appearance, global hotkey, notifications/toasts.
- Voice: speech-to-text models, dictation, wake phrase, text-to-speech engine and voice.
- Themes: theme gallery, custom theme editor, import/export.
- Computer Use / Browser / Sandbox: autonomy presets, app allowlists, resources.
- Permissions: macOS TCC grants (Accessibility, Screen Recording, …). Tool Auto/Ask/Deny policies live on the Tools tab.
- Identity, Privacy → Storage (encryption/backup), Channels credentials.
- Secrets of any kind (API keys, tokens) are always entered in native secure fields, never chat.

## Common names that are different controls

**Automatically Check Model Updates**, in Settings → Local Models, checks
metadata for installed official OsaurusAI Hugging Face models every six hours.
It is enabled by default and saved immediately. Turn it off to stop these
automatic checks; **Check for Model Updates** in a model's details remains a
manual action. Failures remain errors and retry with backoff. Checking never
downloads or replaces model weights. This switch is Settings UI only and is
separate from updating the Osaurus application.

| You might say | Actual control | Path |
|---|---|---|
| Context window / context budget / context length | Context Window Cap (tokens) | Settings… (⌘,) → Server → Settings → Cache → Context & KV Policy |
| Context budget (in chat) | Context Budget popover | Chat composer — read-only; Open Context Window Cap jumps to Server → Cache |
| Memory budget / token budget (memories) | Memory Budget | Settings… (⌘,) → Memory → Configuration |
| Max tokens (reply length) | Max Output Tokens | Settings… (⌘,) → Orchestrator → Model & Generation |
| Subagent limits / "agents end too fast" | Limits (Max output tokens per subagent, Max turns per subagent, Time limit per subagent) | Settings… (⌘,) → Orchestrator → Subagents → Limits |
| Orchestrator folder / file access | Working Folder | Settings… (⌘,) → Orchestrator → Working Folder (or the chat Folder chip) |
| Ask before delegating | Permission / Permission for shared (workspace) agents | Settings… (⌘,) → Orchestrator → Subagents → Permission |
| Max tokens (API defaults) | Generation Defaults → Max Tokens | Settings… (⌘,) → Server → Settings → Sampling Defaults |
| KV / cache window | KV Retention Override | Same Cache panel as the context cap |
| Tool permissions | Could be Tools catalog, Chat folder tools, or macOS Permissions — ask `find` |
| Calendar / Reminders / Contacts / Notes / Mail / Messages / Maps / Music / Shortcuts access for an agent | Apple app groups in the tool picker (one group per app, toggled per app) | Settings… (⌘,) → Agents → *custom agent* → Abilities → Tools (declarative: `agents[].capabilities.apple_apps`) |
| Calendar / Contacts / Automation grant for the whole app | macOS permission | Settings… (⌘,) → Permissions (or the **Permission needed** badge on the app's group under Agents → Abilities → Tools) |

## Apple Apps (built-in)

Osaurus ships native tools for Calendar, Reminders, Contacts, Notes, Mail, Messages, Maps & Location, Music, and Shortcuts. They are **off by default** for every agent and are turned on per custom agent under **Agents → Abilities → Tools**, where each app is a group in the tool picker (Calendar, Reminders, …) listed above the plugin and MCP groups. The group's master checkbox — or any row switch, marked **Per app** — turns all of that app's tools on or off together; individual tools are not toggled separately. Turning an app on (in an existing agent or the Create Agent sheet) asks macOS for that app's permission right away (Calendar, Reminders, Contacts, Location, or Automation for Notes/Mail/Messages/Music; Messages reading needs Full Disk Access via System Settings). A denied grant does not flip the switch back — the group header shows a **Permission needed** badge; clicking it re-asks for any grant macOS can still prompt for and then opens the System Settings pane for whatever is still missing (Full Disk Access, or an Automation grant that was denied). Sending mail or messages and running deletes always show an approval card; "Allow for this run" never covers them. The Default agent (Orchestrator) has no Apple app groups in its picker and never calls these tools; it manages them on custom agents through `osaurus_config` (`capabilities.apple_apps`, the full list replaces the set, `[]` turns all off) and can provision a new agent with apps in the same call. The former `osaurus.calendar` / `.reminders` / `.contacts` / `.notes` / `.mail` / `.messages` / `.maps` / `.music` plugins are superseded by these built-ins.

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
and remote children do not need a swap. Local image jobs and context compaction
use this same parent-swap setting. The image Load policy controls only image-model
cleanup after the job; restoring a swapped parent always drains and unloads the
image model first. Independent scheduled/watch jobs and background helpers do
not gain permission to evict unrelated chat models from this switch. A scheduled
or watched agent's nested delegation uses that job's own invoking model.

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

General, Chat, Voice, Themes, Credits, Workspaces, Identity, Permissions, Privacy, Local Models, Providers, Media, Orchestrator, Agents, Channels, Web Search, Knowledge, Memory, Tools, Skills, Commands, Schedules, Watchers, Computer Use, Browser Use, Server, Sandbox, Insights.

## Where settings are stored

Config JSON lives under `~/.osaurus/config/` (`server.json`, `server-runtime.json`, `chat.json`, `default-agent.json`, `agent-delegation.json`, `memory.json`, …). Secrets live in the macOS Keychain.

### SSD cache controls

Normal cache filling and eviction are silent. Cache state is available in the
context-budget popover and Live Activity; there is no inline capacity-notice
popup or suppression setting.

**Clear SSD Cache** remains available in Cache settings and removes indexed
conversation cache files and linked companion data. Chats and model weights are
preserved. Clearing can make the next reply slower while cached data rebuilds;
it does not increase the cache limit. Save directory changes before clearing the
SSD cache; Clear is disabled while the displayed directory differs from the saved
directory. Clearing remains available when prefix reuse is disabled.

Disk Cache Size left blank uses **Automatic**: 30% of free space plus the cache's indexed payload bytes, including companions. Cache growth therefore does not shrink its own quota. An explicit percentage remains a percentage of total volume size, bounded by 25% of free space plus this cache; Settings shows the requested and effective amounts when limited. Existing percentages and legacy GB choices are preserved. Editing the percentage field replaces a legacy GB choice; clearing an explicit percentage selects Automatic. For a saved legacy GB choice, click **Use Automatic Cache Size**, then Save Changes.

Saving only the disk size updates resident models without unloading their weights. A decrease is enforced at the next cache write. Low free space produces an advisory and does not silently disable caching. Prefix Cache remains the master reuse switch; with paged RAM off, SSD reuse can still operate independently.

Cache controls are individually searchable: **Prefix Cache**, **Enable GPU Cache**,
**Block Size (tokens)**, **Max Blocks**, **Disk Cache**, **Disk Cache Directory**,
**Disk Cache Size (% of disk)**, **Clear SSD Cache**,
and **Re-derive SSM State After Generation**. Each result opens Server → Settings
→ Cache and scrolls to that control. Prefix Cache controls all reuse; Enable GPU
Cache controls the optional RAM tier, Disk Cache controls SSD reuse, and the
SSM option retains architecture-specific companion state for hybrid models.
