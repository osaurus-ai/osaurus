//
//  ModelDownloadView.swift
//  osaurus
//
//  Created by Terence on 8/17/25.
//

import AppKit
import Foundation
import SwiftUI

/// Sort options for the model list.
enum ModelSortOption: String, CaseIterable, Identifiable {
    case recommended
    case downloadsDesc
    case nameAsc
    case compatibility
    case sizeAsc
    case sizeDesc

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .recommended: return "Recommended"
        case .downloadsDesc: return "Most Downloaded"
        case .nameAsc: return "Name (A–Z)"
        case .compatibility: return "Compatibility"
        case .sizeAsc: return "Size (Smallest first)"
        case .sizeDesc: return "Size (Largest first)"
        }
    }

    var iconName: String {
        switch self {
        case .recommended: return "sparkles"
        case .downloadsDesc: return "arrow.down.app"
        case .nameAsc: return "textformat"
        case .compatibility: return "checkmark.seal"
        case .sizeAsc: return "arrow.up.circle"
        case .sizeDesc: return "arrow.down.circle"
        }
    }
}

/// Deep linking is supported via `deeplinkModelId` to open the view with a specific model pre-selected.
struct ModelDownloadView: View {

    // MARK: - State Management

    /// Shared model manager for handling downloads and model state
    @ObservedObject private var modelManager = ModelManager.shared

    /// System resource monitor for hardware info display
    @ObservedObject private var systemMonitor = SystemMonitorService.shared

    /// Theme manager for consistent UI styling
    @ObservedObject private var themeManager = ThemeManager.shared

    /// Use computed property to always get the current theme from ThemeManager
    private var theme: ThemeProtocol { themeManager.currentTheme }

    /// Current search query text  bound directly to the search field so
    /// keystrokes are reflected immediately in the input.
    @State private var searchText: String = ""

    /// Debounced copy of `searchText` that drives filtering + grid animation
    @State private var debouncedSearchText: String = ""

    /// Currently selected tab (All, Suggested, or Downloaded)
    @State private var selectedTab: ModelListTab = .all

    /// Debounce task for the remote Hugging Face fetch.
    @State private var searchDebounceTask: Task<Void, Never>? = nil

    /// Debounce task for the local filter / animation trigger.
    @State private var localSearchDebounceTask: Task<Void, Never>? = nil

    /// Model to show in the detail sheet
    @State private var modelToShowDetails: MLXModel? = nil

    /// Content has appeared (for entrance animation)
    @State private var hasAppeared = false

    /// Filter state
    @State private var filterState = ModelManager.ModelFilterState()
    @State private var showFilterPopover = false

    /// Sort option for the model list
    @State private var sortOption: ModelSortOption = .recommended
    @State private var showSortPopover = false

    /// Import-from-Hugging-Face sheet state
    @State private var showImportSheet = false

    // MARK: - Deep Link Support

    /// Optional model ID for deep linking (e.g., from URL schemes)
    var deeplinkModelId: String? = nil

    /// Optional file path for deep linking
    var deeplinkFile: String? = nil

    var body: some View {
        // compute the grid lists once per body pass and thread them down
        // so derived properties don't re-run multiple times during animation frames
        let lists = gridLists
        return VStack(spacing: 0) {
            headerView(lists: lists)
                .opacity(hasAppeared ? 1 : 0)
                .offset(y: hasAppeared ? 0 : -10)
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: hasAppeared)

            SystemStatusBar(
                totalMemoryGB: systemMonitor.totalMemoryGB,
                usedMemoryGB: systemMonitor.usedMemoryGB,
                availableStorageGB: systemMonitor.availableStorageGB,
                totalStorageGB: systemMonitor.totalStorageGB
            )
            .opacity(hasAppeared ? 1 : 0)

            modelListView(lists: lists)
                .opacity(hasAppeared ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.primaryBackground)
        .environment(\.theme, themeManager.currentTheme)
        .onAppear {
            // If invoked via deeplink, prefill search and ensure the model is visible
            if let modelId = deeplinkModelId, !modelId.isEmpty {
                searchText = modelId.split(separator: "/").last.map(String.init) ?? modelId
                debouncedSearchText = searchText
                _ = modelManager.resolveModel(byRepoId: modelId)
            }

            // Animate content appearance before heavy operations
            withAnimation(.easeOut(duration: 0.25).delay(0.05)) {
                hasAppeared = true
            }

            // Defer heavy fetch operation to prevent initial jank
            Task {
                try? await Task.sleep(nanoseconds: 150_000_000)  // 150ms delay
                modelManager.fetchRemoteMLXModels(searchText: searchText)
            }
        }
        .onChange(of: searchText) { _, newValue in
            // If input looks like a Hugging Face repo, switch to All so it's visible
            if ModelManager.parseHuggingFaceRepoId(from: newValue) != nil, selectedTab != .all {
                selectedTab = .all
            }
            // 150ms debounce for the local filter + grid animation: avoids
            // running the mosaic transition on every keystroke.
            localSearchDebounceTask?.cancel()
            localSearchDebounceTask = Task { @MainActor in
                do { try await Task.sleep(nanoseconds: 150_000_000) } catch { return }
                if Task.isCancelled { return }
                withAnimation(GridDiff.spring) {
                    debouncedSearchText = newValue
                }
            }
            // 300ms debounce for the remote fetch.
            searchDebounceTask?.cancel()
            searchDebounceTask = Task { @MainActor in
                do { try await Task.sleep(nanoseconds: 300_000_000) } catch { return }
                if Task.isCancelled { return }
                modelManager.fetchRemoteMLXModels(searchText: newValue)
            }
        }
        .sheet(item: $modelToShowDetails) { model in
            ModelDetailView(model: model)
                .environment(\.theme, themeManager.currentTheme)
        }
        .sheet(isPresented: $showImportSheet) {
            HuggingFaceImportSheet(
                onImported: { repoId in
                    showImportSheet = false
                    selectedTab = .all
                    searchText = repoId
                }
            )
            .environment(\.theme, themeManager.currentTheme)
        }
    }

