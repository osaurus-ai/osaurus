//
//  OsaurusPaths.swift
//  osaurus
//
//  Centralized path management for all Osaurus app data.
//  Provides consistent directory structure across all components.
//

import Foundation

/// Centralized path management for all Osaurus app data.
/// All stores and services should use this module for path resolution.
public enum OsaurusPaths {
    /// Optional root directory override for tests
    /// Note: nonisolated(unsafe) since this is only set during test setup before any concurrent access
    public nonisolated(unsafe) static var overrideRoot: URL?

    // MARK: - Root Directory

    private static let defaultRoot: URL = {
        let fm = FileManager.default
        let newRoot = fm.homeDirectoryForCurrentUser.appendingPathComponent(".osaurus", isDirectory: true)
        let supportDir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let oldRoot = supportDir.appendingPathComponent("com.dinoki.osaurus", isDirectory: true)

        // Copy data from old Application Support on first access (never deletes the original).
        if fm.fileExists(atPath: oldRoot.path) {
            if !fm.fileExists(atPath: newRoot.path) {
                do {
                    try fm.copyItem(at: oldRoot, to: newRoot)
                    print("[Osaurus] Copied data from \(oldRoot.path) to \(newRoot.path)")
                    return newRoot
                } catch {
                    print("[Osaurus] Copy failed, falling back to merge: \(error)")
                }
            }
            mergeDirectory(from: oldRoot, into: newRoot)
            print("[Osaurus] Merged data from \(oldRoot.path) into \(newRoot.path)")
        }

        return newRoot
    }()

    /// The root data directory for Osaurus: `~/.osaurus/`
    public static func root() -> URL {
        if let override = overrideRoot {
            return override
        }
        return defaultRoot
    }

    // MARK: - Directory Paths

    /// Configuration files directory
    public static func config() -> URL {
        root().appendingPathComponent("config", isDirectory: true)
    }

    /// Voice-related configuration directory
    public static func voiceConfig() -> URL {
        config().appendingPathComponent("voice", isDirectory: true)
    }

    /// Provider configurations directory
    public static func providers() -> URL {
        root().appendingPathComponent("providers", isDirectory: true)
    }

    /// Agents directory
    public static func agents() -> URL {
        root().appendingPathComponent("agents", isDirectory: true)
    }

    /// Themes directory
    public static func themes() -> URL {
        root().appendingPathComponent("themes", isDirectory: true)
    }

    /// Chat sessions directory
    public static func sessions() -> URL {
        root().appendingPathComponent("sessions", isDirectory: true)
    }

    /// Schedules directory
    public static func schedules() -> URL {
        root().appendingPathComponent("schedules", isDirectory: true)
    }

    /// Watchers directory
    public static func watchers() -> URL {
        root().appendingPathComponent("watchers", isDirectory: true)
    }

    /// Runtime state directory
    public static func runtime() -> URL {
        root().appendingPathComponent("runtime", isDirectory: true)
    }

    /// Cache directory
    public static func cache() -> URL {
        root().appendingPathComponent("cache", isDirectory: true)
    }

    /// Skills directory
    public static func skills() -> URL {
        root().appendingPathComponent("skills", isDirectory: true)
    }

    /// Artifacts directory
    public static func artifacts() -> URL {
        root().appendingPathComponent("artifacts", isDirectory: true)
    }

    /// Work data directory
    public static func workData() -> URL {
        root().appendingPathComponent("work", isDirectory: true)
    }

    /// Memory system data directory
    public static func memory() -> URL {
        root().appendingPathComponent("memory", isDirectory: true)
    }

    /// Plugin binaries directory (`~/.osaurus/Tools/`)
    public static func tools() -> URL {
        root().appendingPathComponent("Tools", isDirectory: true)
    }

    /// Plugin specifications directory (`~/.osaurus/PluginSpecs/`)
    public static func toolSpecs() -> URL {
        root().appendingPathComponent("PluginSpecs", isDirectory: true)
    }

    // MARK: - Configuration Files

