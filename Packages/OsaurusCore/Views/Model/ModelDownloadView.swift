//
//  ModelDownloadView.swift
//  osaurus
//
//  Created by Terence on 8/17/25.
//

import AppKit
import Foundation
import SwiftUI

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

    /// Current search query text
    @State private var searchText: String = ""

    /// Currently selected tab (All, Suggested, or Downloaded)
    @State private var selectedTab: ModelListTab = .all

    /// Debounce task to prevent excessive API calls during typing
    @State private var searchDebounceTask: Task<Void, Never>? = nil

    /// Model to show in the detail sheet
    @State private var modelToShowDetails: MLXModel? = nil

    /// Content has appeared (for entrance animation)
    @State private var hasAppeared = false

    /// Filter state
    @State private var filterState = ModelManager.ModelFilterState()
    @State private var showFilterPopover = false

    // MARK: - Deep Link Support

    /// Optional model ID for deep linking (e.g., from URL schemes)
    var deeplinkModelId: String? = nil

    /// Optional file path for deep linking
    var deeplinkFile: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            // Header with search and tabs
            headerView
                .opacity(hasAppeared ? 1 : 0)
                .offset(y: hasAppeared ? 0 : -10)
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: hasAppeared)

            // System status bar
            SystemStatusBar(
                totalMemoryGB: systemMonitor.totalMemoryGB,
                usedMemoryGB: systemMonitor.usedMemoryGB,
                availableStorageGB: systemMonitor.availableStorageGB,
                totalStorageGB: systemMonitor.totalStorageGB
            )
            .opacity(hasAppeared ? 1 : 0)

            // Model list
            modelListView
                .opacity(hasAppeared ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.primaryBackground)
        .environment(\.theme, themeManager.currentTheme)
        .onAppear {
            // If invoked via deeplink, prefill search and ensure the model is visible
            if let modelId = deeplinkModelId, !modelId.isEmpty {
                searchText = modelId.split(separator: "/").last.map(String.init) ?? modelId
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
            // Debounce remote search to avoid spamming the API
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
    }

    // MARK: - Header View

    private var headerView: some View {
        ManagerHeaderWithTabs(
            title: L("Models"),
            subtitle: "\(completedDownloadedModelsCount) downloaded • \(modelManager.totalDownloadedSizeString)"
        ) {
            HStack(spacing: 12) {
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
                        Text("Filter", bundle: .module)
                            .font(.system(size: 13, weight: .medium))
                        if filterState.isActive {
                            Circle()
                                .fill(theme.accentColor)
                                .frame(width: 6, height: 6)
                        }
                    }
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
                    .all: filteredModels.count,
                    .suggested: filteredSuggestedModels.count,
                    .downloaded: completedDownloadedModelsCount,
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

    private var filterPopoverView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Filters", bundle: .module)
                        .font(.system(size: 14, weight: .bold))
                    Spacer()
                    if filterState.isActive {
                        Button {
                            filterState.reset()
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
                                filterState.typeFilter = filterState.typeFilter.isLLM ? .all : .llm
                            }
                            FilterChip(label: "VLM", isSelected: filterState.typeFilter.isVLM) {
                                filterState.typeFilter = filterState.typeFilter.isVLM ? .all : .vlm
                            }
                        }
                    }

                    FilterSection(title: "Model Size") {
                        FlowLayout(spacing: 8) {
                            ForEach(ModelManager.ModelFilterState.SizeCategory.allCases) { cat in
                                FilterChip(label: cat.rawValue, isSelected: filterState.sizeCategory == cat) {
                                    filterState.sizeCategory = filterState.sizeCategory == cat ? nil : cat
                                }
                            }
                        }
                    }

                    FilterSection(title: "Parameters") {
                        HStack(spacing: 8) {
                            ForEach(ModelManager.ModelFilterState.ParamCategory.allCases) { cat in
                                FilterChip(label: cat.rawValue, isSelected: filterState.paramCategory == cat) {
                                    filterState.paramCategory = filterState.paramCategory == cat ? nil : cat
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
                                        filterState.family = filterState.family == fam ? nil : fam
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
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
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

        var body: some View {
            Button(action: action) {
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(isSelected ? theme.accentColor : theme.tertiaryBackground.opacity(0.4))
                    )
                    .foregroundColor(isSelected ? .white : theme.secondaryText)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(theme.primaryBorder.opacity(isSelected ? 0 : 0.1), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Model List View

    /// Main content area with scrollable model list
    private var modelListView: some View {
        Group {
            if modelManager.isLoadingModels && displayedModels.isEmpty {
                loadingState
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        if !modelManager.deprecationNotices.isEmpty {
                            deprecationBanner
                        }

                        if displayedModels.isEmpty {
                            emptyState
                        } else {
                            ForEach(Array(displayedModels.enumerated()), id: \.element.id) { index, model in
                                ModelRowView(
                                    model: model,
                                    downloadState: modelManager.effectiveDownloadState(for: model),
                                    metrics: modelManager.downloadMetrics[model.id],
                                    totalMemoryGB: systemMonitor.totalMemoryGB,
                                    onViewDetails: { modelToShowDetails = model },
                                    onCancel: { modelManager.cancelDownload(model.id) },
                                    animationIndex: index
                                )
                            }
                        }
                    }
                    .padding(24)
                }
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

            Text("Some downloaded models have been replaced with improved OsaurusAI versions that fix known bugs.", bundle: .module)
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
        case .all, .suggested:
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
        case .suggested:
            return L("No recommended models")
        case .downloaded:
            return L("No downloaded models")
        }
    }

    // MARK: - Model Filtering

    private var filteredModels: [MLXModel] {
        let searched = SearchService.filterModels(modelManager.availableModels, with: searchText)
        let filtered = filterState.apply(to: searched)
        return filtered.sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    /// Suggested (curated) models filtered by current search text and filters
    private var filteredSuggestedModels: [MLXModel] {
        let searched = SearchService.filterModels(modelManager.suggestedModels, with: searchText)
        let filtered = filterState.apply(to: searched)
        return filtered.sorted { lhs, rhs in
            // Top suggestions first
            if lhs.isTopSuggestion != rhs.isTopSuggestion {
                return lhs.isTopSuggestion
            }
            // Then alphabetically
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    /// Downloaded tab contents: include active downloads at the top, then completed ones
    private var filteredDownloadedModels: [MLXModel] {
        let all = modelManager.deduplicatedModels()
        // Active: in-progress downloads regardless of on-disk completion
        let active: [MLXModel] = all.filter { m in
            switch modelManager.downloadStates[m.id] ?? .notStarted {
            case .downloading: return true
            default: return false
            }
        }
        // Completed: on-disk completed models
        let completed: [MLXModel] = all.filter { $0.isDownloaded }
        // Merge with active first; de-dupe by lowercase id while preserving order
        var seen: Set<String> = []
        var merged: [MLXModel] = []
        for m in active + completed {
            let k = m.id.lowercased()
            if !seen.contains(k) {
                seen.insert(k)
                merged.append(m)
            }
        }
        // Apply search filter
        let searched = SearchService.filterModels(merged, with: searchText)
        let filtered = filterState.apply(to: searched)

        // Sort: active first, then by name
        return filtered.sorted { lhs, rhs in
            let lhsActive: Bool = {
                if case .downloading = (modelManager.downloadStates[lhs.id] ?? .notStarted) { return true }
                return false
            }()
            let rhsActive: Bool = {
                if case .downloading = (modelManager.downloadStates[rhs.id] ?? .notStarted) { return true }
                return false
            }()
            if lhsActive != rhsActive { return lhsActive && !rhsActive }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    /// Count of completed (on-disk) downloaded models respecting current search and filters
    private var completedDownloadedModelsCount: Int {
        let completed = modelManager.deduplicatedModels().filter { $0.isDownloaded }
        let searched = SearchService.filterModels(Array(completed), with: searchText)
        let filtered = filterState.apply(to: searched)
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

    /// Models to display based on the currently selected tab
    private var displayedModels: [MLXModel] {
        let baseModels: [MLXModel]
        switch selectedTab {
        case .all:
            baseModels = filteredModels
        case .suggested:
            baseModels = filteredSuggestedModels
        case .downloaded:
            baseModels = filteredDownloadedModels
        }

        return baseModels
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

            VStack(alignment: .leading, spacing: 3) {
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

#Preview {
    ModelDownloadView()
}