    // MARK: - Header View

    private func headerView(lists: GridLists) -> some View {
        ManagerHeaderWithTabs(
            title: L("Models"),
            subtitle: "\(completedDownloadedModelsCount) downloaded • \(modelManager.totalDownloadedSizeString)"
        ) {
            HStack(spacing: 12) {
                // Refresh OsaurusAI HF org listing (Recommended section lives inside All)
                if selectedTab == .all {
                    Button {
                        Task { await modelManager.refreshSuggestedModels() }
                    } label: {
                        HStack(spacing: 6) {
                            if modelManager.isLoadingSuggested {
                                ProgressView()
                                    .controlSize(.small)
                                    .scaleEffect(0.7)
                                    .frame(width: 13, height: 13)
                            } else {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 13))
                            }
                            Text("Refresh", bundle: .module)
                                .font(.system(size: 13, weight: .medium))
                        }
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(theme.tertiaryBackground.opacity(0.5))
                        )
                        .foregroundColor(theme.secondaryText)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .disabled(modelManager.isLoadingSuggested)
                    .help(L("Refresh OsaurusAI models from Hugging Face"))
                }

                // Import from Hugging Face
                Button {
                    showImportSheet = true
                } label: {
                    HStack(spacing: 6) {
                        Text("🤗")
                            .font(.system(size: 13))
                        Text("Import", bundle: .module)
                            .font(.system(size: 13, weight: .medium))
                    }
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(theme.tertiaryBackground.opacity(0.5))
                    )
                    .foregroundColor(theme.secondaryText)
                }
                .buttonStyle(PlainButtonStyle())
                .help(L("Import an MLX model from Hugging Face"))

