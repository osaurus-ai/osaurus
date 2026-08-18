//
//  AddChatsToProjectSheet.swift
//  osaurus
//
//  Themed-alert custom content for bulk-adding existing ungrouped chats to
//  a project, saving the tedious per-chat sidebar drag. Lists every chat not
//  already in a project; the user ticks any number and confirms.
//

import SwiftUI

/// Multi-select picker over the app's ungrouped chats. Presented via
/// `ThemedAlertCenter` custom content; the host owns dismissal and receives
/// the chosen session ids through `onAdd`.
struct AddChatsToProjectSheet: View {
    /// Candidate chats (already filtered to those in no project, unarchived).
    let candidates: [ChatSessionData]
    let onAdd: (Set<UUID>) -> Void

    @Environment(\.theme) private var theme
    @ObservedObject private var agentManager = AgentManager.shared
    @State private var selection: Set<UUID> = []
    @State private var query: String = ""
    @FocusState private var isSearchFocused: Bool

    private var filtered: [ChatSessionData] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return candidates }
        return candidates.filter { SearchService.matches(query: trimmed, in: $0.title) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pick chats to move into this project. They'll share its instructions, knowledge, and memory.", bundle: .module)
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            if candidates.isEmpty {
                emptyState
            } else {
                if candidates.count > 6 {
                    SidebarSearchField(
                        text: $query,
                        placeholder: "Search chats...",
                        isFocused: $isSearchFocused,
                        isSearching: false,
                        showsRestingBorder: true
                    )
                }

                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(filtered) { session in
                            row(session)
                        }
                    }
                }
                .frame(maxHeight: 300)

                HStack {
                    Text("\(selection.count) selected", bundle: .module)
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryText)
                    Spacer()
                    Button(action: { onAdd(selection) }) {
                        Text("Add to Project", bundle: .module)
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .disabled(selection.isEmpty)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "tray")
                .font(.system(size: 22))
                .foregroundColor(theme.secondaryText.opacity(0.5))
            Text("No ungrouped chats to add", bundle: .module)
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText.opacity(0.8))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    private func row(_ session: ChatSessionData) -> some View {
        let isSelected = selection.contains(session.id)
        let agent = session.agentId.flatMap { id in
            agentManager.agents.first { $0.id == id }
        }
        return Button {
            if isSelected { selection.remove(session.id) } else { selection.insert(session.id) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(isSelected ? theme.accentColor : theme.secondaryText.opacity(0.6))

                if let agent {
                    AgentAvatarView(
                        mascotId: agent.avatar,
                        name: agent.name,
                        tint: theme.accentColor,
                        diameter: 22,
                        customImageURL: agent.customAvatarURL,
                        monogramFontSize: 9,
                        borderWidth: 0
                    )
                } else {
                    Image(systemName: "bubble.left")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                        .frame(width: 22, height: 22)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: session.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)
                    if let agent {
                        Text(verbatim: agent.displayName)
                            .font(.system(size: 10))
                            .foregroundColor(theme.secondaryText.opacity(0.85))
                            .lineLimit(1)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? theme.accentColor.opacity(0.08) : .clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }
}
