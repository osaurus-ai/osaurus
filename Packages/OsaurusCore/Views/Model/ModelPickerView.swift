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
    @State private var searchDebounceTask: Task<Void, Never>?
    @State private var selectedTabKey: String?
    @State private var cachedTabs: [ModelPickerTab] = []
    @State private var cachedTabRows: [String: [ModelPickerRow]] = [:]
    @State private var cachedFlattenedRows: [ModelPickerRow] = []
    @Environment(\.theme) private var theme

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

    /// Rebuild tabs from options and keep the active tab valid. Called on
    /// appear and whenever the options array changes.
    private func rebuildTabs() {
        cachedTabs = displayOptions.groupedByTab()
        cachedTabRows = [:]

        if let key = selectedTabKey, cachedTabs.contains(where: { $0.key == key }) {
            return
        }
        selectedTabKey = tabKey(containing: selectedModel) ?? cachedTabs.first?.key
    }

    private func tabKey(containing modelId: String?) -> String? {
        guard let modelId else { return nil }
        return cachedTabs.first(where: { tab in tab.models.contains(where: { $0.id == modelId }) })?.key
    }

    /// Rows for a tab, built lazily on first visit and reused until the
    /// options array changes.
    private func rowsForTab(_ tab: ModelPickerTab) -> [ModelPickerRow] {
        if let cached = cachedTabRows[tab.key] { return cached }

        var rows: [ModelPickerRow] = []
        rows.reserveCapacity(tab.models.count)
        for model in tab.models {
            rows.append(
                ModelPickerRow(
                    modelId: model.id,
                    sourceKey: model.source.uniqueKey,
                    displayName: model.displayName,
                    description: model.description,
                    parameterCount: model.parameterCount,
                    quantization: model.quantization,
                    isVLM: model.isVLM
                )
            )
        }
        cachedTabRows[tab.key] = rows
        return rows
    }

    private func recomputeRows() {
        guard isSearching else {
            if let key = selectedTabKey, let tab = cachedTabs.first(where: { $0.key == key }) {
                cachedFlattenedRows = rowsForTab(tab)
            } else {
                cachedFlattenedRows = []
            }
            return
        }

        // Unified search: one pass across every tab's models with the query
        // prepared once. Each row carries its provider title so identical
        // model IDs offered by different providers stay distinguishable.
        let prepared = SearchService.PreparedQuery(searchText)
        var rows: [ModelPickerRow] = []
        rows.reserveCapacity(64)

        for tab in cachedTabs {
            for model in tab.models {
                guard
                    SearchService.matches(prepared, in: model.displayName)
                        || SearchService.matches(prepared, in: model.id)
                else { continue }
                rows.append(
                    ModelPickerRow(
                        modelId: model.id,
                        sourceKey: model.source.uniqueKey,
                        displayName: model.displayName,
                        description: model.description,
                        parameterCount: model.parameterCount,
                        quantization: model.quantization,
                        isVLM: model.isVLM,
                        providerLabel: tab.title
                    )
                )
            }
        }
        cachedFlattenedRows = rows
    }

    private func switchTab(by offset: Int) {
        guard !cachedTabs.isEmpty else { return }
        let currentIndex = cachedTabs.firstIndex(where: { $0.key == selectedTabKey }) ?? 0
        let newIndex = max(0, min(cachedTabs.count - 1, currentIndex + offset))
        guard cachedTabs[newIndex].key != selectedTabKey else { return }
        selectedTabKey = cachedTabs[newIndex].key
    }

    // MARK: - Body

    private var selectedModelReplacement: String? {
        guard let id = selectedModel else { return nil }
        return ModelManager.replacementForDeprecatedModel(id)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(theme.primaryBorder.opacity(0.3))
            searchField
            Divider().background(theme.primaryBorder.opacity(0.3))

            if !isSearching, cachedTabs.count > 1 {
                tabBar
                Divider().background(theme.primaryBorder.opacity(0.3))
            }

            if let replacement = selectedModelReplacement {
                deprecationBanner(replacement: replacement)
            }

            if cachedFlattenedRows.isEmpty {
                emptyState
            } else {
                modelList
            }
        }
        .frame(width: 380, height: min(CGFloat(displayOptions.count * 48 + 160), 480))
        .background(popoverBackground)
        .overlay(popoverBorder)
        .shadow(color: theme.shadowColor.opacity(0.15), radius: 12, x: 0, y: 6)
        .onAppear {
            rebuildTabs()
            recomputeRows()
        }
        .task {
            // refresh remote model lists on open so newly-added/removed
            // models surface
            await RemoteProviderManager.shared.refreshConnectedProviders()

            // Drop external models (HF cache, LM Studio) the user deleted on
            // disk while the app stayed running — the picker cache is built
            // once and only rebuilds on `.localModelsChanged`, which this
            // posts when something went missing. Cheap existence check; no-op
            // when nothing changed. Runs last since it's the lowest priority.
            _ = await Task.detached(priority: .utility) {
                ExternalModelLocator.pruneMissing()
            }.value
        }
        .onDisappear {
            searchDebounceTask?.cancel()
        }
        .onChange(of: displayOptions.count) { _, _ in
            rebuildTabs()
            recomputeRows()
        }
        .onChange(of: searchText) { _, newValue in
            searchDebounceTask?.cancel()
            if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                recomputeRows()
            } else {
                searchDebounceTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(150))
                    guard !Task.isCancelled else { return }
                    recomputeRows()
                }
            }
        }
        .onChange(of: selectedTabKey) { _, _ in
            recomputeRows()
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

    private var header: some View {
        HStack(spacing: 8) {
            Text("Available Models", bundle: .module)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.primaryText)

            Text("\(displayOptions.count)", bundle: .module)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.secondaryText)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(theme.secondaryBackground))

            Spacer()

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

    private var tabBar: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(cachedTabs) { tab in
                        tabChip(for: tab)
                            .id(tab.key)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .onAppear {
                if let key = selectedTabKey {
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

    private func tabChip(for tab: ModelPickerTab) -> some View {
        let isActive = tab.key == selectedTabKey
        return Button(action: { selectedTabKey = tab.key }) {
            HStack(spacing: 5) {
                Text(tab.title)
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

    private var modelList: some View {
        ModelPickerTableRepresentable(
            rows: cachedFlattenedRows,
            theme: theme,
            selectedModelId: selectedModel,
            onSelectModel: { modelId in
                selectedModel = modelId
                onDismiss()
            },
            // nil while searching so left/right arrows stay with the
            // search field's text cursor instead of switching hidden tabs
            onSwitchTab: isSearching ? nil : { offset in switchTab(by: offset) },
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