                // Download status indicator (shown when downloads are active)
                if modelManager.activeDownloadsCount > 0 {
                    DownloadStatusIndicator(
                        activeCount: modelManager.activeDownloadsCount,
                        averageProgress: averageDownloadProgress,
                        onTap: {
                            withAnimation(.easeOut(duration: 0.2)) {
                                selectedTab = .downloaded
                            }
                        }
                    )
                    .transition(.scale.combined(with: .opacity))
                }
            }
        } tabsRow: {
            HeaderTabsRow(
                selection: $selectedTab,
                counts: [
                    .all: lists.suggested.count + lists.others.count,
                    .downloaded: lists.downloaded.count,
                ],
                badges: modelManager.activeDownloadsCount > 0
                    ? [.downloaded: modelManager.activeDownloadsCount]
                    : nil,
                searchText: $searchText,
                searchPlaceholder: "Search models"
            )
        }
    }

    // MARK: - Filter Popover

    /// Wraps filter/sort mutations in the shared grid spring so the
    /// popover-side animations stay in sync with the grid mosaic. The
    /// grid diff itself is driven by the implicit `.gridDiffAnimation`.
    private func mutateFilter(_ change: () -> Void) {
        withAnimation(GridDiff.spring) { change() }
    }

    private var sortPopoverView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Sort by", bundle: .module)
                .font(.system(size: 10, weight: .bold))
                .tracking(0.6)
                .foregroundColor(theme.tertiaryText)
                .textCase(.uppercase)
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 6)

            ForEach(ModelSortOption.allCases) { option in
                SortOptionRow(
                    option: option,
                    isSelected: sortOption == option
                ) {
                    mutateFilter { sortOption = option }
                    showSortPopover = false
                }
            }
            Spacer(minLength: 8)
        }
        .frame(width: 240)
        .background(theme.primaryBackground)
        .environment(\.theme, themeManager.currentTheme)
    }

    private struct SortOptionRow: View {
        let option: ModelSortOption
        let isSelected: Bool
        let action: () -> Void
        @Environment(\.theme) private var theme
        @State private var isHovering = false

        var body: some View {
            Button(action: action) {
                HStack(spacing: 10) {
                    Image(systemName: option.iconName)
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 16)
                        .foregroundColor(isSelected ? theme.accentColor : theme.secondaryText)
                    Text(option.displayName)
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

    private var filterPopoverView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Filters", bundle: .module)
                        .font(.system(size: 14, weight: .bold))
                    Spacer()
                    if filterState.isActive {
                        Button {
                            mutateFilter { filterState.reset() }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.counterclockwise")
                                    .font(.system(size: 10, weight: .bold))
                                Text("Reset", bundle: .module)
                                    .font(.system(size: 12, weight: .medium))
                            }
                        }
                        .foregroundColor(.red)
                        .buttonStyle(.plain)
                    }
                }
                .padding(.bottom, 4)

                Group {
                    FilterSection(title: "Model Type") {
                        HStack(spacing: 8) {
                            FilterChip(label: "LLM", isSelected: filterState.typeFilter.isLLM) {
                                mutateFilter {
                                    filterState.typeFilter = filterState.typeFilter.isLLM ? .all : .llm
                                }
                            }
                            FilterChip(label: "VLM", isSelected: filterState.typeFilter.isVLM) {
                                mutateFilter {
                                    filterState.typeFilter = filterState.typeFilter.isVLM ? .all : .vlm
                                }
                            }
                        }
                    }

                    FilterSection(title: "Model Size") {
                        FlowLayout(spacing: 8) {
                            ForEach(ModelManager.ModelFilterState.SizeCategory.allCases) { cat in
                                FilterChip(label: cat.rawValue, isSelected: filterState.sizeCategory == cat) {
                                    mutateFilter {
                                        filterState.sizeCategory = filterState.sizeCategory == cat ? nil : cat
                                    }
                                }
                            }
                        }
                    }

                    FilterSection(title: "Parameters") {
                        HStack(spacing: 8) {
                            ForEach(ModelManager.ModelFilterState.ParamCategory.allCases) { cat in
                                FilterChip(label: cat.rawValue, isSelected: filterState.paramCategory == cat) {
                                    mutateFilter {
                                        filterState.paramCategory = filterState.paramCategory == cat ? nil : cat
                                    }
                                }
                            }
                        }
                    }
                    // Performance chips are mutually exclusive — picking one
                    // clears the others so the filter stays a single optional
                    // (matches SizeCategory / ParamCategory conventions and
                    // keeps `isActive` trivially `performance != nil`).
                    FilterSection(title: "Performance") {
                        FlowLayout(spacing: 8) {
                            ForEach(ModelManager.ModelFilterState.PerformanceFilter.allCases) { opt in
                                FilterChip(
                                    label: opt.displayName,
                                    isSelected: filterState.performance == opt
                                ) {
                                    mutateFilter {
                                        filterState.performance =
                                            filterState.performance == opt ? nil : opt
                                    }
                                }
                            }
                        }
                    }
                    FilterSection(title: "Model Family") {
                        let families = Array(Set(modelManager.availableModels.map { $0.family })).sorted()
                        if families.isEmpty {
                            Text("No families found", bundle: .module)
                                .font(.system(size: 11))
                                .foregroundColor(theme.tertiaryText)
                        } else {
                            FlowLayout(spacing: 8) {
                                ForEach(families, id: \.self) { fam in
                                    FilterChip(label: fam, isSelected: filterState.family == fam) {
                                        mutateFilter {
                                            filterState.family = filterState.family == fam ? nil : fam
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
        .frame(width: 300)
        .frame(maxHeight: 480)
        .background(theme.primaryBackground)
        .environment(\.theme, themeManager.currentTheme)
    }

    private struct FilterSection<Content: View>: View {
        let title: String
        @ViewBuilder let content: Content
        @Environment(\.theme) private var theme

        init(title: String, @ViewBuilder content: () -> Content) {
            self.title = title
            self.content = content()
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.6)
                    .foregroundColor(theme.tertiaryText)
                    .textCase(.uppercase)
                content
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

    // MARK: - Model List View
    private var gridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 260), spacing: 12, alignment: .top)]
    }

    private func modelGridSection(
        title: String,
        models: [MLXModel],
        isFirst: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(theme.tertiaryText)
                .textCase(.uppercase)
                .padding(.horizontal, 2)
                .padding(.top, isFirst ? 0 : 16)
            modelGrid(models: models)
        }
    }

    /// Grid of ModelRowView cards. Surviving cells (same `id` before and
    /// after a filter change) slide to their new grid position; cells
    /// that drop out scale-fade away; new cells scale-fade in. Driven by
    /// the shared `gridDiffAnimation(token:)` modifier below.
    private func modelGrid(models: [MLXModel]) -> some View {
        LazyVGrid(columns: gridColumns, spacing: 20) {
            ForEach(models, id: \.id) { model in
                ModelRowView(
                    model: model,
                    downloadState: modelManager.effectiveDownloadState(for: model),
                    metrics: modelManager.downloadMetrics[model.id],
                    totalMemoryGB: systemMonitor.totalMemoryGB,
                    onViewDetails: { modelToShowDetails = model },
                    onCancel: { modelManager.cancelDownload(model.id) }
                )
                .gridDiffCell()
            }
        }
        .gridDiffAnimation(token: gridChangeToken)
    }

    /// Main content area with scrollable model list
    private func modelListView(lists: GridLists) -> some View {
        Group {
            if modelManager.isLoadingModels && lists.displayed.isEmpty {
                loadingState
            } else {
                VStack(spacing: 0) {
                    sortFilterBar
                        .padding(.horizontal, 24)
                        .padding(.top, 12)
                        .padding(.bottom, 4)

                    ScrollView {
                        VStack(spacing: 12) {
                            if !modelManager.deprecationNotices.isEmpty {
                                deprecationBanner
                            }

                            if lists.displayed.isEmpty {
                                emptyState
                            } else {
                                switch selectedTab {
                                case .all:
                                    if !lists.suggested.isEmpty {
                                        modelGridSection(
                                            title: L("Recommended"),
                                            models: lists.suggested,
                                            isFirst: true
                                        )
                                    }
                                    if !lists.others.isEmpty {
                                        modelGridSection(
                                            title: L("Others"),
                                            models: lists.others,
                                            isFirst: lists.suggested.isEmpty
                                        )
                                    }
                                case .downloaded:
                                    modelGrid(models: lists.downloaded)
                                }
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.bottom, 24)
                        .padding(.top, 12)
                    }
                    .mask(
                        VStack(spacing: 0) {
                            LinearGradient(
                                gradient: Gradient(colors: [.clear, .black]),
                                startPoint: .top,
                                endPoint: .bottom
                            )
                            .frame(height: 16)
                            Color.black
                            LinearGradient(
                                gradient: Gradient(colors: [.black, .clear]),
                                startPoint: .top,
                                endPoint: .bottom
                            )
                            .frame(height: 24)
                        }
                    )
                }
            }
        }
    }

    // MARK: - Sort / Filter Bar

    private var sortFilterBar: some View {
        HStack(spacing: 12) {
            Spacer()

            // Sort button
            Button {
                showSortPopover.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 13))
                    if sortOption == .recommended {
                        Text("Sort", bundle: .module)
                            .font(.system(size: 13, weight: .medium))
                    } else {
                        Text("Sort: ", bundle: .module)
                            .font(.system(size: 13, weight: .medium))
                            + Text(sortOption.displayName)
                            .font(.system(size: 13, weight: .semibold))
                    }
                }
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(
                            sortOption != .recommended
                                ? theme.accentColor.opacity(0.12)
                                : theme.tertiaryBackground.opacity(0.5)
                        )
                )
                .foregroundColor(
                    sortOption != .recommended ? theme.accentColor : theme.secondaryText
                )
            }
            .buttonStyle(PlainButtonStyle())
            .popover(isPresented: $showSortPopover, arrowEdge: .top) {
                sortPopoverView
            }
            .help(L("Sort models"))

            // Filter button
            Button {
                showFilterPopover.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(
                        systemName: filterState.isActive
                            ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle"
                    )
                    .font(.system(size: 13))
                    if let active = activeFilterSummary {
                        Text("Filter: ", bundle: .module)
                            .font(.system(size: 13, weight: .medium))
                            + Text(active)
                            .font(.system(size: 13, weight: .semibold))
                    } else {
                        Text("Filter", bundle: .module)
                            .font(.system(size: 13, weight: .medium))
                    }
                }
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(
                            filterState.isActive
                                ? theme.accentColor.opacity(0.12) : theme.tertiaryBackground.opacity(0.5)
                        )
                )
                .foregroundColor(filterState.isActive ? theme.accentColor : theme.secondaryText)
            }
            .buttonStyle(PlainButtonStyle())
            .popover(isPresented: $showFilterPopover, arrowEdge: .top) {
                filterPopoverView
            }
        }
    }

    // MARK: - Deprecation Banner

    private var deprecationBanner: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.orange)

                Text("Model updates available", bundle: .module)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(theme.primaryText)
            }

            Text(
                "Some downloaded models have been replaced with improved OsaurusAI versions that fix known bugs.",
                bundle: .module
            )
            .font(.system(size: 12))
            .foregroundColor(theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)

            ForEach(modelManager.deprecationNotices) { notice in
                deprecationRow(for: notice)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.secondaryBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.orange.opacity(0.3), lineWidth: 1)
                )
        )
    }

    private func deprecationRow(for notice: ModelManager.DeprecationNotice) -> some View {
        let state = modelManager.downloadStates[notice.newId] ?? .notStarted
        let metrics = modelManager.downloadMetrics[notice.newId]

        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.displayName(from: notice.oldId))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.tertiaryText)
                    .strikethrough()

                HStack(spacing: 4) {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10))
                        .foregroundColor(theme.accentColor)
                    Text(Self.displayName(from: notice.newId))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.primaryText)
                }

                if case .downloading(let progress) = state {
                    downloadProgress(progress: progress, metrics: metrics)
                }

                if case .failed(let error) = state {
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundColor(.red)
                        .lineLimit(1)
                        .padding(.top, 2)
                }
            }

            Spacer()

            switch state {
            case .completed:
                pillButton("Remove old", icon: "trash", color: .red, bg: Color.red.opacity(0.12)) {
                    let oldModel = MLXModel(id: notice.oldId, name: "", description: "", downloadURL: "")
                    modelManager.deleteModel(oldModel)
                }
            case .downloading:
                pillButton("Cancel", color: theme.secondaryText, bg: theme.tertiaryBackground) {
                    modelManager.cancelDownload(notice.newId)
                }
            case .failed:
                pillButton("Retry", color: .white, bg: theme.accentColor) {
                    modelManager.downloadModel(withRepoId: notice.newId)
                }
            case .notStarted:
                pillButton("Download", color: .white, bg: theme.accentColor) {
                    modelManager.downloadModel(withRepoId: notice.newId)
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Deprecation Helpers

    private func downloadProgress(progress: Double, metrics: ModelDownloadService.DownloadMetrics?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .tint(theme.accentColor)

            HStack(spacing: 6) {
                Text("\(Int(progress * 100))%", bundle: .module)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(theme.secondaryText)

                if let speed = metrics?.bytesPerSecond, speed > 0 {
                    Text(Self.formatSpeed(speed))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(theme.tertiaryText)
                }

                if let eta = metrics?.etaSeconds, eta > 0, eta < 86400 {
                    Text(Self.formatETA(eta))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(theme.tertiaryText)
                }
            }
        }
        .padding(.top, 2)
    }

    private func pillButton(
        _ title: String,
        icon: String? = nil,
        color: Color,
        bg: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Group {
                if let icon {
                    Label(title, systemImage: icon)
                } else {
                    Text(title)
                }
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(bg))
            .foregroundColor(color)
        }
        .buttonStyle(.plain)
    }

    private static func displayName(from repoId: String) -> String {
        repoId.split(separator: "/").last.map(String.init)?
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ") ?? repoId
    }

    private static func formatSpeed(_ bytesPerSecond: Double) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useGB, .useMB]
        return "\(formatter.string(fromByteCount: Int64(bytesPerSecond)))/s"
    }

    private static func formatETA(_ seconds: Double) -> String {
        ModelDownloadService.DownloadMetrics.formatETA(seconds: seconds)
    }

    // MARK: - Loading State

    private var loadingState: some View {
        VStack(spacing: 20) {
            // Skeleton cards
            ForEach(0 ..< 4) { index in
                SkeletonCard(animationDelay: Double(index) * 0.1)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: emptyStateIcon)
                .font(.system(size: 40, weight: .light))
                .foregroundColor(theme.tertiaryText)

            Text(emptyStateTitle)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(theme.secondaryText)

            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Text("Clear search", bundle: .module)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.accentColor)
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    private var emptyStateIcon: String {
        switch selectedTab {
        case .all:
            return "cube.box"
        case .downloaded:
            return "arrow.down.circle"
        }
    }

    private var emptyStateTitle: String {
        if !searchText.isEmpty {
            return L("No models match your search")
        }
        switch selectedTab {
        case .all:
            return L("No models available")
        case .downloaded:
            return L("No downloaded models")
        }
    }

    // MARK: - Model Filtering

    /// Snapshot of every list the grid renders, computed once per body
    /// pass to avoid running `applySort` / `SearchService.filterModels` /
    /// `filterState.apply` 4–6 times during animation frames.
    struct GridLists {
        let suggested: [MLXModel]
        let others: [MLXModel]
        let downloaded: [MLXModel]
        let displayed: [MLXModel]
    }

    /// Single token for the implicit grid animation. Driving the implicit
    /// `.animation(_:value:)` modifier (rather than `withAnimation`) gives
    /// `LazyVGrid` reliable reorder animations — same path search uses.
    private var gridChangeToken: String {
        "\(selectedTab.rawValue)|\(sortOption.rawValue)|\(debouncedSearchText)|\(filterStateToken)"
    }

    /// Compact label for the active filter selection. `nil` when no
    /// filters are applied, the chosen value's name when exactly one
    /// dimension is active;,`"<n> active"` when multiple dimensions are
    private var activeFilterSummary: String? {
        var parts: [String] = []
        switch filterState.typeFilter {
        case .all: break
        case .llm: parts.append("LLM")
        case .vlm: parts.append("VLM")
        }
        if let size = filterState.sizeCategory { parts.append(size.displayName) }
        if let param = filterState.paramCategory { parts.append(param.rawValue) }
        if let perf = filterState.performance { parts.append(perf.displayName) }
        if let family = filterState.family { parts.append(family) }

        switch parts.count {
        case 0: return nil
        case 1: return parts[0]
        default: return "\(parts.count) active"
        }
    }

    private var filterStateToken: String {
        let type: String
        switch filterState.typeFilter {
        case .all: type = "all"
        case .llm: type = "llm"
        case .vlm: type = "vlm"
        }
        return
            "\(type)|\(filterState.sizeCategory?.rawValue ?? "_")|\(filterState.paramCategory?.rawValue ?? "_")|\(filterState.performance?.rawValue ?? "_")|\(filterState.family ?? "_")"
    }

    /// Consolidates all list computations. Each input pipeline runs once.
    private var gridLists: GridLists {
        let mem = systemMonitor.totalMemoryGB

        let availSearched = SearchService.filterModels(modelManager.availableModels, with: debouncedSearchText)
        let availFiltered = filterState.apply(to: availSearched, totalMemoryGB: mem)
        let allFiltered = applySort(to: availFiltered)

        let suggSearched = SearchService.filterModels(modelManager.suggestedModels, with: debouncedSearchText)
        let suggFiltered = filterState.apply(to: suggSearched, totalMemoryGB: mem)
        let suggested = sortedSuggested(suggFiltered)

        let recommendedIds = Set(suggested.map { $0.id.lowercased() })
        let others = allFiltered.filter { !recommendedIds.contains($0.id.lowercased()) }

        let downloaded = computeDownloadedList(memory: mem)

        let displayed: [MLXModel]
        switch selectedTab {
        case .all: displayed = suggested + others
        case .downloaded: displayed = downloaded
        }

        return GridLists(suggested: suggested, others: others, downloaded: downloaded, displayed: displayed)
    }

    private func sortedSuggested(_ filtered: [MLXModel]) -> [MLXModel] {
        if sortOption != .recommended {
            return applySort(to: filtered)
        }
        let curatedIds = ModelManager.curatedSuggestedIds
        return filtered.sorted { lhs, rhs in
            let lhsCurated = curatedIds.contains(lhs.id.lowercased())
            let rhsCurated = curatedIds.contains(rhs.id.lowercased())
            if lhsCurated != rhsCurated { return lhsCurated }

            if lhsCurated && lhs.isTopSuggestion != rhs.isTopSuggestion {
                return lhs.isTopSuggestion
            }

            switch (lhs.releasedAt, rhs.releasedAt) {
            case let (l?, r?) where l != r:
                return l > r
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            default:
                break
            }

            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private func computeDownloadedList(memory mem: Double) -> [MLXModel] {
        let all = modelManager.deduplicatedModels()
        let isActive: (MLXModel) -> Bool = { m in
            if case .downloading = (modelManager.downloadStates[m.id] ?? .notStarted) { return true }
            return false
        }
        let active = all.filter(isActive)
        let completed = all.filter { $0.isDownloaded }
        var seen: Set<String> = []
        var merged: [MLXModel] = []
        for m in active + completed {
            let k = m.id.lowercased()
            if !seen.contains(k) {
                seen.insert(k)
                merged.append(m)
            }
        }
        let searched = SearchService.filterModels(merged, with: debouncedSearchText)
        let filtered = filterState.apply(to: searched, totalMemoryGB: mem)
        let activeGroup = applySort(to: filtered.filter(isActive))
        let restGroup = applySort(to: filtered.filter { !isActive($0) })
        return activeGroup + restGroup
    }

    /// Apply the active `sortOption` to a list. `.recommended` falls back to
    /// alphabetical so the "Others" section in the All tab stays stable.
    private func applySort(to models: [MLXModel]) -> [MLXModel] {
        switch sortOption {
        case .recommended, .nameAsc:
            return models.sorted { lhs, rhs in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        case .downloadsDesc:
            // Models without a known HF download count drop to the bottom.
            return models.sorted { lhs, rhs in
                let l = lhs.downloads ?? -1
                let r = rhs.downloads ?? -1
                if l != r { return l > r }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        case .compatibility:
            return models.sorted { lhs, rhs in
                let l = compatibilityRank(lhs)
                let r = compatibilityRank(rhs)
                if l != r { return l < r }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        case .sizeAsc, .sizeDesc:
            return models.sorted { lhs, rhs in
                let l = lhs.totalSizeEstimateBytes ?? Int64.max
                let r = rhs.totalSizeEstimateBytes ?? Int64.max
                if l != r { return sortOption == .sizeAsc ? l < r : l > r }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        }
    }

    private func compatibilityRank(_ model: MLXModel) -> Int {
        switch model.compatibility(totalMemoryGB: systemMonitor.totalMemoryGB) {
        case .compatible: return 0
        case .tight: return 1
        case .tooLarge: return 2
        case .unknown: return 3
        }
    }

    /// Count of completed (on-disk) downloaded models respecting current search and filters
    private var completedDownloadedModelsCount: Int {
        let completed = modelManager.deduplicatedModels().filter { $0.isDownloaded }
        let searched = SearchService.filterModels(Array(completed), with: debouncedSearchText)
        let filtered = filterState.apply(to: searched, totalMemoryGB: systemMonitor.totalMemoryGB)
        return filtered.count
    }

    /// Average progress across all active downloads (0.0 to 1.0)
    private var averageDownloadProgress: Double {
        let activeProgress = modelManager.downloadStates.compactMap { (_, state) -> Double? in
            if case .downloading(let progress) = state { return progress }
            return nil
        }
        guard !activeProgress.isEmpty else { return 0 }
        return activeProgress.reduce(0, +) / Double(activeProgress.count)
    }

}

// MARK: - Skeleton Loading Card

private struct SkeletonCard: View {
    @Environment(\.theme) private var theme
    let animationDelay: Double

    @State private var isAnimating = false

    var body: some View {
        HStack(spacing: 16) {
            // Icon placeholder
            RoundedRectangle(cornerRadius: 10)
                .fill(shimmerGradient)
                .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 8) {
                // Title placeholder
                RoundedRectangle(cornerRadius: 4)
                    .fill(shimmerGradient)
                    .frame(width: 180, height: 16)

                // Description placeholder
                RoundedRectangle(cornerRadius: 4)
                    .fill(shimmerGradient)
                    .frame(width: 280, height: 12)

                // Link placeholder
                RoundedRectangle(cornerRadius: 4)
                    .fill(shimmerGradient)
                    .frame(width: 140, height: 10)
            }

            Spacer()
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
        .onAppear {
            withAnimation(
                .easeInOut(duration: 1.2)
                    .repeatForever(autoreverses: true)
                    .delay(animationDelay)
            ) {
                isAnimating = true
            }
        }
    }

    private var shimmerGradient: some ShapeStyle {
        theme.tertiaryBackground.opacity(isAnimating ? 0.8 : 0.4)
    }
}

// MARK: - Download Status Indicator

/// Download status button shown when downloads are active
private struct DownloadStatusIndicator: View {
    @Environment(\.theme) private var theme

    let activeCount: Int
    let averageProgress: Double
    let onTap: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                // Progress ring with arrow
                ZStack {
                    Circle()
                        .stroke(
                            theme.secondaryText.opacity(0.25),
                            lineWidth: 1.5
                        )
                        .frame(width: 14, height: 14)

                    Circle()
                        .trim(from: 0, to: averageProgress)
                        .stroke(
                            theme.accentColor,
                            style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
                        )
                        .frame(width: 14, height: 14)
                        .rotationEffect(.degrees(-90))
                        .animation(.easeOut(duration: 0.3), value: averageProgress)

                    Image(systemName: "arrow.down")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundColor(theme.accentColor)
                }

                Text("Downloading", bundle: .module)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.secondaryText)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovering ? theme.tertiaryBackground : theme.tertiaryBackground.opacity(0.5))
            )
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.1)) {
                isHovering = hovering
            }
        }
        .help(Text("Downloading \(activeCount) model\(activeCount == 1 ? "" : "s") – Click to view", bundle: .module))
    }
}

