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
    @ObservedObject private var systemMonitor = SystemMonitorService.shared
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

    /// Whether the Advanced section is expanded
    @State private var isAdvancedExpanded = false

    /// Repair status: nil = idle, true = succeeded, false = failed
    @State private var isRepairing = false
    @State private var repairResult: Bool?

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

            // Metadata pills + Hugging Face link sit just under the hero
            metaStrip

            // Scrollable Content
            ScrollView {
                VStack(spacing: 16) {
                    compatibilityCallout

                    modelDetailsCard

                    statsGrid

                    advancedSection
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
        ZStack {
            LinearGradient(
                colors: ModelCardGradient.colors(for: model),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [.white.opacity(0.32), .white.opacity(0)],
                center: UnitPoint(x: 0.18, y: 0.18),
                startRadius: 4,
                endRadius: 320
            )

            RadialGradient(
                colors: [.black.opacity(0.30), .black.opacity(0)],
                center: UnitPoint(x: 0.92, y: 0.95),
                startRadius: 4,
                endRadius: 360
            )

            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Text(model.name)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(.white)
                        .shadow(color: .black.opacity(0.22), radius: 2, x: 0, y: 1)
                        .lineLimit(1)
                        .multilineTextAlignment(.center)

                    if model.isDownloaded {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 15))
                            .foregroundColor(.white)
                    }
                }

                if !model.description.isEmpty {
                    Text(model.description)
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.88))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 56)

            VStack {
                HStack {
                    Spacer()
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(.black.opacity(0.32)))
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                Spacer()
            }
            .padding(16)
        }
    }

    private var metaStrip: some View {
        HStack(spacing: 8) {
            if let size = sizeChipText {
                MetadataPill(text: size, icon: nil, color: theme.secondaryText)
            }

            modelTypeBadge

            if let params = model.parameterCount {
                MetadataPill(text: params, icon: nil, color: theme.secondaryText)
            }

            if let quant = model.quantization {
                MetadataPill(text: quant, icon: nil, color: theme.secondaryText)
            }

            Spacer()

            Button(action: openHuggingFace) {
                HStack(spacing: 5) {
                    Text("🤗")
                        .font(.system(size: 12))
                    Text("View on Hugging Face", bundle: .module)
                        .font(.system(size: 12, weight: .medium))
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9, weight: .semibold))
                }
                .foregroundColor(theme.accentColor)
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(theme.secondaryBackground)
        .overlay(
            Rectangle()
                .fill(theme.cardBorder)
                .frame(height: 1),
            alignment: .bottom
        )
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
        let typeLabel = isVLM ? "VLM" : "LLM"
        let color: Color = isVLM ? .purple : theme.accentColor

        return Text(typeLabel)
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
        if model.isDownloaded { return model.isVLM }
        if let details = hfDetails, let mt = details.modelType {
            return VLMDetection.isVLM(modelType: mt)
        }
        return model.isVLM
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
            Text("About this model", bundle: .module)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.primaryText)

            // Info Rows — only the rows a non-technical user cares about.
            // Architecture / repo id / required files live in `advancedSection`.
            VStack(spacing: 10) {
                if let author = hfDetails?.author {
                    DetailInfoRow(label: "Author", value: author)
                }

                if let pipelineTag = hfDetails?.pipelineTag {
                    DetailInfoRow(
                        label: "Task",
                        value: pipelineTag.replacingOccurrences(of: "-", with: " ").capitalized
                    )
                }

                DetailInfoRow(
                    label: "Type",
                    value: detectIsVLM()
                        ? L("Vision + Language")
                        : L("Language")
                )

                DetailInfoRow(label: "Download size", value: estimatedSizeString)

                if model.isDownloaded, let downloadedAt = model.downloadedAt {
                    DetailInfoRow(
                        label: "Downloaded",
                        value: RelativeDateTimeFormatter().localizedString(for: downloadedAt, relativeTo: Date())
                    )
                }
            }
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

    // MARK: - Compatibility Callout

    /// Headline "will it run on this Mac?" treatment so the verdict
    /// dominates the modal instead of being buried in a stats pill.
    private var compatibilityCallout: some View {
        let verdict = model.compatibility(totalMemoryGB: systemMonitor.totalMemoryGB)
        let totalMem = systemMonitor.totalMemoryGB

        let (icon, title, subtitle, tint): (String, String, String, Color) = {
            switch verdict {
            case .compatible:
                return (
                    "checkmark.shield.fill",
                    L("Should run smoothly on this Mac"),
                    String(format: L("Estimated %@ used of %.0f GB unified memory"),
                           model.formattedEstimatedMemory ?? "—", totalMem),
                    theme.successColor
                )
            case .tight:
                return (
                    "exclamationmark.triangle.fill",
                    L("Will be a tight fit"),
                    String(format: L("Estimated %@ on a %.0f GB Mac — close other apps for best results"),
                           model.formattedEstimatedMemory ?? "—", totalMem),
                    theme.warningColor
                )
            case .tooLarge:
                return (
                    "xmark.octagon.fill",
                    L("Too large for this Mac"),
                    String(format: L("Estimated %@ exceeds the %.0f GB available — try a smaller variant"),
                           model.formattedEstimatedMemory ?? "—", totalMem),
                    theme.errorColor
                )
            case .unknown:
                return (
                    "questionmark.circle.fill",
                    L("Compatibility unknown"),
                    L("We couldn't estimate memory needs for this model."),
                    theme.tertiaryText
                )
            }
        }()

        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundColor(tint)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(tint.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(tint.opacity(0.25), lineWidth: 1)
                )
        )
    }

    // MARK: - Advanced Section

    /// Collapsible group for the developer-oriented content. Hidden by
    /// default so the modal reads cleanly for non-technical users.
    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isAdvancedExpanded.toggle()
                }
            }) {
                HStack {
                    Text("Advanced", bundle: .module)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(theme.primaryText)

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(theme.tertiaryText)
                        .rotationEffect(.degrees(isAdvancedExpanded ? 90 : 0))
                }
                .padding(14)
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())

            if isAdvancedExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    DetailInfoRow(label: "Repository", value: repositoryName(from: model.downloadURL))

                    if let modelType = hfDetails?.modelType {
                        DetailInfoRow(label: "Architecture", value: modelType)
                    }

                    HStack {
                        Text("Model ID for API", bundle: .module)
                            .font(.system(size: 13))
                            .foregroundColor(theme.secondaryText)
                        Spacer()
                        CopyModelIdButton(modelId: apiModelId)
                    }

                    RepositoryLinkRow(url: model.downloadURL)

                    RequiredFilesSection(isExpanded: $isFilesExpanded)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }
        }
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
                Text("Cancel", bundle: .module)
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
                    Text("Download", bundle: .module)
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
                Text("\(Int(progress * 100))%", bundle: .module)
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
                    Text("Cancel", bundle: .module)
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
                Text("Delete Model", bundle: .module)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(theme.errorColor)
            }
            .buttonStyle(PlainButtonStyle())

            Button(action: {
                repairResult = nil
                isRepairing = true
                Task {
                    await repairModel()
                    isRepairing = false
                }
            }) {
                HStack(spacing: 4) {
                    if isRepairing {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle())
                            .scaleEffect(0.5)
                            .frame(width: 12, height: 12)
                    } else if let result = repairResult {
                        Image(systemName: result ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(result ? theme.successColor : theme.errorColor)
                    }
                    Text("Repair", bundle: .module)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.accentColor)
                }
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(isRepairing)

            Spacer()

            Button(action: { dismiss() }) {
                Text("Done", bundle: .module)
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

    // MARK: - Repair

    private func repairModel() async {
        let success = await ModelDownloadService.ensureComplete(
            for: model,
            directory: model.localDirectory,
            clearSentinel: true
        )
        await MainActor.run { repairResult = success }
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

    /// Compact size string for the meta-strip pill. Uses the
    /// network resolved size when available, otherwise the params×quant
    /// estimate. Returns nil only when neither is known.
    private var sizeChipText: String? {
        if let s = estimatedSize, s > 0 {
            return ByteCountFormatter.string(fromByteCount: s, countStyle: .file)
        }
        return model.formattedDownloadSize
    }

    /// Formatted string for the estimated download size.
    /// Prefers the network-resolved size; falls back to the
    /// params×quantization estimate so the modal isn't blank while loading.
    private var estimatedSizeString: String {
        if let s = estimatedSize, s > 0 {
            return ByteCountFormatter.string(fromByteCount: s, countStyle: .file)
        }
        if let fallback = model.formattedDownloadSize {
            return model.downloadSizeBytes != nil ? fallback : "~\(fallback)"
        }
        return L("Unknown")
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

    private func formattedMetricsLine() -> String? {
        modelManager.downloadMetrics[model.id]?.formattedLine
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
        .help(Text("Copy '\(modelId)' for API usage", bundle: .module))
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
                    Text("Required Files", bundle: .module)
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
                    ForEach(ModelDownloadService.downloadFilePatterns, id: \.self) { pattern in
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
