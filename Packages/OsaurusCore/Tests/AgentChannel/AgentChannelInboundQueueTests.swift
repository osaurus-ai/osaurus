//
//  AgentChannelInboundQueueTests.swift
//  osaurusTests
//
//  Messages that arrive while a channel turn is running are folded into
//  one follow-up turn instead of being dropped (#2987).
//

import Foundation
import Testing

@testable import OsaurusCore

struct AgentChannelInboundQueueTests {
    private func request(
        _ eventId: String,
        _ content: String,
        onOutcome: AgentChannelTurnOutcomeHandler? = nil
    ) -> AgentChannelInboundRelayRequest {
        AgentChannelInboundRelayRequest(
            identity: ChannelIdentity(
                kind: .telegram,
                installationId: "telegram-installation",
                groupId: nil,
                threadId: nil,
                sender: ChannelSenderMetadata(senderId: "user-a", displayName: "A. User", username: "user-a"),
                trustLevel: .verified
            ),
            connectionId: "connection",
            providerEventId: eventId,
            providerRoute: AgentChannelProviderRoute(conversationId: "telegram-chat-1"),
            content: content,
            target: .local(UUID()),
            sourceLabel: "Telegram",
            onOutcome: onOutcome
        )
    }

    @Test func mergedRequestKeepsArrivalOrderAndKeysOnTheLastEvent() {
        let merged = AgentChannelInboundRelay.mergedRequest(
            [request("858", "2"), request("859", "3"), request("860", "4")],
            contents: ["2", "3", "4"]
        )
        #expect(merged.content == "2\n\n3\n\n4")
        #expect(merged.request.content == merged.content)
        #expect(merged.request.providerEventId == "860")
    }

    @Test func mergedRequestSkipsEmptyContent() {
        let merged = AgentChannelInboundRelay.mergedRequest(
            [request("1", "first"), request("2", ""), request("3", "third")],
            contents: ["first", "", "third"]
        )
        #expect(merged.content == "first\n\nthird")
    }

    /// Every queued message owns a ledger row, so the folded turn reports
    /// its outcome to each of them, not only the last.
    @MainActor
    @Test func mergedRequestReportsOutcomeToEveryQueuedMessage() {
        final class Seen { var ids: [String] = [] }
        let seen = Seen()
        let merged = AgentChannelInboundRelay.mergedRequest(
            [
                request("1", "a", onOutcome: { _ in seen.ids.append("1") }),
                request("2", "b"),
                request("3", "c", onOutcome: { _ in seen.ids.append("3") }),
            ],
            contents: ["a", "b", "c"]
        )
        merged.request.onOutcome?(.finished(status: .succeeded, sessionId: nil, error: nil, reason: nil))
        #expect(seen.ids == ["1", "3"])
    }

    @Test func queueFullHasRecoveryGuidance() {
        #expect(
            AgentChannelInboundActivityPresentation.guidance(stage: .rejected, reason: "conversation_queue_full") != nil
        )
    }

    @Test func defaultsMatchTheHistoricRelayBehavior() {
        let plain = request("1", "a")
        #expect(plain.maxQueued == AgentChannelInboundRelay.maxQueuedMessagesPerConversation)
        #expect(plain.steerRunningTurn)
        #expect(AgentChannelInboundRelay.shouldTrySteer(queued: 0, request: plain))
        #expect(!AgentChannelInboundRelay.shouldTrySteer(queued: 1, request: plain))
        #expect(AgentChannelInboundRelay.queueRejection(queued: 19, request: plain) == nil)
        #expect(AgentChannelInboundRelay.queueRejection(queued: 20, request: plain) == "conversation_queue_full")
    }

    @Test func eventQueueingSettingsShapeTheBusyConversation() {
        var capped = request("1", "a")
        capped.maxQueued = 5
        #expect(AgentChannelInboundRelay.queueRejection(queued: 4, request: capped) == nil)
        #expect(AgentChannelInboundRelay.queueRejection(queued: 5, request: capped) == "conversation_queue_full")

        var skipWhileBusy = request("2", "b")
        skipWhileBusy.maxQueued = 0
        #expect(AgentChannelInboundRelay.queueRejection(queued: 0, request: skipWhileBusy) == "conversation_busy")
        #expect(
            AgentChannelInboundActivityPresentation.guidance(stage: .rejected, reason: "conversation_busy") != nil)

        var noSteer = request("3", "c")
        noSteer.steerRunningTurn = false
        #expect(!AgentChannelInboundRelay.shouldTrySteer(queued: 0, request: noSteer))
        #expect(AgentChannelInboundRelay.queueRejection(queued: 0, request: noSteer) == nil)
    }

    @Test func blockedReplyHasRecoveryGuidance() {
        #expect(
            AgentChannelInboundActivityPresentation.guidance(
                stage: .agentReplied, reason: AgentChannelInboundRelay.globalWritesDisabledReason) != nil
        )
    }
}
