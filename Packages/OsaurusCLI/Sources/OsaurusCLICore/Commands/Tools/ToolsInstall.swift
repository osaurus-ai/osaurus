//
//  ToolsInstall.swift
//  osaurus
//
//  Command to install a plugin from a URL, local path, or registry.
//

import CryptoKit
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

        // Track the source name for parsing plugin_id and version
        var sourceName: String = ""

        // 1. Unpack/Copy to staging
        if src.hasPrefix("http://") || src.hasPrefix("https://") {
            guard let url = URL(string: src) else {
                fputs("Invalid URL: \(src)\n", stderr)
                exit(EXIT_FAILURE)
            }
            // Extract filename from URL path
            sourceName = url.lastPathComponent
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
            sourceName = pathURL.deletingPathExtension().lastPathComponent
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

        // 2. Parse plugin_id and version from source name
        // Expected format: <plugin_id>-<version> (e.g., my-plugin-1.0.0)
        guard let (pluginId, semver) = parsePluginIdAndVersion(from: sourceName) else {
            fputs("Invalid naming format. Expected: <plugin_id>-<version>.zip (e.g., my-plugin-1.0.0.zip)\n", stderr)
            exit(EXIT_FAILURE)
        }

        // Find the plugin root (unzip might create a wrapper directory)
        var pluginRoot: URL = tmpDir
        do {
            let contents = try fm.contentsOfDirectory(
                at: tmpDir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            // If there's a single subdirectory, use it as the plugin root
            if contents.count == 1, contents[0].hasDirectoryPath {
                pluginRoot = contents[0]
            }
        } catch {
            // ignore - use tmpDir as root
        }

        // 3. Install to Tools/<id>/<version>
        let installDir = PluginInstallManager.toolsVersionDirectory(pluginId: pluginId, version: semver)

        do {
            if fm.fileExists(atPath: installDir.path) {
                try fm.removeItem(at: installDir)
            }
            try fm.createDirectory(at: installDir.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: pluginRoot, to: installDir)

            // 4. Create receipt.json for manual installs
            try createManualInstallReceipt(pluginId: pluginId, version: semver, installDir: installDir)

            // 5. Update Current Symlink
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

    /// Parses plugin_id and version from a filename like "my-plugin-1.0.0" or "my-plugin-1.0.0.zip"
    /// Returns nil if the format is invalid.
    private static func parsePluginIdAndVersion(from name: String) -> (pluginId: String, version: SemanticVersion)? {
        // Remove .zip extension if present
        var baseName = name
        if baseName.lowercased().hasSuffix(".zip") {
            baseName = String(baseName.dropLast(4))
        }

        // Find the last occurrence of a version pattern (e.g., -1.0.0, -1.2.3-beta)
        // We scan from the end to find where the version starts
        let parts = baseName.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2 else { return nil }

        // Try to find a valid semver by joining parts from the end
        // Version could be "1.0.0" or "1.0.0-beta" etc.
        for i in (1 ..< parts.count).reversed() {
            let potentialVersion = parts[i...].joined(separator: "-")
            if let semver = SemanticVersion.parse(potentialVersion) {
                let pluginId = parts[0 ..< i].joined(separator: "-")
                if !pluginId.isEmpty {
                    return (pluginId, semver)
                }
            }
        }

        return nil
    }

    /// Creates a receipt.json for manual installations
    private static func createManualInstallReceipt(pluginId: String, version: SemanticVersion, installDir: URL) throws {
        // Find the dylib in the install directory
        guard let dylibURL = findFirstDylib(in: installDir) else {
            // No dylib found - skip receipt creation (plugin might not be fully built)
            return
        }

        // Calculate SHA256 of the dylib
        let dylibData = try Data(contentsOf: dylibURL)
        let digest = SHA256.hash(data: dylibData)
        let dylibSha = Data(digest).map { String(format: "%02x", $0) }.joined()

        // Create receipt structure matching PluginReceipt
        let receipt: [String: Any] = [
            "plugin_id": pluginId,
            "version": version.description,
            "installed_at": ISO8601DateFormatter().string(from: Date()),
            "dylib_filename": dylibURL.lastPathComponent,
            "dylib_sha256": dylibSha,
            "platform": "macos",
            "arch": "arm64",
        ]

        let receiptURL = installDir.appendingPathComponent("receipt.json")
        let receiptData = try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
        try receiptData.write(to: receiptURL)
    }

    private static func findFirstDylib(in directory: URL) -> URL? {
        let fm = FileManager.default
        guard
            let enumerator = fm.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return nil
        }
        for case let fileURL as URL in enumerator {
            if fileURL.pathExtension == "dylib" {
                return fileURL
            }
        }
        return nil
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
