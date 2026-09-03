---
title: The Orchestrator
summary: The built-in agent that configures Osaurus, answers questions, and delegates work to your agents.
order: 45
---

# The Orchestrator

The built-in Osaurus agent is the default Orchestrator. New chat windows open on it unless you start a chat on a custom agent. It has two jobs:

1. **Configure and explain Osaurus.** It answers questions about the app and changes settings for you through the declarative `osaurus_config` tool (see the Declarative Configuration topic): it plans the change, shows an approval card, and applies only after you confirm.
2. **Delegate work.** It can spawn your custom agents and allowed local/cloud models as subagents — in parallel, within budgets you set — and weave their results back into the conversation.

It deliberately does *not* do hands-on work itself: no sandbox, no working folder, no browser or computer use. Those capabilities belong to custom agents, which keeps the Orchestrator safe and predictable.

The chat composer does not offer a working-folder chip on the Orchestrator. To list or edit files, create or switch to a custom agent, then pick the working folder on that agent. You can also ask the Orchestrator to create the agent and switch to it.

## Settings → Orchestrator

The Orchestrator has its own settings tab (Management ⌘⇧M → Orchestrator):

- **Identity** — display name (defaults to "Osaurus") and system prompt (persona). Its model is picked from the chat model selector, or ask it to switch models.
- **Generation** — temperature and max output tokens.
- **Delegation** — its delegation helpers:
  - *Main Chat Capabilities*: allow image or AppleScript helper models.
  - *Main Chat Spawn*: the allow-list of agents and local/cloud models it may delegate to, worker tool access, permission mode, and child budgets (tokens, turns, tool calls, seconds, parallel spawns).
  - *Local Handoff & RAM Safety*: local orchestrator handoff, RAM-safety preflight, and the experimental coexistence mode.

Custom agents join this spawn pool automatically on creation; existing custom agents are seeded once. Remove an agent in Settings → Orchestrator if you do not want it spawnable — removals persist. Local/cloud model targets stay on an explicit allow-list.

## Renaming the Orchestrator

Set a custom name in Settings → Orchestrator → Identity, or declaratively:

```yaml
default_agent:
  name: Jarvis
```

`name: null` restores "Osaurus". The name is cosmetic — the agent's identity, tools, and behavior are unchanged.

## Typical asks

- "What's configured?" / "Change a setting" — inspects live state and plans config changes for approval.
- "Create a research agent with web search and switch to it."
- "Delegate this to my coding agent and summarize the result."
- "Export my setup as a template."

## Where its settings are stored

Identity fields persist to `~/.osaurus/config/default-agent.json`; delegation settings to `~/.osaurus/config/agent-delegation.json`. Both are covered by the declarative document (`default_agent` and `delegation` sections).
