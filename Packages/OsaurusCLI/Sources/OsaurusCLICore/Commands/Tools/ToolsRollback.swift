//
//  ToolsRollback.swift
//  osaurus
//
//  Command to roll back a tool to its previous installed version by updating the current symlink.
//

import Foundation
import OsaurusRepository

public struct ToolsRollback {
    public static func execute(args: [String]) {
        guard let pluginId = args.first, !pluginId.isEmpty else {
            fputs("Usage: osaurus tools rollback <plugin_id>\n", stderr)
            exit(EXIT_FAILURE)
        }
        guard let target = previousVersion(pluginId: pluginId) else {
            fputs("No previous version to roll back to for \(pluginId)\n", stderr)
            exit(EXIT_FAILURE)
        }
        do {
            try PluginInstallManager.updateCurrentSymlink(pluginId: pluginId, version: target)
            print("Rolled back \(pluginId) to \(target)")
            exit(EXIT_SUCCESS)
        } catch {
            fputs("Rollback failed: \(error)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }

    /// The version to roll back to: the installed version immediately below the
    /// currently active one, or nil when the active version is already the
    /// oldest installed (nothing to roll back to).
    ///
    /// `installedVersions` is sorted descending, so the active version is not
    /// necessarily `versions[0]`: the `current` symlink can point below the
    /// highest installed version (after a previous rollback, or when a newer
    /// version was installed without moving `current`). Resolve the active
    /// version and step to the next-lower one. When the active version is the
    /// highest, this reduces to the previous `versions[1]` behavior.
    public static func previousVersion(pluginId: String) -> SemanticVersion? {
        let versions = InstalledPluginsStore.shared.installedVersions(pluginId: pluginId)
        guard let active = InstalledPluginsStore.shared.latestInstalledVersion(pluginId: pluginId),
            let index = versions.firstIndex(of: active),
            index + 1 < versions.count
        else {
            return nil
        }
        return versions[index + 1]
    }
}
