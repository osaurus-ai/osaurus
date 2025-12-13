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
    @Environment(\.dismiss) private var dismiss

    /// Use computed property to always get the current theme from ThemeManager
    private var theme: ThemeProtocol { themeManager.currentTheme }

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

    /// Hugging Face model details (loaded asynchronously)
    @State private var hfDetails: HuggingFaceService.ModelDetails? = nil

    /// Whether HF details are currently loading
    @State private var isLoadingHFDetails = false

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            content

            Divider()

            footer
        }
        .frame(width: 560, height: 520)
        .background(theme.primaryBackground)
        .environment(\.theme, themeManager.currentTheme)
        .onAppear {
            Task {
                await estimateIfNeeded()
                await loadHFDetails()
            }
        }
    }

    /// Load Hugging Face model details
    private func loadHFDetails() async {
        guard !isLoadingHFDetails else { return }
        isLoadingHFDetails = true
        let details = await HuggingFaceService.shared.fetchModelDetails(repoId: model.id)
        await MainActor.run {
            self.hfDetails = details
            self.isLoadingHFDetails = false
        }
    }

    // MARK: - Header

    /// Top section with model name, description, and close button
    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 8) {
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

                // Metadata badges row
                HStack(spacing: 6) {
                    // Model type badge (LLM/VLM)
                    modelTypeBadge

                    // Parameter count
                    if let params = model.parameterCount {
                        DetailMetadataPill(text: params, icon: "cpu")
                    }

                    // Quantization
                    if let quant = model.quantization {
                        DetailMetadataPill(text: quant, icon: "gauge.with.dots.needle.bottom.50percent")
                    }
                }

                if !model.description.isEmpty {
                    Text(model.description)
                        .font(.system(size: 13))
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

    /// Badge showing whether model is LLM or VLM
    private var modelTypeBadge: some View {
        let isVLM: Bool = {
            // For downloaded models, check config.json for accurate detection
            if model.isDownloaded {
                return ModelManager.isVisionModel(modelId: model.id)
            }
            // Check HF metadata if available
            if let details = hfDetails {
                return details.isVLM
            }
            // Fall back to name heuristics
            return model.isLikelyVLM
        }()

        let type = isVLM ? MLXModel.ModelType.vlm : MLXModel.ModelType.llm
        let color: Color = isVLM ? .purple : theme.accentColor
        let icon = isVLM ? "eye" : "text.bubble"

        return HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
            Text(type.rawValue)
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundColor(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(color.opacity(0.12))
        )
    }

    // MARK: - Content

    /// Scrollable content area with model information and download size estimation
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Hugging Face Stats
                huggingFaceStatsSection

                Divider()

                // Model Information
                modelInfoSection

                Divider()

                // Download Information
                downloadInfoSection

                Divider()

                // Repository URL
                CopyableURLField(label: "Repository URL", url: model.downloadURL)
            }
            .padding(20)
        }
    }

    // MARK: - Hugging Face Stats Section

    private var huggingFaceStatsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Hugging Face")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.primaryText)

                if isLoadingHFDetails {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle())
                        .scaleEffect(0.6)
                }
            }

            if let details = hfDetails {
                // Stats row with icons
                HStack(spacing: 20) {
                    // Downloads
                    if let downloads = details.downloads {
                        StatItem(
                            icon: "arrow.down.circle.fill",
                            value: formatNumber(downloads),
                            label: "Downloads",
                            color: theme.accentColor
                        )
                    }

                    // Likes
                    if let likes = details.likes {
                        StatItem(
                            icon: "heart.fill",
                            value: formatNumber(likes),
                            label: "Likes",
                            color: .pink
                        )
                    }

                    // License
                    if let license = details.license {
                        StatItem(
                            icon: "doc.text.fill",
                            value: license.uppercased(),
                            label: "License",
                            color: .orange
                        )
                    }
                }

                // Last updated
                if let lastModified = details.lastModified {
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .font(.system(size: 10))
                        Text(
                            "Updated \(RelativeDateTimeFormatter().localizedString(for: lastModified, relativeTo: Date()))"
                        )
                        .font(.system(size: 12))
                    }
                    .foregroundColor(theme.tertiaryText)
                }
            } else if !isLoadingHFDetails {
                Text("Could not load Hugging Face data")
                    .font(.system(size: 12))
                    .foregroundColor(theme.tertiaryText)
            }
        }
    }

    // MARK: - Model Information Section

    private var modelInfoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Model Information")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.primaryText)

            VStack(alignment: .leading, spacing: 8) {
                InfoRow(label: "Repository", value: repositoryName(from: model.downloadURL))

                if let details = hfDetails, let author = details.author {
                    InfoRow(label: "Author", value: author)
                }

                if let details = hfDetails, let modelType = details.modelType {
                    InfoRow(label: "Architecture", value: modelType)
                }

                if let details = hfDetails, let pipelineTag = details.pipelineTag {
                    InfoRow(label: "Task", value: pipelineTag.replacingOccurrences(of: "-", with: " ").capitalized)
                }

                if model.isDownloaded, let downloadedAt = model.downloadedAt {
                    InfoRow(
                        label: "Downloaded",
                        value: RelativeDateTimeFormatter().localizedString(
                            for: downloadedAt,
                            relativeTo: Date()
                        )
                    )
                }
            }
        }
    }

    // MARK: - Download Information Section

    private var downloadInfoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Download")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.primaryText)

            // Estimated download size
            HStack(spacing: 8) {
                Image(systemName: "internaldrive")
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)

                Text("Size:")
                    .font(.system(size: 13))
                    .foregroundColor(theme.secondaryText)

                if isEstimating {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle())
                        .scaleEffect(0.6)
                }

                Text(estimatedSizeString)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(theme.primaryText)

                if !isEstimating {
                    Button(action: { Task { await estimateIfNeeded(force: true) } }) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11))
                            .foregroundColor(theme.accentColor)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .help("Recalculate size")
                }
            }

            if let err = estimateError {
                Text(err)
                    .font(.system(size: 12))
                    .foregroundColor(theme.errorColor)
            }

            // Required files (collapsed by default)
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(ModelManager.snapshotDownloadPatterns, id: \.self) { pattern in
                        Text(pattern)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(theme.tertiaryText)
                    }
                }
                .padding(.top, 4)
            } label: {
                Text("Required files")
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
            }
        }
    }

    // MARK: - Helper Functions

    /// Format large numbers with K/M suffixes
    private func formatNumber(_ number: Int) -> String {
        if number >= 1_000_000 {
            return String(format: "%.1fM", Double(number) / 1_000_000)
        } else if number >= 1_000 {
            return String(format: "%.1fK", Double(number) / 1_000)
        }
        return "\(number)"
    }

    // MARK: - Helper Properties

    /// Normalized model ID for API usage (lowercase, hyphen-separated)
    ///
    /// Example: "mlx-community/Llama-3.2-1B" → "llama-3.2-1b"
    private var apiModelId: String {
        let last = model.id.split(separator: "/").last.map(String.init) ?? model.name
        return
            last
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

// MARK: - Helper Components

/// Stat item for displaying HF stats (downloads, likes, etc.)
private struct StatItem: View {
    @Environment(\.theme) private var theme

    let icon: String
    let value: String
    let label: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundColor(color)

                Text(value)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(theme.primaryText)
            }

            Text(label)
                .font(.system(size: 10))
                .foregroundColor(theme.tertiaryText)
        }
    }
}

/// Small pill-shaped badge for displaying model metadata in detail view
private struct DetailMetadataPill: View {
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
                    .font(.system(size: 9, weight: .medium))
            }
            Text(text)
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundColor(theme.secondaryText)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(theme.tertiaryBackground)
        )
    }
}
