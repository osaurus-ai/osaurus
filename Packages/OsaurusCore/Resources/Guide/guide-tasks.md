---
title: Tasks and Queues
summary: Everything that runs on its own — automation runs, background agents, workflow runs and helpers — is a task that waits in a queue; see what is running, stop it, and read what each did.
order: 92
---

# Tasks and Queues

A **task** is one unit of work that runs without you at the keyboard: an automation run, a background agent turn (plugin or HTTP dispatch, an agent's own wake-up), a workflow run, or a helper an agent started. Every task waits in a **queue** until a slot frees up, runs, and keeps a timeline of what happened.

Chats you type into, and API or plugin requests to a model, are not tasks and are never queued: you are already watching them, and the chat history and Insights already record them. While one is answering on a local model, tasks that need a different local model wait for it to finish ("Waiting for the chat to finish"). What a chat starts on its own (a helper, a dispatched agent, a workflow run) is a task, and remembers the chat it came from.

Open it from Settings… (⌘,) → **Developer Tools** → **Tasks**, or from any link that names a task (Automations → **History**, an agent's or workflow's **See All**, Insights → **Open Task**, a chat's **Tasks from This Chat**). The sidebar badge counts tasks that are waiting or running, and lights up when one needs you.

## The Tasks page

- **Foreground** (only while something is using a model): one row per chat, API request or plugin request answering right now, with its model, whether it runs on this Mac or remotely, and how long it has been going. **Open** on a chat row brings that chat forward. The rows disappear when the answer finishes; nothing here is saved. While a chat is holding tasks back, the section says how many wait and shows **Yielding**.
- **Queues** (the default view): one section per queue. Each shows how many tasks run and wait, its limit ("up to 20 at once"), **Default** and **Paused** chips, and a settings button. Under it: running tasks, waiting tasks, then the last few that finished, with **See All Finished**.
- A task row is its title, what it runs (agent, workflow or helper), and one status line: where it came from, then how long it has run and what it is doing, why it waits (the chat, a paused queue, a full queue), the last error, or when it finished and how long it took. A running task shows **Stale** when it has stopped making progress: about a minute after its chat would show as stalled (longer while a model loads), or for a workflow, after its run stops.
- **Stop** on a running or waiting task cancels it; the timeline records that you stopped it.
- A task waiting on your answer (a workflow's form, a tool approval, an agent's question) is also in **Inbox** → **Needs You** in the sidebar, where you can answer it. Failed tasks are in **History** → **Failed**.
- **History**: every task, newest first. Narrow it by where it came from (Automation, Agent-scheduled, Channel, Helper, Workflow, API, Plugin…), by result (**Ran / Skipped / Failed**), by queue (once you have more than one), to one agent or workflow, or to one chat. Automations → **History**, an agent's Automations → **Recent Tasks** → **See All**, a workflow's **All Tasks**, and a chat's **Tasks from This Chat** open it already filtered.

## A task's detail

Click a task to open it:

- **Summary**: what it runs, what started it, its queue (once you have more than one), how long it waited and ran, attempts, the current step, the error, its result, and the task id.
- **Open**: **Started from chat** (the conversation whose turn started it, for helpers, dispatches and workflow runs a chat began), the **Chat** it ran in, the **Workflow Run** (its steps), the **Automation** that started it, and **Insights** (every request and tool call it made).
- **Related Tasks**: the task that started it and the helpers it started; click one to move to it.
- **Timeline**: each step with its time — queued, started, waited for the model, a helper started, waiting for you, finished, stopped (and by whom).

## Queues

**Default** is created for you; every automation, background chat, plugin dispatch and helper runs there unless told otherwise. **Add Queue** makes another (for example *Overnight* or *Inbox*); pick it in an automation's **Queue** section. While Default is the only queue, there is nothing to choose, so the automation editor, task details, History and Insights don't show a queue at all; they show it again as soon as you add one. A queue's settings:

- **Max Concurrent Tasks** (1–64; Default queue: 20): how many of its tasks run at the same time. Each agent still runs at most 5 at once. This is about work, not hardware: how many model generations run at once is Server → **Concurrent Sessions**.
- **Max Waiting Tasks** (0 = no limit): how many may wait for a turn. **When Full** then decides: **Refuse new tasks**, **Keep only the newest per conversation**, or **Drop the oldest waiting task**.
- **Start Order**: **In order**, **One at a time per conversation**, or **Any order**.
- **Paused**: holds new tasks without starting them; running ones finish.
- **Delete Queue** (queues you made): waiting tasks move to Default, and automations on it use Default.

## Where else tasks show up

- Insights has a **Tasks** scope: one row per finished task, and every request made inside a task carries its id, so **All Events for This Task** lists its whole trail and **Open Task** comes back here.
- An automation's detail lists its recent tasks under **Runs**.
- In the chat sidebar, right-click a chat → **Tasks from This Chat** (shown only when that chat started tasks).
- Tasks interrupted by a quit are closed as *Interrupted* at the next launch.
