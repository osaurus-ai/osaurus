//
//  ChatHistoryDatabase.swift
//  osaurus
//
//  The pre-sync chat history, kept as a read-only import source. Chats live
//  in `SyncConversationStore`; this database is only opened to import the
//  old sessions (`SyncLegacyImporter`), to copy legacy sandbox and file-change
//  rows (`FileChangeJournal`), and to remove a chat's old row when the chat
//  is deleted. Nothing writes sessions or turns here any more.
//
//  The migrations stay: an older backup still has to reach the current
//  schema before it can be read. Encrypted with SQLCipher
//  (`OsaurusSQLCipher`) under the `StorageKeyManager` key; in-memory test
//  databases are plaintext.
//

import Foundation
import OsaurusSQLCipher

public enum ChatHistoryDatabaseError: Error, LocalizedError {
    case failedToOpen(String)
    case failedToExecute(String)
    case failedToPrepare(String)
    case migrationFailed(String)
    case notOpen

    public var errorDescription: String? {
        switch self {
        case .failedToOpen(let m): return "Failed to open chat-history database: \(m)"
        case .failedToExecute(let m): return "Failed to execute chat-history query: \(m)"
        case .failedToPrepare(let m): return "Failed to prepare chat-history statement: \(m)"
        case .migrationFailed(let m): return "Chat-history migration failed: \(m)"
        case .notOpen: return "Chat-history database is not open"
        }
    }
}

