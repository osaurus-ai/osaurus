//
//  AgentCollaborationAgentConformance.swift
//  osaurus
//
//  Computed adapters from existing agent records into collaboration protocol
//  participants. These extensions do not alter persistence or UI behavior.
//

import Foundation

extension Agent {
    public var agentCollaborationParticipant: AgentCollaborationParticipant {
        AgentCollaborationParticipant(
            id: "local:\(id.uuidString.lowercased())",
            type: .local,
            displayName: displayName,
            address: agentAddress
        )
    }

    public var agentCollaborationCapabilities: AgentCollaborationCapabilities {
        .localDefault()
    }
}

extension RemoteAgent {
    public var agentCollaborationParticipant: AgentCollaborationParticipant {
        AgentCollaborationParticipant(
            id: "remote:\(id.uuidString.lowercased())",
            type: .remote,
            displayName: name,
            address: agentAddress,
            endpoint: relayBaseURL
        )
    }

    public var agentCollaborationCapabilities: AgentCollaborationCapabilities {
        .remoteDefault()
    }
}
