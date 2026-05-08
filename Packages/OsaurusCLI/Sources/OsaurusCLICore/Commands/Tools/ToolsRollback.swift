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
            fputs("Использование: osaurus tools rollback <plugin_id>\n", stderr)
            exit(EXIT_FAILURE)
        }
        let versions = InstalledPluginsStore.shared.installedVersions(pluginId: pluginId)
        guard versions.count >= 2 else {
            fputs("Для \(pluginId) нет предыдущей версии для отката\n", stderr)
            exit(EXIT_FAILURE)
        }
        let target = versions[1]  // previous
        do {
            try PluginInstallManager.updateCurrentSymlink(pluginId: pluginId, version: target)
            print("Откат выполнен: \(pluginId) -> \(target)")
            exit(EXIT_SUCCESS)
        } catch {
            fputs("Откат не удался: \(error)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }
}
