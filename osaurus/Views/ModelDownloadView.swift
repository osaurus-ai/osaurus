//
//  ModelDownloadView.swift
//  osaurus
//
//  Created by Terence on 8/17/25.
//

import AppKit
import Foundation
import SwiftUI

struct ModelDownloadView: View {
  @StateObject private var modelManager = ModelManager.shared
  @StateObject private var themeManager = ThemeManager.shared
  @Environment(\.theme) private var theme
  @State private var showDeleteConfirmation = false
  @State private var modelToDelete: MLXModel?
  @State private var searchText: String = ""
  @State private var selectedTab: ModelListTab = .all
  @State private var searchDebounceTask: Task<Void, Never>? = nil
  @State private var modelToShowDetails: MLXModel? = nil
  @State private var sortOption: ModelSortOption = .relevance
  @State private var showOnlyQuantized: Bool = false
  var deeplinkModelId: String? = nil
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
    .alert("Delete Model", isPresented: $showDeleteConfirmation) {
      Button("Cancel", role: .cancel) {}
      Button("Delete", role: .destructive) {
        if let model = modelToDelete {
          modelManager.deleteModel(model)
        }
      }
    } message: {
      Text(
        "Are you sure you want to delete \(modelToDelete?.name ?? "this model")? This action cannot be undone."
      )
    }
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

  private var headerView: some View {
    HStack(spacing: 24) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Models")
          .font(.system(size: 24, weight: .semibold))
          .foregroundColor(theme.primaryText)
        
        Text("\(filteredDownloadedModels.count) downloaded • \(modelManager.totalDownloadedSizeString)")
          .font(.system(size: 13))
          .foregroundColor(theme.secondaryText)
      }
      
      Spacer()
    }
    .padding(.horizontal, 24)
    .padding(.vertical, 20)
  }

  private var modelListView: some View {
    VStack(spacing: 0) {
      // Search and filter bar
      HStack(spacing: 12) {
        // Tabs
        HStack(spacing: 4) {
          ForEach(ModelListTab.allCases, id: \.self) { tab in
            Button(action: { selectedTab = tab }) {
              Text(tab.title)
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
        
        // Sort button
        Menu {
          ForEach(ModelSortOption.allCases, id: \.self) { option in
            Button(action: { sortOption = option }) {
              HStack {
                Text(option.title)
                if sortOption == option {
                  Spacer()
                  Image(systemName: "checkmark")
                    .font(.system(size: 11))
                }
              }
            }
          }
        } label: {
          HStack(spacing: 4) {
            Text(sortOption == .relevance ? "Sort" : sortOption.title)
              .font(.system(size: 14))
            Image(systemName: "chevron.down")
              .font(.system(size: 11))
          }
          .foregroundColor(theme.secondaryText)
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
          .background(
            RoundedRectangle(cornerRadius: 6)
              .stroke(theme.secondaryBorder, lineWidth: 1)
          )
        }
        .menuStyle(BorderlessButtonMenuStyle())
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
                  onViewDetails: { modelToShowDetails = model },
                  onDelete: {
                    modelToDelete = model
                    showDeleteConfirmation = true
                  }
                )
                .onAppear {
                  modelManager.prefetchModelDetailsIfNeeded(for: model)
                }
              }
            }
          }
          .padding(24)
        }
      }
    }
  }

  private var filteredModels: [MLXModel] {
    SearchService.filterModels(modelManager.availableModels, with: searchText)
  }

  private var filteredSuggestedModels: [MLXModel] {
    SearchService.filterModels(modelManager.suggestedModels, with: searchText)
  }

  private var filteredDownloadedModels: [MLXModel] {
    let combined = modelManager.availableModels + modelManager.suggestedModels
    let uniqueModels = Dictionary(
      combined.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
    ).values
    let downloaded = uniqueModels.filter { $0.isDownloaded }
    let filtered = SearchService.filterModels(Array(downloaded), with: searchText)
    return filtered.sorted { lhs, rhs in
      let la = lhs.downloadedAt ?? .distantPast
      let ra = rhs.downloadedAt ?? .distantPast
      if la == ra { return lhs.name < rhs.name }
      return la > ra  // Newest first
    }
  }

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
    
    // Apply quantized filter
    let filtered = showOnlyQuantized ? baseModels.filter { model in
      model.name.lowercased().contains("4bit") || 
      model.name.lowercased().contains("8bit") ||
      model.name.lowercased().contains("quantized")
    } : baseModels
    
    // Apply sorting
    return sortModels(filtered)
  }
  
  private func sortModels(_ models: [MLXModel]) -> [MLXModel] {
    switch sortOption {
    case .relevance:
      // Default relevance based on search text
      return models
    case .nameAscending:
      return models.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    case .nameDescending:
      return models.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedDescending }
    case .sizeAscending:
      return models.sorted { (lhs: MLXModel, rhs: MLXModel) in lhs.size < rhs.size }
    case .sizeDescending:
      return models.sorted { (lhs: MLXModel, rhs: MLXModel) in lhs.size > rhs.size }
    case .dateNewest:
      return models.sorted { 
        ($0.downloadedAt ?? .distantPast) > ($1.downloadedAt ?? .distantPast)
      }
    case .dateOldest:
      return models.sorted { 
        ($0.downloadedAt ?? .distantPast) < ($1.downloadedAt ?? .distantPast)
      }
    }
  }
}

