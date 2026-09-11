//
//  ModelPickerView.swift
//  osaurus
//
//  Two-pane model picker: a sidebar of groups (Favorites, On this Mac,
//  Osaurus Cloud, each configured provider, Claude Code, + Add provider)
//  and a list pane with a group header, search, and metadata-rich rows.
//  The selected model expands inline to reveal its options.
//

import AppKit
import SwiftUI

struct ModelPickerView: View {
    let options: [ModelPickerItem]
    @Binding var selectedModel: String?
    let agentId: UUID?
    var optionsControl: ModelPickerOptionsControl? = nil
    /// Group to open on instead of the one holding the selected model —
    /// used to land on a provider the user just added from the picker.
    var initialGroupKey: String? = nil
    /// Host hook for the inline add-provider catalog. When nil the picker
    /// falls back to opening the Cloud Providers management tab.
    var onAddProvider: ((ModelPickerAddProviderChoice) -> Void)? = nil
    let onDismiss: () -> Void

    @State private var searchText = ""
    /// Tracks IME composition so the placeholder hides while composing.
    @State private var isSearchComposing = false
    @State private var selectedGroupKey: String?
    @State private var sortOrder: ModelPickerSortOrder = .default
    @State private var contextFilter: ModelPickerContextFilter = .any
    @State private var visionFilter: ModelPickerVisionFilter = .any
    @State private var toolsFilter: ModelPickerToolsFilter = .any
    @State private var localSourceFilter: ModelPickerLocalSourceFilter = .any
    @State private var showSortPopover = false
    @State private var isAddingProvider = false
    @State private var reconnectingProviderIds: Set<UUID> = []
    @State private var isCompactSidebar = false
    @ObservedObject private var favoritesStore = FavoriteModelsStore.shared
    @ObservedObject private var providerManager = RemoteProviderManager.shared
    @Environment(\.theme) private var theme

    /// List pane width; the sidebar adds its expanded or compact width.
    private static let listPaneWidth: CGFloat = 452
    private static let pickerHeight: CGFloat = 500
    /// Below this host-window width the sidebar collapses to an icon rail.
    private static let compactSidebarThreshold: CGFloat = 660

    // MARK: - Test Mode

    #if DEBUG
        // set USE_MOCK_MODELS=1 in Xcode scheme to automatically use mock data
        private var useMockData: Bool {
            ProcessInfo.processInfo.environment["USE_MOCK_MODELS"] == "1"
        }

        private var displayOptions: [ModelPickerItem] {
            useMockData ? ModelPickerItem.generateMockModels(count: 500) : options
        }
    #else
        private var displayOptions: [ModelPickerItem] { options }
    #endif

    // MARK: - Data

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Picker options with non-MLX local bundles removed. The catalog greys
    /// these out so the user can see why they won't run, but the picker exists
    /// only to select a usable model — a non-selectable row is just clutter, so
    /// drop them here. Non-local sources (foundation, remote) are always
    /// `isMLXFormat`, so only co-mingled local non-MLX bundles are filtered.
    /// Filtering before grouping keeps the header count, sidebar counts, and
    /// rows all consistent.
    private var visibleOptions: [ModelPickerItem] {
        displayOptions.filter { $0.isMLXFormat }
    }

    private var currentGroups: [ModelPickerGroup] {
        visibleOptions.groupedIntoPickerGroups(
            providers: providerManager.pickerProviderDescriptors(),
            favoriteKeys: Set(favoritesStore.favoriteKeys)
        )
    }

    /// Provider attribution shown on Favorites / search rows, since those
    /// mix models from every source into one list.
    private func providerTitle(for item: ModelPickerItem) -> String {
        switch item.source {
        case .foundation, .local, .imageGeneration:
            return L("On this Mac")
        case .claudeCode:
            return item.source.displayName
        case .remote(_, let providerId):
            if providerId == RemoteProviderManager.osaurusRouterProviderId { return L("Osaurus Cloud") }
            if case .remote(let providerName, _) = item.source { return providerName }
            return ""
        }
    }

    /// The group holding `selectedModel`, preferring a source group over
    /// Favorites (which mirrors models from elsewhere).
    private static func groupKey(holding selectedModel: String?, in groups: [ModelPickerGroup]) -> String? {
        guard let selectedModel else { return nil }
        let sourceGroup = groups.first { group in
            !group.isFavorites && group.models.contains { $0.id == selectedModel }
        }
        return sourceGroup?.key
    }

    /// The group worth committing to when there is no explicit selection:
    /// the one holding `selectedModel`, otherwise the first source group that
    /// actually has models. Returns nil when no group has any model yet — the
    /// host snapshots the options list asynchronously, so on first open the
    /// sidebar can briefly consist of empty provider descriptors only, and
    /// committing "Favorites" (or an empty provider) at that moment would
    /// stick once the models arrive.
    static func defaultGroupKey(in groups: [ModelPickerGroup], selectedModel: String?) -> String? {
        if let key = groupKey(holding: selectedModel, in: groups) { return key }
        return groups.first(where: { !$0.models.isEmpty && !$0.isFavorites })?.key
    }

