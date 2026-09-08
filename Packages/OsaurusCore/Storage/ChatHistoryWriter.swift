//
//  ChatHistoryWriter.swift
//  osaurus
//
//  Writer-side facade over `ChatHistoryDatabase` shared by every entry point
//  that runs raw `ChatEngine` inference (plugin `complete`/`complete_stream`,
//  HTTP `/v1/chat/completions`, etc.). Handles find-or-create-by-external-key
//  grouping and converts `ChatMessage` arrays to persistable turns.
//

import Foundation

enum ChatHistoryWriter {
    static func persistInBackground(
        source: SessionSource,
        sourcePluginId: String?,
        agentId: UUID?,
        externalKey: String?,
        finalMessages: [ChatMessage],
        model: String,
        workspace: WorkspaceSessionContext? = nil
    ) {
        Task.detached(priority: .utility) {
            persist(
                source: source,
                sourcePluginId: sourcePluginId,
                agentId: agentId,
                externalKey: externalKey,
                finalMessages: finalMessages,
                model: model,
                workspace: workspace
            )
        }
    }

    /// Plugin-shaped key reserved for workspace-served sessions (host side)
    /// so `(source_plugin_id, external_session_key)` grouping works per
    /// teammate conversation without colliding with real plugin ids.
    static let workspacePseudoPluginId = "__workspace__"

    /// Posted on the main queue after a row written outside the in-app
    /// `ChatSession.save` path lands (HTTP / plugin / workspace-served), so
    /// `ChatSessionsManager` can pick it up without polling.
    static let didPersistExternallyNotification = Notification.Name(
        "ChatHistoryWriter.didPersistExternally")

    /// Persist a completed inference round.
    /// - Parameters:
    ///   - source: `.plugin` or `.http` (or any other origin).
    ///   - sourcePluginId: plugin id, only meaningful when `source == .plugin`.
    ///   - agentId: resolved agent (nil = default agent).
    ///   - externalKey: stable grouping key (e.g. plugin `session_id`,
    ///     HTTP `X-Session-Id`). When non-nil, repeat calls with the same
    ///     `(sourcePluginId, externalKey, agentId)` update one row instead
    ///     of creating fresh ones.
    ///   - finalMessages: full conversation including the assistant turn.
    ///     System messages are stripped.
    ///   - model: model id used for inference (recorded as `selected_model`).
    ///   - workspace: set for host-side rows served for a workspace teammate
    ///     (`source == .workspace`); stamps caller + workspace on the row.
    static func persist(
        source: SessionSource,
        sourcePluginId: String?,
        agentId: UUID?,
        externalKey: String?,
        finalMessages: [ChatMessage],
        model: String,
        workspace: WorkspaceSessionContext? = nil
    ) {
        let conversational = finalMessages.filter { $0.role != "system" }
        guard !conversational.isEmpty else { return }
        // Close the launch prewarm race: an early write (first request after
        // launch) can arrive before the detached key prewarm warms the cache.
        // This runs on a background request executor — not the launch-critical
        // path — so loading the key now is safe, and it prevents silently
        // dropping the write. Only the genuine "key can't be unlocked" case
        // falls through to the skip below. Plaintext mode needs no key, so
        // the prewarm is skipped and readiness is always true.
        if StorageEncryptionPolicy.shared.isEncryptionEnabled,
            !StorageKeyManager.shared.hasCachedKey
        {
            try? StorageKeyManager.shared.prewarmCurrentKey()
        }
        guard StorageKeyManager.shared.isStorageReadyForWrites else {
            print("[ChatHistoryWriter] Skipping chat history persistence: storage key is not already unlocked")
            return
        }

        // Park if a key rotation is re-encrypting databases before
        // opening SQLCipher. No-op fast path otherwise; here so a
        // background HTTP / plugin path that hits `persist` during a
        // rotation can't open a half-rekeyed file.
        StorageMutationGate.blockingAwaitNotMutating()

        let db = ChatHistoryDatabase.shared
        do {
            try db.open()
        } catch {
            print("[ChatHistoryWriter] Failed to open chat history db: \(error)")
            return
        }

        let existing: ChatSessionData?
        if let key = externalKey, let pluginId = sourcePluginId {
            existing = db.findSession(pluginId: pluginId, externalKey: key, agentId: agentId)
        } else if let key = externalKey {
            // HTTP-style sessions key by externalKey alone (no plugin id).
            // We synthesize a stable pseudo-id ("http") to share the
            // composite index for (source_plugin_id, external_session_key).
            existing = db.findSession(pluginId: httpPseudoPluginId, externalKey: key, agentId: agentId)
        } else {
            existing = nil
        }

        let now = Date()
        let turns = turns(from: conversational)

        let session: ChatSessionData
        if var hit = existing {
            hit.turns = turns
            hit.updatedAt = now
            hit.selectedModel = model
            if hit.title == "New Chat" {
                hit.title = ChatSessionData.generateTitle(from: turns)
            }
            hit.capabilities = SessionCapability.derive(from: turns)
            if let workspace { hit.workspace = workspace }
            session = hit
        } else {
            let storedPluginId: String?
            switch source {
            case .plugin: storedPluginId = sourcePluginId
            case .http: storedPluginId = externalKey != nil ? httpPseudoPluginId : nil
            case .workspace: storedPluginId = externalKey != nil ? workspacePseudoPluginId : nil
            default: storedPluginId = nil
            }
            session = ChatSessionData(
                id: UUID(),
                title: ChatSessionData.generateTitle(from: turns),
                createdAt: now,
                updatedAt: now,
                selectedModel: model,
                turns: turns,
                agentId: agentId,
                source: source,
                sourcePluginId: storedPluginId,
                externalSessionKey: externalKey,
                dispatchTaskId: nil,
                capabilities: SessionCapability.derive(from: turns),
                workspace: workspace
            )
        }

        do {
            try db.saveSession(session)
            let sessionId = session.id
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: didPersistExternallyNotification,
                    object: nil,
                    userInfo: ["sessionId": sessionId]
                )
            }
        } catch {
            print("[ChatHistoryWriter] Failed to persist session: \(error)")
        }
    }

    /// Canonical `ChatMessage` → persisted-turn mapping shared by every raw
    /// inference surface (HTTP / plugin rows written here, and the live
    /// transcript `InboundSharedRunBridge` keeps for a remote caller's run of
    /// a shared agent). System messages are dropped; tool results stay as
    /// their own `.tool` turns, keyed by `tool_call_id`.
    static func turns(from messages: [ChatMessage]) -> [ChatTurnData] {
        messages
            .filter { $0.role != "system" }
            .map { msg in
                ChatTurnData(
                    id: UUID(),
                    role: MessageRole(rawValue: msg.role) ?? .assistant,
                    content: msg.content ?? "",
                    toolCalls: msg.tool_calls,
                    toolCallId: msg.tool_call_id,
                    toolResults: [:],
                    thinking: ""
                )
            }
    }

    /// Plugin-shaped key reserved for HTTP-origin sessions so they share
    /// the `(source_plugin_id, external_session_key)` composite index used
    /// by `findSession` without conflicting with a real plugin id.
    private static let httpPseudoPluginId = "__http__"
}
