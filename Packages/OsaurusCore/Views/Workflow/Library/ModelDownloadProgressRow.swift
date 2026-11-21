//
//  ModelDownloadProgressRow.swift
//  osaurus
//
//  One model download's progress in setup, whichever service runs it: chat
//  models through `ModelDownloadService`, image and video bundles through
//  `ImageModelDownloadService`. Draws nothing until the download starts, so
//  the caller's own Download row stands in before then.
//

import SwiftUI

struct ModelDownloadProgressRow: View {
    enum Source: Equatable, Hashable {
        /// A chat model, keyed by repo id.
        case chat(repoId: String)
        /// An image or video bundle, keyed by its directory name.
        case media(bundleId: String)
    }

    @Environment(\.theme) private var theme
    @ObservedObject private var chat = ModelDownloadService.shared
    @ObservedObject private var media = ImageModelDownloadService.shared

    let source: Source
    let name: String
    let onRetry: () -> Void

    static func state(of source: Source) -> DownloadState {
        switch source {
        case .chat(let repo): return ModelDownloadService.shared.downloadStates[repo] ?? .notStarted
        case .media(let id): return ImageModelDownloadService.shared.states[id] ?? .notStarted
        }
    }

    static func metrics(of source: Source) -> ModelDownloadService.DownloadMetrics? {
        switch source {
        case .chat(let repo): return ModelDownloadService.shared.downloadMetrics[repo]
        case .media(let id): return ImageModelDownloadService.shared.metrics[id]
        }
    }

    var body: some View {
        switch Self.state(of: source) {
        case .notStarted:
            EmptyView()
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
                    if case .chat(let repo) = source {
                        button(L("Pause"), icon: "pause.fill", primary: false) { ModelManager.shared.pauseDownload(repo) }
                    }
                    button(L("Cancel"), icon: "xmark", primary: false, action: cancel)
                }
                SettingsProgressBar(value: progress, tint: theme.action.primary.default.background)
                    .animation(theme.motion.standard, value: progress)
                if let line = Self.metrics(of: source)?.formattedLine {
                    Text(verbatim: line)
                        .font(SettingsFont.monoSmall)
                        .monospacedDigit()
                        .foregroundColor(theme.text.tertiary)
                }
            }
        case .paused(let progress):
            let percent = progress.formatted(.percent.precision(.fractionLength(0)))
            row(icon: "pause.circle", text: L("\(name) is paused at \(percent).")) {
                if case .chat(let repo) = source {
                    button(L("Resume"), icon: "play.fill", primary: true) { ModelManager.shared.resumeDownload(repo) }
                }
            }
        case .completed:
            row(icon: "checkmark.circle", text: L("\(name) is downloaded.")) { EmptyView() }
        case .failed(let error):
            row(icon: "exclamationmark.triangle", text: L("Downloading \(name) failed: \(error)")) {
                button(L("Try Again"), icon: "arrow.clockwise", primary: true, action: onRetry)
            }
        }
    }

    private func cancel() {
        switch source {
        case .chat(let repo): ModelManager.shared.cancelDownload(repo)
        case .media(let id): ImageModelDownloadService.shared.cancel(id)
        }
    }

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
