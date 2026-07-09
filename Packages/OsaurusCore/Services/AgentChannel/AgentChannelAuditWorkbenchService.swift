//
//  AgentChannelAuditWorkbenchService.swift
//  osaurus
//
//  Redacted inbox and audit views for Agent Channel operators.
//

import Foundation

public struct AgentChannelInboxMessage: Codable, Sendable, Equatable, Identifiable {
    public var id: String {
        [connectionId, roomId, providerMessageId]
            .map { Data($0.utf8).base64EncodedString() }
            .joined(separator: ".")
    }

    public let connectionId: String
    public let roomId: String
    public let providerMessageId: String
    public let direction: AgentChannelStoredMessageDirection
    public let threadId: String?
    public let authorDisplay: String?
    public let preview: String
    public let receivedAt: Date

    public init(message: AgentChannelStoredMessage) {
        connectionId = message.connectionId
        roomId = message.roomId
        providerMessageId = message.providerMessageId
        direction = message.direction
        threadId = message.threadId
        authorDisplay = AgentChannelAuditRedactor.redactedPreview(
            message.authorName ?? message.authorId ?? "",
            maxLength: 80
        )
        preview = AgentChannelAuditRedactor.redactedPreview(message.content)
        receivedAt = message.receivedAt
    }
}

public struct AgentChannelAuditWorkbenchSummary: Codable, Sendable, Equatable {
    public let messageCount: Int
    public let auditEventCount: Int
    public let acceptedCount: Int
    public let duplicateCount: Int
    public let deniedCount: Int
    public let failedCount: Int

    public init(
        messageCount: Int,
        auditEventCount: Int,
        acceptedCount: Int,
        duplicateCount: Int,
        deniedCount: Int,
        failedCount: Int
    ) {
        self.messageCount = messageCount
        self.auditEventCount = auditEventCount
        self.acceptedCount = acceptedCount
        self.duplicateCount = duplicateCount
        self.deniedCount = deniedCount
        self.failedCount = failedCount
    }
}

public struct AgentChannelAuditWorkbenchSnapshot: Codable, Sendable, Equatable {
    public let connectionId: String?
    public let roomId: String?
    public let generatedAt: Date
    public let summary: AgentChannelAuditWorkbenchSummary
    public let messages: [AgentChannelInboxMessage]
    public let auditEvents: [AgentChannelAuditRecord]

    public init(
        connectionId: String?,
        roomId: String?,
        generatedAt: Date = Date(),
        summary: AgentChannelAuditWorkbenchSummary,
        messages: [AgentChannelInboxMessage],
        auditEvents: [AgentChannelAuditRecord]
    ) {
        self.connectionId = connectionId
        self.roomId = roomId
        self.generatedAt = generatedAt
        self.summary = summary
        self.messages = messages
        self.auditEvents = auditEvents
    }
}

public struct AgentChannelAuditExportBundle: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let snapshot: AgentChannelAuditWorkbenchSnapshot

    public init(schemaVersion: Int = 1, snapshot: AgentChannelAuditWorkbenchSnapshot) {
        self.schemaVersion = schemaVersion
        self.snapshot = snapshot
    }
}

public final class AgentChannelAuditWorkbenchService: @unchecked Sendable {
    private let store: AgentChannelMessageStore
    private let encoder: JSONEncoder

    public init(store: AgentChannelMessageStore = .shared) {
        self.store = store
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
    }

    public func snapshot(
        connectionId: String? = nil,
        roomId: String? = nil,
        messageLimit: Int = 25,
        auditLimit: Int = 50
    ) throws -> AgentChannelAuditWorkbenchSnapshot {
        try store.openIfNeeded()
        let normalizedConnection = connectionId.flatMap(Self.normalizedOptionalId)
        let normalizedRoom = roomId.flatMap(Self.normalizedOptionalId)
        let summary = AgentChannelAuditWorkbenchSummary(
            messageCount: try store.messageCount(connectionId: normalizedConnection, roomId: normalizedRoom),
            auditEventCount: try store.auditEventCount(connectionId: normalizedConnection, roomId: normalizedRoom),
            acceptedCount: try store.auditEventCount(
                connectionId: normalizedConnection,
                roomId: normalizedRoom,
                status: .accepted
            ),
            duplicateCount: try store.auditEventCount(
                connectionId: normalizedConnection,
                roomId: normalizedRoom,
                status: .duplicate
            ),
            deniedCount: try store.auditEventCount(
                connectionId: normalizedConnection,
                roomId: normalizedRoom,
                status: .denied
            ),
            failedCount: try store.auditEventCount(
                connectionId: normalizedConnection,
                roomId: normalizedRoom,
                status: .failed
            )
        )
        let messages = try store.recentMessagesFiltered(
            connectionId: normalizedConnection,
            roomId: normalizedRoom,
            limit: messageLimit
        ).map(AgentChannelInboxMessage.init(message:))
        let auditEvents = try store.recentAuditEvents(
            connectionId: normalizedConnection,
            roomId: normalizedRoom,
            limit: auditLimit
        )

        return AgentChannelAuditWorkbenchSnapshot(
            connectionId: normalizedConnection,
            roomId: normalizedRoom,
            summary: summary,
            messages: messages,
            auditEvents: auditEvents
        )
    }

    public func exportRedactedJSON(
        connectionId: String? = nil,
        roomId: String? = nil,
        messageLimit: Int = 25,
        auditLimit: Int = 100
    ) throws -> String {
        let bundle = AgentChannelAuditExportBundle(
            snapshot: try snapshot(
                connectionId: connectionId,
                roomId: roomId,
                messageLimit: messageLimit,
                auditLimit: auditLimit
            )
        )
        let data = try encoder.encode(bundle)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func normalizedOptionalId(_ value: String) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}
