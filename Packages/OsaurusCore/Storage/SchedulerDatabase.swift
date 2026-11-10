//
//  SchedulerDatabase.swift
//  osaurus
//
//  Cross-agent pause state for the Agent DB + Self-Scheduling feature
//  (`agent_pause`, spec §4.2). One file at `~/.osaurus/scheduler.sqlite`,
//  encrypted via the same vendored SQLCipher + `StorageKeyManager` setup
//  the rest of the Osaurus stack uses.
//
//  `agent_next_run` and `agent_runs` are legacy: wake-ups are agent-owned
//  schedule automations and runs are tasks (docs/TASK_QUEUE.md). Both are
//  read once for the import and then retired (`retireLegacyTable`), which
//  leaves an empty copy for older builds.
//
//  Foreign keys to `agents(id)` are not declared because agents live in
//  JSON files. `deleteAllForAgent` cleans up when the user deletes an agent.
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

/// How a self-scheduled wake whose time passed while the app was closed is
/// handled (spec §9.2).
public enum NextRunOnMiss: String, Codable, Sendable, CaseIterable {
    /// Drop the run; its task records the skip.
    case skip
    /// Run immediately with the original instruction, even if late.
    case runOnce = "run_once"
    /// Run once per missed interval. A one-shot wake has one slot, so this
    /// runs it once.
    case runCatchup = "run_catchup"
}

/// Who set the next-run slot. The agent sees this on wake so it can react
/// to user edits (spec §9.5).
public enum NextRunScheduledBy: String, Codable, Sendable, CaseIterable {
    case agent
    case user
    case system
}

/// What woke the agent, as the legacy `agent_runs` rows recorded it.
public enum AgentRunTriggerKind: String, Codable, Sendable, CaseIterable {
    /// Self-scheduled wake via `schedule_next_run`.
    case schedule
    case recurringSchedule = "recurring_schedule"
    case watcher
    case webhook
    case email
    case automation
    case user
}

/// Terminal status written into a run trace (and the legacy `agent_runs`).
public enum AgentRunStatus: String, Codable, Sendable, CaseIterable {
    case running
    case success
    case error
    case cancelled
    case clamped
}

