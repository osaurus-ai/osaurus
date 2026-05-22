//
//  ChatSessionExportCoordinator.swift
//  osaurus
//
//  Glue: NSSavePanel UX, full-session hydration, dispatch to the exporter.
//

import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
enum ChatSessionExportCoordinator {
    static func run(
        metadataSession: ChatSessionData,
        format: ChatSessionSidebar.ExportFormat
    ) {
        // Sidebar only carries metadata. Prefer the store, fall back to the
        // in-memory manager (freshly created sessions are not flushed yet,
        // and `loadSession` is intermittently returning nil for rows that
        // do exist).
        guard let full = ChatSessionStore.load(id: metadataSession.id)
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

        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return }

        switch format {
        case .markdown:
            do {
                try ChatSessionExporter.writeMarkdown(session: full, to: url)
            } catch {
                presentError(error)
            }
        case .pdf:
            do {
                try ChatSessionExporter.writePDF(session: full, to: url)
            } catch {
                presentError(error)
            }
        case .zip:
            Task { @MainActor in
                do {
                    try await ChatSessionExporter.writeZip(session: full, to: url)
                } catch {
                    presentError(error)
                }
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

    private static func sanitize(_ raw: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let cleaned = raw.components(separatedBy: invalid).joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "chat" : String(cleaned.prefix(60))
    }

    private static func presentError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Export failed"
        alert.informativeText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

