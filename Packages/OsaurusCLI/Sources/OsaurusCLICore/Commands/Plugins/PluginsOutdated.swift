//
//  PluginsOutdated.swift
//  osaurus
//
//  Command to check which installed plugins have newer versions available in the repository.
//

import Foundation
import OsaurusRepository

public struct PluginsOutdated {
    public static func execute(args: [String]) {
        let specs = CentralRepositoryManager.shared.listAllSpecs()
        let fm = FileManager.default
        let root = PluginInstallManager.toolsRootDirectory()
        guard let pluginDirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            print("(no plugins installed)")
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
