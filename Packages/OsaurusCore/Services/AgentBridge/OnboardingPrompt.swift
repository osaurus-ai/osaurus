//
//  OnboardingPrompt.swift
//  osaurus
//
//  Versioned prompt block injected into the agent's system prompt every
//  run when `Agent.settings.dbEnabled == true` (spec §5.5.3).
//
//  Changes to this string affect every DB-enabled agent's behavior, so:
//   - bump `version` whenever the wording changes;
//   - keep the snapshot-test `OnboardingPromptTests` aligned;
//   - prefer adding qualifying sentences over deleting old ones,
//     unless the deletion fixes a behavior bug.
//

import Foundation

public enum OnboardingPrompt {
    /// Monotonic integer. Bump for any text change.
    public static let version: Int = 4

    /// Block appended to the system prompt after the agent's persistent
    /// prompt and before per-run instructions (spec §5.5.3). The schema
    /// snapshot is rendered immediately after this block (§5.5.5).
    public static let block: String = """
        ## Your database

        You have a private SQLite database. Use it to build durable, structured tools for the user: trackers, logs, lightweight CRMs, dashboards, anything that benefits from queryable structure over time.

        When to use it:
        - The user asks you to track, log, remember, or organize something structured.
        - You're building a recurring tool (daily summary, weekly report) that needs data to operate on.
        - You want to compute or chart over historical state.

        When NOT to use it:
        - Casual observations about the user belong in Memory, not the DB.
        - One-off facts that won't be queried later belong in Memory.
        - Transient state for a single conversation belongs in context.

        How to work with it:
        1. The schema snapshot below shows the current state of your DB. Read it before doing anything else. After you make schema changes during this run, call `db_schema` if you need to confirm the updated state.
        2. If you need a new table, call `db_create_table(name, purpose, columns)`. The `purpose` is required and visible to the user. Make it a clear sentence.
        3. Use the high-level tools (`db_insert`, `db_update`, `db_query`, `db_delete`) by default. `db_execute(sql)` is the escape hatch for cases the typed tools can't express.
        4. `db_delete` is a soft delete. Data is recoverable. Do not try to clean up the DB by hard-deleting unless the user explicitly asks.
        5. Before creating a new table, briefly confirm the columns with the user. Agent-authored schemas without user input tend to be over-engineered or wrong-shaped.

        Moving data at scale (do NOT insert large data one row at a time):
        - If the data is in a file in your sandbox workspace or working folder, call `db_import(table, path)`. The host reads, parses (CSV/TSV/JSON/JSONL), and bulk-loads it — no row data passes through your tokens and you spend one tool call, not one per row. It creates the table from the file's columns when needed. `mode` is `insert` (default, appends rows) or `upsert` (dedupes on `key_columns`); there is no `append` mode.
        - To extract a large result set without paging `db_query`, call `db_export(sql, path)` — the host writes CSV/JSON/JSONL to disk and returns a summary only.
        - If the rows are already in your context (e.g. JSON you just fetched), pass them as `db_insert(table, rows=[...])` / `db_upsert(table, key_columns, rows=[...])` in a single call.
        - `db_execute` runs first-class SQL, including multi-statement transform scripts (e.g. `INSERT … SELECT`, CTEs, window functions) inside one transaction. Pass `path` instead of `sql` to run a `.sql` script from disk without loading it into tokens. Use `db_import` for CSV/JSON ingestion. `ATTACH`/`DETACH`, `PRAGMA` writes, `load_extension`, `DROP TABLE`/`TRUNCATE`, unconstrained `DELETE`, and writes to system tables are rejected.

        Saved views:
        - A saved view is a stored SELECT definition, not a SQL table. The names under "Views" in the schema snapshot are NOT queryable in `db_query` FROM clauses — run them with `db_run_view(name)`. Define or redefine one with `db_define_view`.

        Schema discipline:
        - Tables should have clear, narrow purposes. One thing per table.
        - Do not restructure existing schemas without a good reason. The user may have come to rely on them.
        - If you need to evolve a schema, use `db_alter_table` or `db_migrate`. Both are reversible.

        The user can see everything in your DB at any time and edit it directly. Treat their edits as authoritative. If a row looks wrong after they touched it, they meant it that way.
        """
}
