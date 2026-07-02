//
//  ModelDownloadView.swift
//  osaurus
//
//  Created by Terence on 8/17/25.
//

import AppKit
import Combine
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
    case newest
    case oldest

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .recommended: return L("Recommended")
        case .downloadsDesc: return L("Most Downloaded")
        case .nameAsc: return L("Name (A–Z)")
        case .compatibility: return L("Compatibility")
        case .sizeAsc: return L("Size (Smallest first)")
        case .sizeDesc: return L("Size (Largest first)")
        case .newest: return L("Newest")
        case .oldest: return L("Oldest")
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
        case .newest: return "calendar.badge.clock"
        case .oldest: return "calendar"
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

    /// Currently selected tab (On Device or Catalog). The initial value is
    /// overridden once on first appear by `chooseInitialTabIfNeeded()`.
    @State private var selectedTab: ModelListTab = .all

    /// Ensures the smart initial-tab selection runs only on first appear so
    /// it never overrides the user's manual tab navigation.
    @State private var didChooseInitialTab = false

    /// Debounce task for the remote Hugging Face fetch.
    @State private var searchDebounceTask: Task<Void, Never>? = nil

    /// Debounce task for the local filter / animation trigger.
    @State private var localSearchDebounceTask: Task<Void, Never>? = nil

    /// Model to show in the detail sheet
    @State private var modelToShowDetails: MLXModel? = nil

    /// Drives the "model can't be used" alert shown when a greyed (non-MLX)
    /// card is tapped, instead of opening its detail sheet.
    @State private var unsupportedModelName: String? = nil

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

    /// Index of the leading Top Picks card the edge arrows scroll to. Desktop
    /// mice can't scroll horizontally, so the carousel is driven by these
    /// buttons; the index is clamped to the model count on every step.
    @State private var topPicksIndex = 0

    /// Which edge arrows the Top Picks carousel can offer, derived from the live
    /// scroll geometry so each arrow hides the moment there's no room to scroll
    /// that way (e.g. the right arrow disappears at the far right).
    @State private var topPicksCanScrollLeft = false
    @State private var topPicksCanScrollRight = false

    /// Cached output of `gridLists`. We used to recompute four filter +
    /// sort passes from a body computed property, which would re-run on
    /// every `modelManager.objectWillChange` publish (one per download
    /// progress chunk). The snapshot is now refreshed only when the
    /// inputs it actually depends on change (filter state, sort option,
    /// selected tab, debounced search text, or a throttled
    /// `modelManager` publish).
    @State private var gridListsSnapshot = GridLists(
        suggested: [],
        others: [],
        downloaded: [],
        displayed: []
    )

    /// Coalesces bursts of `modelManager.objectWillChange` publishes
    /// (e.g. download progress) so we recompute `gridLists` at most once
    /// per ~150 ms instead of per chunk.
    @State private var gridListsRefreshTask: Task<Void, Never>?

    // MARK: - Deep Link Support

    /// Optional model ID for deep linking (e.g., from URL schemes)
    var deeplinkModelId: String? = nil

    /// Optional file path for deep linking
    var deeplinkFile: String? = nil

    var body: some View {
        // Render from the cached snapshot rather than recomputing the
        // filter+sort pipeline per body pass. The snapshot is refreshed
        // by `.onAppear`, by `.onChange` of each user-driven input
        // (filter / sort / tab / debounced search), and by a throttled
        // `.onReceive(modelManager)` to absorb the high-frequency
        // download-progress publishes.
        let lists = gridListsSnapshot
        return VStack(spacing: 0) {
            headerView(lists: lists)
                .managerHeaderEntrance(hasAppeared: hasAppeared)

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

            chooseInitialTabIfNeeded()

            // Animate content appearance before heavy operations
            withAnimation(.easeOut(duration: 0.25).delay(0.05)) {
                hasAppeared = true
            }

            // Defer heavy fetch operation to prevent initial jank
            Task {
                try? await Task.sleep(nanoseconds: 150_000_000)  // 150ms delay
                modelManager.fetchRemoteMLXModels(searchText: searchText)
            }

            refreshGridLists()
        }
        .onDisappear {
            gridListsRefreshTask?.cancel()
            gridListsRefreshTask = nil
        }
        .onChange(of: selectedTab) { _, _ in
            refreshGridLists()
        }
        .onChange(of: sortOption) { _, _ in refreshGridLists() }
        .onChange(of: filterState) { _, _ in refreshGridLists() }
        .onChange(of: debouncedSearchText) { _, _ in refreshGridLists() }
        .onReceive(
            modelManager.objectWillChange
                .throttle(for: .milliseconds(200), scheduler: DispatchQueue.main, latest: true)
        ) { _ in
            scheduleGridListsRefresh()
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
            // Family cards open with their full variant list so the sheet
            // can offer the Versions picker; single-build models get an
            // empty/1-element list, which hides it.
            ModelDetailView(
                model: model,
                variants: gridListsSnapshot.variantsByFamily[
                    ModelMetadataParser.familyKey(from: model.id)
                ] ?? []
            )
            .environment(\.theme, themeManager.currentTheme)
        }
        .sheet(isPresented: $showImportSheet) {
            HuggingFaceImportSheet(
                onImported: { repoId in
                    showImportSheet = false
                    selectedTab = .all
                    searchText = repoId
                },
                onImportedImage: { _ in
                    // Image bundles now live in the dedicated Image Generation
                    // tab — hand off to its Models sub-tab.
                    showImportSheet = false
                    ManagementStateManager.shared.selectedTab = .imageGeneration
                    ManagementStateManager.shared.imageGenerationSubTabRequest =
                        ImageGenerationTab.models.rawValue
                }
            )
            .environment(\.theme, themeManager.currentTheme)
        }
        .themedAlert(
            modelManager.downloadAlert?.title ?? L("Model download failed"),
            isPresented: Binding(
                get: { modelManager.downloadAlert != nil },
                set: { if !$0 { modelManager.downloadAlert = nil } }
            ),
            message: modelManager.downloadAlert.map { info in
                "\(info.message)\n\nDetails (tap Copy to share):\n\(info.details)"
            },
            buttons: [
                .cancel(L("Copy details")) {
                    if let details = modelManager.downloadAlert?.details {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(details, forType: .string)
                    }
                    modelManager.downloadAlert = nil
                },
                .primary(L("OK")) { modelManager.downloadAlert = nil },
            ]
        )
        .themedAlert(
            L("Model not supported"),
            isPresented: Binding(
                get: { unsupportedModelName != nil },
                set: { if !$0 { unsupportedModelName = nil } }
            ),
            message: L(
                "\(unsupportedModelName ?? "") isn't an MLX model, so it can't be used in Osaurus. The local engine runs MLX-format models only."
            ),
            primaryButton: .primary(L("OK")) { unsupportedModelName = nil }
        )
    }

    // MARK: - Header View

    private func headerView(lists: GridLists) -> some View {
        ManagerHeaderWithTabs(
            title: L("Models"),
            subtitle: L("\(completedDownloadedModelsCount) downloaded • \(modelManager.totalDownloadedSizeString)")
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
                    .localizedHelp("Refresh OsaurusAI models from Hugging Face")
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
                .localizedHelp("Import a model from Hugging Face")

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
                    : nil
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
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.6)
                        .foregroundColor(theme.tertiaryText)
                        .textCase(.uppercase)
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
                    FilterSection(title: L("Model Type")) {
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

                    FilterSection(title: L("Model Size")) {
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

                    FilterSection(title: L("Parameters")) {
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
                    FilterSection(title: L("Performance")) {
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
                    FilterSection(title: L("Model Family")) {
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

    /// A single model card wired to the manager's download actions. Shared
    /// by the catalog grid and the Recommended carousel so their behavior
    /// stays identical. Catalog cards are family cards (one per model, all
    /// precision builds behind it); On Device stays one card per bundle, so
    /// the version indicator only applies on the Catalog tab.
    private func modelCard(for model: MLXModel) -> some View {
        let variantCount =
            selectedTab == .all
            ? (gridListsSnapshot.variantsByFamily[
                ModelMetadataParser.familyKey(from: model.id)
            ]?.count ?? 1)
            : 1
        return ModelRowView(
            content: ModelCardContent(
                model: model,
                totalMemoryGB: systemMonitor.totalMemoryGB,
                variantCount: variantCount
            ),
            downloadState: modelManager.effectiveDownloadState(for: model),
            metrics: modelManager.downloadMetrics[model.id],
            onViewDetails: { modelToShowDetails = model },
            onUnsupportedTap: { unsupportedModelName = model.name },
            onCancel: { modelManager.cancelDownload(model.id) },
            onPause: { modelManager.pauseDownload(model.id) },
            onResume: { modelManager.resumeDownload(model.id) }
        )
    }

    /// Grid of ModelRowView cards. Surviving cells (same `id` before and
    /// after a filter change) slide to their new grid position; cells
    /// that drop out scale-fade away; new cells scale-fade in. Driven by
    /// the shared `gridDiffAnimation(token:)` modifier below.
    private func modelGrid(models: [MLXModel]) -> some View {
        LazyVGrid(columns: gridColumns, spacing: 20) {
            ForEach(models, id: \.id) { model in
                modelCard(for: model)
                    .gridDiffCell()
            }
        }
        .gridDiffAnimation(token: gridChangeToken)
    }

    /// Single-row, horizontally scrolling strip of curated top picks shown
    /// at the top of the Catalog when the user isn't searching or filtering.
    private func topPicksCarousel(_ models: [MLXModel]) -> some View {
        let ids = models.map(\.id)
        // One card width plus the LazyHStack spacing — each arrow press advances
        // by roughly one viewport, anchoring the target card to the leading edge.
        let step = 2
        return VStack(alignment: .leading, spacing: 12) {
            Text("Top Picks", bundle: .module)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(theme.tertiaryText)
                .textCase(.uppercase)
                .padding(.horizontal, 2)

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 12) {
                        ForEach(models, id: \.id) { model in
                            modelCard(for: model)
                                .frame(width: 280)
                                .id(model.id)
                        }
                    }
                    .padding(.horizontal, 2)
                    .padding(.bottom, 4)
                }
                // Derive arrow visibility from the actual scroll position so an
                // arrow hides the instant there's no more room to scroll its way.
                // The tolerance absorbs the 2pt content inset (a leading-anchored
                // scroll to the first card lands at offset ~2, not 0) plus rounding.
                .onScrollGeometryChange(for: TopPicksScrollEdges.self) { geo in
                    let edgeTolerance: CGFloat = 4
                    let maxOffsetX = geo.contentSize.width - geo.containerSize.width
                    return TopPicksScrollEdges(
                        canScrollLeft: geo.contentOffset.x > edgeTolerance,
                        canScrollRight: geo.contentOffset.x < maxOffsetX - edgeTolerance
                    )
                } action: { _, edges in
                    withAnimation(.easeOut(duration: 0.2)) {
                        topPicksCanScrollLeft = edges.canScrollLeft
                        topPicksCanScrollRight = edges.canScrollRight
                    }
                }
                .overlay(alignment: .leading) {
                    if topPicksCanScrollLeft {
                        topPicksArrow("chevron.left") {
                            scrollTopPicks(to: topPicksIndex - step, ids: ids, proxy: proxy)
                        }
                        .padding(.leading, 6)
                        .transition(.opacity)
                    }
                }
                .overlay(alignment: .trailing) {
                    if topPicksCanScrollRight {
                        topPicksArrow("chevron.right") {
                            scrollTopPicks(to: topPicksIndex + step, ids: ids, proxy: proxy)
                        }
                        .padding(.trailing, 6)
                        .transition(.opacity)
                    }
                }
            }
            .onChange(of: models.map(\.id)) { _, _ in
                // Reset when the curated set changes so the arrows match the
                // freshly-rendered, left-aligned carousel.
                topPicksIndex = 0
            }
        }
    }

    /// Circular accent-filled edge button for the Top Picks carousel.
    private func topPicksArrow(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 30, height: 30)
                .background(
                    Circle()
                        .fill(theme.accentColor)
                        .shadow(color: theme.shadowColor.opacity(0.3), radius: 5, x: 0, y: 2)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    /// Which directions the Top Picks carousel can still scroll, recomputed from
    /// the live scroll geometry. Equatable so `onScrollGeometryChange` only fires
    /// the action when an edge actually flips.
    private struct TopPicksScrollEdges: Equatable {
        var canScrollLeft = false
        var canScrollRight = false
    }

    private func scrollTopPicks(to index: Int, ids: [String], proxy: ScrollViewProxy) {
        guard !ids.isEmpty else { return }
        let clamped = max(0, min(ids.count - 1, index))
        withAnimation(.easeOut(duration: 0.25)) {
            topPicksIndex = clamped
            proxy.scrollTo(ids[clamped], anchor: .leading)
        }
    }

    /// Catalog body: a Top Picks carousel over the newest-first grid of the
    /// rest of the catalog while browsing; a single flat grid while searching
    /// or filtering (so those span the whole catalog).
    @ViewBuilder
    private func catalogContent(lists: GridLists) -> some View {
        let isBrowsing =
            debouncedSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !filterState.isActive
        if isBrowsing {
            VStack(alignment: .leading, spacing: 16) {
                if lists.suggested.isEmpty {
                    modelGrid(models: lists.others)
                } else {
                    topPicksCarousel(lists.suggested)
                    modelGridSection(
                        title: L("Our Curated Models"),
                        models: lists.others,
                        isFirst: true
                    )
                }
                imageModelsLinkRow
            }
        } else {
            modelGrid(models: lists.displayed)
        }
    }

    /// Inline pointer to the dedicated Images pane. Replaces the old fake
    /// "Images" tab (which navigated away and snapped the selector back) with
    /// an honest link at the end of the catalog.
    private var imageModelsLinkRow: some View {
        Button {
            ManagementStateManager.shared.selectedTab = .imageGeneration
            ManagementStateManager.shared.imageGenerationSubTabRequest =
                ImageGenerationTab.models.rawValue
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(theme.secondaryText)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Looking for image models?", bundle: .module)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                    Text(
                        "Image generation and editing models live in Images settings.",
                        bundle: .module
                    )
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
                }

                Spacer(minLength: 8)

                HStack(spacing: 4) {
                    Text("Open Images", bundle: .module)
                        .font(.system(size: 12, weight: .medium))
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundColor(theme.accentColor)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(theme.tertiaryBackground.opacity(0.4))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(theme.cardBorder.opacity(0.6), lineWidth: 1)
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(PlainButtonStyle())
        .padding(.top, 4)
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
                        .padding(.bottom, 12)

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
                                    catalogContent(lists: lists)
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
            SearchField(text: $searchText, placeholder: "Search models", width: 240, compact: true)

            Spacer()

            // Sort button
            Button {
                showSortPopover.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 12))
                    if sortOption == .recommended {
                        Text("Sort", bundle: .module)
                            .font(.system(size: 12, weight: .medium))
                    } else {
                        Text("Sort: ", bundle: .module)
                            .font(.system(size: 12, weight: .medium))
                            + Text(sortOption.displayName)
                            .font(.system(size: 12, weight: .semibold))
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
            .localizedHelp("Sort models")

            // Filter button
            Button {
                showFilterPopover.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(
                        systemName: filterState.isActive
                            ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle"
                    )
                    .font(.system(size: 12))
                    if let active = activeFilterSummary {
                        Text("Filter: ", bundle: .module)
                            .font(.system(size: 12, weight: .medium))
                            + Text(active)
                            .font(.system(size: 12, weight: .semibold))
                    } else {
                        Text("Filter", bundle: .module)
                            .font(.system(size: 12, weight: .medium))
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
                    Task { await modelManager.deleteModel(oldModel) }
                }
            case .downloading:
                pillButton("Cancel", color: theme.secondaryText, bg: theme.tertiaryBackground) {
                    modelManager.cancelDownload(notice.newId)
                }
            case .paused:
                pillButton("Resume", color: .white, bg: theme.accentColor) {
                    modelManager.resumeDownload(notice.newId)
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
        _ title: LocalizedStringKey,
        icon: String? = nil,
        color: Color,
        bg: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Group {
                if let icon {
                    Label {
                        Text(localized: title)
                    } icon: {
                        Image(systemName: icon)
                    }
                } else {
                    Text(localized: title)
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
            } else if selectedTab == .downloaded {
                Button(action: {
                    withAnimation(.easeOut(duration: 0.2)) { selectedTab = .all }
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "square.grid.2x2")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Browse Catalog", bundle: .module)
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(theme.accentColor))
                }
                .buttonStyle(PlainButtonStyle())
                .padding(.top, 4)
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
            return "internaldrive"
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
            return L("No models on device yet")
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
        /// Every catalog build keyed by `ModelMetadataParser.familyKey`,
        /// built from the unfiltered merged catalog so the detail sheet's
        /// variant picker always shows the full family even while the grid
        /// is searched or filtered.
        var variantsByFamily: [String: [MLXModel]] = [:]
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

    /// Value snapshot of everything `makeGridLists` reads, captured on the main
    /// actor so the filter/sort pipeline can run off it on a background task
    /// without touching view or manager state.
    struct GridListInput: Sendable {
        let availableModels: [MLXModel]
        let suggestedModels: [MLXModel]
        let deduplicatedModels: [MLXModel]
        let downloadStates: [String: DownloadState]
        let searchText: String
        let filterState: ModelManager.ModelFilterState
        let selectedTab: ModelListTab
        let sortOption: ModelSortOption
        let totalMemoryGB: Double
    }

    /// Snapshot the current inputs. Must run on the main actor.
    private func makeGridListInput() -> GridListInput {
        GridListInput(
            availableModels: modelManager.availableModels,
            suggestedModels: modelManager.suggestedModels,
            deduplicatedModels: modelManager.deduplicatedModels(),
            downloadStates: modelManager.downloadStates,
            searchText: debouncedSearchText,
            filterState: filterState,
            selectedTab: selectedTab,
            sortOption: sortOption,
            totalMemoryGB: systemMonitor.totalMemoryGB
        )
    }

    // MARK: - Family grouping

    /// One card per model family: precision/quant variants of the same model
    /// (MXFP4 vs MXFP8 vs QAT vs JANGTQ…) collapse into a single
    /// representative card. `models` must already be searched/filtered/sorted;
    /// each family keeps the position of its first-listed variant so the
    /// active sort still drives card order.
    nonisolated static func groupIntoFamilyCards(
        _ models: [MLXModel],
        totalMemoryGB: Double,
        downloadStates: [String: DownloadState]
    ) -> [MLXModel] {
        var order: [String] = []
        var buckets: [String: [MLXModel]] = [:]
        for model in models {
            let key = ModelMetadataParser.familyKey(from: model.id)
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(model)
        }
        return order.compactMap { key in
            buckets[key].map {
                defaultFamilyVariant(
                    among: $0,
                    totalMemoryGB: totalMemoryGB,
                    downloadStates: downloadStates
                )
            }
        }
    }

    /// The build a family card represents (and the one its Download button
    /// installs by default). Anything the user already owns or is actively
    /// downloading wins; otherwise the best build for this Mac: better RAM
    /// fit first, then curated over auto-fetched, Top Pick over plain, then
    /// highest precision (largest download) among equals, newest as the
    /// final tiebreak.
    nonisolated static func defaultFamilyVariant(
        among variants: [MLXModel],
        totalMemoryGB: Double,
        downloadStates: [String: DownloadState]
    ) -> MLXModel {
        func isActive(_ m: MLXModel) -> Bool {
            switch downloadStates[m.id] ?? .notStarted {
            case .downloading, .paused: return true
            default: return false
            }
        }
        func compatRank(_ m: MLXModel) -> Int {
            switch m.compatibility(totalMemoryGB: totalMemoryGB) {
            case .compatible: return 0
            case .tight: return 1
            case .tooLarge: return 2
            case .unknown: return 3
            }
        }
        let curatedIds = ModelManager.curatedSuggestedIds
        let best = variants.min { lhs, rhs in
            if isActive(lhs) != isActive(rhs) { return isActive(lhs) }
            if lhs.isDownloaded != rhs.isDownloaded { return lhs.isDownloaded }
            let lc = compatRank(lhs)
            let rc = compatRank(rhs)
            if lc != rc { return lc < rc }
            let lCurated = curatedIds.contains(lhs.id.lowercased())
            let rCurated = curatedIds.contains(rhs.id.lowercased())
            if lCurated != rCurated { return lCurated }
            if lhs.isTopSuggestion != rhs.isTopSuggestion { return lhs.isTopSuggestion }
            let ls = lhs.totalSizeEstimateBytes ?? 0
            let rs = rhs.totalSizeEstimateBytes ?? 0
            if ls != rs { return ls > rs }
            switch (lhs.releasedAt, rhs.releasedAt) {
            case let (l?, r?) where l != r: return l > r
            case (_?, nil): return true
            case (nil, _?): return false
            default: break
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        return best ?? variants[0]
    }

    /// Consolidates all list computations. Pure over `GridListInput` so it can
    /// run off the main thread — the search/filter/sort pass over a large model
    /// catalog otherwise blocked the main thread on every input change.
    nonisolated static func makeGridLists(_ input: GridListInput) -> GridLists {
        let mem = input.totalMemoryGB
        let sortOption = input.sortOption
        let filterState = input.filterState
        let searchText = input.searchText
        let downloadStates = input.downloadStates

        func isActive(_ m: MLXModel) -> Bool {
            switch downloadStates[m.id] ?? .notStarted {
            case .downloading, .paused: return true
            default: return false
            }
        }
        // True when the model is on disk or actively downloading/paused — keeps
        // imported/non-curated models visible in the All tab.
        func isUserModel(_ m: MLXModel) -> Bool {
            m.isDownloaded || isActive(m)
        }
        func compatibilityRank(_ m: MLXModel) -> Int {
            switch m.compatibility(totalMemoryGB: mem) {
            case .compatible: return 0
            case .tight: return 1
            case .tooLarge: return 2
            case .unknown: return 3
            }
        }
        // Newest-first by release date (nil dates last), name as the stable
        // tiebreak. Shared by the catalog, Top Picks, and Recommended sorts.
        func newestFirst(_ lhs: MLXModel, _ rhs: MLXModel) -> Bool {
            switch (lhs.releasedAt, rhs.releasedAt) {
            case let (l?, r?):
                if l != r { return l > r }
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                break
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        func applySort(_ models: [MLXModel]) -> [MLXModel] {
            switch sortOption {
            case .recommended, .nameAsc:
                return models.sorted {
                    $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
            case .downloadsDesc:
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
            case .newest:
                return models.sorted(by: newestFirst)
            case .oldest:
                return models.sorted { lhs, rhs in
                    switch (lhs.releasedAt, rhs.releasedAt) {
                    case let (l?, r?):
                        if l != r { return l < r }
                    case (_?, nil):
                        return true
                    case (nil, _?):
                        return false
                    case (nil, nil):
                        break
                    }
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
            }
        }
        // Catalog default ordering is newest-first; an explicit sort choice
        // takes over via `applySort`, matching `sortedSuggested`'s convention.
        func sortedCatalog(_ models: [MLXModel]) -> [MLXModel] {
            sortOption == .recommended ? models.sorted(by: newestFirst) : applySort(models)
        }
        func sortedSuggested(_ filtered: [MLXModel]) -> [MLXModel] {
            if sortOption != .recommended {
                return applySort(filtered)
            }
            let curatedIds = ModelManager.curatedSuggestedIds
            return filtered.sorted { lhs, rhs in
                let lhsCurated = curatedIds.contains(lhs.id.lowercased())
                let rhsCurated = curatedIds.contains(rhs.id.lowercased())
                if lhsCurated != rhsCurated { return lhsCurated }

                if lhsCurated && lhs.isTopSuggestion != rhs.isTopSuggestion {
                    return lhs.isTopSuggestion
                }

                return newestFirst(lhs, rhs)
            }
        }
        func computeDownloadedList() -> [MLXModel] {
            let all = input.deduplicatedModels
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
            let searched = SearchService.filterModels(merged, with: searchText)
            let filtered = filterState.apply(to: searched, totalMemoryGB: mem)
            let activeGroup = applySort(filtered.filter(isActive))
            let restGroup = applySort(filtered.filter { !isActive($0) })
            return activeGroup + restGroup
        }

        // All tab = OsaurusAI catalog + models the user owns/is downloading +
        // (when searching) anything matching the query. without the latter two,
        // imported/pasted repos inserted into `availableModels` are filtered
        // out and never appear
        let hasQuery = !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let allTabBase = input.availableModels.filter { model in
            isOsaurusAI(model) || isUserModel(model) || hasQuery
        }
        let osaurusSuggested = input.suggestedModels.filter { isOsaurusAI($0) }

        let availSearched = SearchService.filterModels(allTabBase, with: searchText)
        let availFiltered = filterState.apply(to: availSearched, totalMemoryGB: mem)
        let allFiltered = sortedCatalog(availFiltered)

        let suggSearched = SearchService.filterModels(osaurusSuggested, with: searchText)
        let suggFiltered = filterState.apply(to: suggSearched, totalMemoryGB: mem)
        let recommended = sortedSuggested(suggFiltered)

        // The Top Picks carousel only exists under the default Recommended
        // sort. Any explicit sort merges the picks back into the grid so they
        // sort alongside everything else. The carousel itself is newest-first,
        // one card per family — precision siblings collapse into the variant
        // that suits this Mac best.
        let topPicks =
            sortOption == .recommended
            ? groupIntoFamilyCards(
                sortedCatalog(recommended.filter { $0.isTopSuggestion }),
                totalMemoryGB: mem,
                downloadStates: downloadStates
            )
            : []
        // Exclude by family, not id, so demoted precision siblings of a Top
        // Pick don't reappear as separate grid cards below the carousel.
        let topPickFamilies = Set(topPicks.map { ModelMetadataParser.familyKey(from: $0.id) })

        // The grid is the rest of the catalog — recommended non-top picks plus
        // everything else — deduped and ordered newest-first (or by the
        // explicit sort choice), then collapsed to one card per family.
        var seenCatalog: Set<String> = []
        var catalogRest: [MLXModel] = []
        for model in recommended + allFiltered {
            let key = model.id.lowercased()
            if topPickFamilies.contains(ModelMetadataParser.familyKey(from: model.id)) { continue }
            if seenCatalog.insert(key).inserted {
                catalogRest.append(model)
            }
        }
        let others = groupIntoFamilyCards(
            sortedCatalog(catalogRest),
            totalMemoryGB: mem,
            downloadStates: downloadStates
        )

        let downloaded = computeDownloadedList()

        // Full variant lists per family from the unfiltered merged catalog,
        // for the detail sheet's variant picker and the cards' "N versions"
        // indicator.
        var variantsByFamily: [String: [MLXModel]] = [:]
        var seenVariantIds: Set<String> = []
        for model in input.suggestedModels + input.availableModels {
            guard seenVariantIds.insert(model.id.lowercased()).inserted else { continue }
            variantsByFamily[ModelMetadataParser.familyKey(from: model.id), default: []].append(model)
        }

        let displayed: [MLXModel]
        switch input.selectedTab {
        case .all: displayed = topPicks + others
        case .downloaded: displayed = downloaded
        }

        // Warm disk-backed verdicts while still off the main actor. The catalog
        // cards (`ModelCardContent.init`) read `isVLM` and `isMLXFormat` during
        // SwiftUI body evaluation on the main thread; without this a cold cache
        // would fault config.json / safetensors-header reads per card on main
        // (the Sentry app-hang path). `makeGridLists` always runs inside a
        // `Task.detached`, so these reads stay off the main thread.
        for model in displayed {
            _ = model.isVLM
            _ = model.isMLXFormat
        }

        return GridLists(
            suggested: topPicks,
            others: others,
            downloaded: downloaded,
            displayed: displayed,
            variantsByFamily: variantsByFamily
        )
    }

    /// Eager refresh of the cached snapshot. Called from `.onAppear` and
    /// from every `.onChange` of a user-driven input — these flips
    /// should feel immediate. Inputs are snapshotted now (on the main actor);
    /// the filter/sort pass runs off the main thread and the result is applied
    /// back on main.
    private func refreshGridLists() {
        gridListsRefreshTask?.cancel()
        let input = makeGridListInput()
        gridListsRefreshTask = Task { @MainActor in
            let lists = await Task.detached(priority: .userInitiated) {
                Self.makeGridLists(input)
            }.value
            // A superseded task must not touch the snapshot or the handle —
            // the task that cancelled it now owns both.
            guard !Task.isCancelled else { return }
            applyGridLists(lists)
            gridListsRefreshTask = nil
        }
    }

    /// Swap in a freshly computed grid snapshot, animating the mosaic when the
    /// membership change is bounded.
    ///
    /// The heavy filter/sort already ran off-main (`makeGridLists`), so the
    /// `withAnimation` closure is only the assignment — there is no synchronous
    /// recompute inside the transaction (the shape that caused earlier
    /// `withAnimation` app hangs). The guard is purely about transition volume:
    /// animating a wholesale swap (e.g. clearing a search to reveal the full
    /// catalog) would build and transition a large batch of cells in one spring
    /// transaction on the main thread — a hang risk, and not legible anyway —
    /// so past `maxAnimatedGridChurn` inserted+removed cells we swap instantly.
    /// Reorders of surviving cells are cheap and don't count, so a pure sort
    /// always animates.
    private func applyGridLists(_ lists: GridLists) {
        let churn = Self.membershipChurn(gridListsSnapshot.displayed, lists.displayed)
        if churn <= Self.maxAnimatedGridChurn {
            withAnimation(GridDiff.spring) {
                gridListsSnapshot = lists
            }
        } else {
            gridListsSnapshot = lists
        }
    }

    /// Above this many inserted + removed cells, a grid swap applies without the
    /// mosaic spring to keep the animation off the main thread's critical path.
    private static let maxAnimatedGridChurn = 40

    /// Count of models that must insert or remove between two lists. Survivors
    /// that merely change position are excluded — those animate cheaply and are
    /// the heart of the mosaic.
    private static func membershipChurn(_ a: [MLXModel], _ b: [MLXModel]) -> Int {
        let aIds = Set(a.map(\.id))
        let bIds = Set(b.map(\.id))
        return aIds.symmetricDifference(bIds).count
    }

    /// Debounced refresh for `modelManager.objectWillChange` bursts so
    /// the grid doesn't re-filter+sort on every download progress chunk.
    /// `.throttle` on the publisher already caps to ~5 Hz; the extra
    /// 50 ms sleep here coalesces any same-tick publishes. Inputs are
    /// snapshotted after the debounce (on main) so they reflect the latest
    /// state, then the pass runs off the main thread.
    private func scheduleGridListsRefresh() {
        guard gridListsRefreshTask == nil else { return }
        gridListsRefreshTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }
            let input = makeGridListInput()
            let lists = await Task.detached(priority: .userInitiated) {
                Self.makeGridLists(input)
            }.value
            // A superseded task must not touch the snapshot or the handle —
            // the task that cancelled it now owns both.
            guard !Task.isCancelled else { return }
            gridListsSnapshot = lists
            gridListsRefreshTask = nil
        }
    }

    /// Smart landing: open on "On Device" when the user already owns or is
    /// actively downloading a model, otherwise on the "Catalog" so new users
    /// see something to browse. Runs once on first appear and yields to a
    /// deep link (which pins the Catalog so the linked model is visible).
    private func chooseInitialTabIfNeeded() {
        guard !didChooseInitialTab else { return }
        didChooseInitialTab = true

        if let modelId = deeplinkModelId, !modelId.isEmpty {
            selectedTab = .all
            return
        }

        let hasOwnModels =
            modelManager.deduplicatedModels().contains { $0.isDownloaded }
            || modelManager.activeDownloadsCount > 0
        selectedTab = hasOwnModels ? .downloaded : .all
    }

    private static func isOsaurusAI(_ model: MLXModel) -> Bool {
        model.id.lowercased().hasPrefix("osaurusai/")
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
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
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
        .help(Text(localized: "Downloading \(activeCount) model\(activeCount == 1 ? "" : "s") – Click to view"))
    }
}

// MARK: - Hugging Face Import Sheet

/// Modal that lets users paste a Hugging Face URL or repo id and surface
/// a friendly error when the repo isn't MLX-compatible. On success, the
/// caller routes the resolved repo id back into the search field, which
/// triggers the existing `fetchRemoteMLXModels` resolution path
struct HuggingFaceImportSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    let onImported: (String) -> Void
    /// Called when the pasted repo is an image bundle, staged via the image
    /// store instead of the LLM path.
    let onImportedImage: (String) -> Void

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
            .keyboardShortcut(.cancelAction)
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
                "Paste an MLX language model (try `OsaurusAI` or `mlx-community`) or an mflux image model — each is routed to the right place automatically.",
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
            // Image bundles use a diffusers/mflux layout and a separate engine,
            // so route them to the image store before the LLM compatibility
            // check (which would reject them and stage to the wrong directory).
            if await ImageModelDownloadService.isImageRepo(repoId) {
                ImageModelDownloadService.shared.download(
                    repoId: repoId,
                    displayName: ImageModelDownload.directoryName(forRepoId: repoId)
                )
                isResolving = false
                onImportedImage(repoId)
                return
            }

            let resolved = await ModelManager.shared.resolveModelIfMLXCompatible(byRepoId: repoId)
            isResolving = false
            if resolved != nil {
                onImported(repoId)
            } else if repoId.lowercased().hasPrefix("osaurusai/") {
                errorMessage = L(
                    "That OsaurusAI model isn't in the registry. Pick one from the Recommended list."
                )
            } else if !repoId.lowercased().hasPrefix("mlx-community/")
                && !ModelManager.nameLooksLikeMLX(repoId)
            {
                errorMessage = L(
                    "Repos outside mlx-community must advertise an MLX-native artifact family in the repo name, such as MLX, MXFP, JANG, JANGTQ, or TurboQuant."
                )
            } else {
                errorMessage = L(
                    "This repo did not pass the MLX-compatible metadata/file check. Use an MLX, MXFP, JANG, JANGTQ, or TurboQuant repo with config, tokenizer, and model weights."
                )
            }
        }
    }
}

#if DEBUG && canImport(PreviewsMacros)
    #Preview {
        ModelDownloadView()
    }
#endif
