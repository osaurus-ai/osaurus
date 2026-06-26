//
//  DefaultAgentConfigurationStore.swift
//  osaurus
//
//  Persistence for `DefaultAgentConfiguration` at
//  `~/.osaurus/config/default-agent.json`.
//

import Foundation

@MainActor
public enum DefaultAgentConfigurationStore {
    /// Optional directory override for tests. Tests that want to
    /// exercise the store without touching the user's
    /// `~/.osaurus/config/` set this to a sandboxed `tmp` URL before
    /// calling `load()`.
    public static var overrideDirectory: URL?

    /// In-memory cache. Mirrors the `AppConfiguration.chatConfig`
    /// pattern so views can read `.load()` from the main thread
    /// without paying file I/O on every redraw.
    private static var cached: DefaultAgentConfiguration?

    /// Synchronous cached read. Loads from disk on first call.
    public static func load() -> DefaultAgentConfiguration {
        if let cached { return cached }
        let loaded = loadFromDisk()
        cached = loaded
        return loaded
    }

    /// Persist `configuration` and update the cache. Posts a
    /// `.appConfigurationChanged` notification so observers re-read.
    public static func save(_ configuration: DefaultAgentConfiguration) {
        cached = configuration
        saveToDisk(configuration)
        NotificationCenter.default.post(name: .appConfigurationChanged, object: nil)
    }

    /// Drop the in-memory cache. Used by tests that flip
    /// `overrideDirectory` between iterations and need the next
    /// `load()` to reread from the new directory.
    public static func resetCacheForTests() {
        cached = nil
    }

    // MARK: - Disk

    private static func configFileURL() -> URL {
        if let dir = overrideDirectory {
            return dir.appendingPathComponent("default-agent.json")
        }
        return OsaurusPaths.config().appendingPathComponent("default-agent.json")
    }

    private static func loadFromDisk() -> DefaultAgentConfiguration {
        let url = configFileURL()
        if FileManager.default.fileExists(atPath: url.path) {
            if let data = try? Data(contentsOf: url),
                let decoded = try? JSONDecoder().decode(DefaultAgentConfiguration.self, from: data)
            {
                return decoded
            }
            // File exists but unreadable — fall through to a fresh
            // default. Do NOT auto-overwrite the on-disk file; see the
            // explicit no-implicit-save warning in
            // `AppConfiguration.loadFromDisk`.
            print("[Osaurus] Failed to decode default-agent.json — using defaults (file preserved)")
            ToastManager.shared.warning(
                L("Default agent settings unreadable"),
                message: L("Using defaults; your saved file was left untouched.")
            )
            return DefaultAgentConfiguration.default
        }

        return DefaultAgentConfiguration.default
    }

    private static func saveToDisk(_ configuration: DefaultAgentConfiguration) {
        let url = configFileURL()
        do {
            let dir = url.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: dir.path) {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(configuration)
            // Persist off the main thread. Tests (override directory / root)
            // read the file back immediately, so they write synchronously.
            ConfigDiskWriter.write(
                data,
                to: url,
                synchronous: overrideDirectory != nil || OsaurusPaths.overrideRoot != nil,
                onError: { error in
                    let desc = error.localizedDescription
                    print("[Osaurus] Failed to save default-agent.json: \(desc)")
                    Task { @MainActor in
                        ToastManager.shared.error(
                            L("Couldn't save default agent settings"),
                            message: desc
                        )
                    }
                }
            )
        } catch {
            print("[Osaurus] Failed to save default-agent.json: \(error)")
            ToastManager.shared.error(
                L("Couldn't save default agent settings"),
                message: error.localizedDescription
            )
        }
    }
}
