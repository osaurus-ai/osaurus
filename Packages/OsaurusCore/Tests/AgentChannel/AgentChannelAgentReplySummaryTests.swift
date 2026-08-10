//
//  AgentChannelAgentReplySummaryTests.swift
//  OsaurusCoreTests
//
//  Pins the per-agent "Replies" summary derivation used by the agent's
//  Channels tab: a channel with dispatch off or with the agent unassigned
//  produces no row, the default agent and routed agents each get an
//  explicit description, and rules that point at OTHER (including
//  missing) agents never leak into this agent's summary.
//

import Foundation
import Testing

@testable import OsaurusCore

struct AgentChannelAgentReplySummaryTests {

    private let agent = UUID()
    private let otherAgent = UUID()

    private func detail(_ dispatch: AgentChannelInboundDispatchConfiguration) -> String? {
        AgentChannelAgentReplySummary.detail(for: agent, dispatch: dispatch)
    }

    @Test func disabledDispatchProducesNoRow() {
        // Even when the agent is referenced, an off channel never replies.
        let dispatch = AgentChannelInboundDispatchConfiguration(
            enabled: false,
            targetAgentId: agent,
            routes: [AgentChannelDispatchRoute(roomId: "C1", agentId: agent)]
        )
        #expect(detail(dispatch) == nil)
    }

    @Test func unassignedAgentProducesNoRow() {
        // Dispatch is on, but neither the default slot nor any rule
        // references this agent.
        let dispatch = AgentChannelInboundDispatchConfiguration(
            enabled: true,
            targetAgentId: otherAgent,
            routes: [AgentChannelDispatchRoute(roomId: "C1", agentId: otherAgent)]
        )
        #expect(detail(dispatch) == nil)
    }

    @Test func defaultAgentReplies() {
        let dispatch = AgentChannelInboundDispatchConfiguration(
            enabled: true,
            targetAgentId: agent
        )
        #expect(detail(dispatch) == "Replies to incoming messages")
    }

    @Test func defaultAgentWithOwnRulesCountsThem() {
        let dispatch = AgentChannelInboundDispatchConfiguration(
            enabled: true,
            targetAgentId: agent,
            routes: [
                AgentChannelDispatchRoute(roomId: "C1", agentId: agent),
                AgentChannelDispatchRoute(roomId: "C2", agentId: agent),
            ]
        )
        #expect(detail(dispatch) == "Replies to incoming messages, plus 2 rule(s)")
    }

    @Test func routedOnlyAgentDescribesItsRules() {
        // The default slot belongs to someone else; this agent only
        // answers where its rules match.
        let dispatch = AgentChannelInboundDispatchConfiguration(
            enabled: true,
            targetAgentId: otherAgent,
            routes: [AgentChannelDispatchRoute(roomId: "C1", agentId: agent)]
        )
        #expect(detail(dispatch) == "Replies where 1 rule(s) match")
    }

    @Test func rulesForMissingAgentsDoNotLeakIntoTheSummary() {
        // A rule pointing at a deleted/unknown agent id must not inflate
        // this agent's rule count — only its own rules describe it.
        let dispatch = AgentChannelInboundDispatchConfiguration(
            enabled: true,
            targetAgentId: agent,
            routes: [AgentChannelDispatchRoute(roomId: "C1", agentId: UUID())]
        )
        #expect(detail(dispatch) == "Replies to incoming messages")
    }
}
