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

  /// Optional cancel action when downloading
  let onCancel: (() -> Void)?

  // MARK: - State

  /// Whether the user is currently hovering over this row
  @State private var isHovering = false

  var body: some View {
    Button(action: onViewDetails) {
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
            }

            if !model.description.isEmpty {
              Text(model.description)
                .font(.system(size: 13))
                .foregroundColor(theme.secondaryText)
                .lineLimit(2)
                .truncationMode(.tail)
            }

            // Repository link (non-interactive to allow full-row tap)
            if let url = URL(string: model.downloadURL) {
              Link(repositoryName(from: model.downloadURL), destination: url)
                .font(.system(size: 12))
                .foregroundColor(theme.tertiaryText)
                .lineLimit(1)
                .truncationMode(.middle)
                .allowsHitTesting(false)
            }

            // Download progress
            if case .downloading(let progress) = downloadState {
              VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                  SimpleProgressBar(progress: progress)
                    .frame(height: 4)
                    .frame(maxWidth: .infinity)
                  if let onCancel = onCancel {
                    CircularIconButton(
                      systemName: "xmark",
                      help: "Cancel download",
                      action: onCancel
                    )
                  }
                }

                if let line = formattedMetricsLine() {
                  Text(line)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
                }
              }
              .padding(.top, 4)
            }
          }

          Spacer(minLength: 0)

          // Chevron indicator
          Image(systemName: "chevron.right")
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(theme.tertiaryText)
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 20)

        Divider()
          .padding(.leading, 20)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
      .background(isHovering ? theme.secondaryBackground : Color.clear)
    }
    .buttonStyle(PlainButtonStyle())
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
    .onHover { hovering in
      withAnimation(.easeInOut(duration: 0.15)) {
        isHovering = hovering
      }
    }
  }

  // MARK: - Actions

  // Copy action removed; row opens details instead

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
