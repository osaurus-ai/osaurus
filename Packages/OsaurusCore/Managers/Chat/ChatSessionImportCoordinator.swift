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
import SwiftUI
import UniformTypeIdentifiers

/// Live status line for the import progress alert. Large exports (a
/// multi-GB ChatGPT dump) parse for a long time; without visible
/// progress the app looks frozen even though the work is off-main.
@MainActor
private final class ImportProgressState: ObservableObject {
    @Published var message: String

    init(message: String) {
        self.message = message
    }
}

/// Themed-alert custom content: an indeterminate spinner next to the
/// current parsing status. No buttons — the import isn't cancellable
/// once parsing starts.
private struct ImportProgressContent: View {
    @ObservedObject var state: ImportProgressState
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)

            Text(state.message)
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.top, 2)
        .frame(width: 300)
    }
}

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
        /// Conversations the export contained but the parser couldn't read.
        var unreadable: Int = 0
        /// Files that failed wholesale (unreadable, invalid, unrecognized).
        var failedFiles: [String] = []
        var imported: Int { importedSessions.count }
        var hasIssues: Bool { unreadable > 0 || !failedFiles.isEmpty }
    }

    /// Accumulated result of parsing every chosen file. A failing file is
    /// recorded and skipped rather than aborting the batch, so one bad
    /// file can't discard the conversations of the good ones.
    private struct ParseOutcome: Sendable {
        var conversations: [ChatSessionImporter.ImportedConversation] = []
        var unreadable: Int = 0
        var failedFiles: [String] = []
        var firstError: Error?
    }

    /// Where an import run was started from. Closed token set carried on
    /// the `chat_history_imported` telemetry event so the post-onboarding
    /// prompt's funnel can be measured against the sidebar entry point.
    enum EntryPoint: String {
        case sidebar
        case onboardingPrompt = "onboarding_prompt"
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
        source: EntryPoint = .sidebar,
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

            let progress = ImportProgressState(message: L("Reading files…"))
            let progressAlertId = UUID()
            ThemedAlertCenter.shared.present(
                ThemedAlertRequest(
                    id: progressAlertId,
                    title: "Importing Conversations",
                    message: nil,
                    buttons: [],
                    customContent: AnyView(ImportProgressContent(state: progress)),
                    onDismiss: {}
                ),
                scope: scope
            )
            let onProgress: @Sendable (String) -> Void = { message in
                Task { @MainActor in progress.message = message }
            }

            // Parsing large exports (ChatGPT dumps run to hundreds of MB)
            // must not block the main thread. Files fail independently:
            // one bad file must not discard the good ones' conversations.
            let outcome: ParseOutcome =
                await Task.detached(priority: .userInitiated) {
                    var outcome = ParseOutcome()
                    for url in urls {
                        onProgress(L("Reading \(url.lastPathComponent)…"))
                        do {
                            let data = try Data(contentsOf: url)
                            let result = try ChatSessionImporter.parse(
                                data: data, onProgress: onProgress)
                            outcome.conversations.append(contentsOf: result.conversations)
                            outcome.unreadable += result.unreadable
                        } catch {
                            outcome.failedFiles.append(url.lastPathComponent)
                            if outcome.firstError == nil { outcome.firstError = error }
                        }
                    }
                    return outcome
                }.value

            ThemedAlertCenter.shared.dismiss(scope: scope, id: progressAlertId)

            // Every file failed and nothing was salvaged: a themed error
            // alert explains why instead of a summary toast.
            if outcome.conversations.isEmpty, let error = outcome.firstError {
                presentError(error, scope: scope)
                return
            }

            var summary = persist(outcome.conversations, agentId: agentId)
            summary.unreadable = outcome.unreadable
            summary.failedFiles = outcome.failedFiles
            // Successful import = at least one conversation saved.
            // Duplicate-only re-imports and total failures don't fire.
            if summary.imported > 0 {
                FeatureTelemetry.chatHistoryImported(
                    source: source.rawValue,
                    imported: summary.imported,
                    duplicates: summary.skippedDuplicates,
                    unreadable: summary.unreadable,
                    failedFiles: summary.failedFiles.count
                )
            }
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
        if summary.imported == 0, summary.skippedDuplicates > 0, !summary.hasIssues {
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
        if summary.unreadable > 0 {
            parts.append(
                summary.unreadable == 1
                    ? L("1 conversation couldn't be read")
                    : L("\(summary.unreadable) conversations couldn't be read"))
        }
        for name in summary.failedFiles {
            parts.append(L("\(name) couldn't be imported"))
        }
        if summary.hasIssues {
            ToastManager.shared.warning(
                L("Import finished with issues"), message: parts.joined(separator: " · "))
        } else {
            ToastManager.shared.success(
                L("Import complete"), message: parts.joined(separator: " · "))
        }
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
