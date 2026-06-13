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
        VStack(spacing: 0) {
            header

            Divider().foregroundColor(theme.primaryBorder)

            if orderedProviders.isEmpty {
                emptyState
            } else {
                // EditMode is iOS-only; macOS List supports drag-reorder natively.
                List {
                    ForEach(orderedProviders) { provider in
                        row(for: provider)
                            .listRowBackground(theme.cardBackground)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
                    }
                    .onMove(perform: moveProviders)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(minWidth: 420, minHeight: 480)
        .background(theme.secondaryBackground)
        .onAppear { syncFromManager() }
        .onReceive(manager.$configuration) { _ in syncFromManager() }
        .onDisappear { commitIfNeeded() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Reorder Providers", bundle: .module)
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

    private func row(for provider: RemoteProvider) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.accentColor.opacity(0.12))
                if let preset = ProviderPreset.matching(provider: provider) {
                    ProviderIcon(preset: preset, size: 16, color: theme.accentColor)
                } else {
                    Image(systemName: "cloud.fill")
                        .font(.system(size: 14))
                        .foregroundColor(theme.accentColor)
                }
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text(provider.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)

                Text(provider.displayEndpoint)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
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
            Text("No providers to reorder.", bundle: .module)
                .font(.system(size: 13))
                .foregroundColor(theme.secondaryText)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    /// Preserve working order on external change so an in-progress drag stays stable.
    private func syncFromManager() {
        let incoming = manager.configuration.providers.filter { $0.providerType != .osaurusRouter }
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
