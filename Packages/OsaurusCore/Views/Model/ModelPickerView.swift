//
//  ModelPickerView.swift
//  osaurus
//
//  A rich model picker with provider tabs, unified cross-provider search,
//  and metadata display.
//

import SwiftUI

struct ModelPickerView: View {
    let options: [ModelPickerItem]
    @Binding var selectedModel: String?
    let agentId: UUID?
    let onDismiss: () -> Void

    @State private var searchText = ""
    @State private var selectedTabKey: String?
    @State private var sortOrder: ModelPickerSortOrder = .default
    @State private var contextFilter: ModelPickerContextFilter = .any
    @State private var visionFilter: ModelPickerVisionFilter = .any
    @State private var showSortPopover = false
    @ObservedObject private var favoritesStore = FavoriteModelsStore.shared
    @Environment(\.theme) private var theme

    /// Stable key/title for the synthetic Favourites tab. It only exists while
    /// the user has at least one favourite among the currently visible models.
    private static let favoritesTabKey = "favorites"
    private static let favoritesTabTitle = "Favourites"

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
    /// Filtering before grouping keeps the header count, tab badges, and rows
    /// all consistent.
    private var visibleOptions: [ModelPickerItem] {
        displayOptions.filter { $0.isMLXFormat }
    }

    /// Visible models the user has favourited, in the order they were added.
    /// Favourites whose model isn't currently available (provider offline,
    /// deleted on disk) simply don't appear until the model returns.
    private var favoriteItems: [ModelPickerItem] {
        guard !favoritesStore.favoriteKeys.isEmpty else { return [] }
        let byKey = Dictionary(
            visibleOptions.map { ($0.favoriteKey, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return favoritesStore.favoriteKeys.compactMap { byKey[$0] }
    }

    private var currentTabs: [ModelPickerTab] {
        let base = visibleOptions.groupedByTab()
        let favorites = favoriteItems
        guard !favorites.isEmpty else { return base }
        // Pin the Favourites tab first so a few preferred models are always the
        // shortest path, ahead of the provider tabs.
        let favoritesTab = ModelPickerTab(
            key: Self.favoritesTabKey,
            title: Self.favoritesTabTitle,
            models: favorites
        )
        return [favoritesTab] + base
    }

    /// Provider attribution shown on Favourites-tab rows, since favourites mix
    /// models from every source into one list.
    private func providerTitle(for item: ModelPickerItem) -> String {
        switch item.source {
        case .foundation, .local, .imageGeneration:
            return "Local"
        case .remote(let providerName, _):
            return providerName
        }
    }

    /// The tab to fall back to when there is no valid explicit selection: the
    /// one holding `selectedModel`, otherwise the first tab.
    private static func defaultTabKey(in tabs: [ModelPickerTab], selectedModel: String?) -> String? {
        let modelTab = tabs.first { tab in tab.models.contains { $0.id == selectedModel } }
        return modelTab?.key ?? tabs.first?.key
    }

    /// The tab to render as active: the explicit selection while its tab still
    /// exists, otherwise the derived default. A selection whose tab is
    /// transiently absent mid-refresh falls back here for rendering only.
    private func effectiveSelectedTabKey(in tabs: [ModelPickerTab]) -> String? {
        if let key = selectedTabKey, tabs.contains(where: { $0.key == key }) {
            return key
        }
        return Self.defaultTabKey(in: tabs, selectedModel: selectedModel)
    }

    /// Resolve which tab key should be *committed to `selectedTabKey`*, given the
    /// currently committed key and the available tabs.
    ///
    /// Once a key is committed it is returned untouched — even if that tab is
    /// momentarily absent. The picker refreshes its model lists asynchronously
    /// while open (`refreshConnectedProviders` / `buildModelPickerItems`), so a
    /// tab can briefly disappear mid-refresh; clobbering the user's explicit
    /// choice on that transient absence is what made the picker snap from
    /// "Local" back to the first tab ("Osaurus"). Rendering still falls back
    /// gracefully via `effectiveSelectedTabKey` while a tab is missing, and the
    /// committed key re-resolves the moment it returns.
    ///
    /// With no committed key it derives the initial default via `defaultTabKey`.
    static func resolveCommittedTabKey(
        current: String?,
        tabs: [ModelPickerTab],
        selectedModel: String?
    ) -> String? {
        current ?? defaultTabKey(in: tabs, selectedModel: selectedModel)
    }

    private func ensureSelectedTabValid() {
        let resolved = Self.resolveCommittedTabKey(
            current: selectedTabKey,
            tabs: currentTabs,
            selectedModel: selectedModel
        )
        if selectedTabKey != resolved { selectedTabKey = resolved }
    }

    private func row(for model: ModelPickerItem, providerLabel: String? = nil) -> ModelPickerRow {
        ModelPickerRow(
            modelId: model.id,
            sourceKey: model.source.uniqueKey,
            displayName: model.displayName,
            description: model.description,
            parameterCount: model.parameterCount,
            quantization: model.quantization,
            isVLM: model.isVLM,
            isMLXFormat: model.isMLXFormat,
            providerLabel: providerLabel,
            isFavorite: favoritesStore.isFavorite(model.favoriteKey)
        )
    }

    private func makeRows(for tab: ModelPickerTab, providerLabel: String? = nil) -> [ModelPickerRow] {
        var rows: [ModelPickerRow] = []
        rows.reserveCapacity(tab.models.count)
        for model in tab.models {
            rows.append(row(for: model, providerLabel: providerLabel))
        }
        return rows
    }

    private func visibleRows(in tabs: [ModelPickerTab]) -> [ModelPickerRow] {
        guard isSearching else {
            guard let key = effectiveSelectedTabKey(in: tabs),
                let tab = tabs.first(where: { $0.key == key })
            else { return [] }
            // The Favourites tab mixes models from every source, so each row
            // carries its provider label to stay distinguishable.
            if tab.key == Self.favoritesTabKey {
                return tab.models.map { row(for: $0, providerLabel: providerTitle(for: $0)) }
            }
            // Context filtering and price sorting only apply to the Osaurus
            // tab, whose models carry context/pricing metadata; other tabs keep
            // their existing alphabetical order. Both steps are no-ops at their
            // default (`.any` / `.default`), so the pipeline is safe to always
            // run for Osaurus.
            guard tab.isOsaurus else { return makeRows(for: tab) }
            let processed = tab.models
                .filteredByContext(contextFilter)
                .filteredByVision(visionFilter)
                .sortedByPrice(sortOrder)
            return makeRows(for: ModelPickerTab(key: tab.key, title: tab.title, models: processed))
        }

        return searchRows(in: tabs)
    }

    private func searchRows(in tabs: [ModelPickerTab]) -> [ModelPickerRow] {
        // Unified search: one pass across every tab's models with the query
        // prepared once. Each row carries its provider title so identical
        // model IDs offered by different providers stay distinguishable.
        let prepared = SearchService.PreparedQuery(searchText)
        var rows: [ModelPickerRow] = []
        rows.reserveCapacity(64)

        for tab in tabs {
            for model in tab.models {
                guard
                    SearchService.matches(prepared, in: model.displayName)
                        || SearchService.matches(prepared, in: model.id)
                else { continue }
                rows.append(row(for: model, providerLabel: tab.title))
            }
        }
        return rows
    }

    private func switchTab(by offset: Int) {
        let tabs = currentTabs
        guard !tabs.isEmpty else { return }
        let activeKey = effectiveSelectedTabKey(in: tabs)
        let currentIndex = tabs.firstIndex(where: { $0.key == activeKey }) ?? 0
        let newIndex = max(0, min(tabs.count - 1, currentIndex + offset))
        guard tabs[newIndex].key != activeKey else { return }
        selectedTabKey = tabs[newIndex].key
    }

    // MARK: - Body

    private var selectedModelReplacement: String? {
        guard let id = selectedModel else { return nil }
        return ModelManager.replacementForDeprecatedModel(id)
    }

    var body: some View {
        let tabs = currentTabs
        let rows = visibleRows(in: tabs)
        // The sort control is offered only on the Osaurus tab (the only tab
        // with pricing) and not while the cross-provider search is active.
        let activeTab = tabs.first { $0.key == effectiveSelectedTabKey(in: tabs) }
        let showSort = !isSearching && (activeTab?.isOsaurus ?? false)
        VStack(spacing: 0) {
            header(showSort: showSort)
            Divider().background(theme.primaryBorder.opacity(0.3))
            searchField
            Divider().background(theme.primaryBorder.opacity(0.3))

            if !isSearching, tabs.count > 1 {
                tabBar(tabs: tabs)
                Divider().background(theme.primaryBorder.opacity(0.3))
            }

            if let replacement = selectedModelReplacement {
                deprecationBanner(replacement: replacement)
            }

            if rows.isEmpty {
                emptyState
            } else {
                // Favourites-mode (trash control) only while the Favourites tab
                // is the active, non-search view.
                modelList(
                    rows: rows,
                    isFavoritesTab: !isSearching && activeTab?.key == Self.favoritesTabKey
                )
            }
        }
        .frame(width: 380, height: min(CGFloat(visibleOptions.count * 48 + 160), 480))
        .background(popoverBackground)
        .overlay(popoverBorder)
        .shadow(color: theme.shadowColor.opacity(0.15), radius: 12, x: 0, y: 6)
        .onAppear {
            ensureSelectedTabValid()
        }
        .task {
            // refresh remote model lists on open so newly-added/removed
            // models surface
            await RemoteProviderManager.shared.refreshConnectedProviders()
            await ModelPickerItemCache.shared.buildModelPickerItems()
            ensureSelectedTabValid()

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
            ensureSelectedTabValid()
        }
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

    // MARK: - Header

    @ViewBuilder
    private func header(showSort: Bool) -> some View {
        HStack(spacing: 8) {
            Text("Available Models", bundle: .module)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.primaryText)

            Text("\(visibleOptions.count)", bundle: .module)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.secondaryText)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(theme.secondaryBackground))

            Spacer()

            if showSort {
                sortButton
            }

            Button(action: {
                onDismiss()
                Task { @MainActor in
                    try? await Task.sleepForPopoverDismiss()
                    AppDelegate.shared?.showManagementWindow(initialTab: .models)
                }
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .bold))
                    Text("Add Model", bundle: .module)
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
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: - Sort Menu

    private var sortButton: some View {
        Button(action: { showSortPopover.toggle() }) {
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(theme.accentColor)
                .frame(width: 22, height: 22)
                .background(
                    Circle()
                        .strokeBorder(theme.accentColor.opacity(0.3), lineWidth: 1)
                        .background(
                            Circle().fill(theme.accentColor.opacity(isSortOrFilterActive ? 0.18 : 0.08))
                        )
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(Text("Sort and filter", bundle: .module))
        .popover(isPresented: $showSortPopover, arrowEdge: .bottom) {
            sortPopoverView
        }
    }

    /// Whether any non-default sort/filter is applied, used to highlight the
    /// circular control so the user can tell at a glance the list is modified.
    private var isSortOrFilterActive: Bool {
        sortOrder != .default || contextFilter != .any || visionFilter != .any
    }

    private var sortPopoverView: some View {
        VStack(alignment: .leading, spacing: 4) {
            sortSectionHeader(Text("Sort by price", bundle: .module))

            sortRow(.default, Text("Default", bundle: .module), icon: "list.bullet")
            sortRow(.priceLowToHigh, Text("Cheapest first", bundle: .module), icon: "arrow.up")
            sortRow(.priceHighToLow, Text("Highest first", bundle: .module), icon: "arrow.down")

            sortSectionHeader(Text("Context limit", bundle: .module))

            FlowLayout(spacing: 8) {
                ForEach(ModelPickerContextFilter.allCases) { option in
                    FilterChip(label: option.label, isSelected: contextFilter == option) {
                        contextFilter = option
                    }
                }
            }
            .padding(.horizontal, 12)

            sortSectionHeader(Text("Vision", bundle: .module))

            FlowLayout(spacing: 8) {
                ForEach(ModelPickerVisionFilter.allCases) { option in
                    FilterChip(label: option.label, isSelected: visionFilter == option) {
                        visionFilter = option
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .frame(width: 240)
        .background(theme.primaryBackground)
        .environment(\.theme, theme)
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
                if searchText.isEmpty {
                    Text("Search models...", bundle: .module)
                        .font(.system(size: 13))
                        .foregroundColor(theme.secondaryText)
                        .allowsHitTesting(false)
                }
                TextField("", text: $searchText)
                    .textFieldStyle(.plain)
                    .focusEffectDisabled()
                    .font(.system(size: 13))
                    .foregroundColor(theme.primaryText)
            }

            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(theme.tertiaryText)
                }
                .buttonStyle(.plain)
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(theme.secondaryBackground.opacity(theme.isDark ? 0.4 : 0.5))
        .animation(.easeOut(duration: 0.15), value: searchText.isEmpty)
    }

    // MARK: - Tab Bar

    @ViewBuilder
    private func tabBar(tabs: [ModelPickerTab]) -> some View {
        let activeKey = effectiveSelectedTabKey(in: tabs)
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(tabs) { tab in
                        tabChip(for: tab, activeKey: activeKey)
                            .id(tab.key)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .onAppear {
                if let key = activeKey {
                    proxy.scrollTo(key, anchor: .center)
                }
            }
            .onChange(of: selectedTabKey) { _, newKey in
                guard let newKey else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(newKey, anchor: .center)
                }
            }
        }
    }

    private func tabChip(for tab: ModelPickerTab, activeKey: String?) -> some View {
        let isActive = tab.key == activeKey
        let isFavorites = tab.key == Self.favoritesTabKey
        return Button(action: { selectedTabKey = tab.key }) {
            HStack(spacing: 5) {
                if isFavorites {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(isActive ? theme.accentColor : theme.secondaryText)
                }

                Group {
                    // The Favourites tab has a fixed, translatable title; every
                    // other tab shows a provider name rendered verbatim.
                    if isFavorites {
                        Text("Favourites", bundle: .module)
                    } else {
                        Text(tab.title)
                    }
                }
                .font(.system(size: 11, weight: isActive ? .semibold : .medium))
                .foregroundColor(isActive ? theme.accentColor : theme.secondaryText)

                Text("\(tab.models.count)")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(isActive ? theme.accentColor.opacity(0.9) : theme.tertiaryText)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        Capsule().fill(
                            isActive
                                ? theme.accentColor.opacity(0.12)
                                : theme.secondaryBackground
                        )
                    )
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .strokeBorder(
                        isActive ? theme.accentColor.opacity(0.35) : theme.primaryBorder.opacity(0.25),
                        lineWidth: 1
                    )
                    .background(
                        Capsule().fill(
                            isActive
                                ? theme.accentColor.opacity(0.08)
                                : theme.secondaryBackground.opacity(theme.isDark ? 0.4 : 0.5)
                        )
                    )
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Deprecation Banner

    private func deprecationBanner(replacement: String) -> some View {
        Button(action: {
            onDismiss()
            Task { @MainActor in
                try? await Task.sleepForPopoverDismiss()
                AppDelegate.shared?.showManagementWindow(initialTab: .models)
            }
        }) {
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

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 24))
                .foregroundColor(theme.tertiaryText)
            Text("No models found", bundle: .module)
                .font(.system(size: 13))
                .foregroundColor(theme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Model List

    private func modelList(rows: [ModelPickerRow], isFavoritesTab: Bool) -> some View {
        ModelPickerTableRepresentable(
            rows: rows,
            theme: theme,
            selectedModelId: selectedModel,
            isFavoritesTab: isFavoritesTab,
            onSelectModel: { modelId in
                selectedModel = modelId
                onDismiss()
            },
            // nil while searching so left/right arrows stay with the
            // search field's text cursor instead of switching hidden tabs
            onSwitchTab: isSearching ? nil : { offset in switchTab(by: offset) },
            onToggleFavorite: { row in
                favoritesStore.toggle(row.favoriteKey)
            },
            onDismiss: onDismiss
        )
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
                            Text("Use Mock Data (\(mockModels.count) models)", bundle: .module)
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
                .frame(width: 450, height: 550)
                .background(Color.gray.opacity(0.2))
            }

            // large mock dataset for performance testing
            private var mockModels: [ModelPickerItem] {
                ModelPickerItem.generateMockModels(count: 500)
            }

            // small sample for quick testing — multiple providers so the tab
            // bar and unified search attribution are exercised
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
                        source: .remote(providerName: "OpenAI", providerId: openAIId)
                    ),
                    ModelPickerItem(
                        id: "openai/gpt-3.5-turbo",
                        displayName: "gpt-3.5-turbo",
                        source: .remote(providerName: "OpenAI", providerId: openAIId)
                    ),
                    ModelPickerItem(
                        id: "anthropic/claude-opus-4",
                        displayName: "claude-opus-4",
                        source: .remote(providerName: "Anthropic", providerId: anthropicId)
                    ),
                ]
            }
        }

        static var previews: some View {
            PreviewWrapper()
        }
    }
#endif
