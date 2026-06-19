//
//  SchedulerDatabase.swift
//  osaurus
//
//  Cross-agent scheduler state for the Agent DB + Self-Scheduling feature.
//  Owns three tables (`agent_next_run`, `agent_runs`, `agent_pause`) per
//  spec §4.2. One file at `~/.osaurus/scheduler.sqlite`, not per-agent —
//  the scheduler tick reads across all agents every second and the
//  Activity dashboard is naturally cross-agent. Encrypted via the same
//  vendored SQLCipher + `StorageKeyManager` setup the rest of the
//  Osaurus stack uses, so prompts / instructions / error messages in
//  this file are protected at rest.
//
//  Foreign keys to `agents(id)` are not declared because agents live in
//  JSON files. The dispatcher does an "orphan" check on read and
//  `deleteAllForAgent` cleans up when the user deletes an agent.
//

import CryptoKit
import Foundation
import OsaurusSQLCipher

public enum SchedulerDatabaseError: Error, LocalizedError {
    case failedToOpen(String)
    case failedToExecute(String)
    case failedToPrepare(String)
    case migrationFailed(String)
    case notOpen

    public var errorDescription: String? {
        switch self {
        case .failedToOpen(let m): return "Failed to open scheduler database: \(m)"
        case .failedToExecute(let m): return "Failed to execute scheduler query: \(m)"
        case .failedToPrepare(let m): return "Failed to prepare scheduler statement: \(m)"
        case .migrationFailed(let m): return "Scheduler migration failed: \(m)"
        case .notOpen: return "Scheduler database is not open"
        }
    }
}

// MARK: - Domain types

/// Lower priority means the scheduler dispatcher may shed this run when
/// host concurrency limits are saturated.
public enum NextRunPriority: String, Codable, Sendable, CaseIterable {
    case normal
    case low
}

/// How the dispatcher should handle a scheduled run whose `scheduled_at`
/// already drifted past `now + staleThreshold` (spec §9.2).
public enum NextRunOnMiss: String, Codable, Sendable, CaseIterable {
    /// Drop the run silently; log it in `agent_runs` as `cancelled`.
    case skip
    /// Run immediately with the original instruction, even if late.
    case runOnce = "run_once"
    /// Run N times, once per missed interval. Rare; for ledger-type agents.
    case runCatchup = "run_catchup"
}

/// Who wrote the row into `agent_next_run`. The agent sees this on wake
/// so it can react to user edits (spec §9.5).
public enum NextRunScheduledBy: String, Codable, Sendable, CaseIterable {
    case agent
    case user
    case system
}

/// The kind of event that woke the agent. Maps from `DispatchRequest.source`
/// at run-start in `BackgroundTaskManager.dispatchChat`.
public enum AgentRunTriggerKind: String, Codable, Sendable, CaseIterable {
    /// Self-scheduled wake via `schedule_next_run` (the new next-run slot).
    case schedule
    /// User-authored recurring schedule from `ScheduleManager` (existing system).
    case recurringSchedule = "recurring_schedule"
    /// File-system watcher from `WatcherManager` (existing system).
    case watcher
    /// User-initiated chat from the UI.
    case user
}

/// Terminal status of an `agent_runs` row. Only `success` and `error`
/// count against `daily_run_cap` (spec §16 Q3).
public enum AgentRunStatus: String, Codable, Sendable, CaseIterable {
    case running
    case success
    case error
    case cancelled
    case clamped
}

/// One row in `agent_next_run`. The "next run" slot is a single row per
/// agent; writers (agent / user / system) overwrite each other,
/// last-write-wins (spec §9.5).
public struct NextRunEntry: Codable, Sendable, Equatable {
    public var agentId: UUID
    public var scheduledAt: Date
    public var instructions: String
    /// Names of saved views the dispatcher should prefetch before the
    /// inference loop begins. Stored as JSON.
    public var contextViews: [String]
    public var priority: NextRunPriority
    public var onMiss: NextRunOnMiss
    public var scheduledBy: NextRunScheduledBy
    public var scheduledAtWall: Date

