---
title: Cloud Providers
summary: Connect OpenAI, Anthropic, Gemini, xAI, OpenRouter, Ollama, and more alongside local models.
order: 30
---

# Cloud Providers

Osaurus can use cloud or peer inference providers alongside local models. Your context, memory, and agents stay on your Mac regardless of which provider serves the model.

## Adding a provider

- Management (⌘⇧M) → Providers → Add Provider → pick a preset or Custom → Save.
- Presets include Anthropic, OpenAI, xAI, and OpenRouter; Gemini, Venice AI, and Osaurus Router are also supported. Custom works with any OpenAI-, Anthropic-, or Open Responses-format API.
- Or ask the default Osaurus assistant in chat to add a provider — API keys are entered through a secure native sheet that stores them straight to the macOS Keychain (never through chat text).

## Provider settings

- Name, Host, Protocol, Port, Base Path, Auth Type (None / API Key), Enabled, Auto-connect, Timeout, and custom headers (secret headers go to Keychain).
- Connection states on each card: Connected (green), Connecting, Disconnected, Disabled, Error (red). Non-secret config is stored in `~/.osaurus/providers/remote.json`.

## Using remote models

- The chat model picker groups each provider's discovered models under the provider name.
- Local apps pointed at Osaurus's API (`http://127.0.0.1:1337/v1/chat/completions`) can use remote models through the same endpoint — Osaurus routes by model id (e.g. `anthropic/claude-...`).

## Local servers as providers

- Ollama: add a Custom provider at `localhost:11434`, base path `/v1`.
- LM Studio: `localhost:1234`, base path `/v1` (enable its server first).

## Osaurus Router and peers

- Osaurus Router is a hosted routing service tied to your Osaurus identity (Credits tab shows usage); it auto-connects at startup when configured.
- Paired Osaurus devices (peers) can share models, or expose whole remote agents that run with their own tools on the other machine.
