//
//  AgentChannelAgentReplySummary.swift
//  osaurus
//
//  Derives the per-agent "Replies" summary shown in an agent's Channels
//  tab from a provider's inbound dispatch configuration. Pure so every
//  state (dispatch off, agent unassigned, default agent, routed agent)
//  is testable without provider services.
//

import Foundation

enum AgentChannelAgentReplySummary {
    /// One line describing how `agentId` replies on a channel with this
    /// inbound dispatch configuration, or nil when the agent does not
    /// reply there — dispatch is off, or the agent is neither the default
    /// agent nor referenced by any rule.
    static func detail(
        for agentId: UUID,
        dispatch: AgentChannelInboundDispatchConfiguration
    ) -> String? {
        guard dispatch.enabled else { return nil }
        let isDefault = dispatch.targetAgentId == agentId
        let ruleCount = dispatch.routes.filter { $0.agentId == agentId }.count
        switch (isDefault, ruleCount) {
        case (false, 0):
            return nil
        case (true, 0):
            return L("Replies to incoming messages")
        case (true, _):
            return L("Replies to incoming messages, plus \(ruleCount) rule(s)")
        case (false, _):
            return L("Replies where \(ruleCount) rule(s) match")
        }
    }
}
