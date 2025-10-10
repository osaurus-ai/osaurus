//
//  ModelDetailView.swift
//  osaurus
//
//  Modal detail view for individual MLX models.
//  Displays comprehensive model information and download controls.
//

import AppKit
import Foundation
import SwiftUI

struct ModelDetailView: View, Identifiable {
  // MARK: - Dependencies
  
  @StateObject private var modelManager = ModelManager.shared
  @StateObject private var themeManager = ThemeManager.shared
  @Environment(\.theme) private var theme
  @Environment(\.dismiss) private var dismiss

  // MARK: - Properties
  
  /// Unique identifier for Identifiable conformance (used for sheet presentation)
  let id = UUID()
  
  /// The model to display details for
  let model: MLXModel

  // MARK: - State
  
  /// Estimated download size in bytes (nil if not yet calculated)
  @State private var estimatedSize: Int64? = nil
  
  /// Whether a size estimation is currently in progress
  @State private var isEstimating = false
  
  /// Error message if size estimation fails
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

  // MARK: - Header
  
  /// Top section with model name, description, and close button
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
  
  // MARK: - Content
  
  /// Scrollable content area with model information and download size estimation
  private var content: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        // Basic info
        VStack(alignment: .leading, spacing: 12) {
          InfoRow(label: "Repository", value: repositoryName(from: model.downloadURL))
          
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

  // MARK: - Helper Properties
  
  /// Normalized model ID for API usage (lowercase, hyphen-separated)
  ///
  /// Example: "mlx-community/Llama-3.2-1B" → "llama-3.2-1b"
  private var apiModelId: String {
    let last = model.id.split(separator: "/").last.map(String.init) ?? model.name
    return last
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: " ", with: "-")
      .replacingOccurrences(of: "_", with: "-")
      .lowercased()
  }
  
  /// Copies the API model ID to the system clipboard
  private func copyAPIId() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(apiModelId, forType: .string)
  }

  // MARK: - Footer
  
  /// Bottom action bar that adapts based on download state
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

  // MARK: - Size Estimation
  
  /// Formatted string for the estimated download size
  private var estimatedSizeString: String {
    if let s = estimatedSize, s > 0 {
      return ByteCountFormatter.string(fromByteCount: s, countStyle: .file)
    }
    return "Not available"
  }

  /// Fetches download size estimation from the model manager if not already calculated
  ///
  /// - Parameter force: If true, recalculates even if a value already exists
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

  // MARK: - Download Metrics
  
  /// Formats download metrics into a human-readable string
  ///
  /// Returns a string like: "150 MB / 2 GB • 5.2 MB/s • ETA 3:45"
  /// Returns nil if no metrics are available
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

  /// Formats ETA seconds into a human-readable time string
  ///
  /// - Parameter seconds: Total seconds remaining
  /// - Returns: Formatted string like "3:45" or "1:23:45" for longer durations
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

