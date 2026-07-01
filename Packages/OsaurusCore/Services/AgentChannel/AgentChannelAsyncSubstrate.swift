//
//  AgentChannelAsyncSubstrate.swift
//  osaurus
//
//  Shared async ingress/reply helpers for provider-backed Agent Channels.
//

import CryptoKit
import Foundation
import Security

final class AgentChannelAsyncSubstrate: @unchecked Sendable {
    static let shared = AgentChannelAsyncSubstrate()

    func verifyWebhookSource(
        request: AgentChannelWebhookVerificationRequest,
        policy: AgentChannelSourceVerificationPolicy
    ) -> AgentChannelSourceVerificationResult {
        switch policy.method {
        case .none:
            return .verified(method: .none, at: request.receivedAt)
        case .sharedSecretHeader:
            return verifySharedSecretHeader(request: request, policy: policy)
        case .hmacSHA256:
            return verifyHMACSHA256(request: request, policy: policy)
        }
    }

    func evaluateSender(
        _ sender: AgentChannelSenderIdentity,
        policy: AgentChannelSenderPolicy
    ) -> AgentChannelSenderPolicyEvaluation {
        if sender.isBot, !policy.allowBots {
            return .rejected("bot_sender", message: "Automated channel sender is not allowed.")
        }
        if let senderId = sender.providerSenderId,
            policy.blockedSenderIds.contains(senderId)
        {
            return .rejected("blocked_sender_id", message: "Channel sender is blocked.")
        }
        if let address = sender.normalizedAddress,
            policy.blockedAddresses.contains(address)
        {
            return .rejected("blocked_address", message: "Channel sender address is blocked.")
        }
        if let senderId = sender.providerSenderId,
            policy.allowedSenderIds.contains(senderId)
        {
            return .allowed("allowed_sender_id")
        }
        if let address = sender.normalizedAddress,
            policy.allowedAddresses.contains(address)
        {
            return .allowed("allowed_address")
        }
        if policy.hasAllowlist {
            return .rejected("allowlist_miss", message: "Channel sender is not on the allowlist.")
        }
        if policy.defaultDisposition == .allow {
            return .allowed("default_allow")
        }
        return .rejected("default_reject", message: "Channel sender is not allowed by default.")
    }

    func makeDeduplicationKey(
        connectionId: String,
        providerEventId: String,
        sourceId: String? = nil
    ) -> AgentChannelDeduplicationKey? {
        AgentChannelDeduplicationKey(
            connectionId: connectionId,
            providerEventId: providerEventId,
            sourceId: sourceId
        )
    }

    func auditKey(for key: AgentChannelDeduplicationKey) -> String {
        "ack_\(Self.sha256Hex("\(key.connectionId)|\(key.storageEventId)").prefix(24))"
    }

    func makeSessionPartition(
        agentId: UUID?,
        connectionId: String,
        providerRoute: AgentChannelProviderRoute,
        salt: Int = 0
    ) -> AgentChannelSessionPartition {
        let normalizedConnectionId = connectionId.trimmingCharacters(in: .whitespacesAndNewlines)
        let agentComponent = agentId?.uuidString.lowercased() ?? "default-agent"
        let routeMaterial = [
            "agent-channel-session",
            agentComponent,
            normalizedConnectionId,
            providerRoute.conversationId,
            providerRoute.threadId ?? "",
            String(salt),
        ].joined(separator: "\u{1F}")
        let conversationHash = String(Self.sha256Hex(routeMaterial).prefix(32))
        let externalSessionKey = "agent-channel:\(normalizedConnectionId):\(conversationHash):s\(salt)"
        return AgentChannelSessionPartition(
            agentId: agentId,
            connectionId: normalizedConnectionId,
            conversationHash: conversationHash,
            salt: salt,
            externalSessionKey: externalSessionKey,
            sessionId: Self.stableUUID(material: externalSessionKey)
        )
    }

    private func verifySharedSecretHeader(
        request: AgentChannelWebhookVerificationRequest,
        policy: AgentChannelSourceVerificationPolicy
    ) -> AgentChannelSourceVerificationResult {
        let headerName =
            policy.headerName?.isEmpty == false
            ? policy.headerName!
            : "X-Osaurus-Channel-Secret"
        guard let expected = policy.secret, !expected.isEmpty else {
            return .failed(
                method: .sharedSecretHeader,
                message: "Agent Channel webhook secret is not configured.",
                at: request.receivedAt
            )
        }
        guard let received = Self.headerValue(named: headerName, in: request.headers),
            Self.constantTimeEqual(received, expected)
        else {
            return .failed(
                method: .sharedSecretHeader,
                message: "Agent Channel webhook secret did not verify.",
                at: request.receivedAt
            )
        }
        return .verified(method: .sharedSecretHeader, at: request.receivedAt)
    }

    private func verifyHMACSHA256(
        request: AgentChannelWebhookVerificationRequest,
        policy: AgentChannelSourceVerificationPolicy
    ) -> AgentChannelSourceVerificationResult {
        let headerName =
            policy.headerName?.isEmpty == false
            ? policy.headerName!
            : "X-Osaurus-Channel-Signature"
        guard let secret = policy.secret, !secret.isEmpty else {
            return .failed(
                method: .hmacSHA256,
                message: "Agent Channel HMAC secret is not configured.",
                at: request.receivedAt
            )
        }
        guard let received = Self.headerValue(named: headerName, in: request.headers) else {
            return .failed(
                method: .hmacSHA256,
                message: "Agent Channel HMAC signature header is missing.",
                at: request.receivedAt
            )
        }
        let expectedHex = Self.hmacSHA256Hex(body: request.body, secret: secret)
        let expected = (policy.signaturePrefix ?? "sha256=") + expectedHex
        guard
            Self.constantTimeEqual(received.lowercased(), expected.lowercased())
                || Self.constantTimeEqual(received.lowercased(), expectedHex.lowercased())
        else {
            return .failed(
                method: .hmacSHA256,
                message: "Agent Channel HMAC signature did not verify.",
                at: request.receivedAt
            )
        }
        return .verified(method: .hmacSHA256, at: request.receivedAt)
    }

