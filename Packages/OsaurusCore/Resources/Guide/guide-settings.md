---
title: Settings Overview
summary: Where every setting lives, and which ones the assistant can change for you.
order: 120
---

# Settings Overview

Osaurus settings live in the Management window (⌘⇧M). The built-in assistant can change many of them directly in chat via its settings tool — each change shows a one-tap approval card first.

## What the assistant can change in chat

- Server: port, expose to network, generation defaults (temperature, top-p, top-k, max tokens), continuous batching, max concurrent sequences, prefix/paged-KV/disk cache toggles. Port and exposure changes restart the server; cache changes unload loaded models.
- Default agent (itself): model, temperature, max tokens, persona (system prompt).
- Chat: top-p, max tool attempts, context length, warm models on load, auto-generated chat titles, clipboard monitoring.
- App: start at login, hide dock icon (takes effect after app restart), appearance (system / light / dark).
- Memory: enabled, budget tokens, retention days.
- Plus everything covered by the other configure tools: models, providers, MCP, plugins, schedules, agents, and web-search providers.

## What lives only in the Settings UI

- General: global hotkey, core model for background jobs, notifications/toasts.
- Voice: speech-to-text models, dictation, wake phrase, text-to-speech engine and voice.
- Themes: theme gallery, custom theme editor, import/export.
- Computer Use / Browser / Sandbox: autonomy presets, app allowlists, resources.
- Permissions: per-tool and per-agent approval policies.
- Identity, Storage (encryption/backup), Privacy, Channels credentials.
- Secrets of any kind (API keys, tokens) are always entered in native secure fields, never chat.

## Where settings are stored

Config JSON lives under `~/.osaurus/config/` (`server.json`, `server-runtime.json`, `chat.json`, `default-agent.json`, `memory.json`, …). Secrets live in the macOS Keychain.
