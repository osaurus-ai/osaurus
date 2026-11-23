//
//  AgentReorderSheet.swift
//  osaurus
//
//  Drag-to-reorder custom agents. Commits once on dismiss.
//

import SwiftUI

struct AgentReorderSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @ObservedObject private var agentManager = AgentManager.shared

    @State private var orderedAgents: [Agent] = []
    @State private var hasPendingReorder = false

    var body: some View {
        VStack(spacing: theme.space.s0) {
            SettingsSheetHeader(
                icon: "arrow.up.arrow.down",
                title: "Reorder Agents",
                subtitle: "Drag to set the order shown across the app.",
                onClose: { dismiss() }
            )

            if orderedAgents.isEmpty {
                emptyState
            } else {
                // EditMode is iOS-only; macOS List supports drag-reorder natively.
                List {
                    ForEach(orderedAgents) { agent in
                        row(for: agent)
                            .listRowBackground(theme.surface.raised)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
                    }
                    .onMove(perform: moveAgents)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }

            SettingsSheetFooter(primary: .init(label: "Done") { dismiss() })
        }
        .frame(minWidth: SettingsSheetWidth.compact, minHeight: 480)
        .background(theme.surface.subtle)
        .onAppear { syncFromManager() }
        .onReceive(agentManager.$agents) { _ in syncFromManager() }
        .onDisappear { commitIfNeeded() }
    }

    // MARK: - Row

    private func row(for agent: Agent) -> some View {
        HStack(spacing: theme.space.s12) {
            AgentAvatarView(
                mascotId: agent.avatar,
                name: agent.name,
                tint: theme.action.primary.default.background,
                diameter: 28,
                customImageURL: agent.customAvatarURL,
                monogramFontSize: 13,
                borderWidth: 1
            )

            SettingsRowText {
                Text(agent.name)
                    .lineLimit(1)
            } description: {
                if !agent.displayDescription.isEmpty {
                    Text(agent.displayDescription)
                        .foregroundColor(theme.text.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            Image(systemName: "line.3.horizontal")
                .glyphSize(.label, weight: .medium)
                .foregroundColor(theme.text.tertiary)
        }
        .padding(.vertical, theme.space.s6)
        .contentShape(Rectangle())
    }

    // MARK: - Empty State

    private var emptyState: some View {
        SettingsEmptyState(inline: "line.3.horizontal", title: "No custom agents to reorder.")
            .frame(maxHeight: .infinity)
    }

    // MARK: - Actions

    /// Preserve working order on external change so an in-progress drag stays stable.
    private func syncFromManager() {
        let custom = agentManager.agents.filter { !$0.isBuiltIn }
        let existingIds = Set(orderedAgents.map(\.id))
        let incomingIds = Set(custom.map(\.id))
        let kept = orderedAgents.filter { incomingIds.contains($0.id) }
        let added = custom.filter { !existingIds.contains($0.id) }
        orderedAgents = kept + added
    }

    private func moveAgents(from source: IndexSet, to destination: Int) {
        orderedAgents.move(fromOffsets: source, toOffset: destination)
        hasPendingReorder = true
    }

    private func commitIfNeeded() {
        guard hasPendingReorder else { return }
        agentManager.reorder(orderedIds: orderedAgents.map(\.id))
        hasPendingReorder = false
    }
}
