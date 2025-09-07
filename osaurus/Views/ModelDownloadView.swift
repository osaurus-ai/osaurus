//
//  ModelDownloadView.swift
//  osaurus
//
//  Created by Terence on 8/17/25.
//

import AppKit
import SwiftUI

struct ModelDownloadView: View {
  @StateObject private var modelManager = ModelManager.shared
  @StateObject private var themeManager = ThemeManager.shared
  @Environment(\.theme) private var theme
  @State private var showDeleteConfirmation = false
  @State private var modelToDelete: MLXModel?
  @State private var searchText: String = ""
  @State private var selectedTab: ModelListTab = .all
  var deeplinkModelId: String? = nil
  var deeplinkFile: String? = nil

  var body: some View {
    ZStack {
      // Themed background
      theme.primaryBackground
        .ignoresSafeArea()

      VStack(spacing: 0) {
        // Header
        headerView

        // Model list
        modelListView
      }
    }
    .frame(minWidth: 700, minHeight: 600)
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
    }
  }

  private var headerView: some View {
    HStack {
      // Logo with minimalistic outline
      ZStack {
        Circle()
          .fill(theme.cardBackground)
          .overlay(
            Circle()
              .stroke(theme.accentColor, lineWidth: 2)
          )
          .frame(width: 50, height: 50)

        Image(systemName: "cube.box")
          .font(.system(size: 26))
          .foregroundColor(theme.accentColor)
      }
      .shadow(color: theme.shadowColor.opacity(theme.shadowOpacity), radius: 6, x: 0, y: 2)

      VStack(alignment: .leading, spacing: 4) {
        Text("Manage Models")
          .font(.system(size: 24, weight: .bold, design: .rounded))
          .foregroundColor(theme.primaryText)

        Text("Download and manage Large Language Models for MLX")
          .font(.system(size: 13, weight: .medium))
          .foregroundColor(theme.secondaryText)
      }

      Spacer()

      VStack(alignment: .trailing, spacing: 4) {
        Text("Total Downloaded")
          .font(.system(size: 12, weight: .medium))
          .foregroundColor(theme.secondaryText)
        Text(modelManager.totalDownloadedSizeString)
          .font(.system(size: 18, weight: .bold))
          .foregroundColor(theme.accentColor)
      }
    }
    .padding(.horizontal, 24)
    .padding(.vertical, 20)
    .background(
      theme.secondaryBackground
        .overlay(
          Rectangle()
            .fill(theme.primaryBorder)
            .frame(height: 1),
          alignment: .bottom
        )
    )
  }

  private var modelListView: some View {
    VStack(spacing: 0) {
      // Tabs
      HStack {
        Spacer()
        ThemedTabPicker(
          selection: $selectedTab,
          tabs: ModelListTab.allCases.map { ($0, $0.title) }
        )
        .frame(maxWidth: 600)
        Spacer()
      }
      .padding(.horizontal, 24)
      .padding(.vertical, 12)
      .background(theme.secondaryBackground)
      .overlay(
        Rectangle()
          .fill(theme.primaryBorder)
          .frame(height: 1),
        alignment: .bottom
      )

      // Search row above results
      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass")
          .foregroundColor(theme.tertiaryText)
        TextField("Search models", text: $searchText)
          .textFieldStyle(PlainTextFieldStyle())
          .foregroundColor(theme.primaryText)
          .accessibilityIdentifier("model_search_field")
      }
      .padding(.horizontal, 24)
      .padding(.vertical, 10)
      .background(theme.secondaryBackground)
      .overlay(
        Rectangle()
          .fill(theme.primaryBorder)
          .frame(height: 1),
        alignment: .bottom
      )

      if modelManager.isLoadingModels {
        VStack(spacing: 12) {
          ProgressView()
            .progressViewStyle(CircularProgressViewStyle())
          Text("Loading models…")
            .foregroundColor(theme.secondaryText)
            .font(.system(size: 13))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
      } else {
        ScrollView {
          LazyVStack(spacing: 16) {
            if displayedModels.isEmpty {
              if selectedTab == .all || selectedTab == .suggested {
                EmptyModelView(
                  title: "No models found",
                  description: "Couldn't find any models that matches your search")
              } else {
                EmptyModelView(
                  title: "No downloads yet", description: "You have no downloaded models")
              }
            } else {
              ForEach(displayedModels) { model in
                ModelRowView(
                  model: model,
                  downloadState: modelManager.effectiveDownloadState(for: model),
                  onDownload: { modelManager.downloadModel(model) },
                  onCancel: { modelManager.cancelDownload(model.id) },
                  onDelete: {
                    modelToDelete = model
                    showDeleteConfirmation = true
                  }
                )
                .onAppear {
                  modelManager.prefetchModelDetailsIfNeeded(for: model)
                }
                .transition(
                  .asymmetric(
                    insertion: .scale.combined(with: .opacity),
                    removal: .scale.combined(with: .opacity)
                  ))
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
    switch selectedTab {
    case .all:
      return filteredModels
    case .suggested:
      return filteredSuggestedModels
    case .downloaded:
      return filteredDownloadedModels
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

struct EmptyModelView: View {
  @Environment(\.theme) private var theme

  var title: String
  var description: String

  var body: some View {
    VStack(alignment: .center, spacing: 6) {
      Text(title)
        .font(.system(size: 16, weight: .semibold))
        .foregroundColor(theme.primaryText)

      Text(description)
        .foregroundColor(theme.secondaryText)
        .font(.system(size: 13))
    }
    .multilineTextAlignment(.center)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

struct ModelRowView: View {
  @Environment(\.theme) private var theme
  let model: MLXModel
  let downloadState: DownloadState
  let onDownload: () -> Void
  let onCancel: () -> Void
  let onDelete: () -> Void

  @State private var isHovering = false
  @State private var showCopiedFeedback = false

  var body: some View {
    SimpleCard(padding: 0) {
      VStack(spacing: 0) {
        HStack(spacing: 16) {
          // Model icon with gradient
          IconBadge(
            icon: "text.bubble.fill",
            color: model.isDownloaded ? .green : .blue,
            size: 50
          )

          // Model info
          VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
              Text(model.name)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(theme.primaryText)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)

              Button(action: copyModelID) {
                HStack(spacing: 4) {
                  Image(systemName: showCopiedFeedback ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11))
                  Text(showCopiedFeedback ? "Copied!" : "Copy ID")
                    .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(showCopiedFeedback ? theme.successColor : theme.tertiaryText)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                  RoundedRectangle(cornerRadius: 6)
                    .fill(theme.cardBackground)
                    .overlay(
                      RoundedRectangle(cornerRadius: 6)
                        .stroke(
                          showCopiedFeedback ? theme.successColor : theme.primaryBorder,
                          lineWidth: 1)
                    )
                )
                .animation(.easeInOut(duration: 0.2), value: showCopiedFeedback)
              }
              .buttonStyle(PlainButtonStyle())
              .help("Copy model ID for API usage")
              .fixedSize()

              Spacer(minLength: 0)
            }

            // Description if available
            if !model.description.isEmpty {
              Text(model.description)
                .font(.system(size: 13))
                .foregroundColor(theme.secondaryText)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Repository URL as small link
            if let url = URL(string: model.downloadURL) {
              HStack(spacing: 4) {
                Image(systemName: "link")
                  .font(.system(size: 10))
                Link(repositoryName(from: model.downloadURL), destination: url)
                  .font(.system(size: 11))
                  .underline(false)
                  .lineLimit(1)
                  .truncationMode(.middle)
              }
              .foregroundColor(theme.tertiaryText)
              .opacity(0.8)
            }

            HStack(spacing: 12) {
              HStack(spacing: 4) {
                Image(systemName: "internaldrive")
                  .font(.system(size: 11))
                if model.size > 0 {
                  Text(model.sizeString)
                    .font(.system(size: 11, weight: .medium))
                } else {
                  Text("estimating…")
                    .font(.system(size: 11, weight: .medium))
                }
              }
              .foregroundColor(theme.tertiaryText)

              if model.isDownloaded {
                StatusBadge(
                  status: "Downloaded",
                  color: theme.successColor,
                  isAnimating: false
                )
              }
            }
          }

          Spacer()

          // Action buttons
          actionButton
        }
        .padding(20)

        // Progress bar
        if case .downloading(let progress) = downloadState {
          VStack(spacing: 8) {
            SimpleProgressBar(progress: progress)
              .padding(.horizontal, 20)

            Text("\(Int(progress * 100))% downloaded")
              .font(.system(size: 11, weight: .medium))
              .foregroundColor(theme.secondaryText)
          }
          .padding(.bottom, 16)
          .transition(.move(edge: .bottom).combined(with: .opacity))
        }
      }
    }
    .scaleEffect(isHovering ? 1.02 : 1.0)
    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isHovering)
    .onHover { hovering in
      isHovering = hovering
    }
  }

  @ViewBuilder
  private var actionButton: some View {
    switch downloadState {
    case .notStarted:
      GradientButton(
        title: "Download",
        icon: "arrow.down.circle.fill",
        action: onDownload
      )

    case .downloading:
      GradientButton(
        title: "Cancel",
        icon: "xmark.circle",
        action: onCancel,
        isDestructive: true,
        isPrimary: false
      )

    case .completed:
      GradientButton(
        title: "Delete",
        icon: "trash",
        action: onDelete,
        isDestructive: true,
        isPrimary: false
      )

    case .failed(_):
      VStack(alignment: .trailing, spacing: 8) {
        StatusBadge(
          status: "Failed",
          color: theme.errorColor,
          isAnimating: false
        )

        Button(action: onDownload) {
          HStack(spacing: 4) {
            Image(systemName: "arrow.clockwise")
              .font(.system(size: 12))
            Text("Retry")
              .font(.system(size: 12, weight: .medium))
          }
          .foregroundColor(.blue)
        }
        .buttonStyle(PlainButtonStyle())
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
