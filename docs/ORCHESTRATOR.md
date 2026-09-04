# The Orchestrator

The built-in Osaurus agent (`Agent.default`) is the default Orchestrator. Unspecified new chat windows open on it; a chat can also open directly on a custom agent (for example via `initialAgentId`). The Orchestrator has two jobs:

1. **Configure and explain Osaurus.** It answers questions about the app from live state and changes settings for you through the declarative `osaurus_config` tool: it plans the change, shows an approval card, and applies only after you confirm.
2. **Delegate work.** It can spawn your custom agents and allowed local/cloud models as subagents — in parallel, within budgets you set — and weave their compact results back into the conversation.

It deliberately does *not* do hands-on work itself: no sandbox, no working folder, no browser or computer use. Those capabilities belong to custom agents, which keeps the Orchestrator safe and predictable.

**Filesystem work is a custom-agent path.** Selecting a folder while chatting with the Orchestrator does not give it file, search, or git tools -- the composer hides the working-folder chip on this agent, and the runtime ignores any persisted folder bookmark for `Agent.defaultId`. To list, read, or edit files (for example `~/Downloads`):

1. Create a custom agent (or select one you already have) from the agent picker.
2. Pick the working folder on that agent's chat composer.
3. Ask the custom agent to do the filesystem work. You can stay on that agent, or ask the Orchestrator to spawn it as a subagent if it is on the spawn allow-list.

See [AGENT_LOOP.md](AGENT_LOOP.md) for the folder/sandbox tool contract on custom agents.

## Settings → Orchestrator

The Orchestrator has its own settings tab (Management `⌘⇧M` → Orchestrator):

- **Identity** — display name (defaults to "Osaurus") and system prompt (persona). Its model is picked from the chat model selector, or ask it to switch models.
- **Generation** — temperature and max output tokens.
- **Delegation** — its delegation helpers:
  - *Main Chat Capabilities*: allow image or AppleScript helper models.
  - *Main Chat Spawn*: the allow-list of agents and local/cloud models it may delegate to, worker tool access, permission mode, and child budgets (tokens, turns, tool calls, seconds, parallel spawns).
  - *Local Handoff & RAM Safety*: local orchestrator handoff, RAM-safety preflight, and the experimental coexistence mode.

Custom agents are added to this spawn pool automatically on creation, and existing custom agents are seeded once. You can remove agents in Settings → Orchestrator; removals persist. Local/cloud model targets stay on an explicit allow-list. An empty agent pool after you clear it keeps agent-spawn unavailable.

## How delegation runs

A **different local model** normally uses single-residency handoff so two large models never fight for memory, unless RAM-safe coexistence is explicitly enabled and admitted:

- **Different local child:** RAM-safety preflight → unload the resident chat model → load and run the subagent model → unload it → restore the chat model → continue the turn. Conversation context (including images) is preserved across the handoff.
- **Same-model child:** the resident model is reused in place; there is no unload/reload.
- **Experimental coexistence:** when enabled and the RAM-safety preflight admits both footprints, both models can stay resident.
- **Cloud orchestrator model:** no unload/reload — nothing is resident. The local subagent still runs and returns a compact result; preflight and permissions still apply to the subagent load.

The RAM-safety preflight refuses *before* evicting anything: if the subagent model won't fit, the chat model stays resident and the Orchestrator reports the shortfall instead of thrashing. Local Orchestrator Handoff is on by default and enforces one sequence for every delegation whose helper is a *different* local model — unload the chat model → load the helper → run → unload the helper → load the chat model back → continue the turn — whether or not the chat model was loaded when the delegation started, and for any agent that delegates (a custom agent's own model is the one swapped out and restored). Same-model helpers and cloud helpers never swap. With the handoff off, a different-model helper runs *without* that sequence (never refused) and the server eviction policy decides what stays loaded; the experimental coexistence mode applies only in that off state. The spawn result reports what happened (`residency_mode`, and for a swap `handoff_sequence` + `handoff_summary`), and the activity feed shows a "model swap" line. All of these live in Settings → Orchestrator → Local Handoff & RAM Safety; the same toggle is mirrored (read-only) in every spawn editor and exported as `delegation.local_text_enabled`.

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
- "Create a file-organizer agent with a working folder and switch to it."
- "Export my setup as a template."

## Scope and security

- **In-app only.** The Orchestrator is never exposed on external surfaces: `POST /agents/{id}/run` and `/agents/{id}/dispatch` reject `Agent.defaultId` with `built_in_agent_not_exposable`. Only your saved custom agents are reachable over HTTP, plugins, or schedulers.
- **No hands-on tools.** The Orchestrator's tool surface (`ToolRegistry.ToolSurface.orchestrator`) excludes sandbox, working-folder, browser, and computer-use tools by construction.
- **Spawn pool is default-on for custom agents.** Existing custom agents are seeded into the Orchestrator's spawn pool once, and newly created agents are added automatically (`SubagentConfiguration.spawnableAgentIDs` / `AgentManager.registerInDefaultSpawnPool`). Removals in Settings → Orchestrator persist. Local/cloud model targets and helper models remain explicit allow-lists.

## Where its settings are stored

Identity fields persist to `~/.osaurus/config/default-agent.json` (`DefaultAgentConfiguration`); delegation settings to `~/.osaurus/config/agent-delegation.json` (`SubagentConfiguration`). Both are covered by the declarative document's `default_agent` and `delegation` sections — see the in-app Guide's Declarative Configuration topic and `docs/examples/osaurus-config.sample.yaml`.

## Key source locations

- `Packages/OsaurusCore/Models/Agent/Agent.swift` — `Agent.default` / `Agent.defaultId`
- `Packages/OsaurusCore/Models/Agent/DefaultAgentConfiguration.swift` — identity persistence
- `Packages/OsaurusCore/Models/AgentDelegation/SubagentConfiguration.swift` — delegation policy
- `Packages/OsaurusCore/Services/Chat/DefaultAgentSystemPromptBuilder.swift` — system prompt
- `Packages/OsaurusCore/Views/Settings/OrchestratorSettingsView.swift` — Settings → Orchestrator
- `Packages/OsaurusCore/Subagent/` — spawn host, residency handoff, subagent kinds
