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
            VStack(spacing: 0) {
                gradientHeader

                VStack(alignment: .leading, spacing: 10) {
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
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, minHeight: 200, alignment: .top)
            .background(theme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(
                        isHovering ? theme.accentColor.opacity(0.25) : theme.cardBorder,
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
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(PlainButtonStyle())
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .onHover { hovering in
            isHovering = hovering
        }
    }

    // MARK: - Gradient Header

    private var gradientHeader: some View {
        ZStack {
            LinearGradient(
                colors: ModelCardGradient.colors(for: model),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            highlightLayer

            RadialGradient(
                colors: [.black.opacity(0.30), .black.opacity(0)],
                center: UnitPoint(x: 0.88, y: 0.95),
                startRadius: 4,
                endRadius: 240
            )

            Text(ModelMetadataParser.simpleName(from: model.name))
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .lineLimit(2)
                .truncationMode(.tail)
                .multilineTextAlignment(.center)
                .shadow(color: .black.opacity(0.22), radius: 2, x: 0, y: 1)
                .padding(.horizontal, 16)

            VStack {
                HStack(alignment: .top, spacing: 6) {
                    Spacer(minLength: 0)
                    if model.isTopSuggestion {
                        topPickRibbon
                    }
                    if model.isDownloaded {
                        downloadedBadge
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(10)
        }
        .frame(height: 110)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var highlightLayer: some View {
        if isHovering {
            // TimelineView only ticks while it's in the view tree, so
            // un-hovered cards don't pay any animation cost.
            TimelineView(.animation) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                let x = 0.34 + sin(t * 0.7) * 0.22
                let y = 0.28 + cos(t * 0.5) * 0.18
                RadialGradient(
                    colors: [.white.opacity(0.38), .white.opacity(0)],
                    center: UnitPoint(x: x, y: y),
                    startRadius: 4,
                    endRadius: 220
                )
            }
            .transition(.opacity)
        } else {
            RadialGradient(
                colors: [.white.opacity(0.32), .white.opacity(0)],
                center: UnitPoint(x: 0.22, y: 0.18),
                startRadius: 4,
                endRadius: 220
            )
            .transition(.opacity)
        }
    }

    private var topPickRibbon: some View {
        HStack(spacing: 3) {
            Image(systemName: "star.fill")
                .font(.system(size: 9, weight: .bold))
            Text("Top Pick", bundle: .module)
                .font(.system(size: 10, weight: .bold))
        }
        .foregroundColor(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(.black.opacity(0.28))
        )
    }

    private var downloadedBadge: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 15, weight: .semibold))
            .foregroundColor(.white)
            .padding(3)
            .background(
                Circle().fill(.black.opacity(0.28))
            )
    }

    // MARK: - Metadata Badges

    private var metadataBadges: some View {
        FlowLayout(spacing: 6) {
            if let size = model.formattedDownloadSize {
                MetadataPill(text: size, icon: "internaldrive")
            }
            compatibilityBadge
            modelTypeBadge
            if let quant = model.quantization {
                MetadataPill(text: quant, icon: "gauge.with.dots.needle.bottom.50percent")
            }
        }
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

// MARK: - Card Gradient Palette

/// Color provider for the model card spotlight header. Curated families
/// get a hand-picked two-stop gradient. everything else gets a
/// deterministic hue derived from the repo id so unknown families stay
/// distinguishable at a glance without a manual mapping
enum ModelCardGradient {
    static func colors(for model: MLXModel) -> [Color] {
        let key = model.family.lowercased()
        if let palette = curated[key] { return palette }
        return hashed(for: model.id)
    }

    /// Two-stop gradients tuned for white text. Stops sit roughly at
    /// Tailwind 500 and 700 of the same family saturated enough that
    /// white reads without a heavy shadow
    private static let curated: [String: [Color]] = [
        "qwen": [Color(hex: "0EA5E9"), Color(hex: "0E7490")],
        "gemma": [Color(hex: "6366F1"), Color(hex: "1D4ED8")],
        "llama": [Color(hex: "8B5CF6"), Color(hex: "A21CAF")],
        "phi": [Color(hex: "10B981"), Color(hex: "0F766E")],
        "mistral": [Color(hex: "F97316"), Color(hex: "DC2626")],
        "mixtral": [Color(hex: "F43F5E"), Color(hex: "C2410C")],
        "deepseek": [Color(hex: "2563EB"), Color(hex: "4338CA")],
        "granite": [Color(hex: "64748B"), Color(hex: "334155")],
        "liquid": [Color(hex: "EC4899"), Color(hex: "7C3AED")],
        "smollm": [Color(hex: "65A30D"), Color(hex: "15803D")],
        "hermes": [Color(hex: "F59E0B"), Color(hex: "C2410C")],
        "starcoder": [Color(hex: "0EA5E9"), Color(hex: "6D28D9")],
        "command-r": [Color(hex: "A855F7"), Color(hex: "BE185D")],
        "nemotron": [Color(hex: "22C55E"), Color(hex: "047857")],
        "yi": [Color(hex: "F59E0B"), Color(hex: "B91C1C")],
        "falcon": [Color(hex: "B45309"), Color(hex: "9A3412")],
        "internlm": [Color(hex: "0891B2"), Color(hex: "1D4ED8")],
        "stablelm": [Color(hex: "8B5CF6"), Color(hex: "1D4ED8")],
        "grok": [Color(hex: "334155"), Color(hex: "4338CA")],
    ]

    /// djb2 hash → two HSB hues separated by ~0.1 on the wheel, with a
    /// noticeable brightness drop between stops so the gradient reads
    /// as one. Saturation/brightness mirror the curated palette so the
    /// fallback feels like part of the same family
    private static func hashed(for id: String) -> [Color] {
        var hash: UInt64 = 5381
        for scalar in id.unicodeScalars {
            hash = (hash &* 33) &+ UInt64(scalar.value)
        }
        let h1 = Double(hash % 360) / 360.0
        let h2 = (h1 + 0.1).truncatingRemainder(dividingBy: 1.0)
        return [
            Color(hue: h1, saturation: 0.70, brightness: 0.78),
            Color(hue: h2, saturation: 0.78, brightness: 0.55),
        ]
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
