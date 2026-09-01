//
//  ChatAgentPickerPill.swift
//  osaurus
//
//  The agent selector pill. Lived in the toolbar's centered slot until the
//  chat tab strip took that space; now rendered by the session sidebar's
//  Chats tab, below the Chats | Projects lens switcher.
//

import SwiftUI

struct ChatAgentPickerPill: View {
    @ObservedObject var windowState: ChatWindowState

    /// Incremented by the `/agent` slash command notification to pop the
    /// agent picker open from the input card.
    @State private var openPickerTrigger: Int = 0

    var body: some View {
        AgentPill(
            agents: windowState.agents,
            activeAgentId: windowState.agentId,
            onSelectAgent: { newAgentId in
                windowState.switchAgent(to: newAgentId)
            },
            discoveredAgents: windowState.discoveredAgents,
            onSelectDiscoveredAgent: { agent in
                NotificationCenter.default.post(
                    name: .chatToolbarSelectDiscoveredAgent,
                    object: agent,
                    userInfo: ["windowId": windowState.windowId]
                )
            },
            activeDiscoveredAgent: windowState.selectedDiscoveredAgent,
            pairedRelayAgents: windowState.pairedRelayAgents,
            onSelectRelayAgent: { relay in
                NotificationCenter.default.post(
                    name: .chatToolbarSelectRelayAgent,
                    object: relay,
                    userInfo: ["windowId": windowState.windowId]
                )
            },
            activeRelayAgent: windowState.selectedRelayAgent,
            activeRemoteAgentAvatar: windowState.pinnedRemoteAgentAvatar,
            onOpenActiveAgentSettings: { openActiveAgentSettings() },
            onOpenRemoteAgentSettings: { openRemoteAgentSettings() },
            openPickerTrigger: openPickerTrigger
        )
        .environment(\.theme, windowState.theme)
        .onReceive(NotificationCenter.default.publisher(for: .chatToolbarOpenAgentPicker)) { notification in
            guard let targetWindowId = notification.userInfo?["windowId"] as? UUID,
                targetWindowId == windowState.windowId
            else { return }
            openPickerTrigger &+= 1
        }
    }

    /// Deep-link the management window to the active local agent's config.
    /// Built-in agents have no editable record, so they open the Agents tab
    /// without a selection.
    private func openActiveAgentSettings() {
        let active = windowState.agents.first { $0.id == windowState.agentId }
        // The built-in Orchestrator has no Agents-tab detail view; its
        // identity + delegation settings live on the dedicated
        // Orchestrator tab.
        if active?.isBuiltIn != false {
            AppDelegate.shared?.showManagementWindow(initialTab: .orchestrator)
            return
        }
        AppDelegate.shared?.showManagementWindow(
            initialTab: .agents,
            deeplinkAgentId: active?.id
        )
    }

    /// Deep-link the management window to the active remote agent's detail view.
    /// Resolves the chat's remote target → persisted `RemoteAgent` id; ephemeral
    /// peers with no record fall back to the Agents tab.
    private func openRemoteAgentSettings() {
        let remoteId = windowState.selectedDiscoveredAgentProviderId.flatMap {
            RemoteAgentManager.shared.remoteAgentDetailId(forProviderId: $0)
        }
        AppDelegate.shared?.showManagementWindow(
            initialTab: .agents,
            deeplinkRemoteAgentId: remoteId
        )
    }
}
