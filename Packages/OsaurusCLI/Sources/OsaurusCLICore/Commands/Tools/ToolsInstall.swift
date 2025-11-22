//
//  ToolsInstall.swift
//  osaurus
//
//  Command to install a plugin from a URL, local path, or registry.
//

import Foundation
import OsaurusRepository

public struct ToolsInstall {
    public static func execute(args: [String]) async {
        guard let src = args.first, !src.isEmpty else {
            fputs("Usage: osaurus tools install <plugin_id|url-or-path> [--version <semver>]\n", stderr)
            exit(EXIT_FAILURE)
        }

        // Check if argument is a local path or URL
        if src.hasPrefix("/") || src.hasPrefix("./") || src.hasPrefix("http://") || src.hasPrefix("https://") {
            await installManual(src: src)
        } else {
            await installFromRegistry(pluginId: src, args: args)
        }
    }

    private static func installFromRegistry(pluginId: String, args: [String]) async {
        var preferredVersion: SemanticVersion? = nil
        if let idx = args.firstIndex(of: "--version"), idx + 1 < args.count {
            let vstr = args[idx + 1]
            preferredVersion = SemanticVersion.parse(vstr)
            if preferredVersion == nil {
                fputs("Invalid semver: \(vstr)\n", stderr)
                exit(EXIT_FAILURE)
            }
        }
        do {
            let result = try await PluginInstallManager.shared.install(
                pluginId: pluginId,
                preferredVersion: preferredVersion
            )
            print(
                "Installed \(result.receipt.plugin_id) @ \(result.receipt.version) to \(result.installDirectory.path)"
            )
            // Notify app to reload tools
            AppControl.postDistributedNotification(name: "com.dinoki.osaurus.control.toolsReload", userInfo: [:])
            exit(EXIT_SUCCESS)
        } catch {
            fputs("Install failed: \(error)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }

    private static func installManual(src: String) async {
        let fm = FileManager.default
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        var zipURL: URL

        if src.hasPrefix("http://") || src.hasPrefix("https://") {
            // Download
            guard let url = URL(string: src) else {
                fputs("Invalid URL: \(src)\n", stderr)
                exit(EXIT_FAILURE)
            }
            zipURL = tmp.appendingPathComponent("osaurus-plugin-\(UUID().uuidString).zip")
            do {
                let (data, resp) = try await URLSession.shared.data(from: url)
                guard let http = resp as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else {
                    fputs("Download failed (status \((resp as? HTTPURLResponse)?.statusCode ?? -1))\n", stderr)
                    exit(EXIT_FAILURE)
                }
                try data.write(to: zipURL)
            } catch {
                fputs("Download error: \(error)\n", stderr)
                exit(EXIT_FAILURE)
            }
        } else {
            var isDir: ObjCBool = false
            let pathURL = URL(fileURLWithPath: src)
            if fm.fileExists(atPath: pathURL.path, isDirectory: &isDir) {
                if isDir.boolValue {
                    // Install directory directly by copying
                    do {
                        let dest = Configuration.toolsRootDirectory().appendingPathComponent(
                            pathURL.lastPathComponent,
                            isDirectory: true
                        )
                        try fm.createDirectory(
                            at: Configuration.toolsRootDirectory(),
                            withIntermediateDirectories: true
                        )
                        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                        try fm.copyItem(at: pathURL, to: dest)
                        print("Installed \(pathURL.lastPathComponent)")
                        // Notify app to reload tools
                        AppControl.postDistributedNotification(
                            name: "com.dinoki.osaurus.control.toolsReload",
                            userInfo: [:]
                        )
                        exit(EXIT_SUCCESS)
                    } catch {
                        fputs("Install failed: \(error)\n", stderr)
                        exit(EXIT_FAILURE)
                    }
                } else if pathURL.pathExtension.lowercased() == "zip" {
                    zipURL = pathURL
                } else {
                    fputs("Unsupported file type: \(src)\n", stderr)
                    exit(EXIT_FAILURE)
                }
            } else {
                fputs("Path not found: \(src)\n", stderr)
                exit(EXIT_FAILURE)
            }
        }

        // Unzip into Tools/<basename>/
        let destRoot = Configuration.toolsRootDirectory()
        let baseName = zipURL.deletingPathExtension().lastPathComponent
        let destDir = destRoot.appendingPathComponent(baseName, isDirectory: true)
        do {
            try fm.createDirectory(at: destRoot, withIntermediateDirectories: true)
        } catch {
            // ignore
        }
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-o", zipURL.path, "-d", destDir.path]
        do {
            try unzip.run()
            unzip.waitUntilExit()
            if unzip.terminationStatus != 0 {
                fputs("unzip failed; ensure /usr/bin/unzip is available.\n", stderr)
                exit(EXIT_FAILURE)
            }
        } catch {
            fputs("Failed to run unzip: \(error)\n", stderr)
            exit(EXIT_FAILURE)
        }
        print("Installed plugin to \(destDir.path)")
        // Best-effort notify the app to reload tools
        AppControl.postDistributedNotification(name: "com.dinoki.osaurus.control.toolsReload", userInfo: [:])
        exit(EXIT_SUCCESS)
    }
}
