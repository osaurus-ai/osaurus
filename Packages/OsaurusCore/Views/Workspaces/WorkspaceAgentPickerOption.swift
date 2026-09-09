//
//  WorkspaceAgentPickerOption.swift
//  osaurus
//
//  One selectable shared workspace agent for the trigger editors (schedules,
//  watchers, channel routes). Built from the live roster minus this
//  instance's own agents; presence is UI decoration only — the dispatch
//  funnel's relay probe is what actually decides whether a run may start.
//

import Foundation
import SwiftUI

struct WorkspaceAgentPickerOption: Identifiable, Equatable {
    let ref: WorkspaceAgentRef
    let name: String
    let description: String?
    let workspaceName: String
    let ownerName: String?
    let presence: WorkspaceRosterStore.Presence

    var id: String { ref.key }

    /// "Workspace · Owner" for the secondary line under the name.
    var subtitle: String {
        var parts = [workspaceName]
        if let ownerName, !ownerName.isEmpty { parts.append(ownerName) }
        return parts.joined(separator: " · ")
    }

    var presenceLabel: String {
        switch presence {
        case .online: return L("Online")
        case .offline: return L("Offline")
        case .unknown: return L("Presence unknown")
        }
    }

    /// Every runnable shared agent, once per `(workspace, address)`, in
    /// roster order. Own agents are excluded: they are reachable as local
    /// targets already, and running them over the relay would bill the
    /// workspace pool for work the user could run for free.
    @MainActor
    static func all(roster: WorkspaceRosterStore = .shared) -> [WorkspaceAgentPickerOption] {
        var seen = Set<WorkspaceAgentRef>()
        var out: [WorkspaceAgentPickerOption] = []
        for entry in roster.rosters {
            for agent in entry.agents where !roster.isOwnAgent(address: agent.agentAddress) {
                let ref = WorkspaceAgentRef(workspaceId: entry.id, agentAddress: agent.agentAddress)
                guard seen.insert(ref).inserted else { continue }
                let description = agent.description?.trimmingCharacters(in: .whitespacesAndNewlines)
                out.append(
                    WorkspaceAgentPickerOption(
                        ref: ref,
                        name: AgentTargetResolver.displayName(for: ref),
                        description: (description?.isEmpty == false) ? description : nil,
                        workspaceName: entry.workspace.name,
                        ownerName: agent.owner?.friendlyName,
                        presence: roster.presence(forAddress: ref.agentAddress, workspaceId: ref.workspaceId)
                    )
                )
            }
        }
        return out
    }

    /// The option for a stored ref, or a placeholder when the agent is no
    /// longer in any roster (unshared / left workspace) so the editor can
    /// still show — and let the user replace — the stale selection.
    @MainActor
    static func resolve(_ ref: WorkspaceAgentRef, in options: [WorkspaceAgentPickerOption]) -> WorkspaceAgentPickerOption {
        if let hit = options.first(where: { $0.ref == ref }) { return hit }
        return WorkspaceAgentPickerOption(
            ref: ref,
            name: AgentTargetResolver.displayName(for: ref),
            description: nil,
            workspaceName: AgentTargetResolver.workspaceName(for: ref) ?? L("Unavailable"),
            ownerName: nil,
            presence: .unknown
        )
    }
}

extension WorkspaceRosterStore.Presence {
    /// Dot color shared by every trigger editor: green online, dim offline,
    /// amber when the relay could not be reached.
    func indicatorColor(theme: any ThemeProtocol) -> Color {
        switch self {
        case .online: return theme.successColor
        case .offline: return theme.tertiaryText
        case .unknown: return theme.warningColor
        }
    }
}
