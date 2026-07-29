//
//  ChatSessionImportCoordinator.swift
//  osaurus
//
//  Glue: NSOpenPanel UX, off-main parsing, de-dup against existing
//  imports, persistence via ChatSessionsManager. Mirror image of
//  ChatSessionExportCoordinator.
//

import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
enum ChatSessionImportCoordinator {

    struct ImportSummary {
        var imported: Int = 0
        var skippedDuplicates: Int = 0
    }

    /// Presents the open panel, parses the chosen export files and saves
    /// each conversation as an `.imported` session for `agentId`.
    /// Conversations whose `externalSessionKey` already exists are
    /// skipped so re-importing the same export is idempotent.
    static func run(agentId: UUID?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.json, .zip]
        panel.title = L("Import Conversations")
        panel.message = L(
            "Choose an export from ChatGPT, Claude, or Gemini (.zip or .json), or an Osaurus import JSON file."
        )

        Task { @MainActor in
            guard await panel.beginModal() == .OK, !panel.urls.isEmpty else { return }
            let urls = panel.urls

            // Parsing large exports (ChatGPT dumps run to hundreds of MB)
            // must not block the main thread.
            let parsed: Result<[ChatSessionImporter.ImportedConversation], Error> =
                await Task.detached(priority: .userInitiated) {
                    do {
                        var all: [ChatSessionImporter.ImportedConversation] = []
                        for url in urls {
                            let data = try Data(contentsOf: url)
                            all.append(contentsOf: try ChatSessionImporter.parse(data: data))
                        }
                        return .success(all)
                    } catch {
                        return .failure(error)
                    }
                }.value

            switch parsed {
            case .failure(let error):
                presentError(error)
            case .success(let conversations):
                let summary = persist(conversations, agentId: agentId)
                presentSummary(summary)
            }
        }
    }

    // MARK: - Persistence

    private static func persist(
        _ conversations: [ChatSessionImporter.ImportedConversation],
        agentId: UUID?
    ) -> ImportSummary {
        let existingKeys = Set(
            ChatSessionsManager.shared.sessions.compactMap(\.externalSessionKey)
        )
        var summary = ImportSummary()
        for imported in conversations {
            if let key = imported.session.externalSessionKey, existingKeys.contains(key) {
                summary.skippedDuplicates += 1
                continue
            }
            var session = imported.session
            session.agentId = agentId
            ChatSessionsManager.shared.save(session)
            summary.imported += 1
        }
        return summary
    }

    // MARK: - Feedback

    private static func presentSummary(_ summary: ImportSummary) {
        if summary.imported == 0, summary.skippedDuplicates > 0 {
            ToastManager.shared.info(
                L("Nothing to import"),
                message: L("All conversations in the file were already imported.")
            )
            return
        }
        var parts = [
            summary.imported == 1
                ? L("1 conversation imported")
                : L("\(summary.imported) conversations imported")
        ]
        if summary.skippedDuplicates > 0 {
            parts.append(L("\(summary.skippedDuplicates) duplicates skipped"))
        }
        ToastManager.shared.success(L("Import complete"), message: parts.joined(separator: " · "))
    }

    private static func presentError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = L("Import failed")
        alert.informativeText =
            (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("OK"))
        alert.runModal()
    }
}
