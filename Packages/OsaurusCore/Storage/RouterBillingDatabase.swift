//
//  RouterBillingDatabase.swift
//  osaurus
//
//  Encrypted, on-device ledger of Osaurus Router billing events. Metadata
//  only — cost, token counts, status, and the rendered outcome, correlated to
//  a chat session + assistant turn. NEVER stores prompt or response text, is
//  never uploaded, and survives chat deletion (no FK to the chat-history DB) so
//  a user's "I was charged but saw nothing" report can be traced afterward.
//
//  WAL mode, serial queue, versioned migrations — follows MethodDatabase /
//  MemoryDatabase patterns and shares the storage key + SQLCipher posture.
//

import Foundation
import OsaurusSQLCipher

// MARK: - Errors

public enum RouterBillingDatabaseError: Error, LocalizedError {
    case failedToOpen(String)
    case failedToExecute(String)
    case failedToPrepare(String)
    case migrationFailed(String)
    case notOpen

    public var errorDescription: String? {
        switch self {
        case .failedToOpen(let m): return "Failed to open router billing database: \(m)"
        case .failedToExecute(let m): return "Failed to execute query: \(m)"
        case .failedToPrepare(let m): return "Failed to prepare statement: \(m)"
        case .migrationFailed(let m): return "Router billing migration failed: \(m)"
        case .notOpen: return "Router billing database is not open"
        }
    }
}

// MARK: - Model

/// How the billed turn ultimately rendered. Drives both the chat UI keep/notice
/// decision and the ledger row, so support can see whether a charge produced
/// anything visible. `pending` is written at the moment the charge lands and
/// finalized once the run finishes.
public enum RouterBillingOutcome: String, Codable, Sendable, CaseIterable {
    case pending
    case rendered
    case reasoningOnly
    case toolOnly
    case empty
    case error
    case cancelled

    /// Pure classification of how a billed turn ultimately rendered, shared by
    /// the chat keep/notice decision and the ledger's finalized row so support
    /// sees exactly what the user saw. Precedence (highest first): visible text
    /// > tool calls > reasoning-only > cancelled > error > genuinely empty.
    public static func classify(
        hasVisibleText: Bool,
        hasToolCalls: Bool,
        hasReasoning: Bool,
        wasCancelled: Bool,
        hadError: Bool
    ) -> RouterBillingOutcome {
        if hasVisibleText { return .rendered }
        if hasToolCalls { return .toolOnly }
        if hasReasoning { return .reasoningOnly }
        if wasCancelled { return .cancelled }
        if hadError { return .error }
        return .empty
    }
}

/// One metadata-only billing record. No prompt/response text by construction.
public struct RouterBillingEntry: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let requestId: String?
    public let createdAt: Date
    public let sessionId: String?
    public let turnId: String?
    public let model: String?
    public let tokenSource: String
    public let inputTokens: Int
    public let outputTokens: Int
    public let costMicro: String
    public let status: String
    public var outcome: RouterBillingOutcome
    public let appVersion: String?

    public init(
        id: String,
        requestId: String?,
        createdAt: Date,
        sessionId: String?,
        turnId: String?,
        model: String?,
        tokenSource: String,
        inputTokens: Int,
        outputTokens: Int,
        costMicro: String,
        status: String,
        outcome: RouterBillingOutcome,
        appVersion: String?
    ) {
        self.id = id
        self.requestId = requestId
        self.createdAt = createdAt
        self.sessionId = sessionId
        self.turnId = turnId
        self.model = model
        self.tokenSource = tokenSource
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.costMicro = costMicro
        self.status = status
        self.outcome = outcome
        self.appVersion = appVersion
    }
}

// MARK: - RouterBillingDatabase

public final class RouterBillingDatabase: @unchecked Sendable {
    public static let shared = RouterBillingDatabase()

    /// Highest schema version this build knows how to produce. Opening a DB
    /// stamped newer than this is refused (forward-version fail-fast).
    private static let latestSchemaVersion = 2

