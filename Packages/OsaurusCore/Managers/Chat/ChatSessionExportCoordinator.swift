//
//  ChatSessionExportCoordinator.swift
//  osaurus
//
//  Glue: NSSavePanel UX, full-session hydration, dispatch to the exporter.
//

import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
enum ChatSessionExportCoordinator {
    static func run(
        metadataSession: ChatSessionData,
        format: ChatSessionSidebar.ExportFormat,
        options: ChatExportOptions = ChatExportOptions(),
        scope: ThemedAlertScope
    ) {
        // Sidebar only carries metadata. Prefer the store, fall back to the
        // in-memory manager (freshly created sessions are not flushed yet,
        // and `loadSession` is intermittently returning nil for rows that
        // do exist).
        guard
            let full = ChatSessionStore.load(id: metadataSession.id)
                ?? ChatSessionsManager.shared.session(for: metadataSession.id)
        else {
            presentError(ChatSessionExporter.ExportError.sessionMissing)
            return
        }

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = suggestedFilename(for: full, format: format)
        panel.allowedContentTypes = [contentType(for: format)]
        panel.title = panelTitle(format)

        Task { @MainActor in
            guard await panel.beginModal() == .OK, let url = panel.url else { return }

            let progressId = UUID()

            // Only surface the progress alert if the export hasn't finished
            // within the threshold, so quick markdown writes don't flash a
            // dialog the user can't read.
            let progressThreshold: Duration = .seconds(2.5)
            let displayTask = Task { @MainActor in
                do {
                    try await Task.sleep(for: progressThreshold)
                } catch {
                    return  // cancelled before the threshold elapsed
                }
                ThemedAlertCenter.shared.present(
                    ThemedAlertRequest(
                        id: progressId,
                        title: progressTitle(format),
                        message: "Working on \"\(full.title)\". This may take a moment for larger chats.",
                        accessory: AnyView(ExportProgressIndicator()),
                        buttons: [.cancel("Hide")],
                        onDismiss: {
                            ThemedAlertCenter.shared.dismiss(scope: scope, id: progressId)
                        }
                    ),
                    scope: scope
                )
            }

            let result: Result<Void, Error>
            do {
                switch format {
                case .markdown:
                    try ChatSessionExporter.writeMarkdown(session: full, options: options, to: url)
                case .pdf:
                    try ChatSessionExporter.writePDF(session: full, options: options, to: url)
                case .zip:
                    try await ChatSessionExporter.writeZip(session: full, options: options, to: url)
                }
                result = .success(())
            } catch {
                result = .failure(error)
            }
            displayTask.cancel()
            // Idempotent: no-op when nothing was ever presented for this id.
            ThemedAlertCenter.shared.dismiss(scope: scope, id: progressId)
            switch result {
            case .success:
                ToastManager.shared.action(
                    L("Export complete"),
                    message: url.lastPathComponent,
                    action: .revealInFinder(url),
                    buttonTitle: L("Reveal in Finder")
                )
            case .failure(let error):
                presentError(error)
            }
        }
    }

    // MARK: - Helpers

    private static func suggestedFilename(
        for session: ChatSessionData,
        format: ChatSessionSidebar.ExportFormat
    ) -> String {
        let base = sanitize(session.title.isEmpty ? "chat" : session.title)
        let ext: String
        switch format {
        case .markdown: ext = "md"
        case .pdf: ext = "pdf"
        case .zip: ext = "zip"
        }
        return "\(base).\(ext)"
    }

    private static func contentType(for format: ChatSessionSidebar.ExportFormat) -> UTType {
        switch format {
        case .markdown: return UTType(filenameExtension: "md") ?? .plainText
        case .pdf: return .pdf
        case .zip: return .zip
        }
    }

    private static func panelTitle(_ format: ChatSessionSidebar.ExportFormat) -> String {
        switch format {
        case .markdown: return "Export Markdown"
        case .pdf: return "Export PDF"
        case .zip: return "Export Zip"
        }
    }

    private static func progressTitle(_ format: ChatSessionSidebar.ExportFormat) -> String {
        switch format {
        case .markdown: return "Exporting Markdown\u{2026}"
        case .pdf: return "Exporting PDF\u{2026}"
        case .zip: return "Building Zip\u{2026}"
        }
    }

    private static func sanitize(_ raw: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let cleaned = raw.components(separatedBy: invalid).joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "chat" : String(cleaned.prefix(60))
    }

    private static func presentError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = L("Export failed")
        alert.informativeText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("OK"))
        alert.runModal()
    }
}

/// Indeterminate spinner used as the themed-alert accessory while an
/// export is in flight.
private struct ExportProgressIndicator: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .scaleEffect(0.8)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }
}
