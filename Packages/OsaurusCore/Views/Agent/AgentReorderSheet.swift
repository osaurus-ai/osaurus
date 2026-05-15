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
        VStack(spacing: 0) {
            header

            Divider().foregroundColor(theme.primaryBorder)

            if orderedAgents.isEmpty {
                emptyState
            } else {
                // EditMode is iOS-only; macOS List supports drag-reorder natively.
                List {
                    ForEach(orderedAgents) { agent in
                        row(for: agent)
                            .listRowBackground(theme.cardBackground)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
                    }
                    .onMove(perform: moveAgents)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(minWidth: 420, minHeight: 480)
        .background(theme.secondaryBackground)
        .onAppear { syncFromManager() }
        .onReceive(agentManager.$agents) { _ in syncFromManager() }
        .onDisappear { commitIfNeeded() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Reorder Agents", bundle: .module)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Text("Drag to set the order shown across the app.", bundle: .module)
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
            }

            Spacer()

            Button {
                dismiss()
            } label: {
                Text("Done", bundle: .module)
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Row

    private func row(for agent: Agent) -> some View {
        HStack(spacing: 12) {
            AgentAvatarView(
                mascotId: agent.avatar,
                name: agent.name,
                tint: theme.accentColor,
                diameter: 28,
                customImageURL: agent.customAvatarURL,
                monogramFontSize: 13,
                borderWidth: 1
            )

            VStack(alignment: .leading, spacing: 1) {
                Text(agent.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)

                if !agent.description.isEmpty {
                    Text(agent.description)
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryText)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            Image(systemName: "line.3.horizontal")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(theme.tertiaryText)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 32, weight: .light))
                .foregroundColor(theme.tertiaryText)
            Text("No custom agents to reorder.", bundle: .module)
                .font(.system(size: 13))
                .foregroundColor(theme.secondaryText)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
