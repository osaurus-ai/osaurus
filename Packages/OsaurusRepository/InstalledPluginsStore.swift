//
//  InstalledPluginsStore.swift
//  osaurus
//
//  Provides installed plugin state derived directly from the file system (single source of truth).
//

import Foundation

public struct PluginReceipt: Codable, Equatable, Sendable {
    public struct ArtifactInfo: Codable, Equatable, Sendable {
        public let url: String
        public let sha256: String
        public let minisign: MinisignInfo?
        public let size: Int?
    }

    public let plugin_id: String
    public let version: SemanticVersion
    public let installed_at: Date
    public let dylib_filename: String
    public let dylib_sha256: String
    public let platform: String
    public let arch: String
    public let public_keys: [String: String]?
    public let artifact: ArtifactInfo
}

/// Derives installed plugin state from the file system.
/// The file system is the single source of truth - no separate index is maintained.
public final class InstalledPluginsStore: @unchecked Sendable {
    public static let shared = InstalledPluginsStore()
    private init() {}

    /// Returns the receipt for a specific plugin version by reading from file system.
    public func receipt(pluginId: String, version: SemanticVersion) -> PluginReceipt? {
        let fm = FileManager.default
        let versionDir = ToolsPaths.toolsRootDirectory()
            .appendingPathComponent(pluginId, isDirectory: true)
            .appendingPathComponent(version.description, isDirectory: true)
        let receiptURL = versionDir.appendingPathComponent("receipt.json", isDirectory: false)

        guard fm.fileExists(atPath: receiptURL.path),
            let data = try? Data(contentsOf: receiptURL),
            let receipt = try? JSONDecoder().decode(PluginReceipt.self, from: data)
        else {
            return nil
        }
        return receipt
    }

    /// Returns all installed versions for a plugin by scanning the file system.
    public func installedVersions(pluginId: String) -> [SemanticVersion] {
        let fm = FileManager.default
        let pluginDir = ToolsPaths.toolsRootDirectory()
            .appendingPathComponent(pluginId, isDirectory: true)

        guard
            let entries = try? fm.contentsOfDirectory(
                at: pluginDir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return []
        }

        // Find version directories that contain a valid receipt.json
        var versions: [SemanticVersion] = []
        for entry in entries {
            // Skip the "current" symlink
            if entry.lastPathComponent == "current" { continue }

            // Must be a directory
            guard entry.hasDirectoryPath else { continue }

            // Must have a valid version name
            guard let version = SemanticVersion.parse(entry.lastPathComponent) else { continue }

            // Must contain a receipt.json
            let receiptURL = entry.appendingPathComponent("receipt.json", isDirectory: false)
            guard fm.fileExists(atPath: receiptURL.path) else { continue }

            versions.append(version)
        }

        return versions.sorted(by: >)
    }

    /// Returns the latest installed version for a plugin.
    /// First checks the "current" symlink, then falls back to highest version.
    public func latestInstalledVersion(pluginId: String) -> SemanticVersion? {
        let fm = FileManager.default
        let pluginDir = ToolsPaths.toolsRootDirectory()
            .appendingPathComponent(pluginId, isDirectory: true)
        let currentLink = pluginDir.appendingPathComponent("current", isDirectory: false)

        // Try to follow the "current" symlink first
        if let dest = try? fm.destinationOfSymbolicLink(atPath: currentLink.path) {
            let versionDir = pluginDir.appendingPathComponent(dest, isDirectory: true)
            let receiptURL = versionDir.appendingPathComponent("receipt.json", isDirectory: false)

            if fm.fileExists(atPath: receiptURL.path),
                let version = SemanticVersion.parse(dest)
            {
                return version
            }
        }

        // Fall back to highest installed version
        return installedVersions(pluginId: pluginId).first
    }
}
