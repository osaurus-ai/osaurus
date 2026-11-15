# The Orchestrator

The built-in Osaurus agent (`Agent.default`) is the default Orchestrator. Unspecified new chat windows open on it; a chat can also open directly on a custom agent (for example via `initialAgentId`). It is a router: when a request needs no tool it answers itself, and when it needs any tool it routes the request and presents what comes back. Its whole tool surface is `ToolRegistry.orchestratorRoutingToolNames`:

- `configurator_handoff` — anything about Osaurus itself (how a feature works, what is configured, any settings change) goes to the **Configurator**, which runs behind the chat in the same turn and owns `osaurus_help`, `osaurus_inspect` and `osaurus_config`. Changes are planned, shown on an approval card, and applied only after you confirm. The Orchestrator never changes a setting itself.
- `run_workflow` — runs an installed workflow marked visible to the Orchestrator, and also hands a task to one of your allowed agents or a built-in helper (Research, Files, Browser, Code) as a one-step workflow.
- `architect_handoff` — new multi-step work with no workflow for it goes to the Architect, which builds a small workflow and runs it in the chat.
- `status` — what is loaded, running, or waiting on you.
- `state` — rewrites the chat's session state once per turn.
- `clarify` — one clarifying question, only when the route is unclear.

It does no hands-on work itself: no file reading or writing, no shell, no sandbox, no web search, no browser or computer use, no media tools, no Apple app tools, and no `spawn_agent`. Those belong to custom agents and the built-in helpers.

**Filesystem work.** Pick a folder with the Folder chip on an Orchestrator chat, or in Settings… (⌘,) → Agents → Orchestrator → Working Folder. The Orchestrator never reads or writes it and has no `prompt_working_folder` tool. The folder is what delegated agents inherit: an agent with no working folder of its own works inside it (read and write), so "write the report into the folder" works out of the box. For direct filesystem work:

1. Create a custom agent (or select one you already have) from the agent picker.
2. Pick the working folder on that agent's chat composer, or let it inherit the Orchestrator's folder.
3. Ask the custom agent to do the filesystem work. You can stay on that agent, or ask the Orchestrator to hand it the task if it is on **Allowed subagents**.

See [AGENT_LOOP.md](AGENT_LOOP.md) for the folder/sandbox tool contract on custom agents.

**Apple apps are a custom-agent path too.** The Orchestrator never calls the built-in Calendar / Reminders / Contacts / Notes / Mail / Messages / Maps / Music / Shortcuts tools; they are in `orchestratorExcludedToolNames`. The Configurator hands them out: `osaurus_inspect` lists each agent's `apple_apps`, and `osaurus_config` sets `capabilities.apple_apps` on an existing agent or provisions a new one with the apps it needs — plan, approval card, apply. The Orchestrator then hands the task to that agent with `run_workflow`. Enabling Mail, Messages, or Shortcuts adds a risk line to the plan card because those apps act on your behalf. See [APPLE_APPS.md](APPLE_APPS.md).

## Settings

Settings… (⌘,) → Agents pins **Orchestrator**, **Architect**, and **Configurator** under **Built-in**, and **Delegation** under **Working Together**.

**Agents → Orchestrator:**

- **Identity** — Orchestrator Name (defaults to "Osaurus"), Orchestrator Avatar, and System Prompt (persona). The model itself is picked from the chat model selector.
- **Model & Generation** — the Model Readiness row (current chat model, context window, whether tools are OK or limited), then Temperature and Max Output Tokens.
- **Working Folder** — the folder folder-less delegated agents inherit. UI-only; it is not part of the declarative document.
- **Subagents** — one row, **Allowed Subagents and Limits**, which opens Agents → Delegation.
- **Delegations** — every delegated run (Sent / Received), with status, duration, tokens, and Open Chat. UI-only.

**Agents → Delegation:**

- **Subagents**
  - *Allowed subagents* — custom agents join on creation; teammates' shared agents join as their workspace roster loads. Removals persist.
  - *Permission* — whether to ask before local agents run. *Permission for shared (workspace) agents* defaults to Ask.
  - *Limits* — max output tokens (8192), turns (24), and time (900 s) per subagent, plus max local (3) and remote (8) subagents at once. There is no separate tool-call cap.
  - *Advanced* — agent-target model override (leave it on "Use each agent's model" unless you need one model for every worker).
- **Local Models & Memory** — **Swap Local Models for Subagents** and **Check Memory Before Delegating**, shared by the Orchestrator and every custom agent. The former experimental coexistence ("keep the chat model loaded") toggle is gone; its old configuration key is retained only for compatibility.

Custom agents are added to the allowed pool automatically on creation, and existing custom agents are seeded once. You can remove agents in Agents → Delegation; removals persist. An empty agent pool after you clear it leaves the Orchestrator with no agents to hand work to.

## How delegation runs

A **different local model** normally uses single-residency handoff so two large models never fight for memory, unless the shared swap setting is off:

- **Different local child:** RAM-safety preflight → unload the resident chat model → load and run the subagent model → unload it → restore the chat model → continue the turn. Conversation context (including images) is preserved across the handoff.
- **Same-model child:** the resident model is reused in place; there is no unload/reload.
- **Swap off:** the invoking model stays resident while the child runs, including under Strict; separate memory admission can refuse without evicting the parent.
- **Cloud orchestrator model:** no unload/reload — nothing is resident. The local subagent still runs and returns a compact result; preflight and permissions still apply to the subagent load.

