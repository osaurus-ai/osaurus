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
            // No gear: agent settings stay reachable from the picker rows /
            // management window; the sidebar pill is purely a selector.
            openPickerTrigger: openPickerTrigger,
            sidebarStyle: true
        )
        .environment(\.theme, windowState.theme)
        .onReceive(NotificationCenter.default.publisher(for: .chatToolbarOpenAgentPicker)) { notification in
            guard let targetWindowId = notification.userInfo?["windowId"] as? UUID,
                targetWindowId == windowState.windowId
            else { return }
            openPickerTrigger &+= 1
        }
    }

}
