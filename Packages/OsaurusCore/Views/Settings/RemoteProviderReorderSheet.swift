//
//  RemoteProviderReorderSheet.swift
//  osaurus
//
//  Drag-to-reorder remote API providers. Commits once on dismiss.
//

import SwiftUI

struct RemoteProviderReorderSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @ObservedObject private var manager = RemoteProviderManager.shared

    @State private var orderedProviders: [RemoteProvider] = []
    @State private var hasPendingReorder = false

    var body: some View {
        VStack(spacing: theme.space.s0) {
            SettingsSheetHeader(
                icon: "arrow.up.arrow.down",
                title: "Reorder Providers",
                subtitle: "Drag to set the order shown across the app.",
                onClose: { dismiss() }
            )

            if orderedProviders.isEmpty {
                emptyState
            } else {
                // EditMode is iOS-only; macOS List supports drag-reorder natively.
                List {
                    ForEach(orderedProviders) { provider in
                        row(for: provider)
                            .listRowBackground(theme.surface.raised)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
                    }
                    .onMove(perform: moveProviders)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }

            SettingsSheetFooter(primary: .init(label: "Done") { dismiss() })
        }
        .frame(minWidth: SettingsSheetWidth.compact, minHeight: 480)
        .background(theme.surface.subtle)
        .onAppear { syncFromManager() }
        .onReceive(manager.$configuration) { _ in syncFromManager() }
        .onDisappear { commitIfNeeded() }
    }

    // MARK: - Row

    private func row(for provider: RemoteProvider) -> some View {
        HStack(spacing: theme.space.s12) {
            ZStack {
                if let preset = ProviderPreset.matching(provider: provider) {
                    ProviderIcon(preset: preset, size: 16, color: theme.action.primary.default.background)
                } else {
                    Image(systemName: "cloud.fill")
                        .glyphSize(.body)
                        .foregroundColor(theme.text.link)
                }
            }
            .frame(width: 28, height: 28)
            .settingsChrome(.selected)

            VStack(alignment: .leading, spacing: theme.space.s2) {
                Text(provider.name)
                    .font(SettingsFont.rowTitle)
                    .foregroundColor(theme.text.primary)
                    .lineLimit(1)

                Text(provider.displayEndpoint)
                    .font(SettingsFont.monoSmall)
                    .foregroundColor(theme.text.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
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
        SettingsEmptyState(inline: "line.3.horizontal", title: "No providers to reorder.")
            .frame(maxHeight: .infinity)
    }

    // MARK: - Actions

    /// Preserve working order on external change so an in-progress drag stays stable.
    private func syncFromManager() {
        // Same visibility rule as the Cloud Models list: no managed router,
        // and no paired Osaurus agents whose owner shares no models for
        // inference. `reorder(orderedIds:)` appends omitted providers, so
        // hidden ones keep their relative order.
        let incoming = manager.configuration.providers.filter {
            $0.providerType != .osaurusRouter && manager.exposesModelsForInference($0)
        }
        let existingIds = Set(orderedProviders.map(\.id))
        let incomingIds = Set(incoming.map(\.id))
        let kept = orderedProviders.filter { incomingIds.contains($0.id) }
        let added = incoming.filter { !existingIds.contains($0.id) }
        orderedProviders = kept + added
    }

    private func moveProviders(from source: IndexSet, to destination: Int) {
        orderedProviders.move(fromOffsets: source, toOffset: destination)
        hasPendingReorder = true
    }

    private func commitIfNeeded() {
        guard hasPendingReorder else { return }
        manager.reorder(orderedIds: orderedProviders.map(\.id))
        hasPendingReorder = false
    }
}
