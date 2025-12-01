//
//  ToolsList.swift
//  osaurus
//
//  Command to list all installed plugins with their IDs and versions.
//

import Foundation

public struct ToolsList {
    public static func execute(args: [String]) {
        let root = Configuration.toolsRootDirectory()
        let fm = FileManager.default
        if !fm.fileExists(atPath: root.path) {
            print("(no plugins installed)")
            exit(EXIT_SUCCESS)
        }
        do {
            let contents = try fm.contentsOfDirectory(atPath: root.path)
            if contents.isEmpty {
                print("(no plugins installed)")
            } else {
                for entry in contents.sorted() {
                    // Skip hidden files
                    if entry.hasPrefix(".") { continue }

                    let pluginDir = root.appendingPathComponent(entry, isDirectory: true)

                    // Check for "current" symlink to find active version
                    let currentLink = pluginDir.appendingPathComponent("current")
                    guard let versionName = try? fm.destinationOfSymbolicLink(atPath: currentLink.path) else {
                        // No current symlink - just print the directory name
                        print("\(entry)  (no active version)")
                        continue
                    }

                    // Read receipt.json from the current version directory
                    let receiptURL =
                        pluginDir
                        .appendingPathComponent(versionName, isDirectory: true)
                        .appendingPathComponent("receipt.json")

                    if let data = try? Data(contentsOf: receiptURL),
                        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                    {
                        let pluginId = (obj["plugin_id"] as? String) ?? entry
                        let version = (obj["version"] as? String) ?? versionName
                        print("\(pluginId)  version=\(version)")
                    } else {
                        // Receipt not found - print basic info from directory structure
                        print("\(entry)  version=\(versionName)")
                    }
                }
            }
            exit(EXIT_SUCCESS)
        } catch {
            fputs("Failed to read tools directory: \(error)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }
}
