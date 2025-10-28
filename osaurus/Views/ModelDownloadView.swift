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
  @Environment(\.theme) private var theme

  // Delete confirmation removed; deletion lives in detail view

  /// Current search query text
  @State private var searchText: String = ""

  /// Currently selected tab (All, Suggested, or Downloaded)
  @State private var selectedTab: ModelListTab = .all

  /// Debounce task to prevent excessive API calls during typing
  @State private var searchDebounceTask: Task<Void, Never>? = nil

  /// Model to show in the detail sheet
  @State private var modelToShowDetails: MLXModel? = nil

  // MARK: - Deep Link Support

  /// Optional model ID for deep linking (e.g., from URL schemes)
  var deeplinkModelId: String? = nil

  /// Optional file path for deep linking
  var deeplinkFile: String? = nil

  var body: some View {
    VStack(spacing: 0) {
      // Header
      headerView

      Divider()

      // Model list
      modelListView
    }
    .frame(minWidth: 720, minHeight: 600)
    .background(theme.primaryBackground)
    .environment(\.theme, themeManager.currentTheme)
    // Delete confirmation alert removed
    .onAppear {
      // If invoked via deeplink, prefill search and ensure the model is visible
      if let modelId = deeplinkModelId, !modelId.isEmpty {
        searchText = modelId.split(separator: "/").last.map(String.init) ?? modelId
        _ = modelManager.resolveModel(byRepoId: modelId)
      }
      // Kick off initial remote fetch to augment curated list
      modelManager.fetchRemoteMLXModels(searchText: searchText)
    }
    .onChange(of: searchText) { _, newValue in
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

  /// Header section displaying the page title and download statistics
  private var headerView: some View {
    HStack(spacing: 24) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Models")
          .font(.system(size: 24, weight: .semibold))
          .foregroundColor(theme.primaryText)

        // Show count of downloaded models and total size
        Text(
          "\(filteredDownloadedModels.count) downloaded • \(modelManager.totalDownloadedSizeString)"
        )
        .font(.system(size: 13))
        .foregroundColor(theme.secondaryText)
      }

      Spacer()
    }
    .padding(.horizontal, 24)
    .padding(.vertical, 20)
  }

  // MARK: - Model List View

  /// Main content area with tabs, search, and scrollable model list
  private var modelListView: some View {
    VStack(spacing: 0) {
      // Search and filter bar
      HStack(spacing: 12) {
        // Tabs
        HStack(spacing: 4) {
          ForEach(ModelListTab.allCases, id: \.self) { tab in
            Button(action: { selectedTab = tab }) {
              Text("\(tab.title) (\(tabCount(tab)))")
                .font(.system(size: 14, weight: selectedTab == tab ? .medium : .regular))
                .foregroundColor(selectedTab == tab ? theme.primaryText : theme.secondaryText)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                  RoundedRectangle(cornerRadius: 6)
                    .fill(selectedTab == tab ? theme.tertiaryBackground : Color.clear)
                )
            }
            .buttonStyle(PlainButtonStyle())
          }
        }

        Spacer()

        // Search field
        HStack(spacing: 8) {
          Image(systemName: "magnifyingglass")
            .font(.system(size: 14))
            .foregroundColor(theme.tertiaryText)

          TextField("Search models", text: $searchText)
            .textFieldStyle(PlainTextFieldStyle())
            .font(.system(size: 14))
            .foregroundColor(theme.primaryText)

          if !searchText.isEmpty {
            Button(action: { searchText = "" }) {
              Image(systemName: "xmark.circle.fill")
                .font(.system(size: 12))
                .foregroundColor(theme.tertiaryText)
            }
            .buttonStyle(PlainButtonStyle())
          }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(width: 240)
        .background(
          RoundedRectangle(cornerRadius: 6)
            .fill(theme.tertiaryBackground)
        )

      }
      .padding(.horizontal, 24)
      .padding(.vertical, 16)
      .background(theme.secondaryBackground)

      if modelManager.isLoadingModels {
        VStack(spacing: 12) {
          ProgressView()
            .progressViewStyle(CircularProgressViewStyle())
          Text("Loading models…")
            .font(.system(size: 13))
            .foregroundColor(theme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
      } else {
        ScrollView {
          LazyVStack(spacing: 12) {
            if displayedModels.isEmpty {
              EmptyStateView(
                selectedTab: selectedTab,
                searchText: searchText,
                onClearSearch: { searchText = "" }
              )
              .padding(.vertical, 40)
            } else {
              ForEach(displayedModels) { model in
                ModelRowView(
                  model: model,
                  downloadState: modelManager.effectiveDownloadState(for: model),
                  metrics: modelManager.downloadMetrics[model.id],
                  onViewDetails: { modelToShowDetails = model }
                )
                .onAppear { /* no-op */  }
              }
            }
          }
          .padding(24)
        }
      }
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
      lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }
  }

  /// Downloaded models filtered by current search text and sorted by download date
  ///
  /// This computed property:
  /// 1. Combines available and suggested models
  /// 2. Removes duplicates by model ID
  /// 3. Filters to only downloaded models
  /// 4. Applies search filter
  /// 5. Sorts by download date (newest first), with name as secondary sort
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
    let downloaded = byLowerId.values.filter { $0.isDownloaded }
    let filtered = SearchService.filterModels(Array(downloaded), with: searchText)
    return filtered.sorted { lhs, rhs in
      lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }
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

  /// Count for a given tab that respects current search filter
  private func tabCount(_ tab: ModelListTab) -> Int {
    switch tab {
    case .all:
      return filteredModels.count
    case .suggested:
      return filteredSuggestedModels.count
    case .downloaded:
      return filteredDownloadedModels.count
    }
  }
}

#Preview {
  ModelDownloadView()
}
