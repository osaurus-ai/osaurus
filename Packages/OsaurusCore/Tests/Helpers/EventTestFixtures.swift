//
//  EventTestFixtures.swift
//  OsaurusCoreTests
//

import Foundation

@testable import OsaurusCore

enum EventTestFixtures {
    /// A channel-message event that runs a local agent.
    static func channelAgentEvent(
        id: UUID = UUID(),
        name: String = "Channel Event",
        kind: AgentChannelKind,
        connectionId: String? = nil,
        agentId: UUID?,
        rooms: [String] = [],
        aliases: [String] = [],
        requireMention: Bool? = nil,
        continueThreads: Bool = true,
        instructions: String = "",
        autoReply: Bool = true,
        isEnabled: Bool = true
    ) -> OsaurusEvent {
        OsaurusEvent(
            id: id,
            name: name,
            isEnabled: isEnabled,
            source: .channelMessage(
                ChannelMessageSourceConfig(
                    kind: kind,
                    connectionId: connectionId,
                    roomIds: rooms,
                    aliases: aliases,
                    requireMention: requireMention,
                    continueThreads: continueThreads
                )
            ),
            action: .agent(AgentEventAction(target: agentId.map { .local($0) }, instructions: instructions)),
            reply: EventReplyPolicy(autoReply: autoReply)
        )
    }

    /// The listener snapshot `events` publish for one connection.
    static func listeners(
        _ events: [OsaurusEvent],
        kind: AgentChannelKind,
        connectionId: String
    ) -> ChannelEventListeners {
        ChannelEventListeners.build(events)[ChannelEventListeners.key(kind, connectionId)] ?? ChannelEventListeners()
    }

    /// Listeners for agents answering on a connection; `rooms` empty = any room.
    static func listeners(
        agents: [(UUID, [String])],
        kind: AgentChannelKind,
        connectionId: String,
        autoReply: Bool = true
    ) -> ChannelEventListeners {
        listeners(
            agents.map {
                channelAgentEvent(
                    kind: kind, connectionId: connectionId, agentId: $0.0, rooms: $0.1, autoReply: autoReply)
            },
            kind: kind,
            connectionId: connectionId
        )
    }
}
