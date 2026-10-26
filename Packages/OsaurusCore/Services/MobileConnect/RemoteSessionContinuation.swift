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
        let hasReasoning = !turn.thinking.isEmpty || turn.reasoningItemId != nil || turn.reasoningEncrypted != nil
        let hasNativeState = !turn.responsesOutputItems.isEmpty || !turn.anthropicThinkingBlocks.isEmpty
        guard hasContent || hasCalls || hasReasoning || hasNativeState else { return nil }
        // The blocks the turn was sent with go back in front, so the model
        // reads the same bytes again and a local model's cache still matches.
        return ChatMessage(
            role: turn.role.rawValue,
            content: (turn.injectedContextPrefix ?? "") + turn.content,
            tool_calls: turn.toolCalls,
            tool_call_id: turn.toolCallId,
            reasoning_content: turn.thinking.isEmpty ? nil : turn.thinking,
            reasoning_item_id: turn.reasoningItemId,
            reasoning_encrypted: turn.reasoningEncrypted,
            responses_output_items: turn.responsesOutputItems.isEmpty ? nil : turn.responsesOutputItems,
            anthropic_thinking_blocks: turn.anthropicThinkingBlocks.isEmpty ? nil : turn.anthropicThinkingBlocks
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
        await append(turns: ChatHistoryWriter.turns(from: messages), to: sessionId, model: model)
    }

    /// Appends an image model's exchange from the phone (§12.5): the prompt,
    /// with any source images, then a reply holding the generated files the
    /// way the Mac's own image mode writes it, so both sides render it.
    static func appendImageExchange(
        prompt: String,
        sourceImages: [Data],
        generated: [URL],
        to sessionId: UUID,
        model: String
    ) async {
        // A new phone chat whose first message is this image prompt.
        if let agentId = pendingImageChats.removeValue(forKey: sessionId), !generated.isEmpty,
            !isContinuable(sessionId)
        {
            let asked = [ChatMessage(role: "user", content: prompt)]
            _ = await startPhoneChat(sessionId, agentId: agentId, messages: asked)
        }
        guard !generated.isEmpty, isContinuable(sessionId) else { return }
        let now = Date()
        // The prompt as the link's alt text, minus the brackets and line
        // breaks that would end it early, or no reader (the Mac's markdown,
        // `SessionTurnImages`, the phone) would find the image.
        let alt = prompt.map { "[]\n\r".contains($0) ? " " : String($0) }.joined()
        let reply = generated.map { "![\(alt)](\($0.absoluteString))" }.joined(separator: "\n\n")
        let turns = [
            ChatTurnData(role: .user, content: prompt, attachments: sourceImages.map(Attachment.image), createdAt: now),
            ChatTurnData(role: .assistant, content: reply, createdAt: now, completedAt: now),
        ]
        await append(turns: turns, to: sessionId, model: model)
    }

    private static func append(turns: [ChatTurnData], to sessionId: UUID, model: String?) async {
        guard !turns.isEmpty else { return }
        MobileConnectLog.hostedRun(
            "continuation appending \(turns.count) turn(s) to \(sessionId) after the run "
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

    /// Deletes the chat for good, as the Mac's History Delete does
    /// (docs/MOBILE_PROTOCOL.md §14.10). False for an unknown id or a chat
    /// the phone may not continue (a teammate's).
    static func delete(_ sessionId: UUID) -> Bool {
        guard isContinuable(sessionId) else { return false }
        ChatWindowManager.shared.deleteSession(id: sessionId)
        return true
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
    /// "Mobile" (or pre-rename "Osaurus Connect") label on the row. Pairing again mints a new key, and
    /// matching only the current one turned every older phone chat into a
    /// teammate's read-only one (tagged "via workspace", titled "caller →
    /// agent"). One phone per Mac, so an earlier key was the owner's too.
    static func isFromPairedPhone(_ workspace: WorkspaceSessionContext) -> Bool {
        guard workspace.workspaceId.isEmpty, let caller = workspace.callerWallet?.lowercased() else { return false }
        if let name = workspace.callerName, MobilePairingService.allKeyLabels.contains(name) { return true }
        guard let nonce = MobilePairingService.shared.pairedKeyNonce?.lowercased() else { return false }
        return caller == nonce
    }

    /// Whether `session` is one of the phone's chats: one it started (see
    /// `startPhoneChat`), or an older hosted row (see `isFromPairedPhone`).
    static func isFromPairedPhone(_ session: ChatSessionData) -> Bool {
        if session.source == .chat, session.externalSessionKey == phoneChatKey { return true }
        return session.workspace.map(isFromPairedPhone) ?? false
    }

    /// Marks a chat the phone started. It is otherwise an ordinary chat:
    /// no workspace stamp, so the Mac can open and continue it as its own.
    static let phoneChatKey = "osaurus-connect-phone"

    /// Whether the caller's access key is the one the phone was paired with.
    static func isPairedPhoneKey(_ keyNonce: String?) -> Bool {
        guard let keyNonce, let paired = MobilePairingService.shared.pairedKeyNonce else { return false }
        return keyNonce.lowercased() == paired.lowercased()
    }

    /// An older phone chat, a hosted row the Mac shows read-only, becomes an
    /// ordinary chat when the phone continues it, so the Mac can continue it
    /// too. Left for a later run while a tab or window holds it: its next
    /// save would stamp the row back. A teammate's row is never touched.
    static func adoptHostedPhoneChat(_ sessionId: UUID) async {
        guard var session = await ChatSessionStore.loadAsync(id: sessionId),
            session.source == .workspace, let workspace = session.workspace, isFromPairedPhone(workspace),
            BackgroundTaskManager.shared.taskState(for: sessionId) == nil,
            ChatWindowManager.shared.session(forSessionId: sessionId) == nil
        else { return }
        session.source = .chat
        session.sourcePluginId = nil
        session.workspace = nil
        session.externalSessionKey = phoneChatKey
        ChatSessionsManager.shared.save(session)
        NotificationCenter.default.post(name: ChatHistoryWriter.didPersistExternallyNotification, object: nil)
        MobileConnectLog.write("phone chat \(sessionId) is now an ordinary chat")
    }

    /// Phone runs under way, by chat: until their turns are in, the Mac's
    /// own composer holds a send for that chat, so turns never interleave.
    private static var phoneRuns: [UUID: Int] = [:]

    static func isPhoneReplying(_ sessionId: UUID) -> Bool { phoneRuns[sessionId] != nil }

    static func beginPhoneRun(_ sessionId: UUID) {
        phoneRuns[sessionId, default: 0] += 1
        // "Running…" on the chat in History, as for a reply the Mac makes.
        SessionActivityMonitor.shared.reportSession(sessionId, status: .working)
    }

    /// The run's turns are in: a send the Mac held for this chat goes now.
    static func endPhoneRun(_ sessionId: UUID) {
        guard let count = phoneRuns[sessionId] else { return }
        if count > 1 {
            phoneRuns[sessionId] = count - 1
            return
        }
        phoneRuns.removeValue(forKey: sessionId)
        SessionActivityMonitor.shared.reportSession(sessionId, status: nil)
        ChatWindowManager.shared.session(forSessionId: sessionId)?.sendHeldForPhone()
    }

    /// Image prompts starting a phone chat, by chat id, with the agent to
    /// start it under. The chat is created once the image is in, with it.
    private static var pendingImageChats: [UUID: UUID] = [:]

    /// The phone starts chat `sessionId` with an image prompt (§14.5).
    /// Honoured for the paired phone's key and an agent this Mac has.
    static func notePhoneImageChat(_ sessionId: UUID, agentId: UUID, keyNonce: String?) {
        guard isPairedPhoneKey(keyNonce), AgentManager.shared.agent(for: agentId) != nil else { return }
        pendingImageChats[sessionId] = agentId
    }

    /// Starts the chat the phone named `sessionId` on its first run
    /// (docs/MOBILE_PROTOCOL.md §14.5), titled from what was asked. The run
    /// appends its turns when it ends, as for any continued chat. False when
    /// the id is already taken: an existing chat is never replaced.
    static func startPhoneChat(_ sessionId: UUID, agentId: UUID, messages: [ChatMessage]) async -> Bool {
        guard ChatSessionsManager.shared.session(for: sessionId) == nil,
            await ChatSessionStore.loadAsync(id: sessionId) == nil
        else { return false }
        let asked = ChatHistoryWriter.turns(from: messages.filter { $0.role == "user" })
        let session = ChatSessionData(
            id: sessionId,
            title: ChatSessionData.generateTitle(from: asked),
            // As a hosted phone row does, so `GET /sessions?agent_id=` lists it.
            agentId: agentId,
            externalSessionKey: phoneChatKey
        )
        ChatSessionsManager.shared.save(session)
        NotificationCenter.default.post(name: ChatHistoryWriter.didPersistExternallyNotification, object: nil)
        MobileConnectLog.write("phone started chat \(sessionId)")
        return true
    }
}
