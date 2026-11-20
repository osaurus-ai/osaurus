//
//  ChatBatchActions.swift
//  osaurus
//
//  Archive, pin and delete for a set of chats at once: the sidebar's batch
//  bar, the selection-aware row menu and the All chats page. Each action
//  goes through `ChatSessionsManager`, which keeps every window's live
//  copy of a chat in step.
//

import Foundation
import SwiftUI

@MainActor
enum ChatBatchActions {

    // MARK: - Pure rules

    /// The ids an action can apply to: chats still in the list. A chat
    /// deleted elsewhere since it was selected is skipped and counted.
    nonisolated static func eligible(
        _ ids: Set<UUID>, in sessions: [ChatSessionData]
    ) -> (ids: Set<UUID>, skipped: Int) {
        let known = Set(sessions.map(\.id))
        let kept = ids.intersection(known)
        return (kept, ids.count - kept.count)
    }

    /// Each chat's archived state before an archive, so Undo restores
    /// exactly those chats to exactly what they were.
    nonisolated static func archivedSnapshot(
        _ ids: Set<UUID>, in sessions: [ChatSessionData]
    ) -> [UUID: Bool] {
        var snapshot: [UUID: Bool] = [:]
        for session in sessions where ids.contains(session.id) {
            snapshot[session.id] = session.archived
        }
        return snapshot
    }

    /// Whether the batch bar offers Unarchive / Unpin: every selected chat
    /// already is.
    nonisolated static func allArchived(_ ids: Set<UUID>, in sessions: [ChatSessionData]) -> Bool {
        let chosen = sessions.filter { ids.contains($0.id) }
        return !chosen.isEmpty && chosen.allSatisfy(\.archived)
    }

    nonisolated static func allPinned(_ ids: Set<UUID>, in sessions: [ChatSessionData]) -> Bool {
        let chosen = sessions.filter { ids.contains($0.id) }
        return !chosen.isEmpty && chosen.allSatisfy(\.pinned)
    }

    // MARK: - Copy

    nonisolated static func archivedToastTitle(count: Int, archived: Bool, skipped: Int) -> String {
        if skipped > 0 {
            return archived
                ? L("\(count) archived, \(skipped) skipped")
                : L("\(count) moved back to the list, \(skipped) skipped")
        }
        if archived {
            return count == 1 ? L("1 chat archived") : L("\(count) chats archived")
        }
        return count == 1 ? L("1 chat moved back to the list") : L("\(count) chats moved back to the list")
    }

    nonisolated static func deletedToastTitle(count: Int, skipped: Int) -> String {
        if skipped > 0 { return L("\(count) deleted, \(skipped) skipped") }
        return count == 1 ? L("1 chat deleted") : L("\(count) chats deleted")
    }

    nonisolated static func deleteTitle(count: Int) -> String {
        count == 1 ? L("Delete 1 chat?") : L("Delete \(count) chats?")
    }

    nonisolated static func deleteMessage(count: Int) -> String {
        count == 1
            ? L("This chat and its messages are removed from this Mac. This cannot be undone.")
            : L("These chats and their messages are removed from this Mac. This cannot be undone.")
    }

    nonisolated static func deleteButtonTitle(count: Int) -> String {
        count == 1 ? L("Delete 1 chat") : L("Delete \(count) chats")
    }

    // MARK: - Actions

    /// Archives (or unarchives) `ids`, then offers Undo, which puts each
    /// chat back to the archived state it had before.
    static func setArchived(_ ids: Set<UUID>, archived: Bool) {
        let manager = ChatSessionsManager.shared
        let (kept, skipped) = eligible(ids, in: manager.sessions)
        guard !kept.isEmpty else { return }
        let snapshot = archivedSnapshot(kept, in: manager.sessions)
        for id in kept { manager.setArchived(id: id, archived: archived) }
        refreshWindows()

        let actionId = "chatBatchUndoArchive.\(UUID().uuidString)"
        let toastId = ToastManager.shared.action(
            archivedToastTitle(count: kept.count, archived: archived, skipped: skipped),
            actionTitle: L("Undo"),
            actionId: actionId
        )
        ToastManager.shared.registerActionHandler(for: actionId) { _ in
            Task { @MainActor in
                ToastManager.shared.unregisterActionHandler(for: actionId)
                ToastManager.shared.dismiss(id: toastId)
                for (id, wasArchived) in snapshot {
                    ChatSessionsManager.shared.setArchived(id: id, archived: wasArchived)
                }
                refreshWindows()
            }
        }
    }

    static func setPinned(_ ids: Set<UUID>, pinned: Bool) {
        let manager = ChatSessionsManager.shared
        let (kept, _) = eligible(ids, in: manager.sessions)
        for id in kept { manager.setPinned(id: id, pinned: pinned) }
        refreshWindows()
    }

    /// One confirmation for one chat or many: Cancel, Archive instead, or
    /// Delete. Honors the "don't ask again" opt-out like the single-row flow.
    static func requestDelete(_ ids: Set<UUID>, scope: ThemedAlertScope, onDone: (() -> Void)? = nil) {
        guard !ids.isEmpty else { return }
        if DeleteConfirmationPreference.shared.skipForSession {
            delete(ids)
            onDone?()
            return
        }
        let requestId = UUID()
        let count = ids.count
        ThemedAlertCenter.shared.present(
            ThemedAlertRequest(
                id: requestId,
                title: deleteTitle(count: count),
                message: deleteMessage(count: count),
                accessory: AnyView(DontAskAgainToggle()),
                buttons: [
                    .cancel(L("Cancel")),
                    .primary(L("Archive instead")) {
                        setArchived(ids, archived: true)
                        onDone?()
                    },
                    .destructive(deleteButtonTitle(count: count)) {
                        delete(ids)
                        onDone?()
                    },
                ],
                onDismiss: {
                    ThemedAlertCenter.shared.dismiss(scope: scope, id: requestId)
                }
            ),
            scope: scope
        )
    }

    /// Cancels each chat's live run, moves every window off it, then
    /// deletes them in one batch.
    static func delete(_ ids: Set<UUID>) {
        let (kept, skipped) = eligible(ids, in: ChatSessionsManager.shared.sessions)
        guard !kept.isEmpty else { return }
        Task { @MainActor in
            await ChatWindowManager.shared.deleteSessions(ids: kept)
            ToastManager.shared.success(deletedToastTitle(count: kept.count, skipped: skipped))
        }
    }

    private static func refreshWindows() {
        for state in ChatWindowManager.shared.allWindowStates { state.refreshSessions() }
    }
}
