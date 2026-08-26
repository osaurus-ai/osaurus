---
title: Settings Overview
summary: Where every setting lives, and which ones the assistant can change for you.
order: 120
---

# Settings Overview

Osaurus settings live in the Management window (⌘⇧M). The built-in assistant can change many of them directly in chat via its `osaurus_config` tool, which plans and applies a declarative YAML document — each change shows a one-tap approval card first (see the Declarative Configuration topic).

## What the assistant can change in chat

- Default agent (itself): model, temperature, max tokens, persona (system prompt).
- Memory: enabled, budget tokens, retention days.
- Agents: create/update custom agents, capability toggles, the active agent.
- Tools: global enablement and permission policies; delegation settings and child budgets.
- Plus everything else the declarative document covers: models, providers, MCP servers, plugins, commands, knowledge collections, channel routing, schedules, watchers, and web-search providers.

## What lives only in the Settings UI

- Server: port, expose to network, generation defaults, batching/concurrency, prefix/paged-KV/disk cache toggles, memory safety, model exposure. (Port and exposure changes restart the server; cache changes unload loaded models.)
- Chat behavior: core model for background jobs, context length, chat titles, clipboard monitoring.
- App: start at login, hide dock icon, appearance, global hotkey, notifications/toasts.
- Voice: speech-to-text models, dictation, wake phrase, text-to-speech engine and voice.
- Themes: theme gallery, custom theme editor, import/export.
- Computer Use / Browser / Sandbox: autonomy presets, app allowlists, resources.
- Permissions: per-tool and per-agent approval policies.
- Identity, Storage (encryption/backup), Privacy, Channels credentials.
- Secrets of any kind (API keys, tokens) are always entered in native secure fields, never chat.

## Where settings are stored

Config JSON lives under `~/.osaurus/config/` (`server.json`, `server-runtime.json`, `chat.json`, `default-agent.json`, `memory.json`, …). Secrets live in the macOS Keychain.
