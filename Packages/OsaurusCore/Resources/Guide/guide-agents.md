---
title: Agents
summary: Create custom agents with their own prompt, model, tools, memory, and theme.
order: 40
---

# Agents

Agents are the core of Osaurus. Each agent has its own system prompt, default model, tool grants, memory, and look. The built-in "Osaurus" default agent — the Orchestrator — configures the app, answers questions about it, and delegates work to your custom agents; custom agents do everything else (see The Orchestrator topic).

## Creating and managing agents

- Settings… (⌘,) → Agents → create, edit, or delete agents.
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
- Working Folder: the one folder the agent works inside. Picking a folder with the chat Folder chip — or in the picker the agent itself opens with `prompt_working_folder` when a folder-less chat needs files — remembers it on the agent, so new chats, schedules, watchers, and other background runs without their own folder start there; it also grants remote agent runs file access confined to that folder. Inside it, `file_read` handles every file type (text, PDF, Word, PowerPoint, Excel preview, images for vision models or via OCR) and `file_write` generates `.xlsx`, `.docx`, and `.pdf` as well as text — see the Chat topic, "File formats the folder tools handle".

## The Orchestrator (default agent) vs custom agents

- The Orchestrator configures and explains Osaurus, answers short questions inline, and delegates everything else to the agents you allow. It has a working folder it can **read** (`file_read`, `file_search`) but no shell, sandbox, browser, computer use, skills, knowledge, or media tools — that keeps setup safe and predictable.
- For hands-on work (edit files, run code, browse, generate images) the Orchestrator delegates to a custom agent. An agent without its own working folder works inside the Orchestrator's folder, so a fresh agent can write deliverables there right away. You can also switch to the agent and work with it directly.
- Custom agents get the full capability surface, gated by your per-agent feature toggles and tool permissions. Delegated agents run with their normal tools; only the delegation tool itself is withheld from a worker.
- New agents the Orchestrator creates with no model default to its current model. `template: coder | researcher | writer | assistant | productivity` fills in the system prompt and a routing description; a `description` is optional and is generated in the background from the system prompt when omitted; Settings → Orchestrator → Subagents → **Create starter agents** makes Coder, Researcher, and Writer in one click.

## Agent identity and settings

- Each agent can have its own theme (activating the agent applies it), avatar, greeting, quick actions, and voice.
- Custom agents are stored as JSON under `~/.osaurus/agents/<uuid>.json`. The Orchestrator's own settings (name, persona, temperature, max tokens, delegation helpers) live in Settings → Orchestrator, or ask the assistant to change them.

## Subagents and delegation

Agents can delegate work to other agents with `spawn_agent` — several calls in one message run in parallel as one wave — with limits and permission modes you control. Targets are your custom agents and, in workspaces you belong to, teammates' shared agents (`Name@Workspace`; see the Workspaces topic). The Orchestrator's allowed subagents, permissions, and limits live in Settings → Orchestrator → Subagents; each custom agent's "Delegate to subagents" settings live in its own Subagents tab. Deleting an agent removes it from every allow-list at once.
