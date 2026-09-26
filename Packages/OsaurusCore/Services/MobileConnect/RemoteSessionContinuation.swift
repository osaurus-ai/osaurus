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

    /// How often, and for how long at most, `append` waits for the Mac to
    /// finish a reply in the same chat.
    private static let streamPollInterval = Duration.milliseconds(250)
    private static let streamWaitLimit = Duration.seconds(600)

    /// Appends the messages produced by a remote run to the session.
    /// `model` updates the stored chat's recorded model, matching what the Mac
    /// does when a turn runs under a different model.
    static func append(_ messages: [ChatMessage], to sessionId: UUID, model: String?) async {
        let turns = ChatHistoryWriter.turns(from: messages)
        guard !turns.isEmpty else { return }
        MobileConnectLog.write(
            "hosted-run: continuation appending \(turns.count) turn(s) to \(sessionId) after the run "
                + "(open in a window=\(ChatWindowManager.shared.session(forSessionId: sessionId) != nil))"
        )

        // The Mac may be replying in this same chat. Splicing the phone's
        // turns in now would put them ahead of that reply, in the transcript
        // and in the next run's context, so they wait for it — they can't be
        // refused, the phone already has its answer. `truncate` refuses
        // (`.busy`) instead, as nothing is lost by retrying later.
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: streamWaitLimit)
        while let live = ChatWindowManager.shared.session(forSessionId: sessionId), live.isStreaming,
            clock.now < deadline
        {
            try? await Task.sleep(for: streamPollInterval)
        }

        // An open window owns the live transcript: append there and let its
        // own save path persist, so the visible chat updates immediately.
        // Its model stays its own: setting `selectedModel` on a live window
        // also writes the choice back to the agent, as if picked there.
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

    enum TruncateOutcome: Equatable {
        case removed(Int)
        /// Unknown, or a chat the phone may not continue (a teammate's).
        case sessionNotFound
        case turnNotFound
        /// The Mac is running this chat right now.
        case busy
    }

    /// Drops `turnId` and everything after it, so the phone can retry a
    /// reply the way the Mac's Regenerate does: the phone re-sends the
    /// prompt, and the run appends it and the new reply again
    /// (docs/MOBILE_PROTOCOL.md §14.8).
    static func truncate(_ sessionId: UUID, fromTurnId turnId: UUID) -> TruncateOutcome {
        guard isContinuable(sessionId) else { return .sessionNotFound }

        // An open window owns the live transcript, as in `append`: cut it
        // there, or its next save would put the turns back.
        if let live = ChatWindowManager.shared.session(forSessionId: sessionId) {
            guard !live.isStreaming else { return .busy }
            guard let removed = live.truncateHostedTurns(fromTurnId: turnId) else { return .turnNotFound }
            live.save()
            return .removed(removed)
        }

        guard var session = ChatSessionStore.load(id: sessionId) else { return .sessionNotFound }
        guard let index = session.turns.firstIndex(where: { $0.id == turnId }) else { return .turnNotFound }
        let removed = session.turns.count - index
        session.turns.removeSubrange(index...)
        session.updatedAt = Date()
        ChatSessionsManager.shared.saveAsync(session)
        NotificationCenter.default.post(
            name: ChatHistoryWriter.didPersistExternallyNotification,
            object: nil
        )
        return .removed(removed)
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

    /// A hosted row created by this Mac's phone: no workspace, and the caller
    /// is a pairing key — the current one, or an earlier one, which keeps its
    /// "Osaurus Connect" label on the row. Pairing again mints a new key, and
    /// matching only the current one turned every older phone chat into a
    /// teammate's read-only one (tagged "via workspace", titled "caller →
    /// agent"). One phone per Mac, so an earlier key was the owner's too.
    static func isFromPairedPhone(_ workspace: WorkspaceSessionContext) -> Bool {
        guard workspace.workspaceId.isEmpty, let caller = workspace.callerWallet?.lowercased() else { return false }
        if workspace.callerName == MobilePairingService.keyLabel { return true }
        guard let nonce = MobilePairingService.shared.pairedKeyNonce?.lowercased() else { return false }
        return caller == nonce
    }

    /// Whether `session` is one of the phone's chats (see `isFromPairedPhone`).
    static func isFromPairedPhone(_ session: ChatSessionData) -> Bool {
        session.workspace.map(isFromPairedPhone) ?? false
    }
}
