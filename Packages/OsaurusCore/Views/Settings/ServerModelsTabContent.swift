//
//  ServerModelsTabContent.swift
//  osaurus
//
//  Server > Models: choose which models the API lists on /models and /tags.
//  Local models are exposed by default; remote provider models are hidden
//  until the user opts them in.
//

import SwiftUI

// MARK: - Row model

private struct ExposureModelRow: Identifiable, Equatable {
    /// The id exactly as the API lists it (repo slug, "foundation", or the
    /// provider-prefixed remote id). Also the exposure-override key.
    let id: String
    let title: String
    let subtitle: String
    let kind: ModelExposureKind

    func matches(_ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return id.localizedCaseInsensitiveContains(query)
            || title.localizedCaseInsensitiveContains(query)
            || subtitle.localizedCaseInsensitiveContains(query)
    }
}

private struct RemoteProviderGroup: Identifiable, Equatable {
    let id: UUID
    let name: String
    let rows: [ExposureModelRow]
}

// MARK: - Tab content

struct ServerModelsTabContent: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    let searchText: String

    @State private var localRows: [ExposureModelRow] = []
    @State private var hasLoadedLocalRows = false
    /// Snapshot of connected remote providers and their models. Never computed
    /// inside `body`: `cachedAvailableModels()` mutates the manager's
    /// `@Published` state (managed-router injection), so calling it during a
    /// view update would publish mid-render and loop.
    @State private var remoteGroups: [RemoteProviderGroup] = []
    /// Resolved exposure values for every toggled row, seeded lazily from the
    /// store so bindings stay cheap.
    @State private var exposedState: [String: Bool] = [:]

    private var theme: ThemeProtocol { themeManager.currentTheme }

    var body: some View {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filteredLocal = localRows.filter { $0.matches(query) }
        let groups = remoteGroups
        let filteredGroups: [(group: RemoteProviderGroup, rows: [ExposureModelRow])] =
            groups.compactMap { group in
                let rows = group.rows.filter { $0.matches(query) }
                return rows.isEmpty && !query.isEmpty ? nil : (group, rows)
            }

        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                introBanner

                // Local models
                ModelExposureSection(
                    title: L("Local Models"),
                    icon: "internaldrive",
                    exposedCount: exposedCount(in: localRows),
                    totalCount: localRows.count,
                    bulkAction: localRows.isEmpty
                        ? nil
                        : { exposed in setAll(localRows, exposed: exposed) }
                ) {
                    if !hasLoadedLocalRows {
                        loadingRow
                    } else if localRows.isEmpty {
                        emptyStateRow(
                            icon: "arrow.down.circle",
                            message: L(
                                "No local models installed yet. Download models from the Models manager and they will be exposed here automatically."
                            )
                        )
                    } else if filteredLocal.isEmpty {
                        emptyStateRow(icon: "magnifyingglass", message: L("No local models match your search."))
                    } else {
                        ForEach(filteredLocal) { row in
                            exposureToggleRow(row)
                        }
                    }
                }

                // Remote models
                remoteModelsHeader

                if groups.isEmpty {
                    ModelExposureSection(
                        title: L("Remote Models"),
                        icon: "cloud",
                        exposedCount: nil,
                        totalCount: nil,
                        bulkAction: nil
                    ) {
                        emptyStateRow(
                            icon: "antenna.radiowaves.left.and.right",
                            message: L(
                                "No remote providers connected. Models from Osaurus Router and your own providers appear here once connected."
                            )
                        )
                    }
                } else {
                    ForEach(filteredGroups, id: \.group.id) { entry in
                        ModelExposureSection(
                            title: entry.group.name,
                            icon: "cloud",
                            exposedCount: exposedCount(in: entry.group.rows),
                            totalCount: entry.group.rows.count,
                            bulkAction: { exposed in setAll(entry.group.rows, exposed: exposed) }
                        ) {
                            if entry.rows.isEmpty {
                                emptyStateRow(
                                    icon: "magnifyingglass",
                                    message: L("No models match your search.")
                                )
                            } else {
                                ForEach(entry.rows) { row in
                                    exposureToggleRow(row)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
        }
        .task {
            reloadRemoteGroups()
            await loadLocalRows()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .remoteProviderModelsChanged)
                .receive(on: DispatchQueue.main)
        ) { _ in
            reloadRemoteGroups()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .remoteProviderStatusChanged)
                .receive(on: DispatchQueue.main)
        ) { _ in
            reloadRemoteGroups()
        }
    }

    // MARK: - Subviews

    private var introBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(theme.accentColor)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(L("Choose which models the API lists"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Text(
                    L(
                        "Controls the models returned by /models and /tags. Hidden models can still be used by requesting them directly. Changes apply immediately."
                    )
                )
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.accentColor.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(theme.accentColor.opacity(0.18), lineWidth: 1)
                )
        )
    }

    private var remoteModelsHeader: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L("Remote Models"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.primaryText)
            Text(L("Hidden by default. Enable the remote models you want the API to list."))
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
        }
        .padding(.top, 4)
    }

    private var loadingRow: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(L("Scanning installed models…"))
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 12)
    }

    private func emptyStateRow(icon: String, message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundColor(theme.tertiaryText)
            Text(message)
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 4)
    }

    private func exposureToggleRow(_ row: ExposureModelRow) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if row.subtitle != row.title {
                    Text(row.subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()

            Toggle("", isOn: exposureBinding(for: row))
                .toggleStyle(SwitchToggleStyle(tint: theme.accentColor))
                .labelsHidden()
                .controlSize(.small)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.inputBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(theme.inputBorder, lineWidth: 1)
                )
        )
    }

    // MARK: - State

    private func isExposed(_ row: ExposureModelRow) -> Bool {
        exposedState[row.id] ?? ModelExposureStore.shared.isExposed(id: row.id, kind: row.kind)
    }

    private func exposureBinding(for row: ExposureModelRow) -> Binding<Bool> {
        Binding(
            get: { isExposed(row) },
            set: { newValue in
                ModelExposureStore.shared.setExposed(newValue, id: row.id, kind: row.kind)
                exposedState[row.id] = newValue
            }
        )
    }

    private func exposedCount(in rows: [ExposureModelRow]) -> Int {
        rows.count(where: { isExposed($0) })
    }

    private func setAll(_ rows: [ExposureModelRow], exposed: Bool) {
        guard let kind = rows.first?.kind else { return }
        ModelExposureStore.shared.setExposed(exposed, ids: rows.map(\.id), kind: kind)
        for row in rows {
            exposedState[row.id] = exposed
        }
    }

    // MARK: - Loading

    private func reloadRemoteGroups() {
        let groups = RemoteProviderManager.shared.cachedAvailableModels().map { entry in
            RemoteProviderGroup(
                id: entry.providerId,
                name: entry.providerName,
                rows: entry.models.map { prefixedId in
                    ExposureModelRow(
                        id: prefixedId,
                        title: Self.unprefixedRemoteId(prefixedId, providerName: entry.providerName),
                        subtitle: prefixedId,
                        kind: .remote
                    )
                }
            )
        }
        if groups != remoteGroups {
            remoteGroups = groups
        }
    }

    private func loadLocalRows() async {
        let discovered = await ModelManager.discoverLocalModelsOffMain()

        // Mirror `ModelManager.installedModelNames()`: the API id is the repo
        // slug, deduped case-insensitively, sorted by slug.
        var seen: Set<String> = []
        var rows: [ExposureModelRow] = []
        for model in discovered {
            let slug =
                model.id.split(separator: "/").last.map(String.init)?.lowercased()
                ?? model.id.lowercased()
            guard !seen.contains(slug) else { continue }
            seen.insert(slug)
            rows.append(
                ExposureModelRow(
                    id: slug,
                    title: slug,
                    subtitle: model.id,
                    kind: .local
                )
            )
        }
        rows.sort { $0.id < $1.id }

        if FoundationModelService.isDefaultModelAvailable() {
            rows.insert(
                ExposureModelRow(
                    id: "foundation",
                    title: "foundation",
                    subtitle: L("Apple Foundation Model"),
                    kind: .local
                ),
                at: 0
            )
        }

        localRows = rows
        hasLoadedLocalRows = true
    }

    // MARK: - Helpers

    /// Strips the provider prefix from a prefixed remote id, using the same
    /// slug rule as `RemoteProviderManager` ("Osaurus" -> "osaurus/").
    private static func unprefixedRemoteId(_ prefixedId: String, providerName: String) -> String {
        let prefix =
            providerName
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "/", with: "-") + "/"
        guard prefixedId.hasPrefix(prefix) else { return prefixedId }
        return String(prefixedId.dropFirst(prefix.count))
    }
}

