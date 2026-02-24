//
//  ModelPickerView.swift
//  osaurus
//
//  A rich model picker with search, grouped sections, and metadata display.
//

import SwiftUI

struct ModelPickerView: View {
    let options: [ModelOption]
    @Binding var selectedModel: String?
    let agentId: UUID?
    let onDismiss: () -> Void

    @State private var searchText = ""
    @State private var collapsedGroups: Set<String> = []
    @State private var highlightedIndex: Int?
    @State private var keyMonitor: Any?
    @State private var cachedGroupedOptions: [(source: ModelOption.Source, models: [ModelOption])] = []
    @Environment(\.theme) private var theme

    // MARK: - Data

    private var filteredGroups: [(source: ModelOption.Source, models: [ModelOption])] {
        guard !searchText.isEmpty else { return cachedGroupedOptions }
        return cachedGroupedOptions.compactMap { group in
            let groupMatches = SearchService.matches(query: searchText, in: group.source.displayName)
            let matchedModels = group.models.filter {
                SearchService.matches(query: searchText, in: $0.displayName)
                    || SearchService.matches(query: searchText, in: $0.id)
            }
            if groupMatches { return group }
            if !matchedModels.isEmpty {
                return (source: group.source, models: matchedModels)
            }
            return nil
        }
    }

    private var flatFilteredModels: [ModelOption] {
        filteredGroups.flatMap { isGroupExpanded($0.source) ? $0.models : [] }
    }

    private var highlightedModelId: String? {
        guard let index = highlightedIndex, index >= 0, index < flatFilteredModels.count else { return nil }
        return flatFilteredModels[index].id
    }

    private func isGroupExpanded(_ source: ModelOption.Source) -> Bool {
        !searchText.isEmpty || !collapsedGroups.contains(source.uniqueKey)
    }

    private func toggleGroup(_ source: ModelOption.Source) {
        let key = source.uniqueKey
        if collapsedGroups.contains(key) {
            collapsedGroups.remove(key)
        } else {
            collapsedGroups.insert(key)
        }
    }

    // MARK: - Keyboard Navigation

    private func moveHighlight(by offset: Int) {
        let models = flatFilteredModels
        guard !models.isEmpty else { return }
        if let current = highlightedIndex {
            highlightedIndex = max(0, min(models.count - 1, current + offset))
        } else {
            highlightedIndex = offset > 0 ? 0 : models.count - 1
        }
    }

    private func selectHighlighted() {
        guard let index = highlightedIndex, index >= 0, index < flatFilteredModels.count else { return }
        selectedModel = flatFilteredModels[index].id
        onDismiss()
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch event.keyCode {
            case 125:  // Down arrow
                moveHighlight(by: 1)
                return nil
            case 126:  // Up arrow
                moveHighlight(by: -1)
                return nil
            case 36:  // Return/Enter
                if highlightedIndex != nil {
                    selectHighlighted()
                    return nil
                }
                return event
            default:
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(theme.primaryBorder.opacity(0.3))
            searchField
            Divider().background(theme.primaryBorder.opacity(0.3))

            if filteredGroups.isEmpty {
                emptyState
            } else {
                modelList
            }
        }
        .frame(width: 380, height: min(CGFloat(options.count * 48 + 160), 480))
        .background(popoverBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(popoverBorder)
        .shadow(color: theme.shadowColor.opacity(0.25), radius: 20, x: 0, y: 10)
        .onAppear {
            cachedGroupedOptions = options.groupedBySource()
            installKeyMonitor()
        }
        .onDisappear { removeKeyMonitor() }
        .onChange(of: options) { _, newOptions in
            cachedGroupedOptions = newOptions.groupedBySource()
        }
        .onChange(of: searchText) { _, _ in highlightedIndex = nil }
    }

    // MARK: - Background & Border

    private var popoverBackground: some View {
        ZStack {
            if theme.glassEnabled {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.ultraThinMaterial)
            }
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.primaryBackground.opacity(theme.isDark ? 0.85 : 0.92))
            LinearGradient(
                colors: [theme.accentColor.opacity(theme.isDark ? 0.06 : 0.04), Color.clear],
                startPoint: .top,
                endPoint: .center
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
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
        HStack {
            Text("Available Models")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.primaryText)

            Spacer()

            Text("\(options.count)")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.secondaryText)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(theme.secondaryBackground))
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

            TextField("Search models...", text: $searchText)
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

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 24))
                .foregroundColor(theme.tertiaryText)
            Text("No models found")
                .font(.system(size: 13))
                .foregroundColor(theme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Flattened Rows

    private var flattenedRows: [ModelPickerRow] {
        var rows: [ModelPickerRow] = []
        for group in filteredGroups {
            let expanded = isGroupExpanded(group.source)
            let sourceKey = group.source.uniqueKey
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
                for model in group.models {
                    rows.append(
                        .model(
                            id: model.id,
                            sourceKey: sourceKey,
                            displayName: model.displayName,
                            description: model.description,
                            parameterCount: model.parameterCount,
                            quantization: model.quantization,
                            isVLM: model.isVLM
                        )
                    )
                }
            }
        }
        return rows
    }

    // MARK: - Model List

    private var modelList: some View {
        ModelPickerTableRepresentable(
            rows: flattenedRows,
            theme: theme,
            selectedModelId: selectedModel,
            highlightedModelId: highlightedModelId,
            scrollToModelId: highlightedModelId,
            onToggleGroup: { sourceKey in
                if let group = filteredGroups.first(where: { $0.source.uniqueKey == sourceKey }) {
                    toggleGroup(group.source)
                }
            },
            onSelectModel: { modelId in
                selectedModel = modelId
                onDismiss()
            }
        )
    }
}

// MARK: - Preview

#if DEBUG
    struct ModelPickerView_Previews: PreviewProvider {
        struct PreviewWrapper: View {
            @State private var selected: String? = "foundation"

            var body: some View {
                ModelPickerView(
                    options: [
                        .foundation(),
                        ModelOption(
                            id: "mlx-community/Llama-3.2-3B-Instruct-4bit",
                            displayName: "Llama 3.2 3B Instruct 4bit",
                            source: .local,
                            parameterCount: "3B",
                            quantization: "4-bit",
                            isVLM: false
                        ),
                        ModelOption(
                            id: "mlx-community/Qwen2-VL-7B-Instruct-4bit",
                            displayName: "Qwen2 VL 7B Instruct 4bit",
                            source: .local,
                            parameterCount: "7B",
                            quantization: "4-bit",
                            isVLM: true
                        ),
                        ModelOption(
                            id: "openai/gpt-4o",
                            displayName: "gpt-4o",
                            source: .remote(providerName: "OpenAI", providerId: UUID())
                        ),
                        ModelOption(
                            id: "openai/gpt-3.5-turbo",
                            displayName: "gpt-3.5-turbo",
                            source: .remote(providerName: "OpenAI", providerId: UUID())
                        ),
                    ],
                    selectedModel: $selected,
                    agentId: nil,
                    onDismiss: {}
                )
                .padding()
                .frame(width: 450, height: 550)
                .background(Color.gray.opacity(0.2))
            }
        }

        static var previews: some View {
            PreviewWrapper()
        }
    }
#endif
