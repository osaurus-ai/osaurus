//
//  DefaultAgentConfigurationStore.swift
//  osaurus
//
//  Persistence for `DefaultAgentConfiguration` at
//  `~/.osaurus/config/default-agent.json`.
//
//  One-shot migration:
//  On first load, when no `default-agent.json` exists AND the
//  UserDefaults marker `defaultAgentConfigMigrated_v1` is unset, we
//  read the relevant default-agent fields out of `ChatConfiguration`
//  (where they used to live) and seed the new file. This preserves
//  the user's existing default-agent settings — system prompt,
//  default model, manual tool/skill selections — across the split.
//  After the marker is written the migration never runs again.
//

import Foundation

@MainActor
public enum DefaultAgentConfigurationStore {
    /// Optional directory override for tests. Tests that want to
    /// exercise the store without touching the user's
    /// `~/.osaurus/config/` set this to a sandboxed `tmp` URL before
    /// calling `load()`.
    public static var overrideDirectory: URL?

    /// UserDefaults key that gates the one-shot migration from
    /// `ChatConfiguration`. Once set, the migration never re-runs even
    /// if the user manually deletes `default-agent.json` — at that
    /// point a fresh empty default is the right reset.
    static let migrationMarkerKey = "defaultAgentConfigMigrated_v1"

    /// In-memory cache. Mirrors the `AppConfiguration.chatConfig`
    /// pattern so views can read `.load()` from the main thread
    /// without paying file I/O on every redraw.
    private static var cached: DefaultAgentConfiguration?

    /// Synchronous cached read. Loads from disk (and runs the one-
    /// shot ChatConfiguration migration if needed) on first call.
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
            return DefaultAgentConfiguration.default
        }

        // One-shot migration: only when the file is missing AND the
        // migration marker is unset, copy the relevant fields out of
        // ChatConfiguration. Subsequent runs see the marker set and
        // start from a fresh default if the user deleted the file.
        let ud = UserDefaults.standard
        if !ud.bool(forKey: migrationMarkerKey) {
            let migrated = migrateFromChatConfiguration(ChatConfigurationStore.load())
            saveToDisk(migrated)
            ud.set(true, forKey: migrationMarkerKey)
            return migrated
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
            try encoder.encode(configuration).write(to: url, options: .atomic)
        } catch {
            print("[Osaurus] Failed to save default-agent.json: \(error)")
        }
    }

    // MARK: - Migration

    /// Copy the default-agent–specific fields off `ChatConfiguration`
    /// into a fresh `DefaultAgentConfiguration`. The source object is
    /// not mutated here; `ChatConfiguration.encode(to:)` simply stops
    /// writing the moved keys going forward (its `Decodable` still
    /// reads them so the migration is robust to a partial run).
    static func migrateFromChatConfiguration(
        _ chat: ChatConfiguration
    ) -> DefaultAgentConfiguration {
        DefaultAgentConfiguration(
            systemPrompt: chat.systemPrompt,
            defaultModel: chat.defaultModel,
            temperature: chat.temperature,
            maxTokens: chat.maxTokens,
            disableTools: chat.disableTools,
            autonomousExec: chat.defaultAutonomousExec,
            toolSelectionMode: chat.defaultToolSelectionMode,
            manualToolNames: chat.defaultManualToolNames,
            manualSkillNames: chat.defaultManualSkillNames
        )
    }
}
