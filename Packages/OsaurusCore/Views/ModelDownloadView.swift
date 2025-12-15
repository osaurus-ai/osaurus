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
    @StateObject private var modelManager = ModelManager.shared

    /// Theme manager for consistent UI styling
    @StateObject private var themeManager = ThemeManager.shared

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

    /// Whether content has appeared (for entrance animation)
    @State private var hasAppeared = false

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
        VStack(spacing: 16) {
            // Title row
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Models")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundColor(theme.primaryText)

                    Text("\(completedDownloadedModelsCount) downloaded • \(modelManager.totalDownloadedSizeString)")
                        .font(.system(size: 14))
                        .foregroundColor(theme.secondaryText)
                }

                Spacer()
            }

            // Tabs + Search row
            HStack(spacing: 16) {
                AnimatedTabSelector(
                    selection: $selectedTab,
                    counts: [
                        .all: filteredModels.count,
                        .suggested: filteredSuggestedModels.count,
                        .downloaded: completedDownloadedModelsCount,
                    ]
                )

                Spacer()

                SearchField(text: $searchText, placeholder: "Search models")
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 16)
        .background(theme.secondaryBackground)
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
                        if displayedModels.isEmpty {
                            emptyState
                        } else {
                            ForEach(Array(displayedModels.enumerated()), id: \.element.id) { index, model in
                                ModelRowView(
                                    model: model,
                                    downloadState: modelManager.effectiveDownloadState(for: model),
                                    metrics: modelManager.downloadMetrics[model.id],
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
                    Text("Clear search")
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
            return "No models match your search"
        }
        switch selectedTab {
        case .all:
            return "No models available"
        case .suggested:
            return "No recommended models"
        case .downloaded:
            return "No downloaded models"
        }
    }

    // MARK: - Model Filtering

    /// All available models filtered by current search text
    private var filteredModels: [MLXModel] {
        let filtered = SearchService.filterModels(modelManager.availableModels, with: searchText)
        return filtered.sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    /// Suggested (curated) models filtered by current search text
    private var filteredSuggestedModels: [MLXModel] {
        let filtered = SearchService.filterModels(modelManager.suggestedModels, with: searchText)
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
        // Prefer curated (suggested) variants over auto-discovered ones when deduplicating
        let combined = modelManager.suggestedModels + modelManager.availableModels
        var byLowerId: [String: MLXModel] = [:]
        for m in combined {
            let key = m.id.lowercased()
            if let existing = byLowerId[key] {
                // Prefer entries that are not the generic discovery description
                let existingIsDiscovered = existing.description == "Discovered on Hugging Face"
                let currentIsDiscovered = m.description == "Discovered on Hugging Face"
                if existingIsDiscovered && !currentIsDiscovered {
                    byLowerId[key] = m
                }
            } else {
                byLowerId[key] = m
            }
        }

        let all = Array(byLowerId.values)
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
        let filtered = SearchService.filterModels(merged, with: searchText)
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

    /// Count of completed (on-disk) downloaded models respecting current search
    private var completedDownloadedModelsCount: Int {
        let combined = modelManager.suggestedModels + modelManager.availableModels
        var byLowerId: [String: MLXModel] = [:]
        for m in combined {
            let key = m.id.lowercased()
            if let existing = byLowerId[key] {
                let existingIsDiscovered = existing.description == "Discovered on Hugging Face"
                let currentIsDiscovered = m.description == "Discovered on Hugging Face"
                if existingIsDiscovered && !currentIsDiscovered { byLowerId[key] = m }
            } else {
                byLowerId[key] = m
            }
        }
        let completed = byLowerId.values.filter { $0.isDownloaded }
        let filtered = SearchService.filterModels(Array(completed), with: searchText)
        return filtered.count
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

#Preview {
    ModelDownloadView()
}