    /// Retention cap: keep at most this many rows, and drop anything older than
    /// `maxRetentionDays`. A billing ledger is metadata-only and tiny, but it's
    /// unbounded over a device's lifetime without a cap.
    public static let maxRows = 10_000
    public static let maxRetentionDays = 365

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "ai.osaurus.router-billing.database")

    public var isOpen: Bool {
        queue.sync { db != nil }
    }

    init() {}

    deinit { close() }

    // MARK: - Lifecycle

    public func open() throws {
        // See `ChatHistoryDatabase.open()` for the gate rationale.
        StorageMutationGate.blockingAwaitNotMutating()
        try queue.sync {
            guard db == nil else { return }
            OsaurusPaths.ensureExistsSilent(OsaurusPaths.billing())
            try openConnection()
            try runMigrations()
        }
        OsaurusDatabaseHandle.register(maintenanceHandle)
    }

    private lazy var maintenanceHandle = OsaurusDatabaseHandle(
        name: "router-billing",
        exec: { [weak self] sql in
            self?.queue.sync {
                guard self?.db != nil else { return }
                try? self?.executeRaw(sql)
            }
        },
        closer: { [weak self] in self?.close() },
        reopener: { [weak self] in try? self?.open() }
    )

    func openInMemory() throws {
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
        OsaurusDatabaseHandle.deregister(name: "router-billing")
        queue.sync {
            guard let connection = db else { return }
            try? executeRaw("PRAGMA optimize")
            sqlite3_close(connection)
            db = nil
        }
    }

    private func openConnection() throws {
        let path = OsaurusPaths.billingLedgerDatabaseFile().path
        do {
            db = try OsaurusStorageOpener.open(path: path)
        } catch let error as EncryptedSQLiteError {
            throw RouterBillingDatabaseError.failedToOpen(error.localizedDescription)
        }
    }

    // MARK: - Schema & Migrations

    private func runMigrations() throws {
        let currentVersion = try getSchemaVersion()
        // A database stamped by a newer build carries columns this build doesn't
        // understand; reading/writing it as the older schema would silently drop
        // forward-version data. Refuse instead — the ledger then fails closed and
        // the facade treats it as unavailable.
        guard currentVersion <= Self.latestSchemaVersion else {
            throw RouterBillingDatabaseError.migrationFailed(
                "on-disk schema v\(currentVersion) is newer than supported v\(Self.latestSchemaVersion)"
            )
        }
        do {
            if currentVersion < 1 { try migrateToV1() }
            if currentVersion < 2 { try migrateToV2() }
        } catch {
            throw RouterBillingDatabaseError.migrationFailed("v\(currentVersion + 1): \(error.localizedDescription)")
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

    private func setSchemaVersion(_ version: Int) throws {
        try executeRaw("PRAGMA user_version = \(version)")
    }

    private func migrateToV1() throws {
        // No FK to the chat-history DB on purpose: deleting a chat must NOT
        // delete its billing record (that's the whole point of a durable
        // ledger), and the two databases are independent files anyway.
        try executeRaw(
            """
                CREATE TABLE IF NOT EXISTS router_billing (
                    entry_id      TEXT PRIMARY KEY,
                    created_at    REAL NOT NULL,
                    session_id    TEXT,
                    turn_id       TEXT,
                    model         TEXT,
                    token_source  TEXT NOT NULL DEFAULT '',
                    input_tokens  INTEGER NOT NULL DEFAULT 0,
                    output_tokens INTEGER NOT NULL DEFAULT 0,
                    cost_micro    TEXT NOT NULL DEFAULT '0',
                    status        TEXT NOT NULL DEFAULT '',
                    outcome       TEXT NOT NULL DEFAULT 'pending',
                    app_version   TEXT
                )
            """
        )
        try executeRaw(
            "CREATE INDEX IF NOT EXISTS idx_router_billing_created ON router_billing(created_at DESC)"
        )
        try executeRaw(
            "CREATE INDEX IF NOT EXISTS idx_router_billing_turn ON router_billing(turn_id)"
        )
        try setSchemaVersion(1)
    }

    private func migrateToV2() throws {
        try executeRaw("ALTER TABLE router_billing ADD COLUMN request_id TEXT")
        try executeRaw(
            "CREATE INDEX IF NOT EXISTS idx_router_billing_request ON router_billing(request_id)"
        )
        try setSchemaVersion(2)
    }

    // MARK: - Raw execution

    private func executeRaw(_ sql: String) throws {
        guard let connection = db else { throw RouterBillingDatabaseError.notOpen }
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(connection, sql, nil, nil, &errorMessage)
        if result != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? "Unknown error"
            sqlite3_free(errorMessage)
            throw RouterBillingDatabaseError.failedToExecute(message)
        }
    }

    private func executeRaw(_ sql: String, handler: (OpaquePointer) throws -> Void) throws {
        guard let connection = db else { throw RouterBillingDatabaseError.notOpen }
        var stmt: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(connection, sql, -1, &stmt, nil)
        guard prepareResult == SQLITE_OK, let statement = stmt else {
            throw RouterBillingDatabaseError.failedToPrepare(String(cString: sqlite3_errmsg(connection)))
        }
        defer { sqlite3_finalize(statement) }
        try handler(statement)
    }

    private func prepareAndExecute(
        _ sql: String,
        bind: (OpaquePointer) -> Void,
        process: (OpaquePointer) throws -> Void
    ) throws {
        try queue.sync {
            guard let connection = db else { throw RouterBillingDatabaseError.notOpen }
            var stmt: OpaquePointer?
            let prepareResult = sqlite3_prepare_v2(connection, sql, -1, &stmt, nil)
            guard prepareResult == SQLITE_OK, let statement = stmt else {
                throw RouterBillingDatabaseError.failedToPrepare(String(cString: sqlite3_errmsg(connection)))
            }
            defer { sqlite3_finalize(statement) }
            bind(statement)
            try process(statement)
        }
    }

    private func executeUpdate(_ sql: String, bind: (OpaquePointer) -> Void) throws {
        try prepareAndExecute(sql, bind: bind) { stmt in
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw RouterBillingDatabaseError.failedToExecute("step failed")
            }
        }
    }

    // MARK: - CRUD

    private static let columns =
        "entry_id, request_id, created_at, session_id, turn_id, model, token_source, input_tokens, output_tokens, cost_micro, status, outcome, app_version"

    public func insert(_ entry: RouterBillingEntry) throws {
        try executeUpdate(
            """
            INSERT INTO router_billing (\(Self.columns))
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)
            ON CONFLICT(entry_id) DO UPDATE SET
                request_id    = excluded.request_id,
                created_at    = excluded.created_at,
                session_id    = excluded.session_id,
                turn_id       = excluded.turn_id,
                model         = excluded.model,
                token_source  = excluded.token_source,
                input_tokens  = excluded.input_tokens,
                output_tokens = excluded.output_tokens,
                cost_micro    = excluded.cost_micro,
                status        = excluded.status,
                outcome       = excluded.outcome,
                app_version   = excluded.app_version
            """
        ) { stmt in
            Self.bindText(stmt, index: 1, value: entry.id)
            Self.bindText(stmt, index: 2, value: entry.requestId)
            sqlite3_bind_double(stmt, 3, entry.createdAt.timeIntervalSince1970)
            Self.bindText(stmt, index: 4, value: entry.sessionId)
            Self.bindText(stmt, index: 5, value: entry.turnId)
            Self.bindText(stmt, index: 6, value: entry.model)
            Self.bindText(stmt, index: 7, value: entry.tokenSource)
            sqlite3_bind_int(stmt, 8, Int32(entry.inputTokens))
            sqlite3_bind_int(stmt, 9, Int32(entry.outputTokens))
            Self.bindText(stmt, index: 10, value: entry.costMicro)
            Self.bindText(stmt, index: 11, value: entry.status)
            Self.bindText(stmt, index: 12, value: entry.outcome.rawValue)
            Self.bindText(stmt, index: 13, value: entry.appVersion)
        }
    }

    /// Insert a billing entry, or update the existing row for the same router
    /// request id. This makes repeated summary frames / request replays
    /// idempotent at the local ledger layer while preserving finalized outcomes.
    public func upsertByRequestId(_ entry: RouterBillingEntry) throws -> RouterBillingEntry {
        guard let requestId = Self.normalizedRequestId(entry.requestId) else {
            try insert(entry)
            return entry
        }

        if let existing = try findByRequestId(requestId) {
            let merged = RouterBillingEntry(
                id: existing.id,
                requestId: requestId,
                createdAt: existing.createdAt,
                sessionId: entry.sessionId ?? existing.sessionId,
                turnId: entry.turnId ?? existing.turnId,
                model: entry.model ?? existing.model,
                tokenSource: entry.tokenSource,
                inputTokens: entry.inputTokens,
                outputTokens: entry.outputTokens,
                costMicro: entry.costMicro,
                status: entry.status,
                outcome: existing.outcome == .pending ? entry.outcome : existing.outcome,
                appVersion: entry.appVersion ?? existing.appVersion
            )
            try insert(merged)
            return merged
        }

        try insert(entry)
        return entry
    }

    public func updateOutcome(entryId: String, outcome: RouterBillingOutcome) throws {
        try executeUpdate("UPDATE router_billing SET outcome = ?1 WHERE entry_id = ?2") { stmt in
            Self.bindText(stmt, index: 1, value: outcome.rawValue)
            Self.bindText(stmt, index: 2, value: entryId)
        }
    }

    public func findByRequestId(_ requestId: String) throws -> RouterBillingEntry? {
        guard let normalized = Self.normalizedRequestId(requestId) else { return nil }
        var entry: RouterBillingEntry?
        try prepareAndExecute(
            "SELECT \(Self.columns) FROM router_billing WHERE request_id = ?1 ORDER BY created_at DESC LIMIT 1",
            bind: { stmt in
                Self.bindText(stmt, index: 1, value: normalized)
            },
            process: { stmt in
                if sqlite3_step(stmt) == SQLITE_ROW {
                    entry = Self.readEntry(from: stmt)
                }
            }
        )
        return entry
    }

    public func findByRequestIds(_ requestIds: [String]) throws -> [RouterBillingEntry] {
        let normalized = Array(Set(requestIds.compactMap(Self.normalizedRequestId))).sorted()
        guard !normalized.isEmpty else { return [] }

        var entries: [RouterBillingEntry] = []
        let placeholders = normalized.indices.map { "?\($0 + 1)" }.joined(separator: ", ")
        try prepareAndExecute(
            "SELECT \(Self.columns) FROM router_billing WHERE request_id IN (\(placeholders)) ORDER BY created_at DESC",
            bind: { stmt in
                for (index, requestId) in normalized.enumerated() {
                    Self.bindText(stmt, index: Int32(index + 1), value: requestId)
                }
            },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    entries.append(Self.readEntry(from: stmt))
                }
            }
        )
        return entries
    }

    public func recent(limit: Int, offset: Int = 0) throws -> [RouterBillingEntry] {
        var entries: [RouterBillingEntry] = []
        try prepareAndExecute(
            "SELECT \(Self.columns) FROM router_billing ORDER BY created_at DESC LIMIT ?1 OFFSET ?2",
            bind: { stmt in
                sqlite3_bind_int(stmt, 1, Int32(max(0, limit)))
                sqlite3_bind_int(stmt, 2, Int32(max(0, offset)))
            },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    entries.append(Self.readEntry(from: stmt))
                }
            }
        )
        return entries
    }

    /// Number of rows currently stored. Exposed for tests and diagnostics.
    public func count() throws -> Int {
        var n = 0
        try prepareAndExecute(
            "SELECT COUNT(*) FROM router_billing",
            bind: { _ in },
            process: { stmt in
                if sqlite3_step(stmt) == SQLITE_ROW { n = Int(sqlite3_column_int(stmt, 0)) }
            }
        )
        return n
    }

    /// Drop rows older than `maxRetentionDays` and trim to the newest
    /// `maxRows`. Cheap; intended to run once per launch (on open) and after
    /// large imports.
    public func pruneIfNeeded() throws {
        let cutoff = Date().addingTimeInterval(-Double(Self.maxRetentionDays) * 86_400)
            .timeIntervalSince1970
        try executeUpdate("DELETE FROM router_billing WHERE created_at < ?1") { stmt in
            sqlite3_bind_double(stmt, 1, cutoff)
        }
        // Keep only the newest `maxRows` by created_at.
        try executeUpdate(
            """
            DELETE FROM router_billing WHERE entry_id NOT IN (
                SELECT entry_id FROM router_billing ORDER BY created_at DESC LIMIT ?1
            )
            """
        ) { stmt in
            sqlite3_bind_int(stmt, 1, Int32(Self.maxRows))
        }
    }

    // MARK: - Row reader

    private static func readEntry(from stmt: OpaquePointer) -> RouterBillingEntry {
        RouterBillingEntry(
            id: String(cString: sqlite3_column_text(stmt, 0)),
            requestId: sqlite3_column_text(stmt, 1).map { String(cString: $0) },
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)),
            sessionId: sqlite3_column_text(stmt, 3).map { String(cString: $0) },
            turnId: sqlite3_column_text(stmt, 4).map { String(cString: $0) },
            model: sqlite3_column_text(stmt, 5).map { String(cString: $0) },
            tokenSource: sqlite3_column_text(stmt, 6).map { String(cString: $0) } ?? "",
            inputTokens: Int(sqlite3_column_int(stmt, 7)),
            outputTokens: Int(sqlite3_column_int(stmt, 8)),
            costMicro: sqlite3_column_text(stmt, 9).map { String(cString: $0) } ?? "0",
            status: sqlite3_column_text(stmt, 10).map { String(cString: $0) } ?? "",
            outcome: sqlite3_column_text(stmt, 11)
                .map { String(cString: $0) }
                .flatMap(RouterBillingOutcome.init(rawValue:)) ?? .pending,
            appVersion: sqlite3_column_text(stmt, 12).map { String(cString: $0) }
        )
    }

    private static func normalizedRequestId(_ requestId: String?) -> String? {
        guard let requestId else { return nil }
        let normalized = requestId.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}

// MARK: - SQLite helpers

private let routerBillingSqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

extension RouterBillingDatabase {
    static func bindText(_ stmt: OpaquePointer, index: Int32, value: String?) {
        if let value {
            sqlite3_bind_text(stmt, index, value, -1, routerBillingSqliteTransient)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }
}
