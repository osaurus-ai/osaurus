---
title: Getting Started with Osaurus
summary: What Osaurus is, system requirements, and how to find your way around.
order: 10
---

# Getting Started with Osaurus

Osaurus is a free, open-source macOS AI app: agents, memory, tools, and identity that live on your Mac. It runs fully offline with local models, and connects to cloud providers only when you choose. MIT licensed, built in native Swift for Apple Silicon.

## Requirements

- macOS 15.5 or newer, Apple Silicon (M-series) Mac.
- Download from the GitHub releases page or `brew install --cask osaurus`.
- Docs: https://docs.osaurus.ai · Models: https://huggingface.co/OsaurusAI · Community: Discord (invite on the website/repo).

## Finding your way around

- Chat window: global hotkey (default ⌘;) or launch Osaurus from Spotlight.
- Settings… (⌘,) opens the Management window. The sidebar has every area: General, Chat, Voice, Themes, Credits, Workspaces, Identity, Permissions, Privacy, Local Models, Providers, Media, Orchestrator, Agents, Channels, Web Search, Knowledge, Memory, Tools, Skills, Commands, Schedules, Watchers, Computer Use, Browser Use, Server, Sandbox, Insights. Type a setting name in the sidebar search to jump to it.
- CLI (install from Settings… (⌘,) → General → Command Line Tool → Install CLI): `osaurus ui`, `osaurus serve`, `osaurus status`.

## First steps

1. Download a local model (Local Models tab) or add a cloud provider (Providers tab).
2. Open chat and talk to the default Osaurus assistant — it can configure the app for you (download models, add providers, change settings) and answer questions about any feature.
3. Create custom agents (Agents tab) for real work: coding, research, files, web — each with its own prompt, tools, memory, and theme.

## The default Osaurus assistant

The built-in "Osaurus" agent in chat is the front door for setup: ask it "what's configured?", "download a model", "add a provider", "change a setting", or any "how does X work?" question. For tasks beyond configuring Osaurus (coding, web research, file work), it will offer to create or switch to a fitting agent.

## Where data lives

Everything is stored locally under `~/.osaurus/` (chats, memory, agents, config). Local models live in `~/MLXModels` by default. Nothing leaves your Mac unless you connect a cloud provider or enable network exposure.
