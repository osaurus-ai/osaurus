//
//  AgentChannelWebhookIngress.swift
//  osaurus
//
//  Generic, secret-verified inbound webhook for Agent Channel kinds that have
//  no native transport (first consumer: `n8n`). NIO-free so the entire
//  verify -> parse -> authorize -> persist -> relay pipeline is unit-testable;
//  `HTTPHandler` owns only the thin route shims.
//
//  Ordering is a security contract:
//    1. connection lookup / kind / enabled
//    2. remote transport policy (426 unless loopback, Secure Channel, or the
//       connection explicitly allows plaintext)
//    3. source verification against the connection secret — BEFORE any byte of
//       the body is interpreted
//    4. envelope parse
//    5. inbound authorization (space / conversation / sender allowlists)
//    6. message store receive (dedupe + audit)
//    7. relay submit -> 202 with a deterministic task id the caller can poll
//

import Foundation

// MARK: - Wire types

struct AgentChannelWebhookIngressResponse: Error, Equatable, Sendable {
    var status: Int
    var body: String
    /// True when the source should be backed off (bad secret, foreign task).
    var penalizeSource: Bool = false

    static func json(_ status: Int, _ object: [String: Any], penalize: Bool = false) -> Self {
        let data =
            (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            ?? Data(#"{"error":{"code":"encoding_failed"}}"#.utf8)
        return Self(status: status, body: String(decoding: data, as: UTF8.self), penalizeSource: penalize)
    }

    static func error(_ status: Int, code: String, message: String, penalize: Bool = false) -> Self {
        json(
            status,
            ["error": ["code": code, "message": message, "type": Self.errorType(for: status)]],
            penalize: penalize
        )
    }

    private static func errorType(for status: Int) -> String {
        switch status {
        case 400: return "invalid_request_error"
        case 401: return "authentication_error"
        case 403: return "permission_error"
        case 404: return "not_found_error"
        case 426: return "upgrade_required"
        case 429: return "rate_limit_error"
        default: return "api_error"
        }
    }
}

struct AgentChannelWebhookIngressRequest: Sendable {
    var kind: String
    var connectionId: String
    var headers: [String: String]
    var body: Data
    var sourceAddress: String
    var isLoopback: Bool
    var isSecureChannel: Bool
    var receivedAt: Date = Date()
}

/// Per-connection receive counters surfaced in diagnostics and the UI.
struct AgentChannelWebhookIngressHealth: Codable, Equatable, Sendable {
    var connectionId: String
    var inboundAccepted: Int = 0
    var inboundDuplicates: Int = 0
    var inboundRejected: Int = 0
    var signatureFailures: Int = 0
    var rateLimited: Int = 0
    var pollRequests: Int = 0
    var outboundSent: Int = 0
    var outboundFailed: Int = 0
    var lastInboundAt: Date?
    var lastAcceptedAt: Date?
    var lastOutboundAt: Date?
    var lastFailureReason: String?

    var dictionary: [String: Any] {
        var row: [String: Any] = [
            "connection_id": connectionId,
            "inbound_accepted": inboundAccepted,
            "inbound_duplicates": inboundDuplicates,
            "inbound_rejected": inboundRejected,
            "signature_failures": signatureFailures,
            "rate_limited": rateLimited,
            "poll_requests": pollRequests,
            "outbound_sent": outboundSent,
            "outbound_failed": outboundFailed,
        ]
        let iso = ISO8601DateFormatter()
        if let lastInboundAt { row["last_inbound_at"] = iso.string(from: lastInboundAt) }
        if let lastAcceptedAt { row["last_accepted_at"] = iso.string(from: lastAcceptedAt) }
        if let lastOutboundAt { row["last_outbound_at"] = iso.string(from: lastOutboundAt) }
        if let lastFailureReason { row["last_failure_reason"] = lastFailureReason }
        return row
    }
}

/// Snapshot of a channel-dispatched task, read on the main actor.
struct AgentChannelWebhookTaskSnapshot: Sendable {
    enum Status: String, Sendable {
        case queued, running, completed, failed, cancelled
    }

    var status: Status
    var output: String?
    var summary: String?
    var externalSessionKey: String?
    var isChannelSource: Bool
}

// MARK: - Ingress

actor AgentChannelWebhookIngress {
    /// Process-wide instance used by `HTTPHandler`. Mutable only so route
    /// tests can swap in an ingress with an in-memory store and a fixed
    /// secret; production code never reassigns it.
    nonisolated(unsafe) static var shared = AgentChannelWebhookIngress()
    static let transportId = "webhook_ingress"
    /// Hard cap on inbound bodies; the envelope content cap is far smaller.
    static let maxBodyBytes = 256 * 1024
    /// Redaction for request logs: verification headers never reach Insights.
    static let sensitiveHeaderNames: Set<String> = [
        "authorization",
        AgentChannelN8nInboundVerification.defaultSharedSecretHeader.lowercased(),
        AgentChannelN8nInboundVerification.defaultSignatureHeader.lowercased(),
    ]

    typealias ConnectionLookup = @Sendable (String) -> AgentChannelConnection?
    typealias RelaySubmit = @Sendable (AgentChannelInboundRelayRequest) async -> AgentChannelInboundRelaySubmission
    typealias TaskLookup = @Sendable (UUID) async -> AgentChannelWebhookTaskSnapshot?
    typealias ReplyHandlerFactory =
        @Sendable (AgentChannelConnection, AgentChannelN8nEnvelope)
        -> AgentChannelInboundReplyHandler?

    private let substrate: AgentChannelAsyncSubstrate
    private let secretResolver: any AgentChannelSecretResolving
    private let authorizationService: AgentChannelConnectionService
    private let messageStore: AgentChannelMessageStore
    private let activityCenter: AgentChannelInboundActivityCenter
    private let transportHealth: AgentChannelTransportHealthCenter
    private let connectionLookup: ConnectionLookup
    private let relaySubmit: RelaySubmit
    private let taskLookup: TaskLookup
    private let rateLimiter: PairingRateLimiter
    /// Runner used for the optional outbound push (reply to n8n webhook).
    private let outboundRunner: any AgentChannelCustomJSONRunning
    /// Test seam; when nil the n8n preset decides whether a push applies.
    private var replyHandlerFactory: ReplyHandlerFactory?

    private var taskOwners: [UUID: String] = [:]
    private var health: [String: AgentChannelWebhookIngressHealth] = [:]
    private var receiveCounters: [String: (received: Int, stored: Int, attempted: Int, suppressed: Int)] = [:]

    init(
        substrate: AgentChannelAsyncSubstrate = .shared,
        secretResolver: any AgentChannelSecretResolving = KeychainAgentChannelSecretResolver(),
        authorizationService: AgentChannelConnectionService = .shared,
        messageStore: AgentChannelMessageStore = .shared,
        activityCenter: AgentChannelInboundActivityCenter = .shared,
        transportHealth: AgentChannelTransportHealthCenter = .shared,
        connectionLookup: ConnectionLookup? = nil,
        relaySubmit: RelaySubmit? = nil,
        taskLookup: TaskLookup? = nil,
        rateLimiter: PairingRateLimiter = PairingRateLimiter(window: 60, maxPerWindow: 120, denialCooldown: 10),
        outboundRunner: (any AgentChannelCustomJSONRunning)? = nil,
        replyHandlerFactory: ReplyHandlerFactory? = nil
    ) {
        self.substrate = substrate
        self.secretResolver = secretResolver
        self.authorizationService = authorizationService
        self.messageStore = messageStore
        self.activityCenter = activityCenter
        self.transportHealth = transportHealth
        self.connectionLookup =
            connectionLookup ?? { id in
                AgentChannelConfigurationStore.load().connection(id: id)
            }
        self.relaySubmit =
            relaySubmit ?? { request in
                await AgentChannelInboundRelay.shared.submit(request)
            }
        self.taskLookup = taskLookup ?? Self.defaultTaskLookup
        self.rateLimiter = rateLimiter
        self.outboundRunner = outboundRunner ?? AgentChannelCustomJSONRunner()
        self.replyHandlerFactory = replyHandlerFactory
    }

    func setReplyHandlerFactory(_ factory: ReplyHandlerFactory?) {
        replyHandlerFactory = factory
    }

    // MARK: Inbound

    func handleInbound(_ request: AgentChannelWebhookIngressRequest) async -> AgentChannelWebhookIngressResponse {
        let connectionId = AgentChannelConnection.normalizedId(request.connectionId)
        guard rateLimiter.allow(ip: request.sourceAddress) else {
            bump(connectionId) { $0.rateLimited += 1 }
            return .error(429, code: "rate_limited", message: "Too many channel requests. Try again shortly.")
        }
        bump(connectionId) { $0.lastInboundAt = request.receivedAt }

        let resolution = resolveConnection(kind: request.kind, connectionId: connectionId)
        let connection: AgentChannelConnection
        let n8n: AgentChannelN8nConfiguration
        switch resolution {
        case .failure(let response):
            return response
        case .success(let resolved):
            connection = resolved.connection
            n8n = resolved.n8n
        }

        if let refusal = transportPolicyRefusal(n8n, request: request) {
            return refusal
        }

        // Verify BEFORE parsing. A bad secret never learns anything about
        // how the body would have been interpreted.
        guard request.body.count <= Self.maxBodyBytes else {
            return .error(413, code: "payload_too_large", message: "Body exceeds \(Self.maxBodyBytes) bytes.")
        }
        let verification = substrate.verifyWebhookSource(
            request: AgentChannelWebhookVerificationRequest(
                headers: request.headers,
                body: request.body,
                sourceAddress: request.sourceAddress,
                receivedAt: request.receivedAt
            ),
            policy: n8n.inboundVerification.policy(secret: resolveSecret(connection: connection, n8n: n8n))
        )
        guard verification.status == .verified else {
            bump(connectionId) {
                $0.signatureFailures += 1
                $0.inboundRejected += 1
                $0.lastFailureReason = "unauthorized"
            }
            await publishHealth(
                connection: connection,
                failure: "Inbound request failed \(n8n.inboundVerification.method.rawValue) verification."
            )
            return penalizing(
                .error(401, code: "unauthorized", message: "Channel request did not verify.", penalize: true),
                source: request.sourceAddress
            )
        }

        let envelope: AgentChannelN8nEnvelope
        do {
            envelope = try AgentChannelN8nEnvelope.parse(request.body)
        } catch let error as AgentChannelN8nEnvelopeError {
            bump(connectionId) {
                $0.inboundRejected += 1
                $0.lastFailureReason = error.code
            }
            return .error(400, code: error.code, message: error.message)
        } catch {
            bump(connectionId) { $0.inboundRejected += 1 }
            return .error(400, code: "invalid_payload", message: "Body could not be parsed.")
        }

        await activityCenter.record(
            connectionId: connection.id,
            providerEventId: envelope.eventId,
            stage: .received
        )
        receiveCounters[connection.id, default: (0, 0, 0, 0)].received += 1

        let authorization: AgentChannelInboundAuthorizationDecision
        let receive: AgentChannelReceiveResult
        do {
            try messageStore.openIfNeeded()
            authorization = try authorizationService.authorizeInboundMessage(
                AgentChannelInboundMessageAuthorizationRequest(
                    connectionId: connection.id,
                    providerEventId: envelope.eventId,
                    providerMessageId: envelope.eventId,
                    spaceId: AgentChannelN8nConfiguration.spaceId,
                    roomId: envelope.conversationId,
                    senderId: envelope.sender.id,
                    isBotMessage: envelope.sender.isBot,
                    isSelfMessage: false
                ),
                messageStore: messageStore
            )
            receive = try messageStore.recordReceiveEvent(
                connectionId: connection.id,
                providerEventId: envelope.eventId,
                authorization: authorization,
                message: envelope.storedMessage(connectionId: connection.id, receivedAt: request.receivedAt)
            )
        } catch {
            bump(connectionId) {
                $0.inboundRejected += 1
                $0.lastFailureReason = "store_error"
            }
            await activityCenter.record(
                connectionId: connection.id,
                providerEventId: envelope.eventId,
                stage: .failed,
                reason: error.localizedDescription
            )
            return .error(500, code: "store_error", message: "The channel message could not be recorded.")
        }

        switch receive.disposition {
        case .duplicate:
            bump(connectionId) { $0.inboundDuplicates += 1 }
            await activityCenter.record(
                connectionId: connection.id,
                providerEventId: envelope.eventId,
                stage: .rejected,
                reason: receive.authorizationReason ?? "duplicate_event"
            )
            let partition = partition(for: connection, n8n: n8n, envelope: envelope)
            return .json(
                200,
                [
                    "status": "duplicate",
                    "event_id": envelope.eventId,
                    "task_id": partition.sessionId.uuidString.lowercased(),
                    "session_id": partition.sessionId.uuidString.lowercased(),
                    "poll_url": Self.pollPath(
                        kind: request.kind,
                        connectionId: connection.id,
                        taskId: partition.sessionId
                    ),
                ]
            )
        case .denied:
            bump(connectionId) {
                $0.inboundRejected += 1
                $0.lastFailureReason = receive.authorizationReason
            }
            await activityCenter.record(
                connectionId: connection.id,
                providerEventId: envelope.eventId,
                stage: .rejected,
                reason: receive.authorizationReason
            )
            await publishHealth(connection: connection, failure: nil)
            return .json(
                202,
                [
                    "status": "rejected",
                    "event_id": envelope.eventId,
                    "reason": receive.authorizationReason ?? "denied",
                ]
            )
        case .accepted:
            break
        }

        receiveCounters[connection.id, default: (0, 0, 0, 0)].stored += 1
        await activityCenter.record(
            connectionId: connection.id,
            providerEventId: envelope.eventId,
            stage: .stored
        )

        let providerRoute = AgentChannelProviderRoute(
            conversationId: envelope.conversationId,
            threadId: n8n.inboundDispatch.continueThreads ? envelope.threadId : nil,
            replyAddress: envelope.replyToken,
            displayName: "n8n \(envelope.conversationId)"
        )
        let identity = ChannelIdentity(
            kind: .n8n,
            installationId: connection.id,
            groupId: envelope.conversationId,
            threadId: envelope.threadId,
            sender: ChannelSenderMetadata(
                senderId: envelope.sender.id,
                displayName: envelope.sender.display
            ),
            trustLevel: .verified
        )
        let submission = await relaySubmit(
            AgentChannelInboundRelayRequest(
                identity: identity,
                connectionId: connection.id,
                providerEventId: envelope.eventId,
                providerRoute: providerRoute,
                content: envelope.content,
                attachments: envelope.attachments.map(\.stored),
                settings: n8n.inboundDispatch,
                sourceLabel:
                    "n8n connection \(connection.id), conversation \(envelope.conversationId), sender \(envelope.sender.id)",
                reply: replyHandler(for: connection, envelope: envelope)
            )
        )

        let partition = partition(for: connection, n8n: n8n, envelope: envelope, submission: submission)
        let dispatchDescription: String
        switch submission {
        case .dispatched(let target, let rule):
            receiveCounters[connection.id, default: (0, 0, 0, 0)].attempted += 1
            taskOwners[partition.sessionId] = connection.id
            dispatchDescription = "dispatched"
            await activityCenter.record(
                connectionId: connection.id,
                providerEventId: envelope.eventId,
                stage: .dispatched,
                reason: await AgentChannelInboundActivityPresentation.dispatchReason(target: target, rule: rule)
            )
        case .suppressed(let reason):
            receiveCounters[connection.id, default: (0, 0, 0, 0)].suppressed += 1
            dispatchDescription = "suppressed:\(reason)"
            await activityCenter.record(
                connectionId: connection.id,
                providerEventId: envelope.eventId,
                stage: .dispatchSuppressed,
                reason: reason
            )
        }
        bump(connectionId) {
            $0.inboundAccepted += 1
            $0.lastAcceptedAt = request.receivedAt
        }
        await publishHealth(connection: connection, failure: nil)

        return .json(
            202,
            [
                "status": "accepted",
                "event_id": envelope.eventId,
                "dispatch": dispatchDescription,
                "task_id": partition.sessionId.uuidString.lowercased(),
                "session_id": partition.sessionId.uuidString.lowercased(),
                "poll_url": Self.pollPath(kind: request.kind, connectionId: connection.id, taskId: partition.sessionId),
            ]
        )
    }

    // MARK: Poll

    func handleTaskPoll(
        _ request: AgentChannelWebhookIngressRequest,
        taskId rawTaskId: String
    ) async -> AgentChannelWebhookIngressResponse {
        let connectionId = AgentChannelConnection.normalizedId(request.connectionId)
        guard rateLimiter.allow(ip: request.sourceAddress) else {
            bump(connectionId) { $0.rateLimited += 1 }
            return .error(429, code: "rate_limited", message: "Too many channel requests. Try again shortly.")
        }
        bump(connectionId) { $0.pollRequests += 1 }

        let connection: AgentChannelConnection
        let n8n: AgentChannelN8nConfiguration
        switch resolveConnection(kind: request.kind, connectionId: connectionId) {
        case .failure(let response):
            return response
        case .success(let resolved):
            connection = resolved.connection
            n8n = resolved.n8n
        }
        if let refusal = transportPolicyRefusal(n8n, request: request) {
            return refusal
        }

        // Polls carry an empty body; HMAC callers sign the empty string.
        let verification = substrate.verifyWebhookSource(
            request: AgentChannelWebhookVerificationRequest(
                headers: request.headers,
                body: request.body,
                sourceAddress: request.sourceAddress,
                receivedAt: request.receivedAt
            ),
            policy: n8n.inboundVerification.policy(secret: resolveSecret(connection: connection, n8n: n8n))
        )
        guard verification.status == .verified else {
            bump(connectionId) { $0.signatureFailures += 1 }
            return penalizing(
                .error(401, code: "unauthorized", message: "Channel request did not verify.", penalize: true),
                source: request.sourceAddress
            )
        }

        guard let taskId = UUID(uuidString: rawTaskId.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return .error(400, code: "invalid_task_id", message: "Invalid task UUID in path.")
        }
        let ownerPrefix = "agent-channel:\(connection.id):"
        let snapshot = await taskLookup(taskId)
        let owned: Bool
        if taskOwners[taskId] == connection.id {
            owned = true
        } else if let snapshot, snapshot.isChannelSource,
            snapshot.externalSessionKey?.hasPrefix(ownerPrefix) == true
        {
            owned = true
        } else {
            owned = false
        }
        guard owned, let snapshot else {
            // Unknown and foreign tasks are indistinguishable on purpose.
            return penalizing(
                .error(404, code: "task_not_found", message: "Task not found.", penalize: !owned),
                source: request.sourceAddress
            )
        }

        var body: [String: Any] = [
            "id": taskId.uuidString.lowercased(),
            "task_id": taskId.uuidString.lowercased(),
            "session_id": taskId.uuidString.lowercased(),
            "status": snapshot.status.rawValue,
            "connection_id": connection.id,
        ]
        if let output = snapshot.output, !output.isEmpty {
            let sanitized = ChannelRemoteSafetyGate.sanitizeResult(ChannelRemoteResultPayload(text: output))
            body["output"] = sanitized.text
            body["output_redacted"] = sanitized.redacted
            body["output_truncated"] = sanitized.truncated
        }
        if let summary = snapshot.summary, !summary.isEmpty {
            body["summary"] = ChannelRemoteSafetyGate.sanitizeResult(ChannelRemoteResultPayload(text: summary)).text
        }
        switch snapshot.status {
        case .completed: body["success"] = true
        case .failed, .cancelled: body["success"] = false
        case .queued, .running: break
        }
        return .json(200, body)
    }

    // MARK: Health

    func healthSnapshot(connectionId: String) -> AgentChannelWebhookIngressHealth {
        let id = AgentChannelConnection.normalizedId(connectionId)
        return health[id] ?? AgentChannelWebhookIngressHealth(connectionId: id)
    }

    func recordOutbound(connectionId: String, succeeded: Bool, at date: Date = Date()) {
        bump(AgentChannelConnection.normalizedId(connectionId)) {
            if succeeded {
                $0.outboundSent += 1
                $0.lastOutboundAt = date
            } else {
                $0.outboundFailed += 1
            }
        }
    }

    /// Test/ops hook: forget per-connection counters and ownership.
    func reset(connectionId: String? = nil) {
        if let connectionId {
            let id = AgentChannelConnection.normalizedId(connectionId)
            health.removeValue(forKey: id)
            receiveCounters.removeValue(forKey: id)
            taskOwners = taskOwners.filter { $0.value != id }
        } else {
            health.removeAll()
            receiveCounters.removeAll()
            taskOwners.removeAll()
        }
    }

    func ownerConnectionId(taskId: UUID) -> String? {
        taskOwners[taskId]
    }

    // MARK: Paths

    static func inboundPath(kind: String, connectionId: String) -> String {
        "/channels/\(kind)/\(AgentChannelConnection.normalizedId(connectionId))/inbound"
    }

    static func pollPath(kind: String, connectionId: String, taskId: UUID) -> String {
        "/channels/\(kind)/\(AgentChannelConnection.normalizedId(connectionId))/tasks/\(taskId.uuidString.lowercased())"
    }

    /// Parses `/channels/{kind}/{connection_id}/inbound` and
    /// `/channels/{kind}/{connection_id}/tasks/{task_id}`.
    enum Route: Equatable, Sendable {
        case inbound(kind: String, connectionId: String)
        case taskPoll(kind: String, connectionId: String, taskId: String)
    }

    static func route(for path: String) -> Route? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 4, parts[0] == "channels" else { return nil }
        let kind = parts[1]
        let connectionId = parts[2]
        guard !kind.isEmpty, !connectionId.isEmpty else { return nil }
        if parts.count == 4, parts[3] == "inbound" {
            return .inbound(kind: kind, connectionId: connectionId)
        }
        if parts.count == 5, parts[3] == "tasks", !parts[4].isEmpty {
            return .taskPoll(kind: kind, connectionId: connectionId, taskId: parts[4])
        }
        return nil
    }

    /// Request-log twin of the inbound headers with verification material
    /// removed. The secret must never reach Insights or the audit log.
    static func redactedHeaders(_ headers: [String: String]) -> [String: String] {
        var redacted: [String: String] = [:]
        for (key, value) in headers {
            let lowered = key.lowercased()
            if sensitiveHeaderNames.contains(lowered) || lowered.contains("secret") || lowered.contains("signature") {
                redacted[key] = "<redacted>"
            } else {
                redacted[key] = value
            }
        }
        return redacted
    }

    // MARK: - Private

    private func replyHandler(
        for connection: AgentChannelConnection,
        envelope: AgentChannelN8nEnvelope
    ) -> AgentChannelInboundReplyHandler? {
        if let replyHandlerFactory {
            return replyHandlerFactory(connection, envelope)
        }
        return AgentChannelN8nPreset.replyHandler(
            for: connection,
            envelope: envelope,
            runner: outboundRunner,
            ingress: self
        )
    }

    private struct ResolvedConnection {
        var connection: AgentChannelConnection
        var n8n: AgentChannelN8nConfiguration
    }

    private func resolveConnection(
        kind: String,
        connectionId: String
    ) -> Result<ResolvedConnection, AgentChannelWebhookIngressResponse> {
        guard let requestedKind = AgentChannelKind(rawValue: kind), requestedKind == .n8n else {
            return .failure(
                .error(400, code: "unsupported_kind", message: "Channel kind '\(kind)' has no webhook ingress.")
            )
        }
        guard !connectionId.isEmpty, let connection = connectionLookup(connectionId) else {
            return .failure(.error(404, code: "connection_not_found", message: "Channel connection not found."))
        }
        guard connection.kind == requestedKind else {
            return .failure(.error(400, code: "unsupported_kind", message: "Connection kind does not match the route."))
        }
        guard connection.enabled else {
            return .failure(.error(403, code: "connection_disabled", message: "Channel connection is disabled."))
        }
        guard let n8n = connection.n8n else {
            return .failure(
                .error(400, code: "unsupported_kind", message: "Connection is missing its n8n configuration.")
            )
        }
        return .success(ResolvedConnection(connection: connection, n8n: n8n))
    }

    private func transportPolicyRefusal(
        _ n8n: AgentChannelN8nConfiguration,
        request: AgentChannelWebhookIngressRequest
    ) -> AgentChannelWebhookIngressResponse? {
        if request.isSecureChannel || request.isLoopback { return nil }
        switch n8n.remoteTransportPolicy {
        case .plaintextAllowed:
            return nil
        case .secureChannelRequired:
            return .error(
                426,
                code: "secure_channel_required",
                message:
                    "This peer requires end-to-end encryption for agent requests. Upgrade Osaurus to a version that supports the secure channel."
            )
        }
    }

    private func resolveSecret(connection: AgentChannelConnection, n8n: AgentChannelN8nConfiguration) -> String? {
        let secret = secretResolver.secret(
            named: n8n.secretName,
            keychainId: n8n.secretName,
            connection: connection
        )
        guard let secret, !secret.isEmpty else { return nil }
        return secret
    }

    private func partition(
        for connection: AgentChannelConnection,
        n8n: AgentChannelN8nConfiguration,
        envelope: AgentChannelN8nEnvelope,
        submission: AgentChannelInboundRelaySubmission? = nil
    ) -> AgentChannelSessionPartition {
        let target: AgentDispatchTarget?
        if case .dispatched(let dispatchedTarget, _)? = submission {
            target = dispatchedTarget
        } else {
            target =
                AgentChannelDispatchRouter.resolve(
                    settings: n8n.inboundDispatch,
                    roomId: envelope.conversationId,
                    content: envelope.content
                )?.target ?? n8n.inboundDispatch.target
        }
        return substrate.makeSessionPartition(
            target: target,
            connectionId: connection.id,
            providerRoute: AgentChannelProviderRoute(
                conversationId: envelope.conversationId,
                threadId: n8n.inboundDispatch.continueThreads ? envelope.threadId : nil
            )
        )
    }

    /// A failed proof backs the source off, as `/pair` does on denial.
    private func penalizing(
        _ response: AgentChannelWebhookIngressResponse,
        source: String
    ) -> AgentChannelWebhookIngressResponse {
        if response.penalizeSource {
            rateLimiter.penalize(ip: source)
        }
        return response
    }

    private func bump(_ connectionId: String, _ mutate: (inout AgentChannelWebhookIngressHealth) -> Void) {
        guard !connectionId.isEmpty else { return }
        var row = health[connectionId] ?? AgentChannelWebhookIngressHealth(connectionId: connectionId)
        mutate(&row)
        health[connectionId] = row
    }

    private func publishHealth(connection: AgentChannelConnection, failure: String?) async {
        let counters = receiveCounters[connection.id] ?? (0, 0, 0, 0)
        let row = health[connection.id] ?? AgentChannelWebhookIngressHealth(connectionId: connection.id)
        let receiveEnabled = connection.n8n?.inboundDispatch.isConfigured ?? false
        let status: AgentChannelTransportHealthStatus
        let severity: AgentChannelTransportHealthSeverity
        let summary: String
        if let failure {
            status = .degraded
            severity = .warning
            summary = failure
        } else if row.inboundAccepted > 0 {
            status = .healthy
            severity = .info
            summary =
                "Verified n8n events are flowing (\(row.inboundAccepted) accepted, \(row.inboundRejected) rejected)."
        } else {
            status = .idle
            severity = .info
            summary = "Waiting for the first verified n8n event."
        }
        await transportHealth.update(
            AgentChannelTransportHealthState(
                connectionId: connection.id,
                transportId: Self.transportId,
                provider: .n8n,
                status: status,
                severity: severity,
                summary: summary,
                detail: row.lastFailureReason,
                isRunning: connection.enabled,
                receiveEnabled: receiveEnabled,
                lastSuccessAt: row.lastAcceptedAt,
                lastFailureAt: failure == nil ? nil : row.lastInboundAt,
                consecutiveFailures: 0,
                lastReceivedCount: counters.received,
                lastStoredCount: counters.stored,
                dispatchAttemptedCount: counters.attempted,
                dispatchSuppressedCount: counters.suppressed
            )
        )
    }

    @Sendable
    private static func defaultTaskLookup(_ taskId: UUID) async -> AgentChannelWebhookTaskSnapshot? {
        await MainActor.run {
            if let state = BackgroundTaskManager.shared.taskState(for: taskId) {
                let turns = state.chatSession?.turns ?? []
                let status: AgentChannelWebhookTaskSnapshot.Status
                var summary: String?
                switch state.status {
                case .queued: status = .queued
                case .running, .waitingForInput: status = .running
                case .completed(let text):
                    status = .completed
                    summary = text
                case .failed(let text):
                    status = .failed
                    summary = text
                case .cancelled: status = .cancelled
                }
                let output: String?
                switch status {
                case .completed:
                    output = AgentChannelInboundRelay.latestAssistantReply(in: turns)
                case .running, .queued, .failed, .cancelled:
                    // Partial transcript while streaming, mirroring /tasks/{id}.
                    output = turns.last.flatMap { $0.role == .assistant && !$0.contentIsBlank ? $0.content : nil }
                }
                return AgentChannelWebhookTaskSnapshot(
                    status: status,
                    output: output,
                    summary: summary,
                    externalSessionKey: state.externalSessionKey,
                    isChannelSource: state.source == .channel
                )
            }
            // Finished tasks age out of the manager; fall back to the persisted session.
            guard let stored = ChatSessionStore.load(id: taskId) else { return nil }
            let reply = AgentChannelInboundRelay.latestAssistantReply(in: stored.turns)
            return AgentChannelWebhookTaskSnapshot(
                status: reply == nil ? .failed : .completed,
                output: reply,
                summary: reply == nil ? "The agent completed without a visible reply." : nil,
                externalSessionKey: stored.externalSessionKey,
                isChannelSource: stored.source == .channel
            )
        }
    }
}
