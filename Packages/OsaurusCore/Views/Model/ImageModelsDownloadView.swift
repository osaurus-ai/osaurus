//
//  ImageModelsDownloadView.swift
//  osaurus
//
//  The "Images" tab of the Models window: stage on-device image-generation
//  bundles (vMLXFlux / mflux) so they become selectable in the chat model
//  picker. Renders image models through the same `ModelRowView` card the
//  On Device / Catalog tabs use, so the grid is visually identical. Curated
//  models download on tap; arbitrary image repos are added via the global
//  Import button, which auto-detects image bundles and routes them here.
//

import SwiftUI

struct ImageModelsDownloadView: View {
    @ObservedObject private var downloads = ImageModelDownloadService.shared
    @Environment(\.theme) private var theme

    @State private var installed: [ImageModelInfo] = []
    @State private var detail: DetailRequest?

    /// Identifiable payload for presenting the detail modal.
    private struct DetailRequest: Identifiable {
        let id: String
        let displayName: String
        let repoId: String?
        let info: ImageModelInfo?
    }

    /// Non-optional download state for a bundle id (absent ⇒ not started).
    private func state(_ id: String) -> DownloadState {
        downloads.states[id] ?? .notStarted
    }

    /// One card per image model: installed bundles first, then curated
    /// suggestions not yet on disk.
    private struct Card: Identifiable {
        let id: String
        let content: ModelCardContent
        /// Download source; `nil` for installed-only rows.
        let repoId: String?
        let displayName: String
    }

    private var cards: [Card] {
        var out: [Card] = []
        var seen = Set<String>()
        for model in installed {
            seen.insert(model.id)
            out.append(
                Card(
                    id: model.id, content: content(forInstalled: model), repoId: nil,
                    displayName: model.displayName))
        }
        for entry in ImageModelDownloadService.catalog where !seen.contains(entry.id) {
            out.append(
                Card(
                    id: entry.id, content: content(forCatalog: entry), repoId: entry.repoId,
                    displayName: entry.displayName))
        }
        return out
    }

    // Match the catalog grid: adaptive columns (≥260) with 12pt column and
    // 20pt row spacing.
    private let columns = [GridItem(.adaptive(minimum: 260), spacing: 12, alignment: .top)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(cards) { card($0) }
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .task { await refreshInstalled() }
        .onReceive(NotificationCenter.default.publisher(for: .localModelsChanged)) { _ in
            Task { await refreshInstalled() }
        }
        .sheet(item: $detail) { request in
            ImageModelDetailView(
                id: request.id,
                displayName: request.displayName,
                repoId: request.repoId,
                info: request.info
            )
            .environment(\.theme, theme)
        }
    }

    private func card(_ card: Card) -> some View {
        ModelRowView(
            content: card.content,
            downloadState: state(card.id),
            metrics: downloads.metrics[card.id],
            onViewDetails: { tap(card) },
            onCancel: { downloads.cancel(card.id) }
        )
    }

    /// Card tap opens the detail modal (download / delete / re-download live
    /// there), matching the On Device / Catalog tabs.
    private func tap(_ card: Card) {
        detail = DetailRequest(
            id: card.id,
            displayName: card.displayName,
            repoId: card.repoId,
            info: installed.first { $0.id == card.id }
        )
    }

    // MARK: - Card content

    private func content(forInstalled model: ImageModelInfo) -> ModelCardContent {
        ModelCardContent(
            name: model.displayName,
            description: model.ready
                ? L("On-device image model")
                : (model.blockedReasons.first ?? L("Not ready")),
            gradientColors: ModelCardGradient.colors(
                family: model.canonicalName ?? model.id, id: model.id),
            isTopSuggestion: false,
            isDownloaded: true,
            useCase: nil,
            compatibility: .unknown,
            type: .image,
            size: model.totalBytes > 0
                ? ByteCountFormatter.string(fromByteCount: Int64(model.totalBytes), countStyle: .file)
                : nil,
            params: nil,
            quant: quantText(bits: model.quantizationBits, id: model.id),
            downloadsText: nil,
            releaseText: nil
        )
    }

    private func content(forCatalog entry: ImageModelDownload) -> ModelCardContent {
        ModelCardContent(
            name: entry.displayName,
            description: entry.note ?? "",
            gradientColors: ModelCardGradient.colors(family: entry.id, id: entry.id),
            isTopSuggestion: false,
            isDownloaded: false,
            useCase: nil,
            compatibility: .unknown,
            type: .image,
            size: nil,
            params: nil,
            quant: quantText(bits: nil, id: entry.repoId),
            downloadsText: nil,
            releaseText: nil
        )
    }

    /// Best-effort quantization label: explicit bit width when known, else
    /// parsed from the repo/dir name (fp8, NF4, 4/6/8-bit).
    private func quantText(bits: Int?, id: String) -> String? {
        if let bits { return "\(bits)-bit" }
        let lower = id.lowercased()
        if lower.contains("fp8") { return "FP8" }
        if lower.contains("nf4") { return "NF4" }
        if lower.contains("8bit") || lower.contains("8-bit") { return "8-bit" }
        if lower.contains("6bit") || lower.contains("6-bit") { return "6-bit" }
        if lower.contains("4bit") || lower.contains("4-bit") { return "4-bit" }
        return nil
    }

    private func refreshInstalled() async {
        installed = (try? await ImageGenerationService.shared.availableModels()) ?? []
    }
}
