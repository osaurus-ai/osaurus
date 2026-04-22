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
    static func persist(
        source: SessionSource,
        sourcePluginId: String?,
        agentId: UUID?,
        externalKey: String?,
        finalMessages: [ChatMessage],
        model: String
    ) {
        let conversational = finalMessages.filter { $0.role != "system" }
        guard !conversational.isEmpty else { return }

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
        let turns = conversational.map { msg in
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

        let session: ChatSessionData
        if var hit = existing {
            hit.turns = turns
            hit.updatedAt = now
            hit.selectedModel = model
            if hit.title == "New Chat" {
                hit.title = ChatSessionData.generateTitle(from: turns)
            }
            session = hit
        } else {
            let storedPluginId: String?
            switch source {
            case .plugin: storedPluginId = sourcePluginId
            case .http: storedPluginId = externalKey != nil ? httpPseudoPluginId : nil
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
                dispatchTaskId: nil
            )
        }

        do {
            try db.saveSession(session)
        } catch {
            print("[ChatHistoryWriter] Failed to persist session: \(error)")
        }
    }

    /// Plugin-shaped key reserved for HTTP-origin sessions so they share
    /// the `(source_plugin_id, external_session_key)` composite index used
    /// by `findSession` without conflicting with a real plugin id.
    private static let httpPseudoPluginId = "__http__"
}