    /// The group to render as active: the explicit selection while its group
    /// still exists, otherwise the derived default, otherwise the first
    /// source group (so a picker with only disconnected providers still
    /// lands on one of them rather than an empty Favorites). A selection
    /// whose group is transiently absent mid-refresh falls back here for
    /// rendering only.
    private func effectiveSelectedGroupKey(in groups: [ModelPickerGroup]) -> String? {
        if let key = selectedGroupKey, groups.contains(where: { $0.key == key }) {
            return key
        }
        if let key = Self.defaultGroupKey(in: groups, selectedModel: selectedModel) { return key }
        return groups.first(where: { !$0.isFavorites })?.key ?? groups.first?.key
    }

    /// Resolve which group key should be *committed to `selectedGroupKey`*,
    /// given the currently committed key and the available groups.
    ///
    /// Once a key is committed it is returned untouched — even if that group
    /// is momentarily absent. The picker refreshes its model lists
    /// asynchronously while open (`refreshConnectedProviders` /
    /// `buildModelPickerItems`), so a group can briefly disappear
    /// mid-refresh; clobbering the user's explicit choice on that transient
    /// absence is what made the picker snap from "Local" back to the first
    /// tab. Rendering still falls back gracefully via
    /// `effectiveSelectedGroupKey` while a group is missing, and the
    /// committed key re-resolves the moment it returns.
    ///
    /// With no committed key it uses `initialGroupKey` when that group
    /// exists, otherwise derives the default via `defaultGroupKey`.
    static func resolveCommittedGroupKey(
        current: String?,
        groups: [ModelPickerGroup],
        selectedModel: String?,
        initialGroupKey: String? = nil
    ) -> String? {
        if let current { return current }
        if let initialGroupKey, groups.contains(where: { $0.key == initialGroupKey }) {
            return initialGroupKey
        }
        return defaultGroupKey(in: groups, selectedModel: selectedModel)
    }

    private func ensureSelectedGroupValid() {
        let resolved = Self.resolveCommittedGroupKey(
            current: selectedGroupKey,
            groups: currentGroups,
            selectedModel: selectedModel,
            initialGroupKey: initialGroupKey
        )
        if selectedGroupKey != resolved { selectedGroupKey = resolved }
    }

    // MARK: - Rows

    private func row(for model: ModelPickerItem, providerLabel: String? = nil) -> ModelPickerRow {
        let media = model.mediaModel
        let structured = model.metadataLine
        return ModelPickerRow(
            modelId: model.id,
            sourceKey: model.source.uniqueKey,
            displayName: model.displayName,
            description: media.map(Self.mediaDetails) ?? structured,
            parameterCount: model.parameterCount,
            quantization: model.quantization,
            isVLM: model.isVLM,
            supportsTools: model.supportsToolCalling,
            supportsReasoning: model.supportsReasoning,
            isDeprecated: model.isDeprecated,
            recommendedReason: model.recommendedReason,
            // The long-form provider description goes to the tooltip when the
            // second line is taken by structured metadata.
            tooltip: (structured != model.description) ? model.description : nil,
            mediaKind: media?.kind,
            mediaPrivacy: media?.privacy.map(Self.mediaPrivacyLabel),
            mediaPrice: media?.pricing?.minimumUSD.map {
                "From \(OsaurusRouter.formatUSDAsCredits($0))"
            },
            isMLXFormat: model.isMLXFormat,
            providerLabel: providerLabel,
            isFavorite: favoritesStore.isFavorite(model.favoriteKey)
        )
    }

    private static func mediaPrivacyLabel(_ value: String) -> String {
        value
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .capitalized
    }

    private static func mediaDetails(_ model: MediaModelInfo) -> String? {
        let constraints = model.constraints
        var details: [String] = []
        if !constraints.aspectRatios.isEmpty {
            details.append("AR: \(constraints.aspectRatios.joined(separator: ", "))")
        }
        if !constraints.resolutions.isEmpty {
            details.append("Res: \(constraints.resolutions.joined(separator: ", "))")
        }
        if !constraints.qualities.isEmpty {
            details.append("Quality: \(constraints.qualities.joined(separator: ", "))")
        }
        if !constraints.durations.isEmpty {
            details.append("Duration: \(constraints.durations.joined(separator: ", "))")
        }
        if let defaultSteps = constraints.defaultSteps, let maxSteps = constraints.maxSteps {
            details.append("Steps: \(defaultSteps)–\(maxSteps)")
        } else if let maxSteps = constraints.maxSteps {
            details.append("Steps: ≤\(maxSteps)")
        } else if let defaultSteps = constraints.defaultSteps {
            details.append("Steps: \(defaultSteps)")
        }
        if constraints.supportsAudio {
            details.append(constraints.audioConfigurable ? "Optional audio" : "Audio")
        }
        if let limit = constraints.promptCharacterLimit {
            details.append("Prompt: \(limit.formatted(.number.notation(.compactName)))")
        }
        if let divisor = constraints.dimensionDivisor, divisor > 1 {
            details.append("\(divisor) px increments")
        }
        return details.isEmpty ? nil : details.joined(separator: " · ")
    }

    /// Apply the active filters/sort to a group's models. Every filter is a
    /// no-op at its default, so the pipeline is safe to run for any group.
    private func processedModels(for group: ModelPickerGroup) -> [ModelPickerItem] {
        var models = group.models
        if group.isLocal {
            models = models.filteredByLocalSource(localSourceFilter)
        }
        return
            models
            .filteredByContext(contextFilter)
            .filteredByVision(visionFilter)
            .filteredByTools(toolsFilter)
            .sortedByPrice(sortOrder)
    }

