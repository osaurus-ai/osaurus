//
//  ModelPickerView.swift
//  osaurus
//
//  A rich model picker with search, grouped sections, and metadata display.
//

import SwiftUI

struct ModelPickerView: View {
    let options: [ModelPickerItem]
    @Binding var selectedModel: String?
    let agentId: UUID?
    let onDismiss: () -> Void

    @State private var searchText = ""
    @State private var searchDebounceTask: Task<Void, Never>?
    @State private var collapsedGroups: Set<String> = []
    @State private var cachedGroupedOptions: [(source: ModelPickerItem.Source, models: [ModelPickerItem])] = []
    @State private var cachedFlattenedRows: [ModelPickerRow] = []
    @State private var cachedGroupRows: [String: [ModelPickerRow]] = [:]
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

    private func recomputeRows() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let groups: [(source: ModelPickerItem.Source, models: [ModelPickerItem])]

        if query.isEmpty {
            groups = cachedGroupedOptions
        } else {
            groups = cachedGroupedOptions.compactMap { group in
                let groupMatches = SearchService.matches(query: query, in: group.source.displayName)
                let matchedModels = group.models.filter {
                    SearchService.matches(query: query, in: $0.displayName)
                        || SearchService.matches(query: query, in: $0.id)
                }
                if groupMatches { return group }
                if !matchedModels.isEmpty {
                    return (source: group.source, models: matchedModels)
                }
                return nil
            }
        }

        var rows: [ModelPickerRow] = []
        // preallocate to reduce allocations
        rows.reserveCapacity(groups.count * 20)

        for group in groups {
            let sourceKey = group.source.uniqueKey
            let expanded = !query.isEmpty || !collapsedGroups.contains(sourceKey)

            rows.append(
                .groupHeader(
                    sourceKey: sourceKey,
                    displayName: group.source.displayName,
                    sourceType: group.source,
                    count: group.models.count,
                    isExpanded: expanded
                )
            )

            if expanded {
                // check if we have cached model rows for this group
                let cacheKey = sourceKey + "_\(group.models.count)"
                if let cachedModelRows = cachedGroupRows[cacheKey], query.isEmpty {
                    rows.append(contentsOf: cachedModelRows)
                } else {
                    var modelRows: [ModelPickerRow] = []
                    modelRows.reserveCapacity(group.models.count)

                    for model in group.models {
                        let row = ModelPickerRow.model(
                            id: model.id,
                            sourceKey: sourceKey,
                            displayName: model.displayName,
                            description: model.description,
                            parameterCount: model.parameterCount,
                            quantization: model.quantization,
                            isVLM: model.isVLM
                        )
                        modelRows.append(row)
                    }

                    // cache model rows when not searching
                    if query.isEmpty {
                        cachedGroupRows[cacheKey] = modelRows
                    }
                    rows.append(contentsOf: modelRows)
                }
            }
        }
        cachedFlattenedRows = rows
    }

    private func toggleGroup(_ source: ModelPickerItem.Source) {
        let key = source.uniqueKey
        if collapsedGroups.contains(key) {
            collapsedGroups.remove(key)
        } else {
            collapsedGroups.insert(key)
        }
        // onChange(of: collapsedGroups) will trigger recomputeRows()
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
            cachedGroupedOptions = displayOptions.groupedBySource()
            recomputeRows()
        }
        .task {
            // refresh remote model lists on open so newly-added/removed
            // models surface
            await RemoteProviderManager.shared.refreshConnectedProviders()
        }
        .onDisappear {
            searchDebounceTask?.cancel()
        }
        .onChange(of: displayOptions.count) { _, _ in
            cachedGroupedOptions = displayOptions.groupedBySource()
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
        .onChange(of: collapsedGroups) { _, _ in
            // debounce to avoid multiple rapid toggles
            searchDebounceTask?.cancel()
            searchDebounceTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled else { return }
                recomputeRows()
            }
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
                .foregroundColor(theme.tertiaryText)

            TextField(text: $searchText, prompt: Text("Search models...", bundle: .module)) {
                Text("Search models...", bundle: .module)
            }
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .foregroundColor(theme.primaryText)

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
            onToggleGroup: { sourceKey in
                if let group = cachedGroupedOptions.first(where: { $0.source.uniqueKey == sourceKey }) {
                    toggleGroup(group.source)
                }
            },
            onSelectModel: { modelId in
                selectedModel = modelId
                onDismiss()
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

            // small sample for quick testing
            private var smallSampleModels: [ModelPickerItem] {
                [
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
                        source: .remote(providerName: "OpenAI", providerId: UUID())
                    ),
                    ModelPickerItem(
                        id: "openai/gpt-3.5-turbo",
                        displayName: "gpt-3.5-turbo",
                        source: .remote(providerName: "OpenAI", providerId: UUID())
                    ),
                ]
            }
        }

        static var previews: some View {
            PreviewWrapper()
        }
    }
#endif
