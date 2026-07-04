# Agent DB & Self-Scheduling

Every Osaurus agent can opt into its own private SQLite database **and** a single self-scheduled "next run" slot. Together they turn the agent from a stateless chat into something that remembers structured data across runs and wakes itself up to act on it — a journal that can also set its own alarm. Like the rest of Osaurus storage, the agent DB is plaintext by default (protected by FileVault) and follows the app-wide [opt-in encryption posture](STORAGE.md#why-encryption-is-opt-in).

This is distinct from [Memory](MEMORY.md). Memory is a global, app-wide system that distills conversational context across all your chats; Agent DB is **per-agent** structured storage the agent decides on, schemas and queries via dedicated tools. You can run an agent with one, both, or neither.

This doc is the reference for developers and power users. It covers the on-disk layout, the `db_*` tool surface, the next-run scheduler, the four schedule-mode presets, and the detail-view tabs that surface all of it.

---

## Table of Contents

- [Enabling the Database](#enabling-the-database)
- [On-Disk Layout and Encryption](#on-disk-layout-and-encryption)
- [System Columns and the Soft-Delete Convention](#system-columns-and-the-soft-delete-convention)
- [Tool Reference](#tool-reference)
- [Bulk Ingestion at Scale](#bulk-ingestion-at-scale)
- [The Changelog](#the-changelog)
- [Storage Quota and Mutation Activity](#storage-quota-and-mutation-activity)
- [The Self-Scheduling Slot](#the-self-scheduling-slot)
- [`schedule_next_run` Contract](#schedule_next_run-contract)
- [Schedule Modes](#schedule-modes)
- [Pause Records](#pause-records)
- [Detail-View Tour](#detail-view-tour)
- [The `.agentDetailDeeplink` Notification](#the-agentdetaildeeplink-notification)
- [Related Documentation](#related-documentation)

---

## Enabling the Database

Each agent carries an `Agent.settings.dbEnabled` flag (see [`Agent.swift`](../Packages/OsaurusCore/Models/Agent/Agent.swift)). Toggling it on does three things:

1. **Tabs appear in the detail view.** The agent management screen at [`AgentsView.swift`](../Packages/OsaurusCore/Views/Agent/AgentsView.swift) gains five DB-backed tabs — `Home`, `Schema`, `Data`, `Views`, `Activity` — gated by `DetailTab.allTabsForAgent(_:)`. Turning the flag off snaps back to the `Configure` tab so you never sit on a now-hidden DB tab with stale state.
2. **The model sees the `db_*` tools.** [`SystemPromptComposer`](../Packages/OsaurusCore/Services/Chat/SystemPromptComposer.swift) strips every `db_*` tool from the resolved tool list when `dbEnabled == false`; with it on, the agent gets the full surface listed in [Tool Reference](#tool-reference).
3. **The agent gets a fresh, empty database on first write.** The file is lazy-opened on demand — no I/O happens until the agent calls a `db_*` tool. It's created in the app's current storage posture: plaintext by default, or SQLCipher if you opted in.

The scheduler tools (`schedule_next_run` / `cancel_next_run`) are **not** gated on `dbEnabled`. Any agent can self-schedule; the database is a separate capability.

---

## On-Disk Layout and Encryption

| Artifact            | Path                                              | Lifecycle                |
| ------------------- | ------------------------------------------------- | ------------------------ |
| Per-agent database  | `~/.osaurus/agents/<uuid>/db.sqlite`              | One per agent, lazy-open |
| Cross-agent slots   | `~/.osaurus/scheduler.sqlite`                     | Single global file       |

Paths are resolved by [`OsaurusPaths.agentDatabaseFile(for:)`](../Packages/OsaurusCore/Utils/OsaurusPaths.swift) and [`OsaurusPaths.schedulerDatabaseFile()`](../Packages/OsaurusCore/Utils/OsaurusPaths.swift). Both files are opened through [`OsaurusStorageOpener`](../Packages/OsaurusCore/Storage/OsaurusStorageOpener.swift), which sniffs each file's header and opens it plaintext (no key) or, when you've opted in to encryption, with the device-scoped SQLCipher key from [`StorageKeyManager`](../Packages/OsaurusCore/Identity/StorageKeyManager.swift) — the same [detection-first stack](STORAGE.md#detection-first-opening) used by chat history, memory, and the rest of the app. See [STORAGE.md](STORAGE.md) for the key-management details.

**Agent bundles.** When an agent is exported or imported as a bundle, its database is always converted to match the host's posture on import (plaintext, or host-key-encrypted), and exported encrypted under the bundle's own key — so importing an agent never mints a storage key on a plaintext install. See [`AgentBundleService`](../Packages/OsaurusCore/Services/AgentBridge/AgentBundleService.swift).

The lazy-open lifecycle and per-agent singleton connection live in [`AgentDatabaseStore`](../Packages/OsaurusCore/Storage/AgentDatabaseStore.swift); the engine itself is [`AgentDatabase`](../Packages/OsaurusCore/Storage/AgentDatabase.swift).

---

## System Columns and the Soft-Delete Convention

Every table the agent creates via `db_create_table` is augmented with three reserved columns:

| Column         | Type        | Set by host  | Meaning                                        |
| -------------- | ----------- | ------------ | ---------------------------------------------- |
| `_created_at`  | `TEXT` ISO  | host         | Set on insert. Never updated.                  |
| `_updated_at`  | `TEXT` ISO  | host         | Refreshed on `db_update` / `db_upsert` writes. |
| `_deleted_at`  | `TEXT` ISO  | host         | `NULL` for live rows; ISO timestamp once soft-deleted. |

`db_delete` is a **soft delete**: it stamps `_deleted_at` rather than removing the row. `db_restore` clears the stamp. `db_query` filters out rows with a non-null `_deleted_at` by default — pass `includeDeleted: true` to see them.

The Data tab's `Active` / `Deleted` / `All` segmented control (in [`AgentDBTabViews.swift`](../Packages/OsaurusCore/Views/Agent/AgentDBTabViews.swift)) maps directly to that flag: `Active` hides tombstones (the agent's default), `Deleted` only shows tombstones, `All` shows both with the soft-deleted rows dimmed.

There is **no hard-delete tool**. If you need to actually purge a row, do it from the host (the migrator or a developer console) — the model can't.

---

## Tool Reference

All `db_*` tools live in [`Tools/Database/DatabaseTools.swift`](../Packages/OsaurusCore/Tools/Database/DatabaseTools.swift) and delegate to [`LocalAgentBridge`](../Packages/OsaurusCore/Services/AgentBridge/LocalAgentBridge.swift), which serialises mutations per-agent and stamps the `_changelog`. The scheduler tools live in [`Tools/Database/SchedulerTools.swift`](../Packages/OsaurusCore/Tools/Database/SchedulerTools.swift).

### Schema management

| Tool              | Role                                                                                 |
| ----------------- | ------------------------------------------------------------------------------------ |
| `db_schema`       | Return the full schema snapshot (tables, columns, indexes, saved views).             |
| `db_create_table` | Create a new table with a stated purpose. Host adds the three `_*` system columns.   |
| `db_alter_table`  | Append columns to an existing table.                                                 |
| `db_migrate`      | Run a multi-statement up/down migration the agent authored.                          |

### Row writes

| Tool         | Role                                                                  |
| ------------ | --------------------------------------------------------------------- |
| `db_insert`  | Insert one row (`row`) **or many** (`rows[]`) in a single call.       |
| `db_upsert`  | Insert-or-update keyed by an explicit conflict column set; also accepts `rows[]`. |
| `db_import`  | Host-mediated bulk load from a working-folder file (CSV/TSV/JSON/JSONL). See [Bulk Ingestion at Scale](#bulk-ingestion-at-scale). |
| `db_update`  | Update rows matching a typed `where` clause.                          |
| `db_delete`  | **Soft-delete** — stamp `_deleted_at`. Restorable via `db_restore`.   |
| `db_restore` | Clear `_deleted_at` to bring a row back into the live set.            |

### Reads and views

| Tool             | Role                                                                                      |
| ---------------- | ----------------------------------------------------------------------------------------- |
| `db_query`       | Run a read-only SELECT. Accepts `limit` / `offset` for paging; rows are capped (hard max **5000**) and a `truncated` flag flips when the cap or an oversized payload kicks in. |
| `db_execute`     | First-class SQL, including **multi-statement** transform scripts (`INSERT … SELECT`, CTEs, window functions) inside one transaction. Restricted by host policy (see below); reach for the typed tools first. |
| `db_define_view` | Save a parameterised SELECT under a name. Surfaces in the Views tab.                       |
| `db_run_view`    | Execute a saved view with arguments.                                                       |
| `db_list_views`  | Enumerate saved views.                                                                     |
| `db_drop_view`   | Delete a saved view definition.                                                            |

`db_execute` is the SQL escape hatch but is **not** unrestricted. [`AgentDatabase.forbiddenReason`](../Packages/OsaurusCore/Storage/AgentDatabase.swift) rejects, before any statement runs: `DROP TABLE` / `TRUNCATE` / `DROP DATABASE`, `DELETE` with no `WHERE`, `ATTACH` / `DETACH` (would mount another file into the agent's private connection), `load_extension` (loads native code), `PRAGMA` *writes* (read-only PRAGMAs are fine), and any write that targets a reserved/system table (`_changelog`, `_views`, `_tables_meta`) — raw writes there would bypass the soft-delete + audit contract. Wide `UPDATE`/`DELETE` without a `WHERE` is allowed but returns a `warning` and is logged to `_changelog` with `op='raw'`.

### Scheduling

| Tool                | Role                                                          |
| ------------------- | ------------------------------------------------------------- |
| `schedule_next_run` | Upsert the agent's single next-run slot. See [contract](#schedule_next_run-contract). |
| `cancel_next_run`   | Clear the slot without scheduling a new one.                  |

---

## Bulk Ingestion at Scale

The agent DB's first wall used to be data movement: a model that needed to load a few hundred rows would issue one `db_insert` per row and exhaust its tool-call budget long before the data landed. The ingestion path is built around the principle that **row data should not pass through the model's tokens or its per-row tool budget** when it doesn't have to.

### Three ways to load data

1. **`db_import(table, path, …)` — host-mediated file load.** When the data already lives in a file in the agent's working folder, this is the right tool. The host resolves the path (same root as `file_read`, via [`FolderToolManager`](../Packages/OsaurusCore/Services/Folder/FolderToolManager.swift)), reads and parses it (CSV/TSV/JSON/JSONL, auto-detected), creates the table from the file's columns when needed, and bulk-loads every row — in **one** tool call, with **zero** row bytes in the model context. Pass `keyColumns` to upsert instead of append. Parsing and schema resolution are shared with the UI importer through [`AgentImportRunner`](../Packages/OsaurusCore/Tools/Database/AgentImportRunner.swift).
2. **`db_insert` / `db_upsert` with `rows[]` — in-context bulk write.** When the rows are something the model *computed* (not a file), it can hand the whole batch over in a single call instead of looping. Backed by [`AgentDatabase.insertMany` / `upsertMany`](../Packages/OsaurusCore/Storage/AgentDatabase.swift), which chunk the write and run it inside one transaction.
3. **`db_execute` multi-statement transforms — don't move the data at all.** For aggregation/derivation, the most efficient path is to compute *in SQL* (`INSERT INTO totals SELECT … GROUP BY …`) rather than pulling rows into context. The whole script runs in one transaction.

### Reading back without blowing the budget

`db_query` takes `limit` and `offset` so the model can page through a large result set instead of slurping it. Results are capped at a hard maximum of **5000** rows, and the tool independently trims the response when the encoded JSON would be too large — in both cases the result's `truncated` flag is set and a paging hint is returned so the model knows to ask for the next page.

### The data-movement budget refund

Bulk operations are also exempted from the agent's reasoning budget. [`AgentLoopPolicy.maxDataMovementSteps`](../Packages/OsaurusCore/Services/Chat/AgentToolLoop.swift) lets a bounded number of **successful** bulk data-movement calls (`db_import`, and bulk `db_insert` / `db_upsert`) be refunded so they don't count against `maxIterations`. The intent is that ingesting data shouldn't eat the steps the agent needs for the actual analysis; the cap (wired to `min(16, maxIterations)` across the chat, HTTP, evaluator, and plugin entry points) keeps it from becoming an unbounded loop. A one-time notice is staged into the transcript the first time relief is granted so the behavior is auditable.

### Importing from the UI

The **Data** tab has an **Import** button and accepts **drag-and-drop** of a file onto the table view ([`AgentDBTabViews.swift`](../Packages/OsaurusCore/Views/Agent/AgentDBTabViews.swift)). This runs the same `AgentImportRunner` path as the tool, but stamps the rows with `actor = user` in the `_changelog` (the parse happens off the main actor; the import itself runs back on the main actor inside the `currentRunActor = "user"` scope) so a human-initiated import is distinguishable from an agent one in the audit log.

---

## The Changelog

Every mutation appends a row to a hidden `_changelog` table. Entries carry:

- `actor` — one of `agent`, `user`, `migration`, `system` (`AgentDatabaseActor` in [`AgentDatabase.swift`](../Packages/OsaurusCore/Storage/AgentDatabase.swift)).
- `op` — `insert`, `update`, `soft_delete`, `restore`, `execute`, … (`AgentDatabaseOp`).
- `table`, `row_id`, `at`, plus tool-payload metadata so an audit can reconstruct what changed and why.

The `Activity` tab in the detail view surfaces these alongside `agent_runs` (the scheduler's run history) in a split pane. When a self-scheduled run wakes, [`BackgroundTaskManager`](../Packages/OsaurusCore/Managers/BackgroundTaskManager.swift) seeds `ChatExecutionContext.currentRunId` / `currentRunActor` on the chat session so any `db_*` writes inside that run get stamped against the correct run row.

---

## Storage Quota and Mutation Activity

Each agent declares its own quota via `Agent.settings.limits.storageBytesMax`. Two things consume it:

- **Hard limit.** [`AgentDatabase.enforceStorageQuotaUnlocked()`](../Packages/OsaurusCore/Storage/AgentDatabase.swift) rejects writes once the on-disk file exceeds the limit. The error envelope tells the model what to do (typically delete or migrate older rows).
- **Soft warning.** An edge-triggered `.agentStorageWarn` notification fires when usage crosses a configurable threshold (default ~80%). The UI surfaces this as a banner in the detail view and a system notification that deep-links into the Data tab.

The Data tab also shows a small per-agent **in-flight mutation** badge driven by [`AgentMutationActivity`](../Packages/OsaurusCore/Services/AgentBridge/AgentMutationActivity.swift). The counter is bumped by `LocalAgentBridge.serialized` on every mutation entry/exit, so when an agent run is mid-write you can see the spinner instead of wondering whether the view is stale.

---

## The Self-Scheduling Slot

> **Opt-in per agent.** Self-scheduling is gated by `Agent.settings.selfSchedulingEnabled` (default **off**), surfaced as the **Self-scheduling** toggle under Configure → Features. When off, [`SystemPromptComposer`](../Packages/OsaurusCore/Services/Chat/SystemPromptComposer.swift) strips the `schedule_next_run` / `cancel_next_run` / `notify` tools from the model's tool list, the Scheduling mode picker and the Next Run banner are hidden, and flipping the toggle off cancels any pending slot so an orphaned run can't fire after the user opted out. This flag is **independent of the schedule mode** — the mode only sets the bounds (below), while this flag decides whether the tools exist at all.

Schedules in Osaurus follow a deliberately minimal contract: **one row per agent**, in the `agent_next_run` table of `~/.osaurus/scheduler.sqlite` ([`SchedulerDatabase.swift`](../Packages/OsaurusCore/Storage/SchedulerDatabase.swift)).

```
┌─────────────────────────┐     ┌─────────────────────────┐     ┌────────────────────┐
│ agent calls             │ ──▶ │ NextRunScheduler        │ ──▶ │ TaskDispatcher     │
│ schedule_next_run(...)  │     │   - clears slot         │     │   .selfSchedule    │
└─────────────────────────┘     │   - honors pause        │     └────────────────────┘
        ▲                       │   - applies on_miss     │              │
        │                       └─────────────────────────┘              ▼
        │                                                       BackgroundTaskManager
        └────────────────────── agent must re-call ◀─────── runs the chat, stamps
                              schedule_next_run for                agent_runs
                              another wake
```

Writes use SQLite `ON CONFLICT` upsert — **last write wins**. The runtime [`NextRunScheduler`](../Packages/OsaurusCore/Managers/NextRunScheduler.swift) polls the table and, when a slot is due:

1. Clears the row **before** dispatch (so a slow chat run can't double-fire).
2. Checks any active `agent_pause` record.
3. Applies the slot's `on_miss` policy if the slot fell behind while the app was asleep.

Because the slot is cleared on wake, **wakeups are single-shot**. If an agent wants to wake again it has to call `schedule_next_run` from inside the run. This is intentional — it's how the agent expresses "keep me alive" vs. "I'm done".

**Every wake runs in a fresh chat session.** The dispatcher does not reattach to the chat from a previous self-scheduled run, so the context window never accretes across wakes. Continuity is the agent's job: carry state forward through the `instructions` on the next `schedule_next_run` call and through the agent DB. The dispatched prompt carries a host-composed preamble — who scheduled the wake, when, and a pointer to the previous run's completion time/status from `agent_runs` — followed by the stored instructions verbatim (see `NextRunScheduler.composeDispatchPrompt`).

If dispatch fails after the slot is cleared (e.g. host concurrency is saturated), the scheduler records a `cancelled` row in `agent_runs` (`dispatch-failed`) so the miss is visible in the Activity tab instead of vanishing.

Every slot carries `NextRunScheduledBy` (`.agent` / `.user` / `.system`) so the audit trail and the Next Run banner can show "scheduled by you" vs. "scheduled by the agent".

---

## `schedule_next_run` Contract

From [`SchedulerTools.swift`](../Packages/OsaurusCore/Tools/Database/SchedulerTools.swift). Pass **either** `scheduled_at` or `in_seconds` (not both).

| Field            | Type            | Required | Meaning                                                                       |
| ---------------- | --------------- | -------- | ----------------------------------------------------------------------------- |
| `scheduled_at`   | ISO-8601 string | one of   | Absolute wake-up time.                                                        |
| `in_seconds`     | integer         | one of   | Relative offset from now.                                                     |
| `instructions`   | string          | yes      | The "wake-up brief" the agent reads when it fires. Becomes the user turn in a fresh chat session, prefixed by the host's wake preamble. |
| `context_views`  | string[]        | no       | Saved-view names to prefetch into the system prompt before the run starts.    |
| `priority`       | `normal` \| `low` | no     | `low` means "skip if the user is mid-conversation when due". Default `normal`. |
| `on_miss`        | `skip` \| `run_once` \| `run_catchup` | no | What to do when the wake-up time has already passed (e.g. laptop was asleep). Default `skip`. |

`cancel_next_run` takes no fields beyond the implicit agent identity.

### Bounds resolution

The requested time is **clamped** against the agent's schedule mode before it's persisted. Bounds are resolved by [`resolveAgentScheduleBounds`](../Packages/OsaurusCore/Tools/Database/SchedulerTools.swift) → [`AgentManager`](../Packages/OsaurusCore/Managers/AgentManager.swift) → the mode preset. If the agent requests "10 days from now" but its mode caps `maxHorizonSeconds` at 24h, the slot is silently clamped to 24h and the tool result carries an `AgentScheduleClampReason` so the model knows why.

---

## Schedule Modes

The modes from `AgentScheduleMode` in [`Agent.swift`](../Packages/OsaurusCore/Models/Agent/Agent.swift). Each one is a preset over `AgentScheduleSettings`; `AgentScheduleSettings.defaults(for:)` returns the values below. The mode sets the **bounds** for self-scheduling; whether the agent can self-schedule at all is the separate `selfSchedulingEnabled` toggle described above.

| Mode      | Max horizon | Min interval | Daily cap | Quiet hours | Days |
| --------- | ----------- | ------------ | --------- | ----------- | ---- |
| Ambient   | 7 days      | 1 hour       | 6         | 22:00–07:00 | All  |
| Reactive  | 24 hours    | 5 minutes    | 48        | None        | All  |
| Project   | 30 days     | 1 hour       | 4         | 22:00–07:00 | All  |
| Manual    | 7 days      | 15 minutes   | **0**     | None        | All  |

**`Manual` (`dailyRunCap = 0`) is a legacy off-state preset** — [`LocalAgentBridge.scheduleNextRun`](../Packages/OsaurusCore/Services/AgentBridge/LocalAgentBridge.swift) rejects agent-initiated slot writes under it. It is no longer offered in the picker (the `selfSchedulingEnabled` toggle owns on/off now), and is only reachable via legacy data; turning the Self-scheduling toggle on promotes a `Manual` mode to `Ambient` so a real preset is selected.

The mode picker lives in the **Configure** tab of the agent detail view ([`AgentsView.swift`](../Packages/OsaurusCore/Views/Agent/AgentsView.swift), `scheduleSection`) and is only shown when self-scheduling is enabled. It offers the three bound presets (Ambient / Reactive / Project) via `selectableScheduleModes`. Selecting a mode writes both `settings.schedule.mode` and the corresponding preset values via `AgentScheduleSettings.defaults(for:)` — so picking "Reactive" actually rewrites the cap, horizon, quiet-hours, etc., not just the label.

---

## Pause Records

Pauses live in `agent_pause` (also in `scheduler.sqlite`). The row carries just two fields beyond the agent id:

- `paused_until` — absolute resume timestamp.
- `reason` — optional free-text, surfaced under the pause banner.

There is **no `paused_by` column** today. If you need to know whether a pause came from the UI or the agent, look at the reason text (UI paths and tool paths set distinguishable reasons in practice). DB-side audit attribution goes through `_changelog`'s `actor` instead.

The Next Run banner's pause menu maps to these presets:

| Menu item        | Behaviour                                            |
| ---------------- | ---------------------------------------------------- |
| `1 hour`         | `paused_until = now + 1h`                            |
| `4 hours`        | `paused_until = now + 4h`                            |
| `Until tomorrow` | `paused_until` = midnight at the start of the next day |
| `Custom…`        | Opens a sheet for an arbitrary date/time + reason.   |
| `Indefinitely`   | `paused_until = .distantFuture`                      |

All five go through [`LocalAgentBridge.pauseAgent(_:until:reason:)`](../Packages/OsaurusCore/Services/AgentBridge/LocalAgentBridge.swift); `Resume` calls `unpauseAgent`. While a pause is active, [`NextRunScheduler`](../Packages/OsaurusCore/Managers/NextRunScheduler.swift) refuses to dispatch even if a slot is due — the slot stays in the row and fires once the pause expires (subject to its own `on_miss`).

---

## Detail-View Tour

All five DB tabs (and the scheduling chrome that sits above them) live in two files: [`AgentDBTabViews.swift`](../Packages/OsaurusCore/Views/Agent/AgentDBTabViews.swift) and [`NextRunPanelView.swift`](../Packages/OsaurusCore/Views/Agent/NextRunPanelView.swift).

### Next Run banner

Three branches in [`NextRunPanelView`](../Packages/OsaurusCore/Views/Agent/NextRunPanelView.swift):

- **`scheduledRow`** — fires when there's a row in `agent_next_run`. Two-row layout: top row carries the relative time ("in 22h"), absolute timestamp, "by …" badge, the Pause menu, and a read-only **Mode chip**; bottom row carries `Run now` / `Edit` / `Cancel` actions.
- **`pausedBanner`** — fires when an `agent_pause` row is active. Same two-row shape: pause icon + "Paused until X" + reason + Mode chip on top, `Resume` on the bottom.
- **`idleBanner`** — fires when neither is set. Keeps the Pause menu and Mode chip visible so the user always has an entry point.

The Mode chip is read-only and tapping it posts an `.agentDetailDeeplink` notification with `tab: "configure"`, jumping to the Configure tab's Scheduling section.

### Configure → Scheduling

Gated behind the **Self-scheduling** toggle: the mode picker and the Next Run banner only render once `selfSchedulingEnabled` is on. When shown, the picker is three radio cards (`scheduleModeCard` in [`AgentsView.swift`](../Packages/OsaurusCore/Views/Agent/AgentsView.swift)) for the Ambient / Reactive / Project presets, each showing the mode name, a one-line tagline, and the resolved preset summary so the user knows what they're switching to before they click.

### Schema / Data / Views / Activity / Home

| Tab        | What it shows                                                                                 |
| ---------- | --------------------------------------------------------------------------------------------- |
| `Schema`   | Read-only catalogue of every table, its columns + types, and indexes. System tables grouped separately. |
| `Data`     | Browse + edit rows. Table dropdown + `Active` / `Deleted` / `All` filter; per-row "Open" affordance; bulk soft-delete via row checkboxes; CSV export; **Import** button + drag-and-drop file ingest (CSV/TSV/JSON/JSONL), stamped `actor = user`. |
| `Views`    | Manage saved views. Split pane: list of view names on the left, definition + live preview on the right. Pin a view to show on `Home`. |
| `Activity` | Split pane of `agent_runs` (left) and the selected run's `_changelog` entries (right). The audit log. |
| `Home`     | Dashboard of pinned views. The agent's "what should I look at right now?" tab.                |

---

## The `.agentDetailDeeplink` Notification

A single `NotificationCenter` channel (`Notification.Name.agentDetailDeeplink` on [`AgentManager`](../Packages/OsaurusCore/Managers/AgentManager.swift)) routes navigation between the detail-view chrome and any view that wants to focus a specific entity. The `userInfo` shape:

| Key         | Type              | Meaning                                                      |
| ----------- | ----------------- | ------------------------------------------------------------ |
| `agentId`   | `UUID` (required) | Which agent to focus.                                        |
| `tab`       | `String`          | `DetailTab` raw value (`configure`, `schema`, `data`, …).    |
| `tableRef`  | `String?`         | Optional table name to pre-select on the Data / Schema tab.  |
| `viewRef`   | `String?`         | Optional view name to pre-select on the Views tab.           |

Posters include the Mode chip in [`NextRunPanelView`](../Packages/OsaurusCore/Views/Agent/NextRunPanelView.swift), the Data-tab "Open" buttons, the Schema-tab "Browse" buttons, and the system notifications fired by [`NotificationService`](../Packages/OsaurusCore/Services/NotificationService.swift). [`AgentsView`](../Packages/OsaurusCore/Views/Agent/AgentsView.swift) is the sole subscriber — it flips `selectedTab` and threads the optional refs through to the focused tab's `initialFocused…` parameter.

---

## Related Documentation

- [Memory](MEMORY.md) — Global, app-wide memory system. Orthogonal to Agent DB; an agent can use neither, either, or both.
- [Storage](STORAGE.md) — Key management, SQLCipher encryption, and the full list of on-disk artifacts.
- [Agent Loop](AGENT_LOOP.md) — The chat loop, the always-on `todo` / `complete` / `clarify` tools, and how `db_*` slots into the same `ToolRegistry`.
- [Features Overview](FEATURES.md) — Complete feature inventory.
