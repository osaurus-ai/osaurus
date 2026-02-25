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
    /// The canonical bundle identifier for Osaurus
    public static let bundleId = "com.dinoki.osaurus"

    /// Optional root directory override for tests
    /// Note: nonisolated(unsafe) since this is only set during test setup before any concurrent access
    public nonisolated(unsafe) static var overrideRoot: URL?

    // MARK: - Root Directory

    /// The root Application Support directory for Osaurus
    public static func appSupportRoot() -> URL {
        if let override = overrideRoot {
            return override
        }
        let fm = FileManager.default
        let supportDir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return supportDir.appendingPathComponent(bundleId, isDirectory: true)
    }

    // MARK: - Directory Paths

    /// Configuration files directory
    public static func config() -> URL {
        appSupportRoot().appendingPathComponent("config", isDirectory: true)
    }

    /// Voice-related configuration directory
    public static func voiceConfig() -> URL {
        config().appendingPathComponent("voice", isDirectory: true)
    }

    /// Provider configurations directory
    public static func providers() -> URL {
        appSupportRoot().appendingPathComponent("providers", isDirectory: true)
    }

    /// Agents directory
    public static func agents() -> URL {
        appSupportRoot().appendingPathComponent("agents", isDirectory: true)
    }

    /// Themes directory
    public static func themes() -> URL {
        appSupportRoot().appendingPathComponent("themes", isDirectory: true)
    }

    /// Chat sessions directory
    public static func sessions() -> URL {
        appSupportRoot().appendingPathComponent("sessions", isDirectory: true)
    }

    /// Schedules directory
    public static func schedules() -> URL {
        appSupportRoot().appendingPathComponent("schedules", isDirectory: true)
    }

    /// Watchers directory
    public static func watchers() -> URL {
        appSupportRoot().appendingPathComponent("watchers", isDirectory: true)
    }

    /// Plugins root directory
    public static func plugins() -> URL {
        appSupportRoot().appendingPathComponent("plugins", isDirectory: true)
    }

    /// Plugin specifications directory
    public static func pluginSpecs() -> URL {
        plugins().appendingPathComponent("specs", isDirectory: true)
    }

    /// Runtime state directory
    public static func runtime() -> URL {
        appSupportRoot().appendingPathComponent("runtime", isDirectory: true)
    }

    /// Cache directory
    public static func cache() -> URL {
        appSupportRoot().appendingPathComponent("cache", isDirectory: true)
    }

    /// Skills directory (future)
    public static func skills() -> URL {
        appSupportRoot().appendingPathComponent("skills", isDirectory: true)
    }

    /// Artifacts directory (future)
    public static func artifacts() -> URL {
        appSupportRoot().appendingPathComponent("artifacts", isDirectory: true)
    }

    /// Work data directory
    public static func workData() -> URL {
        appSupportRoot().appendingPathComponent("work", isDirectory: true)
    }

    /// Memory system data directory
    public static func memory() -> URL {
        appSupportRoot().appendingPathComponent("memory", isDirectory: true)
    }

    // MARK: - Legacy Paths

    /// Legacy Tools directory
    public static func legacyTools() -> URL {
        appSupportRoot().appendingPathComponent("Tools", isDirectory: true)
    }

    /// Legacy PluginSpecs directory
    public static func legacyPluginSpecs() -> URL {
        appSupportRoot().appendingPathComponent("PluginSpecs", isDirectory: true)
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
    public static func activeAgentFile() -> URL { agents().appendingPathComponent("active.txt") }
    public static func activeThemeFile() -> URL { themes().appendingPathComponent("active.json") }
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
        legacyTools().appendingPathComponent(pluginId, isDirectory: true)
    }

    public static func runtimeInstance(_ instanceId: String) -> URL {
        runtime().appendingPathComponent(instanceId, isDirectory: true)
    }

    // MARK: - Legacy Resolution

    /// Resolves a path, preferring legacy location if it exists and new location doesn't.
    /// Use this during the transition period to support existing user data.
    public static func resolvePath(new newPath: URL, legacy legacyName: String) -> URL {
        let legacyPath = appSupportRoot().appendingPathComponent(legacyName)
        let fm = FileManager.default
        if fm.fileExists(atPath: legacyPath.path) && !fm.fileExists(atPath: newPath.path) {
            return legacyPath
        }
        return newPath
    }

    /// Resolves a directory path with legacy fallback
    public static func resolveDirectory(new newPath: URL, legacy legacyName: String) -> URL {
        resolvePath(new: newPath, legacy: legacyName)
    }

    /// Resolves a file path with legacy fallback
    public static func resolveFile(new newPath: URL, legacy legacyName: String) -> URL {
        resolvePath(new: newPath, legacy: legacyName)
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

    /// Ensures all standard directories exist
    public static func ensureAllDirectoriesExist() {
        [
            config(), voiceConfig(), providers(), agents(), themes(),
            sessions(), schedules(), watchers(), plugins(), pluginSpecs(), runtime(),
            legacyTools(), legacyPluginSpecs(), workData(), memory(),
        ].forEach { ensureExistsSilent($0) }
    }

    // MARK: - Migration

    private static func getMigrations() -> [(legacy: String, new: URL)] {
        return [
            ("Personas", agents()),
            ("personas", agents()),
            ("Themes", themes()),
            ("ChatSessions", sessions()),
            ("Schedules", schedules()),
            ("SharedConfiguration", runtime()),
            ("ChatConfiguration.json", chatConfigFile()),
            ("ServerConfiguration.json", serverConfigFile()),
            ("ToolConfiguration.json", toolConfigFile()),
            ("ToastConfiguration.json", toastConfigFile()),
            ("VADConfiguration.json", vadConfigFile()),
            ("TranscriptionConfiguration.json", transcriptionConfigFile()),
            ("RemoteProviderConfiguration.json", remoteProviderConfigFile()),
            ("MCPProviderConfiguration.json", mcpProviderConfigFile()),
            ("ActivePersonaId.txt", activeAgentFile()),
            ("ActiveTheme.json", activeThemeFile()),
            ("agent/agent.db", workDatabaseFile()),
        ]
    }

    /// Migrate data from legacy locations to new standardized locations.
    /// Call once at app startup. Non-destructive - only copies if legacy exists and new doesn't.
    public static func performMigrationIfNeeded() {
        let fm = FileManager.default
        let root = appSupportRoot()
        ensureAllDirectoriesExist()

        for (legacyName, newPath) in getMigrations() {
            let legacyPath = root.appendingPathComponent(legacyName)

            guard fm.fileExists(atPath: legacyPath.path),
                !fm.fileExists(atPath: newPath.path)
            else { continue }

            ensureExistsSilent(newPath.deletingLastPathComponent())

            do {
                try fm.copyItem(at: legacyPath, to: newPath)
                print("[Osaurus] Migrated: \(legacyName)")
            } catch {
                print("[Osaurus] Migration failed for \(legacyName): \(error)")
            }
        }
    }

    /// Check if any legacy data exists that needs migration
    public static func hasLegacyData() -> Bool {
        let fm = FileManager.default
        let root = appSupportRoot()
        return getMigrations().contains { fm.fileExists(atPath: root.appendingPathComponent($0.legacy).path) }
    }
}