enum ModelListTab: CaseIterable {
  case all
  case suggested
  case downloaded

  var title: String {
    switch self {
    case .all: return "All Models"
    case .suggested: return "Suggested"
    case .downloaded: return "Downloaded"
    }
  }
}

enum ModelSortOption: String, CaseIterable {
  case relevance = "Relevance"
  case nameAscending = "Name (A-Z)"
  case nameDescending = "Name (Z-A)"
  case sizeAscending = "Size (Small to Large)"
  case sizeDescending = "Size (Large to Small)"
  case dateNewest = "Date (Newest First)"
  case dateOldest = "Date (Oldest First)"
  
  var title: String {
    self.rawValue
  }
}

struct EmptyStateView: View {
  @Environment(\.theme) private var theme
  let selectedTab: ModelListTab
  let searchText: String
  let onClearSearch: () -> Void

  var body: some View {
    VStack(spacing: 16) {
      Image(systemName: iconName)
        .font(.system(size: 36, weight: .light))
        .foregroundColor(theme.tertiaryText)
      
      VStack(spacing: 8) {
        Text(title)
          .font(.system(size: 16, weight: .medium))
          .foregroundColor(theme.primaryText)
        
        Text(description)
          .font(.system(size: 14))
          .foregroundColor(theme.secondaryText)
          .multilineTextAlignment(.center)
          .frame(maxWidth: 360)
        
        if !searchText.isEmpty {
          Button(action: onClearSearch) {
            Text("Clear search")
              .font(.system(size: 13))
              .foregroundColor(theme.accentColor)
          }
          .buttonStyle(PlainButtonStyle())
          .padding(.top, 4)
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
  
  private var iconName: String {
    searchText.isEmpty ? "cube.box" : "magnifyingglass"
  }
  
  private var title: String {
    if !searchText.isEmpty {
      return "No models found"
    }
    
    switch selectedTab {
    case .all:
      return "No models available"
    case .suggested:
      return "No suggested models"
    case .downloaded:
      return "No downloaded models"
    }
  }
  
  private var description: String {
    if !searchText.isEmpty {
      return "Try adjusting your search terms"
    }
    
    switch selectedTab {
    case .all:
      return "Language models will appear here"
    case .suggested:
      return "Suggested models will appear here"
    case .downloaded:
      return "Downloaded models will appear here"
    }
  }
}

struct ModelRowView: View {
  @Environment(\.theme) private var theme
  let model: MLXModel
  let downloadState: DownloadState
  let metrics: ModelManager.DownloadMetrics?
  let onViewDetails: () -> Void
  let onDelete: () -> Void

  @State private var isHovering = false
  @State private var showCopiedFeedback = false

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 16) {
        // Model info
        VStack(alignment: .leading, spacing: 6) {
          HStack(alignment: .center, spacing: 8) {
            Text(model.name)
              .font(.system(size: 15, weight: .medium))
              .foregroundColor(theme.primaryText)
              .lineLimit(1)
              .truncationMode(.tail)
            
            if model.isDownloaded {
              Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundColor(theme.successColor)
            }
            
            Spacer(minLength: 0)
            
            Text(model.sizeString)
              .font(.system(size: 13))
              .foregroundColor(theme.secondaryText)
          }
          
          if !model.description.isEmpty {
            Text(model.description)
              .font(.system(size: 13))
              .foregroundColor(theme.secondaryText)
              .lineLimit(2)
              .truncationMode(.tail)
          }
          
          // Repository link
          if let url = URL(string: model.downloadURL) {
            Link(repositoryName(from: model.downloadURL), destination: url)
              .font(.system(size: 12))
              .foregroundColor(theme.tertiaryText)
              .lineLimit(1)
              .truncationMode(.middle)
          }
          
          // Download progress
          if case .downloading(let progress) = downloadState {
            VStack(alignment: .leading, spacing: 6) {
              SimpleProgressBar(progress: progress)
                .frame(height: 4)
              
              if let line = formattedMetricsLine() {
                Text(line)
                  .font(.system(size: 11))
                  .foregroundColor(theme.tertiaryText)
              }
            }
            .padding(.top, 4)
          }
        }
        
        // Actions
        HStack(spacing: 8) {
          Button(action: onViewDetails) {
            Text("Details")
              .font(.system(size: 13))
              .foregroundColor(theme.accentColor)
          }
          .buttonStyle(PlainButtonStyle())
          
          if model.isDownloaded {
            Button(action: onDelete) {
              Image(systemName: "trash")
                .font(.system(size: 13))
                .foregroundColor(theme.errorColor)
            }
            .buttonStyle(PlainButtonStyle())
          }
          
          Button(action: copyModelID) {
            Image(systemName: showCopiedFeedback ? "checkmark" : "doc.on.doc")
              .font(.system(size: 13))
              .foregroundColor(showCopiedFeedback ? theme.successColor : theme.tertiaryText)
          }
          .buttonStyle(PlainButtonStyle())
          .help(showCopiedFeedback ? "Copied!" : "Copy model ID")
        }
      }
      .padding(.vertical, 16)
      .padding(.horizontal, 20)
      
      Divider()
        .padding(.leading, 20)
    }
    .background(isHovering ? theme.secondaryBackground : Color.clear)
    .onHover { hovering in
      withAnimation(.easeInOut(duration: 0.15)) {
        isHovering = hovering
      }
    }
  }

  private func copyModelID() {
    let apiId: String = {
      let last = model.id.split(separator: "/").last.map(String.init) ?? model.name
      let normalized =
        last
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: " ", with: "-")
        .replacingOccurrences(of: "_", with: "-")
        .lowercased()
      return normalized
    }()

    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(apiId, forType: .string)

    // Show feedback
    withAnimation {
      showCopiedFeedback = true
    }

    // Reset feedback after delay
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
      withAnimation {
        showCopiedFeedback = false
      }
    }
  }

  private func formattedMetricsLine() -> String? {
    guard let metrics = metrics else { return nil }

    var parts: [String] = []

    if let received = metrics.bytesReceived {
      let receivedStr = ByteCountFormatter.string(fromByteCount: received, countStyle: .file)
      if let total = metrics.totalBytes, total > 0 {
        let totalStr = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        parts.append("\(receivedStr) / \(totalStr)")
      } else {
        parts.append(receivedStr)
      }
    }

    if let bps = metrics.bytesPerSecond {
      let speedStr = ByteCountFormatter.string(fromByteCount: Int64(bps), countStyle: .file)
      parts.append("\(speedStr)/s")
    }

    if let eta = metrics.etaSeconds, eta.isFinite, eta > 0 {
      parts.append("ETA \(formatETA(seconds: eta))")
    }

    guard !parts.isEmpty else { return nil }
    return parts.joined(separator: " • ")
  }

  private func formatETA(seconds: Double) -> String {
    let total = Int(seconds.rounded())
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let secs = total % 60
    if hours > 0 {
      return String(format: "%d:%02d:%02d", hours, minutes, secs)
    } else {
      return String(format: "%d:%02d", minutes, secs)
    }
  }

  
}

