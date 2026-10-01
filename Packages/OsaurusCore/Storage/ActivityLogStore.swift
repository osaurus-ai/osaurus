//
//  ActivityLogStore.swift
//  osaurus
//
//  Persisted, append-only, hash-chained activity log behind Insights.
//  One SQLite database at `~/.osaurus/activity/activity.sqlite` (opened
//  through `OsaurusStorageOpener`, so it follows the user's storage
//  encryption policy like every other store) plus an `activity.head`
//  sidecar holding the last `seq:hash` so tail truncation is detectable.
//
//  Each row's `hash` is `SHA-256(prevHash || "\n" || payload)` where
//  `payload` is the canonical JSON of the record (with `seq` and
//  `prevHash` set, `hash` nil). `verify()` walks the chain from the
//  pruning anchor and reports the first break. Tamper-EVIDENT, not
//  tamper-proof: an actor with write access to the home directory can
//  rewrite the whole chain. It defends against casual edits, partial
//  deletion, and reordering, and gives an exportable, independently
//  checkable record of what this Mac observed.
//
//  Retention: `prune(olderThan:)` removes a contiguous prefix of rows and
//  moves the chain anchor forward so the remaining chain still verifies.
//  `clear()` does the same for every row and then appends a `system`
//  tombstone so the clear itself is on the record.
//

import CryptoKit
import Foundation
import OsaurusSQLCipher

public enum ActivityLogStoreError: Error, LocalizedError {
    case failedToOpen(String)
    case failedToExecute(String)
    case failedToPrepare(String)
    case migrationFailed(String)
    case encodingFailed
    case notOpen

    public var errorDescription: String? {
        switch self {
        case .failedToOpen(let m): return "Failed to open activity log: \(m)"
        case .failedToExecute(let m): return "Failed to execute activity log query: \(m)"
        case .failedToPrepare(let m): return "Failed to prepare activity log statement: \(m)"
        case .migrationFailed(let m): return "Activity log migration failed: \(m)"
        case .encodingFailed: return "Failed to encode activity log record"
        case .notOpen: return "Activity log is not open"
        }
    }
}

public final class ActivityLogStore: @unchecked Sendable {
    public static let shared = ActivityLogStore()

    static let latestSchemaVersion = 1
    static let genesisHash = String(repeating: "0", count: 64)

