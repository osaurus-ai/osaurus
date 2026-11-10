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

    private var theme: any ThemeProtocol { themeManager.currentTheme }

    var body: some View {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filteredLocal = localRows.filter { $0.matches(query) }
        let groups = remoteGroups
        let filteredGroups: [(group: RemoteProviderGroup, rows: [ExposureModelRow])] =
            groups.compactMap { group in
                let rows = group.rows.filter { $0.matches(query) }
                return rows.isEmpty && !query.isEmpty ? nil : (group, rows)
            }

        ScrollView {
            LazyVStack(alignment: .leading, spacing: theme.settingsSectionGap) {
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
                        SettingsEmptyState(
                            inline: "arrow.down.circle",
                            title: "No local models installed yet",
                            hint: "Download models from the Models manager and they will be exposed here automatically."
                        )
                    } else if filteredLocal.isEmpty {
                        SettingsEmptyState(inline: "magnifyingglass", title: "No local models match your search.")
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
                        SettingsEmptyState(
                            inline: "antenna.radiowaves.left.and.right",
                            title: "No remote providers connected",
                            hint: "Models from Osaurus Router and your own providers appear here once connected."
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
                                SettingsEmptyState(inline: "magnifyingglass", title: "No models match your search.")
                            } else {
                                ForEach(entry.rows) { row in
                                    exposureToggleRow(row)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, theme.space.s24)
            .padding(.vertical, theme.space.s24)
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
        HStack(alignment: .top, spacing: theme.space.s8) {
            Image(systemName: "list.bullet.rectangle")
                .glyphSize(13, weight: .medium)
                .foregroundColor(theme.text.link)
                .padding(.top, theme.space.s2)

            VStack(alignment: .leading, spacing: theme.space.s4) {
                Text(L("Choose which models the API lists"))
                    .catalogTypography(.heading, theme: theme, fallback: SettingsFont.sectionTitle)
                    .foregroundColor(theme.text.primary)
                Text(
                    L(
                        "Controls the models returned by /models and /tags. Hidden models can still be used by requesting them directly. Changes apply immediately."
                    )
                )
                .componentInspectionText(47, role: .caption, fallback: .caption, theme: theme)
                .foregroundColor(theme.text.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, theme.space.s12).padding(.vertical, theme.space.s12)
        .settingsChrome(.selected)
    }

    private var remoteModelsHeader: some View {
        VStack(alignment: .leading, spacing: theme.space.s2) {
            Text(L("Remote Models"))
                .catalogTypography(.heading, theme: theme, fallback: SettingsFont.sectionTitle)
                .foregroundColor(theme.text.primary)
            Text(L("Hidden by default. Enable the remote models you want the API to list."))
                .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
                .foregroundColor(theme.text.tertiary)
        }
        .padding(.top, theme.space.s4)
    }

    private var loadingRow: some View {
        HStack(spacing: theme.space.s8) {
            ProgressView()
                .controlSize(.small)
            Text(L("Scanning installed models…"))
                .catalogTypography(.caption, theme: theme, fallback: SettingsFont.caption)
                .foregroundColor(theme.text.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, theme.space.s12)
    }

    private func exposureToggleRow(_ row: ExposureModelRow) -> some View {
        HStack(spacing: theme.space.s12) {
            VStack(alignment: .leading, spacing: theme.space.s2) {
                Text(row.title)
                    .catalogTypography(.label, theme: theme, fallback: SettingsFont.rowTitle)
                    .foregroundColor(theme.text.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if row.subtitle != row.title {
                    Text(row.subtitle)
                        .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
                        .foregroundColor(theme.text.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()

            Toggle("", isOn: exposureBinding(for: row))
                .settingsSwitch()
        }
        .padding(.vertical, theme.space.s8)
        .padding(.horizontal, theme.space.s12)
        .settingsChrome(.control)
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

    private var theme: any ThemeProtocol { themeManager.currentTheme }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s12) {
            HStack(spacing: theme.space.s8) {
                Image(systemName: icon)
                    .glyphSize(12, weight: .semibold)
                    .foregroundColor(theme.text.link)

                Text(title)
                    .catalogTypography(.label, theme: theme, fallback: SettingsFont.compactLabel)
                    .foregroundColor(theme.text.secondary)

                if let exposedCount, let totalCount, totalCount > 0 {
                    StatusChip(L("\(exposedCount) of \(totalCount) exposed"))
                }

                Spacer()

                if let bulkAction {
                    HStack(spacing: theme.space.s6) {
                        bulkButton(L("Expose all")) { bulkAction(true) }
                        bulkButton(L("Hide all")) { bulkAction(false) }
                    }
                }
            }

            LazyVStack(alignment: .leading, spacing: theme.space.s8) {
                content()
            }
        }
        .padding(.horizontal, theme.space.s16).padding(.vertical, theme.space.s16)
        .settingsChrome(.card)
    }

    private func bulkButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
        }
        .assignedSettingsButtonStyle(.secondary, size: .compact)
    }
}
