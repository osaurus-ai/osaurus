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

    @ObservedObject private var modelManager = ModelManager.shared
    @ObservedObject private var themeManager = ThemeManager.shared
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

    /// Whether content has appeared (for entrance animation)
    @State private var hasAppeared = false

    /// Whether the required files section is expanded
    @State private var isFilesExpanded = false

    /// Normalized model ID for API usage
    private var apiModelId: String {
        let last = model.id.split(separator: "/").last.map(String.init) ?? model.name
        return
            last
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
    }

    var body: some View {
        VStack(spacing: 0) {
            // Hero Header
            heroHeader

            // Scrollable Content
            ScrollView {
                VStack(spacing: 20) {
                    // Stats Grid
                    statsGrid

                    // Model Details Card
                    modelDetailsCard

                    // Download Info Card
                    downloadInfoCard
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 24)
            }
            .opacity(hasAppeared ? 1 : 0)

            // Action Footer
            actionFooter
        }
        .frame(width: 560, height: 580)
        .background(theme.primaryBackground)
        .environment(\.theme, themeManager.currentTheme)
        .onAppear {
            withAnimation(.easeOut(duration: 0.2)) {
                hasAppeared = true
            }

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

    // MARK: - Hero Header

    private var heroHeader: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                // Model Info
                VStack(alignment: .leading, spacing: 8) {
                    // Model name and status
                    HStack(spacing: 8) {
                        Text(model.name)
                            .font(.system(size: 20, weight: .bold))
                            .foregroundColor(theme.primaryText)
                            .lineLimit(1)

                        if model.isDownloaded {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundColor(theme.successColor)
                        }
                    }

                    // Metadata pills
                    HStack(spacing: 6) {
                        modelTypeBadge

                        if let params = model.parameterCount {
                            MetadataPill(text: params, icon: nil, color: theme.secondaryText)
                        }

                        if let quant = model.quantization {
                            MetadataPill(text: quant, icon: nil, color: theme.secondaryText)
                        }
                    }

                    // Description
                    if !model.description.isEmpty {
                        Text(model.description)
                            .font(.system(size: 13))
                            .foregroundColor(theme.secondaryText)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Close button
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.tertiaryText)
                        .frame(width: 24, height: 24)
                        .background(
                            Circle()
                                .fill(theme.tertiaryBackground)
                        )
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 16)

            // Action row: HuggingFace link + Copy Model ID
            HStack(spacing: 12) {
                // Hugging Face link
                Button(action: openHuggingFace) {
                    HStack(spacing: 5) {
                        Text("🤗")
                            .font(.system(size: 12))
                        Text("View on Hugging Face")
                            .font(.system(size: 12, weight: .medium))
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundColor(theme.accentColor)
                }
                .buttonStyle(PlainButtonStyle())

                Spacer()

                // Copy Model ID for API
                CopyModelIdButton(modelId: apiModelId)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)

            Divider()
        }
        .background(theme.secondaryBackground)
    }

    /// Open HuggingFace page in browser
    private func openHuggingFace() {
        if let url = URL(string: model.downloadURL) {
            NSWorkspace.shared.open(url)
        }
    }

    /// Badge showing whether model is LLM or VLM
    private var modelTypeBadge: some View {
        let isVLM = detectIsVLM()
        let type = isVLM ? MLXModel.ModelType.vlm : MLXModel.ModelType.llm
        let color: Color = isVLM ? .purple : theme.accentColor

        return Text(type.rawValue)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(color.opacity(0.12))
            )
    }

    /// Detect if model is VLM
    private func detectIsVLM() -> Bool {
        if model.isDownloaded {
            return ModelManager.isVisionModel(modelId: model.id)
        }
        if let details = hfDetails {
            return details.isVLM
        }
        return model.isLikelyVLM
    }

    // MARK: - Stats Grid

    private var statsGrid: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                StatCardView(
                    icon: "arrow.down.circle",
                    value: hfDetails?.downloads.map { formatNumber($0) } ?? "—",
                    label: "Downloads",
                    color: .blue,
                    isLoading: isLoadingHFDetails && hfDetails == nil
                )

                StatCardView(
                    icon: "heart",
                    value: hfDetails?.likes.map { formatNumber($0) } ?? "—",
                    label: "Likes",
                    color: .pink,
                    isLoading: isLoadingHFDetails && hfDetails == nil
                )
            }

            HStack(spacing: 10) {
                StatCardView(
                    icon: "doc.text",
                    value: hfDetails?.license?.uppercased() ?? "—",
                    label: "License",
                    color: .orange,
                    isLoading: isLoadingHFDetails && hfDetails == nil
                )

                StatCardView(
                    icon: "clock",
                    value: hfDetails?.lastModified.map { formatRelativeDate($0) } ?? "—",
                    label: "Updated",
                    color: .green,
                    isLoading: isLoadingHFDetails && hfDetails == nil
                )
            }
        }
    }

    // MARK: - Model Details Card

    private var modelDetailsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Card Header
            Text("Model Details")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.primaryText)

            // Info Rows
            VStack(spacing: 10) {
                DetailInfoRow(label: "Repository", value: repositoryName(from: model.downloadURL))

                if let author = hfDetails?.author {
                    DetailInfoRow(label: "Author", value: author)
                }

                if let modelType = hfDetails?.modelType {
                    DetailInfoRow(label: "Architecture", value: modelType)
                }

                if let pipelineTag = hfDetails?.pipelineTag {
                    DetailInfoRow(
                        label: "Task",
                        value: pipelineTag.replacingOccurrences(of: "-", with: " ").capitalized
                    )
                }

                if model.isDownloaded, let downloadedAt = model.downloadedAt {
                    DetailInfoRow(
                        label: "Downloaded",
                        value: RelativeDateTimeFormatter().localizedString(for: downloadedAt, relativeTo: Date())
                    )
                }
            }

            // Repository URL
            RepositoryLinkRow(url: model.downloadURL)
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
    }

    // MARK: - Download Info Card

    private var downloadInfoCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Card Header
            Text("Download")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.primaryText)

            // Size Row
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "internaldrive.fill")
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)
                    Text("Estimated Size")
                        .font(.system(size: 13))
                        .foregroundColor(theme.secondaryText)
                }

                Spacer()

                if isEstimating {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle())
                        .scaleEffect(0.6)
                } else {
                    HStack(spacing: 8) {
                        Text(estimatedSizeString)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(theme.primaryText)

                        Button(action: { Task { await estimateIfNeeded(force: true) } }) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(theme.accentColor)
                        }
                        .buttonStyle(PlainButtonStyle())
                        .help("Recalculate size")
                    }
                }
            }

            if let err = estimateError {
                Text(err)
                    .font(.system(size: 11))
                    .foregroundColor(theme.errorColor)
            }

            // Required Files Section
            RequiredFilesSection(isExpanded: $isFilesExpanded)
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
    }

    // MARK: - Action Footer

    private var actionFooter: some View {
        VStack(spacing: 0) {
            Divider()

            Group {
                switch modelManager.effectiveDownloadState(for: model) {
                case .notStarted, .failed:
                    notStartedFooter

                case .downloading(let progress):
                    downloadingFooter(progress: progress)

                case .completed:
                    completedFooter
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
    }

    private var notStartedFooter: some View {
        HStack(spacing: 12) {
            Button(action: { dismiss() }) {
                Text("Cancel")
                    .font(.system(size: 13, weight: .medium))
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
                        .font(.system(size: 13))
                    Text("Download")
                        .font(.system(size: 14, weight: .semibold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.accentColor)
                )
            }
            .buttonStyle(PlainButtonStyle())
        }
    }

    private func downloadingFooter(progress: Double) -> some View {
        VStack(spacing: 10) {
            // Progress bar
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(theme.tertiaryBackground)

                    RoundedRectangle(cornerRadius: 4)
                        .fill(theme.accentColor)
                        .frame(width: max(0, geometry.size.width * progress))
                }
            }
            .frame(height: 6)

            // Info row
            HStack {
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(theme.primaryText)

                if let line = formattedMetricsLine() {
                    Text("•")
                        .foregroundColor(theme.tertiaryText)
                    Text(line)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(theme.secondaryText)
                }

                Spacer()

                Button(action: { modelManager.cancelDownload(model.id) }) {
                    Text("Cancel")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.errorColor)
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
    }

    private var completedFooter: some View {
        HStack(spacing: 12) {
            Button(action: {
                modelManager.deleteModel(model)
                dismiss()
            }) {
                Text("Delete Model")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(theme.errorColor)
            }
            .buttonStyle(PlainButtonStyle())

            Spacer()

            Button(action: { dismiss() }) {
                Text("Done")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(theme.accentColor)
                    )
            }
            .buttonStyle(PlainButtonStyle())
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

    /// Format relative date
    private func formatRelativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    /// Formatted string for the estimated download size
    private var estimatedSizeString: String {
        if let s = estimatedSize, s > 0 {
            return ByteCountFormatter.string(fromByteCount: s, countStyle: .file)
        }
        return "Unknown"
    }

    /// Fetches download size estimation from the model manager if not already calculated
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

    /// Formats download metrics into a human-readable string
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

/// Stat card with value and label
private struct StatCardView: View {
    @Environment(\.theme) private var theme

    let icon: String
    let value: String
    let label: String
    let color: Color
    var isLoading: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            // Value and Label
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)

                if isLoading {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(theme.tertiaryBackground)
                        .frame(width: 50, height: 18)
                        .shimmer()
                } else {
                    Text(value)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)
                }
            }

            Spacer()

            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(color.opacity(0.6))
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(theme.cardBorder, lineWidth: 1)
                )
        )
    }
}

