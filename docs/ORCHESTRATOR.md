# The Orchestrator

Every chat in Osaurus starts with the Orchestrator — the built-in "Osaurus" agent (`Agent.default`). It has two jobs:

1. **Configure and explain Osaurus.** It answers questions about the app from live state and changes settings for you through the declarative `osaurus_config` tool: it plans the change, shows an approval card, and applies only after you confirm.
2. **Delegate work.** It can spawn your custom agents and allowed local/cloud models as subagents — in parallel, within budgets you set — and weave their compact results back into the conversation.

It deliberately does *not* do hands-on work itself: no sandbox, no working folder, no browser or computer use. Those capabilities belong to custom agents, which keeps the Orchestrator safe and predictable.

## Settings → Orchestrator

The Orchestrator has its own settings tab (Management `⌘⇧M` → Orchestrator):

- **Identity** — display name (defaults to "Osaurus") and system prompt (persona). Its model is picked from the chat model selector, or ask it to switch models.
- **Generation** — temperature and max output tokens.
- **Delegation** — its delegation helpers:
  - *Main Chat Capabilities*: allow image or AppleScript helper models.
  - *Main Chat Spawn*: the allow-list of agents and local/cloud models it may delegate to, worker tool access, permission mode, and child budgets (tokens, turns, tool calls, seconds, parallel spawns).
  - *Local Handoff & RAM Safety*: local orchestrator handoff, RAM-safety preflight, and the experimental coexistence mode.

An empty spawn allow-list keeps delegation unavailable — the Orchestrator can only delegate to what you explicitly allow.

## How delegation runs

When the Orchestrator (or a custom agent) spawns a subagent on a **local** model, Osaurus performs a single-residency handoff so two large models never fight for memory:

- **Local orchestrator model:** RAM-safety preflight → unload the resident chat model → load and run the subagent model → unload it → restore the chat model → continue the turn. Conversation context (including images) is preserved across the handoff.
- **Cloud orchestrator model:** no unload/reload — nothing is resident. The local subagent still runs and returns a compact result; preflight and permissions still apply to the subagent load.

The RAM-safety preflight refuses *before* evicting anything: if the subagent model won't fit, the chat model stays resident and the Orchestrator reports the shortfall instead of thrashing. Local Orchestrator Handoff is on by default; both switches live in Settings → Orchestrator → Local Handoff & RAM Safety.

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

## Scope and security

- **In-app only.** The Orchestrator is never exposed on external surfaces: `POST /agents/{id}/run` and `/agents/{id}/dispatch` reject `Agent.defaultId` with `built_in_agent_not_exposable`. Only your saved custom agents are reachable over HTTP, plugins, or schedulers.
- **No hands-on tools.** The Orchestrator's tool surface (`ToolRegistry.ToolSurface.orchestrator`) excludes sandbox, working-folder, browser, and computer-use tools by construction.
- **Everything is opt-in.** Delegation targets, helper models, and budgets are all explicit allow-lists; nothing is spawnable until you add it.

## Where its settings are stored

Identity fields persist to `~/.osaurus/config/default-agent.json` (`DefaultAgentConfiguration`); delegation settings to `~/.osaurus/config/agent-delegation.json` (`SubagentConfiguration`). Both are covered by the declarative document's `default_agent` and `delegation` sections — see the in-app Guide's Declarative Configuration topic and `docs/examples/osaurus-config.sample.yaml`.

## Key source locations

- `Packages/OsaurusCore/Models/Agent/Agent.swift` — `Agent.default` / `Agent.defaultId`
- `Packages/OsaurusCore/Models/Agent/DefaultAgentConfiguration.swift` — identity persistence
- `Packages/OsaurusCore/Models/AgentDelegation/SubagentConfiguration.swift` — delegation policy
- `Packages/OsaurusCore/Services/Chat/DefaultAgentSystemPromptBuilder.swift` — system prompt
- `Packages/OsaurusCore/Views/Settings/OrchestratorSettingsView.swift` — Settings → Orchestrator
- `Packages/OsaurusCore/Subagent/` — spawn host, residency handoff, subagent kinds
