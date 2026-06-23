//
//  MemoryDatabase.swift
//  osaurus
//
//  SQLite database for the v2 memory system.
//  WAL mode, serial queue, versioned migrations.
//
//  Tables:
//    identity        — single row of stable user facts
//    pinned_facts    — promoted, salience-scored facts (replaces v1 memory_entries)
//    episodes        — per-session digests (replaces v1 conversation_summaries)
//    transcript      — raw conversation turns (renamed from v1 conversation_chunks)
//    pending_signals — buffered turns awaiting end-of-session distillation
//    processing_log  — distillation/consolidation latency + status
//
//  v5 migration carries forward identity, episodes, and transcript from
//  the old schema. The noisy v1 working-memory entries, profile events,
//  verification audit log, agent activity, embeddings cache, and graph
//  tables are all dropped — `pinned_facts` rebuilds organically from new
//  conversations and consolidator promotion.
//

import CryptoKit
import Foundation
import OsaurusSQLCipher

public enum MemoryDatabaseError: Error, LocalizedError {
    case failedToOpen(String)
    case failedToExecute(String)
    case failedToPrepare(String)
    case migrationFailed(String)
    case databaseFromNewerVersion(found: Int, expected: Int)
    case notOpen

    public var errorDescription: String? {
        switch self {
        case .failedToOpen(let msg): return "Failed to open memory database: \(msg)"
        case .failedToExecute(let msg): return "Failed to execute query: \(msg)"
        case .failedToPrepare(let msg): return "Failed to prepare statement: \(msg)"
        case .migrationFailed(let msg): return "Memory migration failed: \(msg)"
        case .databaseFromNewerVersion(let found, let expected):
            return
                "Memory database is schema v\(found) but this build supports up to v\(expected). Refusing to open to avoid forward-version corruption."
        case .notOpen: return "Memory database is not open"
        }
    }
}

public final class MemoryDatabase: @unchecked Sendable {
    public static let shared = MemoryDatabase()

    private static let schemaVersion = 10

