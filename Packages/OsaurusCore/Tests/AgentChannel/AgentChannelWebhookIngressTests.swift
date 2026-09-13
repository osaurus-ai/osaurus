//
//  AgentChannelWebhookIngressTests.swift
//  osaurusTests
//
//  Contract coverage for the n8n webhook ingress: verify-before-parse,
//  fail-closed authorization, dedupe, transport policy, poll ownership,
//  and secret non-leakage. NIO-free: the ingress actor is exercised directly.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct AgentChannelWebhookIngressTests {
    private static let secret = "n8n-shared-secret-never-in-output"
    private static let connectionId = "n8n-main"
    private static let agentId = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    // MARK: - Fixtures

    private final class RelayRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [AgentChannelInboundRelayRequest] = []
        var submission: AgentChannelInboundRelaySubmission = .dispatched(
            agentId: AgentChannelWebhookIngressTests.agentId,
            rule: "default"
        )

        func record(_ request: AgentChannelInboundRelayRequest) -> AgentChannelInboundRelaySubmission {
            lock.withLock { requests.append(request) }
            return submission
        }

        var all: [AgentChannelInboundRelayRequest] { lock.withLock { requests } }
    }

    private struct FixedSecretResolver: AgentChannelSecretResolving {
        var secret: String?
        func secret(named name: String, keychainId: String, connection: AgentChannelConnection) -> String? {
            secret
        }
    }

    private struct Harness {
        let ingress: AgentChannelWebhookIngress
        let store: AgentChannelMessageStore
        let activity: AgentChannelInboundActivityCenter
        let relay: RelayRecorder
        let health: AgentChannelTransportHealthCenter
    }

    private static func connection(
        id: String = connectionId,
        enabled: Bool = true,
        method: AgentChannelSourceVerificationMethod = .sharedSecretHeader,
        policy: AgentChannelN8nRemoteTransportPolicy = .secureChannelRequired,
        senders: [String] = ["user-1"],
        conversations: [String] = ["conv-1"],
        dispatchEnabled: Bool = true
    ) -> AgentChannelConnection {
        AgentChannelConnection(
            id: id,
            name: "n8n Main",
            kind: .n8n,
            enabled: enabled,
            supportedActions: [.diagnostics, .sendMessage],
            spaceAllowlist: [AgentChannelN8nConfiguration.spaceId],
            inboundAuthorization: AgentChannelInboundAuthorizationPolicy(
                senderAllowlist: senders,
                roomAllowlist: conversations
            ),
            n8n: AgentChannelN8nConfiguration(
                inboundVerification: AgentChannelN8nInboundVerification(method: method),
                inboundDispatch: AgentChannelInboundDispatchConfiguration(
                    enabled: dispatchEnabled,
                    targetAgentId: agentId,
                    autoReplyEnabled: false
                ),
                remoteTransportPolicy: policy
            )
        )
    }

    private func withHarness(
        connections: [AgentChannelConnection],
        resolverSecret: String? = AgentChannelWebhookIngressTests.secret,
        rateLimiter: PairingRateLimiter = PairingRateLimiter(window: 60, maxPerWindow: 1_000, denialCooldown: 0),
        taskLookup: AgentChannelWebhookIngress.TaskLookup? = nil,
        _ body: @Sendable (Harness) async throws -> Void
    ) async throws {
        try await AgentChannelConfigurationTestLock.shared.run {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("osaurus-n8n-ingress-\(UUID().uuidString)", isDirectory: true)
            let previous = AgentChannelConfigurationStore.overrideDirectory
            AgentChannelConfigurationStore.overrideDirectory = root
            defer {
                AgentChannelConfigurationStore.overrideDirectory = previous
                try? FileManager.default.removeItem(at: root)
            }
            try AgentChannelConfigurationStore.save(AgentChannelConfiguration(connections: connections))

            let store = AgentChannelMessageStore()
            try store.openInMemory()
            let activity = AgentChannelInboundActivityCenter()
            let health = AgentChannelTransportHealthCenter()
            let relay = RelayRecorder()
            let ingress = AgentChannelWebhookIngress(
                secretResolver: FixedSecretResolver(secret: resolverSecret),
                messageStore: store,
                activityCenter: activity,
                transportHealth: health,
                relaySubmit: { request in relay.record(request) },
                taskLookup: taskLookup,
                rateLimiter: rateLimiter
            )
            try await body(Harness(ingress: ingress, store: store, activity: activity, relay: relay, health: health))
        }
    }

    private static func envelope(
        eventId: String = "evt-1",
        conversationId: String = "conv-1",
        senderId: String = "user-1",
        content: String = "Summarize today's invoices",
        version: Int = 1,
        isBot: Bool = false
    ) -> Data {
        let object: [String: Any] = [
            "v": version,
            "event_id": eventId,
            "conversation_id": conversationId,
            "thread_id": "thread-9",
            "sender": ["id": senderId, "display": "Ada", "is_bot": isBot],
            "content": content,
            "attachments": [["id": "att-1", "filename": "a.pdf", "content_type": "application/pdf", "size_bytes": 12]],
            "reply_token": "rt-1",
        ]
        return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private static func request(
        body: Data,
        headers: [String: String]? = nil,
        kind: String = "n8n",
        connectionId: String = connectionId,
        isLoopback: Bool = true,
        isSecureChannel: Bool = false,
        source: String = "127.0.0.1"
    ) -> AgentChannelWebhookIngressRequest {
        AgentChannelWebhookIngressRequest(
            kind: kind,
            connectionId: connectionId,
            headers: headers ?? ["X-Osaurus-Channel-Secret": secret, "Content-Type": "application/json"],
            body: body,
            sourceAddress: source,
            isLoopback: isLoopback,
            isSecureChannel: isSecureChannel
        )
    }

    private static func json(_ response: AgentChannelWebhookIngressResponse) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(response.body.utf8))) as? [String: Any] ?? [:]
    }

    private static func errorCode(_ response: AgentChannelWebhookIngressResponse) -> String? {
        (json(response)["error"] as? [String: Any])?["code"] as? String
    }

    // MARK: - Verify before parse

    @Test func badSecretWithMalformedBodyIsRejectedBeforeAnyParsingOrStorage() async throws {
        try await withHarness(connections: [Self.connection()]) { harness in
            let response = await harness.ingress.handleInbound(
                Self.request(body: Data("{not json".utf8), headers: ["X-Osaurus-Channel-Secret": "wrong"])
            )
            #expect(response.status == 401)
            #expect(Self.errorCode(response) == "unauthorized")
            #expect(response.penalizeSource)
            #expect(!response.body.contains(Self.secret))
            // Nothing was interpreted: no activity stage, no store rows, no relay.
            #expect(await harness.activity.recent(connectionId: Self.connectionId).isEmpty)
            try #expect(harness.store.recentAuditEvents(connectionId: Self.connectionId, limit: 10).isEmpty)
            #expect(harness.relay.all.isEmpty)
            let health = await harness.ingress.healthSnapshot(connectionId: Self.connectionId)
            #expect(health.signatureFailures == 1)
            #expect(health.inboundAccepted == 0)
        }
    }

    @Test func missingSecretInKeychainFailsClosed() async throws {
        try await withHarness(connections: [Self.connection()], resolverSecret: nil) { harness in
            let response = await harness.ingress.handleInbound(Self.request(body: Self.envelope()))
            #expect(response.status == 401)
            #expect(harness.relay.all.isEmpty)
        }
    }

    // MARK: - Happy path

    @Test func sharedSecretEnvelopeIsStoredRelayedAndAcceptedWithDeterministicTaskId() async throws {
        try await withHarness(connections: [Self.connection()]) { harness in
            let response = await harness.ingress.handleInbound(Self.request(body: Self.envelope()))
            #expect(response.status == 202)
            let body = Self.json(response)
            #expect(body["status"] as? String == "accepted")
            #expect(body["dispatch"] as? String == "dispatched")
            #expect(body["event_id"] as? String == "evt-1")

            let expected = AgentChannelAsyncSubstrate.shared.makeSessionPartition(
                target: .local(Self.agentId),
                connectionId: Self.connectionId,
                providerRoute: AgentChannelProviderRoute(conversationId: "conv-1", threadId: "thread-9")
            )
            #expect(body["task_id"] as? String == expected.sessionId.uuidString.lowercased())
            #expect(body["session_id"] as? String == expected.sessionId.uuidString.lowercased())
            #expect(
                body["poll_url"] as? String
                    == "/channels/n8n/\(Self.connectionId)/tasks/\(expected.sessionId.uuidString.lowercased())"
            )
            #expect(await harness.ingress.ownerConnectionId(taskId: expected.sessionId) == Self.connectionId)

            let relayed = harness.relay.all
            #expect(relayed.count == 1)
            #expect(relayed.first?.identity.kind == .n8n)
            #expect(relayed.first?.identity.trustLevel == .verified)
            #expect(relayed.first?.identity.installationId == Self.connectionId)
            #expect(relayed.first?.identity.groupId == "conv-1")
            #expect(relayed.first?.providerRoute.threadId == "thread-9")
            #expect(relayed.first?.providerRoute.displayName == "n8n conv-1")
            #expect(relayed.first?.sourceLabel == "n8n connection n8n-main, conversation conv-1, sender user-1")
            #expect(relayed.first?.content == "Summarize today's invoices")
            #expect(relayed.first?.attachments.first?.providerId == "att-1")
            #expect(relayed.first?.settings.requireMention == false)
            #expect(relayed.first?.reply == nil)

            let stored = try harness.store.recentMessages(connectionId: Self.connectionId, roomId: "conv-1", limit: 5)
            #expect(stored.count == 1)
            #expect(stored.first?.providerMessageId == "evt-1")
            #expect(stored.first?.authorId == "user-1")
            #expect(stored.first?.authorName == "Ada")
            #expect(stored.first?.attachments.first?.filename == "a.pdf")

            let stages = await harness.activity.recent(connectionId: Self.connectionId).map(\.stage)
            #expect(stages == [.dispatched, .stored, .received])

            let health = await harness.ingress.healthSnapshot(connectionId: Self.connectionId)
            #expect(health.inboundAccepted == 1)
            #expect(health.lastAcceptedAt != nil)
            let transport = await harness.health.state(
                connectionId: Self.connectionId,
                transportId: AgentChannelWebhookIngress.transportId
            )
            #expect(transport?.status == .healthy)
            #expect(transport?.provider == .n8n)
            #expect(transport?.dispatchAttemptedCount == 1)
        }
    }

    @Test func hmacVerificationAcceptsPrefixedAndBareHexSignatures() async throws {
        try await withHarness(connections: [Self.connection(method: .hmacSHA256)]) { harness in
            let first = Self.envelope(eventId: "evt-hmac-1")
            let firstHex = AgentChannelAsyncSubstrate.hmacSHA256Hex(body: first, secret: Self.secret)
            let prefixed = await harness.ingress.handleInbound(
                Self.request(body: first, headers: ["X-Osaurus-Channel-Signature": "sha256=\(firstHex)"])
            )
            #expect(prefixed.status == 202)

            let second = Self.envelope(eventId: "evt-hmac-2")
            let secondHex = AgentChannelAsyncSubstrate.hmacSHA256Hex(body: second, secret: Self.secret)
            let bare = await harness.ingress.handleInbound(
                Self.request(body: second, headers: ["x-osaurus-channel-signature": secondHex.uppercased()])
            )
            #expect(bare.status == 202)

            // A signature over different bytes must not verify.
            let tampered = await harness.ingress.handleInbound(
                Self.request(
                    body: Self.envelope(eventId: "evt-hmac-3"),
                    headers: ["X-Osaurus-Channel-Signature": "sha256=\(firstHex)"]
                )
            )
            #expect(tampered.status == 401)
            // Shared-secret header is not a substitute when HMAC is configured.
            let wrongMethod = await harness.ingress.handleInbound(
                Self.request(body: Self.envelope(eventId: "evt-hmac-4"))
            )
            #expect(wrongMethod.status == 401)
            #expect(harness.relay.all.count == 2)
        }
    }

    // MARK: - Fail-closed authorization

    @Test func unlistedSenderIsRejectedWithoutDispatchButAudited() async throws {
        try await withHarness(connections: [Self.connection()]) { harness in
            let response = await harness.ingress.handleInbound(
                Self.request(body: Self.envelope(senderId: "intruder"))
            )
            #expect(response.status == 202)
            let body = Self.json(response)
            #expect(body["status"] as? String == "rejected")
            #expect(body["reason"] as? String == "sender_not_allowlisted")
            #expect(body["task_id"] == nil)
            #expect(harness.relay.all.isEmpty)
            let audit = try harness.store.recentAuditEvents(connectionId: Self.connectionId, limit: 10)
            #expect(audit.count == 1)
            #expect(audit.first?.reason == "sender_not_allowlisted")
            #expect(audit.first?.shouldDispatch == false)
            try #expect(
                harness.store.recentMessages(connectionId: Self.connectionId, roomId: "conv-1", limit: 5).isEmpty
            )
            let stages = await harness.activity.recent(connectionId: Self.connectionId).map(\.stage)
            #expect(stages == [.rejected, .received])
        }
    }

    @Test func unlistedConversationAndBotSendersAreRejected() async throws {
        try await withHarness(connections: [Self.connection()]) { harness in
            let room = await harness.ingress.handleInbound(
                Self.request(body: Self.envelope(eventId: "evt-room", conversationId: "conv-other"))
            )
            #expect(Self.json(room)["reason"] as? String == "room_not_allowlisted")
            let bot = await harness.ingress.handleInbound(
                Self.request(body: Self.envelope(eventId: "evt-bot", isBot: true))
            )
            #expect(Self.json(bot)["reason"] as? String == "bot_message_denied")
            #expect(harness.relay.all.isEmpty)
        }
    }

    // MARK: - Dedupe

    @Test func duplicateEventIdAcknowledgesWithoutSecondDispatch() async throws {
        try await withHarness(connections: [Self.connection()]) { harness in
            let first = await harness.ingress.handleInbound(Self.request(body: Self.envelope()))
            #expect(first.status == 202)
            let second = await harness.ingress.handleInbound(Self.request(body: Self.envelope()))
            #expect(second.status == 200)
            let body = Self.json(second)
            #expect(body["status"] as? String == "duplicate")
            // The duplicate still points the caller at the same pollable task.
            #expect(body["task_id"] as? String == Self.json(first)["task_id"] as? String)
            #expect(harness.relay.all.count == 1)
            let health = await harness.ingress.healthSnapshot(connectionId: Self.connectionId)
            #expect(health.inboundAccepted == 1)
            #expect(health.inboundDuplicates == 1)
        }
    }

    // MARK: - Envelope contract

    @Test func envelopeVersionAndShapeAreEnforcedAfterVerification() async throws {
        try await withHarness(connections: [Self.connection()]) { harness in
            let version = await harness.ingress.handleInbound(Self.request(body: Self.envelope(version: 2)))
            #expect(version.status == 400)
            #expect(Self.errorCode(version) == "unsupported_envelope_version")

            let empty = await harness.ingress.handleInbound(Self.request(body: Self.envelope(content: "   ")))
            #expect(empty.status == 400)
            #expect(Self.errorCode(empty) == "invalid_payload")

            let notObject = await harness.ingress.handleInbound(Self.request(body: Data("[1,2]".utf8)))
            #expect(notObject.status == 400)
            #expect(Self.errorCode(notObject) == "invalid_payload")

            var missingSender = (try? JSONSerialization.jsonObject(with: Self.envelope())) as? [String: Any] ?? [:]
            missingSender["sender"] = nil
            let missing = await harness.ingress.handleInbound(
                Self.request(body: try JSONSerialization.data(withJSONObject: missingSender))
            )
            #expect(missing.status == 400)
            #expect(Self.json(missing).description.contains("sender.id"))
            #expect(harness.relay.all.isEmpty)
            #expect(await harness.activity.recent(connectionId: Self.connectionId).isEmpty)
        }
    }

    @Test func envelopeParserNormalizesAttachmentsAndPayload() throws {
        let envelope = try AgentChannelN8nEnvelope.parse(Self.envelope())
        #expect(envelope.version == 1)
        #expect(envelope.threadId == "thread-9")
        #expect(envelope.replyToken == "rt-1")
        #expect(envelope.attachments.first?.stored.kind == .file)
        #expect(envelope.attachments.first?.stored.sizeBytes == 12)
        let stored = envelope.storedMessage(connectionId: "n8n-main")
        #expect(stored.roomId == "conv-1")
        #expect(stored.threadId == "thread-9")
        #expect(stored.direction == .inbound)
        #expect(stored.payloadJSON.contains("\"event_id\":\"evt-1\""))
    }

    // MARK: - Connection resolution

    @Test func unknownDisabledAndForeignKindConnectionsAreRefused() async throws {
        let custom = AgentChannelConnection(
            id: "custom-1",
            name: "Custom",
            kind: .customHTTP,
            supportedActions: [.diagnostics],
            customHTTP: AgentChannelCustomHTTPConfiguration(baseURL: "https://example.com", actions: [:])
        )
        try await withHarness(connections: [Self.connection(enabled: false), custom]) { harness in
            let unknown = await harness.ingress.handleInbound(
                Self.request(body: Self.envelope(), connectionId: "nope")
            )
            #expect(unknown.status == 404)
            #expect(Self.errorCode(unknown) == "connection_not_found")

            let disabled = await harness.ingress.handleInbound(Self.request(body: Self.envelope()))
            #expect(disabled.status == 403)
            #expect(Self.errorCode(disabled) == "connection_disabled")

            let foreign = await harness.ingress.handleInbound(
                Self.request(body: Self.envelope(), connectionId: "custom-1")
            )
            #expect(foreign.status == 400)
            #expect(Self.errorCode(foreign) == "unsupported_kind")

            let badKind = await harness.ingress.handleInbound(
                Self.request(body: Self.envelope(), kind: "zapier")
            )
            #expect(badKind.status == 400)
            #expect(Self.errorCode(badKind) == "unsupported_kind")
            #expect(harness.relay.all.isEmpty)
        }
    }

    // MARK: - Remote transport policy

    @Test func remoteCallersNeedSecureChannelUnlessPlaintextIsExplicitlyAllowed() async throws {
        try await withHarness(connections: [Self.connection()]) { harness in
            let remote = await harness.ingress.handleInbound(
                Self.request(body: Self.envelope(), isLoopback: false, source: "172.17.0.2")
            )
            #expect(remote.status == 426)
            #expect(Self.errorCode(remote) == "secure_channel_required")
            #expect(harness.relay.all.isEmpty)

            let secure = await harness.ingress.handleInbound(
                Self.request(body: Self.envelope(eventId: "evt-secure"), isLoopback: false, isSecureChannel: true)
            )
            #expect(secure.status == 202)
        }
        try await withHarness(connections: [Self.connection(policy: .plaintextAllowed)]) { harness in
            let remote = await harness.ingress.handleInbound(
                Self.request(body: Self.envelope(), isLoopback: false, source: "172.17.0.2")
            )
            #expect(remote.status == 202)
            // The policy only relaxes transport, never verification.
            let unauthenticated = await harness.ingress.handleInbound(
                Self.request(
                    body: Self.envelope(eventId: "evt-2"),
                    headers: [:],
                    isLoopback: false,
                    source: "172.17.0.2"
                )
            )
            #expect(unauthenticated.status == 401)
        }
    }

    // MARK: - Dispatch suppression

    @Test func suppressedDispatchStillAcceptsAndReportsReason() async throws {
        try await withHarness(connections: [Self.connection()]) { harness in
            harness.relay.submission = .suppressed("inbound_agent_unavailable")
            let response = await harness.ingress.handleInbound(Self.request(body: Self.envelope()))
            #expect(response.status == 202)
            #expect(Self.json(response)["dispatch"] as? String == "suppressed:inbound_agent_unavailable")
            let stages = await harness.activity.recent(connectionId: Self.connectionId).map(\.stage)
            #expect(stages.first == .dispatchSuppressed)
        }
    }

    // MARK: - Poll

    @Test func pollReturnsSanitizedOutputForOwnedTasksAndHidesForeignOnes() async throws {
        let ownTask = AgentChannelAsyncSubstrate.shared.makeSessionPartition(
            target: .local(Self.agentId),
            connectionId: Self.connectionId,
            providerRoute: AgentChannelProviderRoute(conversationId: "conv-1", threadId: "thread-9")
        ).sessionId
        let foreignTask = UUID()
        let unownedButKeyed = UUID()
        let lookup: AgentChannelWebhookIngress.TaskLookup = { id in
            switch id {
            case ownTask:
                return AgentChannelWebhookTaskSnapshot(
                    status: .completed,
                    output: "Here is the total: 42 (api_key=sk-live-ABCDEFGHIJKLMNOPQRSTUVWXYZ123456)",
                    summary: "Chat completed",
                    externalSessionKey: "agent-channel:n8n-main:abc:s0",
                    isChannelSource: true
                )
            case foreignTask:
                return AgentChannelWebhookTaskSnapshot(
                    status: .completed,
                    output: "private",
                    summary: nil,
                    externalSessionKey: "agent-channel:other-connection:abc:s0",
                    isChannelSource: true
                )
            case unownedButKeyed:
                return AgentChannelWebhookTaskSnapshot(
                    status: .running,
                    output: nil,
                    summary: nil,
                    externalSessionKey: "agent-channel:n8n-main:zzz:s0",
                    isChannelSource: true
                )
            default:
                return nil
            }
        }
        try await withHarness(connections: [Self.connection()], taskLookup: lookup) { harness in
            // Dispatch records ownership of `ownTask`.
            _ = await harness.ingress.handleInbound(Self.request(body: Self.envelope()))

            let owned = await harness.ingress.handleTaskPoll(
                Self.request(body: Data()),
                taskId: ownTask.uuidString
            )
            #expect(owned.status == 200)
            let body = Self.json(owned)
            #expect(body["status"] as? String == "completed")
            #expect(body["success"] as? Bool == true)
            #expect(body["task_id"] as? String == ownTask.uuidString.lowercased())
            let output = body["output"] as? String ?? ""
            #expect(output.contains("42"))
            #expect(!output.contains("sk-live-ABCDEFGHIJKLMNOPQRSTUVWXYZ123456"))
            #expect(body["output_redacted"] as? Bool == true)

            // Ownership by external session key prefix (task not recorded in-memory).
            let keyed = await harness.ingress.handleTaskPoll(
                Self.request(body: Data()),
                taskId: unownedButKeyed.uuidString
            )
            #expect(keyed.status == 200)
            #expect(Self.json(keyed)["status"] as? String == "running")
            #expect(Self.json(keyed)["success"] == nil)

            let foreign = await harness.ingress.handleTaskPoll(
                Self.request(body: Data()),
                taskId: foreignTask.uuidString
            )
            #expect(foreign.status == 404)
            #expect(Self.errorCode(foreign) == "task_not_found")
            #expect(!foreign.body.contains("private"))

            let unknown = await harness.ingress.handleTaskPoll(
                Self.request(body: Data()),
                taskId: UUID().uuidString
            )
            #expect(unknown.status == 404)

            let malformed = await harness.ingress.handleTaskPoll(
                Self.request(body: Data()),
                taskId: "not-a-uuid"
            )
            #expect(malformed.status == 400)

            let unauthenticated = await harness.ingress.handleTaskPoll(
                Self.request(body: Data(), headers: [:]),
                taskId: ownTask.uuidString
            )
            #expect(unauthenticated.status == 401)

            let remote = await harness.ingress.handleTaskPoll(
                Self.request(body: Data(), isLoopback: false, source: "10.0.0.9"),
                taskId: ownTask.uuidString
            )
            #expect(remote.status == 426)
        }
    }

    @Test func pollWithHMACSignsTheEmptyBody() async throws {
        let task = UUID()
        let lookup: AgentChannelWebhookIngress.TaskLookup = { id in
            id == task
                ? AgentChannelWebhookTaskSnapshot(
                    status: .queued,
                    output: nil,
                    summary: nil,
                    externalSessionKey: "agent-channel:n8n-main:q:s0",
                    isChannelSource: true
                )
                : nil
        }
        try await withHarness(connections: [Self.connection(method: .hmacSHA256)], taskLookup: lookup) { harness in
            let signature = AgentChannelAsyncSubstrate.hmacSHA256Hex(body: Data(), secret: Self.secret)
            let response = await harness.ingress.handleTaskPoll(
                Self.request(body: Data(), headers: ["X-Osaurus-Channel-Signature": "sha256=\(signature)"]),
                taskId: task.uuidString
            )
            #expect(response.status == 200)
            #expect(Self.json(response)["status"] as? String == "queued")
        }
    }

    // MARK: - Rate limiting

    @Test func dedicatedRateLimiterReturns429AndPenalizesBadSecrets() async throws {
        let limiter = PairingRateLimiter(window: 60, maxPerWindow: 2, denialCooldown: 60)
        try await withHarness(connections: [Self.connection()], rateLimiter: limiter) { harness in
            let first = await harness.ingress.handleInbound(Self.request(body: Self.envelope(eventId: "a")))
            #expect(first.status == 202)
            let second = await harness.ingress.handleInbound(Self.request(body: Self.envelope(eventId: "b")))
            #expect(second.status == 202)
            let third = await harness.ingress.handleInbound(Self.request(body: Self.envelope(eventId: "c")))
            #expect(third.status == 429)
            #expect(Self.errorCode(third) == "rate_limited")
            // Another source is unaffected until it fails verification, after
            // which the denial cooldown blocks it immediately.
            let other = await harness.ingress.handleInbound(
                Self.request(
                    body: Self.envelope(eventId: "d"),
                    headers: ["X-Osaurus-Channel-Secret": "wrong"],
                    source: "192.168.1.20"
                )
            )
            #expect(other.status == 401)
            let afterPenalty = await harness.ingress.handleInbound(
                Self.request(body: Self.envelope(eventId: "e"), source: "192.168.1.20")
            )
            #expect(afterPenalty.status == 429)
        }
    }

    // MARK: - Secret hygiene

    @Test func secretNeverAppearsInResponsesActivityOrAudit() async throws {
        try await withHarness(connections: [Self.connection()]) { harness in
            var responses: [AgentChannelWebhookIngressResponse] = []
            responses.append(await harness.ingress.handleInbound(Self.request(body: Self.envelope())))
            responses.append(await harness.ingress.handleInbound(Self.request(body: Self.envelope())))
            responses.append(
                await harness.ingress.handleInbound(Self.request(body: Self.envelope(senderId: "intruder")))
            )
            responses.append(
                await harness.ingress.handleInbound(
                    Self.request(body: Self.envelope(), headers: ["X-Osaurus-Channel-Secret": "nope"])
                )
            )
            for response in responses {
                #expect(!response.body.contains(Self.secret))
            }
            for event in await harness.activity.recent(connectionId: Self.connectionId) {
                #expect(event.reason?.contains(Self.secret) != true)
            }
            for row in try harness.store.recentAuditEvents(connectionId: Self.connectionId, limit: 20) {
                #expect(!row.redactedSummary.contains(Self.secret))
                #expect(!row.metadataJSON.contains(Self.secret))
            }
            let redacted = AgentChannelWebhookIngress.redactedHeaders([
                "X-Osaurus-Channel-Secret": Self.secret,
                "x-osaurus-channel-signature": "sha256=abc",
                "Authorization": "Bearer osk-v1",
                "Content-Type": "application/json",
            ])
            #expect(redacted["X-Osaurus-Channel-Secret"] == "<redacted>")
            #expect(redacted["x-osaurus-channel-signature"] == "<redacted>")
            #expect(redacted["Authorization"] == "<redacted>")
            #expect(redacted["Content-Type"] == "application/json")
        }
    }

    // MARK: - Routing helpers

    @Test func routeParserRecognizesInboundAndPollPathsOnly() {
        #expect(
            AgentChannelWebhookIngress.route(for: "/channels/n8n/n8n-main/inbound")
                == .inbound(kind: "n8n", connectionId: "n8n-main")
        )
        #expect(
            AgentChannelWebhookIngress.route(for: "/channels/n8n/n8n-main/tasks/abc")
                == .taskPoll(kind: "n8n", connectionId: "n8n-main", taskId: "abc")
        )
        #expect(AgentChannelWebhookIngress.route(for: "/channels/n8n/n8n-main") == nil)
        #expect(AgentChannelWebhookIngress.route(for: "/channels/n8n/n8n-main/outbound") == nil)
        #expect(AgentChannelWebhookIngress.route(for: "/channels/n8n/n8n-main/tasks") == nil)
        #expect(AgentChannelWebhookIngress.route(for: "/channels/n8n/n8n-main/tasks/a/b") == nil)
        #expect(AgentChannelWebhookIngress.route(for: "/tasks/abc") == nil)
    }

    // MARK: - Model

    @Test func n8nConfigurationDecodesAdditivelyAndForcesRequireMentionOff() throws {
        let legacy = Data(
            """
            {"id":"n8n-legacy","name":"Legacy","kind":"n8n","supportedActions":["diagnostics"]}
            """.utf8
        )
        let decodedLegacy = try JSONDecoder().decode(AgentChannelConnection.self, from: legacy)
        #expect(decodedLegacy.kind == .n8n)
        #expect(decodedLegacy.n8n == nil)

        let full = Data(
            """
            {"id":"n8n-full","name":"Full","kind":"n8n","supportedActions":["diagnostics"],
             "n8n":{"inboundVerification":{"method":"shared_secret_header"},
                    "inboundDispatch":{"enabled":true,"requireMention":true},
                    "remoteTransportPolicy":"plaintext_allowed",
                    "outbound":{"webhookURL":" https://n8n.example.com/webhook/x "}}}
            """.utf8
        )
        let decoded = try JSONDecoder().decode(AgentChannelConnection.self, from: full)
        let n8n = try #require(decoded.n8n)
        #expect(n8n.inboundVerification.method == .sharedSecretHeader)
        #expect(n8n.inboundVerification.effectiveHeaderName == "X-Osaurus-Channel-Secret")
        #expect(n8n.inboundDispatch.requireMention == false)
        #expect(n8n.remoteTransportPolicy == .plaintextAllowed)
        #expect(n8n.outbound.webhookURL == "https://n8n.example.com/webhook/x")
        #expect(n8n.outbound.signBodies)
        #expect(n8n.secretName == "webhook")

        let roundTrip = try JSONDecoder().decode(
            AgentChannelConnection.self,
            from: JSONEncoder().encode(decoded)
        )
        #expect(roundTrip == decoded)

        // `none` is never accepted as an n8n verification method.
        let none = AgentChannelN8nInboundVerification(method: .none)
        #expect(none.method == .hmacSHA256)
        #expect(none.effectiveHeaderName == "X-Osaurus-Channel-Signature")
    }

    @Test func connectionManagerValidatesN8nConnections() async throws {
        try await AgentChannelConfigurationTestLock.shared.run {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("osaurus-n8n-manager-\(UUID().uuidString)", isDirectory: true)
            let previous = AgentChannelConfigurationStore.overrideDirectory
            AgentChannelConfigurationStore.overrideDirectory = root
            defer {
                AgentChannelConfigurationStore.overrideDirectory = previous
                try? FileManager.default.removeItem(at: root)
            }
            let manager = AgentChannelConnectionManager()

            var missingBlock = Self.connection()
            missingBlock.n8n = nil
            #expect(throws: AgentChannelConnectionManagerError.missingN8nConfiguration("n8n-main")) {
                try manager.upsertConnection(missingBlock)
            }

            var badURL = Self.connection()
            badURL.n8n?.outbound = AgentChannelN8nOutboundConfiguration(webhookURL: "not a url")
            #expect(throws: AgentChannelConnectionManagerError.invalidN8nOutboundURL("not a url")) {
                try manager.upsertConnection(badURL)
            }

            var badHeader = Self.connection()
            badHeader.n8n?.inboundVerification.headerName = "X Bad Header"
            #expect(throws: AgentChannelConnectionManagerError.invalidN8nVerificationHeader("X Bad Header")) {
                try manager.upsertConnection(badHeader)
            }

            // C2 refuses loopback / private / plain-HTTP push targets at save time.
            for blocked in [
                "http://localhost:5678/webhook/reply",
                "https://127.0.0.1:5678/webhook/reply",
                "https://10.0.0.7:5678/webhook/reply",
            ] {
                var loopback = Self.connection()
                loopback.n8n?.outbound = AgentChannelN8nOutboundConfiguration(webhookURL: blocked)
                #expect(throws: AgentChannelConnectionManagerError.invalidN8nOutboundURL(blocked)) {
                    try manager.upsertConnection(loopback)
                }
            }

            try manager.upsertConnection(Self.connection())
            let pollOnly = try #require(AgentChannelConfigurationStore.load().connection(id: "n8n-main"))
            #expect(pollOnly.kind == .n8n)
            #expect(pollOnly.customHTTP == nil)
            #expect(!pollOnly.writeEnabled)
            #expect(pollOnly.spaceAllowlist.contains(AgentChannelN8nConfiguration.spaceId))
            #expect(pollOnly.secrets.map(\.name) == [AgentChannelN8nConfiguration.defaultSecretName])

            // A public HTTPS webhook is projected onto the runner-visible fields.
            var pushed = Self.connection()
            pushed.n8n?.outbound = AgentChannelN8nOutboundConfiguration(
                webhookURL: "https://n8n.example.com/webhook/osaurus-reply"
            )
            try manager.upsertConnection(pushed, replacingOriginalId: "n8n-main")
            let stored = try #require(AgentChannelConfigurationStore.load().connection(id: "n8n-main"))
            #expect(stored.customHTTP?.baseURL == "https://n8n.example.com")
            #expect(stored.customHTTP?.actions[AgentChannelAction.sendMessage.rawValue]?.bodySignature != nil)
            #expect(stored.supportedActions.contains(.sendMessage))
            #expect(stored.writeEnabled)
            #expect(stored.writeRoomAllowlist == stored.inboundAuthorization.roomAllowlist)

            // Clearing the webhook removes the projection again.
            var cleared = stored
            cleared.n8n?.outbound = AgentChannelN8nOutboundConfiguration()
            try manager.upsertConnection(cleared, replacingOriginalId: "n8n-main")
            let reloaded = try #require(AgentChannelConfigurationStore.load().connection(id: "n8n-main"))
            #expect(reloaded.customHTTP == nil)
            #expect(!reloaded.supportedActions.contains(.sendMessage))
        }
    }
}
