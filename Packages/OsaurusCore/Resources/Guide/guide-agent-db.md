---
title: Agent Database and Self-Scheduling
summary: Give an agent its own private SQLite database and let it schedule its own next wake-up.
order: 95
---

# Agent Database and Self-Scheduling

Two per-agent capabilities turn a stateless chat agent into something that remembers structured data across runs and wakes itself up to act on it. Both are off by default and independent — enable one, both, or neither in the agent's Abilities → Overview tab.

## Agent Database

- Toggle **Database** on a custom agent and it gets its own private SQLite file (`~/.osaurus/agents/<id>/db.sqlite`) plus the `db_*` tools: schema management (`db_create_table`, `db_alter_table`, `db_migrate`), row writes (`db_insert`, `db_upsert`, `db_update`), reads (`db_query`, saved views via `db_define_view` / `db_run_view`), and bulk `db_import` / `db_export` (CSV/TSV/JSON/JSONL).
- Every table gets `_created_at` / `_updated_at` / `_deleted_at` system columns. Deletes are **soft** — `db_delete` stamps a tombstone and `db_restore` brings the row back; there is no hard-delete tool.
- Destructive SQL is blocked (`DROP TABLE`, `DELETE` without `WHERE` warnings, extension loading, writes to system tables). Every mutation is recorded in a changelog you can audit.
- The agent detail view gains Home, Schema, Data, Views, and Activity tabs for browsing the schema, rows (Active/Deleted/All), saved views, and run history.
- Storage is capped (100 MB by default); writes are rejected past the limit and a warning appears as usage approaches it.
- This is distinct from Memory (global, conversation-derived) and Knowledge (your curated docs): the agent DB is per-agent structured storage the agent schemas itself.

## Self-Scheduling

- Toggle **Self-scheduling** and the agent gets `schedule_next_run` / `cancel_next_run` / `notify` tools and exactly one pending "next run" slot.
- Wake-ups are single-shot: each wake runs in a fresh chat session, and the agent must call `schedule_next_run` again to keep going. Continuity flows through the instructions it writes for its next wake and through its database.
- The schedule **mode** bounds how often it can wake: Ambient (7-day horizon, 6/day, quiet hours 22:00–07:00), Reactive (24 h, 48/day), Project (30 days, 4/day, quiet hours). Requests beyond the bounds are clamped and the agent is told why.
- A **Next Run** banner in the agent view shows the pending wake with Pause / Run now / Edit / Cancel. Pauses can be timed (1 h, 4 h, until tomorrow, custom, indefinite).
- Missed wakes (Mac asleep) follow the slot's on-miss policy: skip (default), run once, or catch up.

## Notes

- The Default assistant cannot use these capabilities — they are for custom agents.
- Storage follows the app-wide posture: plaintext by default (FileVault-protected), SQLCipher-encrypted if you opted into storage encryption.