/// Metadata pill badge
private struct MetadataPill: View {
    let text: String
    let icon: String?
    let color: Color

    init(text: String, icon: String? = nil, color: Color) {
        self.text = text
        self.icon = icon
        self.color = color
    }

    var body: some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .medium))
            }
            Text(text)
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundColor(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(color.opacity(0.08))
        )
    }
}

/// Copy model ID button for API usage
private struct CopyModelIdButton: View {
    @Environment(\.theme) private var theme

    let modelId: String
    @State private var showCopied = false
    @State private var isHovering = false

    var body: some View {
        Button(action: copyModelId) {
            HStack(spacing: 5) {
                Image(systemName: showCopied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 10, weight: .medium))
                Text(showCopied ? "Copied!" : "Copy Model ID")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(showCopied ? theme.successColor : theme.secondaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovering ? theme.tertiaryBackground : theme.tertiaryBackground.opacity(0.6))
            )
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering in
            isHovering = hovering
        }
        .help("Copy '\(modelId)' for API usage")
    }

    private func copyModelId() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(modelId, forType: .string)

        withAnimation(.easeInOut(duration: 0.15)) {
            showCopied = true
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            withAnimation(.easeInOut(duration: 0.15)) {
                showCopied = false
            }
        }
    }
}

/// Detail info row for model details card
private struct DetailInfoRow: View {
    @Environment(\.theme) private var theme

    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
                .foregroundColor(theme.secondaryText)