/// An agent's next self-scheduled wake. One per agent; writers (agent /
/// user / system) overwrite each other, last-write-wins (spec §9.5). Lives
/// on the agent-owned schedule automation (`SelfScheduleAutomations`).
public struct NextRunEntry: Codable, Sendable, Equatable {
    public var agentId: UUID
    public var scheduledAt: Date
    public var instructions: String
    /// Names of saved views the dispatcher should prefetch before the
    /// inference loop begins.
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

/// One legacy `agent_runs` row, read once for the task import.
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
            db = try OsaurusStorageOpener.open(path: path, cacheTier: .cold)
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
                CREATE TABLE IF NOT EXISTS agent_pause (
                    agent_id      TEXT PRIMARY KEY,
                    paused_until  INTEGER NOT NULL,
                    reason        TEXT
                )
            """
        )
        try setSchemaVersion(1)
    }

    // MARK: - Legacy import

    private func tableExists(_ name: String) throws -> Bool {
        var exists = false
        try prepareAndExecute(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?1",
            bind: { stmt in Self.bindText(stmt, index: 1, value: name) },
            process: { stmt in exists = sqlite3_step(stmt) == SQLITE_ROW }
        )
        return exists
    }

    /// Every slot left in the legacy `agent_next_run` table.
    public func legacyNextRuns() throws -> [NextRunEntry] {
        guard try tableExists("agent_next_run") else { return [] }
        var entries: [NextRunEntry] = []
        try prepareAndExecute(
            """
                SELECT agent_id, scheduled_at, instructions, context_views,
                       priority, on_miss, scheduled_by, scheduled_at_wall
                FROM agent_next_run
            """,
            bind: { _ in },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let raw = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
                    guard let id = UUID(uuidString: raw) else { continue }
                    entries.append(Self.readNextRun(stmt: stmt, agentId: id))
                }
            }
        )
        return entries
    }

    /// The newest `limit` legacy `agent_runs` rows, newest first.
    public func legacyRuns(limit: Int) throws -> [AgentRunRecord] {
        guard try tableExists("agent_runs") else { return [] }
        var records: [AgentRunRecord] = []
        try prepareAndExecute(
            """
                SELECT id, trigger_kind, trigger_payload, instructions,
                       started_at, ended_at, status, tokens_in, tokens_out,
                       cost_usd, error, agent_id
                FROM agent_runs
                ORDER BY started_at DESC LIMIT ?1
            """,
            bind: { stmt in sqlite3_bind_int(stmt, 1, Int32(max(limit, 1))) },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let raw = sqlite3_column_text(stmt, 11).map { String(cString: $0) } ?? ""
                    guard let agentId = UUID(uuidString: raw),
                        let record = Self.readRun(stmt, agentId: agentId)
                    else { continue }
                    records.append(record)
                }
            }
        )
        return records
    }

    /// The legacy tables as older builds created them. Older builds only
    /// create them in their v1 migration, which a v1 file never reruns.
    static let legacySchemas: [String: String] = [
        "agent_next_run": """
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
            """,
        "agent_runs": """
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
            """,
    ]

    /// Retires a legacy table once its rows were imported: renamed, not
    /// dropped, so the rows stay recoverable, and replaced by an empty
    /// table so an older build after a downgrade still finds it. Rows that
    /// build writes are imported again on the next upgrade.
    public func retireLegacyTable(_ name: String) throws {
        guard let schema = Self.legacySchemas[name], try tableExists(name) else { return }
        guard try rowCount(name) > 0 else { return }
        var target = "\(name)_legacy"
        if try tableExists(target) { target += "_\(Int(Date().timeIntervalSince1970))" }
        try queue.sync {
            stmtCache.clear()
            try executeRaw("BEGIN IMMEDIATE")
            do {
                try executeRaw("ALTER TABLE \(name) RENAME TO \(target)")
                try executeRaw(schema)
                try executeRaw("COMMIT")
            } catch {
                try? executeRaw("ROLLBACK")
                throw error
            }
        }
    }

    private func rowCount(_ table: String) throws -> Int {
        var count = 0
        try prepareAndExecute(
            "SELECT COUNT(*) FROM \(table)", bind: { _ in },
            process: { stmt in if sqlite3_step(stmt) == SQLITE_ROW { count = Int(sqlite3_column_int64(stmt, 0)) } })
        return count
    }

    #if DEBUG
        /// Test hook: rows in `table`, or nil when it does not exist.
        func rowCountForTesting(_ table: String) throws -> Int? {
            guard try tableExists(table) else { return nil }
            return try rowCount(table)
        }

        /// Test hook: a legacy `agent_runs` table holding `runs`.
        func seedLegacyRunsForTesting(_ runs: [AgentRunRecord]) throws {
            try queue.sync { try executeRaw(Self.legacySchemas["agent_runs"]!) }
            for run in runs {
                try prepareAndExecute(
                    """
                        INSERT INTO agent_runs (id, agent_id, trigger_kind, instructions, started_at,
                                                ended_at, status, tokens_in, error)
                        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
                    """,
                    bind: { stmt in
                        Self.bindText(stmt, index: 1, value: run.id.uuidString)
                        Self.bindText(stmt, index: 2, value: run.agentId.uuidString)
                        Self.bindText(stmt, index: 3, value: run.triggerKind.rawValue)
                        Self.bindText(stmt, index: 4, value: run.instructions)
                        sqlite3_bind_int64(stmt, 5, Int64(run.startedAt.timeIntervalSince1970))
                        if let ended = run.endedAt {
                            sqlite3_bind_int64(stmt, 6, Int64(ended.timeIntervalSince1970))
                        } else {
                            sqlite3_bind_null(stmt, 6)
                        }
                        Self.bindText(stmt, index: 7, value: run.status.rawValue)
                        if let tokens = run.tokensIn {
                            sqlite3_bind_int(stmt, 8, Int32(tokens))
                        } else {
                            sqlite3_bind_null(stmt, 8)
                        }
                        Self.bindText(stmt, index: 9, value: run.error)
                    },
                    process: { stmt in _ = sqlite3_step(stmt) }
                )
            }
        }
    #endif

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

    /// Called when an agent is deleted (`AgentStore.delete`).
    public func deleteAllForAgent(_ agentId: UUID) throws {
        try inTransaction { _ in
            try self.transactionalStep(
                "DELETE FROM agent_pause WHERE agent_id = ?1"
            ) { stmt in
                Self.bindText(stmt, index: 1, value: agentId.uuidString)
            }
        }
    }

    // MARK: - Row decoders

    private static func readNextRun(stmt: OpaquePointer, agentId: UUID) -> NextRunEntry {
        let scheduledAt = Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 1)))
        let instructions = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
        let viewsJSON = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? "[]"
        let priority = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? "normal"
        let onMiss = sqlite3_column_text(stmt, 5).map { String(cString: $0) } ?? "skip"
        let scheduledBy = sqlite3_column_text(stmt, 6).map { String(cString: $0) } ?? "system"
        let wall = Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 7)))

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