    public init(
        agentId: UUID,
        scheduledAt: Date,
        instructions: String,
        contextViews: [String] = [],
        priority: NextRunPriority = .normal,
        onMiss: NextRunOnMiss = .skip,
        scheduledBy: NextRunScheduledBy,
        scheduledAtWall: Date = Date()
    ) {
        self.agentId = agentId
        self.scheduledAt = scheduledAt
        self.instructions = instructions
        self.contextViews = contextViews
        self.priority = priority
        self.onMiss = onMiss
        self.scheduledBy = scheduledBy
        self.scheduledAtWall = scheduledAtWall
    }
}

/// One row in `agent_runs`. Append-only history; `recordRunStart` writes
/// `status = running` and `recordRunEnd` flips it to a terminal value.
public struct AgentRunRecord: Codable, Sendable, Equatable {
    public var id: UUID
    public var agentId: UUID
    public var triggerKind: AgentRunTriggerKind
    public var triggerPayload: String?
    public var instructions: String
    public var startedAt: Date
    public var endedAt: Date?
    public var status: AgentRunStatus
    public var tokensIn: Int?
    public var tokensOut: Int?
    public var costUSD: Double?
    public var error: String?

    public init(
        id: UUID,
        agentId: UUID,
        triggerKind: AgentRunTriggerKind,
        triggerPayload: String? = nil,
        instructions: String,
        startedAt: Date,
        endedAt: Date? = nil,
        status: AgentRunStatus = .running,
        tokensIn: Int? = nil,
        tokensOut: Int? = nil,
        costUSD: Double? = nil,
        error: String? = nil
    ) {
        self.id = id
        self.agentId = agentId
        self.triggerKind = triggerKind
        self.triggerPayload = triggerPayload
        self.instructions = instructions
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.status = status
        self.tokensIn = tokensIn
        self.tokensOut = tokensOut
        self.costUSD = costUSD
        self.error = error
    }
}

/// One row in `agent_pause`. Transient operational state (not exportable
/// config), so this lives here rather than in `Agent.json`.
public struct AgentPauseRecord: Codable, Sendable, Equatable {
    public var agentId: UUID
    public var pausedUntil: Date
    public var reason: String?

    public init(agentId: UUID, pausedUntil: Date, reason: String? = nil) {
        self.agentId = agentId
        self.pausedUntil = pausedUntil
        self.reason = reason
    }
}

// MARK: - Database

public final class SchedulerDatabase: @unchecked Sendable {
    public static let shared = SchedulerDatabase()

