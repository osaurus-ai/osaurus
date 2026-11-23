//
//  TaskDatabase.swift
//  osaurus
//
//  Encrypted SQLite store for the task substrate
//  (`~/.osaurus/tasks/tasks.sqlite`): queues, tasks, the per-task journal
//  and foreground reservation history. Tasks can name client data in their
//  titles and errors, so the file follows chat history's storage rules:
//  SQLCipher at rest, the shared storage key, rekeyed on rotation.
//
//  Indexed columns serve the board and history filters; the full record is
//  the JSON column.
//
//  Migrations are additive only (new tables, columns, indexes): an older
//  build opens a newer file as-is (`user_version` ahead of it is left
//  alone), so nothing it reads may be renamed or dropped.
//

import Foundation
import OsaurusSQLCipher

public enum TaskDatabaseError: Error, LocalizedError {
    case failedToOpen(String)
    case failedToExecute(String)
    case failedToPrepare(String)
    case migrationFailed(String)
    case notOpen

    public var errorDescription: String? {
        switch self {
        case .failedToOpen(let m): return "Failed to open task database: \(m)"
        case .failedToExecute(let m): return "Failed to execute task query: \(m)"
        case .failedToPrepare(let m): return "Failed to prepare task statement: \(m)"
        case .migrationFailed(let m): return "Task database migration failed: \(m)"
        case .notOpen: return "Task database is not open"
        }
    }
}

/// Filter for task history reads.
public struct TaskQuery: Sendable, Equatable {
    public var queueId: UUID?
    public var states: [TaskState]?
    public var origin: TaskOrigin?
    public var subscriptionId: UUID?
    public var agentId: UUID?
    public var workflowID: UUID?
    public var parentId: UUID?
    public var originSessionId: UUID?
    public var since: Date?
    public var limit: Int

    public init(
        queueId: UUID? = nil, states: [TaskState]? = nil, origin: TaskOrigin? = nil, subscriptionId: UUID? = nil,
        agentId: UUID? = nil, workflowID: UUID? = nil, parentId: UUID? = nil, originSessionId: UUID? = nil,
        since: Date? = nil, limit: Int = 200
    ) {
        self.parentId = parentId
        self.originSessionId = originSessionId
        self.queueId = queueId
        self.states = states
        self.origin = origin
        self.subscriptionId = subscriptionId
        self.agentId = agentId
        self.workflowID = workflowID
        self.since = since
        self.limit = limit
    }

    public func matches(_ task: OsaurusTask) -> Bool {
        if let queueId, task.queueId != queueId { return false }
        if let states, !states.contains(task.state) { return false }
        if let origin, task.origin != origin { return false }
        if let subscriptionId, task.subscriptionId != subscriptionId { return false }
        if let agentId, task.agentId != agentId { return false }
        if let workflowID, task.work.workflowID != workflowID { return false }
        if let parentId, task.parentId != parentId { return false }
        if let originSessionId, task.originSessionId != originSessionId { return false }
        if let since, task.createdAt < since { return false }
        return true
    }
}

public final class TaskDatabase: @unchecked Sendable {
    public static let shared = TaskDatabase()

