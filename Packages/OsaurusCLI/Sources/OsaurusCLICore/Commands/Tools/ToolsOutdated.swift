//
//  ToolsOutdated.swift
//  osaurus
//
//  Command to check which installed tools have newer versions available in the repository.
//

import Foundation
import OsaurusRepository

public struct ToolsOutdated {
    public static func execute(args: [String]) {
        let skipRefresh = args.contains("--no-refresh")

        // `outdated` is the canonical "do I have updates?" command —
        // not refreshing first means it can silently report
        // "All up to date" against a stale clone. Honor `--no-refresh`
        // for scripts / tight loops that don't want the network round-trip.
        if !skipRefresh {
            FileHandle.standardError.write(Data("Refreshing registry…\n".utf8))
            _ = CentralRepositoryManager.shared.refresh()
        }

        let specs = CentralRepositoryManager.shared.listAllSpecs()
        let fm = FileManager.default
        let root = PluginInstallManager.toolsRootDirectory()
        guard let pluginDirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            print("(no tools installed)")
            exit(EXIT_SUCCESS)
        }
        var any = false
        for pluginDir in pluginDirs where pluginDir.hasDirectoryPath {
            let pluginId = pluginDir.lastPathComponent
            let installed = InstalledPluginsStore.shared.latestInstalledVersion(pluginId: pluginId)
            guard
                let available = specs.first(where: { $0.plugin_id == pluginId })?.versions.map(\.version).sorted(by: >)
                    .first
            else {
                continue
            }
            if let inst = installed, available > inst {
                print("\(pluginId)\tinstalled: \(inst)\tavailable: \(available)")
                any = true
            }
        }
        if !any { print("All up to date.") }
        exit(EXIT_SUCCESS)
    }
}
