# Task Queue

Every unit of offloaded work in Osaurus is a **Task**. A task waits in a
**Queue**, is admitted by the **Scheduler**, runs in a **Worker**, and leaves
an append-only **Journal**. Interactive work (a person watching a spinner in
Chat, or an API client holding a connection open) is never a task: it takes a
**Foreground Reservation** the scheduler yields to.

```
Source ──▶ Automation (subscription) ──▶ Queue ──▶ TaskScheduler ──▶ ResourceArbiter ──▶ Worker
                                                         ▲                    ▲
                    Chat / interactive API ──▶ ForegroundReservationCenter ───┘
                                                         │
                                      tasks.sqlite: queues · tasks · task_events · reservations
                                                         │
                                         TaskBus ──▶ Tasks tab · Insights · RunFailed source
```

### Why chats and inference are not tasks

A task is work nobody is watching, which needs what the queue gives it:
admission, retries, crash recovery, history and a Stop from elsewhere
(automations, background agent turns, workflow runs, helpers). A chat turn,
an HTTP inference request and a plugin completion have none of those needs
and already have their own records (`ChatSessionData`, the Insights
inference rows with tokens and tok/s); a task per turn would be a second
record of the same thing. What everything shares is the resource layer:
`ForegroundReservationCenter`, `ResourceArbiter`, `HTTPInferenceAdmission`
and `InferenceLoadCoordinator`. A rule like "a chat waits while RAM is full"
belongs there. Revisit only if chat turns must survive a crash or run on
another machine, or the scheduler has to rank chat against background work.

Tasks a chat turn starts (helpers, a dispatch, a workflow run) do become
tasks, stamped with `originSessionId` so each side links to the other.

User-facing guide: `Packages/OsaurusCore/Resources/Guide/guide-tasks.md`
(`osaurus_help` topic `tasks`). Automations: `docs/AUTOMATIONS.md`.
Workflows: `docs/WORKFLOWS.md`.

## Vocabulary

| Term | Meaning |
| --- | --- |
| Source | Something that emits occurrences: schedule, folder, webhook, feed, event stream, channel message, email, app event, run failure. |
| Automation | A subscription on a source: `(source, filter) → (agent or workflow, queue)`. Internally still `OsaurusEvent`. |
| Task | One unit of offloaded work: one agent turn, one workflow run, one spawned helper. `OsaurusTask`. |
| Queue | A resource lane with a policy. One system queue, **Default**, exists from first launch. |
| Journal | The append-only list of `TaskEvent`s for a task. The audit primitive and the swimlane data source. |
| Reservation | A foreground claim (chat turn, interactive API request) on a model. Never queued. |

## Data model (`Models/Task/`)

`OsaurusTask` (`TaskModels.swift`):

| Group | Fields |
| --- | --- |
| Identity and lineage | `id`, `title`, `rootId`, `parentId`, `queueId`, `subscriptionId` (automation id), `origin` (`TaskOrigin`), `createdBy` (`TaskActor`), `depth` |
| Routing | `priorityClass` (high / normal / batch), `orderingKey` (conversation key), `idempotencyKey` |
| Execution | `state`, `attemptCount`, `lastError`, `lease` (`owner`, `lastHeartbeatAt`, `leaseExpiresAt`), `progressNote`, `waitReason`, `claim` (`ResourceClaim`), `version` |
| Work | `work` (`TaskWork`) |
| Chat link | `originSessionId`: the interactive chat session whose turn started the task tree (see below) |
| Results | `sessionId`, `workflowRunId`, `result` (`TaskResult`: one-line summary, produced ids, tokens, cost), `summary` (metadata only, never bodies) |
| Timestamps | `createdAt`, `queuedAt`, `admittedAt`, `startedAt`, `finishedAt`, `updatedAt` |

`TaskWork` is the durable description of what runs:

- `agentTurn(AgentTurnWork)` — target key, agent id, session source, title.
  The live `DispatchRequest` is held in memory by the worker; the journal
  stores what is needed to audit and re-fire it, not the prompt body.
- `workflowRun(WorkflowRunWork)` — workflow id, workflow run id, caller kind.
- `subagent(SubagentWork)` — parent session, tool call id, child model.

`TaskOrigin` names the door: `automation`, `selfSchedule`, `channel`,
`spawn`, `workflowStep`, `apiDispatch`, `plugin`, `manual`, `system`.