    /// Clip for `EgressInfo.details` values so a runaway caller can't bloat
    /// the indexed row (bodies live in the payload and are clipped upstream).
    static let maxDetailValueLength = 2_048

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "ai.osaurus.activity-log.database")
    /// Cached chain tail so appends don't re-read the last row.
    private var tail: (seq: Int, hash: String)?
    /// nil for in-memory stores (tests); the sidecar is then kept in `memoryHead`.
    private var headFileURL: URL?
    private var memoryHead: (seq: Int, hash: String)?

    public var isOpen: Bool { queue.sync { db != nil } }

    init() {}
    deinit { close() }

    // MARK: - Canonical coding

    static let canonicalEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .millisecondsSince1970
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .millisecondsSince1970
        return d
    }()

    // MARK: - Lifecycle

    public func open() throws {
        StorageMutationGate.blockingAwaitNotMutating()
        try queue.sync {
            guard db == nil else { return }
            OsaurusPaths.ensureExistsSilent(OsaurusPaths.activity())
            let path = OsaurusPaths.activityLogDatabaseFile().path
            do {
                db = try OsaurusStorageOpener.open(path: path)
            } catch let error as EncryptedSQLiteError {
                throw ActivityLogStoreError.failedToOpen(error.localizedDescription)
            }
            headFileURL = OsaurusPaths.activityLogHeadFile()
            do {
                try runMigrations()
            } catch {
                if let connection = db {
                    sqlite3_close(connection)
                    db = nil
                }
                PersistenceHealth.shared.recordDatabaseOpenFailure(
                    subsystem: StorageRecoveryService.Store.activityLog.rawValue,
                    error: error,
                    path: path
                )
                throw error
            }
            tail = nil
            mismatchAtOpen = try headMismatch()
        }
        OsaurusDatabaseHandle.register(maintenanceHandle)
        // Chain-of-custody: the sidecar head disagreed with the database at
        // open (crash between insert and head write, restored backup, or
        // tampering). Put that fact on the chain itself — the append also
        // rewrites the head, so later verifies pass, but the discrepancy
        // and both sequence numbers stay on record.
        if let mismatch = mismatchAtOpen {
            mismatchAtOpen = nil
            _ = try? appendSystemEvent(
                "recovered",
                details: [
                    "expected_seq": String(mismatch.expectedSeq),
                    "found_seq": String(mismatch.foundSeq),
                    "expected_hash": mismatch.expectedHash ?? "",
                    "found_hash": mismatch.foundHash,
                ]
            )
        }
    }

    /// Pending open-time head/database discrepancy, consumed by `open()`.
    private var mismatchAtOpen: HeadMismatch?

    struct HeadMismatch: Sendable, Equatable {
        /// Sequence the sidecar head file claimed (0 when it was missing).
        var expectedSeq: Int
        var expectedHash: String?
        /// Sequence the database actually ends at.
        var foundSeq: Int
        var foundHash: String
    }

    /// Compare the sidecar head to the database tail. Must run on `queue`.
    /// A missing head over an empty database is a fresh install, not a
    /// mismatch.
    private func headMismatch() throws -> HeadMismatch? {
        let tail = try currentTail()
        guard let head = readHead() else {
            var count = 0
            try executeRaw("SELECT COUNT(*) FROM activity") { stmt in
                if sqlite3_step(stmt) == SQLITE_ROW { count = Int(sqlite3_column_int(stmt, 0)) }
            }
            guard count > 0 else { return nil }
            return HeadMismatch(expectedSeq: 0, expectedHash: nil, foundSeq: tail.seq, foundHash: tail.hash)
        }
        guard head.seq != tail.seq || head.hash != tail.hash else { return nil }
        return HeadMismatch(expectedSeq: head.seq, expectedHash: head.hash, foundSeq: tail.seq, foundHash: tail.hash)
    }

    /// Test hook: the discrepancy `open()` would record for the current
    /// head/database pair, without recording it.
    func pendingHeadMismatchForTesting() throws -> HeadMismatch? {
        try queue.sync {
            guard db != nil else { throw ActivityLogStoreError.notOpen }
            tail = nil
            return try headMismatch()
        }
    }

    /// Plaintext in-memory store for tests.
    func openInMemory() throws {
        try queue.sync {
            guard db == nil else { return }
            db = try EncryptedSQLiteOpener.open(path: ":memory:", key: nil, applyPerfPragmas: false)
            headFileURL = nil
            memoryHead = nil
            try runMigrations()
            tail = nil
        }
    }

    /// Test hook: raw SQL against the open connection (tamper simulation).
    func executeForTesting(_ sql: String) throws {
        try queue.sync {
            try executeRaw(sql)
            tail = nil
        }
    }

    public func close() {
        OsaurusDatabaseHandle.deregister(name: "activity-log")
        queue.sync {
            guard let connection = db else { return }
            try? executeRaw("PRAGMA optimize")
            sqlite3_close(connection)
            db = nil
            tail = nil
        }
    }

    private lazy var maintenanceHandle = OsaurusDatabaseHandle(
        name: "activity-log",
        exec: { [weak self] sql in
            self?.queue.sync {
                guard self?.db != nil else { return }
                try? self?.executeRaw(sql)
            }
        },
        closer: { [weak self] in self?.close() },
        reopener: { [weak self] in try? self?.open() }
    )

    // MARK: - Schema

    private func runMigrations() throws {
        let current = try schemaVersion()
        guard current <= Self.latestSchemaVersion else {
            throw ActivityLogStoreError.migrationFailed(
                "on-disk schema v\(current) is newer than supported v\(Self.latestSchemaVersion)"
            )
        }
        if current < 1 { try migrateToV1() }
    }

    private func schemaVersion() throws -> Int {
        var version = 0
        try executeRaw("PRAGMA user_version") { stmt in
            if sqlite3_step(stmt) == SQLITE_ROW { version = Int(sqlite3_column_int(stmt, 0)) }
        }
        return version
    }

    private func migrateToV1() throws {
        try executeRaw(
            """
            CREATE TABLE IF NOT EXISTS activity (
                seq                    INTEGER PRIMARY KEY AUTOINCREMENT,
                id                     TEXT NOT NULL UNIQUE,
                ts_ms                  INTEGER NOT NULL,
                category               TEXT NOT NULL,
                locality               TEXT NOT NULL,
                source                 TEXT NOT NULL,
                method                 TEXT NOT NULL,
                path                   TEXT NOT NULL,
                status                 INTEGER NOT NULL,
                is_error               INTEGER NOT NULL DEFAULT 0,
                duration_ms            REAL NOT NULL,
                model                  TEXT,
                provider_id            TEXT,
                destination_host       TEXT,
                destination_label      TEXT,
                transport              TEXT,
                mode                   TEXT,
                agent_id               TEXT,
                agent_name             TEXT,
                session_id             TEXT,
                turn_id                TEXT,
                request_id             TEXT,
                plugin_id              TEXT,
                access_key_id          TEXT,
                audience               TEXT,
                input_tokens           INTEGER,
                output_tokens          INTEGER,
                tokens_per_second      REAL,
                bytes_sent             INTEGER,
                bytes_received         INTEGER,
                privacy_filter_applied INTEGER NOT NULL DEFAULT 0,
                redacted_count         INTEGER,
                finish_reason          TEXT,
                error_message          TEXT,
                title                  TEXT NOT NULL,
                payload                BLOB NOT NULL,
                prev_hash              TEXT NOT NULL,
                hash                   TEXT NOT NULL
            )
            """
        )
        for index in [
            "CREATE INDEX IF NOT EXISTS idx_activity_ts ON activity(ts_ms DESC, seq DESC)",
            "CREATE INDEX IF NOT EXISTS idx_activity_category ON activity(category)",
            "CREATE INDEX IF NOT EXISTS idx_activity_locality ON activity(locality)",
            "CREATE INDEX IF NOT EXISTS idx_activity_source ON activity(source)",
            "CREATE INDEX IF NOT EXISTS idx_activity_turn ON activity(turn_id)",
            "CREATE INDEX IF NOT EXISTS idx_activity_request ON activity(request_id)",
            "CREATE INDEX IF NOT EXISTS idx_activity_provider ON activity(provider_id)",
            "CREATE INDEX IF NOT EXISTS idx_activity_access_key ON activity(access_key_id)",
            "CREATE INDEX IF NOT EXISTS idx_activity_audience ON activity(audience)",
            "CREATE INDEX IF NOT EXISTS idx_activity_destination ON activity(destination_host)",
            "CREATE INDEX IF NOT EXISTS idx_activity_model ON activity(model)",
            "CREATE INDEX IF NOT EXISTS idx_activity_agent ON activity(agent_id)",
        ] {
            try executeRaw(index)
        }
        try executeRaw(
            """
            CREATE TABLE IF NOT EXISTS meta (
                key   TEXT PRIMARY KEY,
                value TEXT NOT NULL
            )
            """
        )
        try executeRaw(
            "INSERT OR IGNORE INTO meta(key, value) VALUES ('anchor_seq', '0'), ('anchor_hash', '\(Self.genesisHash)')"
        )
        try executeRaw("PRAGMA user_version = 1")
    }

    // MARK: - Append

    /// Persist one record, assigning `seq`, `prevHash` and `hash`. Returns
    /// the chained copy. Serialised on the store queue so the chain is
    /// consistent regardless of caller interleaving.
    @discardableResult
    func append(_ input: RequestLog) throws -> RequestLog {
        try queue.sync {
            guard db != nil else { throw ActivityLogStoreError.notOpen }
            let tail = try currentTail()
            var record = Self.boundedDetails(input)
            record.seq = tail.seq + 1
            record.prevHash = tail.hash
            record.hash = nil
            guard let payload = try? Self.canonicalEncoder.encode(record) else {
                throw ActivityLogStoreError.encodingFailed
            }
            let hash = Self.hash(prevHash: tail.hash, payload: payload)
            record.hash = hash
            try insertRow(record, payload: payload)
            self.tail = (record.seq!, hash)
            try writeHead(seq: record.seq!, hash: hash)
            return record
        }
    }

    private func insertRow(_ r: RequestLog, payload: Data) throws {
        let sql = """
            INSERT INTO activity (
                seq, id, ts_ms, category, locality, source, method, path, status, is_error, duration_ms,
                model, provider_id, destination_host, destination_label, transport, mode,
                agent_id, agent_name, session_id, turn_id, request_id, plugin_id, access_key_id, audience,
                input_tokens, output_tokens, tokens_per_second, bytes_sent, bytes_received,
                privacy_filter_applied, redacted_count, finish_reason, error_message, title,
                payload, prev_hash, hash
            ) VALUES (
                ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11,
                ?12, ?13, ?14, ?15, ?16, ?17,
                ?18, ?19, ?20, ?21, ?22, ?23, ?24, ?25,
                ?26, ?27, ?28, ?29, ?30,
                ?31, ?32, ?33, ?34, ?35,
                ?36, ?37, ?38
            )
            """
        try executeUpdate(sql) { stmt in
            sqlite3_bind_int64(stmt, 1, Int64(r.seq ?? 0))
            Self.bindText(stmt, 2, r.id.uuidString)
            sqlite3_bind_int64(stmt, 3, Int64((r.timestamp.timeIntervalSince1970 * 1000).rounded()))
            Self.bindText(stmt, 4, r.category.rawValue)
            Self.bindText(stmt, 5, r.locality.rawValue)
            Self.bindText(stmt, 6, r.source.rawValue)
            Self.bindText(stmt, 7, r.method)
            Self.bindText(stmt, 8, r.path)
            sqlite3_bind_int(stmt, 9, Int32(clamping: r.statusCode))
            sqlite3_bind_int(stmt, 10, r.isError ? 1 : 0)
            sqlite3_bind_double(stmt, 11, r.durationMs)
            Self.bindText(stmt, 12, r.model)
            Self.bindText(stmt, 13, r.connection?.providerId?.uuidString)
            let host = r.egress?.destinationHost ?? EgressInfo.host(from: r.connection?.remoteEndpoint)
            Self.bindText(stmt, 14, r.locality == .remote ? host : nil)
            Self.bindText(stmt, 15, r.egress?.destinationLabel)
            Self.bindText(stmt, 16, r.connection?.transport?.rawValue)
            Self.bindText(stmt, 17, r.connection?.mode?.rawValue)
            Self.bindText(stmt, 18, r.agentId?.uuidString)
            Self.bindText(stmt, 19, r.agentName)
            Self.bindText(stmt, 20, r.sessionId?.uuidString)
            Self.bindText(stmt, 21, r.turnId?.uuidString)
            Self.bindText(stmt, 22, r.requestId)
            Self.bindText(stmt, 23, r.pluginId)
            Self.bindText(stmt, 24, r.connection?.accessKeyId)
            Self.bindText(stmt, 25, r.connection?.audience)
            Self.bindInt(stmt, 26, r.inputTokens)
            Self.bindInt(stmt, 27, r.outputTokens)
            if let tps = r.tokensPerSecond { sqlite3_bind_double(stmt, 28, tps) } else { sqlite3_bind_null(stmt, 28) }
            Self.bindInt(stmt, 29, r.egress?.bytesSent)
            Self.bindInt(stmt, 30, r.egress?.bytesReceived)
            sqlite3_bind_int(stmt, 31, (r.egress?.privacyFilterApplied ?? false) ? 1 : 0)
            Self.bindInt(stmt, 32, r.egress?.redactedSpanCount)
            Self.bindText(stmt, 33, r.finishReason?.rawValue)
            Self.bindText(stmt, 34, r.errorMessage)
            Self.bindText(stmt, 35, r.title)
            payload.withUnsafeBytes { buf in
                _ = sqlite3_bind_blob(stmt, 36, buf.baseAddress, Int32(buf.count), activityLogSqliteTransient)
            }
            Self.bindText(stmt, 37, r.prevHash ?? Self.genesisHash)
            Self.bindText(stmt, 38, r.hash ?? "")
        }
    }

    private static func boundedDetails(_ log: RequestLog) -> RequestLog {
        guard var egress = log.egress, !egress.details.isEmpty else { return log }
        var out: [String: String] = [:]
        for (key, value) in egress.details.sorted(by: { $0.key < $1.key }).prefix(32) {
            out[String(key.prefix(64))] = String(value.prefix(maxDetailValueLength))
        }
        egress.details = out
        return RequestLog(
            id: log.id, timestamp: log.timestamp, source: log.source, turnId: log.turnId,
            requestId: log.requestId, method: log.method, path: log.path, statusCode: log.statusCode,
            durationMs: log.durationMs, requestBody: log.requestBody, responseBody: log.responseBody,
            userAgent: log.userAgent, pluginId: log.pluginId, model: log.model,
            inputTokens: log.inputTokens, outputTokens: log.outputTokens, temperature: log.temperature,
            maxTokens: log.maxTokens, toolCalls: log.toolCalls, finishReason: log.finishReason,
            errorMessage: log.errorMessage, wireRequestBody: log.wireRequestBody,
            wireResponseBody: log.wireResponseBody, connection: log.connection,
            category: log.category, locality: log.locality, egress: egress, agentId: log.agentId,
            agentName: log.agentName, sessionId: log.sessionId, clientIP: log.clientIP
        )
    }

    // MARK: - Chain tail / anchor / head

    private func currentTail() throws -> (seq: Int, hash: String) {
        if let tail { return tail }
        var found: (Int, String)?
        try executeRaw("SELECT seq, hash FROM activity ORDER BY seq DESC LIMIT 1") { stmt in
            if sqlite3_step(stmt) == SQLITE_ROW {
                found = (Int(sqlite3_column_int64(stmt, 0)), String(cString: sqlite3_column_text(stmt, 1)))
            }
        }
        let resolved = try found ?? anchor()
        tail = resolved
        return resolved
    }

    private func anchor() throws -> (seq: Int, hash: String) {
        var seq = 0
        var hash = Self.genesisHash
        try executeRaw("SELECT key, value FROM meta WHERE key IN ('anchor_seq', 'anchor_hash')") { stmt in
            while sqlite3_step(stmt) == SQLITE_ROW {
                let key = String(cString: sqlite3_column_text(stmt, 0))
                let value = String(cString: sqlite3_column_text(stmt, 1))
                if key == "anchor_seq" { seq = Int(value) ?? 0 }
                if key == "anchor_hash" { hash = value }
            }
        }
        return (seq, hash)
    }

    private func setAnchor(seq: Int, hash: String) throws {
        try executeUpdate("INSERT OR REPLACE INTO meta(key, value) VALUES ('anchor_seq', ?1)") { stmt in
            Self.bindText(stmt, 1, String(seq))
        }
        try executeUpdate("INSERT OR REPLACE INTO meta(key, value) VALUES ('anchor_hash', ?1)") { stmt in
            Self.bindText(stmt, 1, hash)
        }
    }

    private func writeHead(seq: Int, hash: String) throws {
        guard let headFileURL else {
            memoryHead = (seq, hash)
            return
        }
        try Data("\(seq):\(hash)\n".utf8).write(to: headFileURL, options: [.atomic])
    }

    private func readHead() -> (seq: Int, hash: String)? {
        guard let headFileURL else { return memoryHead }
        guard let data = try? Data(contentsOf: headFileURL) else { return nil }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = text.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let seq = Int(parts[0]), parts[1].count == 64 else { return nil }
        return (seq, parts[1])
    }

    static func hash(prevHash: String, payload: Data) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(prevHash.utf8))
        hasher.update(data: Data("\n".utf8))
        hasher.update(data: payload)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Verify

    func verify() throws -> ActivityLogVerification {
        try queue.sync {
            guard db != nil else { throw ActivityLogStoreError.notOpen }
            let anchor = try anchor()
            var problems: [ActivityLogVerification.Problem] = []
            var previousHash = anchor.hash
            var expectedSeq = anchor.seq + 1
            var count = 0
            var firstSeq: Int?
            var lastSeq: Int?
            var isFirst = true
            try executeRaw("SELECT seq, prev_hash, hash, payload FROM activity ORDER BY seq ASC") { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let seq = Int(sqlite3_column_int64(stmt, 0))
                    let prevHash = String(cString: sqlite3_column_text(stmt, 1))
                    let hash = String(cString: sqlite3_column_text(stmt, 2))
                    let payload = Self.blob(stmt, 3)
                    count += 1
                    if firstSeq == nil { firstSeq = seq }
                    lastSeq = seq
                    if isFirst {
                        isFirst = false
                        if seq != expectedSeq {
                            problems.append(.anchorMismatch(expectedSeq: expectedSeq, actualSeq: seq))
                        }
                    } else if seq != expectedSeq {
                        problems.append(.sequenceGap(seq: seq, expected: expectedSeq))
                    }
                    if prevHash != previousHash {
                        problems.append(.brokenLink(seq: seq))
                    }
                    if (try? Self.decoder.decode(RequestLog.self, from: payload)) == nil {
                        problems.append(.malformedRow(seq: seq))
                    }
                    if Self.hash(prevHash: prevHash, payload: payload) != hash {
                        problems.append(.hashMismatch(seq: seq))
                    }
                    previousHash = hash
                    expectedSeq = seq + 1
                }
            }
            let tailSeq = lastSeq ?? anchor.seq
            let tailHash = lastSeq == nil ? anchor.hash : previousHash
            if let head = readHead() {
                if head.seq != tailSeq || head.hash != tailHash {
                    problems.append(.headMismatch(expectedSeq: head.seq, actualSeq: tailSeq))
                }
            } else if count > 0 {
                problems.append(.headMismatch(expectedSeq: 0, actualSeq: tailSeq))
            }
            return ActivityLogVerification(
                recordCount: count,
                firstSeq: firstSeq,
                lastSeq: lastSeq,
                lastHash: lastSeq == nil ? nil : previousHash,
                problems: problems,
                checkedAt: Date()
            )
        }
    }

    // MARK: - Retention

    /// Remove the contiguous prefix of rows older than `cutoff` and advance
    /// the chain anchor so `verify()` still passes. Returns rows removed.
    @discardableResult
    func prune(olderThan cutoff: Date) throws -> Int {
        let outcome = try pruneRows(olderThan: cutoff)
        if outcome.removed > 0 {
            try appendSystemEvent(
                "pruned",
                details: [
                    "removed_rows": String(outcome.removed),
                    "cutoff": Self.iso8601String(cutoff),
                    "anchor_seq": String(outcome.anchorSeq),
                ]
            )
        }
        return outcome.removed
    }

    /// ISO-8601 UTC timestamp for custody-row details (new formatter per call:
    /// `ISO8601DateFormatter` is not Sendable).
    static func iso8601String(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    private func pruneRows(olderThan cutoff: Date) throws -> (removed: Int, anchorSeq: Int) {
        try queue.sync {
            guard db != nil else { throw ActivityLogStoreError.notOpen }
            let cutoffMs = Int64((cutoff.timeIntervalSince1970 * 1000).rounded())
            var boundary: Int?
            try executeRaw("SELECT MIN(seq) FROM activity WHERE ts_ms >= \(cutoffMs)") { stmt in
                if sqlite3_step(stmt) == SQLITE_ROW, sqlite3_column_type(stmt, 0) != SQLITE_NULL {
                    boundary = Int(sqlite3_column_int64(stmt, 0))
                }
            }
            if let boundary {
                var newAnchor: (Int, String)?
                try executeRaw("SELECT seq, prev_hash FROM activity WHERE seq = \(boundary)") { stmt in
                    if sqlite3_step(stmt) == SQLITE_ROW {
                        newAnchor = (Int(sqlite3_column_int64(stmt, 0)) - 1, String(cString: sqlite3_column_text(stmt, 1)))
                    }
                }
                guard let newAnchor else { return (0, 0) }
                let current = try anchor()
                guard newAnchor.0 > current.seq else { return (0, current.seq) }
                try executeRaw("BEGIN TRANSACTION")
                try executeRaw("DELETE FROM activity WHERE seq < \(boundary)")
                let removed = Int(sqlite3_changes(db))
                try setAnchor(seq: newAnchor.0, hash: newAnchor.1)
                try executeRaw("COMMIT")
                return (removed, newAnchor.0)
            }
            // Nothing newer than the cutoff: everything goes.
            let tail = try currentTail()
            var total = 0
            try executeRaw("SELECT COUNT(*) FROM activity") { stmt in
                if sqlite3_step(stmt) == SQLITE_ROW { total = Int(sqlite3_column_int(stmt, 0)) }
            }
            guard total > 0 else { return (0, tail.seq) }
            try executeRaw("BEGIN TRANSACTION")
            try executeRaw("DELETE FROM activity")
            try setAnchor(seq: tail.seq, hash: tail.hash)
            try executeRaw("COMMIT")
            self.tail = tail
            try writeHead(seq: tail.seq, hash: tail.hash)
            return (total, tail.seq)
        }
    }

    // MARK: - Chain-of-custody rows

    /// Append a `system` row describing something done *to* the log
    /// (clear, prune, verify, export, settings change, head recovery). The
    /// row is hashed into the chain like any other, so the maintenance
    /// history is as tamper-evident as the activity it describes.
    @discardableResult
    func appendSystemEvent(_ event: String, details: [String: String] = [:]) throws -> RequestLog {
        var merged = details
        merged["event"] = event
        return try append(
            RequestLog(
                source: .system,
                method: "SYSTEM",
                path: "/activity/\(event)",
                statusCode: 200,
                durationMs: 0,
                errorMessage: nil,
                category: .system,
                locality: .local,
                egress: EgressInfo(details: merged)
            )
        )
    }

    /// Put a verification result on the chain. Kept separate from
    /// `verify()` so the check itself stays side-effect free.
    @discardableResult
    func recordVerification(_ result: ActivityLogVerification) throws -> RequestLog {
        var details: [String: String] = [
            "records": String(result.recordCount),
            "problems": String(result.problems.count),
            "ok": result.isIntact ? "true" : "false",
        ]
        if let hash = result.lastHash { details["head_hash"] = hash }
        if let seq = result.lastSeq { details["head_seq"] = String(seq) }
        if !result.problems.isEmpty {
            details["problem_summary"] = result.problems.prefix(8).map(\.description).joined(separator: "; ")
        }
        return try appendSystemEvent("verified", details: details)
    }

    /// Remove every row, advance the anchor, and append a `system`
    /// tombstone so the clear is itself on the record.
    func clear(reason: String = "cleared_by_user") throws {
        var removed = 0
        try queue.sync {
            guard db != nil else { throw ActivityLogStoreError.notOpen }
            let tail = try currentTail()
            try executeRaw("SELECT COUNT(*) FROM activity") { stmt in
                if sqlite3_step(stmt) == SQLITE_ROW { removed = Int(sqlite3_column_int(stmt, 0)) }
            }
            try executeRaw("BEGIN TRANSACTION")
            try executeRaw("DELETE FROM activity")
            try setAnchor(seq: tail.seq, hash: tail.hash)
            try executeRaw("COMMIT")
            self.tail = tail
            try writeHead(seq: tail.seq, hash: tail.hash)
        }
        try appendSystemEvent("cleared", details: ["reason": reason, "removed_rows": String(removed)])
    }

    // MARK: - Queries

    func count(filter: ActivityFilter = .empty) throws -> Int {
        let (whereSQL, binds) = Self.whereClause(filter)
        var n = 0
        try prepareAndExecute("SELECT COUNT(*) FROM activity \(whereSQL)", binds: binds) { stmt in
            if sqlite3_step(stmt) == SQLITE_ROW { n = Int(sqlite3_column_int(stmt, 0)) }
        }
        return n
    }

    /// Most recent first.
    func fetch(filter: ActivityFilter = .empty, limit: Int = 100, offset: Int = 0) throws -> [RequestLog] {
        let (whereSQL, binds) = Self.whereClause(filter)
        var rows: [RequestLog] = []
        try prepareAndExecute(
            "SELECT payload, hash FROM activity \(whereSQL) ORDER BY ts_ms DESC, seq DESC LIMIT \(max(0, limit)) OFFSET \(max(0, offset))",
            binds: binds
        ) { stmt in
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let row = Self.readRow(stmt) { rows.append(row) }
            }
        }
        return rows
    }

    /// Streams every matching row oldest-first in `batchSize` chunks (export).
    func forEach(filter: ActivityFilter = .empty, batchSize: Int = 500, _ body: (RequestLog) throws -> Void) throws {
        let (whereSQL, binds) = Self.whereClause(filter)
        var offset = 0
        while true {
            var batch: [RequestLog] = []
            try prepareAndExecute(
                "SELECT payload, hash FROM activity \(whereSQL) ORDER BY seq ASC LIMIT \(batchSize) OFFSET \(offset)",
                binds: binds
            ) { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    if let row = Self.readRow(stmt) { batch.append(row) }
                }
            }
            if batch.isEmpty { return }
            for row in batch { try body(row) }
            if batch.count < batchSize { return }
            offset += batchSize
        }
    }

    func find(id: UUID) throws -> RequestLog? {
        try first(where: "id = ?1", binds: [.text(id.uuidString)])
    }

    func find(turnId: UUID) throws -> RequestLog? {
        try first(where: "turn_id = ?1", binds: [.text(turnId.uuidString)])
    }

    func find(requestId: String) throws -> RequestLog? {
        try first(where: "request_id = ?1", binds: [.text(requestId)])
    }

    func find(providerId: UUID) throws -> RequestLog? {
        try first(where: "provider_id = ?1", binds: [.text(providerId.uuidString)])
    }

    func find(accessKeyId: String) throws -> RequestLog? {
        try first(where: "access_key_id = ?1", binds: [.text(accessKeyId)])
    }

    func exists(turnId: UUID) throws -> Bool {
        try find(turnId: turnId) != nil
    }

    private func first(where clause: String, binds: [Bind]) throws -> RequestLog? {
        var row: RequestLog?
        try prepareAndExecute(
            "SELECT payload, hash FROM activity WHERE \(clause) ORDER BY ts_ms DESC, seq DESC LIMIT 1",
            binds: binds
        ) { stmt in
            if sqlite3_step(stmt) == SQLITE_ROW { row = Self.readRow(stmt) }
        }
        return row
    }

    /// Aggregate usage for a remote connection (outbound by provider id,
    /// inbound by access key / audience).
    func connectionActivity(column: String, value: String) throws -> ConnectionActivitySummary {
        var summary = ConnectionActivitySummary()
        try prepareAndExecute(
            """
            SELECT COUNT(*), MAX(ts_ms),
                   AVG(CASE WHEN tokens_per_second > 0 THEN tokens_per_second END),
                   SUM(COALESCE(output_tokens, 0))
            FROM activity WHERE \(column) = ?1
            """,
            binds: [.text(value)]
        ) { stmt in
            if sqlite3_step(stmt) == SQLITE_ROW {
                summary.requestCount = Int(sqlite3_column_int(stmt, 0))
                if sqlite3_column_type(stmt, 1) != SQLITE_NULL {
                    summary.lastUsed = Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 1)) / 1000)
                }
                summary.averageSpeed = sqlite3_column_type(stmt, 2) == SQLITE_NULL ? 0 : sqlite3_column_double(stmt, 2)
                summary.totalOutputTokens = Int(sqlite3_column_int64(stmt, 3))
            }
        }
        return summary
    }

    func summary(filter: ActivityFilter = .empty, destinationLimit: Int = 50) throws -> ActivitySummary {
        let (whereSQL, binds) = Self.whereClause(filter)
        var s = ActivitySummary()
        try prepareAndExecute(
            """
            SELECT COUNT(*),
                   SUM(locality = 'local'), SUM(locality = 'remote'), SUM(is_error), AVG(duration_ms),
                   SUM(category = 'inference'), SUM(category = 'web_search'),
                   SUM(category = 'url_extract'), SUM(category = 'mcp_tool_call'),
                   SUM(COALESCE(input_tokens, 0)), SUM(COALESCE(output_tokens, 0)),
                   AVG(CASE WHEN tokens_per_second > 0 THEN tokens_per_second END),
                   SUM(COALESCE(bytes_sent, 0)), SUM(COALESCE(bytes_received, 0)),
                   SUM(privacy_filter_applied), SUM(COALESCE(redacted_count, 0)),
                   MIN(ts_ms), MAX(ts_ms)
            FROM activity \(whereSQL)
            """,
            binds: binds
        ) { stmt in
            guard sqlite3_step(stmt) == SQLITE_ROW else { return }
            func int(_ i: Int32) -> Int { sqlite3_column_type(stmt, i) == SQLITE_NULL ? 0 : Int(sqlite3_column_int64(stmt, i)) }
            func dbl(_ i: Int32) -> Double { sqlite3_column_type(stmt, i) == SQLITE_NULL ? 0 : sqlite3_column_double(stmt, i) }
            s.totalCount = int(0)
            s.localCount = int(1)
            s.remoteCount = int(2)
            s.errorCount = int(3)
            s.averageDurationMs = dbl(4)
            s.inferenceCount = int(5)
            s.searchCount = int(6)
            s.extractCount = int(7)
            s.mcpCount = int(8)
            s.totalInputTokens = int(9)
            s.totalOutputTokens = int(10)
            s.averageSpeed = dbl(11)
            s.bytesSent = int(12)
            s.bytesReceived = int(13)
            s.privacyFilteredCount = int(14)
            s.redactedSpanTotal = int(15)
            if sqlite3_column_type(stmt, 16) != SQLITE_NULL {
                s.earliest = Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 16)) / 1000)
            }
            if sqlite3_column_type(stmt, 17) != SQLITE_NULL {
                s.latest = Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 17)) / 1000)
            }
        }
        let remoteWhere = whereSQL.isEmpty ? "WHERE locality = 'remote'" : "\(whereSQL) AND locality = 'remote'"
        try prepareAndExecute(
            """
            SELECT COALESCE(destination_label, destination_host, ''), COALESCE(destination_host, ''),
                   COUNT(*), SUM(COALESCE(bytes_sent, 0)), SUM(COALESCE(bytes_received, 0)), SUM(is_error), MAX(ts_ms)
            FROM activity \(remoteWhere)
            GROUP BY 1, 2 ORDER BY 3 DESC LIMIT \(max(1, destinationLimit))
            """,
            binds: binds
        ) { stmt in
            while sqlite3_step(stmt) == SQLITE_ROW {
                let label = String(cString: sqlite3_column_text(stmt, 0))
                let host = String(cString: sqlite3_column_text(stmt, 1))
                s.destinations.append(
                    ActivityDestinationSummary(
                        label: label.isEmpty ? (host.isEmpty ? L("Unknown") : host) : label,
                        host: host,
                        count: Int(sqlite3_column_int(stmt, 2)),
                        bytesSent: Int(sqlite3_column_int64(stmt, 3)),
                        bytesReceived: Int(sqlite3_column_int64(stmt, 4)),
                        errorCount: Int(sqlite3_column_int(stmt, 5)),
                        lastSeen: sqlite3_column_type(stmt, 6) == SQLITE_NULL
                            ? nil : Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 6)) / 1000)
                    )
                )
            }
        }
        return s
    }

    /// Distinct non-null values of an indexed column for filter menus.
    func distinctValues(column: ActivityDistinctColumn, limit: Int = 100) throws -> [String] {
        var values: [String] = []
        try prepareAndExecute(
            "SELECT \(column.rawValue), COUNT(*) FROM activity WHERE \(column.rawValue) IS NOT NULL AND \(column.rawValue) != '' GROUP BY 1 ORDER BY 2 DESC LIMIT \(max(1, limit))",
            binds: []
        ) { stmt in
            while sqlite3_step(stmt) == SQLITE_ROW {
                values.append(String(cString: sqlite3_column_text(stmt, 0)))
            }
        }
        return values
    }

    public enum ActivityDistinctColumn: String {
        case destinationHost = "destination_host"
        case model
        case agentName = "agent_name"
    }

    // MARK: - WHERE builder

    enum Bind {
        case text(String)
        case int(Int64)
        case double(Double)
    }

    static func whereClause(_ f: ActivityFilter) -> (sql: String, binds: [Bind]) {
        var clauses: [String] = []
        var binds: [Bind] = []
        func add(_ b: Bind) -> String {
            binds.append(b)
            return "?\(binds.count)"
        }

        let text = f.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            let pattern = "%" + text.replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") + "%"
            let p = add(.text(pattern))
            clauses.append(
                "(title LIKE \(p) ESCAPE '\\' OR path LIKE \(p) ESCAPE '\\' OR model LIKE \(p) ESCAPE '\\' "
                    + "OR destination_host LIKE \(p) ESCAPE '\\' OR destination_label LIKE \(p) ESCAPE '\\' "
                    + "OR plugin_id LIKE \(p) ESCAPE '\\' OR agent_name LIKE \(p) ESCAPE '\\' "
                    + "OR error_message LIKE \(p) ESCAPE '\\' OR request_id LIKE \(p) ESCAPE '\\')"
            )
        }
        if let bounds = f.dateRange.bounds() {
            let start = add(.int(Int64((bounds.start.timeIntervalSince1970 * 1000).rounded())))
            let end = add(.int(Int64((bounds.end.timeIntervalSince1970 * 1000).rounded())))
            clauses.append("ts_ms >= \(start) AND ts_ms < \(end)")
        }
        if let locality = f.locality {
            clauses.append("locality = \(add(.text(locality.rawValue)))")
        }
        if !f.categories.isEmpty {
            let ps = f.categories.map(\.rawValue).sorted().map { add(.text($0)) }
            clauses.append("category IN (\(ps.joined(separator: ", ")))")
        }
        if !f.sources.isEmpty {
            let ps = f.sources.map(\.rawValue).sorted().map { add(.text($0)) }
            clauses.append("source IN (\(ps.joined(separator: ", ")))")
        }
        if let host = f.destinationHost {
            clauses.append("destination_host = \(add(.text(host)))")
        }
        if let model = f.model {
            clauses.append("model = \(add(.text(model)))")
        }
        if let agentId = f.agentId {
            clauses.append("agent_id = \(add(.text(agentId.uuidString)))")
        }
        switch f.status {
        case .all: break
        case .success: clauses.append("is_error = 0")
        case .error: clauses.append("is_error = 1")
        }
        if let pf = f.privacyFilterApplied {
            clauses.append("privacy_filter_applied = \(add(.int(pf ? 1 : 0)))")
        }
        if !f.includePluginLogs {
            clauses.append("category != \(add(.text(ActivityCategory.pluginLog.rawValue)))")
        }
        return (clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND "), binds)
    }

    // MARK: - Row reading

    private static func readRow(_ stmt: OpaquePointer) -> RequestLog? {
        let payload = blob(stmt, 0)
        guard var row = try? decoder.decode(RequestLog.self, from: payload) else { return nil }
        row.hash = String(cString: sqlite3_column_text(stmt, 1))
        return row
    }

    private static func blob(_ stmt: OpaquePointer, _ index: Int32) -> Data {
        guard let base = sqlite3_column_blob(stmt, index) else { return Data() }
        let count = Int(sqlite3_column_bytes(stmt, index))
        return Data(bytes: base, count: count)
    }

    // MARK: - Raw execution

    private func executeRaw(_ sql: String) throws {
        guard let connection = db else { throw ActivityLogStoreError.notOpen }
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(connection, sql, nil, nil, &errorMessage)
        if result != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? "Unknown error"
            sqlite3_free(errorMessage)
            throw ActivityLogStoreError.failedToExecute(message)
        }
    }

    private func executeRaw(_ sql: String, handler: (OpaquePointer) throws -> Void) throws {
        guard let connection = db else { throw ActivityLogStoreError.notOpen }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &stmt, nil) == SQLITE_OK, let statement = stmt else {
            throw ActivityLogStoreError.failedToPrepare(String(cString: sqlite3_errmsg(connection)))
        }
        defer { sqlite3_finalize(statement) }
        try handler(statement)
    }

    private func prepareAndExecute(_ sql: String, binds: [Bind], process: (OpaquePointer) throws -> Void) throws {
        try queue.sync {
            guard let connection = db else { throw ActivityLogStoreError.notOpen }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(connection, sql, -1, &stmt, nil) == SQLITE_OK, let statement = stmt else {
                throw ActivityLogStoreError.failedToPrepare(String(cString: sqlite3_errmsg(connection)))
            }
            defer { sqlite3_finalize(statement) }
            for (i, bind) in binds.enumerated() {
                let idx = Int32(i + 1)
                switch bind {
                case .text(let s): Self.bindText(statement, idx, s)
                case .int(let v): sqlite3_bind_int64(statement, idx, v)
                case .double(let d): sqlite3_bind_double(statement, idx, d)
                }
            }
            try process(statement)
        }
    }

    /// Caller must already hold `queue`.
    private func executeUpdate(_ sql: String, bind: (OpaquePointer) -> Void) throws {
        guard let connection = db else { throw ActivityLogStoreError.notOpen }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &stmt, nil) == SQLITE_OK, let statement = stmt else {
            throw ActivityLogStoreError.failedToPrepare(String(cString: sqlite3_errmsg(connection)))
        }
        defer { sqlite3_finalize(statement) }
        bind(statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw ActivityLogStoreError.failedToExecute(String(cString: sqlite3_errmsg(connection)))
        }
    }

    static func bindText(_ stmt: OpaquePointer, _ index: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(stmt, index, value, -1, activityLogSqliteTransient)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    static func bindInt(_ stmt: OpaquePointer, _ index: Int32, _ value: Int?) {
        if let value {
            sqlite3_bind_int64(stmt, index, Int64(value))
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }
}

private let activityLogSqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
