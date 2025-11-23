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
        // Create a temporary staging directory
        let tmpDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        } catch {
            fputs("Failed to create temp directory: \(error)\n", stderr)
            exit(EXIT_FAILURE)
        }

        defer {
            try? fm.removeItem(at: tmpDir)
        }

        // 1. Unpack/Copy to staging
        if src.hasPrefix("http://") || src.hasPrefix("https://") {
            guard let url = URL(string: src) else {
                fputs("Invalid URL: \(src)\n", stderr)
                exit(EXIT_FAILURE)
            }
            let zipFile = tmpDir.appendingPathComponent("download.zip")
            do {
                let (data, resp) = try await URLSession.shared.data(from: url)
                guard let http = resp as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else {
                    fputs("Download failed (status \((resp as? HTTPURLResponse)?.statusCode ?? -1))\n", stderr)
                    exit(EXIT_FAILURE)
                }
                try data.write(to: zipFile)
                try unzip(zipURL: zipFile, to: tmpDir)
            } catch {
                fputs("Download/Unzip error: \(error)\n", stderr)
                exit(EXIT_FAILURE)
            }
        } else {
            let pathURL = URL(fileURLWithPath: src)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: pathURL.path, isDirectory: &isDir) {
                if isDir.boolValue {
                    // Copy contents to tmpDir
                    do {
                        let contents = try fm.contentsOfDirectory(at: pathURL, includingPropertiesForKeys: nil)
                        for item in contents {
                            try fm.copyItem(at: item, to: tmpDir.appendingPathComponent(item.lastPathComponent))
                        }
                    } catch {
                        fputs("Failed to copy directory: \(error)\n", stderr)
                        exit(EXIT_FAILURE)
                    }
                } else if pathURL.pathExtension.lowercased() == "zip" {
                    do {
                        try unzip(zipURL: pathURL, to: tmpDir)
                    } catch {
                        fputs("Unzip error: \(error)\n", stderr)
                        exit(EXIT_FAILURE)
                    }
                } else {
                    fputs("Unsupported file type: \(src)\n", stderr)
                    exit(EXIT_FAILURE)
                }
            } else {
                fputs("Path not found: \(src)\n", stderr)
                exit(EXIT_FAILURE)
            }
        }

        // 2. Read manifest.json to get ID and Version
        // Note: unzip might create a wrapper directory (e.g. MyPlugin/manifest.json)
        // We need to find where manifest.json is.
        var pluginRoot: URL = tmpDir

        if !fm.fileExists(atPath: pluginRoot.appendingPathComponent("manifest.json").path) {
            // Check if there is a single subdirectory containing manifest.json
            do {
                let contents = try fm.contentsOfDirectory(
                    at: tmpDir,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )
                if contents.count == 1, contents[0].hasDirectoryPath {
                    let sub = contents[0]
                    if fm.fileExists(atPath: sub.appendingPathComponent("manifest.json").path) {
                        pluginRoot = sub
                    }
                }
            } catch {
                // ignore
            }
        }

        let manifestURL = pluginRoot.appendingPathComponent("manifest.json")
        guard fm.fileExists(atPath: manifestURL.path) else {
            fputs("manifest.json not found in source\n", stderr)
            exit(EXIT_FAILURE)
        }

        struct Manifest: Decodable {
            let id: String?
            let plugin_id: String?
            let version: String

            var effectiveId: String? { id ?? plugin_id }
        }

        let manifest: Manifest
        do {
            let data = try Data(contentsOf: manifestURL)
            manifest = try JSONDecoder().decode(Manifest.self, from: data)
        } catch {
            fputs("Invalid manifest.json: \(error)\n", stderr)
            exit(EXIT_FAILURE)
        }

        guard let pluginId = manifest.effectiveId, !pluginId.isEmpty else {
            fputs("manifest.json missing 'id' or 'plugin_id'\n", stderr)
            exit(EXIT_FAILURE)
        }
        guard let semver = SemanticVersion.parse(manifest.version) else {
            fputs("Invalid version in manifest.json: \(manifest.version)\n", stderr)
            exit(EXIT_FAILURE)
        }

        // 3. Install to Tools/<id>/<version>
        let installDir = PluginInstallManager.toolsVersionDirectory(pluginId: pluginId, version: semver)

        do {
            if fm.fileExists(atPath: installDir.path) {
                try fm.removeItem(at: installDir)
            }
            try fm.createDirectory(at: installDir.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: pluginRoot, to: installDir)

            // 4. Update Current Symlink
            try PluginInstallManager.updateCurrentSymlink(pluginId: pluginId, version: semver)

            print("Installed \(pluginId) @ \(semver) to \(installDir.path)")

            // Notify app
            AppControl.postDistributedNotification(name: "com.dinoki.osaurus.control.toolsReload", userInfo: [:])
            exit(EXIT_SUCCESS)

        } catch {
            fputs("Installation failed: \(error)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }

    private static func unzip(zipURL: URL, to destDir: URL) throws {
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-o", "-q", zipURL.path, "-d", destDir.path]
        try unzip.run()
        unzip.waitUntilExit()
        if unzip.terminationStatus != 0 {
            throw NSError(
                domain: "ToolsInstall",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "unzip command failed"]
            )
        }
    }
}