`TaskActor` attributes every task and every journal event: `user`,
`agent(id)`, `workflow(id)`, `system(name)`.

`originSessionId` is separate from `sessionId` (the session the task itself
runs in). A root task takes it from `ChatExecutionContext.interactiveSessionId`:
`currentSessionId` when no background task is bound (`currentBackgroundId ==
nil`), so a background chat's own spawns carry none. A child copies its
parent's value, never the current session. It is stamped where tasks are
created: `SubagentTaskRecorder` (captured off the main actor beside
`currentTaskId`), `BackgroundTaskManager.recordTask` and
`WorkflowTaskRecorder.began`. `WorkflowExecutionContext.bind` binds the run's
task as `currentTaskId`, so helpers inside a workflow step are children of
the workflow's task.

`ResourceClaim` is what the arbiter reads: resolved `model`, `isLocal`,
`estimatedBytes`.

### TaskState

One status vocabulary for every kind of run. It replaces `EventRunStatus`,
`AgentRunStatus` and the run-level use of `WorkflowRunStatus` (node-level
statuses stay); the old enums map onto it at read boundaries
(`TaskState(EventRunStatus)`, `TaskState(WorkflowRunStatus)`,
`EventRunStatus(TaskState)`).

```
received ─┬─▶ filtered | duplicate | suppressed            (never ran)
          └─▶ queued ─▶ admitted ─▶ running ─┬─▶ succeeded
                 │                    ▲  │    ├─▶ failed
                 │                    │  ▼    ├─▶ cancelled
                 │               waitingUser  └─▶ interrupted   (app quit / crash)
                 └─▶ cancelled | suppressed  (dropped while queued)
```

`isTerminal`: filtered, duplicate, succeeded, failed, cancelled, suppressed,
interrupted. `didRun`: succeeded, failed, cancelled, interrupted.

### Journal kinds (`TaskEvent.kind`)

`enqueued`, `admitted`, `leased`, `started`, `progress`, `toolCall`,
`modelLoadWait`, `resourceWait` (with `reason`), `waitingUser`, `resumed`,
`retryScheduled`, `childSpawned`, `finished`, `cancelled`, `error`,
`timerFired`, `suppressed`. Each event carries `seq` (per task, monotonic),
`at`, `actor`, an optional `reason` and a small string map. Progress events
are coalesced in memory: only the newest `progressNote` reaches the
database per heartbeat.

### Queue policy (`TaskQueuePolicy`)

| Field | Meaning | Phase |
| --- | --- | --- |
| `maxConcurrent` | Running tasks admitted at once (1–64). Default queue seeds from the old `ToastConfiguration.maxConcurrentTasks` (20). | 1 |
| `maxPending` | Waiting tasks held; `nil` is unlimited. | 1 |
| `overflow` | `reject` (`queue_full`), `coalesceByKey` (drop older waiting tasks with the same `orderingKey`), `dropOldest`. | 1 |
| `orderingMode` | `fifo` (arrival order, a blocked task never blocks an unrelated one), `perKey` (one running task per `orderingKey`), `parallel`. | 1 |
| `paused` | Nothing is admitted; waiting tasks stay. | 1 |
| `priorityClass` | Default class for tasks without one. | 3 |
| `retry` | `maxAttempts`, `backoffSeconds`. | 3 |
| `onExhausted` | `needsAttention` (stays failed, counted in **Needs you**) or `routeTo(queueId)`. | 3 (needsAttention counted from 1) |
| `timers` | Deterministic rules on queued or waiting tasks (notify / move / cancel), journaled as `timerFired`. | 3 |
| `runWindow` | `always` or `idleOnly`. | 3 |

Only the user (and the Architect through `ConfigApprovalQueue`) creates,
edits or deletes queues. Agents enqueue into queues and read task state;
they never change policy.

## Scheduler (`Services/Task/TaskScheduler.swift`)

`TaskScheduler` is `@MainActor`. One shared instance drives the app; tests
build their own.

A submission carries the task, its **limits** and a start closure:

```swift
struct TaskLimit { key; capacity; maxPending: Int?; holdsWhileWaiting; rejectReason }
```

Every submission gets the queue limit (`queue:<id>`, capacity =
`policy.maxConcurrent`, pending cap = `policy.maxPending`), plus whatever the
caller adds:

| Key | Capacity | Who adds it |
| --- | --- | --- |
| `queue:<id>` | queue `maxConcurrent` | always |
| `agent:<id>` | 5 (internal safety cap) | agent turns |
| `lane:<eventId>` or `lane:<eventId>\|<conversationKey>` | 1 (serial / per conversation) or the automation's `maxConcurrent` (overlapping runs) | automations; `maxPending` = the automation's `maxQueued`, `holdsWhileWaiting` = true, reject reason `busy` (maxQueued 0) or `queue_full` |
| `order:<queueId>\|<orderingKey>` | 1 | queues in `perKey` mode |

Admission:

1. **Reject** if any limit with a pending cap is full: `running(key) +
   pending(key) ≥ capacity + maxPending`. Queue overflow `coalesceByKey`
   drops older waiting tasks with the same ordering key instead;
   `dropOldest` drops the oldest waiting task in the queue.
2. **Start** (`.started`) when the queue is not paused, every limit has a
   free slot, and the arbiter admits the claim. The caller runs the work
   inline, so ordering stays synchronous for callers that need it.
3. Otherwise **queue** (`.queued(position)`); the start closure runs from
   `pump()` when a slot frees. Pump scans waiting tasks oldest first and
   skips blocked ones (no head-of-line blocking).

Occupancy is explicit: `occupy` (forced, idempotent), `suspend` (frees the
keys that do not hold while waiting — a run waiting on the user gives back
its queue and agent slot but keeps its automation lane), `resume`
(re-occupies without admission, matching the old behavior that a resumed
run is never demoted back to the queue), and `finish` (frees everything and
pumps). `BackgroundTaskManager` drives these from each run's status, so a
run that pauses for a clarify prompt frees its slot exactly as before.

## Resource arbiter (`Services/Task/ResourceArbiter.swift`)

Stage two of admission. The arbiter does not replace the real gates
(`SubagentBatchAdmissionPlanner`, `ModelRuntime` cold-load slots,
`refuseBackgroundLoadIfItWouldDisturb`, `MetalGate`); those still run inside
the worker. What it adds is the **foreground yield**:

