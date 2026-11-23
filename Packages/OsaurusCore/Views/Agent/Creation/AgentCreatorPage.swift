//
//  AgentCreatorPage.swift
//  osaurus
//
//  The main window's New Agent page: the Configurator chat with the agent
//  card beside it. The title bar's back button returns to wherever New
//  Agent was opened from.
//

import SwiftUI

/// The New Agent surface of a chat window. Create lands in a chat with the
/// new agent; Discard goes back.
struct AgentCreatorMainDestination: View {
    @ObservedObject var windowState: ChatWindowState
    @ObservedObject private var creator = AgentCreatorController.shared

    var body: some View {
        Group {
            if let chat = creator.chat {
                AgentCreatorPage(chat: chat, onDiscard: discard, onCreated: landOnCreatedAgent)
                    .id(ObjectIdentifier(chat))
            } else {
                Color.clear.onAppear(perform: leave)
            }
        }
        .background(windowState.theme.surface.canvas)
        .environment(\.theme, windowState.theme)
    }

    private func discard() {
        creator.discard()
        leave()
    }

    /// Chat with the new agent; showing it runs its first-run setup check.
    private func landOnCreatedAgent(_ agentId: UUID) {
        creator.finish()
        windowState.leaveNewAgent {
            windowState.showMainSurface(.chat)
            windowState.switchAgent(to: agentId)
        }
    }

    /// Nothing left to show: back where New Agent was opened from.
    private func leave() {
        guard windowState.mainSurface == .newAgent else { return }
        if !windowState.returnToPreviousSurface() {
            windowState.leaveNewAgent { windowState.showMainSurface(.chat) }
        }
    }
}

struct AgentCreatorPage: View {
    @Environment(\.theme) private var theme
    @ObservedObject var chat: ChatWindowState
    let onDiscard: () -> Void
    let onCreated: (UUID) -> Void

    @ObservedObject private var store = AgentDraftStore.shared
    @State private var confirmingDiscard = false

    private var draftName: String {
        store.draft(forSession: chat.session.sessionId?.uuidString)?.agent.name
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    var body: some View {
        VStack(spacing: theme.space.s0) {
            SettingsPageHeader(
                title: draftName.isEmpty ? L("New Agent") : draftName,
                verbatimTitle: true,
                overflow: {
                    Button(role: .destructive, action: { confirmingDiscard = true }) {
                        Label(L("Discard Draft"), systemImage: "trash")
                    }
                }
            )

            ChatView(windowState: chat, embedded: true, onAgentCreated: onCreated)
        }
        .themedAlert(
            L("Discard this draft?"),
            isPresented: $confirmingDiscard,
            message: L("The draft and its chat are removed. Nothing was created yet."),
            buttons: [
                .cancel(L("Cancel")),
                .destructive(L("Discard")) { onDiscard() },
            ]
        )
    }
}
