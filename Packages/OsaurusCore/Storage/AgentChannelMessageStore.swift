//
//  AgentChannelMessageStore.swift
//  osaurus
//
//  Durable, provider-neutral message state for Agent Channels.
//

import Foundation
import OsaurusSQLCipher

public enum AgentChannelMessageStoreError: Error, LocalizedError, Equatable {
    case failedToOpen(String)
    case failedToExecute(String)
    case failedToPrepare(String)
    case migrationFailed(String)
    case invalidReceiveEvent(String)
    case notOpen

    public var errorDescription: String? {
        switch self {
        case .failedToOpen(let message):
            return "Failed to open Agent Channel message database: \(message)"
        case .failedToExecute(let message):
            return "Failed to execute Agent Channel message query: \(message)"
        case .failedToPrepare(let message):
            return "Failed to prepare Agent Channel message query: \(message)"
        case .migrationFailed(let message):
            return "Agent Channel message migration failed: \(message)"
        case .invalidReceiveEvent(let message):
            return "Invalid Agent Channel receive event: \(message)"
        case .notOpen:
            return "Agent Channel message database is not open"
        }
    }
}

public enum AgentChannelStoredMessageDirection: String, Codable, Sendable, Equatable {
    case inbound
    case outbound
}

public struct AgentChannelStoredMessage: Codable, Sendable, Equatable, Identifiable {
    public var id: String { "\(connectionId):\(roomId):\(providerMessageId)" }

    public let connectionId: String
    public let roomId: String
    public let providerMessageId: String
    public let direction: AgentChannelStoredMessageDirection
    public let threadId: String?
    public let authorId: String?
    public let authorName: String?
    public let content: String
    public let payloadJSON: String
    public let providerTimestamp: String?
    public let receivedAt: Date

    public init(
        connectionId: String,
        roomId: String,
        providerMessageId: String,
        direction: AgentChannelStoredMessageDirection,
        threadId: String? = nil,
        authorId: String? = nil,
        authorName: String? = nil,
        content: String,
        payloadJSON: String = "{}",
        providerTimestamp: String? = nil,
        receivedAt: Date = Date()
    ) {
        self.connectionId = connectionId
        self.roomId = roomId
        self.providerMessageId = providerMessageId
        self.direction = direction
        self.threadId = threadId
        self.authorId = authorId
        self.authorName = authorName
        self.content = content
        self.payloadJSON = payloadJSON
        self.providerTimestamp = providerTimestamp
        self.receivedAt = receivedAt
    }
}

public enum AgentChannelReceiveDisposition: String, Codable, Sendable, Equatable {
    case accepted
    case duplicate
    case denied
}

public enum AgentChannelAuditDirection: String, Codable, Sendable, Equatable {
    case inbound
    case outbound
    case system
}

public enum AgentChannelAuditStatus: String, Codable, Sendable, Equatable {
    case accepted
    case duplicate
    case denied
    case failed
}

public struct AgentChannelAuditRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: String {
        if let databaseId {
            return String(databaseId)
        }
        let components = [
            connectionId,
            roomId ?? "*",
            providerEventId ?? providerMessageId ?? action,
            String(createdAt.timeIntervalSince1970),
        ]
        return "synthetic:" + components
            .map { Data($0.utf8).base64EncodedString() }
            .joined(separator: ".")
    }

    public let databaseId: Int64?
    public let connectionId: String
    public let roomId: String?
    public let providerEventId: String?
    public let providerMessageId: String?
    public let direction: AgentChannelAuditDirection
    public let action: String
    public let status: AgentChannelAuditStatus
    public let authorizationDecision: String?
    public let reason: String?
    public let failureCode: String?
    public let failureMessage: String?
    public let shouldDispatch: Bool
    public let messageInserted: Bool
    public let redactedSummary: String
    public let metadataJSON: String
    public let createdAt: Date

    public init(
        databaseId: Int64? = nil,
        connectionId: String,
        roomId: String? = nil,
        providerEventId: String? = nil,
        providerMessageId: String? = nil,
        direction: AgentChannelAuditDirection,
        action: String,
        status: AgentChannelAuditStatus,
        authorizationDecision: String? = nil,
        reason: String? = nil,
        failureCode: String? = nil,
        failureMessage: String? = nil,
        shouldDispatch: Bool = false,
        messageInserted: Bool = false,
        redactedSummary: String = "",
        metadataJSON: String = "{}",
        createdAt: Date = Date()
    ) {
        self.databaseId = databaseId
        self.connectionId = connectionId
        self.roomId = roomId
        self.providerEventId = providerEventId
        self.providerMessageId = providerMessageId
        self.direction = direction
        self.action = action
        self.status = status
        self.authorizationDecision = authorizationDecision
        self.reason = reason
        self.failureCode = failureCode
        self.failureMessage = failureMessage
        self.shouldDispatch = shouldDispatch
        self.messageInserted = messageInserted
        self.redactedSummary = redactedSummary
        self.metadataJSON = metadataJSON
        self.createdAt = createdAt
    }
}

