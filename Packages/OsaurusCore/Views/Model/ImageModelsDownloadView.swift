//
//  ImageModelsDownloadView.swift
//  osaurus
//
//  The "Images" tab of the Models window: stage on-device image-generation
//  bundles (vMLXFlux / mflux) so they become selectable in the chat model
//  picker. Curated mirrors plus a free-form "download any repo" field — any
//  mflux repo works as long as its name carries a recognizable family token
//  (z-image, flux1-schnell, qwen-image, ideogram, …).
//

import SwiftUI

struct ImageModelsDownloadView: View {
    @ObservedObject private var downloads = ImageModelDownloadService.shared
    @Environment(\.theme) private var theme

    @State private var installed: [ImageModelInfo] = []
    @State private var customRepoId: String = ""

    /// Non-optional download state for a bundle id (absent ⇒ not started).
    private func state(_ id: String) -> DownloadState {
        downloads.states[id] ?? .notStarted
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                intro
                customDownloadField
                if !installed.isEmpty { installedSection }
                catalogSection
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await refreshInstalled() }
        .onReceive(NotificationCenter.default.publisher(for: .localModelsChanged)) { _ in
            Task { await refreshInstalled() }
        }
    }

    // MARK: - Sections

    private var intro: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("On-device image models", bundle: .module)
                .font(.system(size: 15, weight: .semibold))
            Text(
                "Download an image-generation bundle, then pick it in the chat model selector to generate images.",
                bundle: .module
            )
            .font(.system(size: 12))
            .foregroundColor(theme.secondaryText)
        }
    }

    private var customDownloadField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Download from Hugging Face", bundle: .module)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(theme.secondaryText)
            HStack(spacing: 8) {
                TextField("org/Model-mflux-4bit", text: $customRepoId)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13))
                    .onSubmit { startCustomDownload() }
                Button {
                    startCustomDownload()
                } label: {
                    Text("Download", bundle: .module)
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .disabled(customRepoId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let row = activeRow(forRepoId: customRepoId) {
                progressStrip(id: row)
            }
        }
    }

    private var installedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Installed", bundle: .module)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(theme.secondaryText)
            ForEach(installed, id: \.id) { model in
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.system(size: 13))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.displayName).font(.system(size: 13, weight: .medium))
                        Text(model.id).font(.system(size: 11)).foregroundColor(theme.secondaryText)
                    }
                    Spacer()
                    if !model.ready, let reason = model.blockedReasons.first {
                        Text(reason).font(.system(size: 11)).foregroundColor(.orange)
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(theme.tertiaryBackground.opacity(0.4)))
            }
        }
    }

    private var catalogSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Suggested", bundle: .module)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(theme.secondaryText)
            ForEach(ImageModelDownloadService.catalog) { entry in
                catalogRow(entry)
            }
        }
    }

    private func catalogRow(_ entry: ImageModelDownload) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.displayName).font(.system(size: 13, weight: .medium))
                    Text(entry.repoId).font(.system(size: 11)).foregroundColor(theme.secondaryText)
                    if let note = entry.note {
                        Text(note).font(.system(size: 11)).foregroundColor(theme.secondaryText)
                    }
                }
                Spacer()
                trailingControl(for: entry.id, repoId: entry.repoId, displayName: entry.displayName)
            }
            if case .downloading = state(entry.id) {
                progressStrip(id: entry.id)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.tertiaryBackground.opacity(0.4)))
    }

    @ViewBuilder
    private func trailingControl(for id: String, repoId: String, displayName: String) -> some View {
        if downloads.isInstalled(id) || state(id) == .completed {
            Text("Installed", bundle: .module)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.green)
        } else if case .downloading = state(id) {
            Button(role: .destructive) { downloads.cancel(id) } label: {
                Text("Cancel", bundle: .module).font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.bordered)
        } else {
            Button { downloads.download(repoId: repoId, displayName: displayName) } label: {
                Text("Download", bundle: .module).font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.bordered)
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
            HStack {
                if let line = downloads.metrics[id]?.formattedLine {
                    Text(line).font(.system(size: 11)).foregroundColor(theme.secondaryText)
                } else {
                    Text("\(Int(fraction * 100))%").font(.system(size: 11)).foregroundColor(theme.secondaryText)
                }
                Spacer()
                if case .failed(let error) = currentState {
                    Text(error).font(.system(size: 11)).foregroundColor(.red).lineLimit(1)
                }
            }
        }
    }

    // MARK: - Helpers

    private func activeRow(forRepoId repoId: String) -> String? {
        let id = ImageModelDownload.directoryName(forRepoId: repoId.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !id.isEmpty else { return nil }
        if case .downloading = state(id) { return id }
        if case .failed = state(id) { return id }
        return nil
    }

    private func startCustomDownload() {
        let trimmed = customRepoId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let name = ImageModelDownload.directoryName(forRepoId: trimmed)
        downloads.download(repoId: trimmed, displayName: name)
    }

    private func refreshInstalled() async {
        installed = (try? await ImageGenerationService.shared.availableModels()) ?? []
    }
}
