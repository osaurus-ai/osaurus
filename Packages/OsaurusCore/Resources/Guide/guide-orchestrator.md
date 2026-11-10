---
title: The Orchestrator
summary: The built-in agent you talk to. It answers what needs no tools and routes everything else — Osaurus questions and changes to the Configurator, installed workflows, your agents, and the built-in helpers to run_workflow, and new multi-step work to a small workflow it builds and runs.
order: 45
---

# The Orchestrator

The built-in Osaurus agent is the default Orchestrator. New chat windows (⌘N, the menu bar, Siri / Shortcuts "Ask Osaurus") open on it unless you set another agent as the **new-chat agent** (`new_chat_agent` in the declarative document, or "make X my default agent"). Switching the agent inside a chat, or opening a chat from an agent's page, never changes that default — it only changes that conversation.

It is the one assistant you talk to. When a request needs no tool, it answers itself. When a request needs any tool, it routes it and presents what comes back — never both in one turn:

- **Anything about Osaurus itself** — how a feature works, where a setting is, what is configured, or a change to models, agents, providers, tools, automations, or settings — goes to the **Configurator** (`configurator_handoff`). The Configurator runs behind the chat in the same turn with your exact words; it answers, or it makes the change through the declarative `osaurus_config` tool (see the Declarative Configuration topic), which shows an approval card with the exact plan and applies only after you confirm. The Orchestrator never changes a setting itself.
- **A task an installed workflow does** goes to `run_workflow` with the workflow's name and input. Only workflows marked **Osaurus can run this for you** (Main window → Workflows → the workflow → **Who Can Start It**) are offered.
- **Other tool work** (web research, files, a website, code, or a task for one of your agents) goes to `run_workflow` with that agent's or built-in helper's name and your message as the task (see Delegating below).
- **A request that needs several steps or tools together**, with no workflow for it (fetch, then summarize, then email; an intake; a recurring report), goes to `architect_handoff`, which builds a small workflow and runs it in the chat right away. After a successful run it offers to keep it. See the How Osaurus Helps topic.
- **What is running, waiting, or loaded right now** comes from `status` (loaded model, workflow runs running or waiting on you, pending approvals, and the workflows `run_workflow` can run).

At most once per turn it asks one clarifying question (`clarify`), and only when the route is unclear.

It does no hands-on work itself: no web search, no shell, no sandbox, no file reading or writing, no browser or computer use, no media tools, no Apple app tools, and no `spawn_agent`. That work goes to your agents and the built-in helpers. Its instructions name only the tools it has in the current chat; with no working folder it tells you to pick one with the Folder chip before any file task.

## Keeping track

The Orchestrator works from a bounded context: its instructions, the chat's **session state**, the last three exchanges, and the current one — at most 8,000 tokens or a quarter of the model's context window, whichever is smaller. Older exchanges drop out rather than being summarized, so long chats stay fast and the Orchestrator chat does not auto-compact.

What must survive lives in the session state: the goal, decisions, facts, open items, and the workflow runs in flight. The Orchestrator rewrites the whole state once per turn with the `state` tool; running workflows are tracked for it. When a turn ends with an answer but no `state` call, Osaurus asks the same model once more, without tools, to write the state from the previous one and the turn; if that fails too, or you stopped the turn, the previous state is kept and marked as possibly out of date. A turn that ends on a question to you records nothing yet. The state rides with the latest message, is saved with the chat, and survives a relaunch and Sync to your other devices.

## After setup

On a fresh install, the first chat (opened from the welcome window in a compact window) starts as a short walkthrough before the Orchestrator has it, unless you chose **Skip setup** in the welcome window. The walkthrough's own lines are never sent to a model. When setup ends, the Orchestrator receives only the message that ended it, or the task it started, and its session state is seeded with where the chat runs, the teammate you started with, and what you skipped. A discovery card's walkthrough works the same way: its lines stay out of the Orchestrator's context, a step that changes configuration goes to the Configurator with its approval card, and anything you type goes straight to the Orchestrator. Each teammate reads in the Orchestrator's roster as its domain and what it is for, so a request about your day, mail, files, notes, or code goes to the right one; Keeper reads Downloads and Notes, and a worker with the working folder writes files.

## Working folder

Pick a folder with the Folder chip on an Orchestrator chat, or in Settings → Orchestrator → **Working Folder**. The Orchestrator itself never reads or writes it, and it does not have the `prompt_working_folder` picker tool that custom agents have.

The folder is what delegated agents inherit: an agent with no working folder of its own works inside the Orchestrator's folder (read and write), so "write the report into the folder" works out of the box, and the worker's result names the files it wrote. Agents that have their own folder keep it. Teammates' shared agents run on their owner's Mac and cannot see your folder at all — the Orchestrator puts everything they need in the task text.