// Helper function to extract repository name from URL
private func repositoryName(from urlString: String) -> String {
  // Extract the repository part from Hugging Face URL
  // Example: https://huggingface.co/mlx-community/Llama-3.2-1B-Instruct-4bit -> mlx-community/Llama-3.2-1B-Instruct-4bit
  if let url = URL(string: urlString),
    url.host == "huggingface.co"
  {
    let pathComponents = url.pathComponents.filter { $0 != "/" }
    if pathComponents.count >= 2 {
      return "\(pathComponents[0])/\(pathComponents[1])"
    }
  }
  // Fallback to showing the full URL
  return urlString
}

#Preview {
  ModelDownloadView()
}

// MARK: - Model Detail View (embedded to avoid project file updates)

struct ModelDetailView: View, Identifiable {
  @StateObject private var modelManager = ModelManager.shared
  @StateObject private var themeManager = ThemeManager.shared
  @Environment(\.theme) private var theme
  @Environment(\.dismiss) private var dismiss

  let id = UUID()
  let model: MLXModel

  @State private var estimatedSize: Int64? = nil
  @State private var isEstimating = false
  @State private var estimateError: String? = nil

  var body: some View {
    VStack(spacing: 0) {
      header
      
      Divider()
      
      content
      
      Divider()
      
      footer
    }
    .frame(width: 560, height: 480)
    .background(theme.primaryBackground)
    .environment(\.theme, themeManager.currentTheme)
    .onAppear { Task { await estimateIfNeeded() } }
  }

