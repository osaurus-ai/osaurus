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
    private func request(_ eventId: String, _ content: String) -> AgentChannelInboundRelayRequest {
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
            settings: AgentChannelInboundDispatchConfiguration(enabled: true, targetAgentId: UUID()),
            sourceLabel: "Telegram"
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

    @Test func queueFullHasRecoveryGuidance() {
        #expect(
            AgentChannelInboundActivityPresentation.guidance(stage: .rejected, reason: "conversation_queue_full") != nil
        )
    }
}
