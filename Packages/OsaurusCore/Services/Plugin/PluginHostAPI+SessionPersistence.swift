//
//  PluginHostAPI+SessionPersistence.swift
//  osaurus
//
//  Persists inline plugin inference (`complete` / `complete_stream`) to the
//  shared chat history so plugin-driven conversations show up in the chat
//  sidebar alongside user-driven chats.
//
//  Grouping: plugins that pass a stable `session_id` in their request body
//  get one growing session per `(pluginId, session_id, agentId)`. Calls
//  without `session_id` get a fresh one-off row each invocation.
//

import Foundation

extension PluginHostContext {

    // MARK: - Activity registration

    /// Allocate a fresh activity id and register it with the
    /// `PluginActivityManager` from the C-trampoline thread (no `await`).
    /// The actual `@MainActor` mutation hops to the main actor.
    static func beginPluginActivity(
        pluginId: String,
        kind: PluginActivityRecord.Kind
    ) -> UUID {
        let id = UUID()
        Task { @MainActor in
            let displayName = await pluginDisplayName(for: pluginId)
            PluginActivityManager.shared.begin(
                id: id,
                pluginId: pluginId,
                pluginDisplayName: displayName,
                kind: kind
            )
        }
        return id
    }

    /// Release an activity id from the `PluginActivityManager`.
    static func endPluginActivity(_ id: UUID) {
        Task { @MainActor in
            PluginActivityManager.shared.end(id)
        }
    }

    @MainActor
    private static func pluginDisplayName(for pluginId: String) async -> String {
        if let manifestName = PluginManager.shared.loadedPlugin(for: pluginId)?.plugin
            .manifest.name, !manifestName.isEmpty
        {
            return manifestName
        }
        return pluginId
    }

    // MARK: - Session persistence

    /// Persist a non-streaming completion. `messages` should be the full
    /// final conversation including the assistant response.
    static func persistInference(
        pluginId: String,
        agentId: UUID?,
        externalSessionKey: String?,
        finalMessages: [ChatMessage],
        model: String
    ) {
        ChatHistoryWriter.persist(
            source: .plugin,
            sourcePluginId: pluginId,
            agentId: agentId,
            externalKey: externalSessionKey,
            finalMessages: finalMessages,
            model: model
        )
    }

    /// Persist a streamed completion. The assistant response is supplied
    /// separately because streaming callers accumulate it as a String
    /// rather than a `ChatMessage`.
    static func persistStreamingInference(
        pluginId: String,
        agentId: UUID?,
        externalSessionKey: String?,
        priorMessages: [ChatMessage],
        assistantContent: String,
        model: String
    ) {
        var combined = priorMessages
        let trimmed = assistantContent.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            combined.append(ChatMessage(role: "assistant", content: assistantContent))
        }
        ChatHistoryWriter.persist(
            source: .plugin,
            sourcePluginId: pluginId,
            agentId: agentId,
            externalKey: externalSessionKey,
            finalMessages: combined,
            model: model
        )
    }
}