    nonisolated(unsafe) private static let iso8601Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        return f
    }()

    private static func iso8601Now() -> String {
        iso8601Formatter.string(from: Date())
    }

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "ai.osaurus.memory.database")

    private let stmtCache = PreparedStatementCache(capacity: 96)

    /// Why the most recent `open()` failed (connection or migration),
    /// kept for the diagnostics panel — `isOpen == false` alone gives the
    /// user nothing actionable. Guarded by `queue`.
    private var _lastOpenError: String?

    public var isOpen: Bool {
        queue.sync { db != nil }
    }

    public var lastOpenErrorDescription: String? {
        queue.sync { _lastOpenError }
    }

    /// Schema version this build expects (`PRAGMA user_version` once all
    /// migrations have run). Surfaced by diagnostics.
    public static var expectedSchemaVersion: Int { latestSchemaVersion }

    /// Current `PRAGMA user_version` of the open database, or nil when
    /// closed. Surfaced by diagnostics.
    public func schemaUserVersion() -> Int? {
        queue.sync {
            guard db != nil else { return nil }
            return try? getSchemaVersion()
        }
    }

    public static func waitForSharedOpen(
        timeoutSeconds: TimeInterval,
        pollInterval: TimeInterval = 0.1
    ) async -> Bool {
        if shared.isOpen { return true }

        let deadline = Date().addingTimeInterval(max(0, timeoutSeconds))
        while Date() < deadline {
            let nanos = UInt64(max(0.01, pollInterval) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
            if shared.isOpen { return true }
        }

        return shared.isOpen
    }

    init() {}

    deinit { close() }

    // MARK: - Lifecycle

    public func open() throws {
        // See `ChatHistoryDatabase.open()` for the gate rationale —
        // every `*Database.open()` parks while a key rotation is in
        // flight so we can't open a half-rekeyed file.
        StorageMutationGate.blockingAwaitNotMutating()
        try queue.sync {
            guard db == nil else { return }
            OsaurusPaths.ensureExistsSilent(OsaurusPaths.memory())
            do {
                try openConnection()
            } catch {
                _lastOpenError = error.localizedDescription
                throw error
            }
            do {
                try runMigrations()
                _lastOpenError = nil
            } catch {
                // Close the half-opened connection before rethrowing.
                // Leaving `db` set here turns every retry of `open()` into
                // an instant no-op success (`guard db == nil`), so the app
                // would run against the unmigrated schema and the migration
                // failure would never surface anywhere.
                _lastOpenError = "migration: \(error.localizedDescription)"
                stmtCache.clear()
                if let connection = db {
                    sqlite3_close(connection)
                    db = nil
                }
                throw error
            }
        }
        OsaurusDatabaseHandle.register(maintenanceHandle)
    }

    private lazy var maintenanceHandle = OsaurusDatabaseHandle(
        name: "memory",
        exec: { [weak self] sql in
            self?.queue.sync {
                guard self?.db != nil else { return }
                try? self?.executeRaw(sql)
            }
        },
        closer: { [weak self] in self?.close() },
        reopener: { [weak self] in try? self?.open() }
    )

    /// Open an in-memory database for testing. **Plaintext** — see
    /// `SQLCipherIntegrationTests` for encrypted-DB coverage.
    public func openInMemory() throws {
        try queue.sync {
            guard db == nil else { return }
            db = try EncryptedSQLiteOpener.open(
                path: ":memory:",
                key: nil,
                applyPerfPragmas: false
            )
            try runMigrations()
        }
    }

    public func close() {
        OsaurusDatabaseHandle.deregister(name: "memory")
        queue.sync {
            stmtCache.clear()
            guard let connection = db else { return }
            try? executeRaw("PRAGMA optimize")
            sqlite3_close(connection)
            db = nil
        }
    }

    private func openConnection() throws {
        let path = OsaurusPaths.memoryDatabaseFile().path
        do {
            db = try OsaurusStorageOpener.open(path: path)
        } catch let error as EncryptedSQLiteError {
            throw MemoryDatabaseError.failedToOpen(error.localizedDescription)
        }
    }

    // MARK: - Schema & Migrations

    /// Highest schema version this build knows how to produce. Opening a DB
    /// stamped newer than this is refused (forward-version fail-fast).
    private static let latestSchemaVersion = 10

    private func runMigrations() throws {
        let currentVersion = try getSchemaVersion()
        // Refuse a database written by a newer build: reading its rows under
        // the older schema would silently corrupt forward-version data.
        if currentVersion > Self.latestSchemaVersion {
            throw MemoryDatabaseError.databaseFromNewerVersion(
                found: currentVersion,
                expected: Self.latestSchemaVersion
            )
        }
        // Each step is atomic (BEGIN/COMMIT). A failure mid-migration rolls
        // back to the prior version instead of leaving a half-applied schema;
        // the `setSchemaVersion` bump commits with the step.
        if currentVersion < 5 {
            try runMigrationStep(5) { try self.migrateToV5(from: currentVersion) }
        }
        if currentVersion < 6 {
            try runMigrationStep(6, migrateToV6)
        }
        if currentVersion < 7 {
            // `migrateToV7` owns its own BEGIN/COMMIT (table rebuild), so it
            // must NOT be double-wrapped — a nested BEGIN traps SQLite.
            try migrateToV7()
        }
        if currentVersion < 8 {
            // Same self-managed BEGIN/COMMIT as v7 — do not double-wrap.
            try migrateToV8()
        }
        if currentVersion < 9 {
            // Same self-managed BEGIN/COMMIT as v7/v8 — do not double-wrap.
            try migrateToV9()
        }
        if currentVersion < 10 {
            // Single `ALTER TABLE ... ADD COLUMN`; no rebuild/rename, so it
            // owns its own (trivial) statement and stamps the version itself.
            try migrateToV10()
        }
    }

    /// Run one migration body atomically. Called only from `runMigrations`,
    /// which already holds the database queue, so it uses raw
    /// `BEGIN/COMMIT/ROLLBACK` (no nested `queue.sync`).
    private func runMigrationStep(_ version: Int, _ body: () throws -> Void) throws {
        try executeRaw("BEGIN TRANSACTION")
        do {
            try body()
            try executeRaw("COMMIT")
        } catch {
            try? executeRaw("ROLLBACK")
            throw MemoryDatabaseError.migrationFailed("v\(version): \(error.localizedDescription)")
        }
    }

    private func getSchemaVersion() throws -> Int {
        var version: Int = 0
        try executeRaw("PRAGMA user_version") { stmt in
            if sqlite3_step(stmt) == SQLITE_ROW {
                version = Int(sqlite3_column_int(stmt, 0))
            }
        }
        return version
    }

    private func setSchemaVersion(_ version: Int) throws {
        try executeRaw("PRAGMA user_version = \(version)")
    }

    /// V5 migration: rebuild around the v2 schema. Carries forward
    /// `user_profile` → `identity.content`, `user_edits` → `identity.overrides`,
    /// `conversation_summaries` → `episodes`, and `conversation_chunks` → `transcript`.
    /// Drops `memory_entries`, `profile_events`, `memory_events`, `agent_activity`,
    /// `embeddings`, and the graph tables (`entities` / `relationships`).
    private func migrateToV5(from previousVersion: Int) throws {
        MemoryLogger.database.info("Running v5 migration (previous version: \(previousVersion))")

        // Connections open with foreign_keys = ON, so the DROP TABLE sweep below
        // would implicitly delete rows from each old table as it is dropped and
        // fail with "FOREIGN KEY constraint failed" whenever a not-yet-dropped
        // child still references a parent being dropped. Defer FK checks to the
        // commit of this migration: unlike foreign_keys, defer_foreign_keys is
        // settable inside a transaction and resets when it commits. By then every
        // old table is gone and the v5 tables declare no FKs, so nothing is left
        // to violate. Without this, v5 rolls back on affected installs and the
        // whole migration chain (v6-v9) never runs.
        try executeRaw("PRAGMA defer_foreign_keys = ON")

        // Create v2 tables first so we can copy into them within the same migration.
        try createV5Tables()

        // Carry-over from v1-v4 if those tables exist.
        if previousVersion >= 1 {
            try carryOverIdentityFromV1()
            try carryOverEpisodesFromV1()
            try carryOverTranscriptFromV1()
        }

        // Drop everything we don't need anymore.
        if previousVersion >= 1 {
            for table in [
                "memory_entries",
                "memory_events",
                "profile_events",
                "user_profile",
                "user_edits",
                "conversation_summaries",
                "conversation_chunks",
                "conversations",
                "agent_activity",
                "embeddings",
                "entities",
                "relationships",
                "schema_version",
            ] {
                try executeRaw("DROP TABLE IF EXISTS \(table)")
            }
        }

        try setSchemaVersion(5)
        MemoryLogger.database.info("v5 migration completed")
    }

    /// V6 migration: add three FTS5 contentless-mirror virtual tables
    /// + sync triggers so the LIKE-fallback search paths can use
    /// `MATCH` instead of full-table-scan `LIKE '%foo%'`.
    ///
    /// SQLCipher transparently encrypts the FTS5 shadow tables — we
    /// don't have to do anything extra for at-rest protection. The
    /// virtual tables use `content=…` external-content mode so the
    /// authoritative text still lives in the existing tables; FTS5
    /// only stores tokens.
    ///
    /// Backfill is done in one INSERT … SELECT after the triggers are
    /// in place so any concurrent insert doesn't race with the
    /// migration.
    private func migrateToV6() throws {
        MemoryLogger.database.info("Running v6 migration (FTS5 indexes)")

        // pinned_facts → fts_pinned (content column only)
        try executeRaw(
            """
            CREATE VIRTUAL TABLE IF NOT EXISTS fts_pinned USING fts5(
                content,
                content='pinned_facts',
                content_rowid='rowid',
                tokenize='unicode61 remove_diacritics 2'
            )
            """
        )
        try executeRaw(
            """
            CREATE TRIGGER IF NOT EXISTS pinned_facts_ai AFTER INSERT ON pinned_facts BEGIN
                INSERT INTO fts_pinned(rowid, content) VALUES (new.rowid, new.content);
            END
            """
        )
        try executeRaw(
            """
            CREATE TRIGGER IF NOT EXISTS pinned_facts_ad AFTER DELETE ON pinned_facts BEGIN
                INSERT INTO fts_pinned(fts_pinned, rowid, content) VALUES('delete', old.rowid, old.content);
            END
            """
        )
        try executeRaw(
            """
            CREATE TRIGGER IF NOT EXISTS pinned_facts_au AFTER UPDATE ON pinned_facts BEGIN
                INSERT INTO fts_pinned(fts_pinned, rowid, content) VALUES('delete', old.rowid, old.content);
                INSERT INTO fts_pinned(rowid, content) VALUES (new.rowid, new.content);
            END
            """
        )

        // episodes → fts_episodes (summary + topics + entities)
        try executeRaw(
            """
            CREATE VIRTUAL TABLE IF NOT EXISTS fts_episodes USING fts5(
                summary, topics_csv, entities_csv,
                content='episodes',
                content_rowid='id',
                tokenize='unicode61 remove_diacritics 2'
            )
            """
        )
        try executeRaw(
            """
            CREATE TRIGGER IF NOT EXISTS episodes_ai AFTER INSERT ON episodes BEGIN
                INSERT INTO fts_episodes(rowid, summary, topics_csv, entities_csv)
                VALUES (new.id, new.summary, new.topics_csv, new.entities_csv);
            END
            """
        )
        try executeRaw(
            """
            CREATE TRIGGER IF NOT EXISTS episodes_ad AFTER DELETE ON episodes BEGIN
                INSERT INTO fts_episodes(fts_episodes, rowid, summary, topics_csv, entities_csv)
                VALUES('delete', old.id, old.summary, old.topics_csv, old.entities_csv);
            END
            """
        )
        try executeRaw(
            """
            CREATE TRIGGER IF NOT EXISTS episodes_au AFTER UPDATE ON episodes BEGIN
                INSERT INTO fts_episodes(fts_episodes, rowid, summary, topics_csv, entities_csv)
                VALUES('delete', old.id, old.summary, old.topics_csv, old.entities_csv);
                INSERT INTO fts_episodes(rowid, summary, topics_csv, entities_csv)
                VALUES (new.id, new.summary, new.topics_csv, new.entities_csv);
            END
            """
        )

        // transcript → fts_transcript (content)
        try executeRaw(
            """
            CREATE VIRTUAL TABLE IF NOT EXISTS fts_transcript USING fts5(
                content,
                content='transcript',
                content_rowid='id',
                tokenize='unicode61 remove_diacritics 2'
            )
            """
        )
        try executeRaw(
            """
            CREATE TRIGGER IF NOT EXISTS transcript_ai AFTER INSERT ON transcript BEGIN
                INSERT INTO fts_transcript(rowid, content) VALUES (new.id, new.content);
            END
            """
        )
        try executeRaw(
            """
            CREATE TRIGGER IF NOT EXISTS transcript_ad AFTER DELETE ON transcript BEGIN
                INSERT INTO fts_transcript(fts_transcript, rowid, content) VALUES('delete', old.id, old.content);
            END
            """
        )
        try executeRaw(
            """
            CREATE TRIGGER IF NOT EXISTS transcript_au AFTER UPDATE ON transcript BEGIN
                INSERT INTO fts_transcript(fts_transcript, rowid, content) VALUES('delete', old.id, old.content);
                INSERT INTO fts_transcript(rowid, content) VALUES (new.id, new.content);
            END
            """
        )

        // Backfill (idempotent — INSERT into FTS is safe even if
        // triggers caught everything).
        try executeRaw(
            "INSERT INTO fts_pinned(rowid, content) SELECT rowid, content FROM pinned_facts"
        )
        try executeRaw(
            """
            INSERT INTO fts_episodes(rowid, summary, topics_csv, entities_csv)
            SELECT id, summary, topics_csv, entities_csv FROM episodes
            """
        )
        try executeRaw(
            "INSERT INTO fts_transcript(rowid, content) SELECT id, content FROM transcript"
        )

        try setSchemaVersion(6)
        MemoryLogger.database.info("v6 migration completed (FTS5 ready)")
    }

    /// V7 migration: drop the orphan `pending_signals.signal_type` column.
    ///
    /// Some pre-shipping versions of the v5 schema declared an extra
    /// `signal_type TEXT NOT NULL` column on `pending_signals` that was
    /// later removed from the source. Users whose database was created
    /// against that earlier schema kept the orphan column — and because
    /// the runtime `INSERT INTO pending_signals (...)` doesn't bind it,
    /// every buffer-turn write throws `SQLITE_CONSTRAINT_NOTNULL`
    /// (extended code 1299). The pre-fix version of `executeUpdate`
    /// silently swallowed the failure, so the bug was invisible until
    /// the diagnostics panel started surfacing the underlying SQLite
    /// error.
    ///
    /// Fix: rebuild the table with the canonical schema and copy the
    /// preserved columns over. Indexes are recreated by name. We
    /// intentionally drop the `signal_type` *values* — the runtime never
    /// reads them, and pending signals are short-lived (distilled within
    /// the debounce window or purged within `episodeRetentionDays`).
    /// Skipping the rebuild when the column is already absent makes the
    /// migration a fast no-op for fresh installs.
    private func migrateToV7() throws {
        MemoryLogger.database.info("Running v7 migration (drop orphan pending_signals.signal_type)")
        try dropOrphanSignalTypeColumnIfPresent()
        try setSchemaVersion(7)
    }

    /// V8 migration: re-run the orphan `signal_type` drop.
    ///
    /// `migrateToV7` is version-gated behind `currentVersion < 7`, so any
    /// database that was stamped `user_version = 7` *while still carrying*
    /// the orphan column (an intermediate pre-release build bumped the
    /// version without effectively dropping it) never got repaired — and
    /// because the runtime `INSERT INTO pending_signals` doesn't bind
    /// `signal_type`, every buffer-turn write throws
    /// `SQLITE_CONSTRAINT_NOTNULL` (extended code 1299), so no turn ever
    /// reaches the database and no episodes are ever produced. Re-running
    /// the same idempotent drop at v8 lets those stuck databases self-heal;
    /// it's a fast no-op for everyone already canonical.
    private func migrateToV8() throws {
        MemoryLogger.database.info("Running v8 migration (re-check orphan pending_signals.signal_type)")
        try dropOrphanSignalTypeColumnIfPresent()
        try setSchemaVersion(8)
    }

    /// V9 migration: re-run the orphan `signal_type` drop, now rename-free.
    ///
    /// The v7/v8 rebuild started with `ALTER TABLE ... RENAME`, which makes
    /// SQLite re-parse every view and trigger in the database — a single
    /// stale schema object left behind by an earlier build fails that
    /// statement, and with it the whole migration, on every launch.
    /// Combined with the old `open()` behavior (a failed migration left the
    /// connection set, so retries no-opped into "success"), affected
    /// installs kept running against the orphan schema with no visible
    /// error and their `user_version` never advanced. The rebuild in
    /// `dropOrphanSignalTypeColumnIfPresent` is now a copy-out/copy-back
    /// through a scratch table that only ever parses `pending_signals`
    /// itself, so unrelated schema debris can't block it. Re-running it at
    /// v9 heals databases whose earlier repair attempts kept failing; it's
    /// a fast no-op for everyone already canonical.
    private func migrateToV9() throws {
        MemoryLogger.database.info("Running v9 migration (rename-free orphan signal_type drop)")
        try dropOrphanSignalTypeColumnIfPresent()
        try setSchemaVersion(9)
    }

    /// V10 migration: add `pending_signals.attempts` to back the
    /// distillation retry cap + dead-letter (issue #1632). A session that
    /// never yields a parseable episode used to be retried on every launch,
    /// ingest, and debounce forever (the 108 error / 5 empty
    /// `processing_log` rows). The distiller now bumps `attempts` on each
    /// retryable failure and flips the rows to `status='dead_letter'` once
    /// they exceed `MemoryConfiguration.distillMaxAttempts`, dropping them
    /// out of `loadPendingSignals` / `pendingConversations`.
    ///
    /// Implemented as a guarded `ADD COLUMN` rather than the v7-v9
    /// copy-out/copy-back rebuild: `ADD COLUMN` does not RENAME the table,
    /// so it can't be tripped by unrelated stale views/triggers. The
    /// column-presence check keeps it idempotent for fresh installs (which
    /// already created the canonical table at v5) and for re-runs.
    private func migrateToV10() throws {
        MemoryLogger.database.info("Running v10 migration (pending_signals.attempts + dead-letter)")
        if !pendingSignalsHasColumn("attempts") {
            try executeRaw(
                "ALTER TABLE pending_signals ADD COLUMN attempts INTEGER NOT NULL DEFAULT 0"
            )
        }
        try setSchemaVersion(10)
    }

    /// Whether `pending_signals` currently has `column`. Cheap
    /// `PRAGMA table_info` scan; used by `migrateToV10` to stay idempotent.
    private func pendingSignalsHasColumn(_ column: String) -> Bool {
        var found = false
        try? executeRaw("PRAGMA table_info(pending_signals)") { stmt in
            while sqlite3_step(stmt) == SQLITE_ROW {
                if String(cString: sqlite3_column_text(stmt, 1)) == column {
                    found = true
                    break
                }
            }
        }
        return found
    }

    /// Detect and drop the orphan `pending_signals.signal_type` column if it
    /// is present, leaving the canonical schema behind. Idempotent: a no-op
    /// when the column is already absent. Does **not** stamp the schema
    /// version — the calling migration owns that.
    private func dropOrphanSignalTypeColumnIfPresent() throws {
        var hasOrphan = false
        try executeRaw("PRAGMA table_info(pending_signals)") { stmt in
            while sqlite3_step(stmt) == SQLITE_ROW {
                let name = String(cString: sqlite3_column_text(stmt, 1))
                if name == "signal_type" {
                    hasOrphan = true
                    break
                }
            }
        }

        guard hasOrphan else {
            MemoryLogger.database.info("pending_signals already canonical, no orphan column to drop")
            return
        }

        // Rebuild without `ALTER TABLE`: a RENAME makes SQLite re-parse
        // every view and trigger in the database, so a single stale schema
        // object from an earlier build fails the rebuild outright. A
        // copy-out/copy-back through a scratch table only ever parses
        // `pending_signals` itself. Wrap in a transaction so a crash
        // mid-flight doesn't leave a half-rebuilt table.
        try executeRaw("BEGIN TRANSACTION")
        do {
            // Scratch tables an interrupted earlier rebuild may have left
            // behind; they only ever hold a stale duplicate of
            // `pending_signals`, never the sole copy.
            try executeRaw("DROP TABLE IF EXISTS pending_signals_v6")
            try executeRaw("DROP TABLE IF EXISTS pending_signals_old")
            try executeRaw("DROP TABLE IF EXISTS pending_signals_scratch")
            try executeRaw(
                """
                    CREATE TABLE pending_signals_scratch AS
                    SELECT id, agent_id, conversation_id, user_message,
                           assistant_message, status, created_at
                    FROM pending_signals
                """
            )
            try executeRaw("DROP TABLE pending_signals")
            try executeRaw(
                """
                    CREATE TABLE pending_signals (
                        id                INTEGER PRIMARY KEY AUTOINCREMENT,
                        agent_id          TEXT NOT NULL,
                        conversation_id   TEXT NOT NULL,
                        user_message      TEXT NOT NULL,
                        assistant_message TEXT,
                        status            TEXT NOT NULL DEFAULT 'pending',
                        created_at        TEXT NOT NULL DEFAULT (datetime('now'))
                    )
                """
            )
            try executeRaw(
                """
                    INSERT INTO pending_signals
                        (id, agent_id, conversation_id, user_message, assistant_message, status, created_at)
                    SELECT
                        id, agent_id, conversation_id, user_message, assistant_message, status, created_at
                    FROM pending_signals_scratch
                """
            )
            try executeRaw("DROP TABLE pending_signals_scratch")
            // The indexes were dropped with the original table; recreate
            // against the rebuilt one.
            try executeRaw(
                "CREATE INDEX IF NOT EXISTS idx_pending_conv_status ON pending_signals(conversation_id, status)"
            )
            try executeRaw(
                "CREATE INDEX IF NOT EXISTS idx_pending_agent_status ON pending_signals(agent_id, status)"
            )
            try executeRaw("COMMIT")
        } catch {
            try? executeRaw("ROLLBACK")
            throw error
        }

        MemoryLogger.database.info("rebuilt pending_signals without orphan signal_type column")
    }

    private func createV5Tables() throws {
        try executeRaw(
            """
                CREATE TABLE IF NOT EXISTS identity (
                    id            INTEGER PRIMARY KEY CHECK (id = 1),
                    content       TEXT NOT NULL DEFAULT '',
                    overrides     TEXT NOT NULL DEFAULT '[]',
                    token_count   INTEGER NOT NULL DEFAULT 0,
                    version       INTEGER NOT NULL DEFAULT 0,
                    model         TEXT NOT NULL DEFAULT '',
                    generated_at  TEXT NOT NULL DEFAULT ''
                )
            """
        )

        try executeRaw(
            """
                CREATE TABLE IF NOT EXISTS pinned_facts (
                    id                  TEXT PRIMARY KEY,
                    agent_id            TEXT NOT NULL,
                    content             TEXT NOT NULL,
                    salience            REAL NOT NULL DEFAULT 0.5,
                    source_count        INTEGER NOT NULL DEFAULT 1,
                    source_episode_id   INTEGER,
                    last_used           TEXT NOT NULL DEFAULT (datetime('now')),
                    use_count           INTEGER NOT NULL DEFAULT 0,
                    status              TEXT NOT NULL DEFAULT 'active',
                    created_at          TEXT NOT NULL DEFAULT (datetime('now')),
                    tags_csv            TEXT
                )
            """
        )
        try executeRaw(
            "CREATE INDEX IF NOT EXISTS idx_pinned_agent_status ON pinned_facts(agent_id, status, salience DESC)"
        )

        try executeRaw(
            """
                CREATE TABLE IF NOT EXISTS episodes (
                    id                INTEGER PRIMARY KEY AUTOINCREMENT,
                    agent_id          TEXT NOT NULL,
                    conversation_id   TEXT NOT NULL,
                    summary           TEXT NOT NULL,
                    topics_csv        TEXT NOT NULL DEFAULT '',
                    entities_csv      TEXT NOT NULL DEFAULT '',
                    decisions         TEXT NOT NULL DEFAULT '',
                    action_items      TEXT NOT NULL DEFAULT '',
                    salience          REAL NOT NULL DEFAULT 0.5,
                    token_count       INTEGER NOT NULL DEFAULT 0,
                    model             TEXT NOT NULL DEFAULT '',
                    conversation_at   TEXT NOT NULL,
                    status            TEXT NOT NULL DEFAULT 'active',
                    created_at        TEXT NOT NULL DEFAULT (datetime('now'))
                )
            """
        )
        try executeRaw(
            "CREATE INDEX IF NOT EXISTS idx_episodes_agent_at ON episodes(agent_id, status, conversation_at DESC)"
        )

        try executeRaw(
            """
                CREATE TABLE IF NOT EXISTS transcript (
                    id                INTEGER PRIMARY KEY AUTOINCREMENT,
                    agent_id          TEXT NOT NULL,
                    conversation_id   TEXT NOT NULL,
                    chunk_index       INTEGER NOT NULL,
                    role              TEXT NOT NULL,
                    content           TEXT NOT NULL,
                    token_count       INTEGER NOT NULL,
                    title             TEXT,
                    created_at        TEXT NOT NULL DEFAULT (datetime('now'))
                )
            """
        )
        try executeRaw(
            "CREATE INDEX IF NOT EXISTS idx_transcript_conv ON transcript(conversation_id, chunk_index)"
        )
        try executeRaw(
            "CREATE INDEX IF NOT EXISTS idx_transcript_agent_created ON transcript(agent_id, created_at DESC)"
        )

        try executeRaw(
            """
                CREATE TABLE IF NOT EXISTS pending_signals (
                    id                INTEGER PRIMARY KEY AUTOINCREMENT,
                    agent_id          TEXT NOT NULL,
                    conversation_id   TEXT NOT NULL,
                    user_message      TEXT NOT NULL,
                    assistant_message TEXT,
                    status            TEXT NOT NULL DEFAULT 'pending',
                    created_at        TEXT NOT NULL DEFAULT (datetime('now'))
                )
            """
        )
        try executeRaw(
            "CREATE INDEX IF NOT EXISTS idx_pending_conv_status ON pending_signals(conversation_id, status)"
        )
        try executeRaw(
            "CREATE INDEX IF NOT EXISTS idx_pending_agent_status ON pending_signals(agent_id, status)"
        )

        try executeRaw(
            """
                CREATE TABLE IF NOT EXISTS processing_log (
                    id              INTEGER PRIMARY KEY AUTOINCREMENT,
                    agent_id        TEXT NOT NULL,
                    task_type       TEXT NOT NULL,
                    model           TEXT,
                    status          TEXT NOT NULL,
                    details         TEXT,
                    input_tokens    INTEGER,
                    output_tokens   INTEGER,
                    duration_ms     INTEGER,
                    created_at      TEXT NOT NULL DEFAULT (datetime('now'))
                )
            """
        )
        try executeRaw("CREATE INDEX IF NOT EXISTS idx_processing_log_created ON processing_log(created_at)")
    }

    private func carryOverIdentityFromV1() throws {
        guard try tableExists("user_profile") else { return }

        var content = ""
        var version = 0
        var generatedAt = ""
        var model = ""
        try executeRaw(
            "SELECT content, version, model, generated_at FROM user_profile WHERE id = 1"
        ) { stmt in
            if sqlite3_step(stmt) == SQLITE_ROW {
                content = String(cString: sqlite3_column_text(stmt, 0))
                version = Int(sqlite3_column_int(stmt, 1))
                model = String(cString: sqlite3_column_text(stmt, 2))
                generatedAt = String(cString: sqlite3_column_text(stmt, 3))
            }
        }

        var overrides: [String] = []
        if try tableExists("user_edits") {
            try executeRaw(
                "SELECT content FROM user_edits WHERE deleted_at IS NULL ORDER BY created_at"
            ) { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    overrides.append(String(cString: sqlite3_column_text(stmt, 0)))
                }
            }
        }

        // Skip if both are empty — leave the row uninitialized so the
        // Identity sheet shows a clean "no profile yet" state.
        guard !content.isEmpty || !overrides.isEmpty else { return }

        let overridesJSON =
            (try? JSONEncoder().encode(overrides)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let tokenCount = max(0, content.count / MemoryConfiguration.charsPerToken)

        try executeRaw("DELETE FROM identity WHERE id = 1")
        try insertRow(
            """
            INSERT INTO identity (id, content, overrides, token_count, version, model, generated_at)
            VALUES (1, ?1, ?2, ?3, ?4, ?5, ?6)
            """
        ) { stmt in
            Self.bindText(stmt, index: 1, value: content)
            Self.bindText(stmt, index: 2, value: overridesJSON)
            sqlite3_bind_int(stmt, 3, Int32(tokenCount))
            sqlite3_bind_int(stmt, 4, Int32(version))
            Self.bindText(stmt, index: 5, value: model.isEmpty ? "v1-import" : model)
            Self.bindText(
                stmt,
                index: 6,
                value: generatedAt.isEmpty ? Self.iso8601Now() : generatedAt
            )
        }

        MemoryLogger.database.info(
            "v5 migration: carried over identity (v\(version), \(overrides.count) overrides)"
        )
    }

    private func carryOverEpisodesFromV1() throws {
        guard try tableExists("conversation_summaries") else { return }

        var copied = 0
        try executeRaw(
            """
            SELECT agent_id, conversation_id, summary, token_count, model, conversation_at, status, created_at
            FROM conversation_summaries
            """
        ) { stmt in
            while sqlite3_step(stmt) == SQLITE_ROW {
                let agentId = String(cString: sqlite3_column_text(stmt, 0))
                let conversationId = String(cString: sqlite3_column_text(stmt, 1))
                let summary = String(cString: sqlite3_column_text(stmt, 2))
                let tokenCount = Int(sqlite3_column_int(stmt, 3))
                let model = String(cString: sqlite3_column_text(stmt, 4))
                let conversationAt = String(cString: sqlite3_column_text(stmt, 5))
                let status = String(cString: sqlite3_column_text(stmt, 6))
                let createdAt = String(cString: sqlite3_column_text(stmt, 7))

                do {
                    try insertRow(
                        """
                        INSERT INTO episodes
                            (agent_id, conversation_id, summary, token_count, model,
                             conversation_at, status, created_at, salience)
                        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, 0.5)
                        """
                    ) { ins in
                        Self.bindText(ins, index: 1, value: agentId)
                        Self.bindText(ins, index: 2, value: conversationId)
                        Self.bindText(ins, index: 3, value: summary)
                        sqlite3_bind_int(ins, 4, Int32(tokenCount))
                        Self.bindText(ins, index: 5, value: model)
                        Self.bindText(ins, index: 6, value: conversationAt)
                        Self.bindText(ins, index: 7, value: status)
                        Self.bindText(ins, index: 8, value: createdAt)
                    }
                    copied += 1
                } catch {
                    MemoryLogger.database.warning("v5 migration: failed to carry over summary: \(error)")
                }
            }
        }

        if copied > 0 {
            MemoryLogger.database.info("v5 migration: carried over \(copied) episodes from conversation_summaries")
        }
    }

    private func carryOverTranscriptFromV1() throws {
        guard try tableExists("conversation_chunks"), try tableExists("conversations") else { return }

        var copied = 0
        try executeRaw(
            """
            SELECT cc.conversation_id, cc.chunk_index, cc.role, cc.content, cc.token_count, cc.created_at,
                   c.agent_id, c.title
            FROM conversation_chunks cc
            JOIN conversations c ON c.id = cc.conversation_id
            """
        ) { stmt in
            while sqlite3_step(stmt) == SQLITE_ROW {
                let conversationId = String(cString: sqlite3_column_text(stmt, 0))
                let chunkIndex = Int(sqlite3_column_int(stmt, 1))
                let role = String(cString: sqlite3_column_text(stmt, 2))
                let content = String(cString: sqlite3_column_text(stmt, 3))
                let tokenCount = Int(sqlite3_column_int(stmt, 4))
                let createdAt = String(cString: sqlite3_column_text(stmt, 5))
                let agentId = String(cString: sqlite3_column_text(stmt, 6))
                let title = sqlite3_column_text(stmt, 7).map { String(cString: $0) }

                do {
                    try insertRow(
                        """
                        INSERT INTO transcript
                            (agent_id, conversation_id, chunk_index, role, content,
                             token_count, title, created_at)
                        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
                        """
                    ) { ins in
                        Self.bindText(ins, index: 1, value: agentId)
                        Self.bindText(ins, index: 2, value: conversationId)
                        sqlite3_bind_int(ins, 3, Int32(chunkIndex))
                        Self.bindText(ins, index: 4, value: role)
                        Self.bindText(ins, index: 5, value: content)
                        sqlite3_bind_int(ins, 6, Int32(tokenCount))
                        Self.bindText(ins, index: 7, value: title)
                        Self.bindText(ins, index: 8, value: createdAt)
                    }
                    copied += 1
                } catch {
                    MemoryLogger.database.warning("v5 migration: failed to carry over chunk: \(error)")
                }
            }
        }

        if copied > 0 {
            MemoryLogger.database.info("v5 migration: carried over \(copied) transcript turns")
        }
    }

    private func tableExists(_ name: String) throws -> Bool {
        var found = false
        try executeRaw("SELECT name FROM sqlite_master WHERE type='table' AND name=?") { stmt in
            Self.bindText(stmt, index: 1, value: name)
            if sqlite3_step(stmt) == SQLITE_ROW {
                found = true
            }
        }
        return found
    }

    // MARK: - Query Execution

    private func executeRaw(_ sql: String) throws {
        guard let connection = db else { throw MemoryDatabaseError.notOpen }
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(connection, sql, nil, nil, &errorMessage)
        if result != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? "Unknown error"
            sqlite3_free(errorMessage)
            throw MemoryDatabaseError.failedToExecute(message)
        }
    }

    private func executeRaw(_ sql: String, handler: (OpaquePointer) throws -> Void) throws {
        guard let connection = db else { throw MemoryDatabaseError.notOpen }
        var stmt: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(connection, sql, -1, &stmt, nil)
        guard prepareResult == SQLITE_OK, let statement = stmt else {
            let message = String(cString: sqlite3_errmsg(connection))
            throw MemoryDatabaseError.failedToPrepare(message)
        }
        defer { sqlite3_finalize(statement) }
        try handler(statement)
    }

    /// Execute a non-row-returning insert/update with bindings (must be on `queue`).
    private func insertRow(_ sql: String, bind: (OpaquePointer) -> Void) throws {
        guard let connection = db else { throw MemoryDatabaseError.notOpen }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            throw MemoryDatabaseError.failedToPrepare(String(cString: sqlite3_errmsg(connection)))
        }
        defer { sqlite3_finalize(s) }
        bind(s)
        let step = sqlite3_step(s)
        guard step == SQLITE_DONE else {
            throw MemoryDatabaseError.failedToExecute(
                "INSERT step returned \(step): \(String(cString: sqlite3_errmsg(connection)))"
            )
        }
    }

    func execute<T>(_ operation: @escaping (OpaquePointer) throws -> T) throws -> T {
        try queue.sync {
            guard let connection = db else { throw MemoryDatabaseError.notOpen }
            return try operation(connection)
        }
    }

    /// Locking entry point. Acquires `queue.sync` and dispatches to
    /// the unlocked core. Use this from regular call sites that
    /// don't already hold the queue.
    ///
    /// MUST NOT be called from inside an `inTransaction { ... }`
    /// closure — that closure already runs on `queue`, and a
    /// nested `queue.sync` traps with `EXC_BREAKPOINT` (libdispatch
    /// re-entrant-sync deadlock detector). The runtime guard below
    /// surfaces the misuse at the *call site* instead of inside
    /// libdispatch where the stack is harder to read. Use
    /// `prepareAndExecute(on:_:bind:process:)` from inside a
    /// transaction.
    func prepareAndExecute(
        _ sql: String,
        bind: (OpaquePointer) -> Void,
        process: (OpaquePointer) throws -> Void
    ) throws {
        dispatchPrecondition(condition: .notOnQueue(queue))
        try queue.sync {
            guard let connection = db else { throw MemoryDatabaseError.notOpen }
            try Self.prepareAndExecute(
                on: connection,
                sql,
                bind: bind,
                process: process
            )
        }
    }

    /// Non-locking core. Caller MUST hold `queue` (i.e. be inside an
    /// `inTransaction { ... }` closure). Performs the
    /// prepare/bind/process/finalize dance against an already-open
    /// connection.
    static func prepareAndExecute(
        on connection: OpaquePointer,
        _ sql: String,
        bind: (OpaquePointer) -> Void,
        process: (OpaquePointer) throws -> Void
    ) throws {
        var stmt: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(connection, sql, -1, &stmt, nil)
        guard prepareResult == SQLITE_OK, let statement = stmt else {
            let message = String(cString: sqlite3_errmsg(connection))
            throw MemoryDatabaseError.failedToPrepare(message)
        }
        defer { sqlite3_finalize(statement) }
        bind(statement)
        try process(statement)
    }

    /// Locking entry point — see `prepareAndExecute(_:bind:process:)`
    /// for the re-entrancy contract.
    ///
    /// Throws `MemoryDatabaseError.failedToExecute(...)` when
    /// `sqlite3_step` returns anything other than `SQLITE_DONE`. The
    /// pre-fix behaviour was to silently swallow the error and return
    /// `false`, which combined with the universal `_ = try executeUpdate(...)`
    /// callsite pattern meant constraint violations / busy / readonly
    /// failures looked like silent successes — `bufferTurn`'s telemetry
    /// happily incremented `insertSuccesses` while no row ever landed
    /// in `pending_signals`. Always throw so the failure mode is
    /// visible at the call site (and via the diagnostics panel).
    @discardableResult
    func executeUpdate(_ sql: String, bind: (OpaquePointer) -> Void) throws -> Bool {
        try prepareAndExecute(
            sql,
            bind: bind,
            process: { stmt in
                let step = sqlite3_step(stmt)
                guard step == SQLITE_DONE else {
                    // `sqlite3_db_handle(stmt)` retrieves the live connection
                    // associated with this prepared statement so we can pull
                    // the extended error code + human-readable message even
                    // though the closure doesn't capture the connection by
                    // name. Critical: with just the primary code (e.g.
                    // SQLITE_CONSTRAINT/19) the user can't tell whether a
                    // NOT-NULL, UNIQUE, FK, or CHECK constraint tripped.
                    let connection = sqlite3_db_handle(stmt)
                    throw MemoryDatabaseError.failedToExecute(
                        Self.describeStepFailure(step: step, sql: sql, connection: connection)
                    )
                }
            }
        )
        return true
    }

    /// Non-locking core — call from inside `inTransaction { ... }`
    /// when you also need to issue updates against the same
    /// connection without taking the queue lock already.
    @discardableResult
    static func executeUpdate(
        on connection: OpaquePointer,
        _ sql: String,
        bind: (OpaquePointer) -> Void
    ) throws -> Bool {
        try prepareAndExecute(
            on: connection,
            sql,
            bind: bind,
            process: { stmt in
                let step = sqlite3_step(stmt)
                guard step == SQLITE_DONE else {
                    throw MemoryDatabaseError.failedToExecute(
                        describeStepFailure(step: step, sql: sql, connection: connection)
                    )
                }
            }
        )
        return true
    }

    /// Build a useful error string from the most recent SQLite step
    /// failure: the numeric step result, the extended error code, the
    /// human-readable error message, and a short SQL prefix so the log
    /// line points to the exact statement.
    private static func describeStepFailure(
        step: Int32,
        sql: String,
        connection: OpaquePointer? = nil
    ) -> String {
        let prefix = sql.split(separator: "\n").first.map(String.init) ?? sql
        let trimmed = prefix.trimmingCharacters(in: .whitespaces)
        let stepName = sqliteResultName(step)
        if let connection {
            let extended = sqlite3_extended_errcode(connection)
            let msg = String(cString: sqlite3_errmsg(connection))
            return
                "step=\(step)/\(stepName) extended=\(extended) msg=\(msg) sql=\(trimmed.prefix(120))"
        }
        return "step=\(step)/\(stepName) sql=\(trimmed.prefix(120))"
    }

    private func describeStepFailure(step: Int32, sql: String) -> String {
        guard let connection = db else {
            return Self.describeStepFailure(step: step, sql: sql)
        }
        return Self.describeStepFailure(step: step, sql: sql, connection: connection)
    }

    private static func sqliteResultName(_ code: Int32) -> String {
        switch code {
        case SQLITE_OK: return "SQLITE_OK"
        case SQLITE_DONE: return "SQLITE_DONE"
        case SQLITE_ROW: return "SQLITE_ROW"
        case SQLITE_BUSY: return "SQLITE_BUSY"
        case SQLITE_LOCKED: return "SQLITE_LOCKED"
        case SQLITE_READONLY: return "SQLITE_READONLY"
        case SQLITE_FULL: return "SQLITE_FULL"
        case SQLITE_CONSTRAINT: return "SQLITE_CONSTRAINT"
        case SQLITE_MISUSE: return "SQLITE_MISUSE"
        case SQLITE_CORRUPT: return "SQLITE_CORRUPT"
        case SQLITE_NOTADB: return "SQLITE_NOTADB"
        case SQLITE_IOERR: return "SQLITE_IOERR"
        case SQLITE_CANTOPEN: return "SQLITE_CANTOPEN"
        case SQLITE_ERROR: return "SQLITE_ERROR"
        case SQLITE_INTERNAL: return "SQLITE_INTERNAL"
        default: return "code_\(code)"
        }
    }

    func inTransaction<T>(_ operation: (OpaquePointer) throws -> T) throws -> T {
        dispatchPrecondition(condition: .notOnQueue(queue))
        return try queue.sync {
            guard let connection = db else { throw MemoryDatabaseError.notOpen }
            try executeRaw("BEGIN TRANSACTION")
            do {
                let result = try operation(connection)
                try executeRaw("COMMIT")
                return result
            } catch {
                try? executeRaw("ROLLBACK")
                throw error
            }
        }
    }

    // MARK: - Identity

    public func loadIdentity() throws -> Identity? {
        var identity: Identity?
        try prepareAndExecute(
            "SELECT content, overrides, token_count, version, model, generated_at FROM identity WHERE id = 1",
            bind: { _ in },
            process: { stmt in
                if sqlite3_step(stmt) == SQLITE_ROW {
                    let content = String(cString: sqlite3_column_text(stmt, 0))
                    let overridesJSON = String(cString: sqlite3_column_text(stmt, 1))
                    let overrides =
                        (overridesJSON.data(using: .utf8))
                        .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
                    identity = Identity(
                        content: content,
                        overrides: overrides,
                        tokenCount: Int(sqlite3_column_int(stmt, 2)),
                        version: Int(sqlite3_column_int(stmt, 3)),
                        model: String(cString: sqlite3_column_text(stmt, 4)),
                        generatedAt: String(cString: sqlite3_column_text(stmt, 5))
                    )
                }
            }
        )
        return identity
    }

    public func saveIdentity(_ identity: Identity) throws {
        let overridesJSON =
            (try? JSONEncoder().encode(identity.overrides)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        _ = try executeUpdate(
            """
            INSERT INTO identity (id, content, overrides, token_count, version, model, generated_at)
            VALUES (1, ?1, ?2, ?3, ?4, ?5, ?6)
            ON CONFLICT(id) DO UPDATE SET
                content = excluded.content,
                overrides = excluded.overrides,
                token_count = excluded.token_count,
                version = excluded.version,
                model = excluded.model,
                generated_at = excluded.generated_at
            """
        ) { stmt in
            Self.bindText(stmt, index: 1, value: identity.content)
            Self.bindText(stmt, index: 2, value: overridesJSON)
            sqlite3_bind_int(stmt, 3, Int32(identity.tokenCount))
            sqlite3_bind_int(stmt, 4, Int32(identity.version))
            Self.bindText(stmt, index: 5, value: identity.model)
            Self.bindText(stmt, index: 6, value: identity.generatedAt)
        }
    }

    public func setIdentityOverrides(_ overrides: [String]) throws {
        var current = try loadIdentity() ?? Identity()
        current.overrides = overrides
        try saveIdentity(current)
    }

    public func appendIdentityOverride(_ text: String) throws {
        var current = try loadIdentity() ?? Identity()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let lowered = trimmed.lowercased()
        guard !current.overrides.contains(where: { $0.lowercased() == lowered }) else { return }
        current.overrides.append(trimmed)
        try saveIdentity(current)
    }

    public func removeIdentityOverride(at index: Int) throws {
        var current = try loadIdentity() ?? Identity()
        guard index >= 0, index < current.overrides.count else { return }
        current.overrides.remove(at: index)
        try saveIdentity(current)
    }

    // MARK: - Pinned Facts

    public func insertPinnedFact(_ fact: PinnedFact) throws {
        _ = try executeUpdate(
            """
            INSERT INTO pinned_facts
                (id, agent_id, content, salience, source_count, source_episode_id,
                 last_used, use_count, status, created_at, tags_csv)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6,
                    COALESCE(NULLIF(?7, ''), datetime('now')),
                    ?8, ?9,
                    COALESCE(NULLIF(?10, ''), datetime('now')),
                    ?11)
            """
        ) { stmt in
            Self.bindText(stmt, index: 1, value: fact.id)
            Self.bindText(stmt, index: 2, value: fact.agentId)
            Self.bindText(stmt, index: 3, value: fact.content)
            sqlite3_bind_double(stmt, 4, fact.salience)
            sqlite3_bind_int(stmt, 5, Int32(fact.sourceCount))
            if let sid = fact.sourceEpisodeId {
                sqlite3_bind_int(stmt, 6, Int32(sid))
            } else {
                sqlite3_bind_null(stmt, 6)
            }
            Self.bindText(stmt, index: 7, value: fact.lastUsed)
            sqlite3_bind_int(stmt, 8, Int32(fact.useCount))
            Self.bindText(stmt, index: 9, value: fact.status)
            Self.bindText(stmt, index: 10, value: fact.createdAt)
            Self.bindText(stmt, index: 11, value: fact.tagsCSV)
        }
    }

    public func updatePinnedFactSalience(id: String, salience: Double) throws {
        _ = try executeUpdate(
            "UPDATE pinned_facts SET salience = ?1 WHERE id = ?2"
        ) { stmt in
            sqlite3_bind_double(stmt, 1, max(0, min(1, salience)))
            Self.bindText(stmt, index: 2, value: id)
        }
    }

    public func bumpPinnedFactUsage(ids: [String]) throws {
        guard !ids.isEmpty else { return }
        let placeholders = ids.enumerated().map { "?\($0.offset + 1)" }.joined(separator: ",")
        _ = try executeUpdate(
            """
            UPDATE pinned_facts
            SET last_used = datetime('now'), use_count = use_count + 1
            WHERE id IN (\(placeholders))
            """
        ) { stmt in
            for (i, id) in ids.enumerated() {
                Self.bindText(stmt, index: Int32(i + 1), value: id)
            }
        }
    }

    public func deletePinnedFact(id: String) throws {
        _ = try executeUpdate("DELETE FROM pinned_facts WHERE id = ?1") { stmt in
            Self.bindText(stmt, index: 1, value: id)
        }
    }

    public func evictPinnedFacts(belowSalience floor: Double, idleDays: Int) throws -> Int {
        var evicted = 0
        try prepareAndExecute(
            """
            DELETE FROM pinned_facts
            WHERE status = 'active'
              AND salience < ?1
              AND last_used <= datetime('now', '-' || ?2 || ' days')
            """,
            bind: { stmt in
                sqlite3_bind_double(stmt, 1, floor)
                sqlite3_bind_int(stmt, 2, Int32(max(0, idleDays)))
            },
            process: { stmt in
                _ = sqlite3_step(stmt)
                evicted = Int(sqlite3_changes(self.db))
            }
        )
        return evicted
    }

    /// Eviction variant that returns the `(id, agentId)` of every row it
    /// deletes, so the caller can drop the matching Vectura embeddings and
    /// keep the SQL store and the vector index consistent. Without this the
    /// pinned-fact vectors outlive their SQL rows and keep surfacing in
    /// `searchPinnedFacts` until the next full `rebuildIndex()`.
    public func evictPinnedFactsReturningKeys(
        belowSalience floor: Double,
        idleDays: Int
    ) throws -> [(id: String, agentId: String)] {
        var keys: [(id: String, agentId: String)] = []
        try prepareAndExecute(
            """
            SELECT id, agent_id FROM pinned_facts
            WHERE status = 'active'
              AND salience < ?1
              AND last_used <= datetime('now', '-' || ?2 || ' days')
            """,
            bind: { stmt in
                sqlite3_bind_double(stmt, 1, floor)
                sqlite3_bind_int(stmt, 2, Int32(max(0, idleDays)))
            },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    guard let idC = sqlite3_column_text(stmt, 0) else { continue }
                    let id = String(cString: idC)
                    let agentId = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
                    if !id.isEmpty { keys.append((id: id, agentId: agentId)) }
                }
            }
        )
        guard !keys.isEmpty else { return [] }

        // Delete in bounded chunks. A single `DELETE ... WHERE id IN (?, ?, …)`
        // with one bound parameter per evicted fact can exceed SQLite's
        // compile-time host-parameter cap (SQLITE_MAX_VARIABLE_NUMBER, 999 on
        // the system SQLite) and bloat the SQL text once a large backlog is
        // eligible. Chunking keeps every statement well under the limit;
        // wrapping the chunks in one transaction keeps the eviction atomic.
        let ids = keys.map { $0.id }
        let chunkSize = 500
        try inTransaction { connection in
            var start = 0
            while start < ids.count {
                let chunk = Array(ids[start ..< min(start + chunkSize, ids.count)])
                let placeholders = chunk.indices.map { "?\($0 + 1)" }.joined(separator: ",")
                try Self.executeUpdate(
                    on: connection,
                    "DELETE FROM pinned_facts WHERE id IN (\(placeholders))"
                ) { stmt in
                    for (i, id) in chunk.enumerated() {
                        Self.bindText(stmt, index: Int32(i + 1), value: id)
                    }
                }
                start += chunkSize
            }
        }
        return keys
    }

    public func loadPinnedFacts(
        agentId: String? = nil,
        limit: Int = 0,
        minSalience: Double = 0
    ) throws -> [PinnedFact] {
        var facts: [PinnedFact] = []
        var sql = "SELECT \(Self.pinnedColumns) FROM pinned_facts WHERE status = 'active' AND salience >= ?1"
        if agentId != nil { sql += " AND agent_id = ?2" }
        sql += " ORDER BY salience DESC, last_used DESC"
        if limit > 0 {
            let limitParam = agentId != nil ? 3 : 2
            sql += " LIMIT ?\(limitParam)"
        }
        try prepareAndExecute(
            sql,
            bind: { stmt in
                sqlite3_bind_double(stmt, 1, minSalience)
                if let agentId { Self.bindText(stmt, index: 2, value: agentId) }
                if limit > 0 {
                    let limitIndex = Int32(agentId != nil ? 3 : 2)
                    sqlite3_bind_int(stmt, limitIndex, Int32(limit))
                }
            },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    facts.append(Self.readPinnedFact(stmt))
                }
            }
        )
        return facts
    }

    public func loadPinnedFactsByIds(_ ids: [String]) throws -> [PinnedFact] {
        guard !ids.isEmpty else { return [] }
        let placeholders = ids.enumerated().map { "?\($0.offset + 1)" }.joined(separator: ",")
        let sql = """
            SELECT \(Self.pinnedColumns)
            FROM pinned_facts
            WHERE status = 'active' AND id IN (\(placeholders))
            """
        var facts: [PinnedFact] = []
        try prepareAndExecute(
            sql,
            bind: { stmt in
                for (i, id) in ids.enumerated() {
                    Self.bindText(stmt, index: Int32(i + 1), value: id)
                }
            },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    facts.append(Self.readPinnedFact(stmt))
                }
            }
        )
        return facts
    }

    public func searchPinnedFactsText(
        query: String,
        agentId: String? = nil,
        limit: Int = MemoryConfiguration.fallbackSearchLimit
    ) throws -> [PinnedFact] {
        var facts: [PinnedFact] = []
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // Prefer FTS5 (post-v6 schema). Falls back to LIKE for legacy
        // databases that haven't been migrated yet.
        if try ftsAvailable("fts_pinned"), let ftsQuery = Self.ftsMatchQuery(trimmed) {
            var sql = """
                SELECT \(Self.pinnedColumnsQualified)
                FROM pinned_facts
                JOIN fts_pinned ON fts_pinned.rowid = pinned_facts.rowid
                WHERE pinned_facts.status = 'active' AND fts_pinned MATCH ?1
                """
            if agentId != nil { sql += " AND pinned_facts.agent_id = ?2" }
            sql += " ORDER BY pinned_facts.salience DESC LIMIT ?\(agentId != nil ? 3 : 2)"
            try prepareAndExecute(
                sql,
                bind: { stmt in
                    Self.bindText(stmt, index: 1, value: ftsQuery)
                    if let agentId { Self.bindText(stmt, index: 2, value: agentId) }
                    let limitIndex = Int32(agentId != nil ? 3 : 2)
                    sqlite3_bind_int(stmt, limitIndex, Int32(limit))
                },
                process: { stmt in
                    while sqlite3_step(stmt) == SQLITE_ROW {
                        facts.append(Self.readPinnedFact(stmt))
                    }
                }
            )
            return facts
        }

        // Legacy LIKE fallback (no FTS5 available).
        var sql = """
            SELECT \(Self.pinnedColumns)
            FROM pinned_facts
            WHERE status = 'active' AND content LIKE '%' || ?1 || '%'
            """
        if agentId != nil { sql += " AND agent_id = ?2" }
        sql += " ORDER BY salience DESC LIMIT ?\(agentId != nil ? 3 : 2)"
        try prepareAndExecute(
            sql,
            bind: { stmt in
                Self.bindText(stmt, index: 1, value: trimmed)
                if let agentId { Self.bindText(stmt, index: 2, value: agentId) }
                let limitIndex = Int32(agentId != nil ? 3 : 2)
                sqlite3_bind_int(stmt, limitIndex, Int32(limit))
            },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    facts.append(Self.readPinnedFact(stmt))
                }
            }
        )
        return facts
    }

    public func decayPinnedSalience(halfLifeDays: Double) throws {
        try batchedDecaySalience(
            tableName: "pinned_facts",
            timestampColumn: "last_used",
            halfLifeDays: halfLifeDays
        )
    }

    public func pinnedFactStats(agentId: String? = nil) throws -> Int {
        var count = 0
        let sql =
            agentId == nil
            ? "SELECT COUNT(*) FROM pinned_facts WHERE status = 'active'"
            : "SELECT COUNT(*) FROM pinned_facts WHERE status = 'active' AND agent_id = ?1"
        try prepareAndExecute(
            sql,
            bind: { stmt in
                if let agentId { Self.bindText(stmt, index: 1, value: agentId) }
            },
            process: { stmt in
                if sqlite3_step(stmt) == SQLITE_ROW {
                    count = Int(sqlite3_column_int(stmt, 0))
                }
            }
        )
        return count
    }

    public func agentIdsWithPinnedFacts() throws -> [(agentId: String, count: Int)] {
        var results: [(String, Int)] = []
        try prepareAndExecute(
            """
            SELECT agent_id, COUNT(*) FROM pinned_facts
            WHERE status = 'active'
            GROUP BY agent_id
            ORDER BY 2 DESC
            """,
            bind: { _ in },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let id = String(cString: sqlite3_column_text(stmt, 0))
                    let count = Int(sqlite3_column_int(stmt, 1))
                    results.append((id, count))
                }
            }
        )
        return results
    }

    /// Per-agent count of active episodes. Combined with
    /// `agentIdsWithPinnedFacts` so the `/agents` listing's
    /// `memory_entry_count` reflects *stored memory* (a distilled episode
    /// counts even when it yielded zero pinned candidates) instead of only
    /// active pinned facts (issue #1632 U3 — "memory_entry_count stays 0").
    public func agentIdsWithEpisodes() throws -> [(agentId: String, count: Int)] {
        var results: [(String, Int)] = []
        try prepareAndExecute(
            """
            SELECT agent_id, COUNT(*) FROM episodes
            WHERE status = 'active'
            GROUP BY agent_id
            ORDER BY 2 DESC
            """,
            bind: { _ in },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let id = String(cString: sqlite3_column_text(stmt, 0))
                    let count = Int(sqlite3_column_int(stmt, 1))
                    results.append((id, count))
                }
            }
        )
        return results
    }

    private static let pinnedColumns =
        "id, agent_id, content, salience, source_count, source_episode_id, last_used, use_count, status, created_at, tags_csv"

    /// Same as `pinnedColumns` but every column qualified with the
    /// table name. Required for FTS5 joins where `content` is also a
    /// column in the shadow table — without qualification SQLite
    /// throws "ambiguous column name: content".
    private static let pinnedColumnsQualified = """
        pinned_facts.id, pinned_facts.agent_id, pinned_facts.content,
        pinned_facts.salience, pinned_facts.source_count, pinned_facts.source_episode_id,
        pinned_facts.last_used, pinned_facts.use_count, pinned_facts.status,
        pinned_facts.created_at, pinned_facts.tags_csv
        """

    private static func readPinnedFact(_ stmt: OpaquePointer) -> PinnedFact {
        PinnedFact(
            id: String(cString: sqlite3_column_text(stmt, 0)),
            agentId: String(cString: sqlite3_column_text(stmt, 1)),
            content: String(cString: sqlite3_column_text(stmt, 2)),
            salience: sqlite3_column_double(stmt, 3),
            sourceCount: Int(sqlite3_column_int(stmt, 4)),
            sourceEpisodeId: sqlite3_column_type(stmt, 5) != SQLITE_NULL
                ? Int(sqlite3_column_int(stmt, 5)) : nil,
            lastUsed: String(cString: sqlite3_column_text(stmt, 6)),
            useCount: Int(sqlite3_column_int(stmt, 7)),
            status: String(cString: sqlite3_column_text(stmt, 8)),
            createdAt: String(cString: sqlite3_column_text(stmt, 9)),
            tagsCSV: sqlite3_column_text(stmt, 10).map { String(cString: $0) }
        )
    }

    // MARK: - Episodes

    public func insertEpisode(_ ep: Episode) throws -> Int {
        _ = try executeUpdate(
            """
            INSERT INTO episodes
                (agent_id, conversation_id, summary, topics_csv, entities_csv,
                 decisions, action_items, salience, token_count, model,
                 conversation_at, status, created_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12,
                    COALESCE(NULLIF(?13, ''), datetime('now')))
            """
        ) { stmt in
            Self.bindText(stmt, index: 1, value: ep.agentId)
            Self.bindText(stmt, index: 2, value: ep.conversationId)
            Self.bindText(stmt, index: 3, value: ep.summary)
            Self.bindText(stmt, index: 4, value: ep.topicsCSV)
            Self.bindText(stmt, index: 5, value: ep.entitiesCSV)
            Self.bindText(stmt, index: 6, value: ep.decisions)
            Self.bindText(stmt, index: 7, value: ep.actionItems)
            sqlite3_bind_double(stmt, 8, ep.salience)
            sqlite3_bind_int(stmt, 9, Int32(ep.tokenCount))
            Self.bindText(stmt, index: 10, value: ep.model)
            Self.bindText(stmt, index: 11, value: ep.conversationAt)
            Self.bindText(stmt, index: 12, value: ep.status)
            Self.bindText(stmt, index: 13, value: ep.createdAt)
        }
        return Int(sqlite3_last_insert_rowid(db))
    }

    /// Atomically insert an episode and mark exactly the signals folded
    /// into it as processed.
    ///
    /// `signalIds` are the primary keys snapshotted by the distiller before
    /// the LLM call. Marking only those (rather than every `status='pending'`
    /// row for the conversation) means a turn buffered *while the LLM call
    /// was in flight* survives as `pending` and lands in the next episode,
    /// instead of being silently marked processed without ever appearing in
    /// any episode (issue #1632 D2). An empty `signalIds` is treated as "mark
    /// nothing" rather than "mark all".
    public func insertEpisodeAndMarkProcessed(_ ep: Episode, signalIds: [Int]) throws -> Int {
        try inTransaction { _ in
            var rowid: Int = 0
            var stmt: OpaquePointer?
            let insertSQL = """
                INSERT INTO episodes
                    (agent_id, conversation_id, summary, topics_csv, entities_csv,
                     decisions, action_items, salience, token_count, model,
                     conversation_at, status, created_at)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12,
                        COALESCE(NULLIF(?13, ''), datetime('now')))
                """
            guard sqlite3_prepare_v2(self.db, insertSQL, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
                throw MemoryDatabaseError.failedToPrepare(String(cString: sqlite3_errmsg(self.db)))
            }
            Self.bindText(s, index: 1, value: ep.agentId)
            Self.bindText(s, index: 2, value: ep.conversationId)
            Self.bindText(s, index: 3, value: ep.summary)
            Self.bindText(s, index: 4, value: ep.topicsCSV)
            Self.bindText(s, index: 5, value: ep.entitiesCSV)
            Self.bindText(s, index: 6, value: ep.decisions)
            Self.bindText(s, index: 7, value: ep.actionItems)
            sqlite3_bind_double(s, 8, ep.salience)
            sqlite3_bind_int(s, 9, Int32(ep.tokenCount))
            Self.bindText(s, index: 10, value: ep.model)
            Self.bindText(s, index: 11, value: ep.conversationAt)
            Self.bindText(s, index: 12, value: ep.status)
            Self.bindText(s, index: 13, value: ep.createdAt)
            guard sqlite3_step(s) == SQLITE_DONE else {
                sqlite3_finalize(s)
                throw MemoryDatabaseError.failedToExecute("episode insert step failed")
            }
            sqlite3_finalize(s)
            rowid = Int(sqlite3_last_insert_rowid(self.db))

            guard !signalIds.isEmpty else { return rowid }

            let placeholders = signalIds.indices.map { "?\($0 + 1)" }.joined(separator: ", ")
            var clear: OpaquePointer?
            let clearSQL =
                "UPDATE pending_signals SET status = 'processed' WHERE id IN (\(placeholders))"
            guard sqlite3_prepare_v2(self.db, clearSQL, -1, &clear, nil) == SQLITE_OK, let c = clear else {
                throw MemoryDatabaseError.failedToPrepare(String(cString: sqlite3_errmsg(self.db)))
            }
            for (i, id) in signalIds.enumerated() {
                sqlite3_bind_int(c, Int32(i + 1), Int32(id))
            }
            _ = sqlite3_step(c)
            sqlite3_finalize(c)
            return rowid
        }
    }

    public func loadEpisodes(
        agentId: String? = nil,
        days: Int = 0,
        limit: Int = 0
    ) throws -> [Episode] {
        var episodes: [Episode] = []
        var sql = "SELECT \(Self.episodeColumns) FROM episodes WHERE status = 'active'"
        var paramIndex = 1
        var agentIndex: Int = 0
        var daysIndex: Int = 0
        var limitIndex: Int = 0
        if agentId != nil {
            sql += " AND agent_id = ?\(paramIndex)"
            agentIndex = paramIndex
            paramIndex += 1
        }
        if days > 0 {
            sql += " AND conversation_at >= datetime('now', '-' || ?\(paramIndex) || ' days')"
            daysIndex = paramIndex
            paramIndex += 1
        }
        sql += " ORDER BY conversation_at DESC"
        if limit > 0 {
            sql += " LIMIT ?\(paramIndex)"
            limitIndex = paramIndex
        }

        try prepareAndExecute(
            sql,
            bind: { stmt in
                if agentIndex > 0, let agentId { Self.bindText(stmt, index: Int32(agentIndex), value: agentId) }
                if daysIndex > 0 { sqlite3_bind_int(stmt, Int32(daysIndex), Int32(days)) }
                if limitIndex > 0 { sqlite3_bind_int(stmt, Int32(limitIndex), Int32(limit)) }
            },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    episodes.append(Self.readEpisode(stmt))
                }
            }
        )
        return episodes
    }

    public func loadEpisodesByIds(_ ids: [Int]) throws -> [Episode] {
        guard !ids.isEmpty else { return [] }
        let placeholders = ids.enumerated().map { "?\($0.offset + 1)" }.joined(separator: ",")
        let sql = """
            SELECT \(Self.episodeColumns) FROM episodes
            WHERE status = 'active' AND id IN (\(placeholders))
            ORDER BY conversation_at DESC
            """
        var results: [Episode] = []
        try prepareAndExecute(
            sql,
            bind: { stmt in
                for (i, id) in ids.enumerated() {
                    sqlite3_bind_int(stmt, Int32(i + 1), Int32(id))
                }
            },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    results.append(Self.readEpisode(stmt))
                }
            }
        )
        return results
    }

    public func searchEpisodesText(
        query: String,
        agentId: String? = nil,
        limit: Int = MemoryConfiguration.fallbackSearchLimit
    ) throws -> [Episode] {
        var episodes: [Episode] = []
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        if try ftsAvailable("fts_episodes"), let ftsQuery = Self.ftsMatchQuery(trimmed) {
            var sql = """
                SELECT \(Self.episodeColumnsQualified) FROM episodes
                JOIN fts_episodes ON fts_episodes.rowid = episodes.id
                WHERE episodes.status = 'active' AND fts_episodes MATCH ?1
                """
            if agentId != nil { sql += " AND episodes.agent_id = ?2" }
            sql += " ORDER BY episodes.conversation_at DESC LIMIT ?\(agentId != nil ? 3 : 2)"
            try prepareAndExecute(
                sql,
                bind: { stmt in
                    Self.bindText(stmt, index: 1, value: ftsQuery)
                    if let agentId { Self.bindText(stmt, index: 2, value: agentId) }
                    let limitIndex = Int32(agentId != nil ? 3 : 2)
                    sqlite3_bind_int(stmt, limitIndex, Int32(limit))
                },
                process: { stmt in
                    while sqlite3_step(stmt) == SQLITE_ROW {
                        episodes.append(Self.readEpisode(stmt))
                    }
                }
            )
            return episodes
        }

        var sql = """
            SELECT \(Self.episodeColumns) FROM episodes
            WHERE status = 'active'
              AND (summary LIKE '%' || ?1 || '%'
                   OR topics_csv LIKE '%' || ?1 || '%'
                   OR entities_csv LIKE '%' || ?1 || '%')
            """
        if agentId != nil { sql += " AND agent_id = ?2" }
        sql += " ORDER BY conversation_at DESC LIMIT ?\(agentId != nil ? 3 : 2)"
        try prepareAndExecute(
            sql,
            bind: { stmt in
                Self.bindText(stmt, index: 1, value: trimmed)
                if let agentId { Self.bindText(stmt, index: 2, value: agentId) }
                let limitIndex = Int32(agentId != nil ? 3 : 2)
                sqlite3_bind_int(stmt, limitIndex, Int32(limit))
            },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    episodes.append(Self.readEpisode(stmt))
                }
            }
        )
        return episodes
    }

    public func episodeStats(agentId: String? = nil) throws -> Int {
        var count = 0
        let sql =
            agentId == nil
            ? "SELECT COUNT(*) FROM episodes WHERE status = 'active'"
            : "SELECT COUNT(*) FROM episodes WHERE status = 'active' AND agent_id = ?1"
        try prepareAndExecute(
            sql,
            bind: { stmt in
                if let agentId { Self.bindText(stmt, index: 1, value: agentId) }
            },
            process: { stmt in
                if sqlite3_step(stmt) == SQLITE_ROW {
                    count = Int(sqlite3_column_int(stmt, 0))
                }
            }
        )
        return count
    }

    public func deleteEpisode(id: Int) throws {
        _ = try executeUpdate("DELETE FROM episodes WHERE id = ?1") { stmt in
            sqlite3_bind_int(stmt, 1, Int32(id))
        }
    }

    public func pruneEpisodes(olderThanDays days: Int) throws -> Int {
        guard days > 0 else { return 0 }
        var deleted = 0
        try prepareAndExecute(
            "DELETE FROM episodes WHERE conversation_at < datetime('now', '-' || ?1 || ' days')",
            bind: { stmt in sqlite3_bind_int(stmt, 1, Int32(days)) },
            process: { stmt in
                _ = sqlite3_step(stmt)
                deleted = Int(sqlite3_changes(self.db))
            }
        )
        return deleted
    }

    public func decayEpisodeSalience(halfLifeDays: Double) throws {
        try batchedDecaySalience(
            tableName: "episodes",
            timestampColumn: "conversation_at",
            halfLifeDays: halfLifeDays
        )
    }

    /// Apply `salience *= 0.5 ^ (Δdays / halfLife)` to every active
    /// row returned by `selectSQL`, in **one batched UPDATE per
    /// transaction** instead of the previous "select all rows, then
    /// emit one UPDATE per row" loop. SQLite has no native `exp()`
    /// here, so we register a per-connection scalar function for the
    /// duration of the call. The function returns the decay multiplier
    /// for a given Δdays / halfLife pair.
    ///
    /// Shared between `decayPinnedSalience` (TEXT id, `salience`
    /// against `last_used`) and `decayEpisodeSalience` (INTEGER id,
    /// `salience` against `conversation_at`); the caller decides which
    /// table + timestamp column is used via `tableName` /
    /// `timestampColumn`.
    private func batchedDecaySalience(
        tableName: String,
        timestampColumn: String,
        halfLifeDays: Double
    ) throws {
        let factor = halfLifeDays > 0 ? halfLifeDays : 1
        // Half-life decay = 0.5 ^ (Δdays / halfLifeDays); clamp to [0, 1].
        // SQLite gives us `power(...)` in newer builds, but to stay
        // portable we expand using `exp(x*ln(0.5))`. Since the
        // amalgamation we ship enables math via `SQLITE_ENABLE_MATH_FUNCTIONS`
        // on macOS via the standard build, we can rely on `exp` and
        // `log` directly. Cap at the SQL layer so a stale row with
        // Δdays < 0 doesn't blow up.
        let sql = """
            UPDATE \(tableName) SET salience = MAX(0.0, MIN(1.0,
                salience * exp(MAX(0.0, julianday('now') - julianday(\(timestampColumn))) * log(0.5) / ?1)
            ))
            WHERE status = 'active'
            """
        do {
            _ = try executeUpdate(sql) { stmt in
                sqlite3_bind_double(stmt, 1, factor)
            }
        } catch {
            // Older SQLite builds without `exp`/`log` fall back to the
            // row-by-row Swift implementation. SQLCipher 4.6 does ship
            // them, but plaintext system SQLite from earlier macOS may
            // not, so keep the loop alive for the migrator path.
            try fallbackDecaySalience(tableName: tableName, timestampColumn: timestampColumn, halfLifeDays: factor)
        }
    }

    private func fallbackDecaySalience(
        tableName: String,
        timestampColumn: String,
        halfLifeDays: Double
    ) throws {
        struct Row { let id: String; let salience: Double; let deltaDays: Double }
        var rows: [Row] = []
        try prepareAndExecute(
            """
            SELECT id, salience, julianday('now') - julianday(\(timestampColumn)) AS dt_days
            FROM \(tableName) WHERE status = 'active'
            """,
            bind: { _ in },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    rows.append(
                        Row(
                            id: String(cString: sqlite3_column_text(stmt, 0)),
                            salience: sqlite3_column_double(stmt, 1),
                            deltaDays: sqlite3_column_double(stmt, 2)
                        )
                    )
                }
            }
        )
        try inTransaction { connection in
            for row in rows {
                let scaled = max(0, min(1, row.salience * pow(0.5, max(0, row.deltaDays) / halfLifeDays)))
                var stmt: OpaquePointer?
                let updateSQL = "UPDATE \(tableName) SET salience = ?1 WHERE id = ?2"
                guard sqlite3_prepare_v2(connection, updateSQL, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
                    throw MemoryDatabaseError.failedToPrepare(String(cString: sqlite3_errmsg(connection)))
                }
                sqlite3_bind_double(s, 1, scaled)
                if let asInt = Int(row.id) {
                    sqlite3_bind_int(s, 2, Int32(asInt))
                } else {
                    Self.bindText(s, index: 2, value: row.id)
                }
                _ = sqlite3_step(s)
                sqlite3_finalize(s)
            }
        }
    }

    public func loadAllEpisodeKeys() throws -> [(id: Int, agentId: String, conversationId: String)] {
        var keys: [(id: Int, agentId: String, conversationId: String)] = []
        try prepareAndExecute(
            "SELECT id, agent_id, conversation_id FROM episodes WHERE status = 'active'",
            bind: { _ in },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    keys.append(
                        (
                            Int(sqlite3_column_int(stmt, 0)),
                            String(cString: sqlite3_column_text(stmt, 1)),
                            String(cString: sqlite3_column_text(stmt, 2))
                        )
                    )
                }
            }
        )
        return keys
    }

    private static let episodeColumns =
        "id, agent_id, conversation_id, summary, topics_csv, entities_csv, decisions, action_items, salience, token_count, model, conversation_at, status, created_at"

    /// Qualified for FTS5 join (see `pinnedColumnsQualified`).
    private static let episodeColumnsQualified = """
        episodes.id, episodes.agent_id, episodes.conversation_id, episodes.summary,
        episodes.topics_csv, episodes.entities_csv, episodes.decisions,
        episodes.action_items, episodes.salience, episodes.token_count,
        episodes.model, episodes.conversation_at, episodes.status, episodes.created_at
        """

    private static func readEpisode(_ stmt: OpaquePointer) -> Episode {
        Episode(
            id: Int(sqlite3_column_int(stmt, 0)),
            agentId: String(cString: sqlite3_column_text(stmt, 1)),
            conversationId: String(cString: sqlite3_column_text(stmt, 2)),
            summary: String(cString: sqlite3_column_text(stmt, 3)),
            topicsCSV: String(cString: sqlite3_column_text(stmt, 4)),
            entitiesCSV: String(cString: sqlite3_column_text(stmt, 5)),
            decisions: String(cString: sqlite3_column_text(stmt, 6)),
            actionItems: String(cString: sqlite3_column_text(stmt, 7)),
            salience: sqlite3_column_double(stmt, 8),
            tokenCount: Int(sqlite3_column_int(stmt, 9)),
            model: String(cString: sqlite3_column_text(stmt, 10)),
            conversationAt: String(cString: sqlite3_column_text(stmt, 11)),
            status: String(cString: sqlite3_column_text(stmt, 12)),
            createdAt: String(cString: sqlite3_column_text(stmt, 13))
        )
    }

    // MARK: - Transcript

    public func insertTranscriptTurn(
        agentId: String,
        conversationId: String,
        chunkIndex: Int,
        role: String,
        content: String,
        tokenCount: Int,
        title: String? = nil,
        createdAt: String? = nil
    ) throws {
        let effectiveDate = (createdAt?.isEmpty == false) ? createdAt : nil
        _ = try executeUpdate(
            """
            INSERT INTO transcript
                (agent_id, conversation_id, chunk_index, role, content, token_count, title, created_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, COALESCE(?8, datetime('now')))
            """
        ) { stmt in
            Self.bindText(stmt, index: 1, value: agentId)
            Self.bindText(stmt, index: 2, value: conversationId)
            sqlite3_bind_int(stmt, 3, Int32(chunkIndex))
            Self.bindText(stmt, index: 4, value: role)
            Self.bindText(stmt, index: 5, value: content)
            sqlite3_bind_int(stmt, 6, Int32(tokenCount))
            Self.bindText(stmt, index: 7, value: title)
            Self.bindText(stmt, index: 8, value: effectiveDate)
        }
    }

    public func deleteTranscriptForConversation(_ conversationId: String) throws {
        _ = try executeUpdate("DELETE FROM transcript WHERE conversation_id = ?1") { stmt in
            Self.bindText(stmt, index: 1, value: conversationId)
        }
    }

    public func loadTranscript(
        agentId: String? = nil,
        days: Int = 30,
        limit: Int = 200
    ) throws -> [TranscriptTurn] {
        var turns: [TranscriptTurn] = []
        var sql = """
            SELECT id, agent_id, conversation_id, chunk_index, role, content, token_count, title, created_at
            FROM transcript
            WHERE created_at >= datetime('now', '-' || ?1 || ' days')
            """
        if agentId != nil { sql += " AND agent_id = ?2" }
        sql += " ORDER BY created_at DESC LIMIT ?\(agentId != nil ? 3 : 2)"
        try prepareAndExecute(
            sql,
            bind: { stmt in
                sqlite3_bind_int(stmt, 1, Int32(days))
                if let agentId { Self.bindText(stmt, index: 2, value: agentId) }
                let limitIndex = Int32(agentId != nil ? 3 : 2)
                sqlite3_bind_int(stmt, limitIndex, Int32(limit))
            },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    turns.append(Self.readTranscriptTurn(stmt))
                }
            }
        )
        return turns
    }

    public func loadTranscriptByCompositeKeys(
        _ keys: [(conversationId: String, chunkIndex: Int)]
    ) throws -> [TranscriptTurn] {
        guard !keys.isEmpty else { return [] }
        let conditions = keys.enumerated().map { (i, _) in
            "(conversation_id = ?\(i * 2 + 1) AND chunk_index = ?\(i * 2 + 2))"
        }.joined(separator: " OR ")
        let sql = """
            SELECT id, agent_id, conversation_id, chunk_index, role, content, token_count, title, created_at
            FROM transcript WHERE \(conditions)
            ORDER BY created_at DESC
            """
        var turns: [TranscriptTurn] = []
        try prepareAndExecute(
            sql,
            bind: { stmt in
                for (i, key) in keys.enumerated() {
                    Self.bindText(stmt, index: Int32(i * 2 + 1), value: key.conversationId)
                    sqlite3_bind_int(stmt, Int32(i * 2 + 2), Int32(key.chunkIndex))
                }
            },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    turns.append(Self.readTranscriptTurn(stmt))
                }
            }
        )
        return turns
    }

    public func loadTranscriptForConversation(
        conversationId: String,
        limit: Int = 500
    ) throws -> [TranscriptTurn] {
        var turns: [TranscriptTurn] = []
        try prepareAndExecute(
            """
            SELECT id, agent_id, conversation_id, chunk_index, role, content, token_count, title, created_at
            FROM transcript
            WHERE conversation_id = ?1
            ORDER BY chunk_index ASC
            LIMIT ?2
            """,
            bind: { stmt in
                Self.bindText(stmt, index: 1, value: conversationId)
                sqlite3_bind_int(stmt, 2, Int32(limit))
            },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    turns.append(Self.readTranscriptTurn(stmt))
                }
            }
        )
        return turns
    }

    public func searchTranscriptText(
        query: String,
        agentId: String? = nil,
        days: Int = 365,
        limit: Int = MemoryConfiguration.fallbackSearchLimit
    ) throws -> [TranscriptTurn] {
        var turns: [TranscriptTurn] = []
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        if try ftsAvailable("fts_transcript"), let ftsQuery = Self.ftsMatchQuery(trimmed) {
            var sql = """
                SELECT transcript.id, transcript.agent_id, transcript.conversation_id,
                       transcript.chunk_index, transcript.role, transcript.content,
                       transcript.token_count, transcript.title, transcript.created_at
                FROM transcript
                JOIN fts_transcript ON fts_transcript.rowid = transcript.id
                WHERE fts_transcript MATCH ?1
                  AND transcript.created_at >= datetime('now', '-' || ?2 || ' days')
                """
            if agentId != nil { sql += " AND transcript.agent_id = ?3" }
            sql += " ORDER BY transcript.created_at DESC LIMIT ?\(agentId != nil ? 4 : 3)"
            try prepareAndExecute(
                sql,
                bind: { stmt in
                    Self.bindText(stmt, index: 1, value: ftsQuery)
                    sqlite3_bind_int(stmt, 2, Int32(days))
                    if let agentId { Self.bindText(stmt, index: 3, value: agentId) }
                    let limitIndex = Int32(agentId != nil ? 4 : 3)
                    sqlite3_bind_int(stmt, limitIndex, Int32(limit))
                },
                process: { stmt in
                    while sqlite3_step(stmt) == SQLITE_ROW {
                        turns.append(Self.readTranscriptTurn(stmt))
                    }
                }
            )
            if !turns.isEmpty {
                return turns
            }
        }

        var sql = """
            SELECT id, agent_id, conversation_id, chunk_index, role, content, token_count, title, created_at
            FROM transcript
            WHERE content LIKE '%' || ?1 || '%'
              AND created_at >= datetime('now', '-' || ?2 || ' days')
            """
        if agentId != nil { sql += " AND agent_id = ?3" }
        sql += " ORDER BY created_at DESC LIMIT ?\(agentId != nil ? 4 : 3)"
        try prepareAndExecute(
            sql,
            bind: { stmt in
                Self.bindText(stmt, index: 1, value: trimmed)
                sqlite3_bind_int(stmt, 2, Int32(days))
                if let agentId { Self.bindText(stmt, index: 3, value: agentId) }
                let limitIndex = Int32(agentId != nil ? 4 : 3)
                sqlite3_bind_int(stmt, limitIndex, Int32(limit))
            },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    turns.append(Self.readTranscriptTurn(stmt))
                }
            }
        )
        if !turns.isEmpty {
            return turns
        }

        return try searchTranscriptLooseText(query: trimmed, agentId: agentId, days: days, limit: limit)
    }

    private func searchTranscriptLooseText(
        query: String,
        agentId: String?,
        days: Int,
        limit: Int
    ) throws -> [TranscriptTurn] {
        let terms = Self.looseSearchTerms(query)
        guard !terms.isEmpty else { return [] }

        let recent = try loadTranscript(
            agentId: agentId,
            days: days,
            limit: max(limit * 50, 250)
        )
        let scored = recent.compactMap { turn -> (turn: TranscriptTurn, score: Int)? in
            let content = turn.content.lowercased()
            let score = terms.reduce(0) { partial, term in
                partial + (content.contains(term) ? 1 : 0)
            }
            guard score > 0 else { return nil }
            return (turn, score)
        }
        return
            scored
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.turn.createdAt > $1.turn.createdAt
            }
            .prefix(limit)
            .map(\.turn)
    }

    private static func looseSearchTerms(_ raw: String) -> [String] {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let terms =
            raw.lowercased().unicodeScalars
            .map { allowed.contains($0) ? Character($0) : " " }
            .reduce(into: "") { $0.append($1) }
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { $0.count >= 4 && !Self.looseSearchStopWords.contains($0) }
        return Array(NSOrderedSet(array: terms).compactMap { $0 as? String })
    }

    private static let looseSearchStopWords: Set<String> = [
        "what", "when", "where", "which", "with", "this", "that", "these", "those",
        "reply", "only", "codeword", "please", "about", "into", "from", "have",
        "were", "your", "mine", "typed", "type",
    ]

    /// Returns true when `name` exists as a virtual table — used to
    /// detect whether the v6 FTS5 indexes have been created (handles
    /// the brief window between SQLCipher key set and migration run,
    /// and DBs imported from the migrator before triggers existed).
    private func ftsAvailable(_ name: String) throws -> Bool {
        var available = false
        try prepareAndExecute(
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name = ?1 LIMIT 1",
            bind: { stmt in Self.bindText(stmt, index: 1, value: name) },
            process: { stmt in
                if sqlite3_step(stmt) == SQLITE_ROW { available = true }
            }
        )
        return available
    }

    /// Sanitize a free-text query into something safe to pass to FTS5
    /// `MATCH`. We strip every char that isn't alphanumeric, keep
    /// individual words, then quote each term so SQL operators
    /// (`AND`, `OR`, `NEAR`, parens, etc.) embedded by the user get
    /// treated as literal tokens. Empty result returns nil so callers
    /// can short-circuit to the LIKE fallback.
    static func ftsMatchQuery(_ raw: String) -> String? {
        let allowed = CharacterSet.alphanumerics.union(.whitespaces).union(CharacterSet(charactersIn: "-_"))
        let scrubbed = String(raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : " " })
        let words =
            scrubbed
            .split(whereSeparator: { $0.isWhitespace })
            .map { String($0) }
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return nil }
        return words.map { "\"\($0)\"" }.joined(separator: " ")
    }

    public func pruneTranscript(olderThanDays days: Int) throws -> Int {
        guard days > 0 else { return 0 }
        var deleted = 0
        try prepareAndExecute(
            "DELETE FROM transcript WHERE created_at < datetime('now', '-' || ?1 || ' days')",
            bind: { stmt in sqlite3_bind_int(stmt, 1, Int32(days)) },
            process: { stmt in
                _ = sqlite3_step(stmt)
                deleted = Int(sqlite3_changes(self.db))
            }
        )
        return deleted
    }

    /// Like `pruneTranscript(olderThanDays:)` but returns the
    /// composite `(conversationId, chunkIndex)` keys that were
    /// removed, so callers can also delete the matching VecturaKit
    /// vectors. Used by `MemoryConsolidator` to keep the vector
    /// store in sync with SQL prunes.
    public func pruneTranscriptReturningKeys(
        olderThanDays days: Int
    ) throws -> [(conversationId: String, chunkIndex: Int)] {
        guard days > 0 else { return [] }
        var keys: [(conversationId: String, chunkIndex: Int)] = []
        // CRITICAL: use the non-locking `…(on: connection, …)` cores
        // here. Calling the locking `prepareAndExecute` / `executeUpdate`
        // wrappers from inside `inTransaction` re-enters the serial
        // queue and traps with `EXC_BREAKPOINT` (libdispatch deadlock
        // detector). The runtime guards on those wrappers now catch
        // this misuse at the call site, but the previous version
        // crashed in production during memory consolidation.
        try inTransaction { connection in
            // Collect first, then delete by date predicate.
            try Self.prepareAndExecute(
                on: connection,
                """
                SELECT id, conversation_id, chunk_index FROM transcript
                WHERE created_at < datetime('now', '-' || ?1 || ' days')
                """,
                bind: { stmt in sqlite3_bind_int(stmt, 1, Int32(days)) },
                process: { stmt in
                    while sqlite3_step(stmt) == SQLITE_ROW {
                        keys.append(
                            (
                                conversationId: String(cString: sqlite3_column_text(stmt, 1)),
                                chunkIndex: Int(sqlite3_column_int(stmt, 2))
                            )
                        )
                    }
                }
            )
            try Self.executeUpdate(
                on: connection,
                "DELETE FROM transcript WHERE created_at < datetime('now', '-' || ?1 || ' days')"
            ) { stmt in sqlite3_bind_int(stmt, 1, Int32(days)) }
            return ()
        }
        return keys
    }

    public func loadAllTranscriptKeys(days: Int = 365) throws -> [(id: Int, conversationId: String, chunkIndex: Int)] {
        var keys: [(id: Int, conversationId: String, chunkIndex: Int)] = []
        try prepareAndExecute(
            """
            SELECT id, conversation_id, chunk_index FROM transcript
            WHERE created_at >= datetime('now', '-' || ?1 || ' days')
            """,
            bind: { stmt in sqlite3_bind_int(stmt, 1, Int32(days)) },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    keys.append(
                        (
                            Int(sqlite3_column_int(stmt, 0)),
                            String(cString: sqlite3_column_text(stmt, 1)),
                            Int(sqlite3_column_int(stmt, 2))
                        )
                    )
                }
            }
        )
        return keys
    }

    private static func readTranscriptTurn(_ stmt: OpaquePointer) -> TranscriptTurn {
        TranscriptTurn(
            id: Int(sqlite3_column_int(stmt, 0)),
            conversationId: String(cString: sqlite3_column_text(stmt, 2)),
            chunkIndex: Int(sqlite3_column_int(stmt, 3)),
            role: String(cString: sqlite3_column_text(stmt, 4)),
            content: String(cString: sqlite3_column_text(stmt, 5)),
            tokenCount: Int(sqlite3_column_int(stmt, 6)),
            createdAt: String(cString: sqlite3_column_text(stmt, 8)),
            agentId: String(cString: sqlite3_column_text(stmt, 1)),
            conversationTitle: sqlite3_column_text(stmt, 7).map { String(cString: $0) }
        )
    }

    // MARK: - Pending Signals

    public func insertPendingSignal(_ signal: PendingSignal) throws {
        _ = try executeUpdate(
            """
            INSERT INTO pending_signals
                (agent_id, conversation_id, user_message, assistant_message, status)
            VALUES (?1, ?2, ?3, ?4, ?5)
            """
        ) { stmt in
            Self.bindText(stmt, index: 1, value: signal.agentId)
            Self.bindText(stmt, index: 2, value: signal.conversationId)
            Self.bindText(stmt, index: 3, value: signal.userMessage)
            Self.bindText(stmt, index: 4, value: signal.assistantMessage)
            Self.bindText(stmt, index: 5, value: signal.status)
        }
    }

    public func loadPendingSignals(conversationId: String) throws -> [PendingSignal] {
        var signals: [PendingSignal] = []
        try prepareAndExecute(
            """
            SELECT id, agent_id, conversation_id, user_message, assistant_message, status, created_at
            FROM pending_signals WHERE conversation_id = ?1 AND status = 'pending'
            ORDER BY created_at ASC
            """,
            bind: { stmt in Self.bindText(stmt, index: 1, value: conversationId) },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    signals.append(Self.readPendingSignal(stmt))
                }
            }
        )
        return signals
    }

    public func pendingConversations() throws -> [(agentId: String, conversationId: String)] {
        var results: [(agentId: String, conversationId: String)] = []
        try prepareAndExecute(
            "SELECT DISTINCT agent_id, conversation_id FROM pending_signals WHERE status = 'pending'",
            bind: { _ in },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    results.append(
                        (
                            agentId: String(cString: sqlite3_column_text(stmt, 0)),
                            conversationId: String(cString: sqlite3_column_text(stmt, 1))
                        )
                    )
                }
            }
        )
        return results
    }

    public func markSignalsProcessed(conversationId: String) throws {
        _ = try executeUpdate(
            "UPDATE pending_signals SET status = 'processed' WHERE conversation_id = ?1 AND status = 'pending'"
        ) { stmt in
            Self.bindText(stmt, index: 1, value: conversationId)
        }
    }

    /// Set `status` on exactly the given signal ids. Used by the distiller
    /// to clear only the signals that were folded into an episode (or a
    /// terminal empty result) without touching turns buffered after the
    /// snapshot (issue #1632 D2). No-op for an empty id list.
    public func markSignals(ids: [Int], status: String) throws {
        guard !ids.isEmpty else { return }
        let placeholders = ids.indices.map { "?\($0 + 2)" }.joined(separator: ", ")
        _ = try executeUpdate(
            "UPDATE pending_signals SET status = ?1 WHERE id IN (\(placeholders))"
        ) { stmt in
            Self.bindText(stmt, index: 1, value: status)
            for (i, id) in ids.enumerated() {
                sqlite3_bind_int(stmt, Int32(i + 2), Int32(id))
            }
        }
    }

    /// Record one failed distillation attempt for `ids` and dead-letter
    /// them once they exceed `maxAttempts`. Returns the new max attempt
    /// count across the ids and whether they were dead-lettered.
    ///
    /// Dead-lettered rows (`status='dead_letter'`) drop out of
    /// `loadPendingSignals` / `pendingConversations`, so a session that
    /// keeps failing stops re-distilling on every launch/ingest/debounce
    /// forever (issue #1632 D1). Only `pending` rows are dead-lettered, so
    /// a concurrently-processed row is never clobbered.
    @discardableResult
    public func recordDistillFailure(
        ids: [Int],
        maxAttempts: Int
    ) throws -> (attempts: Int, deadLettered: Bool) {
        guard !ids.isEmpty else { return (0, false) }
        let placeholders = ids.indices.map { "?\($0 + 1)" }.joined(separator: ", ")
        let bindIds: (OpaquePointer) -> Void = { stmt in
            for (i, id) in ids.enumerated() {
                sqlite3_bind_int(stmt, Int32(i + 1), Int32(id))
            }
        }

        _ = try executeUpdate(
            "UPDATE pending_signals SET attempts = attempts + 1 WHERE id IN (\(placeholders)) AND status = 'pending'",
            bind: bindIds
        )

        var maxSoFar = 0
        try prepareAndExecute(
            "SELECT COALESCE(MAX(attempts), 0) FROM pending_signals WHERE id IN (\(placeholders))",
            bind: bindIds,
            process: { stmt in
                if sqlite3_step(stmt) == SQLITE_ROW { maxSoFar = Int(sqlite3_column_int(stmt, 0)) }
            }
        )

        let deadLettered = maxSoFar >= maxAttempts
        if deadLettered {
            _ = try executeUpdate(
                "UPDATE pending_signals SET status = 'dead_letter' WHERE id IN (\(placeholders)) AND status = 'pending'",
                bind: bindIds
            )
        }
        return (maxSoFar, deadLettered)
    }

    /// Delete every pending signal for a conversation regardless of status.
    /// Used by `/memory/ingest` to make re-ingesting a `conversation_id`
    /// idempotent (issue #1632 I1) — a fresh ingest fully replaces the
    /// prior buffered state instead of stacking duplicate signals.
    public func deletePendingSignalsForConversation(_ conversationId: String) throws {
        _ = try executeUpdate(
            "DELETE FROM pending_signals WHERE conversation_id = ?1"
        ) { stmt in
            Self.bindText(stmt, index: 1, value: conversationId)
        }
    }

    /// Delete every episode for a conversation. Paired with
    /// `deletePendingSignalsForConversation` so a re-ingested
    /// `conversation_id` yields exactly one active episode instead of a
    /// duplicate per run (`episodes` has no `UNIQUE(conversation_id)`).
    /// Mirrors `deleteEpisode(id:)` semantics (FTS stays trigger-synced;
    /// any stale vector-index rows resolve to a missing SQL row and are
    /// filtered on read, same as the consolidator's merge path).
    public func deleteEpisodesForConversation(_ conversationId: String) throws {
        _ = try executeUpdate(
            "DELETE FROM episodes WHERE conversation_id = ?1"
        ) { stmt in
            Self.bindText(stmt, index: 1, value: conversationId)
        }
    }

    private static func readPendingSignal(_ stmt: OpaquePointer) -> PendingSignal {
        PendingSignal(
            id: Int(sqlite3_column_int(stmt, 0)),
            agentId: String(cString: sqlite3_column_text(stmt, 1)),
            conversationId: String(cString: sqlite3_column_text(stmt, 2)),
            userMessage: String(cString: sqlite3_column_text(stmt, 3)),
            assistantMessage: sqlite3_column_text(stmt, 4).map { String(cString: $0) },
            status: String(cString: sqlite3_column_text(stmt, 5)),
            createdAt: String(cString: sqlite3_column_text(stmt, 6))
        )
    }

    // MARK: - Processing Log

    public func insertProcessingLog(
        agentId: String,
        taskType: String,
        model: String?,
        status: String,
        details: String? = nil,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        durationMs: Int? = nil
    ) throws {
        _ = try executeUpdate(
            """
            INSERT INTO processing_log
                (agent_id, task_type, model, status, details, input_tokens, output_tokens, duration_ms)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
            """
        ) { stmt in
            Self.bindText(stmt, index: 1, value: agentId)
            Self.bindText(stmt, index: 2, value: taskType)
            Self.bindText(stmt, index: 3, value: model)
            Self.bindText(stmt, index: 4, value: status)
            Self.bindText(stmt, index: 5, value: details)
            if let t = inputTokens { sqlite3_bind_int(stmt, 6, Int32(t)) } else { sqlite3_bind_null(stmt, 6) }
            if let t = outputTokens { sqlite3_bind_int(stmt, 7, Int32(t)) } else { sqlite3_bind_null(stmt, 7) }
            if let t = durationMs { sqlite3_bind_int(stmt, 8, Int32(t)) } else { sqlite3_bind_null(stmt, 8) }
        }
    }

    /// Cheap row-count for the diagnostics panel — avoids loading every
    /// episode just to display a single integer.
    public func episodeCount(agentId: String? = nil) throws -> Int {
        let sql: String
        if agentId != nil {
            sql = "SELECT COUNT(*) FROM episodes WHERE status = 'active' AND agent_id = ?1"
        } else {
            sql = "SELECT COUNT(*) FROM episodes WHERE status = 'active'"
        }
        var count = 0
        try prepareAndExecute(
            sql,
            bind: { stmt in
                if let agentId { Self.bindText(stmt, index: 1, value: agentId) }
            },
            process: { stmt in
                if sqlite3_step(stmt) == SQLITE_ROW { count = Int(sqlite3_column_int(stmt, 0)) }
            }
        )
        return count
    }

    /// Cheap row-count for the diagnostics panel.
    public func pinnedFactCount(agentId: String? = nil) throws -> Int {
        let sql: String
        if agentId != nil {
            sql = "SELECT COUNT(*) FROM pinned_facts WHERE status = 'active' AND agent_id = ?1"
        } else {
            sql = "SELECT COUNT(*) FROM pinned_facts WHERE status = 'active'"
        }
        var count = 0
        try prepareAndExecute(
            sql,
            bind: { stmt in
                if let agentId { Self.bindText(stmt, index: 1, value: agentId) }
            },
            process: { stmt in
                if sqlite3_step(stmt) == SQLITE_ROW { count = Int(sqlite3_column_int(stmt, 0)) }
            }
        )
        return count
    }

    /// Conversation ids that already have at least one active episode
    /// for the given agent. Used by the backfill flow to skip
    /// conversations we've already distilled (idempotent re-run safety).
    public func distilledConversationIds(agentId: String? = nil) throws -> Set<String> {
        var ids: Set<String> = []
        let sql: String
        if agentId != nil {
            sql =
                "SELECT DISTINCT conversation_id FROM episodes WHERE status = 'active' AND agent_id = ?1"
        } else {
            sql = "SELECT DISTINCT conversation_id FROM episodes WHERE status = 'active'"
        }
        try prepareAndExecute(
            sql,
            bind: { stmt in
                if let agentId { Self.bindText(stmt, index: 1, value: agentId) }
            },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    ids.insert(String(cString: sqlite3_column_text(stmt, 0)))
                }
            }
        )
        return ids
    }

    /// Conversation ids that already have at least one pending signal.
    /// Avoids double-buffering when a backfill is re-run after a partial
    /// previous attempt.
    public func bufferedConversationIds() throws -> Set<String> {
        var ids: Set<String> = []
        try prepareAndExecute(
            "SELECT DISTINCT conversation_id FROM pending_signals",
            bind: { _ in },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    ids.insert(String(cString: sqlite3_column_text(stmt, 0)))
                }
            }
        )
        return ids
    }

    /// Dump the actual on-disk schema for a given table — used by the
    /// memory diagnostics panel when a constraint fires on `INSERT INTO
    /// pending_signals`. The user's database may have an older / mutated
    /// schema (e.g. an extra NOT NULL column from a partial migration),
    /// and seeing `PRAGMA table_info` lets us localise the divergence
    /// without a second round-trip.
    public func tableSchemaDescription(table: String) -> String {
        var lines: [String] = []
        let safeTable = table.replacingOccurrences(of: "'", with: "''")
        do {
            try prepareAndExecute(
                "PRAGMA table_info('\(safeTable)')",
                bind: { _ in },
                process: { stmt in
                    while sqlite3_step(stmt) == SQLITE_ROW {
                        let cid = Int(sqlite3_column_int(stmt, 0))
                        let name = String(cString: sqlite3_column_text(stmt, 1))
                        let type = String(cString: sqlite3_column_text(stmt, 2))
                        let notNull = sqlite3_column_int(stmt, 3) == 1
                        let defaultVal: String =
                            sqlite3_column_type(stmt, 4) == SQLITE_NULL
                            ? "—"
                            : String(cString: sqlite3_column_text(stmt, 4))
                        let pk = Int(sqlite3_column_int(stmt, 5))
                        let parts: [String] = [
                            "[\(cid)]",
                            name,
                            type,
                            notNull ? "NOT NULL" : "NULL",
                            "default=\(defaultVal)",
                            pk > 0 ? "PK\(pk)" : "",
                        ].filter { !$0.isEmpty }
                        lines.append(parts.joined(separator: " "))
                    }
                }
            )
        } catch {
            return "(schema dump failed: \(error.localizedDescription))"
        }
        return lines.isEmpty ? "(table not found)" : lines.joined(separator: "\n")
    }

    /// Counts of unprocessed `pending_signals` plus an all-time row count
    /// (regardless of status). The diagnostics panel uses the all-time
    /// total to distinguish "bufferTurn never reached the database" (= 0)
    /// from "buffered then drained" (= some N with empty `pending`).
    public func pendingSignalsSummary() throws -> PendingSignalsSummary {
        var summary = PendingSignalsSummary()
        try prepareAndExecute(
            """
            SELECT
                SUM(CASE WHEN status = 'pending' THEN 1 ELSE 0 END),
                COUNT(DISTINCT CASE WHEN status = 'pending' THEN conversation_id END),
                COUNT(*)
            FROM pending_signals
            """,
            bind: { _ in },
            process: { stmt in
                if sqlite3_step(stmt) == SQLITE_ROW {
                    summary.totalSignals =
                        sqlite3_column_type(stmt, 0) == SQLITE_NULL ? 0 : Int(sqlite3_column_int(stmt, 0))
                    summary.distinctConversations = Int(sqlite3_column_int(stmt, 1))
                    summary.allTimeSignals = Int(sqlite3_column_int(stmt, 2))
                }
            }
        )
        return summary
    }

    /// Most-recent `processing_log` rows for the diagnostics panel. Capped
    /// by `limit` so we never page in the entire log on every Memory-tab
    /// re-render.
    public func recentProcessingLog(limit: Int = 20) throws -> [ProcessingLogRow] {
        var rows: [ProcessingLogRow] = []
        try prepareAndExecute(
            """
            SELECT id, agent_id, task_type, model, status, details,
                   input_tokens, output_tokens, duration_ms, created_at
            FROM processing_log
            ORDER BY id DESC
            LIMIT ?1
            """,
            bind: { stmt in sqlite3_bind_int(stmt, 1, Int32(max(0, limit))) },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let id = Int(sqlite3_column_int(stmt, 0))
                    let agentId = String(cString: sqlite3_column_text(stmt, 1))
                    let taskType = String(cString: sqlite3_column_text(stmt, 2))
                    let model = sqlite3_column_text(stmt, 3).map { String(cString: $0) }
                    let status = String(cString: sqlite3_column_text(stmt, 4))
                    let details = sqlite3_column_text(stmt, 5).map { String(cString: $0) }
                    let inputTokens: Int? =
                        sqlite3_column_type(stmt, 6) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 6))
                    let outputTokens: Int? =
                        sqlite3_column_type(stmt, 7) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 7))
                    let durationMs: Int? =
                        sqlite3_column_type(stmt, 8) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 8))
                    let createdAt = String(cString: sqlite3_column_text(stmt, 9))
                    rows.append(
                        ProcessingLogRow(
                            id: id,
                            agentId: agentId,
                            taskType: taskType,
                            model: model,
                            status: status,
                            details: details,
                            inputTokens: inputTokens,
                            outputTokens: outputTokens,
                            durationMs: durationMs,
                            createdAt: createdAt
                        )
                    )
                }
            }
        )
        return rows
    }

    public func processingStats() throws -> ProcessingStats {
        var stats = ProcessingStats()
        try prepareAndExecute(
            """
            SELECT COUNT(*), AVG(duration_ms),
                   SUM(CASE WHEN status = 'success' THEN 1 ELSE 0 END),
                   SUM(CASE WHEN status = 'error' THEN 1 ELSE 0 END)
            FROM processing_log
            """,
            bind: { _ in },
            process: { stmt in
                if sqlite3_step(stmt) == SQLITE_ROW {
                    stats.totalCalls = Int(sqlite3_column_int(stmt, 0))
                    stats.avgDurationMs =
                        sqlite3_column_type(stmt, 1) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 1)) : 0
                    stats.successCount = Int(sqlite3_column_int(stmt, 2))
                    stats.errorCount = Int(sqlite3_column_int(stmt, 3))
                }
            }
        )
        return stats
    }

    // MARK: - Database Info & Maintenance

    public func databaseSizeBytes() -> Int64 {
        let path = OsaurusPaths.memoryDatabaseFile().path
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return (attrs?[.size] as? Int64) ?? 0
    }

    public func optimize() {
        queue.sync {
            guard db != nil else { return }
            try? executeRaw("PRAGMA optimize")
        }
    }

    public func vacuum() throws {
        try queue.sync {
            guard db != nil else { throw MemoryDatabaseError.notOpen }
            try executeRaw("VACUUM")
        }
    }

    /// Trim old processing logs and processed pending signals.
    public func purgeOldEventData(retentionDays: Int = 30) throws {
        _ = try executeUpdate(
            "DELETE FROM processing_log WHERE created_at < datetime('now', '-' || ?1 || ' days')"
        ) { stmt in sqlite3_bind_int(stmt, 1, Int32(retentionDays)) }
        _ = try executeUpdate(
            "DELETE FROM pending_signals WHERE status = 'processed' AND created_at < datetime('now', '-' || ?1 || ' days')"
        ) { stmt in sqlite3_bind_int(stmt, 1, Int32(retentionDays)) }
    }
}

// MARK: - SQLite Helpers

/// SQLITE_TRANSIENT tells SQLite to make its own copy of the string data immediately.
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

extension MemoryDatabase {
    static func bindText(_ stmt: OpaquePointer, index: Int32, value: String?) {
        if let value = value {
            sqlite3_bind_text(stmt, index, value, -1, sqliteTransient)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }
}
