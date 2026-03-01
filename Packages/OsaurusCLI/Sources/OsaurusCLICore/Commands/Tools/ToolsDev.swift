//
//  ToolsDev.swift
//  osaurus
//
//  Development mode for plugins with optional web proxy for frontend HMR.
//  Watches for dylib changes and sends reload signals.
//

import Foundation
import OsaurusRepository

public struct ToolsDev {
    public static func execute(args: [String]) async {
        guard let pluginId = args.first, !pluginId.isEmpty else {
            fputs("Usage: osaurus tools dev <plugin_id> [--web-proxy <url>]\n", stderr)
            fputs("\nOptions:\n", stderr)
            fputs("  --web-proxy <url>  Proxy web/ mount to a local dev server (e.g. http://localhost:5173)\n", stderr)
            exit(EXIT_FAILURE)
        }

        var webProxyURL: String?
        if let idx = args.firstIndex(of: "--web-proxy"), idx + 1 < args.count {
            webProxyURL = args[idx + 1]
        }

        let pluginDir = ToolsPaths.toolsRootDirectory()
            .appendingPathComponent(pluginId, isDirectory: true)

        guard FileManager.default.fileExists(atPath: pluginDir.path) else {
            fputs("Plugin not found: \(pluginId)\n", stderr)
            fputs("Install it first or create the directory at: \(pluginDir.path)\n", stderr)
            exit(EXIT_FAILURE)
        }

        print("Starting dev mode for \(pluginId)")
        if let proxy = webProxyURL {
            print("Web proxy: \(proxy)")
            print("Requests to /plugins/\(pluginId)/app/* will be proxied to \(proxy)")
        }
        print("Watching for .dylib changes in \(pluginDir.path)")
        print("Press Ctrl+C to stop\n")

        // Store proxy config so the main app can read it
        if let proxy = webProxyURL {
            let configDir = ToolsPaths.root().appendingPathComponent("config", isDirectory: true)
            try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
            let devConfig: [String: Any] = [
                "plugin_id": pluginId,
                "web_proxy": proxy,
            ]
            let data = try? JSONSerialization.data(withJSONObject: devConfig, options: .prettyPrinted)
            let configFile = configDir.appendingPathComponent("dev-proxy.json")
            try? data?.write(to: configFile)
        }

        // Watch for dylib changes using a simple polling loop
        var lastModified: Date?

        // Find the current dylib
        func findDylib() -> URL? {
            let currentLink = pluginDir.appendingPathComponent("current")
            let versionDir: URL?
            if let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: currentLink.path) {
                versionDir = pluginDir.appendingPathComponent(dest, isDirectory: true)
            } else {
                versionDir = try? FileManager.default.contentsOfDirectory(
                    at: pluginDir,
                    includingPropertiesForKeys: nil,
                    options: .skipsHiddenFiles
                ).filter(\.hasDirectoryPath).first
            }
            guard let dir = versionDir else { return nil }

            if let enumerator = FileManager.default.enumerator(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: .skipsHiddenFiles
            ) {
                for case let url as URL in enumerator where url.pathExtension == "dylib" {
                    return url
                }
            }
            return nil
        }

        if let dylib = findDylib() {
            let attrs = try? FileManager.default.attributesOfItem(atPath: dylib.path)
            lastModified = attrs?[.modificationDate] as? Date
        }

        // Polling loop
        while true {
            try? await Task.sleep(nanoseconds: 1_000_000_000)  // 1 second

            if let dylib = findDylib() {
                let attrs = try? FileManager.default.attributesOfItem(atPath: dylib.path)
                let modified = attrs?[.modificationDate] as? Date

                if let modified, let last = lastModified, modified > last {
                    print("[\(timestamp())] Detected dylib change, sending reload signal...")
                    AppControl.postDistributedNotification(
                        name: "com.dinoki.osaurus.control.toolsReload",
                        userInfo: [:]
                    )
                    lastModified = modified
                    print("[\(timestamp())] Reload signal sent.")
                } else if lastModified == nil {
                    lastModified = modified
                }
            }
        }
    }

    private static func timestamp() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        return fmt.string(from: Date())
    }
}