public enum AgentChannelAuditRedactor {
    public static func redactedPreview(_ text: String, maxLength: Int = 180) -> String {
        var redacted = text
        let replacements: [(pattern: String, replacement: String)] = [
            (#"://[^/\s:@]+:[^/\s@]+@"#, "://[redacted-credentials]@"),
            (#"(?i)\b(bearer\s+)[A-Za-z0-9._~+/=-]{8,}"#, "$1[redacted-token]"),
            (#"(?i)\b(api[_-]?key|password|token|secret)\s*[:=]\s*["']?[^"'\s,;]{6,}"#, "$1=[redacted-secret]"),
            (#"(?i)\b(sk-[A-Za-z0-9_-]{8,}|xox[baprs]-[A-Za-z0-9-]{8,}|gh[pousr]_[A-Za-z0-9_]{8,})\b"#, "[redacted-token]"),
            (#"\b[A-Za-z0-9_-]{24}\.[A-Za-z0-9_-]{6}\.[A-Za-z0-9_-]{27,}\b"#, "[redacted-discord-token]"),
            (#"\bAKIA[0-9A-Z]{16}\b"#, "[redacted-aws-key]"),
            (#"\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b"#, "[redacted-jwt]"),
            (#"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#, "[redacted-email]"),
            (#"(?<![\w-])(?:\+\d{1,3}[\s.-]?)?(?:\(?\d{2,4}\)?[\s.-]){2,3}\d{2,4}(?![\w-])"#, "[redacted-phone]"),
        ]

        for replacement in replacements {
            guard let expression = try? NSRegularExpression(
                pattern: replacement.pattern,
                options: [.caseInsensitive]
            ) else {
                continue
            }
            let range = NSRange(redacted.startIndex ..< redacted.endIndex, in: redacted)
            redacted = expression.stringByReplacingMatches(
                in: redacted,
                options: [],
                range: range,
                withTemplate: replacement.replacement
            )
        }

        let collapsed = redacted
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard collapsed.count > maxLength else { return collapsed }
        let cutoff = collapsed.index(collapsed.startIndex, offsetBy: max(0, maxLength - 1))
        return String(collapsed[..<cutoff]) + "…"
    }
}

public struct AgentChannelReceiveResult: Codable, Sendable, Equatable {
    public let connectionId: String
    public let providerEventId: String?
    public let disposition: AgentChannelReceiveDisposition
    public let shouldDispatch: Bool
    public let messageInserted: Bool
    public let cursorUpdated: Bool
    public let authorizationDecision: String?
    public let authorizationReason: String?

    public init(
        connectionId: String,
        providerEventId: String?,
        disposition: AgentChannelReceiveDisposition,
        shouldDispatch: Bool,
        messageInserted: Bool,
        cursorUpdated: Bool,
        authorizationDecision: String? = nil,
        authorizationReason: String? = nil
    ) {
        self.connectionId = connectionId
        self.providerEventId = providerEventId
        self.disposition = disposition
        self.shouldDispatch = shouldDispatch
        self.messageInserted = messageInserted
        self.cursorUpdated = cursorUpdated
        self.authorizationDecision = authorizationDecision
        self.authorizationReason = authorizationReason
    }
}

public final class AgentChannelMessageStore: @unchecked Sendable {
    public static let shared = AgentChannelMessageStore()
    public static let maxMessagesPerRoom = 1_000
    public static let maxAuditEventsPerConnection = 10_000

    private static let latestSchemaVersion = 2

    private var db: OpaquePointer?
    private var registeredMaintenanceHandle = false
    private let queue = DispatchQueue(label: "ai.osaurus.agent-channel.messages")

    public var isOpen: Bool {
        queue.sync { db != nil }
    }

    public init() {}

    deinit { close() }

    public func openIfNeeded() throws {
        if isOpen { return }
        try open()
    }

    public func open() throws {
        StorageMutationGate.blockingAwaitNotMutating()
        var didOpen = false
        try queue.sync {
            guard db == nil else { return }
            OsaurusPaths.ensureExistsSilent(OsaurusPaths.agentChannels())
            try openConnection()
            try runMigrations()
            didOpen = true
        }
        if didOpen {
            OsaurusDatabaseHandle.register(maintenanceHandle)
            registeredMaintenanceHandle = true
        }
    }

    private lazy var maintenanceHandle = OsaurusDatabaseHandle(
        name: "agent-channels",
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
        if registeredMaintenanceHandle {
            OsaurusDatabaseHandle.deregister(name: "agent-channels")
            registeredMaintenanceHandle = false
        }
        queue.sync {
            guard let connection = db else { return }
            try? executeRaw("PRAGMA optimize")
            sqlite3_close(connection)
            db = nil
        }
    }

    private func openConnection() throws {
        let path = OsaurusPaths.agentChannelMessagesDatabaseFile().path
        do {
            db = try OsaurusStorageOpener.open(path: path)
        } catch let error as EncryptedSQLiteError {
            throw AgentChannelMessageStoreError.failedToOpen(error.localizedDescription)
        }
    }

    private func runMigrations() throws {
        let currentVersion = try getSchemaVersion()
        guard currentVersion <= Self.latestSchemaVersion else {
            throw AgentChannelMessageStoreError.migrationFailed(
                "on-disk schema v\(currentVersion) is newer than supported v\(Self.latestSchemaVersion)"
            )
        }
        do {
            if currentVersion < 1 { try migrateToV1() }
            if currentVersion < 2 { try migrateToV2() }
        } catch {
            throw AgentChannelMessageStoreError.migrationFailed(error.localizedDescription)
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
        try executeRaw(
            """
            CREATE TABLE IF NOT EXISTS channel_messages (
                connection_id       TEXT NOT NULL,
                room_id             TEXT NOT NULL,
                provider_message_id TEXT NOT NULL,
                direction           TEXT NOT NULL,
                thread_id           TEXT,
                author_id           TEXT,
                author_name         TEXT,
                content             TEXT NOT NULL DEFAULT '',
                payload_json        TEXT NOT NULL DEFAULT '{}',
                provider_timestamp  TEXT,
                received_at         REAL NOT NULL,
                PRIMARY KEY (connection_id, room_id, provider_message_id)
            )
            """
        )
        try executeRaw(
            """
            CREATE INDEX IF NOT EXISTS idx_channel_messages_room_time
            ON channel_messages(connection_id, room_id, received_at DESC)
            """
        )
        try executeRaw(
            """
            CREATE TABLE IF NOT EXISTS channel_seen_events (
                connection_id     TEXT NOT NULL,
                provider_event_id TEXT NOT NULL,
                seen_at           REAL NOT NULL,
                PRIMARY KEY (connection_id, provider_event_id)
            )
            """
        )
        try executeRaw(
            """
            CREATE INDEX IF NOT EXISTS idx_channel_seen_events_seen_at
            ON channel_seen_events(seen_at)
            """
        )
        try executeRaw(
            """
            CREATE TABLE IF NOT EXISTS channel_receive_cursors (
                connection_id TEXT NOT NULL,
                room_id       TEXT NOT NULL,
                cursor        TEXT NOT NULL DEFAULT '',
                updated_at    REAL NOT NULL,
                PRIMARY KEY (connection_id, room_id)
            )
            """
        )
        try setSchemaVersion(1)
    }

    private func migrateToV2() throws {
        try executeRaw(
            """
            CREATE TABLE IF NOT EXISTS channel_audit_events (
                id                  INTEGER PRIMARY KEY AUTOINCREMENT,
                connection_id       TEXT NOT NULL,
                room_id             TEXT,
                provider_event_id   TEXT,
                provider_message_id TEXT,
                direction           TEXT NOT NULL,
                action              TEXT NOT NULL,
                status              TEXT NOT NULL,
                authorization_decision TEXT,
                reason              TEXT,
                failure_code        TEXT,
                failure_message     TEXT,
                should_dispatch     INTEGER NOT NULL DEFAULT 0,
                message_inserted    INTEGER NOT NULL DEFAULT 0,
                redacted_summary    TEXT NOT NULL DEFAULT '',
                metadata_json       TEXT NOT NULL DEFAULT '{}',
                created_at          REAL NOT NULL
            )
            """
        )
        try executeRaw(
            """
            CREATE INDEX IF NOT EXISTS idx_channel_audit_events_connection_time
            ON channel_audit_events(connection_id, created_at DESC)
            """
        )
        try executeRaw(
            """
            CREATE INDEX IF NOT EXISTS idx_channel_audit_events_room_time
            ON channel_audit_events(connection_id, room_id, created_at DESC)
            """
        )
        try executeRaw(
            """
            CREATE INDEX IF NOT EXISTS idx_channel_audit_events_status_time
            ON channel_audit_events(status, created_at DESC)
            """
        )
        try setSchemaVersion(2)
    }

    @discardableResult
    public func recordMessages(_ messages: [AgentChannelStoredMessage]) throws -> Int {
        try queue.sync {
            guard db != nil else { throw AgentChannelMessageStoreError.notOpen }
            try executeRaw("BEGIN IMMEDIATE")
            do {
                var inserted = 0
                var touchedRoomKeys = Set<String>()
                var touchedRooms: [(connectionId: String, roomId: String)] = []
                for message in messages {
                    let connectionId = Self.normalizedId(message.connectionId)
                    let roomId = Self.normalizedId(message.roomId)
                    let providerMessageId = Self.normalizedId(message.providerMessageId)
                    guard Self.isUsableId(connectionId),
                        Self.isUsableId(roomId),
                        Self.isUsableId(providerMessageId)
                    else {
                        continue
                    }
                    let roomKey = "\(connectionId)\u{1F}\(roomId)"
                    if touchedRoomKeys.insert(roomKey).inserted {
                        touchedRooms.append((connectionId: connectionId, roomId: roomId))
                    }
                    inserted += try insertMessage(message)
                }
                for room in touchedRooms {
                    _ = try pruneMessagesOnQueue(
                        connectionId: room.connectionId,
                        roomId: room.roomId,
                        maxRows: Self.maxMessagesPerRoom
                    )
                }
                try executeRaw("COMMIT")
                return inserted
            } catch {
                try? executeRaw("ROLLBACK")
                throw error
            }
        }
    }

    @discardableResult
    public func recordReceiveEvent(
        connectionId: String,
        providerEventId: String? = nil,
        authorization: AgentChannelInboundAuthorizationDecision,
        message: AgentChannelStoredMessage,
        cursor: String? = nil,
        seenAt: Date = Date()
    ) throws -> AgentChannelReceiveResult {
        let normalizedConnectionId = Self.normalizedId(connectionId)
        let explicitProviderEventId = Self.normalizedOptionalId(providerEventId)
        let authorizationProviderEventId = Self.normalizedOptionalId(authorization.providerEventId)
        guard Self.isUsableId(normalizedConnectionId) else {
            throw AgentChannelMessageStoreError.invalidReceiveEvent("connection_id is required")
        }
        let normalizedProviderEventId = explicitProviderEventId ?? authorizationProviderEventId

        let snapshot = try Self.normalizedReceiveSnapshot(
            connectionId: normalizedConnectionId,
            message: message
        )
        let normalizedCursor = Self.normalizedOptionalId(cursor)
        if let denied = Self.authorizationDenial(
            authorization,
            connectionId: normalizedConnectionId,
            providerEventId: normalizedProviderEventId,
            roomId: snapshot.roomId,
            providerMessageId: snapshot.providerMessageId,
            senderId: snapshot.authorId
        ) {
            try recordReceiveAuditIfOpen(
                result: denied,
                authorization: authorization,
                message: snapshot,
                seenAt: seenAt
            )
            return denied
        }

        return try queue.sync {
            guard db != nil else { throw AgentChannelMessageStoreError.notOpen }
            try executeRaw("BEGIN IMMEDIATE")
            do {
                if let normalizedProviderEventId {
                    let eventInserted =
                        try insertSeenEventOnQueue(
                            connectionId: normalizedConnectionId,
                            providerEventId: normalizedProviderEventId,
                            seenAt: seenAt
                        ) > 0
                    guard eventInserted else {
                        let result = AgentChannelReceiveResult(
                            connectionId: normalizedConnectionId,
                            providerEventId: normalizedProviderEventId,
                            disposition: .duplicate,
                            shouldDispatch: false,
                            messageInserted: false,
                            cursorUpdated: false,
                            authorizationDecision: authorization.decision.rawValue,
                            authorizationReason: authorization.reason
                        )
                        _ = try insertAuditEventOnQueue(
                            Self.receiveAuditRecord(
                                result: result,
                                authorization: authorization,
                                message: snapshot,
                                seenAt: seenAt
                            )
                        )
                        try executeRaw("COMMIT")
                        return result
                    }
                }

                let messageInserted = try insertMessage(snapshot) > 0
                if normalizedProviderEventId == nil, !messageInserted {
                    let result = AgentChannelReceiveResult(
                        connectionId: normalizedConnectionId,
                        providerEventId: nil,
                        disposition: .duplicate,
                        shouldDispatch: false,
                        messageInserted: false,
                        cursorUpdated: false,
                        authorizationDecision: authorization.decision.rawValue,
                        authorizationReason: authorization.reason
                    )
                    _ = try insertAuditEventOnQueue(
                        Self.receiveAuditRecord(
                            result: result,
                            authorization: authorization,
                            message: snapshot,
                            seenAt: seenAt
                        )
                    )
                    try executeRaw("COMMIT")
                    return result
                }
                let cursorUpdated: Bool
                if let normalizedCursor {
                    cursorUpdated =
                        try upsertCursorOnQueue(
                            connectionId: normalizedConnectionId,
                            roomId: snapshot.roomId,
                            cursor: normalizedCursor,
                            updatedAt: seenAt
                        ) > 0
                } else {
                    cursorUpdated = false
                }
                _ = try pruneMessagesOnQueue(
                    connectionId: normalizedConnectionId,
                    roomId: snapshot.roomId,
                    maxRows: Self.maxMessagesPerRoom
                )
                let result = AgentChannelReceiveResult(
                    connectionId: normalizedConnectionId,
                    providerEventId: normalizedProviderEventId,
                    disposition: .accepted,
                    shouldDispatch: messageInserted,
                    messageInserted: messageInserted,
                    cursorUpdated: cursorUpdated,
                    authorizationDecision: authorization.decision.rawValue,
                    authorizationReason: authorization.reason
                )
                _ = try insertAuditEventOnQueue(
                    Self.receiveAuditRecord(
                        result: result,
                        authorization: authorization,
                        message: snapshot,
                        seenAt: seenAt,
                        metadata: ["cursor_updated": cursorUpdated ? "true" : "false"]
                    )
                )
                try executeRaw("COMMIT")
                return result
            } catch {
                try? executeRaw("ROLLBACK")
                throw error
            }
        }
    }

    public func recentMessages(connectionId: String, roomId: String, limit: Int) throws -> [AgentChannelStoredMessage] {
        let safeLimit = max(1, min(limit, 200))
        var rows: [AgentChannelStoredMessage] = []
        try prepareAndExecute(
            """
            SELECT \(Self.messageColumns)
            FROM channel_messages
            WHERE connection_id = ?1 AND room_id = ?2
            ORDER BY received_at DESC
            LIMIT ?3
            """,
            bind: { stmt in
                Self.bindText(stmt, index: 1, value: Self.normalizedId(connectionId))
                Self.bindText(stmt, index: 2, value: Self.normalizedId(roomId))
                sqlite3_bind_int(stmt, 3, Int32(safeLimit))
            },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    rows.append(Self.readMessage(from: stmt))
                }
            }
        )
        return rows
    }

    public func recentMessagesFiltered(
        connectionId: String? = nil,
        roomId: String? = nil,
        limit: Int
    ) throws -> [AgentChannelStoredMessage] {
        let safeLimit = max(1, min(limit, 200))
        let connection = connectionId.flatMap(Self.normalizedOptionalId)
        let room = roomId.flatMap(Self.normalizedOptionalId)
        var clauses: [String] = []
        if connection != nil { clauses.append("connection_id = ?") }
        if room != nil { clauses.append("room_id = ?") }
        let whereClause = clauses.isEmpty ? "" : "WHERE \(clauses.joined(separator: " AND "))"
        var rows: [AgentChannelStoredMessage] = []

        try prepareAndExecute(
            """
            SELECT \(Self.messageColumns)
            FROM channel_messages
            \(whereClause)
            ORDER BY received_at DESC
            LIMIT ?
            """,
            bind: { stmt in
                var index: Int32 = 1
                if let connection {
                    Self.bindText(stmt, index: index, value: connection)
                    index += 1
                }
                if let room {
                    Self.bindText(stmt, index: index, value: room)
                    index += 1
                }
                sqlite3_bind_int(stmt, index, Int32(safeLimit))
            },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    rows.append(Self.readMessage(from: stmt))
                }
            }
        )
        return rows
    }

    @discardableResult
    public func pruneMessages(connectionId: String, roomId: String, maxRows: Int) throws -> Int {
        try queue.sync {
            try pruneMessagesOnQueue(
                connectionId: Self.normalizedId(connectionId),
                roomId: Self.normalizedId(roomId),
                maxRows: maxRows
            )
        }
    }

    public func messageCount(connectionId: String? = nil, roomId: String? = nil) throws -> Int {
        let connection = connectionId.flatMap(Self.normalizedOptionalId)
        let room = roomId.flatMap(Self.normalizedOptionalId)
        let sql: String
        if connection != nil, room != nil {
            sql = "SELECT COUNT(*) FROM channel_messages WHERE connection_id = ?1 AND room_id = ?2"
        } else if connection != nil {
            sql = "SELECT COUNT(*) FROM channel_messages WHERE connection_id = ?1"
        } else if room != nil {
            sql = "SELECT COUNT(*) FROM channel_messages WHERE room_id = ?1"
        } else {
            sql = "SELECT COUNT(*) FROM channel_messages"
        }

        var count = 0
        try prepareAndExecute(
            sql,
            bind: { stmt in
                if let connection {
                    Self.bindText(stmt, index: 1, value: connection)
                }
                if let room {
                    Self.bindText(stmt, index: connection == nil ? 1 : 2, value: room)
                }
            },
            process: { stmt in
                if sqlite3_step(stmt) == SQLITE_ROW {
                    count = Int(sqlite3_column_int(stmt, 0))
                }
            }
        )
        return count
    }

    @discardableResult
    public func recordAuditEvent(_ event: AgentChannelAuditRecord) throws -> Int {
        try queue.sync {
            guard db != nil else { throw AgentChannelMessageStoreError.notOpen }
            return try insertAuditEventOnQueue(event)
        }
    }

    public func recentAuditEvents(
        connectionId: String? = nil,
        roomId: String? = nil,
        limit: Int
    ) throws -> [AgentChannelAuditRecord] {
        let safeLimit = max(1, min(limit, 200))
        let connection = connectionId.flatMap(Self.normalizedOptionalId)
        let room = roomId.flatMap(Self.normalizedOptionalId)
        var clauses: [String] = []
        if connection != nil { clauses.append("connection_id = ?") }
        if room != nil { clauses.append("room_id = ?") }
        let whereClause = clauses.isEmpty ? "" : "WHERE \(clauses.joined(separator: " AND "))"
        var rows: [AgentChannelAuditRecord] = []

        try prepareAndExecute(
            """
            SELECT \(Self.auditColumns)
            FROM channel_audit_events
            \(whereClause)
            ORDER BY created_at DESC
            LIMIT ?
            """,
            bind: { stmt in
                var index: Int32 = 1
                if let connection {
                    Self.bindText(stmt, index: index, value: connection)
                    index += 1
                }
                if let room {
                    Self.bindText(stmt, index: index, value: room)
                    index += 1
                }
                sqlite3_bind_int(stmt, index, Int32(safeLimit))
            },
            process: { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    rows.append(Self.readAuditRecord(from: stmt))
                }
            }
        )
        return rows
    }

    public func auditEventCount(
        connectionId: String? = nil,
        roomId: String? = nil,
        status: AgentChannelAuditStatus? = nil
    ) throws -> Int {
        let connection = connectionId.flatMap(Self.normalizedOptionalId)
        let room = roomId.flatMap(Self.normalizedOptionalId)
        var clauses: [String] = []
        if connection != nil { clauses.append("connection_id = ?") }
        if room != nil { clauses.append("room_id = ?") }
        if status != nil { clauses.append("status = ?") }
        let whereClause = clauses.isEmpty ? "" : "WHERE \(clauses.joined(separator: " AND "))"
        var count = 0

        try prepareAndExecute(
            """
            SELECT COUNT(*)
            FROM channel_audit_events
            \(whereClause)
            """,
            bind: { stmt in
                var index: Int32 = 1
                if let connection {
                    Self.bindText(stmt, index: index, value: connection)
                    index += 1
                }
                if let room {
                    Self.bindText(stmt, index: index, value: room)
                    index += 1
                }
                if let status {
                    Self.bindText(stmt, index: index, value: status.rawValue)
                }
            },
            process: { stmt in
                if sqlite3_step(stmt) == SQLITE_ROW {
                    count = Int(sqlite3_column_int(stmt, 0))
                }
            }
        )
        return count
    }

    @discardableResult
    public func pruneAuditEvents(connectionId: String, maxRows: Int) throws -> Int {
        try queue.sync {
            try pruneAuditEventsOnQueue(
                connectionId: Self.normalizedId(connectionId),
                maxRows: maxRows
            )
        }
    }

    @discardableResult
    public func pruneAuditEvents(olderThan cutoff: Date) throws -> Int {
        try executeUpdate("DELETE FROM channel_audit_events WHERE created_at < ?1") { stmt in
            sqlite3_bind_double(stmt, 1, cutoff.timeIntervalSince1970)
        }
    }

    @discardableResult
    public func markEventSeen(connectionId: String, providerEventId: String, seenAt: Date = Date()) throws -> Bool {
        guard Self.isUsableId(connectionId), Self.isUsableId(providerEventId) else { return false }
        let changes = try queue.sync {
            try insertSeenEventOnQueue(
                connectionId: Self.normalizedId(connectionId),
                providerEventId: Self.normalizedId(providerEventId),
                seenAt: seenAt
            )
        }
        return changes > 0
    }

    public func isEventSeen(connectionId: String, providerEventId: String) throws -> Bool {
        var seen = false
        try prepareAndExecute(
            """
            SELECT 1 FROM channel_seen_events
            WHERE connection_id = ?1 AND provider_event_id = ?2
            LIMIT 1
            """,
            bind: { stmt in
                Self.bindText(stmt, index: 1, value: Self.normalizedId(connectionId))
                Self.bindText(stmt, index: 2, value: Self.normalizedId(providerEventId))
            },
            process: { stmt in
                seen = sqlite3_step(stmt) == SQLITE_ROW
            }
        )
        return seen
    }

    @discardableResult
    public func pruneSeenEvents(olderThan cutoff: Date) throws -> Int {
        try executeUpdate("DELETE FROM channel_seen_events WHERE seen_at < ?1") { stmt in
            sqlite3_bind_double(stmt, 1, cutoff.timeIntervalSince1970)
        }
    }

    public func cursor(connectionId: String, roomId: String) throws -> String? {
        var cursor: String?
        try prepareAndExecute(
            """
            SELECT cursor FROM channel_receive_cursors
            WHERE connection_id = ?1 AND room_id = ?2
            LIMIT 1
            """,
            bind: { stmt in
                Self.bindText(stmt, index: 1, value: Self.normalizedId(connectionId))
                Self.bindText(stmt, index: 2, value: Self.normalizedId(roomId))
            },
            process: { stmt in
                if sqlite3_step(stmt) == SQLITE_ROW {
                    cursor = Self.columnText(stmt, 0)
                }
            }
        )
        return cursor
    }

    public func upsertCursor(
        connectionId: String,
        roomId: String,
        cursor: String,
        updatedAt: Date = Date()
    ) throws {
        try queue.sync {
            _ = try upsertCursorOnQueue(
                connectionId: Self.normalizedId(connectionId),
                roomId: Self.normalizedId(roomId),
                cursor: cursor,
                updatedAt: updatedAt
            )
        }
    }

    private func insertSeenEventOnQueue(
        connectionId: String,
        providerEventId: String,
        seenAt: Date
    ) throws -> Int {
        try executeUpdateOnQueue(
            """
            INSERT OR IGNORE INTO channel_seen_events (
                connection_id, provider_event_id, seen_at
            ) VALUES (?1, ?2, ?3)
            """
        ) { stmt in
            Self.bindText(stmt, index: 1, value: connectionId)
            Self.bindText(stmt, index: 2, value: providerEventId)
            sqlite3_bind_double(stmt, 3, seenAt.timeIntervalSince1970)
        }
    }

    @discardableResult
    private func upsertCursorOnQueue(
        connectionId: String,
        roomId: String,
        cursor: String,
        updatedAt: Date
    ) throws -> Int {
        try executeUpdateOnQueue(
            """
            INSERT INTO channel_receive_cursors (
                connection_id, room_id, cursor, updated_at
            ) VALUES (?1, ?2, ?3, ?4)
            ON CONFLICT(connection_id, room_id) DO UPDATE SET
                cursor = excluded.cursor,
                updated_at = excluded.updated_at
            """
        ) { stmt in
            Self.bindText(stmt, index: 1, value: connectionId)
            Self.bindText(stmt, index: 2, value: roomId)
            Self.bindText(stmt, index: 3, value: cursor)
            sqlite3_bind_double(stmt, 4, updatedAt.timeIntervalSince1970)
        }
    }

    private static let messageColumns =
        """
        connection_id, room_id, provider_message_id, direction, thread_id,
        author_id, author_name, content, payload_json, provider_timestamp, received_at
        """

    private static let auditColumns =
        """
        id, connection_id, room_id, provider_event_id, provider_message_id,
        direction, action, status, authorization_decision, reason, failure_code,
        failure_message, should_dispatch, message_inserted, redacted_summary,
        metadata_json, created_at
        """

    private func insertMessage(_ message: AgentChannelStoredMessage) throws -> Int {
        try executeUpdateOnQueue(
            """
            INSERT OR IGNORE INTO channel_messages (
                connection_id, room_id, provider_message_id, direction, thread_id,
                author_id, author_name, content, payload_json, provider_timestamp, received_at
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
            """
        ) { stmt in
            Self.bindText(stmt, index: 1, value: Self.normalizedId(message.connectionId))
            Self.bindText(stmt, index: 2, value: Self.normalizedId(message.roomId))
            Self.bindText(stmt, index: 3, value: Self.normalizedId(message.providerMessageId))
            Self.bindText(stmt, index: 4, value: message.direction.rawValue)
            Self.bindText(stmt, index: 5, value: Self.normalizedOptionalId(message.threadId))
            Self.bindText(stmt, index: 6, value: Self.normalizedOptionalId(message.authorId))
            Self.bindText(stmt, index: 7, value: Self.normalizedOptionalId(message.authorName))
            Self.bindText(stmt, index: 8, value: message.content)
            Self.bindText(stmt, index: 9, value: message.payloadJSON)
            Self.bindText(stmt, index: 10, value: Self.normalizedOptionalId(message.providerTimestamp))
            sqlite3_bind_double(stmt, 11, message.receivedAt.timeIntervalSince1970)
        }
    }

    private func insertAuditEventOnQueue(_ event: AgentChannelAuditRecord) throws -> Int {
        let normalizedConnectionId = Self.normalizedId(event.connectionId)
        guard Self.isUsableId(normalizedConnectionId) else { return 0 }
        let inserted = try executeUpdateOnQueue(
            """
            INSERT INTO channel_audit_events (
                connection_id, room_id, provider_event_id, provider_message_id,
                direction, action, status, authorization_decision, reason,
                failure_code, failure_message, should_dispatch, message_inserted,
                redacted_summary, metadata_json, created_at
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16)
            """
        ) { stmt in
            Self.bindText(stmt, index: 1, value: normalizedConnectionId)
            Self.bindText(stmt, index: 2, value: event.roomId.flatMap(Self.normalizedOptionalId))
            Self.bindText(stmt, index: 3, value: event.providerEventId.flatMap(Self.normalizedOptionalId))
            Self.bindText(stmt, index: 4, value: event.providerMessageId.flatMap(Self.normalizedOptionalId))
            Self.bindText(stmt, index: 5, value: event.direction.rawValue)
            Self.bindText(stmt, index: 6, value: Self.normalizedId(event.action))
            Self.bindText(stmt, index: 7, value: event.status.rawValue)
            Self.bindText(stmt, index: 8, value: event.authorizationDecision.flatMap(Self.normalizedOptionalId))
            Self.bindText(
                stmt,
                index: 9,
                value: event.reason.flatMap { AgentChannelAuditRedactor.redactedPreview($0, maxLength: 160) }
            )
            Self.bindText(stmt, index: 10, value: event.failureCode.flatMap(Self.normalizedOptionalId))
            Self.bindText(
                stmt,
                index: 11,
                value: event.failureMessage.flatMap { AgentChannelAuditRedactor.redactedPreview($0, maxLength: 160) }
            )
            sqlite3_bind_int(stmt, 12, event.shouldDispatch ? 1 : 0)
            sqlite3_bind_int(stmt, 13, event.messageInserted ? 1 : 0)
            Self.bindText(
                stmt,
                index: 14,
                value: AgentChannelAuditRedactor.redactedPreview(event.redactedSummary)
            )
            Self.bindText(stmt, index: 15, value: Self.redactedMetadataJSON(event.metadataJSON))
            sqlite3_bind_double(stmt, 16, event.createdAt.timeIntervalSince1970)
        }
        _ = try pruneAuditEventsOnQueue(
            connectionId: normalizedConnectionId,
            maxRows: Self.maxAuditEventsPerConnection
        )
        return inserted
    }

    private func pruneAuditEventsOnQueue(connectionId: String, maxRows: Int) throws -> Int {
        guard Self.isUsableId(connectionId) else { return 0 }
        let safeMaxRows = max(1, min(maxRows, Self.maxAuditEventsPerConnection))
        return try executeUpdateOnQueue(
            """
            DELETE FROM channel_audit_events
            WHERE connection_id = ?1
              AND id NOT IN (
                  SELECT id
                  FROM channel_audit_events
                  WHERE connection_id = ?1
                  ORDER BY created_at DESC, id DESC
                  LIMIT ?2
              )
            """
        ) { stmt in
            Self.bindText(stmt, index: 1, value: connectionId)
            sqlite3_bind_int(stmt, 2, Int32(safeMaxRows))
        }
    }

    private func pruneMessagesOnQueue(connectionId: String, roomId: String, maxRows: Int) throws -> Int {
        guard Self.isUsableId(connectionId), Self.isUsableId(roomId) else { return 0 }
        let safeMaxRows = max(1, min(maxRows, Self.maxMessagesPerRoom))
        return try executeUpdateOnQueue(
            """
            DELETE FROM channel_messages
            WHERE connection_id = ?1
              AND room_id = ?2
              AND rowid NOT IN (
                  SELECT rowid
                  FROM channel_messages
                  WHERE connection_id = ?1 AND room_id = ?2
                  ORDER BY received_at DESC
                  LIMIT ?3
              )
            """
        ) { stmt in
            Self.bindText(stmt, index: 1, value: connectionId)
            Self.bindText(stmt, index: 2, value: roomId)
            sqlite3_bind_int(stmt, 3, Int32(safeMaxRows))
        }
    }

    private func executeRaw(_ sql: String) throws {
        guard let connection = db else { throw AgentChannelMessageStoreError.notOpen }
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(connection, sql, nil, nil, &errorMessage)
        if result != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? "Unknown error"
            sqlite3_free(errorMessage)
            throw AgentChannelMessageStoreError.failedToExecute(message)
        }
    }

    private func executeRaw(_ sql: String, handler: (OpaquePointer) throws -> Void) throws {
        guard let connection = db else { throw AgentChannelMessageStoreError.notOpen }
        var stmt: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(connection, sql, -1, &stmt, nil)
        guard prepareResult == SQLITE_OK, let statement = stmt else {
            throw AgentChannelMessageStoreError.failedToPrepare(String(cString: sqlite3_errmsg(connection)))
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
            guard let connection = db else { throw AgentChannelMessageStoreError.notOpen }
            var stmt: OpaquePointer?
            let prepareResult = sqlite3_prepare_v2(connection, sql, -1, &stmt, nil)
            guard prepareResult == SQLITE_OK, let statement = stmt else {
                throw AgentChannelMessageStoreError.failedToPrepare(String(cString: sqlite3_errmsg(connection)))
            }
            defer { sqlite3_finalize(statement) }
            bind(statement)
            try process(statement)
        }
    }

    @discardableResult
    private func executeUpdate(_ sql: String, bind: (OpaquePointer) -> Void) throws -> Int {
        try queue.sync {
            try executeUpdateOnQueue(sql, bind: bind)
        }
    }

    @discardableResult
    private func executeUpdateOnQueue(_ sql: String, bind: (OpaquePointer) -> Void) throws -> Int {
        guard let connection = db else { throw AgentChannelMessageStoreError.notOpen }
        var stmt: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(connection, sql, -1, &stmt, nil)
        guard prepareResult == SQLITE_OK, let statement = stmt else {
            throw AgentChannelMessageStoreError.failedToPrepare(String(cString: sqlite3_errmsg(connection)))
        }
        defer { sqlite3_finalize(statement) }
        bind(statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw AgentChannelMessageStoreError.failedToExecute(String(cString: sqlite3_errmsg(connection)))
        }
        return Int(sqlite3_changes(connection))
    }

    private static func readMessage(from stmt: OpaquePointer) -> AgentChannelStoredMessage {
        AgentChannelStoredMessage(
            connectionId: columnText(stmt, 0) ?? "",
            roomId: columnText(stmt, 1) ?? "",
            providerMessageId: columnText(stmt, 2) ?? "",
            direction: columnText(stmt, 3).flatMap(AgentChannelStoredMessageDirection.init(rawValue:)) ?? .inbound,
            threadId: columnText(stmt, 4),
            authorId: columnText(stmt, 5),
            authorName: columnText(stmt, 6),
            content: columnText(stmt, 7) ?? "",
            payloadJSON: columnText(stmt, 8) ?? "{}",
            providerTimestamp: columnText(stmt, 9),
            receivedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 10))
        )
    }

    private static func readAuditRecord(from stmt: OpaquePointer) -> AgentChannelAuditRecord {
        AgentChannelAuditRecord(
            databaseId: sqlite3_column_type(stmt, 0) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 0),
            connectionId: columnText(stmt, 1) ?? "",
            roomId: columnText(stmt, 2),
            providerEventId: columnText(stmt, 3),
            providerMessageId: columnText(stmt, 4),
            direction: columnText(stmt, 5).flatMap(AgentChannelAuditDirection.init(rawValue:)) ?? .system,
            action: columnText(stmt, 6) ?? "",
            status: columnText(stmt, 7).flatMap(AgentChannelAuditStatus.init(rawValue:)) ?? .failed,
            authorizationDecision: columnText(stmt, 8),
            reason: columnText(stmt, 9),
            failureCode: columnText(stmt, 10),
            failureMessage: columnText(stmt, 11),
            shouldDispatch: sqlite3_column_int(stmt, 12) != 0,
            messageInserted: sqlite3_column_int(stmt, 13) != 0,
            redactedSummary: columnText(stmt, 14) ?? "",
            metadataJSON: columnText(stmt, 15) ?? "{}",
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 16))
        )
    }

    private func recordReceiveAuditIfOpen(
        result: AgentChannelReceiveResult,
        authorization: AgentChannelInboundAuthorizationDecision,
        message: AgentChannelStoredMessage,
        seenAt: Date
    ) throws {
        try queue.sync {
            guard db != nil else { return }
            _ = try insertAuditEventOnQueue(
                Self.receiveAuditRecord(
                    result: result,
                    authorization: authorization,
                    message: message,
                    seenAt: seenAt
                )
            )
        }
    }

    private static func receiveAuditRecord(
        result: AgentChannelReceiveResult,
        authorization: AgentChannelInboundAuthorizationDecision,
        message: AgentChannelStoredMessage,
        seenAt: Date,
        metadata: [String: String] = [:]
    ) -> AgentChannelAuditRecord {
        let status: AgentChannelAuditStatus
        switch result.disposition {
        case .accepted:
            status = .accepted
        case .duplicate:
            status = .duplicate
        case .denied:
            status = .denied
        }

        let metadataJSON = auditMetadataJSON(
            [
                "audit_decision_reason": authorization.auditDecisionReason,
                "space_id": authorization.spaceId,
            ].merging(metadata) { current, _ in current }
        )

        return AgentChannelAuditRecord(
            connectionId: result.connectionId,
            roomId: message.roomId,
            providerEventId: result.providerEventId,
            providerMessageId: message.providerMessageId,
            direction: .inbound,
            action: "receive_message",
            status: status,
            authorizationDecision: result.authorizationDecision,
            reason: result.authorizationReason,
            shouldDispatch: result.shouldDispatch,
            messageInserted: result.messageInserted,
            redactedSummary: AgentChannelAuditRedactor.redactedPreview(message.content),
            metadataJSON: metadataJSON,
            createdAt: seenAt
        )
    }

    private static func auditMetadataJSON(_ metadata: [String: String?]) -> String {
        let compact = metadata.compactMapValues { value in
            value.flatMap { AgentChannelAuditRedactor.redactedPreview($0, maxLength: 120) }
        }
        guard !compact.isEmpty,
            JSONSerialization.isValidJSONObject(compact),
            let data = try? JSONSerialization.data(withJSONObject: compact, options: [.sortedKeys]),
            let string = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return string
    }

    private static func redactedMetadataJSON(_ metadataJSON: String) -> String {
        let trimmed = metadataJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "{}" else { return "{}" }
        guard let data = trimmed.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data),
            JSONSerialization.isValidJSONObject(object)
        else {
            return auditMetadataJSON(["preview": trimmed])
        }

        let redacted = redactedJSONObject(object)
        guard JSONSerialization.isValidJSONObject(redacted),
            let encoded = try? JSONSerialization.data(withJSONObject: redacted, options: [.sortedKeys]),
            let string = String(data: encoded, encoding: .utf8)
        else {
            return "{}"
        }
        return string
    }

    private static func redactedJSONObject(_ value: Any) -> Any {
        if let string = value as? String {
            return AgentChannelAuditRedactor.redactedPreview(string, maxLength: 160)
        }
        if let array = value as? [Any] {
            return array.map(redactedJSONObject)
        }
        if let dictionary = value as? [String: Any] {
            return dictionary.mapValues(redactedJSONObject)
        }
        return value
    }

    private static func normalizedReceiveSnapshot(
        connectionId: String,
        message: AgentChannelStoredMessage
    ) throws -> AgentChannelStoredMessage {
        let roomId = normalizedId(message.roomId)
        let providerMessageId = normalizedId(message.providerMessageId)
        guard isUsableId(roomId) else {
            throw AgentChannelMessageStoreError.invalidReceiveEvent("message.room_id is required")
        }
        guard isUsableId(providerMessageId) else {
            throw AgentChannelMessageStoreError.invalidReceiveEvent("message.provider_message_id is required")
        }
        return AgentChannelStoredMessage(
            connectionId: connectionId,
            roomId: roomId,
            providerMessageId: providerMessageId,
            direction: .inbound,
            threadId: normalizedOptionalId(message.threadId),
            authorId: normalizedOptionalId(message.authorId),
            authorName: normalizedOptionalId(message.authorName),
            content: message.content,
            payloadJSON: message.payloadJSON,
            providerTimestamp: normalizedOptionalId(message.providerTimestamp),
            receivedAt: message.receivedAt
        )
    }

    private static func authorizationDenial(
        _ authorization: AgentChannelInboundAuthorizationDecision,
        connectionId: String,
        providerEventId: String?,
        roomId: String,
        providerMessageId: String,
        senderId: String?
    ) -> AgentChannelReceiveResult? {
        if authorization.decision == .duplicate {
            return deniedReceiveResult(
                connectionId: connectionId,
                providerEventId: providerEventId,
                authorization: authorization,
                reason: authorization.reason,
                disposition: .duplicate,
                authorizationDecision: .duplicate
            )
        }
        guard authorization.decision == .allow, authorization.shouldDispatch else {
            return deniedReceiveResult(
                connectionId: connectionId,
                providerEventId: providerEventId,
                authorization: authorization,
                reason: authorization.reason,
                authorizationDecision: .deny
            )
        }
        guard normalizedId(authorization.connectionId) == connectionId else {
            return deniedReceiveResult(
                connectionId: connectionId,
                providerEventId: providerEventId,
                authorization: authorization,
                reason: "connection_id_authorization_mismatch",
                authorizationDecision: .deny
            )
        }
        if providerEventId != normalizedOptionalId(authorization.providerEventId) {
            return deniedReceiveResult(
                connectionId: connectionId,
                providerEventId: providerEventId,
                authorization: authorization,
                reason: "provider_event_id_authorization_mismatch",
                authorizationDecision: .deny
            )
        }
        let authorizedProviderMessageId = normalizedOptionalId(authorization.providerMessageId)
        if providerEventId == nil {
            guard authorizedProviderMessageId == providerMessageId else {
                return deniedReceiveResult(
                    connectionId: connectionId,
                    providerEventId: providerEventId,
                    authorization: authorization,
                    reason: "provider_message_id_authorization_mismatch",
                    authorizationDecision: .deny
                )
            }
        } else if let authorizedProviderMessageId, authorizedProviderMessageId != providerMessageId {
            return deniedReceiveResult(
                connectionId: connectionId,
                providerEventId: providerEventId,
                authorization: authorization,
                reason: "provider_message_id_authorization_mismatch",
                authorizationDecision: .deny
            )
        }
        guard normalizedId(authorization.roomId) == roomId else {
            return deniedReceiveResult(
                connectionId: connectionId,
                providerEventId: providerEventId,
                authorization: authorization,
                reason: "room_id_authorization_mismatch",
                authorizationDecision: .deny
            )
        }
        if normalizedOptionalId(senderId) != normalizedOptionalId(authorization.senderId) {
            return deniedReceiveResult(
                connectionId: connectionId,
                providerEventId: providerEventId,
                authorization: authorization,
                reason: "sender_id_authorization_mismatch",
                authorizationDecision: .deny
            )
        }
        return nil
    }

    private static func deniedReceiveResult(
        connectionId: String,
        providerEventId: String?,
        authorization: AgentChannelInboundAuthorizationDecision,
        reason: String,
        disposition: AgentChannelReceiveDisposition = .denied,
        authorizationDecision: AgentChannelInboundAuthorizationDecisionValue? = nil
    ) -> AgentChannelReceiveResult {
        AgentChannelReceiveResult(
            connectionId: connectionId,
            providerEventId: providerEventId,
            disposition: disposition,
            shouldDispatch: false,
            messageInserted: false,
            cursorUpdated: false,
            authorizationDecision: (authorizationDecision ?? authorization.decision).rawValue,
            authorizationReason: reason
        )
    }

    private static func columnText(_ stmt: OpaquePointer, _ index: Int32) -> String? {
        guard let text = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: text)
    }

    private static func normalizedId(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedOptionalId(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = normalizedId(value)
        return normalized.isEmpty ? nil : normalized
    }

    private static func isUsableId(_ value: String) -> Bool {
        !normalizedId(value).isEmpty
    }
}

private let agentChannelSqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

extension AgentChannelMessageStore {
    static func bindText(_ stmt: OpaquePointer, index: Int32, value: String?) {
        if let value {
            sqlite3_bind_text(stmt, index, value, -1, agentChannelSqliteTransient)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }
}