// MARK: - System Status Bar

/// Compact bar showing available memory and storage with mini gauges.
private struct SystemStatusBar: View {
    @Environment(\.theme) private var theme

    let totalMemoryGB: Double
    let usedMemoryGB: Double
    let availableStorageGB: Double
    let totalStorageGB: Double

    var body: some View {
        HStack(spacing: 20) {
            ResourceGauge(
                label: "Memory",
                icon: "memorychip",
                usedFraction: totalMemoryGB > 0 ? usedMemoryGB / totalMemoryGB : 0,
                detail: String(
                    format: "%.0f GB free / %.0f GB",
                    max(0, totalMemoryGB - usedMemoryGB),
                    totalMemoryGB
                )
            )

            ResourceGauge(
                label: "Storage",
                icon: DirectoryPickerService.shared.hasValidDirectory ? "externaldrive" : "internaldrive",
                usedFraction: totalStorageGB > 0
                    ? (totalStorageGB - availableStorageGB) / totalStorageGB : 0,
                detail: String(
                    format: "%.0f GB free / %.0f GB",
                    availableStorageGB,
                    totalStorageGB
                )
            )
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .background(theme.secondaryBackground)
    }
}

/// Reusable mini gauge showing a label, icon, detail text, and color-coded progress bar.
private struct ResourceGauge: View {
    @Environment(\.theme) private var theme

