//
//  AgentSidebarActions.swift
//  osaurus
//
//  Rename and Delete Agent… from an agent row's menu in the chat sidebar.
//  Both go through `AgentManager`, the same as Settings → Agents.
//

import Foundation
import SwiftUI

@MainActor
enum AgentSidebarActions {

    // MARK: - Copy

    nonisolated static func deleteTitle(name: String) -> String {
        L("Delete \(name)?")
    }

    nonisolated static func deleteMessage(name: String, chatCount: Int) -> String {
        switch chatCount {
        case 0: L("\(name) and its memory are removed from this Mac. This cannot be undone.")
        case 1: L("\(name), its memory and its 1 chat are removed from this Mac. This cannot be undone.")
        default: L("\(name), its memory and its \(chatCount) chats are removed from this Mac. This cannot be undone.")
        }
    }

    // MARK: - Actions

    /// An empty or unchanged name is no rename. Built-in agents keep
    /// their names.
    static func rename(_ agent: Agent, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !agent.isBuiltIn, !trimmed.isEmpty, trimmed != agent.name,
            var current = AgentManager.shared.agent(for: agent.id)
        else { return }
        current.name = trimmed
        AgentManager.shared.update(current)
    }

    /// One confirmation naming what goes with the agent. A shared agent
    /// must be unshared from its workspace first, as in Settings.
    static func requestDelete(_ agent: Agent, chatCount: Int, scope: ThemedAlertScope) {
        guard !agent.isBuiltIn else { return }
        if let address = agent.agentAddress,
            !WorkspaceRosterStore.shared.workspacesSharing(agentAddress: address).isEmpty
        {
            ToastManager.shared.errorLocalized(
                "Agent is shared", message: "Unshare it from its workspace before deleting."
            )
            return
        }
        let requestId = UUID()
        ThemedAlertCenter.shared.present(
            ThemedAlertRequest(
                id: requestId,
                title: deleteTitle(name: agent.displayName),
                message: deleteMessage(name: agent.displayName, chatCount: chatCount),
                buttons: [
                    .cancel(L("Cancel")),
                    .destructive(L("Delete Agent")) { delete(agent) },
                ],
                onDismiss: {
                    ThemedAlertCenter.shared.dismiss(scope: scope, id: requestId)
                }
            ),
            scope: scope
        )
    }

    /// Moves every window off the agent's chats (cancelling their runs)
    /// before `AgentManager.delete` removes the agent, its chats and its
    /// memory, so no window saves a deleted chat back.
    static func delete(_ agent: Agent) {
        Task { @MainActor in
            // Captured up front: removing the agent already moves these
            // windows to the Orchestrator's last open chat.
            let windowsOnAgent = ChatWindowManager.shared.allWindowStates.filter { $0.agentId == agent.id }
            let chatIds = Set(
                ChatSessionsManager.shared.sessions
                    .filter { ($0.agentId ?? Agent.defaultId) == agent.id }
                    .map(\.id))
            if !chatIds.isEmpty { await ChatWindowManager.shared.deleteSessions(ids: chatIds) }
            let result = await AgentManager.shared.delete(id: agent.id)
            guard result.deleted else {
                ToastManager.shared.errorLocalized("Failed to delete agent", message: "Please try again.")
                return
            }
            for state in windowsOnAgent {
                state.startNewChat(with: Agent.defaultId)
            }
            ToastManager.shared.success(L("Deleted \"\(agent.name)\""))
            if let notice = result.sandboxCleanupNotice {
                switch notice.kind {
                case .completed:
                    ToastManager.shared.success(notice.title, message: notice.message)
                case .incomplete:
                    ToastManager.shared.warning(notice.title, message: notice.message)
                }
            }
        }
    }
}
