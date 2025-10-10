//
//  ModelRowView.swift
//  osaurus
//
//  Reusable component for displaying a single model in the model list.
//  Includes download progress, actions, and hover effects.
//

import AppKit
import Foundation
import SwiftUI

/// The row has a hover effect and adapts its appearance based on download state.
/// Users can copy the normalized model ID to their clipboard for use in API calls.
struct ModelRowView: View {
  // MARK: - Dependencies

  @Environment(\.theme) private var theme

  // MARK: - Properties

  /// The model to display
  let model: MLXModel

  /// Current download state (not started, downloading, completed, or failed)
  let downloadState: DownloadState

  /// Optional download metrics (speed, ETA, bytes transferred)
  let metrics: ModelManager.DownloadMetrics?

  /// Callback when user taps the Details button
  let onViewDetails: () -> Void

  /// Callback when user taps the Delete button
  let onDelete: () -> Void

  // MARK: - State

  /// Whether the user is currently hovering over this row
  @State private var isHovering = false

  /// Shows temporary "Copied!" feedback when user copies model ID
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

  // MARK: - Actions

  /// Copies the normalized model ID to the system clipboard
  ///
  /// The ID is normalized for API use:
  /// - Extracts the last part after "/"
  /// - Converts to lowercase
  /// - Replaces spaces and underscores with hyphens
  ///
  /// Shows temporary visual feedback for 2 seconds after copying.
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

  // MARK: - Metrics Formatting

  /// Formats download metrics into a single human-readable line
  ///
  /// Example output: "150 MB / 2 GB • 5.2 MB/s • ETA 3:45"
  ///
  /// - Returns: Formatted string with available metrics, or nil if no metrics exist
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

  /// Formats estimated time remaining into a readable string
  ///
  /// - Parameter seconds: Total seconds remaining
  /// - Returns: Formatted string like "3:45" for times under an hour, or "1:23:45" for longer
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

// MARK: - Helper Functions

/// Extracts the repository name from a Hugging Face URL
///
/// Converts full URLs to readable repository names:
/// - Input: `https://huggingface.co/mlx-community/Llama-3.2-1B-Instruct-4bit`
/// - Output: `mlx-community/Llama-3.2-1B-Instruct-4bit`
///
/// - Parameter urlString: Full Hugging Face URL
/// - Returns: Repository name in "organization/model" format, or the full URL if parsing fails
func repositoryName(from urlString: String) -> String {
  if let url = URL(string: urlString),
    url.host == "huggingface.co"
  {
    let pathComponents = url.pathComponents.filter { $0 != "/" }
    if pathComponents.count >= 2 {
      return "\(pathComponents[0])/\(pathComponents[1])"
    }
  }
  // Fallback to showing the full URL if parsing fails
  return urlString
}