            Spacer()

            Text(value)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(theme.primaryText)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
    }
}

/// Repository link row with open and copy buttons
private struct RepositoryLinkRow: View {
    @Environment(\.theme) private var theme

    let url: String
    @State private var showCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
                .padding(.vertical, 4)

            HStack(spacing: 8) {
                // Clickable URL
                Button(action: openURL) {
                    HStack(spacing: 6) {
                        Image(systemName: "link")
                            .font(.system(size: 10))
                        Text(url)
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 8, weight: .semibold))
                    }
                    .foregroundColor(theme.accentColor)
                }
                .buttonStyle(PlainButtonStyle())

                Spacer()

                // Copy button
                Button(action: copyURL) {
                    Image(systemName: showCopied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(showCopied ? theme.successColor : theme.tertiaryText)
                }
                .buttonStyle(PlainButtonStyle())
                .help(showCopied ? "Copied!" : "Copy URL")
            }
        }
    }

    private func openURL() {
        if let url = URL(string: url) {
            NSWorkspace.shared.open(url)
        }
    }

    private func copyURL() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)

        withAnimation(.easeInOut(duration: 0.15)) {
            showCopied = true
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            withAnimation(.easeInOut(duration: 0.15)) {
                showCopied = false
            }
        }
    }
}

/// Required files expandable section
private struct RequiredFilesSection: View {
    @Environment(\.theme) private var theme
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            }) {
                HStack {
                    Text("Required Files")
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(theme.tertiaryText)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())

            if isExpanded {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(ModelManager.snapshotDownloadPatterns, id: \.self) { pattern in
                        Text(pattern)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(theme.tertiaryText)
                    }
                }
                .padding(.leading, 12)
                .padding(.top, 2)
            }
        }
    }
}

// MARK: - Shimmer Effect

private struct ShimmerModifier: ViewModifier {
    @State private var isAnimating = false

    func body(content: Content) -> some View {
        content
            .opacity(isAnimating ? 0.5 : 1.0)
            .animation(
                .easeInOut(duration: 1.0).repeatForever(autoreverses: true),
                value: isAnimating
            )
            .onAppear {
                isAnimating = true
            }
    }
}

private extension View {
    func shimmer() -> some View {
        modifier(ShimmerModifier())
    }
}
