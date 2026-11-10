//
//  AgentCreatorPage.swift
//  osaurus
//
//  Settings → Agents → New agent: the Configurator chat with the agent
//  card beside it, under the Agents page's back line. Settings' sidebar
//  collapses while it shows.
//

import SwiftUI

struct AgentCreatorPage: View {
    @ObservedObject var chat: ChatWindowState
    let onBack: () -> Void
    let onDiscard: () -> Void
    let onCreated: (UUID) -> Void

    @ObservedObject private var store = AgentDraftStore.shared
    @State private var confirmingDiscard = false

    private var draftName: String {
        store.draft(forSession: chat.session.sessionId?.uuidString)?.agent.name
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    var body: some View {
        VStack(spacing: 0) {
            SettingsPageHeader(
                title: draftName.isEmpty ? L("New Agent") : draftName,
                verbatimTitle: true,
                overflow: {
                    Button(role: .destructive, action: { confirmingDiscard = true }) {
                        Label(L("Discard Draft"), systemImage: "trash")
                    }
                }
            )
            .settingsBackDestination(L("Agents"), verbatim: true, action: onBack)

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