## Delegating

The Orchestrator hands tool work to your agents and the built-in helpers (Research, Files, Browser, Code) through `run_workflow`: each agent on **Allowed subagents**, and each helper, runs as a one-step workflow that takes your message as its task. Its card shows in the chat and its answer comes back into the conversation. See the How Osaurus Helps topic.

Custom agents with delegation turned on hand work to other agents with `spawn_agent`:

- Several `spawn_agent` calls in one message run as one **wave**, in parallel, up to the "Max local/remote subagents at once" limits. One permission card covers the whole wave. Calls beyond the limit are refused with a retryable result and the Orchestrator sends them in its next message, so a wave of two with a local limit of 1 still completes — serialized.
- Each delegation is a separate chat session with the target agent's own prompt, model, tools, and folder; the Orchestrator gets back a short summary and presents it. Workers write deliverables into the (inherited) folder; the result lists the files they wrote (`artifact_paths`).
- A worker that needs a decision ends with `NEEDS INPUT: …`. That is a question for the launching agent: it answers with `spawn_agent` `continue: <session_id>`, which reattaches to the same worker session (history intact) instead of starting over, and asks you only when it genuinely cannot answer itself. `continue` also works for shared workspace agents and for any follow-up ("now also add tests").
- `background: true` starts a worker without waiting: the call returns at once with an acknowledgment carrying the worker's `session_id`, and the worker's summary arrives later as a follow-up message in the same conversation. A background worker is not part of the wave count. It shows in Activity with its own Stop; stopping the launching turn stops the background workers it launched as well.
- Results from teammates' shared agents come back as a digest plus any **small files** the agent shared with `share_artifact` (a few MB in total), promoted to artifact cards on your chat. Larger files stay on the teammate's Mac and the worker says so.

### Creating agents and delegating in one turn

"Create a research agent and have it summarize X" works with an empty **Allowed subagents** list: the Configurator applies the `agents:` entry (approval card), the new agent joins the list, and the Orchestrator can hand it the task by name with `run_workflow`. A `delegation.spawnable_agents` list in a document **replaces** the whole list; an apply that would leave it empty while agents exist is flagged as high risk on the approval card.

### Teammates' shared agents (workspaces)

Agents teammates share into a workspace you belong to are delegation targets too. Ask "who can I delegate to?" and the Configurator lists them (name, owner, workspace, online/offline, whether each is already in **Allowed subagents**). The Orchestrator addresses them as `Name@Workspace`. If a shared agent is offline the call is refused with the reason and the Orchestrator re-plans to another agent or tells you. See the Workspaces topic for sharing, workspace credits, and what comes back from a teammate's Mac.

Image generation, AppleScript, Browser Use, and Computer Use are custom-agent abilities. Give such an agent to the Orchestrator through **Allowed subagents**; there are no Orchestrator-level toggles for them.

## Workflows and automations

Anything that should run on its own (a time, a changed folder, a webhook call, a feed item, an event stream, a failed run, app launch) is an **automation** (see the Automations topic). Ask for one and what it runs is picked in this order, never creating an agent just to have one:

1. **An installed workflow that fits.** The Configurator creates the automation and binds each required input to a trigger value (`{{schedule.scheduled_for}}`, `{{webhook.body.title}}`) or fixed text.
2. **A new workflow.** The Configurator never designs one. For a new repeatable multi-step process the Orchestrator builds a small workflow with `architect_handoff`, runs it, and offers to keep it; once kept, an automation can run it. For a bigger design, open **Workflows** and start one with the Architect, whose save card offers **Then run it** with a trigger: one tap saves the workflow and creates the automation.
3. **An agent** (Configurator), only for open-ended tool work (web, files, apps): one that exists, or a new one when none fits.
4. **Instructions alone**, for a simple text task (a daily quote, a reminder, a digest of what a webhook sent): no agent, one tool-less model answer per run (**Ask a Model** in the editor).

Automations never run the Orchestrator itself: a webhook or feed must never be able to change your configuration.

## Settings

Settings… (⌘,) → Agents pins **Orchestrator**, **Architect**, and **Configurator** under **Built-in**, and **Delegation** under **Working Together**.

**Settings → Orchestrator:**

