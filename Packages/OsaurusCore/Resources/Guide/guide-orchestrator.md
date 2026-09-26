---
title: The Orchestrator
summary: The built-in agent that configures Osaurus, answers questions, and delegates real work to your agents — locally or on teammates' Macs.
order: 45
---

# The Orchestrator

The built-in Osaurus agent is the default Orchestrator. New chat windows open on it unless you start a chat on a custom agent (or set `new_chat_agent` in the declarative document). It has two jobs:

1. **Configure and explain Osaurus.** It answers questions about the app and changes settings for you through the declarative `osaurus_config` tool (see the Declarative Configuration topic): it plans the change, shows an approval card, and applies only after you confirm. `osaurus_inspect` gives it read-only lookups (agents, models, providers, workspaces, shared agents, …).
2. **Delegate work.** Anything that needs tools, files, browsing, or sustained work goes to one of your agents through `spawn_agent`. Each delegation is a separate chat session with the target agent's own prompt, model, tools, and folder; the Orchestrator gets back a short summary and weaves it into the conversation. Short knowledge questions it simply answers inline.

It does not do hands-on work itself: no shell, no sandbox, no browser or computer use, no media tools. Those belong to custom agents. The one exception is its **working folder**, which it can read.

## Working folder

Pick a folder with the Folder chip on an Orchestrator chat, or in Settings → Orchestrator → Working Folder. With a folder set the Orchestrator can **read** it (`file_read`, `file_search`) — list what is there, open a deliverable a worker wrote, check a result. It never writes.

The folder is also what delegated agents inherit: an agent with no working folder of its own works inside the Orchestrator's folder (read and write), so "write the report into the folder" works out of the box. Agents that have their own folder keep it. Teammates' shared agents run on their owner's Mac and cannot see your folder at all — the Orchestrator puts everything they need in the task text.

## Delegating

- Several `spawn_agent` calls in one message run as one **wave**, in parallel, up to the "Max local/remote subagents at once" limits. One permission card covers the whole wave.
- Workers write deliverables into the (inherited) folder and return a short summary with the paths; the Orchestrator reads the files when it needs the content.
- A worker that needs a decision ends with `NEEDS INPUT: …`. The Orchestrator asks you, then answers with `spawn_agent` `continue: <session_id>`, which reattaches to the same worker session (history intact) instead of starting over. `continue` also works for shared workspace agents.
- Results from teammates' shared agents come back as a digest plus any **small files** the agent shared with `share_artifact` (a few MB in total), promoted to artifact cards on your chat. Larger files stay on the teammate's Mac and the worker says so.

## Settings → Orchestrator

Settings… (⌘,) → Orchestrator:

- **Identity** — display name (defaults to "Osaurus") and system prompt (persona).
- **Model & Generation** — the **Model readiness** row shows the current chat model, its context window and whether tools are OK or limited, with a recommended-model hint when the window is small; then temperature and max output tokens. The model itself is picked from the chat model selector, or ask the Orchestrator to switch.
- **Working Folder** — the folder described above.
- **Subagents**
  - *Allowed subagents* — the agents the Orchestrator may delegate to. Every custom agent joins on creation; teammates' shared agents join automatically as their workspace roster loads. Remove one and it stays removed (a tombstone survives re-sharing) until you add it back. Deleted agents disappear from the list immediately — no stale references. With no agents yet, **Create starter agents** makes Coder, Researcher, and Writer on your current model and adds them.
  - *Permission* — whether to ask before local agents run. **Always Allow** is the default; each agent still shows its own permission cards for anything sensitive. *Permission for shared (workspace) agents* defaults to **Ask** because those runs leave your Mac and spend the workspace's pool; one card covers every shared agent in a wave, and the card names the agent, owner, and workspace.
  - *Limits* — per worker: **Max output tokens per subagent** (default 8192), **Max turns per subagent** (24 tool-call rounds), **Time limit per subagent** (900 s), plus **Max local subagents at once** (3, mirrors Server Concurrent Sessions) and **Max remote subagents at once** (8). Turns and time bound a worker; there is no separate tool-call cap. All of these are searchable from the Management sidebar.
  - *Advanced* — **Agent-target model override** runs every delegated agent on one model instead of its own. Leave it on "Use each agent's model" unless you need that.
  - *Local Models & Memory* — **Swap local models for subagents** and **Check memory before delegating**. The old experimental keep-the-chat-model-loaded toggle is gone.
- **Delegations** — every delegated run with its status, duration, tokens, tok/s, artifacts and an **Open Chat** button. **Sent** lists the runs this Osaurus delegated; **Received** lists runs a teammate's Orchestrator asked one of *your* shared agents to do.

Image generation, AppleScript, Browser Use, and Computer Use are custom-agent abilities. Give such an agent to the Orchestrator through Allowed subagents; there are no Orchestrator-level toggles for them.

## Teammates' shared agents (workspaces)

Agents teammates share into a workspace you belong to are delegation targets too. Ask "who can I delegate to?" and the Orchestrator lists them from `osaurus_inspect` (scope `shared_agents`: name, owner, workspace, online/offline, whether it is already in the pool). It addresses them as `Name@Workspace`. If a shared agent is offline the tool call is refused with the reason and the Orchestrator re-plans to another agent or tells you. See the Workspaces topic for sharing, the pool, and what comes back over the relay.

## Renaming the Orchestrator

Set a custom name in Settings → Orchestrator → Identity, or declaratively:

```yaml
default_agent:
  name: Jarvis
```

`name: null` restores "Osaurus". The name is cosmetic — the agent's identity, tools, and behavior are unchanged.

## Typical asks

- "What's configured?" / "Change a setting" — inspects live state and plans config changes for approval.
- "Create a research agent with web search." — new agents default to the Orchestrator's current model; `template: researcher` fills the prompt and description; a custom `description` of what the agent does and when to use it is optional and is generated from the system prompt when omitted.
- "Have Coder add tests to this project and tell me what changed." — delegated into the working folder; the summary names the files.
- "Ask Research@Acme for a market summary." — a teammate's shared agent, on their Mac.
- "Export my setup as a template."

## Where its settings are stored

Identity and the working folder persist to `~/.osaurus/config/default-agent.json`; delegation settings (allowed subagents, permissions, limits) to `~/.osaurus/config/agent-delegation.json`. The declarative document covers identity (`default_agent`) and delegation (`delegation`); the working folder is set from the chat Folder chip or Settings → Orchestrator → Working Folder.