public final class ChatHistoryDatabase: @unchecked Sendable {
    public static let shared = ChatHistoryDatabase()

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "ai.osaurus.chatHistory.database")
    private let stmtCache = PreparedStatementCache(capacity: 64)

    /// Mirrors `db != nil` without hopping onto `queue`. `isOpen` does a
    /// `queue.sync`, which parks the caller behind an in-flight `open()`
    /// (slow disk: file open + WAL + migrations) — exactly the wait that
    /// main-thread callers use this flag to avoid.
    private let openFlagLock = NSLock()
    private var openFlag = false

    /// Non-blocking `isOpen`. May lag an in-flight `open()` by design.
    public var isOpenNonBlocking: Bool {
        openFlagLock.lock()
        defer { openFlagLock.unlock() }
        return openFlag
    }

    private func setOpenFlag(_ value: Bool) {
        openFlagLock.lock()
        openFlag = value
        openFlagLock.unlock()
    }

    init() {}

    deinit { close() }

    // MARK: - Lifecycle

    public func open() throws {
        // Defensive gate: parks only while a key rotation is
        // re-encrypting databases so we can't open a half-rekeyed
        // file with the wrong key. No-op fast path otherwise.
        StorageMutationGate.blockingAwaitNotMutating()
        try queue.sync {
            guard db == nil else { return }
            OsaurusPaths.ensureExistsSilent(OsaurusPaths.chatHistory())
            do {
                try openConnection()
                try runMigrations()
                setOpenFlag(true)
            } catch {
                // Report initial connection/key/pragma failures as well as
                // migration failures so the recovery UI can offer Retry.
                // Don't leave a live, half-migrated connection: `db` is set by
                // `openConnection()`, and a non-nil `db` makes every later
                // `open()` no-op-succeed (`guard db == nil`), running the app
                // against a schema missing columns its SQL expects. Close it,
                // record the failure so it surfaces in `/health` + the recovery
                // UI, and rethrow so `StorageRecoveryService` can retry/reset.
                stmtCache.clear()
                if let connection = db {
                    sqlite3_close(connection)
                    db = nil
                }
                PersistenceHealth.shared.recordDatabaseOpenFailure(
                    subsystem: StorageRecoveryService.Store.chatHistory.rawValue,
                    error: error,
                    path: OsaurusPaths.chatHistoryDatabaseFile().path
                )
                throw error
            }
        }
        OsaurusDatabaseHandle.register(maintenanceHandle)
    }

    private lazy var maintenanceHandle = OsaurusDatabaseHandle(
        name: "chat-history",
        exec: { [weak self] sql in
            self?.queue.sync {
                guard self?.db != nil else { return }
                try? self?.executeRaw(sql)
            }
        },
        closer: { [weak self] in self?.close() },
        reopener: { [weak self] in try? self?.open() }
    )

    /// Open an in-memory database for testing. **Plaintext** — no
    /// encryption is applied; tests can still verify SQLCipher
    /// integration via `SQLCipherIntegrationTests`.
    func openInMemory() throws {
        try queue.sync {
            guard db == nil else { return }
            db = try EncryptedSQLiteOpener.open(
                path: ":memory:",
                key: nil,
                applyPerfPragmas: false
            )
            try runMigrations()
            setOpenFlag(true)
        }
    }

    public func close() {
        OsaurusDatabaseHandle.deregister(name: "chat-history")
        queue.sync {
            stmtCache.clear()
            guard let connection = db else { return }
            try? executeRaw("PRAGMA optimize")
            sqlite3_close(connection)
            db = nil
            setOpenFlag(false)
        }
    }

    public var isOpen: Bool { queue.sync { db != nil } }

    // MARK: - Connection / Schema

    private func openConnection() throws {
        let path = OsaurusPaths.chatHistoryDatabaseFile().path
        do {
            db = try OsaurusStorageOpener.open(path: path)
        } catch let error as EncryptedSQLiteError {
            throw ChatHistoryDatabaseError.failedToOpen(error.localizedDescription)
        }
    }

    /// Highest schema version this build knows how to produce.
    /// Internal (not private) so migration-repair tests assert "reconciled
    /// to the latest" against the real constant instead of a stale literal.
    static let latestSchemaVersion = 26

    /// Forward-compatibility invariant. Every chat-history migration is
    /// **additive** — it only `ADD COLUMN`s, `CREATE INDEX`es, or `CREATE
    /// TABLE`s; it never drops, renames, or re-types an existing column, and
    /// never changes the meaning of one this build already reads. That means a
    /// DB stamped by a *newer* build is still safe for this build to open: the
    /// extra columns are simply ignored on read.
    ///
    /// Because of that invariant we **open version-ahead databases instead of
    /// refusing them**. Hard-refusing (the old behavior) is what turned a
    /// harmless schema-ahead DB — a user who ran a projects/beta build and then
    /// a stable build, or bounced between release channels — into the "all my
    /// chat history is gone after updating" report: the file was untouched but
    /// the sidebar rendered empty and looked like total data loss.
    ///
    /// IMPORTANT: if a future migration ever becomes destructive (drops /
    /// renames / re-types an existing column, or changes its semantics), this
    /// forward-open is no longer safe. Such a change MUST introduce an explicit
    /// minimum-compatible-version gate rather than rely on this constant.
    ///
    /// Every step must also stay **idempotent** (`addColumnIfMissing`,
    /// `CREATE … IF NOT EXISTS`): every open replays the whole ladder to
    /// pick up columns a sibling build's same-numbered step never added
    /// (see `reconcileAdditiveSchema`).
    static let migrationsAreAdditiveOnly = true

    private func runMigrations() throws {
        let current = try getSchemaVersion()
        // Always replay the idempotent ladder. Version numbers are claimed
        // independently on parallel branches, so a store stamped 15 *or* 17
        // may still lack a column this build's SELECTs name. The old
        // version-gated path skipped earlier steps once the stamp was past
        // them — field report / #2736: `user_version = 15` with `project_id`
        // but no `shared_artifacts`, every save throwing `failedToPrepare`.
        // Stamp `max(on-disk, latest)` so a sibling v17 stamp is preserved
        // and a lagging store advances to this build's schema.
        try reconcileAdditiveSchema(preservingVersion: max(current, Self.latestSchemaVersion))
        try assertWritableSchema()
    }

    /// Every migration body in ladder order. `reconcileAdditiveSchema`
    /// replays all of them on every open.
    private var migrationLadder: [() throws -> Void] {
        [
            migrateToV1, migrateToV2, migrateToV3, migrateToV4, migrateToV5, migrateToV6,
            migrateToV7, migrateToV8, migrateToV9, migrateToV10, migrateToV11, migrateToV12,
            migrateToV13, migrateToV14, migrateToV15, migrateToV16, migrateToV17,
            migrateToV18, migrateToV19, migrateToV20, migrateToV21, migrateToV22, migrateToV23,
            migrateToV24, migrateToV25, migrateToV26,
        ]
    }

    /// Re-run every (idempotent) migration body, then put `version` on the
    /// stamp. Cheap when nothing is missing — each step is a `PRAGMA
    /// table_info` scan or `IF NOT EXISTS` — and it repairs a store that
    /// another build stamped at or ahead of this one without carrying this
    /// build's columns. One transaction: a failure leaves the store exactly
    /// as found.
    private func reconcileAdditiveSchema(preservingVersion version: Int) throws {
        try executeRaw("BEGIN TRANSACTION")
        do {
            for step in migrationLadder { try step() }
            // Each body stamps its own version; restore the (possibly
            // higher) one we were handed so the build that owns it still
            // recognizes it, or advance a lagging store to `latest`.
            try setSchemaVersion(version)
            try executeRaw("COMMIT")
        } catch {
            try? executeRaw("ROLLBACK")
            throw ChatHistoryDatabaseError.migrationFailed(
                "reconcile at v\(version): \(error.localizedDescription)")
        }
    }

    /// Columns the reads and the importer depend on, including the ones only
    /// older builds wrote. If one is missing after the ladder, `open()` fails
    /// closed instead of succeeding and then returning half-read rows.
    private static let requiredSessionColumns = [
        "id", "title", "created_at", "updated_at", "selected_model", "agent_id",
        "source", "source_plugin_id", "external_session_key", "dispatch_task_id",
        "archived", "capabilities", "folder_bookmark", "folder_path", "pinned",
        "project_id", "workspace_context", "remote_agent_address", "parked_workflow_runs",
        "automation_kind", "conversation_summary",
    ]
    private static let requiredTurnColumns = [
        "id", "session_id", "seq", "role", "content", "attachments", "shared_artifacts",
        "tool_calls", "tool_call_id", "tool_results", "thinking", "content_hash",
        "created_at", "completed_at", "generation_token_count", "time_to_first_token",
        "tool_call_durations", "thinking_duration", "router_billing",
        "terminal_stop_reason", "model_context_excluded", "tool_call_logs",
        "injected_context_prefix", "generation_tokens_per_second", "model_load_seconds", "last_output_at",
        "requested_at",
        "reasoning_item_id", "reasoning_encrypted", "responses_output_items",
        "anthropic_thinking_blocks", "input_token_count", "cached_input_token_count", "turn_generation_controls",
    ]

    private func assertWritableSchema() throws {
        let missingSessions = Self.requiredSessionColumns.filter { !tableHasColumn("sessions", $0) }
        let missingTurns = Self.requiredTurnColumns.filter { !tableHasColumn("turns", $0) }
        guard missingSessions.isEmpty, missingTurns.isEmpty else {
            var parts: [String] = []
            if !missingSessions.isEmpty {
                parts.append("sessions missing \(missingSessions.joined(separator: ", "))")
            }
            if !missingTurns.isEmpty {
                parts.append("turns missing \(missingTurns.joined(separator: ", "))")
            }
            throw ChatHistoryDatabaseError.migrationFailed(
                "writable schema incomplete: \(parts.joined(separator: "; "))"
            )
        }
    }

    private func getSchemaVersion() throws -> Int {
        var version = 0
        try executeRaw("PRAGMA user_version") { stmt in
            if sqlite3_step(stmt) == SQLITE_ROW {
                version = Int(sqlite3_column_int(stmt, 0))
            }
        }
        return version
    }

    private func setSchemaVersion(_ v: Int) throws {
        try executeRaw("PRAGMA user_version = \(v)")
    }

    /// Whether `table` currently has `column`. Cheap `PRAGMA table_info`
    /// scan, mirroring `MemoryDatabase`'s idempotent-migration helper.
    private func tableHasColumn(_ table: String, _ column: String) -> Bool {
        var found = false
        try? executeRaw("PRAGMA table_info(\(table))") { stmt in
            while sqlite3_step(stmt) == SQLITE_ROW {
                if String(cString: sqlite3_column_text(stmt, 1)) == column {
                    found = true
                    break
                }
            }
        }
        return found
    }

    /// Idempotent `ALTER TABLE <table> ADD COLUMN <column> <type>`, run only
    /// when `column` is absent (`type` carries the SQL type + any
    /// constraints, e.g. `TEXT NOT NULL DEFAULT ''`). Re-running a migration
    /// step on a DB that already has the column — e.g. a store whose
    /// `user_version` is stuck behind columns a prior build (or the
    /// encryption-convergence rebuild) already added — is then a no-op
    /// instead of a fatal `duplicate column name` error that aborts `open()`
    /// and renders the whole chat history unreadable and unwritable.
    private func addColumnIfMissing(_ table: String, _ column: String, _ type: String) throws {
        guard !tableHasColumn(table, column) else { return }
        try executeRaw("ALTER TABLE \(table) ADD COLUMN \(column) \(type)")
    }

    private func migrateToV1() throws {
        try executeRaw(
            """
                CREATE TABLE IF NOT EXISTS sessions (
                    id                   TEXT PRIMARY KEY,
                    title                TEXT NOT NULL,
                    created_at           REAL NOT NULL,
                    updated_at           REAL NOT NULL,
                    selected_model       TEXT,
                    agent_id             TEXT,
                    source               TEXT NOT NULL DEFAULT 'chat',
                    source_plugin_id     TEXT,
                    external_session_key TEXT,
                    dispatch_task_id     TEXT,
                    turn_count           INTEGER NOT NULL DEFAULT 0
                )
            """
        )
        try executeRaw("CREATE INDEX IF NOT EXISTS idx_sessions_agent ON sessions (agent_id)")
        try executeRaw("CREATE INDEX IF NOT EXISTS idx_sessions_source ON sessions (source)")
        try executeRaw(
            "CREATE INDEX IF NOT EXISTS idx_sessions_plugin_key ON sessions (source_plugin_id, external_session_key)"
        )
        try executeRaw("CREATE INDEX IF NOT EXISTS idx_sessions_updated ON sessions (updated_at DESC)")

        try executeRaw(
            """
                CREATE TABLE IF NOT EXISTS turns (
                    id            TEXT PRIMARY KEY,
                    session_id    TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                    seq           INTEGER NOT NULL,
                    role          TEXT NOT NULL,
                    content       TEXT,
                    attachments   TEXT,
                    tool_calls    TEXT,
                    tool_call_id  TEXT,
                    tool_results  TEXT,
                    thinking      TEXT NOT NULL DEFAULT ''
                )
            """
        )
        try executeRaw("CREATE UNIQUE INDEX IF NOT EXISTS idx_turns_session_seq ON turns (session_id, seq)")

        try setSchemaVersion(1)
    }

    /// v2: add `content_hash` so `upsertTurnsIncrementally` can skip
    /// rewrites when a turn's persisted shape hasn't changed (massive
    /// win for the post-stream `save()` path that previously ran
    /// `DELETE all + INSERT all`).
    private func migrateToV2() throws {
        try addColumnIfMissing("turns", "content_hash", "TEXT NOT NULL DEFAULT ''")
        try setSchemaVersion(2)
    }

    /// v3: add `archived` flag on sessions so the sidebar can hide
    /// conversations under an opt-in "Archived" filter without deleting
    /// them.
    private func migrateToV3() throws {
        try addColumnIfMissing("sessions", "archived", "INTEGER NOT NULL DEFAULT 0")
        try setSchemaVersion(3)
    }

    /// v4: add `capabilities` (comma-separated `SessionCapability`
    /// raw values) so the sidebar can render per-row badges without
    /// loading every turn. Existing rows keep an empty string and will
    /// fill in lazily when the user next saves them; a full backfill
    /// would require parsing every turn's attachments + toolCalls JSON
    /// in Swift, which we avoid here to keep the migration cheap.
    private func migrateToV4() throws {
        try addColumnIfMissing("sessions", "capabilities", "TEXT NOT NULL DEFAULT ''")
        try setSchemaVersion(4)
    }

    /// v5: per-turn timing for opt-in inclusion in exports (billing /
    /// reporting). All four columns are nullable so legacy turns just
    /// surface no timing data, matching the exporter's "leave blank"
    /// behavior. `created_at` and `completed_at` are stored as REAL
    /// (timeIntervalSince1970), consistent with the session timestamps.
    private func migrateToV5() throws {
        try addColumnIfMissing("turns", "created_at", "REAL")
        try addColumnIfMissing("turns", "completed_at", "REAL")
        try addColumnIfMissing("turns", "generation_token_count", "INTEGER")
        try addColumnIfMissing("turns", "time_to_first_token", "REAL")
        try setSchemaVersion(5)
    }

    /// v6: add `tool_call_durations` — a JSON map of `callId -> seconds` so the
    /// chat UI can show "· 1.2s" next to each completed tool call after reload.
    /// Nullable; legacy turns just surface no durations.
    private func migrateToV6() throws {
        try addColumnIfMissing("turns", "tool_call_durations", "TEXT")
        try setSchemaVersion(6)
    }

    /// v7: add `thinking_duration` (REAL seconds) so the thinking block can show
    /// "Thought for 30s" after reload. Nullable; legacy turns surface nothing.
    private func migrateToV7() throws {
        try addColumnIfMissing("turns", "thinking_duration", "REAL")
        try setSchemaVersion(7)
    }

    /// v8: add `router_billing` — JSON `RouterBillingSummary` (cost, token
    /// counts, status) for an Osaurus Router turn, so a reloaded chat still
    /// shows a billed-but-empty turn and its "you were charged" notice rather
    /// than a silent gap. Nullable; metadata only (no prompt/response text).
    private func migrateToV8() throws {
        try addColumnIfMissing("turns", "router_billing", "TEXT")
        try setSchemaVersion(8)
    }

    /// v9: add `sandbox_changes` — one row per net outstanding sandbox
    /// workspace change per chat session, backing the chat "Changes" list
    /// and its undo across app relaunches. No FK on sessions: a change can
    /// be recorded before the session row's first save lands; cleanup is
    /// explicit in `deleteSession`.
    private func migrateToV9() throws {
        try executeRaw(
            """
                CREATE TABLE IF NOT EXISTS sandbox_changes (
                    id                 TEXT PRIMARY KEY,
                    session_id         TEXT NOT NULL,
                    agent_name         TEXT NOT NULL,
                    root               TEXT NOT NULL,
                    relative_path      TEXT NOT NULL,
                    entry_type         TEXT NOT NULL,
                    kind               TEXT NOT NULL,
                    state              TEXT NOT NULL,
                    baseline_signature TEXT,
                    current_signature  TEXT,
                    source_tool        TEXT NOT NULL DEFAULT '',
                    first_changed_at   REAL NOT NULL,
                    last_changed_at    REAL NOT NULL,
                    UNIQUE(session_id, agent_name, root, relative_path)
                )
            """
        )
        try executeRaw(
            "CREATE INDEX IF NOT EXISTS idx_sandbox_changes_session ON sandbox_changes (session_id)"
        )
        try setSchemaVersion(9)
    }

    /// v10: per-session working folder. `folder_bookmark` is the
    /// security-scoped bookmark blob (nil = no folder); `folder_path` is the
    /// non-sensitive display path that survives a stale bookmark. Both
    /// nullable — legacy rows simply have no folder, matching the pre-v10
    /// behavior where the (process-global) folder was never persisted per
    /// chat.
    private func migrateToV10() throws {
        try addColumnIfMissing("sessions", "folder_bookmark", "BLOB")
        try addColumnIfMissing("sessions", "folder_path", "TEXT")
        try setSchemaVersion(10)
    }

    /// v11: add `pinned` flag on sessions so the sidebar can float
    /// frequently-used conversations to the top of the list.
    private func migrateToV11() throws {
        try addColumnIfMissing("sessions", "pinned", "INTEGER NOT NULL DEFAULT 0")
        try setSchemaVersion(11)
    }

    /// v12: persist the runtime's authoritative finish reason so a reloaded
    /// chat keeps distinguishing a natural stop from output-token exhaustion.
    /// Nullable for legacy turns and providers that do not report a reason.
    private func migrateToV12() throws {
        try addColumnIfMissing("turns", "terminal_stop_reason", "TEXT")
        try setSchemaVersion(12)
    }

    /// v13: mark an abandoned reasoning/protocol attempt as transcript-only.
    /// The turn remains visible to the user, but later requests (including
    /// after an app restart) must not replay it beside the successful retry.
    private func migrateToV13() throws {
        try addColumnIfMissing("turns", "model_context_excluded", "INTEGER NOT NULL DEFAULT 0")
        try setSchemaVersion(13)
    }

    /// v14: persist chat-local shared artifacts. Generated images, videos,
    /// screenshots, and files already live under the session artifact directory;
    /// this column retains the metadata needed to render them after chat reload.
    private func migrateToV14() throws {
        try addColumnIfMissing("turns", "shared_artifacts", "TEXT")
        try setSchemaVersion(14)
    }

    /// v15: add `project_id` so sessions can be grouped under user-created
    /// projects. Nullable — legacy rows belong to no project.
    ///
    /// An earlier revision of this branch claimed v14 for `project_id` while
    /// main's v14 shipped `shared_artifacts`, so a database stamped 14 may
    /// carry either column but not the other. Both adds are
    /// `addColumnIfMissing`, so this step repairs whichever half is absent
    /// regardless of which v14 the database actually ran.
    private func migrateToV15() throws {
        try addColumnIfMissing("sessions", "project_id", "TEXT")
        try executeRaw("CREATE INDEX IF NOT EXISTS idx_sessions_project ON sessions (project_id)")
        try addColumnIfMissing("turns", "shared_artifacts", "TEXT")
        try setSchemaVersion(15)
    }

    /// v16: Workspaces. `workspace_context` is the JSON
    /// `WorkspaceSessionContext` (workspace id, shared-agent address, and —
    /// host side — the teammate caller); `remote_agent_address` duplicates
    /// the lowercased address as a plain indexed column so the sidebar can
    /// list a team agent's history without parsing JSON. Both nullable —
    /// legacy rows are local chats.
    private func migrateToV16() throws {
        try addColumnIfMissing("sessions", "workspace_context", "TEXT")
        try addColumnIfMissing("sessions", "remote_agent_address", "TEXT")
        try executeRaw(
            "CREATE INDEX IF NOT EXISTS idx_sessions_remote_agent ON sessions (remote_agent_address)"
        )
        try setSchemaVersion(16)
    }

    /// v17: `tool_call_logs` — JSON map of `callId -> SubagentRunLog`, the
    /// finished Computer Use / AppleScript step log shown under the tool
    /// row. Nullable; legacy turns have none.
    private func migrateToV17() throws {
        try addColumnIfMissing("turns", "tool_call_logs", "TEXT")
        try setSchemaVersion(17)
    }

    /// v18: `injected_context_prefix` — the frozen `[Current Time]` / memory /
    /// screen block a user turn was SENT with. `ChatTurnData` has always
    /// documented it as persisted "so a reloaded session replays the exact
    /// wire bytes of every past turn and the disk-backed prefix cache can
    /// still hit", but no column carried it: after a relaunch (or reopening
    /// a chat from History) every past user turn rendered WITHOUT its block,
    /// the prompt diverged at the first user turn, and the whole conversation
    /// was prefilled again — measured live, a 10.7k-token chat resumed with
    /// a hit at the 3.5k-token system prompt only. Additive and nullable;
    /// a sibling build that already added the column is left as found.
    private func migrateToV18() throws {
        try addColumnIfMissing("turns", "injected_context_prefix", "TEXT")
        try setSchemaVersion(18)
    }

    /// v19: retain displayed generation metrics and the pre-finalization output boundary.
    private func migrateToV19() throws {
        try addColumnIfMissing("turns", "generation_tokens_per_second", "REAL")
        try addColumnIfMissing("turns", "model_load_seconds", "REAL")
        try addColumnIfMissing("turns", "last_output_at", "REAL")
        try setSchemaVersion(19)
    }

    /// v21: when the user sent the run (before any pre-send model load), the
    /// start of the footer's total response time.
    private func migrateToV21() throws {
        try addColumnIfMissing("turns", "requested_at", "REAL")
        try setSchemaVersion(21)
    }

    /// v22: `parked_workflow_runs` — JSON `[ParkedWorkflowCall]`, the
    /// workflow calls a Work Mode task was waiting on when it was saved, so
    /// a chat reopened after a relaunch picks up its (resumed) runs.
    /// Nullable; legacy rows wait on nothing.
    private func migrateToV22() throws {
        try addColumnIfMissing("sessions", "parked_workflow_runs", "TEXT")
        try setSchemaVersion(22)
    }

    /// v23: `automation_kind` — the trigger kind (`EventSourceKind` raw) of
    /// an `.automation` session. Nullable; legacy rows keep their specific
    /// `source`.
    private func migrateToV23() throws {
        try addColumnIfMissing("sessions", "automation_kind", "TEXT")
        try setSchemaVersion(23)
    }

    /// v24: native provider state is part of the conversation, not a display
    /// projection. Nullable columns keep legacy chats readable without
    /// inventing IDs, signatures, opaque payloads or token measurements.
    /// Upstream stamps these columns as v22; the ladder replays every step,
    /// so a store from either numbering ends up with all of them.
    private func migrateToV24() throws {
        try addColumnIfMissing("turns", "reasoning_item_id", "TEXT")
        try addColumnIfMissing("turns", "reasoning_encrypted", "TEXT")
        try addColumnIfMissing("turns", "responses_output_items", "TEXT")
        try addColumnIfMissing("turns", "anthropic_thinking_blocks", "TEXT")
        try addColumnIfMissing("turns", "input_token_count", "INTEGER")
        try addColumnIfMissing("turns", "cached_input_token_count", "INTEGER")
        try setSchemaVersion(24)
    }

    /// v25: request controls belong to the user turn, surviving retry/relaunch.
    /// Upstream stamps this column as v23; the ladder replays every step.
    private func migrateToV25() throws {
        try addColumnIfMissing("turns", "turn_generation_controls", "TEXT")
        try setSchemaVersion(25)
    }

    /// v26: `conversation_summary` — the accepted compaction summary, JSON
    /// `ConversationSummary`. Upstream stamps this column as v24; the ladder
    /// replays every step. Read on import so a compacted chat keeps its
    /// summary instead of restoring the full prompt.
    private func migrateToV26() throws {
        try addColumnIfMissing("sessions", "conversation_summary", "TEXT")
        try setSchemaVersion(26)
    }

    /// v20: git-like file history. One `file_change_sets` row per mutating
    /// tool call (or revert), one `file_change_entries` row per touched
    /// path with exact before/after signatures (bytes live in the
    /// content-addressed object store). Supersedes `sandbox_changes`,
    /// whose rows are imported by `FileChangeJournal` on first open.
    private func migrateToV20() throws {
        try executeRaw(
            """
                CREATE TABLE IF NOT EXISTS file_change_sets (
                    id              TEXT PRIMARY KEY,
                    session_id      TEXT NOT NULL,
                    tool_name       TEXT NOT NULL DEFAULT '',
                    tool_call_id    TEXT,
                    turn_id         TEXT,
                    origin          TEXT NOT NULL,
                    status          TEXT NOT NULL,
                    reverts_set_id  TEXT,
                    note            TEXT,
                    created_at      REAL NOT NULL
                )
            """
        )
        try executeRaw(
            """
                CREATE TABLE IF NOT EXISTS file_change_entries (
                    id           TEXT PRIMARY KEY,
                    set_id       TEXT NOT NULL,
                    session_id   TEXT NOT NULL,
                    ordinal      INTEGER NOT NULL DEFAULT 0,
                    root_kind    TEXT NOT NULL,
                    root_id      TEXT NOT NULL,
                    path         TEXT NOT NULL,
                    from_path    TEXT,
                    kind         TEXT NOT NULL,
                    state        TEXT NOT NULL,
                    before_type  TEXT,
                    before_sig   TEXT,
                    before_mode  INTEGER,
                    before_size  INTEGER,
                    after_type   TEXT,
                    after_sig    TEXT,
                    after_mode   INTEGER,
                    after_size   INTEGER
                )
            """
        )
        try executeRaw(
            "CREATE INDEX IF NOT EXISTS idx_file_change_sets_session ON file_change_sets (session_id, created_at)"
        )
        try executeRaw(
            "CREATE INDEX IF NOT EXISTS idx_file_change_sets_tool_call ON file_change_sets (tool_call_id)"
        )
        try executeRaw(
            "CREATE INDEX IF NOT EXISTS idx_file_change_entries_set ON file_change_entries (set_id)"
        )
        try executeRaw(
            "CREATE INDEX IF NOT EXISTS idx_file_change_entries_session ON file_change_entries (session_id, state)"
        )
        try setSchemaVersion(20)
    }

    // MARK: - Public API: sessions

    /// Load a session by id, including its turns in seq order. Returns
    /// nil if not found. Both the session row and its turns are
    /// fetched inside one `queue.sync` block so the main actor only
    /// pays a single round-trip across the serial queue.
    public func loadSession(id: UUID) -> ChatSessionData? {
        MainThreadOperationLedger.shared.withMainThreadOperation(
            subsystem: "chat-history-db", operation: "load-session"
        ) {
            loadSessionOnQueue(id: id)
        }
    }

    private func loadSessionOnQueue(id: UUID) -> ChatSessionData? {
        var session: ChatSessionData?
        do {
            try queue.sync {
                guard let connection = self.db else { throw ChatHistoryDatabaseError.notOpen }

                // 1. session row
                let sessionStmt = try self.stmtCache.statement(for: Self.selectSessionSQL, on: connection)
                Self.bindText(sessionStmt, index: 1, value: id.uuidString)
                if sqlite3_step(sessionStmt) == SQLITE_ROW {
                    session = Self.readSession(sessionStmt, turns: [])
                } else {
                    return
                }

                // 2. turns for that session, in seq order
                let turnsStmt = try self.stmtCache.statement(for: Self.selectTurnsSQL, on: connection)
                Self.bindText(turnsStmt, index: 1, value: id.uuidString)
                var turns: [ChatTurnData] = []
                while sqlite3_step(turnsStmt) == SQLITE_ROW {
                    if let turn = Self.readTurn(turnsStmt) {
                        turns.append(turn)
                    }
                }
                session?.turns = turns
            }
        } catch {
            print("[ChatHistoryDatabase] loadSession(\(id)) failed: \(error)")
            return nil
        }
        return session
    }

    /// Load all session rows (no turns) ordered by updated_at DESC.
    public func loadAllMetadata() -> [ChatSessionData] {
        var sessions: [ChatSessionData] = []
        do {
            try prepareAndExecute(
                Self.baseSessionSelectSQL + " ORDER BY updated_at DESC",
                bind: { _ in },
                process: { stmt in
                    while sqlite3_step(stmt) == SQLITE_ROW {
                        sessions.append(Self.readSession(stmt, turns: []))
                    }
                }
            )
        } catch {
            print("[ChatHistoryDatabase] loadAllMetadata failed: \(error)")
        }
        return sessions
    }

    /// Ids of sessions with no turn rows.
    public func emptySessionIds() -> Set<UUID> {
        var ids: Set<UUID> = []
        do {
            try prepareAndExecute(
                "SELECT id FROM sessions WHERE NOT EXISTS (SELECT 1 FROM turns WHERE turns.session_id = sessions.id)",
                bind: { _ in },
                process: { stmt in
                    while sqlite3_step(stmt) == SQLITE_ROW {
                        if let id = UUID(uuidString: String(cString: sqlite3_column_text(stmt, 0))) { ids.insert(id) }
                    }
                }
            )
        } catch {
            print("[ChatHistoryDatabase] emptySessionIds failed: \(error)")
        }
        return ids
    }

    public func deleteSession(id: UUID) throws {
        try MainThreadOperationLedger.shared.withMainThreadOperation(
            subsystem: "chat-history-db", operation: "delete-session"
        ) {
            try queue.sync { try deleteSessionOnQueue(id: id) }
        }
    }

    /// Body of a single-session delete. Must run on `queue`.
    private func deleteSessionOnQueue(id: UUID) throws {
        guard db != nil else { throw ChatHistoryDatabaseError.notOpen }

        // GC: collect blob refs from this session's turns *before*
        // deleting the rows, then drop any blob no other session
        // references. Conservative: only deletes when zero remaining
        // turns reference the hash.
        var ownedRefs: Set<String> = []
        try collectAttachmentRefsOnQueue(sessionId: id, into: &ownedRefs)

        try deleteSessionRowsOnQueue(id: id)

        // Best-effort GC. We re-check each hash against the surviving
        // rows; anything still referenced stays.
        for hash in ownedRefs where !isBlobReferencedOnQueue(hash) {
            AttachmentBlobStore.delete(hash)
        }
    }

    /// Collect the attachment blob hashes referenced by a session's turns.
    /// Must run on `queue`.
    private func collectAttachmentRefsOnQueue(sessionId id: UUID, into ownedRefs: inout Set<String>) throws {
        try transactionalQuery(
            "SELECT attachments FROM turns WHERE session_id = ?1",
            bind: { stmt in Self.bindText(stmt, index: 1, value: id.uuidString) },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    guard let cText = sqlite3_column_text(stmt, 0) else { continue }
                    let json = String(cString: cText)
                    let parsed: [Attachment]? = Self.decodeJSON(json)
                    for a in parsed ?? [] {
                        switch a.kind {
                        case .imageRef(let h, _), .documentRef(_, let h, _):
                            ownedRefs.insert(h)
                        default: continue
                        }
                    }
                }
            }
        )
    }

    /// Delete a session's row plus its keyed-but-FK-less cascades. Must run
    /// on `queue`; safe both standalone (autocommit) and inside an open
    /// transaction.
    private func deleteSessionRowsOnQueue(id: UUID) throws {
        try transactionalStep("DELETE FROM sessions WHERE id = ?1") { stmt in
            Self.bindText(stmt, index: 1, value: id.uuidString)
        }

        // Manual cascade: sandbox change rows are keyed by session id but
        // carry no FK (they can be written before the session row exists).
        try? transactionalStep("DELETE FROM sandbox_changes WHERE session_id = ?1") { stmt in
            Self.bindText(stmt, index: 1, value: id.uuidString)
        }
        try? transactionalStep("DELETE FROM file_change_entries WHERE session_id = ?1") { stmt in
            Self.bindText(stmt, index: 1, value: id.uuidString)
        }
        try? transactionalStep("DELETE FROM file_change_sets WHERE session_id = ?1") { stmt in
            Self.bindText(stmt, index: 1, value: id.uuidString)
        }
    }

    // MARK: - Legacy sandbox changes

    public func deleteSandboxChanges(sessionId: String) throws {
        _ = try executeUpdate("DELETE FROM sandbox_changes WHERE session_id = ?1") { stmt in
            Self.bindText(stmt, index: 1, value: sessionId)
        }
    }

    public func loadSandboxChanges(sessionId: String) -> [SandboxWorkspaceChange] {
        var changes: [SandboxWorkspaceChange] = []
        do {
            try prepareAndExecute(
                """
                SELECT id, session_id, agent_name, root, relative_path, entry_type,
                       kind, state, baseline_signature, current_signature, source_tool,
                       first_changed_at, last_changed_at
                FROM sandbox_changes
                WHERE session_id = ?1
                ORDER BY relative_path ASC
                """,
                bind: { stmt in Self.bindText(stmt, index: 1, value: sessionId) },
                process: { stmt in
                    while sqlite3_step(stmt) == SQLITE_ROW {
                        guard
                            let id = UUID(uuidString: String(cString: sqlite3_column_text(stmt, 0))),
                            let root = SandboxWorkspaceRootKind(
                                rawValue: String(cString: sqlite3_column_text(stmt, 3))),
                            let entryType = SandboxChangeEntryType(
                                rawValue: String(cString: sqlite3_column_text(stmt, 5))),
                            let kind = SandboxChangeKind(
                                rawValue: String(cString: sqlite3_column_text(stmt, 6))),
                            let state = SandboxChangeState(
                                rawValue: String(cString: sqlite3_column_text(stmt, 7)))
                        else { continue }
                        changes.append(
                            SandboxWorkspaceChange(
                                id: id,
                                sessionId: String(cString: sqlite3_column_text(stmt, 1)),
                                agentName: String(cString: sqlite3_column_text(stmt, 2)),
                                root: root,
                                relativePath: String(cString: sqlite3_column_text(stmt, 4)),
                                entryType: entryType,
                                kind: kind,
                                state: state,
                                baselineSignature: sqlite3_column_text(stmt, 8).map {
                                    String(cString: $0)
                                },
                                currentSignature: sqlite3_column_text(stmt, 9).map {
                                    String(cString: $0)
                                },
                                sourceTool: String(cString: sqlite3_column_text(stmt, 10)),
                                firstChangedAt: Date(
                                    timeIntervalSince1970: sqlite3_column_double(stmt, 11)),
                                lastChangedAt: Date(
                                    timeIntervalSince1970: sqlite3_column_double(stmt, 12))
                            )
                        )
                    }
                }
            )
        } catch {
            print("[ChatHistoryDatabase] loadSandboxChanges failed: \(error)")
        }
        return changes
    }

    /// Session ids that still have legacy net-change rows (import source).
    public func sandboxChangeSessionIds() -> [String] {
        var ids: [String] = []
        try? prepareAndExecute(
            "SELECT DISTINCT session_id FROM sandbox_changes",
            bind: { _ in },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    ids.append(String(cString: sqlite3_column_text(stmt, 0)))
                }
            }
        )
        return ids
    }

    // MARK: - Legacy file history

    /// Sessions with file history in this database. File history now lives in
    /// `FileHistoryDatabase`; these rows are read once to copy them over.
    func legacyFileChangeSessionIds() -> [String] {
        var ids: [String] = []
        try? prepareAndExecute(
            "SELECT DISTINCT session_id FROM file_change_sets",
            bind: { _ in },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    ids.append(String(cString: sqlite3_column_text(stmt, 0)))
                }
            }
        )
        return ids
    }

    func legacyFileChangeSets(sessionId: String) throws -> [FileChangeSet] {
        try FileHistoryDatabase.readSets(sessionId: sessionId) { sql, bind, process in
            try prepareAndExecute(sql, bind: bind, process: process)
        }
    }

    /// Whether any surviving turn still references blob `hash`. Runs on
    /// `queue`. A `LIKE` probe, because attachments live as JSON in a TEXT
    /// column; the hash is hex, so `LIKE` collisions are not a concern.
    private func isBlobReferencedOnQueue(_ hash: String) -> Bool {
        var found = false
        do {
            try transactionalQuery(
                "SELECT 1 FROM turns WHERE attachments LIKE ?1 LIMIT 1",
                bind: { stmt in
                    let pattern = "%\"hash\":\"\(hash)\"%"
                    Self.bindText(stmt, index: 1, value: pattern)
                },
                process: { stmt in
                    if sqlite3_step(stmt) == SQLITE_ROW { found = true }
                }
            )
        } catch {
            return true  // be conservative: never delete on error
        }
        return found
    }

    // MARK: - SQL constants

    private static let baseSessionSelectSQL = """
        SELECT id, title, created_at, updated_at, selected_model, agent_id,
               source, source_plugin_id, external_session_key, dispatch_task_id,
               archived, capabilities, folder_bookmark, folder_path, pinned,
               project_id, workspace_context, parked_workflow_runs, automation_kind,
               conversation_summary
        FROM sessions
        """

    private static let selectSessionSQL = baseSessionSelectSQL + " WHERE id = ?1"

    private static let selectTurnsSQL = """
        SELECT id, role, content, attachments, shared_artifacts,
               tool_calls, tool_call_id, tool_results, thinking,
               created_at, completed_at, generation_token_count, time_to_first_token,
               tool_call_durations, thinking_duration, router_billing, terminal_stop_reason,
               model_context_excluded, tool_call_logs, injected_context_prefix,
               generation_tokens_per_second, model_load_seconds, last_output_at, requested_at,
               reasoning_item_id, reasoning_encrypted, responses_output_items, anthropic_thinking_blocks,
               input_token_count, cached_input_token_count, turn_generation_controls
        FROM turns
        WHERE session_id = ?1
        ORDER BY seq ASC
        """

    // MARK: - Row decoding

    private static func readSession(_ stmt: OpaquePointer, turns: [ChatTurnData]) -> ChatSessionData {
        let idStr = String(cString: sqlite3_column_text(stmt, 0))
        let title = String(cString: sqlite3_column_text(stmt, 1))
        let created = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2))
        let updated = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))
        let model = sqlite3_column_text(stmt, 4).map { String(cString: $0) }
        let agentId = sqlite3_column_text(stmt, 5).map { String(cString: $0) }.flatMap { UUID(uuidString: $0) }
        let sourceRaw = String(cString: sqlite3_column_text(stmt, 6))
        let source = SessionSource(rawValue: sourceRaw) ?? .chat
        let pluginId = sqlite3_column_text(stmt, 7).map { String(cString: $0) }
        let externalKey = sqlite3_column_text(stmt, 8).map { String(cString: $0) }
        let dispatchId = sqlite3_column_text(stmt, 9).map { String(cString: $0) }.flatMap { UUID(uuidString: $0) }
        let archived = sqlite3_column_int(stmt, 10) != 0
        let capabilitiesRaw = sqlite3_column_text(stmt, 11).map { String(cString: $0) } ?? ""
        let folderBookmark: Data? = sqlite3_column_blob(stmt, 12).map { base in
            Data(bytes: base, count: Int(sqlite3_column_bytes(stmt, 12)))
        }
        let folderPath = sqlite3_column_text(stmt, 13).map { String(cString: $0) }
        let pinned = sqlite3_column_int(stmt, 14) != 0
        let projectId = sqlite3_column_text(stmt, 15).map { String(cString: $0) }.flatMap { UUID(uuidString: $0) }
        let workspace = WorkspaceSessionContext.decode(
            json: sqlite3_column_text(stmt, 16).map { String(cString: $0) })
        let parked = ParkedWorkflowCall.decode(json: sqlite3_column_text(stmt, 17).map { String(cString: $0) })
        let automationKind = sqlite3_column_text(stmt, 18).map { String(cString: $0) }
            .flatMap(EventSourceKind.init(rawValue:))
        let summary: ConversationSummary? = sqlite3_column_text(stmt, 19)
            .map { String(cString: $0) }
            .flatMap(decodeJSON)
        return ChatSessionData(
            id: UUID(uuidString: idStr) ?? UUID(),
            title: title,
            createdAt: created,
            updatedAt: updated,
            selectedModel: model,
            turns: turns,
            agentId: agentId,
            source: source,
            automationKind: automationKind,
            sourcePluginId: pluginId,
            externalSessionKey: externalKey,
            dispatchTaskId: dispatchId,
            archived: archived,
            pinned: pinned,
            capabilities: SessionCapability.decode(capabilitiesRaw),
            folderBookmark: folderBookmark,
            folderPath: folderPath,
            conversationSummary: summary,
            projectId: projectId,
            workspace: workspace,
            parkedWorkflowRuns: parked
        )
    }

    private static func readTurn(_ stmt: OpaquePointer) -> ChatTurnData? {
        let idStr = String(cString: sqlite3_column_text(stmt, 0))
        let roleStr = String(cString: sqlite3_column_text(stmt, 1))
        guard let role = MessageRole(rawValue: roleStr) else { return nil }
        var content = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
        let attachments: [Attachment] =
            sqlite3_column_text(stmt, 3)
            .map { String(cString: $0) }
            .flatMap(decodeJSON) ?? []
        let sharedArtifacts: [SharedArtifact] =
            sqlite3_column_text(stmt, 4)
            .map { String(cString: $0) }
            .flatMap(decodeJSON) ?? []
        let toolCalls: [ToolCall]? = sqlite3_column_text(stmt, 5)
            .map { String(cString: $0) }
            .flatMap(decodeJSON)
        let toolCallId = sqlite3_column_text(stmt, 6).map { String(cString: $0) }
        let toolResults: [String: String] =
            sqlite3_column_text(stmt, 7)
            .map { String(cString: $0) }
            .flatMap(decodeJSON) ?? [:]
        let thinking = String(cString: sqlite3_column_text(stmt, 8))
        let createdAt = readNullableDate(stmt, index: 9)
        let completedAt = readNullableDate(stmt, index: 10)
        let tokenCount = readNullableInt(stmt, index: 11)
        let timeToFirstToken = readNullableDouble(stmt, index: 12)
        let toolCallDurations: [String: TimeInterval] =
            sqlite3_column_text(stmt, 13)
            .map { String(cString: $0) }
            .flatMap(decodeJSON) ?? [:]
        let thinkingDuration = readNullableDouble(stmt, index: 14)
        let routerBilling: RouterBillingSummary? = sqlite3_column_text(stmt, 15)
            .map { String(cString: $0) }
            .flatMap(decodeJSON)
        let terminalStopReason = sqlite3_column_text(stmt, 16).map { String(cString: $0) }
        let modelContextExcluded = sqlite3_column_int(stmt, 17) != 0
        let toolCallLogs: [String: SubagentRunLog] =
            sqlite3_column_text(stmt, 18)
            .map { String(cString: $0) }
            .flatMap(decodeJSON) ?? [:]
        var injectedContextPrefix = sqlite3_column_text(stmt, 19).map { String(cString: $0) }
        // Turns a paired phone added before the writer split them were stored
        // with the memory and time blocks inside the text.
        if role == .user, injectedContextPrefix == nil,
            let injected = InjectedContextSpans.splittingLeadingBlocks(content)
        {
            content = injected.rest
            injectedContextPrefix = injected.prefix
        }
        var turn = ChatTurnData(
            id: UUID(uuidString: idStr) ?? UUID(),
            role: role,
            content: content,
            attachments: attachments,
            sharedArtifacts: sharedArtifacts,
            toolCalls: toolCalls,
            toolCallId: toolCallId,
            toolResults: toolResults,
            toolCallDurations: toolCallDurations,
            thinkingDuration: thinkingDuration,
            thinking: thinking,
            createdAt: createdAt,
            completedAt: completedAt,
            lastOutputAt: readNullableDate(stmt, index: 22),
            generationTokenCount: tokenCount,
            timeToFirstToken: timeToFirstToken,
            generationTokensPerSecond: readNullableDouble(stmt, index: 20),
            modelLoadSeconds: readNullableDouble(stmt, index: 21),
            requestedAt: readNullableDate(stmt, index: 23),
            terminalStopReason: terminalStopReason,
            reasoningItemId: sqlite3_column_text(stmt, 24).map { String(cString: $0) },
            reasoningEncrypted: sqlite3_column_text(stmt, 25).map { String(cString: $0) },
            responsesOutputItems: sqlite3_column_text(stmt, 26).map { String(cString: $0) }.flatMap(decodeJSON) ?? [],
            inputTokenCount: readNullableInt(stmt, index: 28),
            cachedInputTokenCount: readNullableInt(stmt, index: 29),
            modelContextExcluded: modelContextExcluded,
            routerBilling: routerBilling,
            injectedContextPrefix: injectedContextPrefix,
            toolCallLogs: toolCallLogs
        )
        turn.generationControls = sqlite3_column_text(stmt, 30)
            .map { String(cString: $0) }.flatMap(decodeJSON)
        turn.anthropicThinkingBlocks = sqlite3_column_text(stmt, 27)
            .map { String(cString: $0) }.flatMap(decodeJSON) ?? []
        return turn
    }

    private static func readNullableDate(_ stmt: OpaquePointer, index: Int32) -> Date? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(stmt, index))
    }

    private static func readNullableDouble(_ stmt: OpaquePointer, index: Int32) -> Double? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(stmt, index)
    }

    private static func readNullableInt(_ stmt: OpaquePointer, index: Int32) -> Int? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int64(stmt, index))
    }

    // MARK: - JSON helpers

    private static func decodeJSON<T: Decodable>(_ json: String) -> T? {
        guard let data = json.data(using: .utf8) else {
            PersistenceHealth.shared.recordChatDecodeFailure("\(T.self): non-UTF8 column")
            return nil
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            // A non-empty column that fails to decode is real corruption /
            // a schema mismatch — log + count it rather than returning nil
            // and pretending the field was empty.
            PersistenceHealth.shared.recordChatDecodeFailure("\(T.self): \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - SQLite helpers (mirrors MemoryDatabase)

    private static let SQLITE_TRANSIENT = unsafeBitCast(
        OpaquePointer(bitPattern: -1),
        to: sqlite3_destructor_type.self
    )

    static func bindBlob(_ stmt: OpaquePointer, index: Int, value: Data?) {
        if let value {
            _ = value.withUnsafeBytes { bytes in
                sqlite3_bind_blob(
                    stmt, Int32(index), bytes.baseAddress, Int32(value.count), SQLITE_TRANSIENT
                )
            }
        } else {
            sqlite3_bind_null(stmt, Int32(index))
        }
    }

    static func bindText(_ stmt: OpaquePointer, index: Int, value: String?) {
        if let value {
            // Bind with an explicit UTF-8 byte length instead of -1
            // (NUL-terminated). Document-extracted text (e.g. from a PDF) can
            // contain embedded NUL bytes; with -1 SQLite truncates the value
            // at the first NUL, silently dropping the rest of the content.
            // SQLITE_TRANSIENT makes SQLite copy the bytes during the call.
            sqlite3_bind_text(stmt, Int32(index), value, Int32(value.utf8.count), SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, Int32(index))
        }
    }

    #if DEBUG
        func executeForTesting(_ sql: String) throws {
            try queue.sync { try executeRaw(sql) }
        }
    #endif

    private func executeRaw(_ sql: String) throws {
        guard let connection = db else { throw ChatHistoryDatabaseError.notOpen }
        var errorMessage: UnsafeMutablePointer<Int8>?
        let result = sqlite3_exec(connection, sql, nil, nil, &errorMessage)
        if result != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? "Unknown error"
            sqlite3_free(errorMessage)
            throw ChatHistoryDatabaseError.failedToExecute(message)
        }
    }

    private func executeRaw(_ sql: String, handler: (OpaquePointer) throws -> Void) throws {
        guard let connection = db else { throw ChatHistoryDatabaseError.notOpen }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            throw ChatHistoryDatabaseError.failedToPrepare(String(cString: sqlite3_errmsg(connection)))
        }
        defer { sqlite3_finalize(s) }
        try handler(s)
    }

    private func prepareAndExecute(
        _ sql: String,
        bind: (OpaquePointer) -> Void,
        process: (OpaquePointer) throws -> Void
    ) throws {
        // Ledger entry (main thread only): a main-thread read parks behind
        // whatever already holds the serial queue (a large transaction, a
        // maintenance pass). A watchdog breach then attributes to
        // "chat-history-db.query" rather than a generic hang.
        try MainThreadOperationLedger.shared.withMainThreadOperation(
            subsystem: "chat-history-db", operation: "query"
        ) {
            try prepareAndExecuteOnQueue(sql, bind: bind, process: process)
        }
    }

    private func prepareAndExecuteOnQueue(
        _ sql: String,
        bind: (OpaquePointer) -> Void,
        process: (OpaquePointer) throws -> Void
    ) throws {
        try queue.sync {
            guard let connection = db else { throw ChatHistoryDatabaseError.notOpen }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(connection, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
                throw ChatHistoryDatabaseError.failedToPrepare(String(cString: sqlite3_errmsg(connection)))
            }
            defer { sqlite3_finalize(s) }
            bind(s)
            try process(s)
        }
    }

    private func executeUpdate(_ sql: String, bind: (OpaquePointer) -> Void) throws -> Bool {
        var success = false
        try prepareAndExecute(sql, bind: bind) { stmt in
            success = sqlite3_step(stmt) == SQLITE_DONE
        }
        return success
    }

    /// Prepare/bind/step/finalize inside an already-open transaction.
    private func transactionalStep(_ sql: String, bind: (OpaquePointer) -> Void) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            throw ChatHistoryDatabaseError.failedToPrepare(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(s) }
        bind(s)
        guard sqlite3_step(s) == SQLITE_DONE else {
            throw ChatHistoryDatabaseError.failedToExecute("step failed: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    /// Prepare/bind/process/finalize inside an already-open transaction (queries).
    private func transactionalQuery(
        _ sql: String,
        bind: (OpaquePointer) -> Void,
        process: (OpaquePointer) throws -> Void
    ) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            throw ChatHistoryDatabaseError.failedToPrepare(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(s) }
        bind(s)
        try process(s)
    }

    // MARK: - Test hooks

    #if DEBUG
        /// Test-only: run `body` on the database's serial queue with
        /// the connection handle. Used by storage tests to inspect
        /// internal columns (e.g. `content_hash`) without exposing
        /// every read path through a public API.
        func queueRunForTest(_ body: (OpaquePointer) throws -> Void) throws {
            try queue.sync {
                guard let connection = db else { throw ChatHistoryDatabaseError.notOpen }
                try body(connection)
            }
        }
    #endif
}
