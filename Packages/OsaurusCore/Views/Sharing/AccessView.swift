//
//  AccessView.swift
//  osaurus
//
//  Sharing → Access: who can reach this Mac's agents and what they can use.
//  Remote access per agent, the guests who hold a guest link, the agents
//  other people shared with you, and whether peers may use your models.
//  Workspaces (teammates) and Devices (your own Macs and iPhones) are the
//  sibling pages.
//

import SwiftUI

struct AccessView: View {
    @ObservedObject private var agentManager = AgentManager.shared

    private var shareableAgents: [Agent] {
        agentManager.agents.filter { !$0.isBuiltIn && $0.agentAddress != nil }
    }

    var body: some View {
        SettingsPage {
            SettingsPageHeader(
                title: "Access",
                subtitle: "Who can reach your agents from outside this Mac, and the agents others shared with you"
            )
        } content: {
            RemoteAccessSection(anchorId: "access.remoteAccess")
            GuestAccessLedger(agents: shareableAgents)
                .settingsLandingAnchor("access.guests")
            SharedWithYouSection(anchorId: "access.sharedWithYou")
            ModelSharingSection()
        }
    }
}

/// Whether people who can reach your agents (teammates, guests, peers on the
/// local network) may also use your models directly. Takes effect on their
/// next request.
struct ModelSharingSection: View {
    @State private var isEnabled = PeerInferenceSharing.isEnabled()

    var body: some View {
        SettingsSection(title: "Model Sharing") {
            SettingsToggle(
                title: "Share My Models for Inference",
                description: "Teammates, guests and peers on your network can list the models you expose in Server → Models and run them through this Mac. Off: they see no models and those requests are refused. Chatting with agents you share works either way.",
                anchorId: "server.peerInference",
                isOn: $isEnabled
            )
        }
        .onChange(of: isEnabled) { _, newValue in
            PeerInferenceSharing.setEnabled(newValue)
        }
        .onAppear { isEnabled = PeerInferenceSharing.isEnabled() }
    }
}
