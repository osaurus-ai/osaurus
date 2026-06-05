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

    /// Rendered model card markdown (README with front-matter stripped).
    @State private var readme: String? = nil

    /// Whether the README is currently loading
    @State private var isLoadingReadme = false

    /// Full repo file listing (all files, with per-file size + download flag)
    @State private var allFiles: [HuggingFaceService.MatchedFile]? = nil

    /// Whether the file listing is currently loading
    @State private var isLoadingFiles = false

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
            // Minimal title bar
            headerBar

            // Scrollable Content — README model card leads; everything else
            // is condensed beneath it.
            ScrollView {
                VStack(spacing: 14) {
                    compatibilityLine

                    modelCardSection

                    detailsCard

                    filesSection

                    advancedSection
                }
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 24)
            }
            .opacity(hasAppeared ? 1 : 0)

            // Action Footer
            actionFooter
        }
        .frame(width: 720, height: 720)
        .background(theme.primaryBackground)
        .environment(\.theme, themeManager.currentTheme)
        .onAppear {
            withAnimation(.easeOut(duration: 0.2)) {
                hasAppeared = true
            }

            Task {
                await estimateIfNeeded()
                await loadHFDetails()
                await loadReadmeIfNeeded()
            }
        }
    }

    /// Load the README model card lazily (only when the section is first
    /// expanded) so opening the modal doesn't always pay the extra request.
    private func loadReadmeIfNeeded() async {
        guard readme == nil, !isLoadingReadme else { return }
        isLoadingReadme = true
        let text = await HuggingFaceService.shared.fetchReadme(repoId: model.id)
        await MainActor.run {
            self.readme = text
            self.isLoadingReadme = false
        }
    }

    /// Load the full repo file listing (all files + sizes + download flag).
    private func loadAllFiles() async {
        guard allFiles == nil, !isLoadingFiles else { return }
        isLoadingFiles = true
        let files = await HuggingFaceService.shared.fetchAllFiles(
            repoId: model.id,
            downloadPatterns: ModelDownloadService.downloadFilePatterns,
            excludedFiles: ModelDownloadService.downloadExcludedFiles
        )
        await MainActor.run {
            self.allFiles = files
            self.isLoadingFiles = false
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

    // MARK: - Header Bar

    /// Minimal title bar: a thin brand-colored accent on top, then the model
    /// name + verified/type badges on the left and the Hugging Face link +
    /// close button on the right. Replaces the oversized gradient hero so the
    /// content (model card) leads.
    private var headerBar: some View {
        VStack(spacing: 0) {
            // 3px brand accent keeps the model's identity without the banner.
            LinearGradient(
                colors: ModelCardGradient.colors(for: model),
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(height: 3)

            HStack(spacing: 10) {
                Text(model.name)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if model.isDownloaded {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(theme.accentColor)
                }

                modelTypeBadge

                Spacer(minLength: 12)

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

                Button(action: { dismiss() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(theme.secondaryText)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(theme.tertiaryBackground))
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .background(theme.primaryBackground)
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
            // The plain `open(_:)` is synchronous: it blocks the main thread on a
            // LaunchServices XPC round-trip until the browser is up, which can
            // stall the UI for seconds on a cold launch. The configuration-based
            // form dispatches the open asynchronously and returns immediately.
            NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration())
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

    // MARK: - Details Card

    /// Every fact about the model, condensed into a single card: a 2-column
    /// grid of compact label/value pairs (only the ones we actually have)
    /// plus the tag chips. Replaces the old "About" rows + 2x2 stat tiles.
    private var detailsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Details", bundle: .module)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.primaryText)

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 16, alignment: .topLeading),
                    GridItem(.flexible(), spacing: 16, alignment: .topLeading),
                ],
                alignment: .leading,
                spacing: 12
            ) {
                MetaItem(label: L("Download size"), value: estimatedSizeString)

                MetaItem(
                    label: L("Type"),
                    value: detectIsVLM() ? L("Vision + Language") : L("Language")
                )

                if let params = model.parameterCount {
                    MetaItem(label: L("Parameters"), value: params)
                }

                if let quant = model.quantization {
                    MetaItem(label: L("Quantization"), value: quant)
                }

                if let license = hfDetails?.license {
                    MetaItem(label: L("License"), value: license.uppercased())
                }

                if let downloads = hfDetails?.downloads {
                    MetaItem(label: L("Downloads"), value: formatNumber(downloads))
                }

                if let likes = hfDetails?.likes {
                    MetaItem(label: L("Likes"), value: formatNumber(likes))
                }

                if let updated = hfDetails?.lastModified {
                    MetaItem(label: L("Updated"), value: formatRelativeDate(updated))
                }

                if let pipelineTag = hfDetails?.pipelineTag {
                    MetaItem(
                        label: L("Task"),
                        value: pipelineTag.replacingOccurrences(of: "-", with: " ").capitalized
                    )
                }

                if let author = hfDetails?.author {
                    MetaItem(label: L("Author"), value: author)
                }

                if let baseModels = hfDetails?.baseModels, !baseModels.isEmpty {
                    MetaItem(label: L("Based on"), value: baseModels.joined(separator: ", "))
                }

                if let source = model.externalSource {
                    MetaItem(label: L("Source"), value: source)
                }

                if model.isDownloaded, let downloadedAt = model.downloadedAt {
                    MetaItem(
                        label: L("Downloaded"),
                        value: RelativeDateTimeFormatter().localizedString(
                            for: downloadedAt,
                            relativeTo: Date()
                        )
                    )
                }
            }

            if !displayTags.isEmpty {
                Divider()
                    .background(theme.cardBorder)

                TagFlowLayout(spacing: 6, runSpacing: 6) {
                    ForEach(displayTags, id: \.self) { tag in
                        MetadataPill(text: tag, icon: nil, color: theme.secondaryText)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .detailCardSurface()
    }

    /// Curated subset of HF tags worth showing as chips. Drops the
    /// machine-oriented `key:value` tags (license:, base_model:, region:,
    /// arxiv:, doi:, etc.) and the bare `mlx`/format noise we already
    /// surface elsewhere, then caps the count so the card stays compact.
    private var displayTags: [String] {
        guard let tags = hfDetails?.tags else { return [] }
        let dropPrefixes = ["license:", "base_model", "region:", "arxiv:", "doi:", "dataset:"]
        let dropExact: Set<String> = ["mlx", "safetensors", "transformers", "text-generation"]
        var seen = Set<String>()
        var result: [String] = []
        for tag in tags {
            let lower = tag.lowercased()
            if dropPrefixes.contains(where: { lower.hasPrefix($0) }) { continue }
            if dropExact.contains(lower) { continue }
            if lower.contains(":") { continue }
            guard seen.insert(lower).inserted else { continue }
            result.append(tag)
            if result.count >= 8 { break }
        }
        return result
    }

    // MARK: - Compatibility Line

    /// Slim, single-row "will it run on this Mac?" verdict. Kept compact so
    /// the README leads, but still the first thing visible for a pre-download
    /// decision.
    private var compatibilityLine: some View {
        let verdict = model.compatibility(totalMemoryGB: systemMonitor.totalMemoryGB)
        let totalMem = systemMonitor.totalMemoryGB

        // The memory estimate reads the same for every verdict except
        // `.unknown` (where we have nothing to show), so compute it once.
        let memoryDetail = String(
            format: L("~%@ of %.0f GB"),
            model.formattedEstimatedMemory ?? "—",
            totalMem
        )

        let (icon, title, detail, tint): (String, String, String, Color) = {
            switch verdict {
            case .compatible:
                return (
                    "checkmark.shield.fill",
                    L("Should run smoothly on this Mac"),
                    memoryDetail,
                    theme.successColor
                )
            case .tight:
                return (
                    "exclamationmark.triangle.fill",
                    L("Will be a tight fit"),
                    memoryDetail,
                    theme.warningColor
                )
            case .tooLarge:
                return (
                    "xmark.octagon.fill",
                    L("Too large for this Mac"),
                    memoryDetail,
                    theme.errorColor
                )
            case .unknown:
                return (
                    "questionmark.circle.fill",
                    L("Compatibility unknown"),
                    "",
                    theme.tertiaryText
                )
            }
        }()

        return HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(tint)

            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.primaryText)
                .lineLimit(1)

            Spacer(minLength: 8)

            if !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(theme.secondaryText)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(tint.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(tint.opacity(0.22), lineWidth: 1)
                )
        )
    }

    // MARK: - Model Card (README)

    /// The model's README, rendered with the full-fidelity chat markdown
    /// engine. This is the primary content of the modal — always visible and
    /// loaded eagerly on appear.
    private var modelCardSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Model Card", bundle: .module)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.primaryText)

                Spacer()

                if isLoadingReadme {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle())
                        .scaleEffect(0.5)
                        .frame(width: 12, height: 12)
                }
            }

            if let readme {
                MarkdownDocument(text: readme)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if isLoadingReadme {
                Text("Loading model card…", bundle: .module)
                    .font(.system(size: 12))
                    .foregroundColor(theme.tertiaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("No model card available.", bundle: .module)
                    .font(.system(size: 12))
                    .foregroundColor(theme.tertiaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .detailCardSurface()
    }

    // MARK: - Files Section

    /// Lists every file in the repo with its size, marking the ones
    /// Osaurus actually downloads. Falls back to a loading state while the
    /// tree request is in flight.
    private var filesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isFilesExpanded.toggle()
                }
                if isFilesExpanded {
                    Task { await loadAllFiles() }
                }
            }) {
                HStack {
                    Text("Files", bundle: .module)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(theme.primaryText)

                    if let files = allFiles {
                        Text("\(files.count)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(theme.tertiaryText)
                    }

                    Spacer()

                    if isLoadingFiles {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle())
                            .scaleEffect(0.5)
                            .frame(width: 12, height: 12)
                    }

                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(theme.tertiaryText)
                        .rotationEffect(.degrees(isFilesExpanded ? 90 : 0))
                }
                .padding(14)
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())

            if isFilesExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    if let files = allFiles, !files.isEmpty {
                        ForEach(files, id: \.path) { file in
                            FileRow(file: file)
                        }
                    } else if isLoadingFiles {
                        Text("Loading files…", bundle: .module)
                            .font(.system(size: 12))
                            .foregroundColor(theme.tertiaryText)
                    } else {
                        // Network listing unavailable — fall back to the
                        // static download-pattern hint so the section is
                        // never empty.
                        ForEach(ModelDownloadService.downloadFilePatterns, id: \.self) { pattern in
                            Text(pattern)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(theme.tertiaryText)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }
        }
        .detailCardSurface()
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
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }
        }
        .detailCardSurface()
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
                    downloadingFooter(progress: progress, isPaused: false)

                case .paused(let progress):
                    downloadingFooter(progress: progress, isPaused: true)

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

    private func downloadingFooter(progress: Double, isPaused: Bool) -> some View {
        VStack(spacing: 10) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(theme.tertiaryBackground)

                    RoundedRectangle(cornerRadius: 4)
                        .fill(isPaused ? theme.tertiaryText : theme.accentColor)
                        .frame(width: max(0, geometry.size.width * progress))
                }
            }
            .frame(height: 6)

            HStack(spacing: 8) {
                Text("\(Int(progress * 100))%", bundle: .module)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(theme.primaryText)

                if isPaused {
                    Text("Paused", bundle: .module)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(theme.warningColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(theme.warningColor.opacity(0.12))
                        )
                } else if let line = formattedMetricsLine() {
                    Text("•")
                        .foregroundColor(theme.tertiaryText)
                    Text(line)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(theme.secondaryText)
                }

                Spacer()

                if isPaused {
                    Button(action: { modelManager.resumeDownload(model.id) }) {
                        Text("Resume", bundle: .module)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(theme.accentColor)
                    }
                    .buttonStyle(PlainButtonStyle())
                } else {
                    Button(action: { modelManager.pauseDownload(model.id) }) {
                        Text("Pause", bundle: .module)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(theme.secondaryText)
                    }
                    .buttonStyle(PlainButtonStyle())
                }

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
                Task { await modelManager.deleteModel(model) }
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

/// Compact label-over-value pair for the Details grid.
private struct MetaItem: View {
    @Environment(\.theme) private var theme

    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
                .lineLimit(1)

            Text(value)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(theme.primaryText)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
        .localizedHelp("Copy '\(modelId)' for API usage")
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
                .help(showCopied ? Text(localized: "Copied!") : Text(localized: "Copy URL"))
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

/// One row in the repo file listing: relative path, byte size, and a
/// subtle marker when the file is part of what Osaurus downloads.
private struct FileRow: View {
    @Environment(\.theme) private var theme
    let file: HuggingFaceService.MatchedFile

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: file.isDownloaded ? "arrow.down.circle.fill" : "doc")
                .font(.system(size: 10))
                .foregroundColor(file.isDownloaded ? theme.accentColor : theme.tertiaryText)

            Text(file.path)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(file.isDownloaded ? theme.secondaryText : theme.tertiaryText)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(theme.tertiaryText)
        }
        .padding(.vertical, 1)
    }
}