The RAM-safety preflight refuses *before* evicting anything: if the subagent model won't fit, the chat model stays resident and the Orchestrator reports the shortfall instead of thrashing. Local Orchestrator Handoff is on by default and enforces one sequence for every delegation whose helper is a *different* local model — unload the chat model → load the helper → run → unload the helper → load the chat model back → continue the turn — whether or not the chat model was loaded when the delegation started, and for any agent that delegates (a custom agent's own model is the one swapped out and restored). Same-model helpers and cloud helpers never swap. With **Swap local models for subagents** off, a different-model helper retains the exact invoking parent through the job. Only that job's cold-loaded child is cleaned up afterward; previously shared residents are preserved. A queued dispatch captures its own residency authority. The former experimental coexistence flag is now inert. The spawn result reports what happened (`residency_mode`, and for a swap `handoff_sequence` + `handoff_summary`), and the activity feed shows a "model swap" line. All of these live in Settings → Agents → Delegation → Local Models & Memory; the same toggle is mirrored (read-only) in every spawn editor and exported as `delegation.local_text_enabled`.

Local image jobs and context compaction follow the same invoking-parent switch.
The image load-policy menu controls only image cleanup, not whether the chat
model unloads. A swapped parent is restored only after image producer drain and
unload; swap OFF holds the parent's exact resident generation through the job.
Independent scheduled/watcher work has no authority over the frontmost chat;
its own nested helpers use that job's parent/source. See
`auxiliary-handoff-parity-2026-09-17.md` for the pending verification matrix.

## Renaming the Orchestrator

Set a custom name in Settings → Agents → Orchestrator → Identity, or declaratively:

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
- "Make me an agent from the Cloud Agent template that summarizes RSS feeds." — bases the new agent on a template flagged Available to the Orchestrator (Agents → Templates).
- "Run Daily Digest every weekday at 8." / "Every morning, send me a quote." — an `automations:` entry (workflow, or instructions alone).

## Workflows and automations

"Run something when X happens" is an `automations:` entry, applied by the Configurator through `osaurus_config`. What it runs is picked in this order:

1. An installed workflow (`workflow` + `input`). `osaurus_inspect` lists every installed workflow with `orchestrator_can_run`; `run_workflow` itself stays limited to workflows marked visible.
2. A new workflow: the Orchestrator's `architect_handoff`, with the trigger in the brief. The Architect passes it as `trigger` on `workflow_propose_save`, validated by `ConfigEvents.build` against the draft, and the save card creates the automation on Save (`WorkflowSavePromptState.save`).
3. An agent, only for open-ended tool work.
4. `instructions` alone: a `prompt` action (`EventAction.prompt`, `PromptRunWorker`) that runs one tool-less generation. It never runs the Default agent, so `BuiltInAgentGuard` still holds.

## Scope and security

- **In-app only.** The Orchestrator is never exposed on external surfaces: `POST /agents/{id}/run` and `/agents/{id}/dispatch` reject `Agent.defaultId` with `built_in_agent_not_exposable`. Only your saved custom agents are reachable over HTTP, plugins, or schedulers.
- **Routing only.** The Orchestrator's tool surface (`ToolRegistry.ToolSurface.orchestrator`) is `orchestratorRoutingToolNames`. File tools (reading included), shell, `share_artifact`, the configure tools (`osaurus_config`, `osaurus_inspect`, `osaurus_help`) and the Apple app tools are additionally listed in `orchestratorExcludedToolNames`, so not even a ticked manual name or a session load puts one in its schema.
- **Spawn pool is default-on for custom agents.** Existing custom agents are seeded into the Orchestrator's spawn pool once, and newly created agents are added automatically (`SubagentConfiguration.spawnableAgentIDs` / `AgentManager.registerInDefaultSpawnPool`). Removals in Settings → Agents → Delegation persist.

## Where its settings are stored

Identity and the working folder persist to `~/.osaurus/config/default-agent.json` (`DefaultAgentConfiguration`); delegation settings to `~/.osaurus/config/agent-delegation.json` (`SubagentConfiguration`). The declarative document covers identity (`default_agent`) and delegation (`delegation`); the working folder is set from the chat Folder chip or Settings… (⌘,) → Agents → Orchestrator → Working Folder. See the in-app Guide's Declarative Configuration topic and `docs/examples/osaurus-config.sample.yaml`.

## Key source locations

- `Packages/OsaurusCore/Models/Agent/Agent.swift` — `Agent.default` / `Agent.defaultId`
- `Packages/OsaurusCore/Models/Agent/DefaultAgentConfiguration.swift` — identity persistence
- `Packages/OsaurusCore/Models/AgentDelegation/SubagentConfiguration.swift` — delegation policy
- `Packages/OsaurusCore/Services/Chat/DefaultAgentSystemPromptBuilder.swift` — system prompt
- `Packages/OsaurusCore/Views/Settings/OrchestratorSettingsView.swift` — Agents → Orchestrator
- `Packages/OsaurusCore/Views/Settings/SubagentSettingsSection.swift` — Agents → Delegation
- `Packages/OsaurusCore/Subagent/` — spawn host, residency handoff, subagent kinds
