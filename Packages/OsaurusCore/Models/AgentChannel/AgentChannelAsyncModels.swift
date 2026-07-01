//
//  AgentChannelAsyncModels.swift
//  osaurus
//
//  Provider-neutral contracts for async Agent Channel ingress and replies.
//

import Foundation

enum AgentChannelAsyncStatus: String, Codable, CaseIterable, Sendable, Equatable {
    case accepted
    case duplicate
    case ignored
    case rejected
    case dispatched
    case awaitingAgent = "awaiting_agent"
    case awaitingClarification = "awaiting_clarification"
    case replied
    case completed
    case failed
}

enum AgentChannelFailureCode: String, Codable, CaseIterable, Sendable, Equatable {
    case verificationFailed = "verification_failed"
    case senderNotAllowed = "sender_not_allowed"
    case duplicateEvent = "duplicate_event"
    case invalidPayload = "invalid_payload"
    case invalidDeduplicationKey = "invalid_deduplication_key"
    case replyTokenUnknown = "reply_token_unknown"
    case replyTokenExpired = "reply_token_expired"
    case replyTokenAgentMismatch = "reply_token_agent_mismatch"
    case artifactForwardingUnsupported = "artifact_forwarding_unsupported"
    case artifactTooLarge = "artifact_too_large"
    case dispatchUnavailable = "dispatch_unavailable"
    case storageUnavailable = "storage_unavailable"
    case providerUnavailable = "provider_unavailable"
    case rateLimited = "rate_limited"
    case internalFailure = "internal_failure"
}

struct AgentChannelFailure: Codable, Equatable, Sendable, LocalizedError {
    var code: AgentChannelFailureCode
    var message: String
    var retryable: Bool

    init(
        code: AgentChannelFailureCode,
        message: String,
        retryable: Bool = false
    ) {
        self.code = code
        self.message = message
        self.retryable = retryable
    }

    var errorDescription: String? {
        message
    }
}

enum AgentChannelSourceVerificationMethod: String, Codable, CaseIterable, Sendable, Equatable {
    case none
    case sharedSecretHeader = "shared_secret_header"
    case hmacSHA256 = "hmac_sha256"
}

enum AgentChannelSourceVerificationStatus: String, Codable, CaseIterable, Sendable, Equatable {
    case verified
    case skipped
    case failed
}

struct AgentChannelSourceVerificationPolicy: Codable, Equatable, Sendable {
    var method: AgentChannelSourceVerificationMethod
    var headerName: String?
    var secret: String?
    var signaturePrefix: String?

    init(
        method: AgentChannelSourceVerificationMethod,
        headerName: String? = nil,
        secret: String? = nil,
        signaturePrefix: String? = nil
    ) {
        self.method = method
        self.headerName = headerName?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.secret = secret
        self.signaturePrefix = signaturePrefix
    }

    static let unverified = AgentChannelSourceVerificationPolicy(method: .none)
}

struct AgentChannelWebhookVerificationRequest: Equatable, Sendable {
    var headers: [String: String]
    var body: Data
    var sourceAddress: String?
    var receivedAt: Date

    init(
        headers: [String: String],
        body: Data = Data(),
        sourceAddress: String? = nil,
        receivedAt: Date = Date()
    ) {
        self.headers = headers
        self.body = body
        self.sourceAddress = sourceAddress?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.receivedAt = receivedAt
    }
}

struct AgentChannelSourceVerificationResult: Codable, Equatable, Sendable {
    var status: AgentChannelSourceVerificationStatus
    var method: AgentChannelSourceVerificationMethod
    var verifiedAt: Date
    var failure: AgentChannelFailure?

    var isVerified: Bool {
        status == .verified || status == .skipped
    }

    static func verified(
        method: AgentChannelSourceVerificationMethod,
        at date: Date = Date()
    ) -> AgentChannelSourceVerificationResult {
        AgentChannelSourceVerificationResult(
            status: method == .none ? .skipped : .verified,
            method: method,
            verifiedAt: date,
            failure: nil
        )
    }

    static func failed(
        method: AgentChannelSourceVerificationMethod,
        message: String,
        at date: Date = Date()
    ) -> AgentChannelSourceVerificationResult {
        AgentChannelSourceVerificationResult(
            status: .failed,
            method: method,
            verifiedAt: date,
            failure: AgentChannelFailure(code: .verificationFailed, message: message)
        )
    }
}

struct AgentChannelSenderIdentity: Codable, Equatable, Sendable {
    var providerSenderId: String?
    var normalizedAddress: String?
    var displayName: String?
    var isBot: Bool