- **Identity** — **Orchestrator Name** (defaults to "Osaurus"), **Orchestrator Avatar** (upload your own image or pick a dino), and **System Prompt** (persona).
- **Model & Generation** — the **Model Readiness** row shows the current chat model, its context window and whether tools are OK or limited, with a recommended-model hint when the window is small; then **Temperature** and **Max Output Tokens**. The model itself is picked from the chat model selector.
- **Working Folder** — the folder described above.
- **Subagents** — one row, **Allowed Subagents and Limits**, which opens Agents → **Delegation**.
- **Delegations** — every delegated run with its status, duration, tokens, tok/s, artifacts and an **Open Chat** button. **Sent** lists the runs this Osaurus delegated; **Received** lists runs a teammate's Orchestrator asked one of *your* shared agents to do.
- **Danger Zone** → **Restore Defaults** puts back the identity settings (and the green dino).

**Settings → Agents → Delegation:**

- **Subagents**
  - **Allowed subagents** — the agents the Orchestrator may delegate to. Every custom agent joins on creation (unless the bundle or config entry that created it set `orchestrator_spawnable: false`); remove one and it stays out until you add it back (or it is listed in a `delegation.spawnable_agents` apply). Teammates' shared agents join automatically as their workspace roster loads; removing a shared agent leaves a tombstone so it does not rejoin when re-shared — tombstones exist only for workspace agents. Deleted agents disappear from the list immediately. With no agents yet, **Create starter agents** makes the team (Planner, Courier, Keeper, and Scout, plus Builder on a developer Mac) on your current model and adds them. If agents exist but none is allowed, a notice says so, with an **Add all agents** button.
  - **Permission** — whether to ask before local agents run. **Always Allow** is the default; each agent still shows its own permission cards for anything sensitive. **Permission for shared (workspace) agents** defaults to **Ask** because those runs leave your Mac and spend the workspace's pool; one card covers every shared agent in a wave, and the card names the agent, owner, and workspace.
  - **Limits** — per worker: **Max output tokens per subagent** (default 8192), **Max turns per subagent** (24 tool-call rounds), **Time limit per subagent** (900 s), plus **Max local subagents at once** and **Max remote subagents at once** (8). The local value is one shared setting with Server → Concurrency → **Concurrent Sessions**: change either and the other follows, and in Automatic mode it mirrors the resolved safe value for this Mac rather than a fixed number. The row beneath shows the resulting same-model ceiling; RAM checks and current engine occupancy can still run a smaller wave. Turns and time bound a worker; there is no separate tool-call cap.
  - **Advanced** — **Agent-target model override** runs every delegated agent on one model instead of its own. Leave it on "Use each agent's model" unless you need that.
- **Local Models & Memory** — **Swap Local Models for Subagents** and **Check Memory Before Delegating**, shared by the Orchestrator and every custom agent.

**Settings → Configurator** customizes the helper behind `configurator_handoff`: **Extra Instructions**, **Configurator Model** (unset uses the Orchestrator's model), and **Temperature**. See the Settings topic.

All of these are searchable from the Management sidebar.

## Renaming the Orchestrator

Set **Orchestrator Name** in Settings → Orchestrator → Identity, or declaratively:

```yaml
default_agent:
  name: Jarvis
```

`name: null` restores "Osaurus". The name is cosmetic — the agent's identity, tools, and behavior are unchanged.

## Typical asks

- "What's configured?" / "Change a setting" — the Configurator inspects live state and applies the change after your approval.
- "Create a research agent with web search." — new agents default to the Orchestrator's current model; `template: researcher` fills the prompt and description; a custom `description` is optional and is generated from the system prompt when omitted.
- "Have Coder add tests to this project and tell me what changed." — delegated into the working folder; the summary names the files.
- "Ask Research@Acme for a market summary." — a teammate's shared agent, on their Mac.
- "Make Coder my default agent." — sets `new_chat_agent`; "back to Osaurus" restores the Orchestrator.
- "Export my setup as a template."
- "Run Daily Digest every weekday at 8." — an `automations:` entry that runs the installed workflow on a schedule.
- "Build me a workflow that triages new GitHub issues when the webhook fires." — hands off to the Architect; the save card offers the webhook automation.
- "Every morning, send me a motivational quote." — an automation with instructions only, no agent.
- "Run Meeting Action Items on these notes." — `run_workflow`, for a workflow marked **Osaurus can run this for you**.
- "What's running right now?" — `status`.

## Where its settings are stored

Identity and the working folder persist to `~/.osaurus/config/default-agent.json`; delegation settings (allowed subagents, permissions, limits) to `~/.osaurus/config/agent-delegation.json`; the Configurator's to `~/.osaurus/config/configurator.json`. The new-chat agent is stored separately from the agent currently shown in the foreground window. The declarative document covers identity (`default_agent`), delegation (`delegation`), and the Configurator (`configurator`); the working folder is set from the chat Folder chip or Settings → Orchestrator → Working Folder.