- A claim for a **local** model is held with `resourceWait(foreground_active)`
  while a local reservation on a **different** model is active. Agent turns
  claim the model their session starts on (`ChatSession.initialModel`: the
  agent's effective model, else the same fallback pick the session makes);
  workflow automations claim every local
  model bound to the workflow's slots, so a workflow that loads more than
  one local model waits for any local reservation.
- Same-model claims are admitted (they share the resident engine), and remote
  or unknown-model claims are admitted (no local RAM claim to protect).
- **Starvation guard**: a task is never held longer than 600 seconds by
  reservations. After that it is admitted and the journal records
  `resourceWait(foreground_hold_expired)`. A user chatting all afternoon
  delays background work by at most ten minutes per task, and the existing
  RAM gates still refuse unsafe loads.
- Releasing a reservation pumps every scheduler.

Model affinity (prefer tasks whose model is already resident) is Phase 3.

## Foreground reservations (`Services/Task/ForegroundReservationCenter.swift`)

`ForegroundReservation { id, owner, kind (chat / api), model, isLocal,
estimatedBytes, startedAt, endedAt }`. Thread-safe; callable from NIO
handlers and the main actor.

- **Chat**: taken when an interactive run begins (`ChatSession.beginRun`,
  no background task bound), released in `completeRunCleanup`, which every
  exit path (finish, Stop, error) goes through, or in `deinit` if the
  session goes away mid-turn.
- **Interactive API**: held by the `HTTPInferenceAdmission.Token` of every
  MLX-bearing route (chat completions, completions, messages, responses,
  Ollama, agent run) and released with the slot. An agent run usually omits
  `model`, so it re-reserves once the agent's model is resolved.
- **Plugin completions**: `complete` and `complete_stream` hold one for the
  request's model while the plugin waits. Embeddings, image, video and
  transcription calls take none.
- A run dispatched from **inside** a chat turn (delegation, a tool that
  dispatches and waits) makes no claim: its parent turn is waiting on it,
  and holding it behind the parent's own reservation would stall both.
- It does not delay a chat send and does not replace the chat busy guard or
  the HTTP 503 ceiling. Those stay until reservations are live-proven.
- Reservations are journaled in the `task_reservations` table (newest 5,000
  rows, 30 days) so the Tasks tab can say "Chat on Qwen is using the model;
  2 tasks waiting".

## Workers (`Services/Task/Workers/`)

`TaskWorker` is the protocol a kind of work implements. Two workers exist:

- `AgentTurnWorker` — builds the `DispatchRequest` for an automation
  (prompt, session key, folder, load intent), dispatches it through
  `BackgroundTaskManager.dispatchChat(_:admittedTaskId:)`, awaits completion
  and returns a `TaskOutcome`. Holds the automation-target rejection rules.
- `WorkflowRunWorker` — maps the occurrence to workflow input, starts the
  run through `WorkflowRunService`, waits until it settles or parks on a
  form, and maps the run to a `TaskOutcome`. Holds the reply-text rules.

`BackgroundTaskManager` keeps hosting `ExecutionContext` (headless session
lifecycle, Activity toasts, completion waiters) but no longer owns a queue:
every dispatch is submitted to the shared scheduler on the Default queue with
an `agent:<id>` limit. `TaskDispatcher` is gone; plugin, HTTP and toast
callers talk to `BackgroundTaskManager` directly.

## Storage (`Storage/TaskDatabase.swift`, `Services/Task/TaskStore.swift`)

`~/.osaurus/tasks/tasks.sqlite`, opened through `OsaurusStorageOpener`
(SQLCipher, shared storage key). It and the automation ledger
(`events/runs.sqlite`) are in `StorageDatabaseCatalog`, so they are rekeyed
on rotation, converted with the encryption mode and included in export.
When the file cannot open at launch (usually the storage key is not
resident yet), the failure shows under Settings → Storage with Retry and
Reset, the store runs in memory, and it reattaches when the key arrives or
on Retry: stored rows win, and anything recorded meanwhile is written
through.

| Table | Rows |
| --- | --- |
| `task_queues` | One per queue: id, slug, name, is_system, policy JSON. |
| `tasks` | One per task: indexed queue / state / origin / subscription / agent / created_at columns plus the record JSON. |
| `task_events` | Journal: task id, seq, at, kind, record JSON. Capped at 1,000 rows per task: the first row and the newest. |
| `task_reservations` | Foreground reservation history. |

Migrations are additive only (schema v2 added indexes on `parent_id`,
`finished_at`, `idempotency_key` and `(state, created_at)`; v3 added the
`origin_session_id` column and its `(origin_session_id, created_at)` index),
so an older build opens a newer file unchanged. `TaskQuery(originSessionId:)`
filters on it, and `TaskStore.originSessionIds` (loaded at launch, grown as
tasks arrive) tells a chat whether it has any tasks to link to.

`TaskStore` is the `@MainActor` facade. It keeps live (non-terminal) tasks and
a 500-row hot cache of recent terminal tasks in memory, writes behind on a
serial queue, enforces optimistic versions (`update(id, expectedVersion:)`
returns false on a stale write, so two controls acting on one task during a
state change cannot both apply), publishes changes on `TaskBus`, and prunes
terminal tasks older than 30 days (and past 20,000 rows) at launch and then
at most every six hours. There is no Retry control yet: a failed task is
re-run from where it came from (the automation, the workflow, the chat).
`revision` moves on every change except a lease heartbeat, so history
lists do not re-query the database every 15 seconds per running task; rows
and the detail sheet read the live record for running tasks instead.

### Leases and recovery

Agent turns and workflow runs carry a lease renewed by the run's own
progress, at most every 15 seconds: token usage, tool calls and status
changes for agent turns (`BackgroundTaskManager.renewLease`), step updates
for workflow runs (`WorkflowTaskRecorder.observed`), each with the latest
step as `progressNote`. Silent phases keep the lease too: an agent turn
renews while its chat's liveness monitor (`RunProgressMonitor`, the source
of the composer's slow and stalled chips) does not call it stalled, which
allows ten minutes for an opaque model load and two otherwise; a workflow
run renews while its runner task executes, since every node is bounded by
its own timeout (`WorkflowTaskRecorder.alive`), and an automation's
workflow run renews the automation's task. Workers are in-process, so a
lease that runs out while the app runs means a hung run, not a crash: 60
seconds after renewals stop the card shows **Stale** with Stop. Nothing is killed
automatically. Subagent tasks (`SubagentTaskRecorder`, recorded around
`SubagentSession.runPrepared` under the launching task) carry no lease:
they are a shadow record, and their admission and Stop stay with the
parent turn.

On launch, every task left `admitted`, `running` or `waitingUser` becomes
`interrupted` (journal `finished(interrupted)`), except workflow tasks whose
workflow run resumes; those follow the run as before. Tasks left `queued`
become `cancelled(interrupted)`; their automation's missed-fire policy decides
whether the source fires again.

### Lifecycle as a source and the loop guard

Today the only task-triggered source is `RunFailedEventSource`, which is
never re-entrant: a run a run-failed automation started, or that automation's
own failure, fires nothing. Its submissions run at depth 0.
`TaskLifecycleSource` (`task.failed`, `task.succeeded`, `task.exhausted`,
`queue.drained`) replaces it in Phase 3; its tasks will carry `depth + 1`, and
the scheduler already refuses a `Submission` past depth 8 (the subworkflow
cap) with `loop_guard`.

## Migration map

| Before | After |
| --- | --- |
| `EventQueue` lanes | `lane:` limits on the Default queue |
| `EventExecutor` | `AgentTurnWorker`, `WorkflowRunWorker` |
| `EventRunStatus` | `TaskState` (EventRun keeps its own enum for the ledger API, derived from the task) |
| `event_runs` rows | Still written as a projection of the task so `GET /events/{token}/runs/{id}` and the automation tools stay identical; imported once as terminal tasks |
| `TaskDispatcher` | deleted; callers use `BackgroundTaskManager` |
| BTM `queuedOrder` / `pendingStarts` / `pumpQueue` / `hasExecutionCapacity` | `TaskScheduler` |
| `ToastConfiguration.maxConcurrentTasks` + Notifications field | Default queue `maxConcurrent` (saved value migrated once); field removed |
| `NextRunScheduler` + `agent_next_run` | Agent-owned one-shot schedule automations (owner in `parameters.selfScheduleOwner`, missed-fire mapped from the slot's `on_miss`); rows migrated at launch; once every wake is saved, the table is renamed to `agent_next_run_legacy` and recreated empty |
| `agent_runs` | Tasks (agent turns with `agentId`); self-scheduled and manual rows imported at launch (automation rows already come from `event_runs`); once the import commits, the table is renamed to `agent_runs_legacy` and recreated empty. Daily self-schedule cap counts tasks. |
| New automation sessions' `SessionSource` (`schedule` / `watcher` / `webhook` / `email`) | `.automation` (old values still decode). Unattended auto-approval now comes from the request (`DispatchRequest.unattended`), not the source. |
| Delivery knobs in the editor | **Queue** picker + **Allow overlapping runs**; `delivery:` in config still decodes |
| Automations → History | **Tasks → History** (the History button opens it filtered to automations). The channel-message audit (refused, unclaimed, form answers) stays as **Automations → Channel Messages**: those messages never became tasks, and recording each one would flood the queue history in busy rooms |
| Automation detail Runs ledger | `RecentTasksList(subscriptionId:)` |
| Agent run history | `RecentTasksList(agentId:)` on the agent's Automations tab, See All → Tasks → History; the Database History trace already reads tasks |
| Workflow Recent Runs | Kept as the per-step `WorkflowRun` record, plus **All Tasks** → Tasks → History for the workflow |

Dedupe keys and source cursors stay in `EventRunDatabase`
(`event_seen_keys`, `event_source_state`).

### Self-scheduled wake-ups

`schedule_next_run` creates (or re-arms) one automation per agent through
`SelfScheduleAutomations`: a `.once` schedule source, serial delivery with one
queued run and a 5-second dedupe window, tagged as agent-owned. The list shows
it with an **Agent-scheduled** badge. `ScheduleEventSource` is the only clock;
it re-arms a paused agent's wake at the pause end instead of consuming it, and
fires a missed wake that is less than 5 minutes late even under **Skip**.

Firing or cancelling a wake **disables** the automation rather than deleting
it, so its task history stays attached and the next `schedule_next_run` reuses
the same automation. Deleting the agent deletes it.

Recurring automations gain a third missed-fire policy, **Run every missed
time** (`run_catchup`): after sleep or quit, each missed slot fires once,
newest 24 at most.

## UX

- **Tasks** tab in the Developer Tools group of Management, after Server,
  Sandbox and Insights. Every deep link (`TaskControl.showHistory` /
  `showDetail`, Automations → History, See All, Insights → Open Task) opens
  it wherever it sits.
  - **Board**: one row per queue, split into Waiting, Running and a short
    Recently finished tail. No time axis.
  - **Card**: title, the agent's or workflow's icon, one status line. Running
    shows elapsed time and `progressNote`. Waiting shows a reason only when it
    waits on something (`foreground chat`, `queue full`, `paused`). Failed
    shows the last error. Running cards are locked; the only action is
    **Stop**, journaled with who stopped it.
  - **Foreground** section, above the queues, while anything holds a
    reservation: one row per `ForegroundReservationCenter.active` entry
    (chat, API or plugin, model display name, on this Mac or remote,
    elapsed time; a saved chat's row opens it). Rebuilt from the center on
    `TaskBus.reservationsChanged`, never from the stored history. Its
    subtitle and **Yielding** chip appear only while a reservation actually
    holds a task.
  - **Needs you**: a count of tasks in `waitingUser` plus failed tasks whose
    retries ran out (the last day's).
  - **History**: every task, newest first, narrowed by origin, result
    (ran / skipped / failed), queue, or one agent or workflow. Automations →
    History, an agent's See All and a workflow's All Tasks open it
    pre-filtered (`TaskHistoryFilter`).
  - **Task detail** sheet: journal timeline with timings, lineage, result,
    links to the chat session or workflow run, and **Started from chat**
    (`originSessionId`, when it differs from `sessionId`).
  - **Queue settings** (per queue): max running, max waiting, overflow,
    ordering, paused.
- Chat sidebar: a session's context menu has **Tasks from This Chat**
  (History filtered by `originSessionId`) when it started any.
- Automation editor: **When → Only When → Do → Queue**.
- One queue, no choice: while only Default exists
  (`TaskStore.hasMultipleQueues` is false) the editor hides its queue picker
  (the section keeps the overlap and queued-message controls), the task
  detail hides its Queue row unless the task's queue was not Default, the
  History filter hides its queue menu, and Insights task rows drop "on
  Default" (decided by the row's `queue_id` detail). Adding a queue shows
  them all again without a relaunch.
- Insights: scope **Tasks** (`ActivityCategory.task`); terminal tasks mirror
  into the hash-chained activity log (`TaskActivityLogger`, one metadata row
  per finished task; filtered and duplicate deliveries are skipped). Every
  model, tool and network row made inside a task carries `taskId` (read from
  `ChatExecutionContext.currentTaskId`, indexed `task_id` column), and
  automation `event` rows carry their task's id, so **All Events for This
  Task** lists a task's whole trail.

## Kris's board spec

His spec is a business-process board (long-lived items moving through
stages). Ours is the execution layer underneath; a future board is one more
source (`item.entered_lane`) whose agent runs are our tasks.

Adopted: leases with a visible stale state, the append-only journal as the
single source for UI and audit, idempotent enqueue, versioned writes,
structured `result`, retry limit then human (`onExhausted`, Needs you),
deterministic timers (Phase 3), locked running cards with a logged Stop,
`progressNote`, loop protection, agents cannot reconfigure queues, actor
attribution on every task and event.

Deferred: typed board items, lane roles, tag routing and round robin across
agent pools, per-lane grants and N-of-M signatories, cross-board moves.

Not adopted: "workflows are deterministic, no LLM at run time" (Osaurus
workflows have inference and agentic steps by design) and "one shared
database for several people" (Osaurus is a local app; Workspaces share
agents, not data).

## Phases

- **Phase 1** (shipped): models, storage, scheduler, arbiter, reservations,
  workers; automations and background dispatch admitted by the scheduler;
  `EventQueue`, `EventExecutor` and `TaskDispatcher` deleted; Default queue
  owns the concurrency cap; subagent spawns and workflow runs shadow-recorded;
  Insights scope; Tasks tab.
- **Phase 2** (shipped): user-created queues; editor When / Only When / Do /
  Queue; self-scheduling as agent-owned automations (`NextRunScheduler`
  deleted); one run history (`agent_runs` imported and retired,
  `RecentTasksList`).
- **Phase 2** (shipped): Tasks under Developer Tools; chat links
  (`originSessionId`, schema v3); live Foreground rows; queue choice hidden
  while only Default exists.
- **Phase 2 (open)**: swimlane board with a time axis (the Foreground
  section becomes its track); scheduler control of channel relay ordering and subagent waves;
  drag between queues; folding `refusesLocalBusySend` and the HTTP 503
  counter into reservation policy once reservations are live-proven.
- **Phase 3**: model affinity, priority classes, retry/backoff and
  `routeTo`, queue timers, `runWindow`, `TaskLifecycleSource`.
