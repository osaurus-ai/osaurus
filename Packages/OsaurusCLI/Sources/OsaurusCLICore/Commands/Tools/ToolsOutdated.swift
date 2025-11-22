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