    private static let schemaVersion = 1

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "ai.osaurus.scheduler.database")
    private let stmtCache = PreparedStatementCache(capacity: 64)

    init() {}

    deinit { close() }

    // MARK: - Lifecycle

    public func open() throws {
        // Mirrors the gating in every other `*Database.open()`: parks
        // only while a key rotation is re-encrypting databases so we
        // can't open a half-rekeyed file. No-op fast path otherwise.
        StorageMutationGate.blockingAwaitNotMutating()
        try queue.sync {
            guard db == nil else { return }
            OsaurusPaths.ensureExistsSilent(OsaurusPaths.root())
            try openConnection()
            try runMigrations()
        }
        OsaurusDatabaseHandle.register(maintenanceHandle)
    }

    private lazy var maintenanceHandle = OsaurusDatabaseHandle(
        name: "scheduler",
        exec: { [weak self] sql in
            self?.queue.sync {
                guard self?.db != nil else { return }
                try? self?.executeRaw(sql)
            }
        },
        closer: { [weak self] in self?.close() },
        reopener: { [weak self] in try? self?.open() }
    )

    /// Open an in-memory database for testing. Plaintext.
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
        OsaurusDatabaseHandle.deregister(name: "scheduler")
        queue.sync {
            stmtCache.clear()
            guard let connection = db else { return }
            try? executeRaw("PRAGMA optimize")
            sqlite3_close(connection)
            db = nil
        }
    }

    public var isOpen: Bool { queue.sync { db != nil } }

    private func openConnection() throws {
        let path = OsaurusPaths.schedulerDatabaseFile().path
        do {
            db = try OsaurusStorageOpener.open(path: path)
        } catch let error as EncryptedSQLiteError {
            throw SchedulerDatabaseError.failedToOpen(error.localizedDescription)
        }
    }

    // MARK: - Schema

    private func runMigrations() throws {
        let current = try getSchemaVersion()
        if current < 1 { try migrateToV1() }
    }

    private func getSchemaVersion() throws -> Int {
        var v = 0
        try executeRaw("PRAGMA user_version") { stmt in
            if sqlite3_step(stmt) == SQLITE_ROW {
                v = Int(sqlite3_column_int(stmt, 0))
            }
        }
        return v
    }

    private func setSchemaVersion(_ v: Int) throws {
        try executeRaw("PRAGMA user_version = \(v)")
    }

    private func migrateToV1() throws {
        try executeRaw(
            """
                CREATE TABLE IF NOT EXISTS agent_next_run (
                    agent_id          TEXT PRIMARY KEY,
                    scheduled_at      INTEGER NOT NULL,
                    instructions      TEXT NOT NULL,
                    context_views     TEXT NOT NULL DEFAULT '[]',
                    priority          TEXT NOT NULL DEFAULT 'normal',
                    on_miss           TEXT NOT NULL DEFAULT 'skip',
                    scheduled_by      TEXT NOT NULL,
                    scheduled_at_wall INTEGER NOT NULL
                )
            """
        )
        try executeRaw(
            "CREATE INDEX IF NOT EXISTS idx_next_run_scheduled_at ON agent_next_run(scheduled_at)"
        )

        try executeRaw(
            """
                CREATE TABLE IF NOT EXISTS agent_runs (
                    id                TEXT PRIMARY KEY,
                    agent_id          TEXT NOT NULL,
                    trigger_kind      TEXT NOT NULL,
                    trigger_payload   TEXT,
                    instructions      TEXT NOT NULL,
                    started_at        INTEGER NOT NULL,
                    ended_at          INTEGER,
                    status            TEXT NOT NULL,
                    tokens_in         INTEGER,
                    tokens_out        INTEGER,
                    cost_usd          REAL,
                    error             TEXT
                )
            """
        )
        try executeRaw(
            "CREATE INDEX IF NOT EXISTS idx_runs_agent_started ON agent_runs(agent_id, started_at DESC)"
        )
        try executeRaw(
            "CREATE INDEX IF NOT EXISTS idx_runs_started ON agent_runs(started_at DESC)"
        )

        try executeRaw(
            """
                CREATE TABLE IF NOT EXISTS agent_pause (
                    agent_id      TEXT PRIMARY KEY,
                    paused_until  INTEGER NOT NULL,
                    reason        TEXT
                )
            """
        )

        try setSchemaVersion(1)
    }

    // MARK: - agent_next_run

    /// Insert or replace the single next-run slot for `agentId`. Last
    /// write wins (spec §9.5). Returns the entry that was stored.
    @discardableResult
    public func upsertNextRun(_ entry: NextRunEntry) throws -> NextRunEntry {
        let viewsJSON = Self.jsonEncode(entry.contextViews) ?? "[]"
        try prepareAndExecute(
            """
                INSERT INTO agent_next_run
                    (agent_id, scheduled_at, instructions, context_views,
                     priority, on_miss, scheduled_by, scheduled_at_wall)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
                ON CONFLICT(agent_id) DO UPDATE SET
                    scheduled_at      = excluded.scheduled_at,
                    instructions      = excluded.instructions,
                    context_views     = excluded.context_views,
                    priority          = excluded.priority,
                    on_miss           = excluded.on_miss,
                    scheduled_by      = excluded.scheduled_by,
                    scheduled_at_wall = excluded.scheduled_at_wall
            """,
            bind: { stmt in
                Self.bindText(stmt, index: 1, value: entry.agentId.uuidString)
                sqlite3_bind_int64(stmt, 2, Int64(entry.scheduledAt.timeIntervalSince1970))
                Self.bindText(stmt, index: 3, value: entry.instructions)
                Self.bindText(stmt, index: 4, value: viewsJSON)
                Self.bindText(stmt, index: 5, value: entry.priority.rawValue)
                Self.bindText(stmt, index: 6, value: entry.onMiss.rawValue)
                Self.bindText(stmt, index: 7, value: entry.scheduledBy.rawValue)
                sqlite3_bind_int64(stmt, 8, Int64(entry.scheduledAtWall.timeIntervalSince1970))
            },
            process: { stmt in
                let step = sqlite3_step(stmt)
                guard step == SQLITE_DONE else {
                    throw SchedulerDatabaseError.failedToExecute(
                        "upsertNextRun: step returned \(step)"
                    )
                }
            }
        )
        return entry
    }

    public func nextRun(for agentId: UUID) throws -> NextRunEntry? {
        var entry: NextRunEntry?
        try prepareAndExecute(
            """
                SELECT scheduled_at, instructions, context_views,
                       priority, on_miss, scheduled_by, scheduled_at_wall
                FROM agent_next_run
                WHERE agent_id = ?1
            """,
            bind: { stmt in Self.bindText(stmt, index: 1, value: agentId.uuidString) },
            process: { stmt in
                if sqlite3_step(stmt) == SQLITE_ROW {
                    entry = Self.readNextRun(stmt: stmt, agentId: agentId)
                }
            }
        )
        return entry
    }

    /// All entries whose `scheduled_at <= now`, ordered by `scheduled_at ASC`.
    /// The scheduler loop calls this on every tick (spec §9.1) with a
    /// bounded `limit` for concurrency.
    public func dueNextRuns(asOf now: Date, limit: Int) throws -> [NextRunEntry] {
        var entries: [NextRunEntry] = []
        try prepareAndExecute(
            """
                SELECT agent_id, scheduled_at, instructions, context_views,
                       priority, on_miss, scheduled_by, scheduled_at_wall
                FROM agent_next_run
                WHERE scheduled_at <= ?1
                ORDER BY scheduled_at ASC
                LIMIT ?2
            """,
            bind: { stmt in
                sqlite3_bind_int64(stmt, 1, Int64(now.timeIntervalSince1970))
                sqlite3_bind_int(stmt, 2, Int32(max(limit, 1)))
            },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let raw = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
                    guard let id = UUID(uuidString: raw) else { continue }
                    entries.append(Self.readNextRun(stmt: stmt, agentId: id, agentIdColumn: 0))
                }
            }
        )
        return entries
    }

    public func clearNextRun(for agentId: UUID) throws {
        try prepareAndExecute(
            "DELETE FROM agent_next_run WHERE agent_id = ?1",
            bind: { stmt in Self.bindText(stmt, index: 1, value: agentId.uuidString) },
            process: { stmt in
                let step = sqlite3_step(stmt)
                guard step == SQLITE_DONE else {
                    throw SchedulerDatabaseError.failedToExecute(
                        "clearNextRun: step returned \(step)"
                    )
                }
            }
        )
    }

    // MARK: - agent_runs

    /// Insert a `running` row and return its id. Pair with `recordRunEnd`
    /// before the run finishes so the row reaches a terminal state.
    @discardableResult
    public func recordRunStart(
        agentId: UUID,
        triggerKind: AgentRunTriggerKind,
        triggerPayload: String? = nil,
        instructions: String,
        startedAt: Date = Date(),
        id: UUID = UUID()
    ) throws -> UUID {
        try prepareAndExecute(
            """
                INSERT INTO agent_runs
                    (id, agent_id, trigger_kind, trigger_payload, instructions,
                     started_at, status)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
            """,
            bind: { stmt in
                Self.bindText(stmt, index: 1, value: id.uuidString)
                Self.bindText(stmt, index: 2, value: agentId.uuidString)
                Self.bindText(stmt, index: 3, value: triggerKind.rawValue)
                Self.bindText(stmt, index: 4, value: triggerPayload)
                Self.bindText(stmt, index: 5, value: instructions)
                sqlite3_bind_int64(stmt, 6, Int64(startedAt.timeIntervalSince1970))
                Self.bindText(stmt, index: 7, value: AgentRunStatus.running.rawValue)
            },
            process: { stmt in
                let step = sqlite3_step(stmt)
                guard step == SQLITE_DONE else {
                    throw SchedulerDatabaseError.failedToExecute(
                        "recordRunStart: step returned \(step)"
                    )
                }
            }
        )
        return id
    }

    public func recordRunEnd(
        runId: UUID,
        status: AgentRunStatus,
        endedAt: Date = Date(),
        tokensIn: Int? = nil,
        tokensOut: Int? = nil,
        costUSD: Double? = nil,
        error: String? = nil
    ) throws {
        try prepareAndExecute(
            """
                UPDATE agent_runs SET
                    ended_at   = ?2,
                    status     = ?3,
                    tokens_in  = ?4,
                    tokens_out = ?5,
                    cost_usd   = ?6,
                    error      = ?7
                WHERE id = ?1
            """,
            bind: { stmt in
                Self.bindText(stmt, index: 1, value: runId.uuidString)
                sqlite3_bind_int64(stmt, 2, Int64(endedAt.timeIntervalSince1970))
                Self.bindText(stmt, index: 3, value: status.rawValue)
                Self.bindOptionalInt(stmt, index: 4, value: tokensIn)
                Self.bindOptionalInt(stmt, index: 5, value: tokensOut)
                Self.bindOptionalDouble(stmt, index: 6, value: costUSD)
                Self.bindText(stmt, index: 7, value: error)
            },
            process: { stmt in
                let step = sqlite3_step(stmt)
                guard step == SQLITE_DONE else {
                    throw SchedulerDatabaseError.failedToExecute(
                        "recordRunEnd: step returned \(step)"
                    )
                }
            }
        )
    }

    /// Reverse-chrono runs for one agent, optionally bounded above by
    /// `before`. The Activity tab consumes this.
    public func runs(
        agentId: UUID,
        limit: Int = 100,
        before: Date? = nil
    ) throws -> [AgentRunRecord] {
        var sql =
            """
                SELECT id, trigger_kind, trigger_payload, instructions,
                       started_at, ended_at, status, tokens_in, tokens_out,
                       cost_usd, error
                FROM agent_runs
                WHERE agent_id = ?1
            """
        if before != nil {
            sql += " AND started_at < ?2"
        }
        sql += " ORDER BY started_at DESC LIMIT ?\(before == nil ? 2 : 3)"

        var records: [AgentRunRecord] = []
        try prepareAndExecute(
            sql,
            bind: { stmt in
                Self.bindText(stmt, index: 1, value: agentId.uuidString)
                var idx: Int32 = 2
                if let before {
                    sqlite3_bind_int64(stmt, idx, Int64(before.timeIntervalSince1970))
                    idx += 1
                }
                sqlite3_bind_int(stmt, idx, Int32(max(limit, 1)))
            },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    if let record = Self.readRun(stmt, agentId: agentId) {
                        records.append(record)
                    }
                }
            }
        )
        return records
    }

    /// Count of runs in the rolling window ending `now` that we should
    /// charge against `daily_run_cap`. Per spec §16 Q3, only `success`
    /// and `error` runs count; clamped/cancelled scheduling attempts
    /// don't burn budget.
    public func successfulOrErroredRunCount(
        agentId: UUID,
        triggerKind: AgentRunTriggerKind,
        in window: TimeInterval,
        asOf now: Date = Date()
    ) throws -> Int {
        let since = now.addingTimeInterval(-window)
        var count = 0
        try prepareAndExecute(
            """
                SELECT COUNT(*) FROM agent_runs
                WHERE agent_id = ?1
                  AND trigger_kind = ?2
                  AND status IN ('success', 'error')
                  AND started_at >= ?3
            """,
            bind: { stmt in
                Self.bindText(stmt, index: 1, value: agentId.uuidString)
                Self.bindText(stmt, index: 2, value: triggerKind.rawValue)
                sqlite3_bind_int64(stmt, 3, Int64(since.timeIntervalSince1970))
            },
            process: { stmt in
                if sqlite3_step(stmt) == SQLITE_ROW {
                    count = Int(sqlite3_column_int(stmt, 0))
                }
            }
        )
        return count
    }

    // MARK: - agent_pause

    public func pause(agentId: UUID, until: Date, reason: String? = nil) throws {
        try prepareAndExecute(
            """
                INSERT INTO agent_pause (agent_id, paused_until, reason)
                VALUES (?1, ?2, ?3)
                ON CONFLICT(agent_id) DO UPDATE SET
                    paused_until = excluded.paused_until,
                    reason       = excluded.reason
            """,
            bind: { stmt in
                Self.bindText(stmt, index: 1, value: agentId.uuidString)
                sqlite3_bind_int64(stmt, 2, Int64(until.timeIntervalSince1970))
                Self.bindText(stmt, index: 3, value: reason)
            },
            process: { stmt in
                let step = sqlite3_step(stmt)
                guard step == SQLITE_DONE else {
                    throw SchedulerDatabaseError.failedToExecute(
                        "pause: step returned \(step)"
                    )
                }
            }
        )
    }

    public func unpause(agentId: UUID) throws {
        try prepareAndExecute(
            "DELETE FROM agent_pause WHERE agent_id = ?1",
            bind: { stmt in Self.bindText(stmt, index: 1, value: agentId.uuidString) },
            process: { stmt in
                let step = sqlite3_step(stmt)
                guard step == SQLITE_DONE else {
                    throw SchedulerDatabaseError.failedToExecute(
                        "unpause: step returned \(step)"
                    )
                }
            }
        )
    }

    public func pauseInfo(for agentId: UUID) throws -> AgentPauseRecord? {
        var record: AgentPauseRecord?
        try prepareAndExecute(
            "SELECT paused_until, reason FROM agent_pause WHERE agent_id = ?1",
            bind: { stmt in Self.bindText(stmt, index: 1, value: agentId.uuidString) },
            process: { stmt in
                if sqlite3_step(stmt) == SQLITE_ROW {
                    let until = Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 0)))
                    let reason = sqlite3_column_text(stmt, 1).map { String(cString: $0) }
                    record = AgentPauseRecord(
                        agentId: agentId,
                        pausedUntil: until,
                        reason: reason
                    )
                }
            }
        )
        return record
    }

    // MARK: - Cleanup

    /// Called when an agent is deleted (`AgentStore.delete`). Removes
    /// every row across the three tables.
    public func deleteAllForAgent(_ agentId: UUID) throws {
        try inTransaction { _ in
            try self.transactionalStep(
                "DELETE FROM agent_next_run WHERE agent_id = ?1"
            ) { stmt in
                Self.bindText(stmt, index: 1, value: agentId.uuidString)
            }
            try self.transactionalStep(
                "DELETE FROM agent_runs WHERE agent_id = ?1"
            ) { stmt in
                Self.bindText(stmt, index: 1, value: agentId.uuidString)
            }
            try self.transactionalStep(
                "DELETE FROM agent_pause WHERE agent_id = ?1"
            ) { stmt in
                Self.bindText(stmt, index: 1, value: agentId.uuidString)
            }
        }
    }

    // MARK: - Row decoders

    /// `agentId` is passed in explicitly because the row may have been
    /// read with `agent_id` as either the first or a later column.
    private static func readNextRun(
        stmt: OpaquePointer,
        agentId: UUID,
        agentIdColumn: Int? = nil
    ) -> NextRunEntry {
        // Column layout shifts based on whether agent_id is selected.
        let base = agentIdColumn == nil ? 0 : 1
        let scheduledAt = Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, Int32(base + 0))))
        let instructions = sqlite3_column_text(stmt, Int32(base + 1)).map { String(cString: $0) } ?? ""
        let viewsJSON = sqlite3_column_text(stmt, Int32(base + 2)).map { String(cString: $0) } ?? "[]"
        let priority = sqlite3_column_text(stmt, Int32(base + 3)).map { String(cString: $0) } ?? "normal"
        let onMiss = sqlite3_column_text(stmt, Int32(base + 4)).map { String(cString: $0) } ?? "skip"
        let scheduledBy = sqlite3_column_text(stmt, Int32(base + 5)).map { String(cString: $0) } ?? "system"
        let wall = Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, Int32(base + 6))))

        let views = Self.jsonDecode([String].self, from: viewsJSON) ?? []
        return NextRunEntry(
            agentId: agentId,
            scheduledAt: scheduledAt,
            instructions: instructions,
            contextViews: views,
            priority: NextRunPriority(rawValue: priority) ?? .normal,
            onMiss: NextRunOnMiss(rawValue: onMiss) ?? .skip,
            scheduledBy: NextRunScheduledBy(rawValue: scheduledBy) ?? .system,
            scheduledAtWall: wall
        )
    }

    private static func readRun(_ stmt: OpaquePointer, agentId: UUID) -> AgentRunRecord? {
        let idStr = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
        guard let runId = UUID(uuidString: idStr) else { return nil }
        let kindRaw = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
        let payload = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
        let instructions = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
        let startedAt = Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 4)))
        let endedAt: Date? =
            sqlite3_column_type(stmt, 5) == SQLITE_NULL
            ? nil : Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 5)))
        let statusRaw = sqlite3_column_text(stmt, 6).map { String(cString: $0) } ?? "running"
        let tokensIn: Int? = sqlite3_column_type(stmt, 7) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 7))
        let tokensOut: Int? = sqlite3_column_type(stmt, 8) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 8))
        let cost: Double? = sqlite3_column_type(stmt, 9) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 9)
        let error = sqlite3_column_text(stmt, 10).map { String(cString: $0) }

        return AgentRunRecord(
            id: runId,
            agentId: agentId,
            triggerKind: AgentRunTriggerKind(rawValue: kindRaw) ?? .user,
            triggerPayload: payload,
            instructions: instructions,
            startedAt: startedAt,
            endedAt: endedAt,
            status: AgentRunStatus(rawValue: statusRaw) ?? .running,
            tokensIn: tokensIn,
            tokensOut: tokensOut,
            costUSD: cost,
            error: error
        )
    }

    // MARK: - SQLite helpers (mirrors ChatHistoryDatabase)

    private static let SQLITE_TRANSIENT = unsafeBitCast(
        OpaquePointer(bitPattern: -1),
        to: sqlite3_destructor_type.self
    )

    private static func bindText(_ stmt: OpaquePointer, index: Int, value: String?) {
        if let value {
            sqlite3_bind_text(stmt, Int32(index), value, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, Int32(index))
        }
    }

    private static func bindOptionalInt(_ stmt: OpaquePointer, index: Int, value: Int?) {
        if let value {
            sqlite3_bind_int64(stmt, Int32(index), Int64(value))
        } else {
            sqlite3_bind_null(stmt, Int32(index))
        }
    }

    private static func bindOptionalDouble(_ stmt: OpaquePointer, index: Int, value: Double?) {
        if let value {
            sqlite3_bind_double(stmt, Int32(index), value)
        } else {
            sqlite3_bind_null(stmt, Int32(index))
        }
    }

    private static func jsonEncode<T: Encodable>(_ value: T) -> String? {
        guard let data = try? JSONEncoder().encode(value),
            let str = String(data: data, encoding: .utf8)
        else { return nil }
        return str
    }

    private static func jsonDecode<T: Decodable>(_ type: T.Type, from json: String) -> T? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func executeRaw(_ sql: String) throws {
        guard let connection = db else { throw SchedulerDatabaseError.notOpen }
        var errorMessage: UnsafeMutablePointer<Int8>?
        let result = sqlite3_exec(connection, sql, nil, nil, &errorMessage)
        if result != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? "Unknown error"
            sqlite3_free(errorMessage)
            throw SchedulerDatabaseError.failedToExecute(message)
        }
    }

    private func executeRaw(_ sql: String, handler: (OpaquePointer) throws -> Void) throws {
        guard let connection = db else { throw SchedulerDatabaseError.notOpen }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            throw SchedulerDatabaseError.failedToPrepare(String(cString: sqlite3_errmsg(connection)))
        }
        defer { sqlite3_finalize(s) }
        try handler(s)
    }

    private func prepareAndExecute(
        _ sql: String,
        bind: (OpaquePointer) -> Void,
        process: (OpaquePointer) throws -> Void
    ) throws {
        try queue.sync {
            guard let connection = db else { throw SchedulerDatabaseError.notOpen }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(connection, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
                throw SchedulerDatabaseError.failedToPrepare(String(cString: sqlite3_errmsg(connection)))
            }
            defer { sqlite3_finalize(s) }
            bind(s)
            try process(s)
        }
    }

    private func inTransaction<T>(_ operation: (OpaquePointer) throws -> T) throws -> T {
        try queue.sync {
            guard let connection = db else { throw SchedulerDatabaseError.notOpen }
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

    private func transactionalStep(_ sql: String, bind: (OpaquePointer) -> Void) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            throw SchedulerDatabaseError.failedToPrepare(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(s) }
        bind(s)
        guard sqlite3_step(s) == SQLITE_DONE else {
            throw SchedulerDatabaseError.failedToExecute(
                "transactionalStep: \(String(cString: sqlite3_errmsg(db)))"
            )
        }
    }
}
