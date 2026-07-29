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

extension Notification.Name {
    /// Posted after an import saves sessions, so every open chat window
    /// refreshes its sidebar list (windows don't observe
    /// `ChatSessionsManager.sessions` directly).
    static let chatSessionsImported = Notification.Name("chatSessionsImported")
}

/// Transient "you just imported these" sidebar state: rows glow briefly
/// so the user can spot where the conversations landed in the list —
/// imported sessions keep their original timestamps, so they sort into
/// arbitrary positions rather than the top.
@MainActor
final class ChatSessionImportHighlight: ObservableObject {
    static let shared = ChatSessionImportHighlight()

    @Published private(set) var sessionIds: Set<UUID> = []
    private var clearTask: Task<Void, Never>?
    private init() {}

    func flash(_ ids: Set<UUID>, duration: TimeInterval = 2) {
        clearTask?.cancel()
        sessionIds = ids
        clearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.sessionIds = []
        }
    }
}

@MainActor
enum ChatSessionImportCoordinator {

    struct ImportSummary {
        var importedSessions: [ChatSessionData] = []
        var skippedDuplicates: Int = 0
        var imported: Int { importedSessions.count }
    }

    /// Presents the open panel, parses the chosen export files and saves
    /// each conversation as an `.imported` session for `agentId`.
    /// Conversations whose `externalSessionKey` already exists are
    /// skipped so re-importing the same export is idempotent.
    ///
    /// `onOpen` fires when the import produced exactly one conversation:
    /// the caller (the sidebar) loads it into the window so the user
    /// isn't left hunting the list for what they just imported.
    static func run(
        agentId: UUID?,
        scope: ThemedAlertScope = .unspecified,
        onOpen: ((ChatSessionData) -> Void)? = nil
    ) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.json, .zip]
        panel.title = L("Import Conversations")
        panel.message = L(
            "Choose an export from ChatGPT, Claude, Grok, Gemini, or Open WebUI (.zip or .json), or an Osaurus import JSON file."
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
                presentError(error, scope: scope)
            case .success(let conversations):
                let summary = persist(conversations, agentId: agentId)
                NotificationCenter.default.post(name: .chatSessionsImported, object: nil)
                presentSummary(summary)
                if summary.importedSessions.count == 1, let only = summary.importedSessions.first {
                    onOpen?(only)
                }
                if !summary.importedSessions.isEmpty {
                    let ids = Set(summary.importedSessions.map(\.id))
                    // Deferred one main-actor turn: the notification's
                    // sidebar refresh is itself a queued task, and the
                    // flash's scroll-to-row needs the new rows in the list.
                    Task { @MainActor in
                        ChatSessionImportHighlight.shared.flash(ids)
                    }
                }
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
            summary.importedSessions.append(session)
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

    private static func presentError(_ error: Error, scope: ThemedAlertScope) {
        let requestId = UUID()
        ThemedAlertCenter.shared.present(
            ThemedAlertRequest(
                id: requestId,
                title: "Import failed",
                message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                buttons: [.primary(L("OK")) {}],
                onDismiss: {
                    ThemedAlertCenter.shared.dismiss(scope: scope, id: requestId)
                }
            ),
            scope: scope
        )
    }
}
