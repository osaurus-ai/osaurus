//
//  ToolsUpgrade.swift
//  osaurus
//
//  Command to upgrade one or all tools to their latest available versions from the repository.
//

import Foundation
import OsaurusRepository

public struct ToolsUpgrade {
    public static func execute(args: [String]) async {
        let targetId = args.first
        let specs = CentralRepositoryManager.shared.listAllSpecs()
        let pluginIds: [String]
        if let t = targetId {
            pluginIds = [t]
        } else {
            // All outdated
            pluginIds = specs.map(\.plugin_id)
        }
        var failures = 0
        for pid in pluginIds {
            guard let spec = specs.first(where: { $0.plugin_id == pid }) else { continue }
            let latest = spec.versions.map(\.version).sorted(by: >).first
            let installed = InstalledPluginsStore.shared.latestInstalledVersion(pluginId: pid)
            if let latest, installed == nil || latest > installed! {
                do {
                    _ = try await PluginInstallManager.shared.install(pluginId: pid, preferredVersion: latest)
                    print("Upgraded \(pid) to \(latest)")
                } catch {
                    fputs("Upgrade failed for \(pid): \(error)\n", stderr)
                    failures += 1
                }
            }
        }
        exit(failures == 0 ? EXIT_SUCCESS : EXIT_FAILURE)
    }
}
