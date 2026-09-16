---
title: Agents
summary: Create custom agents with their own prompt, model, tools, memory, and theme.
order: 40
---

# Agents

Agents are the core of Osaurus. Each agent has its own system prompt, default model, tool grants, memory, and look. The built-in "Osaurus" default agent — the Orchestrator — configures the app, answers questions about it, and delegates work to your custom agents; custom agents do everything else (see The Orchestrator topic).

## Creating and managing agents

- Management (⌘⇧M) → Agents → create, edit, or delete agents.
- Or ask the default Osaurus assistant: "create a coding agent" — it can create, update, and switch agents for you.
- Switch agents from the agent menu in the chat window.

## Agent templates (Agents → Templates tab)

- A template is one agent's configuration as portable JSON: prompt, model, tool selection (MCP servers and plugins by name), sandbox, subagent settings, and a `requires` list of what the author relied on (working folder, knowledge collections, plugins, MCP servers, permissions, model). Secrets, folder access grants, and knowledge files never travel.
- Save one from any agent card (⋯ → Save as Template). Import one with the Import Template button, by pasting JSON, or by dropping a `.json` file on the Templates tab. Copy JSON from a template card to share it.
- Use Template opens the Create Agent sheet prefilled. Anything the template needs that this Mac does not have yet (a folder to pick, an MCP server to add) is listed above the form.
- "Available to the Orchestrator" (toggle on the card) lets you say "make me an agent from the Cloud Agent template that does X"; the Orchestrator bases the new agent on the template instead of enabling every tool.
- Templates live in `~/.osaurus/templates/<slug>.json`, next to whole-config YAML templates saved by `osaurus_config export`.

## Per-agent features (agent → Abilities → Overview)

- Tools (on by default) and Memory (on by default).
- Off by default, opt in per agent: Charts, Voice output, Memory Recall (search past memory), Self-scheduling, Computer Use, Database (per-agent private SQLite), Knowledge collections, sandbox execution options.
- Working Folder: the one folder the agent works inside. Picking a folder with the chat Folder chip remembers it on the agent, so new chats, schedules, watchers, and other background runs without their own folder start there; it also grants remote agent runs file access confined to that folder.

## The Orchestrator (default agent) vs custom agents

- The Orchestrator only configures and explains Osaurus, and delegates work to the agents and models you allow. It cannot use skills, knowledge, browser, computer use, or file tools — that keeps setup safe and predictable. The chat composer does not offer a working-folder chip on the Orchestrator.
- For filesystem work (list, read, or edit a folder), create or switch to a custom agent, then pick the working folder on that agent — or ask the Orchestrator to create the agent and switch to it.
- Custom agents get the full capability surface, gated by your per-agent feature toggles and tool permissions.

## Agent identity and settings

- Each agent can have its own theme (activating the agent applies it), avatar, greeting, quick actions, and voice.
- Custom agents are stored as JSON under `~/.osaurus/agents/<uuid>.json`. The Orchestrator's own settings (name, persona, temperature, max tokens, delegation helpers) live in Settings → Orchestrator, or ask the assistant to change them.

## Subagents and delegation

Agents can delegate work to subagents (other agents or local/cloud models, in parallel), with limits and permission modes you control. The Orchestrator's allowed subagents and limits live in Settings → Orchestrator → Subagents; each custom agent's "Delegate to subagents" settings live in its own Subagents tab.