    /// Insert the inline options row directly after the first row for the
    /// selected model, when the selected model has options to show.
    private func insertingOptionsRow(into rows: [ModelPickerRow]) -> [ModelPickerRow] {
        guard let optionsControl, !optionsControl.isEmpty, let selectedModel,
            let index = rows.firstIndex(where: { $0.isModel && $0.modelId == selectedModel })
        else { return rows }
        var result = rows
        result.insert(
            .options(forModelId: selectedModel, sourceKey: rows[index].sourceKey),
            at: index + 1
        )
        return result
    }

    private func visibleRows(in groups: [ModelPickerGroup]) -> [ModelPickerRow] {
        let rows: [ModelPickerRow]
        if isSearching {
            rows = searchRows(in: groups)
        } else {
            guard let key = effectiveSelectedGroupKey(in: groups),
                let group = groups.first(where: { $0.key == key })
            else { return [] }
            if group.isFavorites {
                // Favorites mixes models from every source, so each row
                // carries its provider label to stay distinguishable.
                rows = processedModels(for: group).map { row(for: $0, providerLabel: providerTitle(for: $0)) }
            } else {
                rows = processedModels(for: group).map { row(for: $0) }
            }
        }
        return insertingOptionsRow(into: rows)
    }

    private func searchRows(in groups: [ModelPickerGroup]) -> [ModelPickerRow] {
        // Unified search: one pass across every source group's models with
        // the query prepared once, grouped under a header per source so
        // identical model IDs offered by different providers stay
        // distinguishable. Favorites is skipped (its models live elsewhere).
        let prepared = SearchService.PreparedQuery(searchText)
        var rows: [ModelPickerRow] = []
        rows.reserveCapacity(64)

        for group in groups where !group.isFavorites {
            var matched: [ModelPickerRow] = []
            for model in group.models {
                guard
                    SearchService.matches(prepared, in: model.displayName)
                        || SearchService.matches(prepared, in: model.id)
                else { continue }
                matched.append(row(for: model))
            }
            guard !matched.isEmpty else { continue }
            rows.append(.header(title: group.title, key: group.key))
            rows.append(contentsOf: matched)
        }
        return rows
    }

    private func switchGroup(by offset: Int) {
        let groups = currentGroups
        guard !groups.isEmpty else { return }
        let activeKey = effectiveSelectedGroupKey(in: groups)
        let currentIndex = groups.firstIndex(where: { $0.key == activeKey }) ?? 0
        let newIndex = max(0, min(groups.count - 1, currentIndex + offset))
        guard groups[newIndex].key != activeKey else { return }
        selectedGroupKey = groups[newIndex].key
    }

    // MARK: - Body

    private var selectedModelReplacement: String? {
        guard let id = selectedModel else { return nil }
        return ModelManager.replacementForDeprecatedModel(id)
    }

    private var sidebarWidth: CGFloat {
        isCompactSidebar ? ModelPickerSidebar.compactWidth : ModelPickerSidebar.expandedWidth
    }

    var body: some View {
        let groups = currentGroups
        let activeKey = effectiveSelectedGroupKey(in: groups)
        let activeGroup = groups.first { $0.key == activeKey }
        let rows = visibleRows(in: groups)

        HStack(spacing: 0) {
            ModelPickerSidebar(
                groups: groups,
                activeKey: activeKey,
                selectedModelGroupKey: Self.groupKey(holding: selectedModel, in: groups),
                isCompact: isCompactSidebar,
                isAddingProvider: isAddingProvider,
                onSelect: { key in
                    isAddingProvider = false
                    selectedGroupKey = key
                    if isSearching { searchText = "" }
                },
                onAddProvider: { beginAddProvider() }
            )

            Divider().background(theme.primaryBorder.opacity(0.3))

            listPane(groups: groups, activeGroup: activeGroup, rows: rows)
                .frame(width: Self.listPaneWidth)
        }
        .frame(width: sidebarWidth + Self.listPaneWidth + 1, height: Self.pickerHeight)
        .background(popoverBackground)
        .overlay(popoverBorder)
        .shadow(color: theme.shadowColor.opacity(0.15), radius: 12, x: 0, y: 6)
        .background(
            // Reads the *host* window's width (the popover's parent), not
            // NSApp.mainWindow/keyWindow: the chat window is a panel that is
            // neither once the popover is up, so those report other windows.
            ModelPickerHostWindowWidthReader { width in
                let compact = width < Self.compactSidebarThreshold
                if compact != isCompactSidebar { isCompactSidebar = compact }
            }
        )
        .onAppear {
            ensureSelectedGroupValid()
        }
        .task {
            // refresh remote model lists on open so newly-added/removed
            // models surface
            await RemoteProviderManager.shared.refreshConnectedProviders()
            await ModelPickerItemCache.shared.buildModelPickerItems()
            ensureSelectedGroupValid()

            // Drop external models (HF cache, LM Studio) the user deleted on
            // disk while the app stayed running — the picker cache is built
            // once and only rebuilds on `.localModelsChanged`, which this
            // posts when something went missing. Cheap existence check; no-op
            // when nothing changed. Runs last since it's the lowest priority.
            _ = await Task.detached(priority: .utility) {
                ExternalModelLocator.pruneMissing()
            }.value
        }
        .onChange(of: options) { _, _ in
            ensureSelectedGroupValid()
        }
    }