/// Simple wrapping flow layout for the tag chips. Mirrors the existing
/// chip layouts used elsewhere (e.g. `ChipFlowLayout`).
private struct TagFlowLayout: Layout {
    var spacing: CGFloat = 6
    var runSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        arrange(in: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) {
        for placement in arrange(in: bounds.width, subviews: subviews).placements {
            placement.subview.place(
                at: CGPoint(x: bounds.minX + placement.origin.x, y: bounds.minY + placement.origin.y),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: placement.size.width, height: placement.size.height)
            )
        }
    }

    private struct Placement {
        var subview: LayoutSubview
        var origin: CGPoint
        var size: CGSize
    }

    private struct Arrangement {
        var placements: [Placement]
        var size: CGSize
    }

    private func arrange(in maxWidth: CGFloat, subviews: Subviews) -> Arrangement {
        var placements: [Placement] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += lineHeight + runSpacing
                lineHeight = 0
            }
            placements.append(Placement(subview: subview, origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            totalWidth = max(totalWidth, x - spacing)
        }
        return Arrangement(placements: placements, size: CGSize(width: totalWidth, height: y + lineHeight))
    }
}

// MARK: - Card Surface

/// Standard rounded card chrome (fill + 1px border) shared by the detail
/// modal's sections so the styling stays consistent in one place.
private struct DetailCardSurface: ViewModifier {
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content.background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(theme.cardBorder, lineWidth: 1)
                )
        )
    }
}

extension View {
    fileprivate func detailCardSurface() -> some View {
        modifier(DetailCardSurface())
    }
}