    private static let latestSchemaVersion = 3
    /// Terminal tasks older than this are pruned.
    static let retentionDays: Double = 30
    /// At most this many terminal tasks are kept (newest first), even
    /// within `retentionDays`.
    static let retentionRows = 20_000
    /// Journal rows kept per task: the first (how it started) and the newest.
    static let journalRowsPerTask = 1_000
    /// Newest reservation rows kept (every chat turn and API call adds one).
    static let reservationRows = 5_000

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "ai.osaurus.tasks.db")

    public var isOpen: Bool { queue.sync { db != nil } }

    init() {}

    deinit { close() }

    #if DEBUG
        /// Test hook: `open()` fails as if the storage key were missing.
        nonisolated(unsafe) var refusesOpenForTesting = false
    #endif

    public func open() throws {
        #if DEBUG
            if refusesOpenForTesting { throw TaskDatabaseError.failedToOpen("refused for testing") }
        #endif
        StorageMutationGate.blockingAwaitNotMutating()
        try queue.sync {
            guard db == nil else { return }
            OsaurusPaths.ensureExistsSilent(OsaurusPaths.tasks())
            do {
                db = try OsaurusStorageOpener.open(path: OsaurusPaths.tasksDatabaseFile().path, cacheTier: .cold)
                try runMigrations()
            } catch {
                if let connection = db {
                    sqlite3_close(connection)
                    db = nil
                }
                PersistenceHealth.shared.recordDatabaseOpenFailure(
                    subsystem: StorageRecoveryService.Store.tasks.rawValue, error: error,
                    path: OsaurusPaths.tasksDatabaseFile().path)
                if let error = error as? EncryptedSQLiteError {
                    throw TaskDatabaseError.failedToOpen(error.localizedDescription)
                }
                throw error
            }
        }
        OsaurusDatabaseHandle.register(maintenanceHandle)
    }

    private lazy var maintenanceHandle = OsaurusDatabaseHandle(
        name: "tasks",
        exec: { [weak self] sql in
            self?.queue.sync {
                guard self?.db != nil else { return }
                try? self?.executeRaw(sql)
            }
        },
        closer: { [weak self] in self?.close() },
        reopener: { [weak self] in try? self?.open() }
    )

    /// Plaintext in-memory database for tests.
    public func openInMemory() throws {
        try openPlaintext(path: ":memory:")
    }

    #if DEBUG
        /// Plaintext file an older build left behind (migration tests).
        func openPlaintextForTesting(path: String) throws {
            try openPlaintext(path: path)
        }
    #endif

    private func openPlaintext(path: String) throws {
        try queue.sync {
            guard db == nil else { return }
            db = try EncryptedSQLiteOpener.open(path: path, key: nil, applyPerfPragmas: false)
            try runMigrations()
        }
    }

    public func close() {
        OsaurusDatabaseHandle.deregister(name: "tasks")
        queue.sync {
            guard let connection = db else { return }
            sqlite3_close(connection)
            db = nil
        }
    }

    // MARK: - Schema

    private func runMigrations() throws {
        var version = 0
        try executeRaw("PRAGMA user_version") { stmt in
            if sqlite3_step(stmt) == SQLITE_ROW { version = Int(sqlite3_column_int(stmt, 0)) }
        }
        if version > Self.latestSchemaVersion { return }
        if version < 1 {
            try executeRaw("BEGIN TRANSACTION")
            do {
                try executeRaw(
                    """
                    CREATE TABLE IF NOT EXISTS task_queues (
                        id TEXT PRIMARY KEY,
                        slug TEXT NOT NULL UNIQUE,
                        is_system INTEGER NOT NULL DEFAULT 0,
                        created_at REAL NOT NULL,
                        record_json TEXT NOT NULL
                    )
                    """)
                try executeRaw(
                    """
                    CREATE TABLE IF NOT EXISTS tasks (
                        id TEXT PRIMARY KEY,
                        queue_id TEXT NOT NULL,
                        root_id TEXT NOT NULL,
                        parent_id TEXT,
                        subscription_id TEXT,
                        agent_id TEXT,
                        workflow_id TEXT,
                        origin TEXT NOT NULL,
                        state TEXT NOT NULL,
                        idempotency_key TEXT,
                        created_at REAL NOT NULL,
                        finished_at REAL,
                        record_json TEXT NOT NULL
                    )
                    """)
                try executeRaw("CREATE INDEX IF NOT EXISTS idx_tasks_created ON tasks(created_at DESC)")
                try executeRaw("CREATE INDEX IF NOT EXISTS idx_tasks_queue ON tasks(queue_id, created_at DESC)")
                try executeRaw("CREATE INDEX IF NOT EXISTS idx_tasks_state ON tasks(state)")
                try executeRaw(
                    "CREATE INDEX IF NOT EXISTS idx_tasks_subscription ON tasks(subscription_id, created_at DESC)")
                try executeRaw("CREATE INDEX IF NOT EXISTS idx_tasks_agent ON tasks(agent_id, created_at DESC)")
                try executeRaw("CREATE INDEX IF NOT EXISTS idx_tasks_workflow ON tasks(workflow_id, created_at DESC)")
                try executeRaw("CREATE INDEX IF NOT EXISTS idx_tasks_root ON tasks(root_id)")
                try executeRaw(
                    """
                    CREATE TABLE IF NOT EXISTS task_events (
                        task_id TEXT NOT NULL,
                        seq INTEGER NOT NULL,
                        at REAL NOT NULL,
                        kind TEXT NOT NULL,
                        record_json TEXT NOT NULL,
                        PRIMARY KEY (task_id, seq)
                    )
                    """)
                try executeRaw(
                    """
                    CREATE TABLE IF NOT EXISTS task_reservations (
                        id TEXT PRIMARY KEY,
                        started_at REAL NOT NULL,
                        record_json TEXT NOT NULL
                    )
                    """)
                try executeRaw(
                    "CREATE INDEX IF NOT EXISTS idx_task_reservations_started ON task_reservations(started_at DESC)")
                try executeRaw("CREATE TABLE IF NOT EXISTS task_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
                try executeRaw("PRAGMA user_version = 1")
                try executeRaw("COMMIT")
            } catch {
                try? executeRaw("ROLLBACK")
                throw TaskDatabaseError.migrationFailed("v1: \(error.localizedDescription)")
            }
        }
        if version < 2 {
            try executeRaw("BEGIN TRANSACTION")
            do {
                try executeRaw("CREATE INDEX IF NOT EXISTS idx_tasks_parent ON tasks(parent_id)")
                try executeRaw("CREATE INDEX IF NOT EXISTS idx_tasks_finished ON tasks(finished_at DESC)")
                try executeRaw(
                    "CREATE INDEX IF NOT EXISTS idx_tasks_idempotency ON tasks(idempotency_key, created_at DESC)")
                try executeRaw("CREATE INDEX IF NOT EXISTS idx_tasks_state_created ON tasks(state, created_at DESC)")
                try executeRaw("PRAGMA user_version = 2")
                try executeRaw("COMMIT")
            } catch {
                try? executeRaw("ROLLBACK")
                throw TaskDatabaseError.migrationFailed("v2: \(error.localizedDescription)")
            }
        }
        if version < 3 {
            try executeRaw("BEGIN TRANSACTION")
            do {
                // Stores converted by an older build lost `user_version`
                // and re-run this step with the column already there.
                if try !hasColumn("tasks", "origin_session_id") {
                    try executeRaw("ALTER TABLE tasks ADD COLUMN origin_session_id TEXT")
                }
                try executeRaw(
                    "CREATE INDEX IF NOT EXISTS idx_tasks_origin_session ON tasks(origin_session_id, created_at DESC)")
                try executeRaw("PRAGMA user_version = 3")
                try executeRaw("COMMIT")
            } catch {
                try? executeRaw("ROLLBACK")
                throw TaskDatabaseError.migrationFailed("v3: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Coding

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private static func json<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    // MARK: - Queues

    public func upsertQueue(_ taskQueue: TaskQueue) throws {
        let json = try Self.json(taskQueue)
        try run(
            """
            INSERT INTO task_queues (id, slug, is_system, created_at, record_json) VALUES (?1, ?2, ?3, ?4, ?5)
            ON CONFLICT(id) DO UPDATE SET slug = excluded.slug, record_json = excluded.record_json
            """
        ) { stmt in
            Self.bindText(stmt, 1, taskQueue.id.uuidString)
            Self.bindText(stmt, 2, taskQueue.slug)
            sqlite3_bind_int(stmt, 3, taskQueue.isSystem ? 1 : 0)
            sqlite3_bind_double(stmt, 4, taskQueue.createdAt.timeIntervalSince1970)
            Self.bindText(stmt, 5, json)
        }
    }

    public func deleteQueue(id: UUID) throws {
        try run("DELETE FROM task_queues WHERE id = ?1 AND is_system = 0") { Self.bindText($0, 1, id.uuidString) }
    }

    public func queues() throws -> [TaskQueue] {
        try decodeRows("SELECT record_json FROM task_queues ORDER BY is_system DESC, created_at", bind: { _ in })
    }

    // MARK: - Tasks

    public func upsertTasks(_ tasks: [OsaurusTask]) throws {
        guard !tasks.isEmpty else { return }
        let rows = try tasks.map { ($0, try Self.json($0)) }
        try transaction { try self.upsertTasksUnlocked(rows) }
    }

    /// Inserts imported history and marks the import done in one
    /// transaction: either both land or neither does.
    public func importTasks(_ tasks: [OsaurusTask], metaKey: String, metaValue: String) throws {
        let rows = try tasks.map { ($0, try Self.json($0)) }
        try transaction {
            try self.upsertTasksUnlocked(rows)
            try self.runUnlocked("INSERT OR REPLACE INTO task_meta (key, value) VALUES (?1, ?2)") { stmt in
                Self.bindText(stmt, 1, metaKey)
                Self.bindText(stmt, 2, metaValue)
            }
        }
    }

    private func upsertTasksUnlocked(_ rows: [(OsaurusTask, String)]) throws {
        for (task, json) in rows {
            try self.runUnlocked(
                """
                INSERT INTO tasks (id, queue_id, root_id, parent_id, subscription_id, agent_id, workflow_id,
                    origin, state, idempotency_key, created_at, finished_at, record_json, origin_session_id)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14)
                ON CONFLICT(id) DO UPDATE SET queue_id = excluded.queue_id, state = excluded.state,
                    finished_at = excluded.finished_at, record_json = excluded.record_json,
                    origin_session_id = excluded.origin_session_id
                """
            ) { stmt in
                Self.bindText(stmt, 1, task.id.uuidString)
                Self.bindText(stmt, 2, task.queueId.uuidString)
                Self.bindText(stmt, 3, task.rootId.uuidString)
                Self.bindOptional(stmt, 4, task.parentId?.uuidString)
                Self.bindOptional(stmt, 5, task.subscriptionId?.uuidString)
                Self.bindOptional(stmt, 6, task.agentId?.uuidString)
                Self.bindOptional(stmt, 7, task.work.workflowID?.uuidString)
                Self.bindText(stmt, 8, task.origin.rawValue)
                Self.bindText(stmt, 9, task.state.rawValue)
                Self.bindOptional(stmt, 10, task.idempotencyKey)
                sqlite3_bind_double(stmt, 11, task.createdAt.timeIntervalSince1970)
                if let finished = task.finishedAt {
                    sqlite3_bind_double(stmt, 12, finished.timeIntervalSince1970)
                } else {
                    sqlite3_bind_null(stmt, 12)
                }
                Self.bindText(stmt, 13, json)
                Self.bindOptional(stmt, 14, task.originSessionId?.uuidString)
            }
        }
    }

    public func task(id: UUID) throws -> OsaurusTask? {
        let rows: [OsaurusTask] = try decodeRows("SELECT record_json FROM tasks WHERE id = ?1") {
            Self.bindText($0, 1, id.uuidString)
        }
        return rows.first
    }

    public func task(idempotencyKey: String) throws -> OsaurusTask? {
        let rows: [OsaurusTask] = try decodeRows(
            "SELECT record_json FROM tasks WHERE idempotency_key = ?1 ORDER BY created_at DESC LIMIT 1"
        ) { Self.bindText($0, 1, idempotencyKey) }
        return rows.first
    }

    public func tasks(_ query: TaskQuery) throws -> [OsaurusTask] {
        let (whereSQL, bind, next) = Self.whereClause(query)
        let sql = "SELECT record_json FROM tasks\(whereSQL) ORDER BY created_at DESC LIMIT ?\(next)"
        return try decodeRows(sql) { stmt in
            bind(stmt)
            sqlite3_bind_int(stmt, next, Int32(max(1, query.limit)))
        }
    }

    public func count(_ query: TaskQuery) throws -> Int {
        let (whereSQL, bind, _) = Self.whereClause(query)
        var count = 0
        try prepare("SELECT COUNT(*) FROM tasks\(whereSQL)") { stmt in
            bind(stmt)
            if sqlite3_step(stmt) == SQLITE_ROW { count = Int(sqlite3_column_int(stmt, 0)) }
        }
        return count
    }

    private static func whereClause(_ query: TaskQuery) -> (String, (OpaquePointer) -> Void, Int32) {
        var clauses: [String] = []
        var binds: [(OpaquePointer, Int32) -> Void] = []
        func add(_ clause: String, _ bind: @escaping (OpaquePointer, Int32) -> Void) {
            clauses.append(clause.replacingOccurrences(of: "?", with: "?\(binds.count + 1)"))
            binds.append(bind)
        }
        if let id = query.queueId { add("queue_id = ?") { Self.bindText($0, $1, id.uuidString) } }
        if let origin = query.origin { add("origin = ?") { Self.bindText($0, $1, origin.rawValue) } }
        if let id = query.subscriptionId { add("subscription_id = ?") { Self.bindText($0, $1, id.uuidString) } }
        if let id = query.agentId { add("agent_id = ?") { Self.bindText($0, $1, id.uuidString) } }
        if let id = query.workflowID { add("workflow_id = ?") { Self.bindText($0, $1, id.uuidString) } }
        if let id = query.parentId { add("parent_id = ?") { Self.bindText($0, $1, id.uuidString) } }
        if let id = query.originSessionId {
            add("origin_session_id = ?") { Self.bindText($0, $1, id.uuidString) }
        }
        if let since = query.since {
            add("created_at >= ?") { sqlite3_bind_double($0, $1, since.timeIntervalSince1970) }
        }
        if let states = query.states, !states.isEmpty {
            let list = states.map { "'\($0.rawValue)'" }.joined(separator: ",")
            clauses.append("state IN (\(list))")
        }
        let whereSQL = clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")
        let bindAll: (OpaquePointer) -> Void = { stmt in
            for (index, bind) in binds.enumerated() { bind(stmt, Int32(index + 1)) }
        }
        return (whereSQL, bindAll, Int32(binds.count + 1))
    }

    /// Every chat session that started a stored task.
    public func originSessionIds() throws -> Set<UUID> {
        var ids: Set<UUID> = []
        try prepare("SELECT DISTINCT origin_session_id FROM tasks WHERE origin_session_id IS NOT NULL") { stmt in
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let text = sqlite3_column_text(stmt, 0), let id = UUID(uuidString: String(cString: text)) {
                    ids.insert(id)
                }
            }
        }
        return ids
    }

    /// Tasks the last launch left without a terminal state.
    public func openTasks() throws -> [OsaurusTask] {
        try decodeRows(
            "SELECT record_json FROM tasks WHERE state IN ('received', 'queued', 'admitted', 'running', 'waiting_user')",
            bind: { _ in })
    }

    public func deleteTasks(subscriptionId: UUID) throws {
        try transaction {
            try self.runUnlocked(
                "DELETE FROM task_events WHERE task_id IN (SELECT id FROM tasks WHERE subscription_id = ?1)"
            ) { Self.bindText($0, 1, subscriptionId.uuidString) }
            try self.runUnlocked("DELETE FROM tasks WHERE subscription_id = ?1") {
                Self.bindText($0, 1, subscriptionId.uuidString)
            }
        }
    }

    public func deleteTasks(agentId: UUID) throws {
        try transaction {
            try self.runUnlocked("DELETE FROM task_events WHERE task_id IN (SELECT id FROM tasks WHERE agent_id = ?1)") {
                Self.bindText($0, 1, agentId.uuidString)
            }
            try self.runUnlocked("DELETE FROM tasks WHERE agent_id = ?1") { Self.bindText($0, 1, agentId.uuidString) }
        }
    }

    /// Drops terminal tasks past the age and row limits, with their journal.
    public func prune(now: Date = Date()) throws {
        let cutoff = now.addingTimeInterval(-Self.retentionDays * 86_400).timeIntervalSince1970
        try transaction {
            try self.runUnlocked(
                """
                DELETE FROM tasks WHERE finished_at IS NOT NULL AND (finished_at < ?1 OR id NOT IN (
                    SELECT id FROM tasks WHERE finished_at IS NOT NULL ORDER BY finished_at DESC LIMIT ?2))
                """
            ) { stmt in
                sqlite3_bind_double(stmt, 1, cutoff)
                sqlite3_bind_int(stmt, 2, Int32(Self.retentionRows))
            }
            try self.runUnlocked("DELETE FROM task_events WHERE task_id NOT IN (SELECT id FROM tasks)") { _ in }
            try self.runUnlocked(
                """
                DELETE FROM task_reservations WHERE started_at < ?1 OR id NOT IN (
                    SELECT id FROM task_reservations ORDER BY started_at DESC LIMIT ?2)
                """
            ) { stmt in
                sqlite3_bind_double(stmt, 1, cutoff)
                sqlite3_bind_int(stmt, 2, Int32(Self.reservationRows))
            }
        }
    }

    // MARK: - Journal

    public func appendEvents(_ events: [TaskEvent]) throws {
        guard !events.isEmpty else { return }
        let rows = try events.map { ($0, try Self.json($0)) }
        try transaction {
            for (event, json) in rows {
                try self.runUnlocked(
                    "INSERT OR REPLACE INTO task_events (task_id, seq, at, kind, record_json) VALUES (?1, ?2, ?3, ?4, ?5)"
                ) { stmt in
                    Self.bindText(stmt, 1, event.taskId.uuidString)
                    sqlite3_bind_int(stmt, 2, Int32(event.seq))
                    sqlite3_bind_double(stmt, 3, event.at.timeIntervalSince1970)
                    Self.bindText(stmt, 4, event.kind.rawValue)
                    Self.bindText(stmt, 5, json)
                }
            }
            var newest: [UUID: Int] = [:]
            for (event, _) in rows { newest[event.taskId] = max(newest[event.taskId] ?? 0, event.seq) }
            for (taskId, seq) in newest where seq > Self.journalRowsPerTask {
                try self.runUnlocked("DELETE FROM task_events WHERE task_id = ?1 AND seq > 1 AND seq <= ?2") { stmt in
                    Self.bindText(stmt, 1, taskId.uuidString)
                    sqlite3_bind_int(stmt, 2, Int32(seq - Self.journalRowsPerTask + 1))
                }
            }
        }
    }

    public func events(taskId: UUID) throws -> [TaskEvent] {
        try decodeRows("SELECT record_json FROM task_events WHERE task_id = ?1 ORDER BY seq") {
            Self.bindText($0, 1, taskId.uuidString)
        }
    }

    /// The highest journal seq written for a task, so a relaunch continues it.
    public func lastSeq(taskId: UUID) throws -> Int {
        var seq = 0
        try prepare("SELECT MAX(seq) FROM task_events WHERE task_id = ?1") { stmt in
            Self.bindText(stmt, 1, taskId.uuidString)
            if sqlite3_step(stmt) == SQLITE_ROW { seq = Int(sqlite3_column_int(stmt, 0)) }
        }
        return seq
    }

    // MARK: - Reservations

    public func upsertReservation(_ reservation: ForegroundReservation) throws {
        let json = try Self.json(reservation)
        try run(
            """
            INSERT INTO task_reservations (id, started_at, record_json) VALUES (?1, ?2, ?3)
            ON CONFLICT(id) DO UPDATE SET record_json = excluded.record_json
            """
        ) { stmt in
            Self.bindText(stmt, 1, reservation.id.uuidString)
            sqlite3_bind_double(stmt, 2, reservation.startedAt.timeIntervalSince1970)
            Self.bindText(stmt, 3, json)
        }
    }

    public func reservations(limit: Int = 100) throws -> [ForegroundReservation] {
        try decodeRows("SELECT record_json FROM task_reservations ORDER BY started_at DESC LIMIT ?1") {
            sqlite3_bind_int($0, 1, Int32(limit))
        }
    }

    // MARK: - Meta

    public func meta(_ key: String) throws -> String? {
        var value: String?
        try prepare("SELECT value FROM task_meta WHERE key = ?1") { stmt in
            Self.bindText(stmt, 1, key)
            if sqlite3_step(stmt) == SQLITE_ROW, let text = sqlite3_column_text(stmt, 0) {
                value = String(cString: text)
            }
        }
        return value
    }

    // MARK: - SQLite plumbing

    private func decodeRows<T: Decodable>(_ sql: String, bind: (OpaquePointer) -> Void) throws -> [T] {
        var rows: [T] = []
        try prepare(sql) { stmt in
            bind(stmt)
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let text = sqlite3_column_text(stmt, 0) else { continue }
                if let row = try? Self.decoder.decode(T.self, from: Data(String(cString: text).utf8)) {
                    rows.append(row)
                }
            }
        }
        return rows
    }

    private func run(_ sql: String, bind: (OpaquePointer) -> Void) throws {
        try prepare(sql) { stmt in
            bind(stmt)
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw TaskDatabaseError.failedToExecute(sql) }
        }
    }

    /// Runs `body` inside one transaction on the database queue. `body`
    /// must use the `Unlocked` helpers.
    private func transaction(_ body: () throws -> Void) throws {
        dispatchPrecondition(condition: .notOnQueue(queue))
        try queue.sync {
            guard db != nil else { throw TaskDatabaseError.notOpen }
            try executeRaw("BEGIN TRANSACTION")
            do {
                try body()
                try executeRaw("COMMIT")
            } catch {
                try? executeRaw("ROLLBACK")
                throw error
            }
        }
    }

    private func runUnlocked(_ sql: String, bind: (OpaquePointer) -> Void) throws {
        guard let connection = db else { throw TaskDatabaseError.notOpen }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw TaskDatabaseError.failedToPrepare(String(cString: sqlite3_errmsg(connection)))
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw TaskDatabaseError.failedToExecute(sql) }
    }

    private func prepare(_ sql: String, process: (OpaquePointer) throws -> Void) throws {
        dispatchPrecondition(condition: .notOnQueue(queue))
        try queue.sync {
            guard let connection = db else { throw TaskDatabaseError.notOpen }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(connection, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                throw TaskDatabaseError.failedToPrepare(String(cString: sqlite3_errmsg(connection)))
            }
            defer { sqlite3_finalize(stmt) }
            try process(stmt)
        }
    }

    private func executeRaw(_ sql: String) throws {
        guard let connection = db else { throw TaskDatabaseError.notOpen }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(connection, sql, nil, nil, &err) != SQLITE_OK {
            let message = err.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(err)
            throw TaskDatabaseError.failedToExecute(message)
        }
    }

    private func executeRaw(_ sql: String, handler: (OpaquePointer) throws -> Void) throws {
        guard let connection = db else { throw TaskDatabaseError.notOpen }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw TaskDatabaseError.failedToPrepare(String(cString: sqlite3_errmsg(connection)))
        }
        defer { sqlite3_finalize(stmt) }
        try handler(stmt)
    }

    private func hasColumn(_ table: String, _ column: String) throws -> Bool {
        var found = false
        try executeRaw("PRAGMA table_info(\(table))") { stmt in
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let name = sqlite3_column_text(stmt, 1), String(cString: name) == column { found = true }
            }
        }
        return found
    }

    private static func bindText(_ stmt: OpaquePointer, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, value, -1, taskSQLiteTransient)
    }

    private static func bindOptional(_ stmt: OpaquePointer, _ index: Int32, _ value: String?) {
        if let value { bindText(stmt, index, value) } else { sqlite3_bind_null(stmt, index) }
    }
}

private let taskSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