    init(
        providerSenderId: String? = nil,
        normalizedAddress: String? = nil,
        displayName: String? = nil,
        isBot: Bool = false
    ) {
        self.providerSenderId = Self.normalized(providerSenderId)
        self.normalizedAddress = Self.normalized(normalizedAddress)?.lowercased()
        self.displayName = Self.normalized(displayName)
        self.isBot = isBot
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum AgentChannelSenderPolicyDisposition: String, Codable, CaseIterable, Sendable, Equatable {
    case allow
    case reject
}

struct AgentChannelSenderPolicy: Codable, Equatable, Sendable {
    var defaultDisposition: AgentChannelSenderPolicyDisposition
    var allowedSenderIds: [String]
    var blockedSenderIds: [String]
    var allowedAddresses: [String]
    var blockedAddresses: [String]
    var allowBots: Bool

    init(
        defaultDisposition: AgentChannelSenderPolicyDisposition = .reject,
        allowedSenderIds: [String] = [],
        blockedSenderIds: [String] = [],
        allowedAddresses: [String] = [],
        blockedAddresses: [String] = [],
        allowBots: Bool = false
    ) {
        self.defaultDisposition = defaultDisposition
        self.allowedSenderIds = Self.normalizedIds(allowedSenderIds)
        self.blockedSenderIds = Self.normalizedIds(blockedSenderIds)
        self.allowedAddresses = Self.normalizedAddresses(allowedAddresses)
        self.blockedAddresses = Self.normalizedAddresses(blockedAddresses)
        self.allowBots = allowBots
    }

    var hasAllowlist: Bool {
        !allowedSenderIds.isEmpty || !allowedAddresses.isEmpty
    }

    private static func normalizedIds(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return
            values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private static func normalizedAddresses(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return
            values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

struct AgentChannelSenderPolicyEvaluation: Codable, Equatable, Sendable {
    var disposition: AgentChannelSenderPolicyDisposition
    var failure: AgentChannelFailure?
    var matchedPolicy: String

    var isAllowed: Bool {
        disposition == .allow
    }

    static func allowed(_ matchedPolicy: String) -> AgentChannelSenderPolicyEvaluation {
        AgentChannelSenderPolicyEvaluation(
            disposition: .allow,
            failure: nil,
            matchedPolicy: matchedPolicy
        )
    }

    static func rejected(_ matchedPolicy: String, message: String) -> AgentChannelSenderPolicyEvaluation {
        AgentChannelSenderPolicyEvaluation(
            disposition: .reject,
            failure: AgentChannelFailure(code: .senderNotAllowed, message: message),
            matchedPolicy: matchedPolicy
        )
    }
}

struct AgentChannelDeduplicationKey: Codable, Hashable, Sendable {
    var connectionId: String
    var providerEventId: String
    var sourceId: String?

    init?(connectionId: String, providerEventId: String, sourceId: String? = nil) {
        let connectionId = Self.normalized(connectionId)
        let providerEventId = Self.normalized(providerEventId)
        guard !connectionId.isEmpty, !providerEventId.isEmpty else { return nil }
        self.connectionId = connectionId
        self.providerEventId = providerEventId
        self.sourceId = Self.normalizedOptional(sourceId)
    }

    var storageEventId: String {
        if let sourceId {
            return "\(sourceId):\(providerEventId)"
        }
        return providerEventId
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedOptional(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = Self.normalized(value)
        return normalized.isEmpty ? nil : normalized
    }
}

enum AgentChannelDeduplicationOutcome: String, Codable, CaseIterable, Sendable, Equatable {
    case firstSeen = "first_seen"
    case duplicate
    case invalidKey = "invalid_key"
}

struct AgentChannelProviderRoute: Codable, Equatable, Sendable {
    var conversationId: String
    var threadId: String?
    var replyAddress: String?
    var displayName: String?

    init(
        conversationId: String,
        threadId: String? = nil,
        replyAddress: String? = nil,
        displayName: String? = nil
    ) {
        self.conversationId = conversationId.trimmingCharacters(in: .whitespacesAndNewlines)
        self.threadId = Self.normalizedOptional(threadId)
        self.replyAddress = Self.normalizedOptional(replyAddress)
        self.displayName = Self.normalizedOptional(displayName)
    }

    private static func normalizedOptional(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct AgentChannelReplyToken: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    var rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var description: String {
        rawValue
    }
}

struct AgentChannelReplyBindingInput: Equatable, Sendable {
    var agentId: UUID?
    var connectionId: String
    var providerRoute: AgentChannelProviderRoute
    var sessionId: UUID
    var taskId: UUID?
    var timeToLive: TimeInterval

    init(
        agentId: UUID?,
        connectionId: String,
        providerRoute: AgentChannelProviderRoute,
        sessionId: UUID,
        taskId: UUID? = nil,
        timeToLive: TimeInterval = 600
    ) {
        self.agentId = agentId
        self.connectionId = connectionId.trimmingCharacters(in: .whitespacesAndNewlines)
        self.providerRoute = providerRoute
        self.sessionId = sessionId
        self.taskId = taskId
        self.timeToLive = max(1, timeToLive)
    }
}

struct AgentChannelReplyTokenBinding: Codable, Equatable, Sendable {
    var token: AgentChannelReplyToken
    var agentId: UUID?
    var connectionId: String
    var providerRoute: AgentChannelProviderRoute
    var sessionId: UUID
    var taskId: UUID?
    var issuedAt: Date
    var expiresAt: Date

    var agentVisiblePayload: [String: String] {
        [
            "reply_token": token.rawValue,
            "expires_at": Self.iso8601String(from: expiresAt),
        ]
    }

    func isExpired(at date: Date = Date()) -> Bool {
        date >= expiresAt
    }

    private static func iso8601String(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

struct AgentChannelSessionPartition: Codable, Equatable, Sendable {
    var agentId: UUID?
    var connectionId: String
    var conversationHash: String
    var salt: Int
    var externalSessionKey: String
    var sessionId: UUID
}

enum AgentChannelArtifactForwardingStatus: String, Codable, CaseIterable, Sendable, Equatable {
    case notRequested = "not_requested"
    case queued
    case forwarded
    case skipped
    case blocked
    case failed
}

struct AgentChannelArtifactForwardingRecord: Codable, Equatable, Sendable {
    var artifactId: String
    var filename: String?
    var status: AgentChannelArtifactForwardingStatus
    var failure: AgentChannelFailure?
    var updatedAt: Date

    init(
        artifactId: String,
        filename: String? = nil,
        status: AgentChannelArtifactForwardingStatus,
        failure: AgentChannelFailure? = nil,
        updatedAt: Date = Date()
    ) {
        self.artifactId = artifactId.trimmingCharacters(in: .whitespacesAndNewlines)
        self.filename = filename?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.status = status
        self.failure = failure
        self.updatedAt = updatedAt
    }
}

struct AgentChannelArtifactForwardingReport: Codable, Equatable, Sendable {
    var records: [AgentChannelArtifactForwardingRecord]

    init(records: [AgentChannelArtifactForwardingRecord] = []) {
        self.records = records
    }

    var status: AgentChannelArtifactForwardingStatus {
        if records.isEmpty { return .notRequested }
        if records.contains(where: { $0.status == .failed }) { return .failed }
        if records.contains(where: { $0.status == .blocked }) { return .blocked }
        if records.contains(where: { $0.status == .queued }) { return .queued }
        if records.contains(where: { $0.status == .forwarded }) { return .forwarded }
        return .skipped
    }
}

enum AgentChannelAuditEventKind: String, Codable, CaseIterable, Sendable, Equatable {
    case webhookReceived = "webhook_received"
    case sourceVerified = "source_verified"
    case sourceRejected = "source_rejected"
    case senderAccepted = "sender_accepted"
    case senderRejected = "sender_rejected"
    case eventAccepted = "event_accepted"
    case eventDuplicate = "event_duplicate"
    case replyTokenIssued = "reply_token_issued"
    case dispatchStarted = "dispatch_started"
    case artifactForwardingChanged = "artifact_forwarding_changed"
    case replySent = "reply_sent"
    case replyFailed = "reply_failed"
    case taskCompleted = "task_completed"
    case taskFailed = "task_failed"
}

struct AgentChannelAuditEvent: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var timestamp: Date
    var kind: AgentChannelAuditEventKind
    var status: AgentChannelAsyncStatus
    var connectionId: String
    var agentId: UUID?
    var sessionId: UUID?
    var auditKey: String?
    var replyToken: AgentChannelReplyToken?
    var artifactStatus: AgentChannelArtifactForwardingStatus?
    var failure: AgentChannelFailure?
    var metadata: [String: String]

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        kind: AgentChannelAuditEventKind,
        status: AgentChannelAsyncStatus,
        connectionId: String,
        agentId: UUID? = nil,
        sessionId: UUID? = nil,
        auditKey: String? = nil,
        replyToken: AgentChannelReplyToken? = nil,
        artifactStatus: AgentChannelArtifactForwardingStatus? = nil,
        failure: AgentChannelFailure? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.status = status
        self.connectionId = connectionId.trimmingCharacters(in: .whitespacesAndNewlines)
        self.agentId = agentId
        self.sessionId = sessionId
        self.auditKey = auditKey
        self.replyToken = replyToken
        self.artifactStatus = artifactStatus
        self.failure = failure
        self.metadata = metadata
    }
}
