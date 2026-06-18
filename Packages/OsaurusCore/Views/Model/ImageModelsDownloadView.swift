//
//  ImageModelsDownloadView.swift
//  osaurus
//
//  The "Images" tab of the Models window: stage on-device image-generation
//  bundles (vMLXFlux / mflux) so they become selectable in the chat model
//  picker. Rendered as a card grid matching the other Models tabs. Curated
//  models download in place; arbitrary image repos are added via the global
//  Import button, which auto-detects image bundles and routes them here.
//

import SwiftUI

struct ImageModelsDownloadView: View {
    @ObservedObject private var downloads = ImageModelDownloadService.shared
    @Environment(\.theme) private var theme

    @State private var installed: [ImageModelInfo] = []

    /// Non-optional download state for a bundle id (absent ⇒ not started).
    private func state(_ id: String) -> DownloadState {
        downloads.states[id] ?? .notStarted
    }

    /// One card per image model: installed bundles first, then curated
    /// suggestions not yet on disk.
    private struct Row: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let note: String?
        /// Download source; `nil` for installed-only rows (no re-download).
        let repoId: String?
        let installed: Bool
        let blockedReason: String?
    }

    private var rows: [Row] {
        var result: [Row] = []
        var seen = Set<String>()
        for model in installed {
            seen.insert(model.id)
            result.append(
                Row(
                    id: model.id, title: model.displayName, subtitle: model.id, note: nil,
                    repoId: nil, installed: true,
                    blockedReason: model.ready ? nil : model.blockedReasons.first))
        }
        for entry in ImageModelDownloadService.catalog where !seen.contains(entry.id) {
            result.append(
                Row(
                    id: entry.id, title: entry.displayName, subtitle: entry.repoId,
                    note: entry.note, repoId: entry.repoId, installed: false, blockedReason: nil))
        }
        return result
    }

    private let columns = [GridItem(.adaptive(minimum: 260), spacing: 12, alignment: .top)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                hint
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(rows) { card($0) }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await refreshInstalled() }
        .onReceive(NotificationCenter.default.publisher(for: .localModelsChanged)) { _ in
            Task { await refreshInstalled() }
        }
    }

    private var hint: some View {
        Text(
            "Download a model, then pick it in the chat model selector to generate images. Use Import above to add any Hugging Face image repo.",
            bundle: .module
        )
        .font(.system(size: 12))
        .foregroundColor(theme.secondaryText)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func card(_ row: Row) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "photo")
                    .font(.system(size: 14))
                    .foregroundColor(theme.accentColor)
                Text(row.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            Text(row.subtitle)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(theme.tertiaryText)
                .lineLimit(1)
            if let note = row.note {
                Text(note).font(.system(size: 11)).foregroundColor(theme.secondaryText)
            }
            if let blocked = row.blockedReason {
                Text(blocked).font(.system(size: 11)).foregroundColor(.orange).lineLimit(2)
            }

            Spacer(minLength: 6)

            actionRow(row)

            if case .downloading = state(row.id) {
                progressStrip(id: row.id)
            } else if case .failed(let error) = state(row.id) {
                Text(error).font(.system(size: 11)).foregroundColor(.red).lineLimit(2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 124, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12).stroke(theme.cardBorder, lineWidth: 1))
        )
    }

    @ViewBuilder
    private func actionRow(_ row: Row) -> some View {
        if row.installed {
            installedBadge(attention: row.blockedReason != nil)
        } else if case .downloading = state(row.id) {
            Button(role: .destructive) { downloads.cancel(row.id) } label: {
                Text("Cancel", bundle: .module)
                    .font(.system(size: 12, weight: .medium))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        } else if downloads.isInstalled(row.id) || state(row.id) == .completed {
            installedBadge(attention: false)
        } else if let repoId = row.repoId {
            Button { downloads.download(repoId: repoId, displayName: row.title) } label: {
                Text("Download", bundle: .module)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func installedBadge(attention: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: attention ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundColor(attention ? .orange : .green)
            Text(attention ? "Needs attention" : "Installed", bundle: .module)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(attention ? .orange : .green)
        }
    }

    private func progressStrip(id: String) -> some View {
        let currentState = state(id)
        let fraction: Double = {
            if case .downloading(let p) = currentState { return p }
            return 0
        }()
        return VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: fraction)
            if let line = downloads.metrics[id]?.formattedLine {
                Text(line).font(.system(size: 11)).foregroundColor(theme.secondaryText).lineLimit(1)
            } else {
                Text("\(Int(fraction * 100))%").font(.system(size: 11)).foregroundColor(
                    theme.secondaryText)
            }
        }
    }

    private func refreshInstalled() async {
        installed = (try? await ImageGenerationService.shared.availableModels()) ?? []
    }
}
