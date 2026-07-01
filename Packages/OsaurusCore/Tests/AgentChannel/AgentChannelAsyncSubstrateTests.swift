//
//  AgentChannelAsyncSubstrateTests.swift
//  osaurusTests
//
//  Focused coverage for provider-neutral async Agent Channel contracts.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct AgentChannelAsyncSubstrateTests {

    @Test func webhookVerificationSupportsSharedSecretAndHMACWithoutSecretLeakage() {
        let substrate = AgentChannelAsyncSubstrate()
        let receivedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let secret = "webhook-secret-do-not-leak"

        let sharedSecretResult = substrate.verifyWebhookSource(
            request: AgentChannelWebhookVerificationRequest(
                headers: ["x-telegram-bot-api-secret-token": secret],
                receivedAt: receivedAt
            ),
            policy: AgentChannelSourceVerificationPolicy(
                method: .sharedSecretHeader,
                headerName: "X-Telegram-Bot-Api-Secret-Token",
                secret: secret
            )
        )
        #expect(sharedSecretResult.status == .verified)
        #expect(sharedSecretResult.method == .sharedSecretHeader)

        let failedSharedSecret = substrate.verifyWebhookSource(
            request: AgentChannelWebhookVerificationRequest(
                headers: ["x-telegram-bot-api-secret-token": "wrong"],
                receivedAt: receivedAt
            ),
            policy: AgentChannelSourceVerificationPolicy(
                method: .sharedSecretHeader,
                headerName: "X-Telegram-Bot-Api-Secret-Token",
                secret: secret
            )
        )
        #expect(failedSharedSecret.status == .failed)
        #expect(failedSharedSecret.failure?.code == .verificationFailed)
        #expect(failedSharedSecret.failure?.message.contains(secret) == false)

        let body = Data(#"{"event":"message.created"}"#.utf8)
        let signature = AgentChannelAsyncSubstrate.hmacSHA256Hex(body: body, secret: secret)
        let hmacResult = substrate.verifyWebhookSource(
            request: AgentChannelWebhookVerificationRequest(
                headers: ["X-Resend-Signature": "sha256=\(signature)"],
                body: body,
                receivedAt: receivedAt
            ),
            policy: AgentChannelSourceVerificationPolicy(
                method: .hmacSHA256,
                headerName: "x-resend-signature",
                secret: secret
            )
        )
        #expect(hmacResult.status == .verified)
        #expect(hmacResult.method == .hmacSHA256)
    }

    @Test func webhookVerificationReportsSkippedAndFailureStates() {
        let substrate = AgentChannelAsyncSubstrate()
        let receivedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let body = Data(#"{"event":"message.created"}"#.utf8)
        let secret = "webhook-secret"

        let skipped = substrate.verifyWebhookSource(
            request: AgentChannelWebhookVerificationRequest(headers: [:], receivedAt: receivedAt),
            policy: .unverified
        )
        #expect(skipped.status == .skipped)
        #expect(skipped.isVerified)

        let missingSharedSecret = substrate.verifyWebhookSource(
            request: AgentChannelWebhookVerificationRequest(
                headers: ["X-Osaurus-Channel-Secret": "received"],
                receivedAt: receivedAt
            ),
            policy: AgentChannelSourceVerificationPolicy(method: .sharedSecretHeader)
        )
        #expect(missingSharedSecret.status == .failed)
        #expect(missingSharedSecret.failure?.code == .verificationFailed)

        let missingHMACSecret = substrate.verifyWebhookSource(
            request: AgentChannelWebhookVerificationRequest(
                headers: ["X-Osaurus-Channel-Signature": "sha256=abc"],
                body: body,
                receivedAt: receivedAt
            ),
            policy: AgentChannelSourceVerificationPolicy(method: .hmacSHA256)
        )
        #expect(missingHMACSecret.status == .failed)

        let missingHMACHeader = substrate.verifyWebhookSource(
            request: AgentChannelWebhookVerificationRequest(headers: [:], body: body, receivedAt: receivedAt),
            policy: AgentChannelSourceVerificationPolicy(method: .hmacSHA256, secret: secret)
        )
        #expect(missingHMACHeader.status == .failed)

        let badHMAC = substrate.verifyWebhookSource(
            request: AgentChannelWebhookVerificationRequest(
                headers: ["X-Osaurus-Channel-Signature": "sha256=bad"],
                body: body,
                receivedAt: receivedAt
            ),
            policy: AgentChannelSourceVerificationPolicy(method: .hmacSHA256, secret: secret)
        )
        #expect(badHMAC.status == .failed)

        let bareSignature = AgentChannelAsyncSubstrate.hmacSHA256Hex(body: body, secret: secret)
        let bareHMAC = substrate.verifyWebhookSource(
            request: AgentChannelWebhookVerificationRequest(
                headers: ["X-Osaurus-Channel-Signature": bareSignature],
                body: body,
                receivedAt: receivedAt
            ),
            policy: AgentChannelSourceVerificationPolicy(method: .hmacSHA256, secret: secret)
        )
        #expect(bareHMAC.status == .verified)
    }

    @Test func senderPolicyBlocksBeforeAllowlistAndRejectsAllowlistMisses() {
        let substrate = AgentChannelAsyncSubstrate()
        let policy = AgentChannelSenderPolicy(
            defaultDisposition: .allow,
            allowedSenderIds: ["user-1"],
            blockedSenderIds: ["blocked-user"],
            allowedAddresses: ["Allowed@Example.COM"],
            blockedAddresses: ["blocked@example.com"],
            allowBots: false
        )

        let blocked = substrate.evaluateSender(
            AgentChannelSenderIdentity(providerSenderId: "blocked-user"),
            policy: policy
        )
        #expect(blocked.disposition == .reject)
        #expect(blocked.matchedPolicy == "blocked_sender_id")

        let allowedByAddress = substrate.evaluateSender(
            AgentChannelSenderIdentity(normalizedAddress: "allowed@example.com"),
            policy: policy
        )
        #expect(allowedByAddress.disposition == .allow)
        #expect(allowedByAddress.matchedPolicy == "allowed_address")

        let bot = substrate.evaluateSender(
            AgentChannelSenderIdentity(providerSenderId: "user-1", isBot: true),
            policy: policy
        )
        #expect(bot.disposition == .reject)
        #expect(bot.matchedPolicy == "bot_sender")

        let allowlistMiss = substrate.evaluateSender(
            AgentChannelSenderIdentity(providerSenderId: "stranger"),
            policy: policy
        )
        #expect(allowlistMiss.disposition == .reject)
        #expect(allowlistMiss.matchedPolicy == "allowlist_miss")

        let defaultAllow = substrate.evaluateSender(
            AgentChannelSenderIdentity(providerSenderId: "stranger"),
            policy: AgentChannelSenderPolicy(defaultDisposition: .allow, allowBots: true)
        )
        #expect(defaultAllow.disposition == .allow)
        #expect(defaultAllow.matchedPolicy == "default_allow")
    }

    @Test func replyTokenRegistryKeepsProviderRouteOpaqueAgentScopedAndExpiring() async throws {
        let agentId = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let otherAgentId = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let sessionId = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let issuedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let registry = AgentChannelReplyTokenRegistry(tokenGenerator: { "acr_test_token" })
        let route = AgentChannelProviderRoute(
            conversationId: "telegram-chat-5544332211",
            threadId: "topic-42",
            replyAddress: "5544332211",
            displayName: "Dana"
        )

        let binding = try await registry.issue(
            AgentChannelReplyBindingInput(
                agentId: agentId,
                connectionId: "telegram",
                providerRoute: route,
                sessionId: sessionId,
                timeToLive: 60
            ),
            issuedAt: issuedAt
        )

        #expect(binding.token.rawValue == "acr_test_token")
        #expect(!binding.token.rawValue.contains(route.conversationId))
        #expect(!String(describing: binding.agentVisiblePayload).contains(route.conversationId))
        #expect(!String(describing: binding.agentVisiblePayload).contains(route.replyAddress ?? ""))

        switch await registry.resolve(token: binding.token, agentId: agentId, at: issuedAt.addingTimeInterval(30)) {
        case .success(let resolved):
            #expect(resolved.providerRoute == route)
            #expect(resolved.sessionId == sessionId)
        case .failure(let failure):
            Issue.record("Expected reply token to resolve, got \(failure.code.rawValue)")
        }

        switch await registry.resolve(token: binding.token, agentId: otherAgentId, at: issuedAt.addingTimeInterval(30))
        {
        case .success:
            Issue.record("Reply token resolved for the wrong agent")
        case .failure(let failure):
            #expect(failure.code == .replyTokenAgentMismatch)
        }

        switch await registry.resolve(token: binding.token, agentId: agentId, at: issuedAt.addingTimeInterval(61)) {
        case .success:
            Issue.record("Expired reply token resolved")
        case .failure(let failure):
            #expect(failure.code == .replyTokenExpired)
        }
        #expect(await registry.count() == 0)

        let expiredForOtherAgent = try await registry.issue(
            AgentChannelReplyBindingInput(
                agentId: agentId,
                connectionId: "telegram",
                providerRoute: route,
                sessionId: sessionId,
                timeToLive: 1
            ),
            issuedAt: issuedAt.addingTimeInterval(100)
        )
        switch await registry.resolve(
            token: expiredForOtherAgent.token,
            agentId: otherAgentId,
            at: issuedAt.addingTimeInterval(102)
        ) {
        case .success:
            Issue.record("Expired reply token resolved for the wrong agent")
        case .failure(let failure):
            #expect(failure.code == .replyTokenExpired)
        }
    }

    @Test func replyTokenRegistrySupportsRevokePruneAndCollisionFailure() async throws {
        let agentId = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let sessionId = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let route = AgentChannelProviderRoute(conversationId: "telegram-chat-5544332211")
        let input = AgentChannelReplyBindingInput(
            agentId: agentId,
            connectionId: "telegram",
            providerRoute: route,
            sessionId: sessionId,
            timeToLive: 60
        )

        let registry = AgentChannelReplyTokenRegistry()
        _ = try await registry.issue(input, issuedAt: now.addingTimeInterval(-120))
        let active = try await registry.issue(input, issuedAt: now)
        #expect(await registry.count() == 1)

        let pruned = await registry.pruneExpired(at: now)
        #expect(pruned == 0)
        await registry.revoke(token: active.token)
        #expect(await registry.count() == 0)

        let collidingRegistry = AgentChannelReplyTokenRegistry(tokenGenerator: { "acr_collision" })
        _ = try await collidingRegistry.issue(input, issuedAt: now)
        do {
            _ = try await collidingRegistry.issue(input, issuedAt: now.addingTimeInterval(1))
            Issue.record("Expected colliding reply token generator to fail")
        } catch let failure as AgentChannelFailure {
            #expect(failure.code == .internalFailure)
        }
    }

    @Test func sessionPartitionIsStablePerAgentAndDoesNotExposeProviderRoute() {
        let substrate = AgentChannelAsyncSubstrate()
        let route = AgentChannelProviderRoute(
            conversationId: "email-thread-raw-provider-id",
            threadId: "message-raw-provider-id"
        )
        let agentA = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let agentB = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!

        let first = substrate.makeSessionPartition(
            agentId: agentA,
            connectionId: "resend",
            providerRoute: route,
            salt: 2
        )
        let repeatFirst = substrate.makeSessionPartition(
            agentId: agentA,
            connectionId: "resend",
            providerRoute: route,
            salt: 2
        )
        let otherAgent = substrate.makeSessionPartition(
            agentId: agentB,
            connectionId: "resend",
            providerRoute: route,
            salt: 2
        )
        let otherSalt = substrate.makeSessionPartition(
            agentId: agentA,
            connectionId: "resend",
            providerRoute: route,
            salt: 3
        )

        #expect(first == repeatFirst)
        #expect(first.sessionId != otherAgent.sessionId)
        #expect(first.externalSessionKey != otherAgent.externalSessionKey)
        #expect(first.sessionId != otherSalt.sessionId)
        #expect(first.externalSessionKey != otherSalt.externalSessionKey)
        #expect(!first.externalSessionKey.contains(route.conversationId))
        #expect(!first.externalSessionKey.contains(route.threadId ?? ""))
        #expect(first.externalSessionKey.hasPrefix("agent-channel:resend:"))
        #expect(first.sessionId.uuidString.split(separator: "-")[2].hasPrefix("5"))
    }

    @Test func deduplicationServicePersistsFirstSeenAndDuplicateOutcomes() throws {
        let store = AgentChannelMessageStore()
        try store.openInMemory()
        defer { store.close() }

        let substrate = AgentChannelAsyncSubstrate()
        let deduplication = AgentChannelDeduplicationService(store: store)
        let key = try #require(
            substrate.makeDeduplicationKey(
                connectionId: "telegram",
                providerEventId: "update-123456",
                sourceId: "bot-a"
            )
        )

        #expect(substrate.makeDeduplicationKey(connectionId: " ", providerEventId: "update") == nil)
        #expect(substrate.makeDeduplicationKey(connectionId: "telegram", providerEventId: " ") == nil)
        #expect(try deduplication.register(key) == .firstSeen)
        #expect(try deduplication.register(key) == .duplicate)
        #expect(try deduplication.register(nil) == .invalidKey)

        let auditKey = substrate.auditKey(for: key)
        #expect(auditKey.hasPrefix("ack_"))
        #expect(!auditKey.contains(key.providerEventId))
        #expect(!auditKey.contains(key.sourceId ?? ""))
    }

    @Test func artifactForwardingRollupAndAuditEventsUseTypedStatus() async {
        let report = AgentChannelArtifactForwardingReport(records: [
            AgentChannelArtifactForwardingRecord(
                artifactId: "artifact-1",
                filename: "summary.pdf",
                status: .forwarded
            ),
            AgentChannelArtifactForwardingRecord(
                artifactId: "artifact-2",
                filename: "large.mov",
                status: .failed,
                failure: AgentChannelFailure(
                    code: .artifactTooLarge,
                    message: "Artifact exceeds channel forwarding limit."
                )
            ),
        ])
        #expect(report.status == .failed)
        #expect(AgentChannelArtifactForwardingReport(records: []).status == .notRequested)
        #expect(
            AgentChannelArtifactForwardingReport(records: [
                AgentChannelArtifactForwardingRecord(artifactId: "artifact-1", status: .skipped)
            ]).status == .skipped
        )
        #expect(
            AgentChannelArtifactForwardingReport(records: [
                AgentChannelArtifactForwardingRecord(artifactId: "artifact-1", status: .forwarded),
                AgentChannelArtifactForwardingRecord(artifactId: "artifact-2", status: .skipped),
            ]).status == .forwarded
        )
        #expect(
            AgentChannelArtifactForwardingReport(records: [
                AgentChannelArtifactForwardingRecord(artifactId: "artifact-1", status: .queued),
                AgentChannelArtifactForwardingRecord(artifactId: "artifact-2", status: .forwarded),
            ]).status == .queued
        )
        #expect(
            AgentChannelArtifactForwardingReport(records: [
                AgentChannelArtifactForwardingRecord(artifactId: "artifact-1", status: .blocked),
                AgentChannelArtifactForwardingRecord(artifactId: "artifact-2", status: .queued),
            ]).status == .blocked
        )

        let audit = AgentChannelAuditLog()
        let event = AgentChannelAuditEvent(
            kind: .artifactForwardingChanged,
            status: .failed,
            connectionId: "resend",
            artifactStatus: report.status,
            failure: report.records[1].failure,
            metadata: ["artifact_count": "\(report.records.count)"]
        )
        await audit.record(event)

        let events = await audit.snapshot()
        #expect(events.count == 1)
        #expect(events[0].kind == .artifactForwardingChanged)
        #expect(events[0].artifactStatus == .failed)
        #expect(events[0].failure?.code == .artifactTooLarge)

        let cappedAudit = AgentChannelAuditLog(maxEvents: 2)
        await cappedAudit.record(
            AgentChannelAuditEvent(kind: .eventAccepted, status: .accepted, connectionId: "resend-1")
        )
        await cappedAudit.record(
            AgentChannelAuditEvent(kind: .eventAccepted, status: .accepted, connectionId: "resend-2")
        )
        await cappedAudit.record(
            AgentChannelAuditEvent(kind: .eventAccepted, status: .accepted, connectionId: "resend-3")
        )
        let cappedEvents = await cappedAudit.snapshot()
        #expect(cappedEvents.map(\.connectionId) == ["resend-2", "resend-3"])
    }

    @Test func asyncModelsCodableRoundTripKeepsStableShapes() throws {
        let token = AgentChannelReplyToken(rawValue: " acr_roundtrip ")
        let tokenData = try JSONEncoder().encode(token)
        let decodedToken = try JSONDecoder().decode(AgentChannelReplyToken.self, from: tokenData)
        #expect(decodedToken.rawValue == "acr_roundtrip")

        let failure = AgentChannelFailure(code: .duplicateEvent, message: "Duplicate event", retryable: false)
        let failureData = try JSONEncoder().encode(failure)
        let decodedFailure = try JSONDecoder().decode(AgentChannelFailure.self, from: failureData)
        #expect(decodedFailure == failure)
    }
}
