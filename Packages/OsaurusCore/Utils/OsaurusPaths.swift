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

    /// Per-agent invite ledger directory (one JSON file per agent).
    /// Sibling of `agents()` so `AgentStore` doesn't try to decode the
    /// ledger files as agent records.
    public static func agentInvites() -> URL {
        root().appendingPathComponent("agent-invites", isDirectory: true)
    }

    /// Remote (paired) agents that the receiver has added from someone else's
    /// share link. Distinct from `agents()` — those are the local agents
    /// this device owns and signs for.
    public static func remoteAgents() -> URL {
        root().appendingPathComponent("remote-agents", isDirectory: true)
    }

    /// Themes directory
    public static func themes() -> URL {
        root().appendingPathComponent("themes", isDirectory: true)
    }

    /// Chat sessions directory (legacy JSON files, archived after migration)
    public static func sessions() -> URL {
        root().appendingPathComponent("sessions", isDirectory: true)
    }

    /// Archive directory used by the chat-history SQLite migration to retain
    /// the original per-session JSON files (never deleted).
    public static func sessionsArchive() -> URL {
        root().appendingPathComponent("sessions.archive", isDirectory: true)
    }

    /// Chat history database directory
    public static func chatHistory() -> URL {
        root().appendingPathComponent("chat-history", isDirectory: true)
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

    /// Disk KV cache directory used by vmlx-swift-lm's `DiskCache` (L2 tier).
    /// Stores SQLite index + safetensors blocks keyed by model + token hash.
    public static func diskKVCache() -> URL {
        cache().appendingPathComponent("kv_v2", isDirectory: true)
    }

    /// Current size of the disk KV cache in bytes. Returns 0 when the
    /// directory doesn't exist yet.
    public static func diskKVCacheUsageBytes() -> Int {
        let url = diskKVCache()
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        return directorySize(at: url)
    }

    // MARK: - Volume free-space query
    //
    // ⚠️ Use the URL-keyed `.volumeAvailableCapacityForImportantUsageKey`
    //    rather than the legacy `attributesOfFileSystem(.systemFreeSize)`.
    //    On modern macOS (≥ 11) inside a sandboxed container the legacy
    //    API can return 0 because it reports raw bytes excluding the
    //    OS's "purgeable" allowance — which is exactly what users see
    //    in Finder. `.systemFreeSize` was the historical default and
    //    `SystemMonitorService` shipped with it for a long time, surfacing
    //    bug #964 (the dashboard reports `Available: 0 GB` even when the
    //    user clearly has free space). The URL-keyed query is what
    //    `ModelDownloadService.freeBytesOnVolume` already used; this
    //    helper consolidates both call-sites onto the same logic so the
    //    answer can never silently drift again.

    /// Returns the free-for-important-usage byte count on the volume that
    /// hosts `path`. Falls back to the legacy
    /// `attributesOfFileSystem(.systemFreeSize)` only when the modern
    /// query is unavailable. Returns `nil` if both queries fail —
    /// callers should treat `nil` as "unknown, render 'unknown'" rather
    /// than coercing to zero.
    public static func volumeFreeBytes(forPath path: String) -> Int64? {
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey]
        if let values = try? url.resourceValues(forKeys: keys),
            let capacity = values.volumeAvailableCapacityForImportantUsage
        {
            return capacity
        }
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: path),
            let free = (attrs[.systemFreeSize] as? NSNumber)?.int64Value
        {
            return free
        }
        return nil
    }

    /// Returns total volume capacity in bytes for the volume that hosts
    /// `path`. Uses `.volumeTotalCapacityKey` first, legacy `.systemSize`
    /// as fallback. Returns `nil` on full failure.
    public static func volumeTotalBytes(forPath path: String) -> Int64? {
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey]
        if let values = try? url.resourceValues(forKeys: keys),
            let capacity = values.volumeTotalCapacity
        {
            return Int64(capacity)
        }
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: path),
            let total = (attrs[.systemSize] as? NSNumber)?.int64Value
        {
            return total
        }
        return nil
    }

    /// Deletes every file under the disk KV cache directory. The directory
    /// itself is left in place (re-created on next model load via
    /// `ensureExistsSilent`). Safe to call while models are loaded — the
    /// package's `DiskCache` will reopen its SQLite handle on the next
    /// `storeAfterGeneration` call, but may log errors for writes that race
    /// the deletion. For a clean clear, call `ModelRuntime.shared.clearAll()`
    /// first to release the coordinators.
    ///
    /// Returns the number of bytes freed.
    @discardableResult
    public static func clearDiskKVCache() -> Int {
        let url = diskKVCache()
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return 0 }
        let before = directorySize(at: url)
        if let contents = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
            for entry in contents {
                try? fm.removeItem(at: entry)
            }
        }
        return before
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

    /// Methods system data directory
    public static func methods() -> URL {
        root().appendingPathComponent("methods", isDirectory: true)
    }

    /// Tool index data directory
    public static func toolIndex() -> URL {
        root().appendingPathComponent("tool-index", isDirectory: true)
    }

    /// Plugin binaries directory (`~/.osaurus/Tools/`)
    public static func tools() -> URL {
        root().appendingPathComponent("Tools", isDirectory: true)
    }

    /// Plugin specifications directory (`~/.osaurus/PluginSpecs/`)
    public static func toolSpecs() -> URL {
        root().appendingPathComponent("PluginSpecs", isDirectory: true)
    }

    /// Central sandbox plugin library (`~/.osaurus/sandbox-plugins/`)
    public static func sandboxPluginLibrary() -> URL {
        root().appendingPathComponent("sandbox-plugins", isDirectory: true)
    }

    // MARK: - Container / Sandbox Paths

    /// Container root: `~/.osaurus/container/`
    public static func container() -> URL {
        root().appendingPathComponent("container", isDirectory: true)
    }

    /// Kernel binary directory: `~/.osaurus/container/kernel/`
    public static func containerKernelDir() -> URL {
        container().appendingPathComponent("kernel", isDirectory: true)
    }

    /// Path to the Linux kernel binary
    public static func containerKernelFile() -> URL {
        containerKernelDir().appendingPathComponent("vmlinux")
    }

    /// Path to the init filesystem image: `~/.osaurus/container/initfs.ext4`
    public static func containerInitFSFile() -> URL {
        container().appendingPathComponent("initfs.ext4")
    }

    /// Mounted as `/workspace` inside the container
    public static func containerWorkspace() -> URL {
        container().appendingPathComponent("workspace", isDirectory: true)
    }

    /// Per-agent workspace directories inside the container workspace
    public static func containerAgentsDir() -> URL {
        containerWorkspace().appendingPathComponent("agents", isDirectory: true)
    }

    /// A specific agent's workspace directory (host-side path)
    public static func containerAgentDir(_ agentName: String) -> URL {
        containerAgentsDir().appendingPathComponent(agentName, isDirectory: true)
    }

    /// Shared workspace readable by all agents
    public static func containerSharedDir() -> URL {
        containerWorkspace().appendingPathComponent("shared", isDirectory: true)
    }

    // MARK: - Shared Artifacts

    /// Root directory for all shared artifacts: `~/.osaurus/artifacts/`
    public static func artifactsDir() -> URL {
        root().appendingPathComponent("artifacts", isDirectory: true)
    }

    /// Per-context artifacts directory: `~/.osaurus/artifacts/{contextId}/`
    public static func contextArtifactsDir(contextId: String) -> URL {
        artifactsDir().appendingPathComponent(contextId, isDirectory: true)
    }

    /// In-container absolute path for an agent's home directory
    public static func inContainerAgentHome(_ agentName: String) -> String {
        "/workspace/agents/\(agentName)"
    }

    /// In-container absolute path for a plugin directory
    public static func inContainerPluginDir(_ agentName: String, _ pluginName: String) -> String {
        "/workspace/agents/\(agentName)/plugins/\(pluginName)"
    }

    // MARK: - Configuration Files

    public static func chatConfigFile() -> URL { config().appendingPathComponent("chat.json") }
    public static func serverConfigFile() -> URL { config().appendingPathComponent("server.json") }
    public static func toolConfigFile() -> URL { config().appendingPathComponent("tools.json") }
    public static func toastConfigFile() -> URL { config().appendingPathComponent("toast.json") }
    public static func sandboxConfigFile() -> URL { config().appendingPathComponent("sandbox.json") }
    public static func speechConfigFile() -> URL { voiceConfig().appendingPathComponent("speech.json") }
    public static func ttsConfigFile() -> URL { voiceConfig().appendingPathComponent("tts.json") }
    public static func vadConfigFile() -> URL { voiceConfig().appendingPathComponent("vad.json") }
    public static func transcriptionConfigFile() -> URL { voiceConfig().appendingPathComponent("transcription.json") }
    public static func remoteProviderConfigFile() -> URL { providers().appendingPathComponent("remote.json") }
    public static func mcpProviderConfigFile() -> URL { providers().appendingPathComponent("mcp.json") }
    public static func workDatabaseFile() -> URL { workData().appendingPathComponent("work.db") }
    public static func memoryDatabaseFile() -> URL { memory().appendingPathComponent("memory.sqlite") }
    public static func chatHistoryDatabaseFile() -> URL {
        chatHistory().appendingPathComponent("history.sqlite")
    }
    public static func methodsDatabaseFile() -> URL { methods().appendingPathComponent("methods.sqlite") }
    public static func toolIndexDatabaseFile() -> URL { toolIndex().appendingPathComponent("tool_index.sqlite") }
    public static func memoryConfigFile() -> URL { config().appendingPathComponent("memory.json") }
    public static func relayConfigFile() -> URL { config().appendingPathComponent("relay.json") }

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

    /// Per-plugin data directory for sandboxed SQLite storage
    public static func pluginDataDirectory(for pluginId: String) -> URL {
        pluginDirectory(for: pluginId).appendingPathComponent("data", isDirectory: true)
    }

    /// Per-plugin SQLite database file
    public static func pluginDatabaseFile(for pluginId: String) -> URL {
        pluginDataDirectory(for: pluginId).appendingPathComponent("data.db")
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

    // MARK: - File Utilities

    /// Computes the total size of all files in a directory tree.
    public static func directorySize(at url: URL) -> Int {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += size
            }
        }
        return total
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