    public static func chatConfigFile() -> URL { config().appendingPathComponent("chat.json") }
    public static func serverConfigFile() -> URL { config().appendingPathComponent("server.json") }
    public static func toolConfigFile() -> URL { config().appendingPathComponent("tools.json") }
    public static func toastConfigFile() -> URL { config().appendingPathComponent("toast.json") }
    public static func speechConfigFile() -> URL { voiceConfig().appendingPathComponent("speech.json") }
    public static func vadConfigFile() -> URL { voiceConfig().appendingPathComponent("vad.json") }
    public static func transcriptionConfigFile() -> URL { voiceConfig().appendingPathComponent("transcription.json") }
    public static func remoteProviderConfigFile() -> URL { providers().appendingPathComponent("remote.json") }
    public static func mcpProviderConfigFile() -> URL { providers().appendingPathComponent("mcp.json") }
    public static func workDatabaseFile() -> URL { workData().appendingPathComponent("work.db") }
    public static func memoryDatabaseFile() -> URL { memory().appendingPathComponent("memory.sqlite") }
    public static func memoryConfigFile() -> URL { config().appendingPathComponent("memory.json") }

    // MARK: - File Path Helpers

    public static func agentFile(for id: UUID) -> URL {
        agents().appendingPathComponent("\(id.uuidString).json")
    }

    public static func themeFile(for id: UUID) -> URL {
        themes().appendingPathComponent("\(id.uuidString).json")
    }

    public static func sessionFile(for id: UUID) -> URL {
        sessions().appendingPathComponent("\(id.uuidString).json")
    }

    public static func scheduleFile(for id: UUID) -> URL {
        schedules().appendingPathComponent("\(id.uuidString).json")
    }

    public static func watcherFile(for id: UUID) -> URL {
        watchers().appendingPathComponent("\(id.uuidString).json")
    }

    public static func pluginDirectory(for pluginId: String) -> URL {
        tools().appendingPathComponent(pluginId, isDirectory: true)
    }

    public static func runtimeInstance(_ instanceId: String) -> URL {
        runtime().appendingPathComponent(instanceId, isDirectory: true)
    }

    // MARK: - Legacy Resolution

    /// Resolves a path, preferring the legacy location if it exists and the new location doesn't.
    public static func resolvePath(new newPath: URL, legacy legacyName: String) -> URL {
        let legacyPath = root().appendingPathComponent(legacyName)
        let fm = FileManager.default
        if fm.fileExists(atPath: legacyPath.path) && !fm.fileExists(atPath: newPath.path) {
            return legacyPath
        }
        return newPath
    }

    // MARK: - Directory Creation

    /// Ensures a directory exists, creating it if necessary
    public static func ensureExists(_ url: URL) throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if !fm.fileExists(atPath: url.path, isDirectory: &isDir) {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    /// Ensures a directory exists (non-throwing version)
    public static func ensureExistsSilent(_ url: URL) {
        try? ensureExists(url)
    }

    // MARK: - Migration

    /// Recursively copy the contents of `src` into `dest` (never deletes from `src`).
    /// When both source and destination files exist, the newer one wins.
    private static func mergeDirectory(from src: URL, into dest: URL) {
        let fm = FileManager.default
        ensureExistsSilent(dest)
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .contentModificationDateKey]
        guard let contents = try? fm.contentsOfDirectory(at: src, includingPropertiesForKeys: Array(keys)) else {
            return
        }
        for item in contents {
            let target = dest.appendingPathComponent(item.lastPathComponent)
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false

            if fm.fileExists(atPath: target.path) {
                if isDir {
                    mergeDirectory(from: item, into: target)
                } else {
                    let srcDate =
                        (try? item.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                        ?? .distantPast
                    let destDate =
                        (try? target.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                        ?? .distantPast
                    if srcDate > destDate {
                        try? fm.removeItem(at: target)
                        try? fm.copyItem(at: item, to: target)
                    }
                }
            } else {
                try? fm.copyItem(at: item, to: target)
            }
        }
    }

}