    static func hmacSHA256Hex(body: Data, secret: String) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        let signature = HMAC<SHA256>.authenticationCode(for: body, using: key)
        return signature.map { String(format: "%02x", $0) }.joined()
    }

    static func sha256Hex(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func stableUUID(material: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(material.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let tuple: uuid_t = (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        )
        return UUID(uuid: tuple)
    }

    private static func headerValue(named name: String, in headers: [String: String]) -> String? {
        let normalized = name.lowercased()
        return headers.first { key, _ in
            key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalized
        }?.value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        let count = max(left.count, right.count)
        var diff = left.count == right.count ? 0 : 1
        for index in 0 ..< count {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            diff |= Int(l ^ r)
        }
        return diff == 0
    }
}

actor AgentChannelReplyTokenRegistry {
    typealias TokenGenerator = @Sendable () throws -> String

    private var bindings: [AgentChannelReplyToken: AgentChannelReplyTokenBinding] = [:]
    private let tokenGenerator: TokenGenerator

    init(tokenGenerator: @escaping TokenGenerator = AgentChannelReplyTokenRegistry.randomToken) {
        self.tokenGenerator = tokenGenerator
    }

    func issue(
        _ input: AgentChannelReplyBindingInput,
        issuedAt: Date = Date()
    ) throws -> AgentChannelReplyTokenBinding {
        removeExpired(at: issuedAt)
        let token = try uniqueToken()
        let binding = AgentChannelReplyTokenBinding(
            token: token,
            agentId: input.agentId,
            connectionId: input.connectionId,
            providerRoute: input.providerRoute,
            sessionId: input.sessionId,
            taskId: input.taskId,
            issuedAt: issuedAt,
            expiresAt: issuedAt.addingTimeInterval(input.timeToLive)
        )
        bindings[token] = binding
        return binding
    }

    func resolve(
        token: AgentChannelReplyToken,
        agentId: UUID?,
        at date: Date = Date()
    ) -> Result<AgentChannelReplyTokenBinding, AgentChannelFailure> {
        guard let binding = bindings[token] else {
            removeExpired(at: date)
            return .failure(
                AgentChannelFailure(
                    code: .replyTokenUnknown,
                    message: "Reply token is unknown or already cleared."
                )
            )
        }
        guard !binding.isExpired(at: date) else {
            bindings.removeValue(forKey: token)
            removeExpired(at: date)
            return .failure(
                AgentChannelFailure(
                    code: .replyTokenExpired,
                    message: "Reply token has expired."
                )
            )
        }
        guard binding.agentId == agentId else {
            return .failure(
                AgentChannelFailure(
                    code: .replyTokenAgentMismatch,
                    message: "Reply token is scoped to a different agent."
                )
            )
        }
        removeExpired(at: date)
        return .success(binding)
    }

    func revoke(token: AgentChannelReplyToken) {
        bindings.removeValue(forKey: token)
    }

    @discardableResult
    func pruneExpired(at date: Date = Date()) -> Int {
        removeExpired(at: date)
    }

    func count() -> Int {
        bindings.count
    }

    @discardableResult
    private func removeExpired(at date: Date) -> Int {
        let previousCount = bindings.count
        bindings = bindings.filter { _, binding in
            !binding.isExpired(at: date)
        }
        return previousCount - bindings.count
    }

    private func uniqueToken() throws -> AgentChannelReplyToken {
        for _ in 0 ..< 5 {
            let token = AgentChannelReplyToken(rawValue: try tokenGenerator())
            if !token.rawValue.isEmpty, bindings[token] == nil {
                return token
            }
        }
        throw AgentChannelFailure(
            code: .internalFailure,
            message: "Unable to mint a unique Agent Channel reply token."
        )
    }

    private static func randomToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw AgentChannelFailure(
                code: .internalFailure,
                message: "Secure random generator failed while minting reply token."
            )
        }
        let encoded = Data(bytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "acr_\(encoded)"
    }
}

final class AgentChannelDeduplicationService: @unchecked Sendable {
    private let store: AgentChannelMessageStore

    init(store: AgentChannelMessageStore = .shared) {
        self.store = store
    }

    func register(_ key: AgentChannelDeduplicationKey?) throws -> AgentChannelDeduplicationOutcome {
        guard let key else { return .invalidKey }
        let inserted = try store.markEventSeen(
            connectionId: key.connectionId,
            providerEventId: key.storageEventId
        )
        return inserted ? .firstSeen : .duplicate
    }
}

actor AgentChannelAuditLog {
    private var events: [AgentChannelAuditEvent] = []
    private let maxEvents: Int

    init(maxEvents: Int = 1_000) {
        self.maxEvents = max(maxEvents, 1)
    }

    func record(_ event: AgentChannelAuditEvent) {
        events.append(event)
        if events.count > maxEvents {
            events.removeFirst(events.count - maxEvents)
        }
    }

    func snapshot() -> [AgentChannelAuditEvent] {
        events
    }

    func clear() {
        events.removeAll()
    }
}
