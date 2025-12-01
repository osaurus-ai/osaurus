//
//  ToolsUninstall.swift
//  osaurus
//
//  Command to uninstall a plugin by ID, folder name, or path.
//

import Foundation

public struct ToolsUninstall {
    public static func execute(args: [String]) {
        guard let target = args.first, !target.isEmpty else {
            fputs("Usage: osaurus tools uninstall <plugin_id|folder|path>\n", stderr)
            exit(EXIT_FAILURE)
        }
        let fm = FileManager.default
        let root = Configuration.toolsRootDirectory()
        var dirToRemove: URL?
        // If target looks like a path and exists, use it
        let tURL = URL(fileURLWithPath: target)
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: tURL.path, isDirectory: &isDir), isDir.boolValue {
            dirToRemove = tURL
        } else {
            // Try direct folder under Tools root (directory name is plugin_id)
            let candidate = root.appendingPathComponent(target, isDirectory: true)
            if fm.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
                dirToRemove = candidate
            } else {
                // Match by plugin_id from receipt.json
                if let contents = try? fm.contentsOfDirectory(atPath: root.path) {
                    for entry in contents {
                        // Skip hidden files
                        if entry.hasPrefix(".") { continue }

                        let pluginDir = root.appendingPathComponent(entry, isDirectory: true)

                        // Try to read receipt.json from current version
                        let currentLink = pluginDir.appendingPathComponent("current")
                        if let versionName = try? fm.destinationOfSymbolicLink(atPath: currentLink.path) {
                            let receiptURL =
                                pluginDir
                                .appendingPathComponent(versionName, isDirectory: true)
                                .appendingPathComponent("receipt.json")

                            if let data = try? Data(contentsOf: receiptURL),
                                let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                            {
                                let pluginId = (obj["plugin_id"] as? String) ?? ""
                                if pluginId == target {
                                    dirToRemove = pluginDir
                                    break
                                }
                            }
                        }

                        // Also match by directory name (which should be the plugin_id)
                        if entry == target {
                            dirToRemove = pluginDir
                            break
                        }
                    }
                }
            }
        }
        guard let dir = dirToRemove else {
            fputs("Could not locate installed plugin for '\(target)'\n", stderr)
            exit(EXIT_FAILURE)
        }
        do {
            try fm.removeItem(at: dir)
            print("Uninstalled \(dir.lastPathComponent)")
        } catch {
            fputs("Failed to uninstall: \(error)\n", stderr)
            exit(EXIT_FAILURE)
        }
        // Notify app to reload
        AppControl.postDistributedNotification(name: "com.dinoki.osaurus.control.toolsReload", userInfo: [:])
        exit(EXIT_SUCCESS)
    }
}
