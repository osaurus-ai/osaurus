//
//  PIIModelDownloadPromptView.swift
//  osaurus
//
//  Themed-alert flow presented when an agent tool (`detect_pii` /
//  `redact_file`) needs a PII model and none is installed. Two phases on
//  the chat window's existing `ThemedAlertHost` overlay so styling
//  matches every other app dialog: an Install / Not Now ask, then a
//  progress alert driving `RampartModelManager` (~37MB). Resolves the
//  suspended tool call true only when the bundle is installed and loaded.
//

import SwiftUI

@MainActor
enum PIIModelDownloadAlertFlow {

    /// Run the full ask -> download -> resolve flow in `scope`. Returns
    /// true when the model is installed and ready, false on decline,
    /// cancel, or download failure.
    static func run(scope: ThemedAlertScope) async -> Bool {
        // Phase 1: ask. Standard title/message/buttons so the card is
        // byte-for-byte the app's themed alert.
        let askId = UUID()
        let install = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            var resumed = false
            let finish: (Bool) -> Void = { value in
                guard !resumed else { return }
                resumed = true
                // Clear the ask from the center before the next present:
                // the host's dialog view is per-request, and a stale
                // entry would otherwise linger invisible after its
                // dismiss animation.
                ThemedAlertCenter.shared.dismiss(scope: scope, id: askId)
                cont.resume(returning: value)
            }
            ThemedAlertCenter.shared.present(
                ThemedAlertRequest(
                    id: askId,
                    title: L("Install PII Detection Model?"),
                    message: L(
                        "This task detects personal information (names, addresses) with an on-device model. Installing the recommended model (37 MB) takes a few seconds and runs fully offline. Without it, only pattern-based detection (emails, phone numbers) is available."
                    ),
                    buttons: [
                        .cancel(L("Not Now")) { finish(false) },
                        .primary(L("Install")) { finish(true) },
                    ],
                    onDismiss: { finish(false) }
                ),
                scope: scope
            )
        }
        guard install else { return false }

        // Phase 2: download with live progress. No buttons; dismissing
        // the card (overlay tap has no cancel button, so only
        // programmatic dismissal ends it) cancels the download.
        let manager = RampartModelManager.shared
        manager.startDownload()
        let progressId = UUID()
        ThemedAlertCenter.shared.present(
            ThemedAlertRequest(
                id: progressId,
                title: L("Downloading PII Model"),
                message: nil,
                buttons: [],
                customContent: AnyView(RampartDownloadProgressContent()),
                onDismiss: { manager.cancel() }
            ),
            scope: scope
        )
        defer { ThemedAlertCenter.shared.dismiss(scope: scope, id: progressId) }
        while true {
            switch manager.state {
            case .ready:
                return true
            case .failed, .idle:
                // `.idle` here means the download was cancelled.
                return false
            case .downloading:
                try? await Task.sleep(nanoseconds: 200_000_000)
                if Task.isCancelled { return false }
            }
        }
    }
}

/// Progress body for the download alert, styled after the conversation
/// import progress content so in-alert progress reads identically
/// everywhere.
private struct RampartDownloadProgressContent: View {
    @ObservedObject private var manager = RampartModelManager.shared
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch manager.state {
            case .downloading(let progress):
                ProgressView(value: progress)
                Text(L("Downloading, \(Int(progress * 100))%"))
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
            case .failed(let message):
                Text(L("Download failed: \(message)"))
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            case .idle, .ready:
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.top, 2)
        .frame(width: 300)
    }
}