  private var header: some View {
    HStack {
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 8) {
          Text(model.name)
            .font(.system(size: 18, weight: .semibold))
            .foregroundColor(theme.primaryText)
          
          if model.isDownloaded {
            Image(systemName: "checkmark.circle.fill")
              .font(.system(size: 14))
              .foregroundColor(theme.successColor)
          }
        }
        
        if !model.description.isEmpty {
          Text(model.description)
            .font(.system(size: 14))
            .foregroundColor(theme.secondaryText)
            .lineLimit(2)
        }
      }
      
      Spacer()
      
      Button(action: { dismiss() }) {
        Image(systemName: "xmark")
          .font(.system(size: 14, weight: .medium))
          .foregroundColor(theme.secondaryText)
      }
      .buttonStyle(PlainButtonStyle())
    }
    .padding(20)
  }
  
  private var content: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        // Basic info
        VStack(alignment: .leading, spacing: 12) {
          InfoRow(label: "Repository", value: repositoryName(from: model.downloadURL))
          InfoRow(label: "Size", value: model.sizeString)
          
          if model.isDownloaded, let downloadedAt = model.downloadedAt {
            InfoRow(label: "Downloaded", value: RelativeDateTimeFormatter().localizedString(for: downloadedAt, relativeTo: Date()))
          }
        }
        
        // Estimated download size
        VStack(alignment: .leading, spacing: 8) {
          Text("Estimated download size")
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(theme.secondaryText)
          
          HStack(spacing: 8) {
            if isEstimating {
              ProgressView()
                .progressViewStyle(CircularProgressViewStyle())
                .scaleEffect(0.7)
            }
            
            Text(estimatedSizeString)
              .font(.system(size: 14, weight: .medium))
              .foregroundColor(theme.primaryText)
            
            if !isEstimating {
              Button(action: { Task { await estimateIfNeeded(force: true) } }) {
                Text("Recalculate")
                  .font(.system(size: 12))
                  .foregroundColor(theme.accentColor)
              }
              .buttonStyle(PlainButtonStyle())
            }
          }
          
          if let err = estimateError {
            Text(err)
              .font(.system(size: 12))
              .foregroundColor(theme.errorColor)
          }
        }
        
        // Repository URL
        CopyableURLField(label: "Repository URL", url: model.downloadURL)
        
        // Required files
        VStack(alignment: .leading, spacing: 8) {
          Text("Required files")
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(theme.secondaryText)
          
          VStack(alignment: .leading, spacing: 4) {
            ForEach(ModelManager.snapshotDownloadPatterns, id: \.self) { pattern in
              Text(pattern)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(theme.tertiaryText)
            }
          }
        }
      }
      .padding(20)
    }
  }

  private var apiModelId: String {
    let last = model.id.split(separator: "/").last.map(String.init) ?? model.name
    return last
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: " ", with: "-")
      .replacingOccurrences(of: "_", with: "-")
      .lowercased()
  }
  
  private func copyAPIId() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(apiModelId, forType: .string)
  }

  private var footer: some View {
    HStack(spacing: 12) {
      switch modelManager.effectiveDownloadState(for: model) {
      case .notStarted, .failed(_):
        Button(action: { dismiss() }) {
          Text("Cancel")
            .font(.system(size: 14))
            .foregroundColor(theme.secondaryText)
        }
        .buttonStyle(PlainButtonStyle())
        
        Spacer()
        
        Button(action: { 
          modelManager.downloadModel(model)
          dismiss()
        }) {
          HStack(spacing: 6) {
            Image(systemName: "arrow.down.circle")
              .font(.system(size: 14))
            Text("Download")
              .font(.system(size: 14, weight: .medium))
          }
          .foregroundColor(.white)
          .padding(.horizontal, 16)
          .padding(.vertical, 8)
          .background(
            RoundedRectangle(cornerRadius: 6)
              .fill(theme.accentColor)
          )
        }
        .buttonStyle(PlainButtonStyle())
        
      case .downloading(let progress):
        VStack(alignment: .leading, spacing: 8) {
          HStack {
            Text("\(Int(progress * 100))% downloaded")
              .font(.system(size: 13))
              .foregroundColor(theme.primaryText)
            
            Spacer()
            
            if let line = formattedMetricsLine() {
              Text(line)
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
            }
          }
          
          SimpleProgressBar(progress: progress)
            .frame(height: 6)
        }
        .frame(maxWidth: .infinity)
        
        Button(action: { modelManager.cancelDownload(model.id) }) {
          Text("Cancel")
            .font(.system(size: 13))
            .foregroundColor(theme.errorColor)
        }
        .buttonStyle(PlainButtonStyle())
        
      case .completed:
        Button(action: { 
          modelManager.deleteModel(model)
          dismiss()
        }) {
          Text("Delete Model")
            .font(.system(size: 14))
            .foregroundColor(theme.errorColor)
        }
        .buttonStyle(PlainButtonStyle())
        
        Spacer()
        
        Button(action: { dismiss() }) {
          Text("Done")
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
              RoundedRectangle(cornerRadius: 6)
                .fill(theme.accentColor)
            )
        }
        .buttonStyle(PlainButtonStyle())
      }
    }
    .padding(20)
  }

  private var estimatedSizeString: String {
    if let s = estimatedSize, s > 0 {
      return ByteCountFormatter.string(fromByteCount: s, countStyle: .file)
    }
    return "Not available"
  }

  private func estimateIfNeeded(force: Bool = false) async {
    if isEstimating { return }
    if !force, let est = estimatedSize, est > 0 { return }
    isEstimating = true
    estimateError = nil
    let size = await modelManager.estimateDownloadSize(for: model)
    await MainActor.run {
      self.estimatedSize = size
      if size == nil { self.estimateError = "Could not estimate size right now." }
      self.isEstimating = false
    }
  }

  private func formattedMetricsLine() -> String? {
    guard let metrics = modelManager.downloadMetrics[model.id] else { return nil }

    var parts: [String] = []

    if let received = metrics.bytesReceived {
      let receivedStr = ByteCountFormatter.string(fromByteCount: received, countStyle: .file)
      if let total = metrics.totalBytes, total > 0 {
        let totalStr = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        parts.append("\(receivedStr) / \(totalStr)")
      } else {
        parts.append(receivedStr)
      }
    }

    if let bps = metrics.bytesPerSecond {
      let speedStr = ByteCountFormatter.string(fromByteCount: Int64(bps), countStyle: .file)
      parts.append("\(speedStr)/s")
    }

    if let eta = metrics.etaSeconds, eta.isFinite, eta > 0 {
      parts.append("ETA \(formatETA(seconds: eta))")
    }

    guard !parts.isEmpty else { return nil }
    return parts.joined(separator: " • ")
  }

  private func formatETA(seconds: Double) -> String {
    let total = Int(seconds.rounded())
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let secs = total % 60
    if hours > 0 {
      return String(format: "%d:%02d:%02d", hours, minutes, secs)
    } else {
      return String(format: "%d:%02d", minutes, secs)
    }
  }
}

// MARK: - Supporting Types

struct InfoRow: View {
  @Environment(\.theme) private var theme
  let label: String
  let value: String
  
  var body: some View {
    HStack {
      Text(label)
        .font(.system(size: 13, weight: .medium))
        .foregroundColor(theme.secondaryText)
      
      Spacer()
      
      Text(value)
        .font(.system(size: 13, weight: .medium))
        .foregroundColor(theme.primaryText)
        .multilineTextAlignment(.trailing)
    }
  }
}
