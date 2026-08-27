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

## Per-agent features (agent → Abilities → Overview)

- Tools (on by default) and Memory (on by default).
- Off by default, opt in per agent: Charts, Voice output, Memory Recall (search past memory), Self-scheduling, Computer Use, Database (per-agent private SQLite), Knowledge collections, sandbox execution options.
- Host Files: grant a working folder so the agent gets file read/write/edit/search, shell, and git tools in that folder.

## The Orchestrator (default agent) vs custom agents

- The Orchestrator only configures and explains Osaurus, and delegates work to the agents and models you allow. It cannot use skills, knowledge, browser, computer use, or file tools — that keeps setup safe and predictable.
- Custom agents get the full capability surface, gated by your per-agent feature toggles and tool permissions.

## Agent identity and settings

- Each agent can have its own theme (activating the agent applies it), avatar, greeting, quick actions, and voice.
- Custom agents are stored as JSON under `~/.osaurus/agents/<uuid>.json`. The Orchestrator's own settings (name, persona, temperature, max tokens, delegation helpers) live in Settings → Orchestrator, or ask the assistant to change them.

## Subagents and delegation

Agents can delegate work to subagents (spawn other local/cloud models in parallel), with budgets and permission modes you control. The Orchestrator's delegation allow-list and budgets live in Settings → Orchestrator; each custom agent's spawn policy lives in its own Subagents tab.