// MARK: - Section card

private struct ModelExposureSection<Content: View>: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    let title: String
    let icon: String
    let exposedCount: Int?
    let totalCount: Int?
    /// When non-nil, renders "Expose all" / "Hide all" header actions.
    let bulkAction: ((Bool) -> Void)?
    @ViewBuilder let content: () -> Content

    private var theme: ThemeProtocol { themeManager.currentTheme }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.accentColor)

                Text(title)
                    .textCase(.uppercase)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(theme.secondaryText)
                    .tracking(0.5)

                if let exposedCount, let totalCount, totalCount > 0 {
                    Text(L("\(exposedCount) of \(totalCount) exposed"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.tertiaryText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(theme.inputBackground)
                        )
                }

                Spacer()

                if let bulkAction {
                    HStack(spacing: 6) {
                        bulkButton(L("Expose all")) { bulkAction(true) }
                        bulkButton(L("Hide all")) { bulkAction(false) }
                    }
                }
            }

            LazyVStack(alignment: .leading, spacing: 8) {
                content()
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(theme.cardBorder, lineWidth: 1)
                )
        )
    }

    private func bulkButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.secondaryText)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule()
                        .fill(theme.inputBackground)
                        .overlay(Capsule().stroke(theme.inputBorder, lineWidth: 1))
                )
        }
        .buttonStyle(.plain)
    }
}