    let label: String
    let icon: String
    let usedFraction: Double
    let detail: String

    private var clampedFraction: Double { min(1.0, max(0, usedFraction)) }

    private var barColor: Color {
        if clampedFraction < 0.7 { return theme.successColor }
        if clampedFraction < 0.9 { return theme.warningColor }
        return theme.errorColor
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(theme.secondaryText)

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 4) {
                    Text(label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                    Spacer()
                    Text(detail)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(barColor)
                }

                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(theme.tertiaryBackground)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(barColor)
                            .frame(width: geometry.size.width * clampedFraction)
                    }
                }
                .frame(height: 4)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Hugging Face Import Sheet

/// Modal that lets users paste a Hugging Face URL or repo id and surface
/// a friendly error when the repo isn't MLX-compatible. On success, the
/// caller routes the resolved repo id back into the search field, which
/// triggers the existing `fetchRemoteMLXModels` resolution path
private struct HuggingFaceImportSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    let onImported: (String) -> Void

    @State private var inputText: String = ""
    @State private var errorMessage: String? = nil
    @State private var isResolving = false

    private var trimmedInput: String {
        inputText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSubmit: Bool {
        !isResolving && ModelManager.parseHuggingFaceRepoId(from: trimmedInput) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            VStack(alignment: .leading, spacing: 16) {
                explainer
                inputField
                if let errorMessage {
                    errorBanner(errorMessage)
                }
            }
            .padding(20)

            Divider()
            footer
        }
        .frame(width: 460)
        .background(theme.primaryBackground)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("🤗")
                .font(.system(size: 18))
            VStack(alignment: .leading, spacing: 2) {
                Text("Import from Hugging Face", bundle: .module)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Text("Paste a model URL or repo id", bundle: .module)
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
            }
            Spacer()
            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.tertiaryText)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(theme.tertiaryBackground))
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var explainer: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(theme.accentColor)
                .padding(.top, 1)
            Text(
                "Osaurus only runs MLX models. Try a repo from `OsaurusAI` or `mlx-community`.",
                bundle: .module
            )
            .font(.system(size: 12))
            .foregroundColor(theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.accentColor.opacity(0.08))
        )
    }

    private var inputField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Repository", bundle: .module)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(theme.tertiaryText)
                .textCase(.uppercase)

            TextField(
                "OsaurusAI/gemma-4-E2B-it-8bit",
                text: $inputText,
                onCommit: submit
            )
            .textFieldStyle(.plain)
            .font(.system(size: 13, design: .monospaced))
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.tertiaryBackground.opacity(0.6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(theme.cardBorder, lineWidth: 1)
                    )
            )
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundColor(.orange)
                .padding(.top, 1)
            Text(message)
                .font(.system(size: 12))
                .foregroundColor(theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.orange.opacity(0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.orange.opacity(0.3), lineWidth: 1)
                )
        )
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button(action: { dismiss() }) {
                Text("Cancel", bundle: .module)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(theme.secondaryText)
            }
            .buttonStyle(PlainButtonStyle())
            .keyboardShortcut(.cancelAction)

            Button(action: submit) {
                HStack(spacing: 6) {
                    if isResolving {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(0.5)
                            .frame(width: 12, height: 12)
                    }
                    Text("Import", bundle: .module)
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(canSubmit ? theme.accentColor : theme.accentColor.opacity(0.4))
                )
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(!canSubmit)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func submit() {
        guard let repoId = ModelManager.parseHuggingFaceRepoId(from: trimmedInput) else {
            errorMessage = L(
                "That doesn't look like a Hugging Face repo. Use the format org/repo or paste a huggingface.co URL."
            )
            return
        }
        errorMessage = nil
        isResolving = true
        Task { @MainActor in
            let resolved = await ModelManager.shared.resolveModelIfMLXCompatible(byRepoId: repoId)
            isResolving = false
            if resolved != nil {
                onImported(repoId)
            } else {
                errorMessage = L(
                    "This repo doesn't appear to be MLX-compatible. Try a model from mlx-community or one with “-mlx” in its name."
                )
            }
        }
    }
}

#Preview {
    ModelDownloadView()
}
