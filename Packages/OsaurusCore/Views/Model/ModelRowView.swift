//
//  ModelRowView.swift
//  osaurus
//
//  Card-based model row with polished hover animations.
//  Includes download progress, actions, and smooth transitions.
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
    let metrics: ModelDownloadService.DownloadMetrics?

    /// Total system unified memory in GB, used for compatibility assessment
    var totalMemoryGB: Double = 0

    /// Callback when user taps the Details button
    let onViewDetails: () -> Void

    /// Optional cancel action when downloading
    let onCancel: (() -> Void)?

    // MARK: - State

    /// Whether the user is currently hovering over this row
    @State private var isHovering = false

    var body: some View {
        Button(action: onViewDetails) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 10) {
                    modelIcon
                    Text(model.name)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    if model.isDownloaded {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundColor(theme.successColor)
                    }
                }

                // Wrapping badges row
                metadataBadges

                if !model.description.isEmpty {
                    Text(model.description)
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if case .downloading(let progress) = downloadState {
                    downloadProgressView(progress: progress)
                }

                Spacer(minLength: 0)

                footer
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(cardBackground)
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(PlainButtonStyle())
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .onHover { hovering in
            isHovering = hovering
        }
    }

    // MARK: - Metadata Badges
    private var metadataBadges: some View {
        FlowLayout(spacing: 6) {
            compatibilityBadge
            if model.isTopSuggestion {
                topSuggestionBadge
            }
            modelTypeBadge
            if let params = model.parameterCount {
                MetadataPill(text: params, icon: "cpu")
            }
            if let quant = model.quantization {
                MetadataPill(text: quant, icon: "gauge.with.dots.needle.bottom.50percent")
            }
        }
    }

    // MARK: - Footer
    @ViewBuilder
    private var footer: some View {
        if let url = URL(string: model.downloadURL) {
            Button(action: { NSWorkspace.shared.open(url) }) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 10, weight: .semibold))
                    Text(shortRepoLabel(from: model.downloadURL))
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .foregroundColor(theme.accentColor.opacity(isHovering ? 1.0 : 0.85))
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
        }
    }

    private func shortRepoLabel(from urlString: String) -> String {
        let full = repositoryName(from: urlString)
        return full.split(separator: "/").last.map(String.init) ?? full
    }

    @ViewBuilder
    private var compatibilityBadge: some View {
        switch model.compatibility(totalMemoryGB: totalMemoryGB) {
        case .compatible:
            CompatibilityPill(text: L("Runs Well"), icon: "checkmark.shield", color: theme.successColor)
        case .tight:
            CompatibilityPill(text: L("Tight Fit"), icon: "exclamationmark.triangle", color: theme.warningColor)
        case .tooLarge:
            CompatibilityPill(text: L("Too Large"), icon: "xmark.circle", color: theme.errorColor)
        case .unknown:
            EmptyView()
        }
    }

    private var topSuggestionBadge: some View {
        CompatibilityPill(text: "Top Pick", icon: "star.fill", color: .orange)
    }

    /// Badge showing whether model is LLM or VLM
    private var modelTypeBadge: some View {
        let isVLM = model.isVLM
        let typeLabel = isVLM ? "VLM" : "LLM"
        let color: Color = isVLM ? .purple : theme.accentColor
        let icon = isVLM ? "eye" : "text.bubble"

        return HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 8, weight: .semibold))
            Text(typeLabel)
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundColor(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(color.opacity(0.12))
        )
    }

    // MARK: - Model Icon

    private var modelIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(
                    model.isDownloaded
                        ? theme.successColor.opacity(0.12)
                        : theme.accentColor.opacity(0.12)
                )

            Image(systemName: model.isDownloaded ? "cube.fill" : "cube")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(
                    model.isDownloaded
                        ? theme.successColor
                        : theme.accentColor
                )
        }
        .frame(width: 32, height: 32)
    }

    // MARK: - Card Background

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(theme.cardBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        isHovering ? theme.accentColor.opacity(0.2) : theme.cardBorder,
                        lineWidth: 1
                    )
            )
            .shadow(
                color: theme.shadowColor.opacity(
                    isHovering ? theme.shadowOpacity * 1.5 : theme.shadowOpacity
                ),
                radius: isHovering ? 12 : theme.cardShadowRadius,
                x: 0,
                y: isHovering ? 4 : theme.cardShadowY
            )
    }

    // MARK: - Download Progress View

    private func downloadProgressView(progress: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                // Progress bar
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(theme.tertiaryBackground)

                        RoundedRectangle(cornerRadius: 3)
                            .fill(theme.accentColor)
                            .frame(width: geometry.size.width * progress)
                            .animation(.easeOut(duration: 0.3), value: progress)
                    }
                }
                .frame(height: 6)

                // Cancel button
                if let onCancel = onCancel {
                    Button(action: onCancel) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundColor(theme.tertiaryText)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .help(Text("Cancel download", bundle: .module))
                }
            }

            if let line = formattedMetricsLine() {
                Text(line)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(theme.tertiaryText)
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
        metrics?.formattedLine
    }
}

// MARK: - Metadata Pill Component

/// Small pill-shaped badge for displaying model metadata
private struct MetadataPill: View {
    @Environment(\.theme) private var theme

    let text: String
    let icon: String?

    init(text: String, icon: String? = nil) {
        self.text = text
        self.icon = icon
    }

    var body: some View {
        HStack(spacing: 3) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 8, weight: .medium))
            }
            Text(text)
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundColor(theme.secondaryText)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(theme.tertiaryBackground)
        )
    }
}

// MARK: - Compatibility Pill Component

/// Colored pill indicating hardware compatibility
private struct CompatibilityPill: View {
    let text: String
    let icon: String
    let color: Color

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 8, weight: .semibold))
            Text(text)
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundColor(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(color.opacity(0.12))
        )
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
