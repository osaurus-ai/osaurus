//
//  RemoteSessionContinuation.swift
//  osaurus
//
//  Lets a paired phone continue one of the Mac's own chats: `/agents/{id}/run`
//  with `osaurus_session_id` loads that session's turns as model context and
//  appends the new turns back into it (docs/MOBILE_PROTOCOL.md §14.5).
//
//  Writes go through the open chat window when there is one, so a Mac window
//  showing that chat updates live; otherwise straight to the store, followed
//  by the same notification external writers post so History refreshes.
//

import Foundation

@MainActor
enum RemoteSessionContinuation {

    /// The stored conversation as model messages, oldest first. Turns the
    /// Mac excluded from context (compacted away) are skipped, as are
    /// system turns — the run endpoint composes its own system prompt.
    static func history(for sessionId: UUID) async -> [ChatMessage] {
        guard let session = await ChatSessionStore.loadAsync(id: sessionId) else { return [] }
        return session.turns.compactMap(message(from:))
    }

    static func message(from turn: ChatTurnData) -> ChatMessage? {
        guard !turn.modelContextExcluded, turn.role != .system else { return nil }
        let hasContent = !turn.content.isEmpty
        let hasCalls = !(turn.toolCalls?.isEmpty ?? true)
        guard hasContent || hasCalls else { return nil }
        return ChatMessage(
            role: turn.role.rawValue,
            content: turn.content,
            tool_calls: turn.toolCalls,
            tool_call_id: turn.toolCallId
        )
    }

    /// Appends the messages produced by a remote run to the session.
    /// `model` updates the chat's recorded model, matching what the Mac does
    /// when a turn runs under a different model.
    static func append(_ messages: [ChatMessage], to sessionId: UUID, model: String?) {
        let turns = ChatHistoryWriter.turns(from: messages)
        guard !turns.isEmpty else { return }

        // An open window owns the live transcript: append there and let its
        // own save path persist, so the visible chat updates immediately.
        if let live = ChatWindowManager.shared.session(forSessionId: sessionId) {
            live.appendHostedTurns(turns)
            live.save()
            return
        }

        guard var session = ChatSessionStore.load(id: sessionId) else { return }
        session.turns.append(contentsOf: turns)
        session.updatedAt = Date()
        if let model, !model.isEmpty, model != "default" {
            session.selectedModel = model
        }
        ChatSessionsManager.shared.saveAsync(session)
        // Same signal external writers post, so the History list refreshes.
        NotificationCenter.default.post(
            name: ChatHistoryWriter.didPersistExternallyNotification,
            object: nil
        )
    }

    /// Whether this session can be continued by the owner's phone. The
    /// owner's own chats qualify, as do the rows the phone itself created
    /// (hosted runs stamp a workspace context whose caller is the pairing
    /// key). Chats served for a workspace teammate do not.
    static func isContinuable(_ sessionId: UUID) -> Bool {
        guard let session = ChatSessionsManager.shared.session(for: sessionId) else { return false }
        guard let workspace = session.workspace else { return true }
        return isFromPairedPhone(workspace)
    }

    /// A hosted row created by this Mac's paired phone: no workspace, and
    /// the caller is the pairing key.
    static func isFromPairedPhone(_ workspace: WorkspaceSessionContext) -> Bool {
        guard workspace.workspaceId.isEmpty,
            let caller = workspace.callerWallet?.lowercased(),
            let nonce = MobilePairingService.shared.pairedKeyNonce?.lowercased()
        else { return false }
        return caller == nonce
    }
}
