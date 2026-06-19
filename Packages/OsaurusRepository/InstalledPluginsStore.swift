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

        public init(url: String, sha256: String, minisign: MinisignInfo? = nil, size: Int? = nil) {
            self.url = url
            self.sha256 = sha256
            self.minisign = minisign
            self.size = size
        }
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

    public init(
        plugin_id: String,
        version: SemanticVersion,
        installed_at: Date,
        dylib_filename: String,
        dylib_sha256: String,
        platform: String,
        arch: String,
        public_keys: [String: String]? = nil,
        artifact: ArtifactInfo
    ) {
        self.plugin_id = plugin_id
        self.version = version
        self.installed_at = installed_at
        self.dylib_filename = dylib_filename
        self.dylib_sha256 = dylib_sha256
        self.platform = platform
        self.arch = arch
        self.public_keys = public_keys
        self.artifact = artifact
    }
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

            // Must contain a receipt.json OR a .dylib file (for dev mode)
            let receiptURL = entry.appendingPathComponent("receipt.json", isDirectory: false)
            if !fm.fileExists(atPath: receiptURL.path) {
                // Check for any .dylib file
                guard let files = try? fm.contentsOfDirectory(atPath: entry.path),
                    files.contains(where: { $0.hasSuffix(".dylib") })
                else {
                    continue
                }
            }

            versions.append(version)
        }

        return versions.sorted(by: >)
    }

    /// Returns all installed plugin IDs by scanning the Tools root directory.
    /// A plugin ID is included if its directory contains at least one valid version with a receipt.
    public func allInstalledPluginIds() -> [String] {
        let fm = FileManager.default
        let root = ToolsPaths.toolsRootDirectory()

        guard
            let entries = try? fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return []
        }

        var pluginIds: [String] = []
        for entry in entries {
            guard entry.hasDirectoryPath else { continue }
            let pluginId = entry.lastPathComponent
            if !installedVersions(pluginId: pluginId).isEmpty {
                pluginIds.append(pluginId)
            }
        }
        return pluginIds
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

            var isValid = fm.fileExists(atPath: receiptURL.path)
            if !isValid, let files = try? fm.contentsOfDirectory(atPath: versionDir.path) {
                isValid = files.contains(where: { $0.hasSuffix(".dylib") })
            }

            if isValid, let version = SemanticVersion.parse(dest) {
                return version
            }
        }

        // Fall back to highest installed version
        return installedVersions(pluginId: pluginId).first
    }

    /// Immutable, value-typed view of on-disk install state captured in a single
    /// scan. Built by `snapshot()` so callers can resolve every plugin's latest
    /// version once, off the main actor, then assemble UI state without further
    /// file I/O.
    public struct Snapshot: Sendable {
        public let installedIds: [String]
        public let latestVersions: [String: SemanticVersion]

        public func latestVersion(for pluginId: String) -> SemanticVersion? {
            latestVersions[pluginId]
        }
    }

    /// Scans the Tools directory and resolves each installed plugin's latest
    /// version in one pass. Performs synchronous file I/O (directory listings and
    /// `readlink` via `latestInstalledVersion`) and MUST be called off the main
    /// actor — running these per-plugin probes on the main thread has tripped the
    /// app-hang detector.
    public func snapshot() -> Snapshot {
        let ids = allInstalledPluginIds()
        var versions: [String: SemanticVersion] = [:]
        versions.reserveCapacity(ids.count)
        for id in ids {
            versions[id] = latestInstalledVersion(pluginId: id)
        }
        return Snapshot(installedIds: ids, latestVersions: versions)
    }
}
