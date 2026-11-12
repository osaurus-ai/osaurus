//
//  WorkflowModelSourceRow.swift
//  osaurus
//
//  In a model slot's card, when its suggested model is not on this Mac: one
//  way to get it without leaving setup. A Hugging Face repo downloads in place
//  with progress, a cloud model's provider connects in a sheet, and
//  anything else points at the Models tab.
//

import SwiftUI

struct WorkflowModelSourceRow: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var downloads = ModelDownloadService.shared

    let plan: WorkflowModelResolution.Plan
    /// The slot falls back to the default model until this one is here;
    /// false when the workflow requires this model.
    let fallsBack: Bool
    /// False when no default model is set, so nothing stands in.
    var hasDefault = true
    /// Leaves setup for another tab. Nil hides those actions.
    let onLeave: ((ManagementTab) -> Void)?

    @State private var connecting: ProviderPreset?
    @State private var isResolving = false
    @State private var failure: String?
    @State private var sizeBytes: Int64?

    var body: some View {
        switch plan {
        case .none, .ready:
            EmptyView()
        case .download(let repo):
            downloadRow(repo)
        case .connectProvider(let preset, let model):
            row(
                icon: "cloud",
                text: (fallsBack
                    ? L("Suggests \(model), which runs on \(preset.name). Connect \(preset.name) to use it.")
                    : L("Requires \(model), which runs on \(preset.name). Connect \(preset.name) to use it."))
                    + fallbackNote
            ) {
                button(L("Connect \(preset.name)"), icon: "link", primary: true) { connecting = preset }
            }
            .sheet(
                isPresented: Binding(get: { connecting != nil }, set: { if !$0 { connecting = nil } })
            ) {
                RemoteProviderEditSheet(provider: nil, initialPreset: connecting) { provider, apiKey, oauthTokens in
                    RemoteProviderManager.shared.addProvider(provider, apiKey: apiKey, oauthTokens: oauthTokens)
                    Task { @MainActor in
                        // The model is pickable only once the provider's
                        // catalog is fetched and the picker cache rebuilt;
                        // setup refreshes when the cache changes.
                        await RemoteProviderManager.shared.refreshConnectedProviders()
                        await ModelPickerItemCache.shared.buildModelPickerItems()
                    }
                }
                .environment(\.theme, theme)
            }
        case .unavailable(let id):
            row(
                icon: "questionmark.circle",
                text: fallsBack
                    ? L("Suggests \(id), which isn't on this Mac. Pick a model above or find one in Models.") + fallbackNote
                    : L("Requires \(id), which isn't on this Mac. Find it in Models.")
            ) {
                if let onLeave {
                    button(L("Browse Models"), icon: "arrow.up.right", primary: false) { onLeave(.models) }
                }
            }
        }
    }

    private var fallbackNote: String {
        guard fallsBack else { return "" }
        return " "
            + (hasDefault
                ? L("Until then it uses your default model.")
                : L("No default model is set either, so choose one above until then."))
    }

    // MARK: - Download

    @ViewBuilder
    private func downloadRow(_ repo: String) -> some View {
        let name = WorkflowModelChoices.displayName(repo)
        let state = downloads.downloadStates[repo] ?? .notStarted
        switch state {
        case .downloading(let progress):
            VStack(alignment: .leading, spacing: theme.space.s6) {
                HStack(spacing: theme.space.s8) {
                    Text(verbatim: L("Downloading \(name)"))
                        .font(SettingsFont.smallLabel)
                        .foregroundColor(theme.text.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(1)
                    Spacer()
                    button(L("Pause"), icon: "pause.fill", primary: false) { ModelManager.shared.pauseDownload(repo) }
                    button(L("Cancel"), icon: "xmark", primary: false) { ModelManager.shared.cancelDownload(repo) }
                }
                SettingsProgressBar(value: progress, tint: theme.action.primary.default.background)
                if let line = downloads.downloadMetrics[repo]?.formattedLine {
                    Text(verbatim: line)
                        .font(SettingsFont.monoSmall)
                        .foregroundColor(theme.text.tertiary)
                }
            }
        case .paused(let progress):
            let percent = progress.formatted(.percent.precision(.fractionLength(0)))
            row(icon: "pause.circle", text: L("\(name) is paused at \(percent).")) {
                button(L("Resume"), icon: "play.fill", primary: true) { ModelManager.shared.resumeDownload(repo) }
            }
        case .completed:
            row(icon: "checkmark.circle", text: L("\(name) is downloaded.")) { EmptyView() }
        case .failed(let error):
            row(icon: "exclamationmark.triangle", text: L("Downloading \(name) failed: \(error)")) {
                button(L("Try Again"), icon: "arrow.clockwise", primary: true) { download(repo) }
            }
        case .notStarted:
            row(
                icon: "arrow.down.circle",
                text: (failure
                    ?? (fallsBack ? L("Suggests \(name), which isn't downloaded.") : L("Requires \(name), which isn't downloaded."))
                    + sizeNote) + fallbackNote
            ) {
                if isResolving {
                    SettingsSpinner()
                } else {
                    button(L("Download"), icon: "arrow.down", primary: true) { download(repo) }
                }
            }
            .task(id: repo) { await loadSize(repo) }
        }
    }

    private var sizeNote: String {
        guard let sizeBytes, sizeBytes > 0 else { return "" }
        return " " + L("About \(ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)).")
    }

    private func loadSize(_ repo: String) async {
        let manager = ModelManager.shared
        guard sizeBytes == nil,
            let model = (manager.availableModels + manager.suggestedModels).first(where: {
                $0.id.caseInsensitiveCompare(repo) == .orderedSame
            })
        else { return }
        sizeBytes = await manager.estimateDownloadSize(for: model)
    }

    private func download(_ repo: String) {
        failure = nil
        isResolving = true
        Task { @MainActor in
            defer { isResolving = false }
            switch await ModelManager.shared.resolveModelForDeepLink(byRepoId: repo) {
            case .model(let model):
                ModelManager.shared.downloadModel(model)
            case .image(let repoId):
                ImageModelDownloadService.shared.download(
                    repoId: repoId, displayName: ImageModelDownload.directoryName(forRepoId: repoId))
            case .unsupported:
                failure = L("Hugging Face has no MLX model Osaurus can run at \(repo).")
            case .registryGated:
                failure = L("\(repo) isn't in the Osaurus model catalog.")
            }
        }
    }

    // MARK: - Parts

    private func row<Trailing: View>(
        icon: String, text: String, @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: theme.space.s8) {
            Image(systemName: icon)
                .glyphSize(.caption)
                .foregroundColor(theme.status.info.foreground)
            Text(verbatim: text)
                .font(SettingsFont.rowDescription)
                .foregroundColor(theme.text.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minWidth: 120, alignment: .leading)
                .layoutPriority(1)
            Spacer(minLength: theme.space.s8)
            trailing()
        }
    }

    private func button(_ title: String, icon: String, primary: Bool, action: @escaping () -> Void) -> some View {
        SettingsButton(primary ? .primary : .secondary, title, icon: icon, size: .compact, verbatim: true, action: action)
            .fixedSize()
    }
}

extension WorkflowModelResolution.Plan {
    /// Whether a source row has something to offer for this plan.
    var offersSource: Bool {
        switch self {
        case .none, .ready: return false
        default: return true
        }
    }
}

/// Under a setup's model slots: where to get a model none of them offers.
struct WorkflowModelSourcesLine: View {
    @Environment(\.theme) private var theme
    let onLeave: (ManagementTab) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: theme.space.s8) {
                prompt
                Spacer(minLength: theme.space.s8)
                buttons
            }
            VStack(alignment: .leading, spacing: theme.space.s8) {
                prompt
                HStack(spacing: theme.space.s8) { buttons }
            }
        }
    }

    private var prompt: some View {
        Text("Need a different model?", bundle: .module)
            .textStyle(.caption)
            .foregroundColor(theme.text.tertiary)
            .fixedSize()
    }

    @ViewBuilder private var buttons: some View {
        SettingsButton(.secondary, "Add a Provider", icon: "cloud", size: .compact) { onLeave(.providers) }
            .fixedSize()
        SettingsButton(.secondary, "Download a Model", icon: "arrow.down.circle", size: .compact) { onLeave(.models) }
            .fixedSize()
    }
}
