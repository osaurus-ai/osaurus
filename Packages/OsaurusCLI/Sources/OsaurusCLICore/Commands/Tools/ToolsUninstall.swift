//
//  ToolsUninstall.swift
//  osaurus
//
//  Command to uninstall a plugin by ID, name, folder name, or path.
//

import Foundation

public struct ToolsUninstall {
    public static func execute(args: [String]) {
        guard let target = args.first, !target.isEmpty else {
            fputs("Usage: osaurus tools uninstall <id|folder|path>\n", stderr)
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
            // Try direct folder under Tools root
            let candidate = root.appendingPathComponent(target, isDirectory: true)
            if fm.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
                dirToRemove = candidate
            } else {
                // Match by manifest id or name
                if let contents = try? fm.contentsOfDirectory(atPath: root.path) {
                    for entry in contents {
                        let dir = root.appendingPathComponent(entry, isDirectory: true)
                        let manifestURL = dir.appendingPathComponent("manifest.json")
                        if let data = try? Data(contentsOf: manifestURL),
                            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                        {
                            let id = (obj["id"] as? String) ?? ""
                            let name = (obj["name"] as? String) ?? ""
                            if id == target || name == target {
                                dirToRemove = dir
                                break
                            }
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
