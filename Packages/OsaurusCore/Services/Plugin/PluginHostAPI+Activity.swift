//
//  PluginHostAPI+Activity.swift
//  osaurus
//
//  Registers inline plugin inference (`complete` / `complete_stream`) with
//  `PluginActivityManager` while it runs. The conversation itself is not
//  written to chat history; Insights records each inference.
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
}