    @ViewBuilder
    private func listPane(groups: [ModelPickerGroup], activeGroup: ModelPickerGroup?, rows: [ModelPickerRow])
        -> some View
    {
        if isAddingProvider {
            ModelPickerAddProviderPane(
                configuredPresets: configuredPresets,
                isClaudeCodeConfigured: groups.contains(where: \.isClaudeCode),
                onChoose: { choice in chooseProvider(choice) },
                onCancel: { isAddingProvider = false }
            )
        } else {
            VStack(spacing: 0) {
                // While searching the capsule counts matches (model rows only,
                // not the per-group header rows), not the whole catalog.
                groupHeader(activeGroup, totalCount: rows.filter { $0.isModel }.count)
                Divider().background(theme.primaryBorder.opacity(0.3))
                searchField
                Divider().background(theme.primaryBorder.opacity(0.3))

                if let replacement = selectedModelReplacement {
                    deprecationBanner(replacement: replacement)
                }

                // The table stays mounted even with no rows so its key monitor
                // (Esc, ←/→ group switching, type-to-search) keeps working on
                // an empty search or a disconnected provider; the empty state
                // overlays it.
                // Favorites-mode (always-visible remove star) only while the
                // Favorites group is the active, non-search view.
                modelList(
                    rows: rows,
                    isFavoritesGroup: !isSearching && activeGroup?.isFavorites == true
                )
                .overlay {
                    if rows.isEmpty {
                        emptyState(for: activeGroup)
                    }
                }
            }
        }
    }

    /// Presets already configured, for the inline catalog's "Added" tags.
    private var configuredPresets: Set<ProviderPreset> {
        Set(providerManager.configuration.providers.compactMap { ProviderPreset.matching(provider: $0) })
    }

    // MARK: - Background & Border

