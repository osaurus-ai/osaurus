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
- Agents: create/update custom agents, capability toggles, the active agent.
- Tools: global enablement and permission policies; delegation settings and child budgets.
- Plus everything else the declarative document covers: models, providers, MCP servers, plugins, commands, knowledge collections, channel routing, schedules, watchers, and web-search providers.

## What lives only in the Settings UI

- Server: port, expose to network, generation defaults, batching/concurrency, prefix/paged-KV/disk cache, **Context Window Cap**, KV retention, memory safety, model exposure. (Port and exposure changes restart the server; cache changes unload loaded models.)
- Orchestrator: the identity fields above are also editable in Settings → Orchestrator, alongside its delegation helpers (spawn allow-list, budgets, RAM safety).
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
| Max tokens (reply length) | Max Output Tokens | ⌘⇧M → Orchestrator → Generation |
| Max tokens (API defaults) | Generation Defaults → Max Tokens | ⌘⇧M → Server → Settings → Sampling Defaults |
| KV / cache window | KV Retention Override | Same Cache panel as the context cap |
| Tool permissions | Could be Tools catalog, Chat folder tools, or macOS Permissions — ask `find` |

Unknown-Model Metadata Fallback on the same Cache panel does **not** constrain local models. Use Context Window Cap to lower the window.

## Management sidebar

General, Chat, Voice, Themes, Credits, Workspaces, Identity, Permissions, Privacy, Local Models, Cloud Models, Media, Orchestrator, Agents, Channels, Web Search, Knowledge, Memory, Tools, Skills, Commands, Schedules, Watchers, Computer Use, Browser Use, Server, Sandbox, Insights.

## Where settings are stored

Config JSON lives under `~/.osaurus/config/` (`server.json`, `server-runtime.json`, `chat.json`, `default-agent.json`, `memory.json`, …). Secrets live in the macOS Keychain.