    private var popoverBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(theme.primaryBackground)
    }

    private var popoverBorder: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(
                LinearGradient(
                    colors: [theme.glassEdgeLight.opacity(0.2), theme.primaryBorder.opacity(0.15)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1
            )
    }

    // MARK: - Group Header

    @ViewBuilder
    private func groupHeader(_ group: ModelPickerGroup?, totalCount: Int) -> some View {
        HStack(spacing: 8) {
            if isSearching {
                Text("Search results", bundle: .module)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                countCapsule(totalCount)
            } else if let group {
                Text(group.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)
                if group.status.isConnected || group.status == .none {
                    countCapsule(group.models.count)
                }
                statusLabel(for: group)
            } else {
                Text("Models", bundle: .module)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.primaryText)
            }

            Spacer(minLength: 4)

            if let group, !isSearching {
                headerActions(for: group)
            }

            if !isSearching, let group, group.isProviderBacked || group.isLocal || group.isFavorites {
                sortButton(for: group)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
    }

    private func countCapsule(_ count: Int) -> some View {
        Text("\(count)")
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(theme.secondaryText)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(theme.secondaryBackground))
    }

    @ViewBuilder
    private func statusLabel(for group: ModelPickerGroup) -> some View {
        switch group.status {
        case .none, .connected:
            EmptyView()
        case .connecting:
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text("Connecting…", bundle: .module)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
            }
        case .disconnected:
            HStack(spacing: 5) {
                Circle().fill(Color.red.opacity(0.85)).frame(width: 6, height: 6)
                Text("Not connected", bundle: .module)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
            }
        case .needsSignIn:
            HStack(spacing: 5) {
                Circle().fill(Color.orange).frame(width: 6, height: 6)
                Text("Sign in required", bundle: .module)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
            }
        }
    }

    @ViewBuilder
    private func headerActions(for group: ModelPickerGroup) -> some View {
        if let providerId = group.providerId, group.isProviderBacked {
            switch group.status {
            case .disconnected:
                headerPillButton(
                    icon: reconnectingProviderIds.contains(providerId) ? nil : "arrow.clockwise",
                    title: Text("Reconnect", bundle: .module),
                    isBusy: reconnectingProviderIds.contains(providerId)
                ) {
                    reconnect(providerId: providerId)
                }
            case .needsSignIn:
                headerPillButton(icon: "person.crop.circle.badge.checkmark", title: Text("Sign in", bundle: .module)) {
                    openManagement(tab: .providers)
                }
            case .none, .connected, .connecting:
                EmptyView()
            }
            headerIconButton(icon: "slider.horizontal.3", help: Text("Manage providers", bundle: .module)) {
                openManagement(tab: .providers)
            }
        } else if group.isLocal {
            headerPillButton(icon: "plus", title: Text("Add Model", bundle: .module)) {
                openManagement(tab: .models)
            }
        } else if group.isFavorites, !group.models.isEmpty {
            Text("⌘D toggles a favorite", bundle: .module)
                .font(.system(size: 10.5))
                .foregroundColor(theme.tertiaryText)
        }
    }

    private func headerPillButton(
        icon: String?,
        title: Text,
        isBusy: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if isBusy {
                    ProgressView().controlSize(.mini)
                } else if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .bold))
                }
                title
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(theme.accentColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .strokeBorder(theme.accentColor.opacity(0.3), lineWidth: 1)
                    .background(Capsule().fill(theme.accentColor.opacity(0.08)))
            )
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .pointingHandCursor()
    }

    private func headerIconButton(icon: String, help: Text, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(theme.secondaryText)
                .frame(width: 22, height: 22)
                .background(
                    Circle()
                        .strokeBorder(theme.primaryBorder.opacity(0.3), lineWidth: 1)
                        .background(Circle().fill(theme.secondaryBackground.opacity(0.6)))
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .pointingHandCursor()
    }

    private func openManagement(tab: ManagementTab) {
        onDismiss()
        Task { @MainActor in
            try? await Task.sleepForPopoverDismiss()
            AppDelegate.shared?.showManagementWindow(initialTab: tab)
        }
    }

    private func reconnect(providerId: UUID) {
        guard !reconnectingProviderIds.contains(providerId) else { return }
        reconnectingProviderIds.insert(providerId)
        Task { @MainActor in
            defer { reconnectingProviderIds.remove(providerId) }
            try? await RemoteProviderManager.shared.reconnect(providerId: providerId)
            await ModelPickerItemCache.shared.buildModelPickerItems()
        }
    }

    // MARK: - Add Provider

    private func beginAddProvider() {
        if onAddProvider != nil {
            isAddingProvider = true
            if isSearching { searchText = "" }
        } else {
            openManagement(tab: .providers)
        }
    }

    private func chooseProvider(_ choice: ModelPickerAddProviderChoice) {
        guard let onAddProvider else {
            openManagement(tab: .providers)
            return
        }
        isAddingProvider = false
        onAddProvider(choice)
    }

    // MARK: - Sort Menu

    private func sortButton(for group: ModelPickerGroup) -> some View {
        Button(action: { showSortPopover.toggle() }) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(isSortOrFilterActive ? theme.accentColor : theme.secondaryText)
                .frame(width: 22, height: 22)
                .background(
                    Circle()
                        .strokeBorder(
                            isSortOrFilterActive ? theme.accentColor.opacity(0.3) : theme.primaryBorder.opacity(0.3),
                            lineWidth: 1
                        )
                        .background(
                            Circle().fill(
                                isSortOrFilterActive
                                    ? theme.accentColor.opacity(0.14)
                                    : theme.secondaryBackground.opacity(0.6)
                            )
                        )
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(Text("Sort and filter", bundle: .module))
        .pointingHandCursor()
        .popover(isPresented: $showSortPopover, arrowEdge: .bottom) {
            sortPopoverView(for: group)
        }
    }

    /// Whether any non-default sort/filter is applied, used to highlight the
    /// circular control so the user can tell at a glance the list is modified.
    private var isSortOrFilterActive: Bool {
        sortOrder != .default || contextFilter != .any || visionFilter != .any
            || toolsFilter != .any || localSourceFilter != .any
    }

    /// Chip choices for the On this Mac source filter: the two fixed cases
    /// plus one chip per external provenance actually present, so the row
    /// never offers a filter that would match nothing.
    private func localSourceOptions(for group: ModelPickerGroup) -> [ModelPickerLocalSourceFilter] {
        [.any, .osaurus] + group.models.distinctExternalSources.map { .external($0) }
    }

    private func sortPopoverView(for group: ModelPickerGroup) -> some View {
        // Sections adapt to what the group's models actually publish: the
        // price sort only where any model carries a price, the source filter
        // only where external local models are co-mingled. Context, vision,
        // and tools filters are offered everywhere (they drop unknowns).
        VStack(alignment: .leading, spacing: 4) {
            if group.isLocal, !group.models.distinctExternalSources.isEmpty {
                sortSectionHeader(Text("Source", bundle: .module))

                FlowLayout(spacing: 8) {
                    ForEach(localSourceOptions(for: group)) { option in
                        FilterChip(label: option.label, isSelected: localSourceFilter == option) {
                            localSourceFilter = option
                        }
                    }
                }
                .padding(.horizontal, 12)
            }

            if group.hasPricing {
                sortSectionHeader(Text("Sort by price", bundle: .module))

                sortRow(.default, Text("Default", bundle: .module), icon: "list.bullet")
                sortRow(.priceLowToHigh, Text("Cheapest first", bundle: .module), icon: "arrow.up")
                sortRow(.priceHighToLow, Text("Highest first", bundle: .module), icon: "arrow.down")
            }

            sortSectionHeader(Text("Context limit", bundle: .module))

            FlowLayout(spacing: 8) {
                ForEach(ModelPickerContextFilter.allCases) { option in
                    FilterChip(label: option.label, isSelected: contextFilter == option) {
                        contextFilter = option
                    }
                }
            }
            .padding(.horizontal, 12)

            sortSectionHeader(Text("Capabilities", bundle: .module))

            FlowLayout(spacing: 8) {
                ForEach(ModelPickerVisionFilter.allCases) { option in
                    FilterChip(label: option.label, isSelected: visionFilter == option) {
                        visionFilter = option
                    }
                }
                FilterChip(label: ModelPickerToolsFilter.toolsOnly.label, isSelected: toolsFilter == .toolsOnly) {
                    toolsFilter = toolsFilter == .toolsOnly ? .any : .toolsOnly
                }
            }
            .padding(.horizontal, 12)

            if isSortOrFilterActive {
                Button(action: resetSortAndFilters) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 9))
                        Text("Reset filters", bundle: .module)
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(theme.secondaryText)
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .padding(.horizontal, 12)
                .padding(.top, 10)
            }
        }
        .padding(.bottom, 12)
        .frame(width: 250)
        .background(theme.primaryBackground)
        .environment(\.theme, theme)
    }

    private func resetSortAndFilters() {
        sortOrder = .default
        contextFilter = .any
        visionFilter = .any
        toolsFilter = .any
        localSourceFilter = .any
    }

    private func sortSectionHeader(_ text: Text) -> some View {
        text
            .font(.system(size: 10, weight: .bold))
            .tracking(0.6)
            .foregroundColor(theme.tertiaryText)
            .textCase(.uppercase)
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 6)
    }

    private func sortRow(_ order: ModelPickerSortOrder, _ title: Text, icon: String) -> some View {
        SortOptionRow(icon: icon, title: title, isSelected: sortOrder == order) {
            sortOrder = order
            showSortPopover = false
        }
    }

    private struct SortOptionRow: View {
        let icon: String
        let title: Text
        let isSelected: Bool
        let action: () -> Void
        @Environment(\.theme) private var theme
        @State private var isHovering = false

        var body: some View {
            Button(action: action) {
                HStack(spacing: 10) {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 16)
                        .foregroundColor(isSelected ? theme.accentColor : theme.secondaryText)
                    title
                        .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                        .foregroundColor(isSelected ? theme.accentColor : theme.primaryText)
                    Spacer(minLength: 0)
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(theme.accentColor)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(
                            isSelected
                                ? theme.accentColor.opacity(0.12)
                                : (isHovering
                                    ? theme.tertiaryBackground.opacity(0.7)
                                    : Color.clear)
                        )
                )
                .padding(.horizontal, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.12)) {
                    isHovering = hovering
                }
            }
        }
    }

    private struct FilterChip: View {
        let label: String
        let isSelected: Bool
        let action: () -> Void
        @Environment(\.theme) private var theme
        @State private var isHovering = false

        var body: some View {
            Button(action: action) {
                HStack(spacing: 4) {
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                    }
                    Text(label)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(
                            isSelected
                                ? theme.accentColor.opacity(0.15)
                                : (isHovering
                                    ? theme.tertiaryBackground.opacity(0.7)
                                    : theme.tertiaryBackground.opacity(0.4))
                        )
                )
                .foregroundColor(isSelected ? theme.accentColor : theme.secondaryText)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(
                            isSelected
                                ? theme.accentColor.opacity(0.45)
                                : theme.primaryBorder.opacity(0.1),
                            lineWidth: 1
                        )
                )
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.12)) {
                    isHovering = hovering
                }
            }
        }
    }

    // MARK: - Search Field

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundColor(theme.secondaryText)

            ZStack(alignment: .leading) {
                if searchText.isEmpty && !isSearchComposing {
                    Text("Search all models…", bundle: .module)
                        .font(.system(size: 13))
                        .foregroundColor(theme.secondaryText)
                        .allowsHitTesting(false)
                }
                IMEAwareTextField(
                    text: $searchText,
                    isComposing: $isSearchComposing,
                    font: .systemFont(ofSize: 13),
                    textColor: NSColor(theme.primaryText)
                )
                .frame(height: 17)
            }

            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(theme.tertiaryText)
                }
                .buttonStyle(.plain)
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            } else {
                keyboardHints
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(theme.secondaryBackground.opacity(theme.isDark ? 0.4 : 0.5))
        .animation(.easeOut(duration: 0.15), value: searchText.isEmpty)
    }

    /// Discoverability for the keyboard model: arrows move, Return selects,
    /// ⌘D stars the highlighted model.
    private var keyboardHints: some View {
        HStack(spacing: 8) {
            keyHint("↑↓", Text("move", bundle: .module))
            keyHint("↵", Text("select", bundle: .module))
            keyHint("⌘D", Text("★", bundle: .module))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func keyHint(_ key: String, _ label: Text) -> some View {
        HStack(spacing: 3) {
            Text(key)
                .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                .foregroundColor(theme.tertiaryText)
                .padding(.horizontal, 4)
                .padding(.vertical, 1.5)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(theme.primaryBorder.opacity(0.35), lineWidth: 1)
                )
            label
                .font(.system(size: 9.5))
                .foregroundColor(theme.tertiaryText)
        }
    }

    // MARK: - Deprecation Banner

    private func deprecationBanner(replacement: String) -> some View {
        Button(action: { openManagement(tab: .models) }) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.orange)

                Text("Selected model is outdated.", bundle: .module)
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)

                Spacer()

                Text("Update", bundle: .module)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.accentColor)

                Image(systemName: "arrow.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(theme.accentColor)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.orange.opacity(0.08))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Empty State

    @ViewBuilder
    private func emptyState(for group: ModelPickerGroup?) -> some View {
        VStack(spacing: 10) {
            if isSearching {
                emptyIcon("magnifyingglass")
                Text("No models found", bundle: .module)
                    .font(.system(size: 13))
                    .foregroundColor(theme.secondaryText)
            } else if let group, group.isFavorites {
                emptyIcon("star")
                Text("No favorites yet", bundle: .module)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(theme.secondaryText)
                Text("Hover a model and click ☆, or press ⌘D, to pin it here.", bundle: .module)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
                    .multilineTextAlignment(.center)
            } else if let group, let providerId = group.providerId, group.isProviderBacked {
                switch group.status {
                case .disconnected(let message):
                    emptyIcon("bolt.slash")
                    Text("Not connected", bundle: .module)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                    if let message, !message.isEmpty {
                        Text(message)
                            .font(.system(size: 11))
                            .foregroundColor(theme.tertiaryText)
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                            .padding(.horizontal, 24)
                    }
                    headerPillButton(
                        icon: reconnectingProviderIds.contains(providerId) ? nil : "arrow.clockwise",
                        title: Text("Reconnect", bundle: .module),
                        isBusy: reconnectingProviderIds.contains(providerId)
                    ) {
                        reconnect(providerId: providerId)
                    }
                    .padding(.top, 4)
                case .needsSignIn:
                    emptyIcon("person.crop.circle.badge.exclamationmark")
                    Text("Sign in required", bundle: .module)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                    headerPillButton(icon: "person.crop.circle.badge.checkmark", title: Text("Sign in", bundle: .module)) {
                        openManagement(tab: .providers)
                    }
                    .padding(.top, 4)
                case .connecting:
                    ProgressView().controlSize(.small)
                    Text("Connecting…", bundle: .module)
                        .font(.system(size: 12))
                        .foregroundColor(theme.tertiaryText)
                case .none, .connected:
                    emptyIcon("tray")
                    Text(isSortOrFilterActive ? "No models match the filters" : "No models available", bundle: .module)
                        .font(.system(size: 13))
                        .foregroundColor(theme.secondaryText)
                    if isSortOrFilterActive {
                        Button(action: resetSortAndFilters) {
                            Text("Reset filters", bundle: .module)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(theme.accentColor)
                        }
                        .buttonStyle(.plain)
                        .pointingHandCursor()
                    }
                }
            } else {
                emptyIcon("tray")
                Text(isSortOrFilterActive ? "No models match the filters" : "No models available", bundle: .module)
                    .font(.system(size: 13))
                    .foregroundColor(theme.secondaryText)
                if isSortOrFilterActive {
                    Button(action: resetSortAndFilters) {
                        Text("Reset filters", bundle: .module)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(theme.accentColor)
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func emptyIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 24))
            .foregroundColor(theme.tertiaryText)
    }

    // MARK: - Model List

    private func modelList(rows: [ModelPickerRow], isFavoritesGroup: Bool) -> some View {
        let optionsContent: AnyView? = optionsControl.flatMap { control in
            control.isEmpty
                ? nil
                : AnyView(ModelPickerOptionsRows(control: control).environment(\.theme, theme))
        }
        return ModelPickerTableRepresentable(
            rows: rows,
            theme: theme,
            selectedModelId: selectedModel,
            isFavoritesGroup: isFavoritesGroup,
            optionsContent: optionsContent,
            optionsLayoutKey: optionsControl?.layoutKey ?? "",
            optionsEstimatedHeight: optionsControl?.estimatedHeight(availableWidth: Self.listPaneWidth - 36) ?? 0,
            onSelectModel: { modelId in
                selectedModel = modelId
                onDismiss()
            },
            // nil while searching so left/right arrows stay with the
            // search field's text cursor instead of switching groups
            onSwitchGroup: isSearching ? nil : { offset in switchGroup(by: offset) },
            onToggleFavorite: { row in
                favoritesStore.toggle(row.favoriteKey)
            },
            onDismiss: onDismiss
        )
    }
}

// MARK: - Host Window Width

/// Zero-size helper that reports the width of the window hosting the picker
/// popover — the popover window's parent — whenever the view lands in a
/// window or that window is resized, so the sidebar can collapse to its icon
/// rail on narrow chat windows.
private struct ModelPickerHostWindowWidthReader: NSViewRepresentable {
    let onWidth: (CGFloat) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onWidth = onWidth
        return view
    }

    func updateNSView(_ nsView: ReaderView, context: Context) {
        nsView.onWidth = onWidth
    }

    final class ReaderView: NSView {
        var onWidth: ((CGFloat) -> Void)?
        private var observedWindow: NSWindow?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // The popover window is parented to the host only after its
            // content is installed, so resolve on the next turn of the run
            // loop (which also keeps the state write out of the view update).
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                self.observe(window.parent ?? window)
                self.report()
            }
        }

        private func observe(_ host: NSWindow?) {
            guard host !== observedWindow else { return }
            if let observedWindow {
                NotificationCenter.default.removeObserver(
                    self, name: NSWindow.didResizeNotification, object: observedWindow)
            }
            observedWindow = host
            if let host {
                NotificationCenter.default.addObserver(
                    self, selector: #selector(hostDidResize), name: NSWindow.didResizeNotification, object: host)
            }
        }

        @objc private func hostDidResize() { report() }

        private func report() {
            guard let host = observedWindow else { return }
            onWidth?(host.frame.width)
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }
}

// MARK: - Preview

#if DEBUG
    struct ModelPickerView_Previews: PreviewProvider {
        struct PreviewWrapper: View {
            @State private var selected: String? = "foundation"
            @State private var useMockData = true

            var body: some View {
                VStack(spacing: 0) {
                    // toggle for mock data
                    HStack {
                        Toggle(isOn: $useMockData) {
                            Text(
                                mockModels.count == 1
                                    ? L("Use Mock Data (1 model)")
                                    : L("Use Mock Data (\(mockModels.count) models)")
                            )
                        }
                        .padding()
                        Spacer()
                    }
                    .background(Color.gray.opacity(0.1))

                    ModelPickerView(
                        options: useMockData ? mockModels : smallSampleModels,
                        selectedModel: $selected,
                        agentId: nil,
                        onDismiss: {}
                    )
                    .padding()
                }
                .frame(width: 700, height: 600)
                .background(Color.gray.opacity(0.2))
            }

            // large mock dataset for performance testing
            private var mockModels: [ModelPickerItem] {
                ModelPickerItem.generateMockModels(count: 500)
            }

            // small sample for quick testing — multiple providers so the
            // sidebar and unified search attribution are exercised
            private var smallSampleModels: [ModelPickerItem] {
                let openAIId = UUID()
                let anthropicId = UUID()
                return [
                    .foundation(),
                    ModelPickerItem(
                        id: "mlx-community/Llama-3.2-3B-Instruct-4bit",
                        displayName: "Llama 3.2 3B Instruct 4bit",
                        source: .local,
                        parameterCount: "3B",
                        quantization: "4-bit",
                        isVLM: false
                    ),
                    ModelPickerItem(
                        id: "mlx-community/Qwen2-VL-7B-Instruct-4bit",
                        displayName: "Qwen2 VL 7B Instruct 4bit",
                        source: .local,
                        parameterCount: "7B",
                        quantization: "4-bit",
                        isVLM: true
                    ),
                    ModelPickerItem(
                        id: "openai/gpt-4o",
                        displayName: "gpt-4o",
                        source: .remote(providerName: "OpenAI", providerId: openAIId),
                        contextLength: 128_000,
                        supportsToolCalling: true
                    ),
                    ModelPickerItem(
                        id: "openai/gpt-3.5-turbo",
                        displayName: "gpt-3.5-turbo",
                        source: .remote(providerName: "OpenAI", providerId: openAIId),
                        isDeprecated: true
                    ),
                    ModelPickerItem(
                        id: "anthropic/claude-opus-4",
                        displayName: "Claude Opus 4",
                        source: .remote(providerName: "Anthropic", providerId: anthropicId),
                        inputPriceMicroPerMTok: 15_000_000,
                        outputPriceMicroPerMTok: 75_000_000,
                        contextLength: 200_000,
                        supportsToolCalling: true,
                        supportsReasoning: true,
                        recommendedReason: "Vendor default"
                    ),
                ]
            }
        }

        /// Standalone picker with a Thinking-capable options section, for
        /// visually validating the inline Model Options expansion (Thinking
        /// row and segmented effort row) under the selected model. An
        /// explicit override toggles the Default pill and reset affordance
        /// like the live picker.
        struct ThinkingPreviewWrapper: View {
            @State private var selected: String? = "qwen3.5-35b-a3b-4bit"
            @State private var thinkingOverride: Bool? = nil
            @State private var effortOverride: String? = nil

            private var thinkingOptionsControl: ModelPickerOptionsControl {
                ModelPickerOptionsControl(
                    capabilities: nil,
                    thinking: ModelPickerThinkingControl(
                        isEnabled: thinkingOverride ?? true,
                        isExplicit: thinkingOverride != nil,
                        onSetEnabled: { thinkingOverride = $0 }
                    ),
                    options: [
                        ModelOptionDefinition(
                            id: "reasoningEffort",
                            label: L("Reasoning Effort"),
                            icon: "brain",
                            kind: .segmented([
                                ModelOptionSegment(id: "low", label: L("Low")),
                                ModelOptionSegment(id: "medium", label: L("Medium")),
                                ModelOptionSegment(id: "high", label: L("High")),
                            ])
                        )
                    ],
                    values: effortOverride.map { ["reasoningEffort": .string($0)] } ?? [:],
                    defaults: ["reasoningEffort": .string("medium")],
                    onChange: { _, newValue in
                        effortOverride = newValue?.stringValue
                    }
                )
            }

            var body: some View {
                ModelPickerView(
                    options: [
                        ModelPickerItem(
                            id: "qwen3.5-35b-a3b-4bit",
                            displayName: "Qwen3.5 35B A3B 4bit",
                            source: .local,
                            parameterCount: "35B",
                            quantization: "4-bit",
                            isVLM: false
                        )
                    ],
                    selectedModel: $selected,
                    agentId: nil,
                    optionsControl: thinkingOptionsControl,
                    onDismiss: {}
                )
                .padding()
                .frame(width: 700, height: 620)
                .background(Color.gray.opacity(0.2))
            }
        }

        static var previews: some View {
            PreviewWrapper()
                .previewDisplayName("Model list")
            ThinkingPreviewWrapper()
                .previewDisplayName("Thinking-capable options")
        }
    }
#endif
