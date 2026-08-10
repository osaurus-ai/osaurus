//
//  BrowserConfigurationStore.swift
//  OsaurusCore — Native Browser Use
//
//  Persistence for the native Browser Use configuration, stored at
//  `~/.osaurus/config/browser.json`. Browser Use is a custom-agent capability
//  (`browserUseEnabled` on `AgentSettings`); the Default agent never gets it,
//  so this file only carries feature-level state such as the one-time
//  plugin-profile migration marker.
//

import Foundation

/// Native Browser Use configuration.
public struct BrowserConfiguration: Codable, Sendable, Equatable {
    /// One-time marker: the launch sweep that copies `osaurus.browser`
    /// plugin profile UUIDs out of the Keychain has already run.
    public var pluginProfilesMigrated: Bool

    public init(pluginProfilesMigrated: Bool = false) {
        self.pluginProfilesMigrated = pluginProfilesMigrated
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pluginProfilesMigrated =
            try container.decodeIfPresent(Bool.self, forKey: .pluginProfilesMigrated) ?? false
    }
}

@MainActor
public enum BrowserConfigurationStore {
    /// Test override for the persistence directory.
    public static var overrideDirectory: URL?

    private static var cached: BrowserConfiguration?

    public static func load() -> BrowserConfiguration {
        if let cached { return cached }
        let url = configurationFileURL()
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                let config = try JSONDecoder().decode(
                    BrowserConfiguration.self, from: Data(contentsOf: url))
                cached = config
                return config
            } catch {
                print("[Osaurus] Failed to load BrowserConfiguration: \(error)")
            }
        }
        let config = BrowserConfiguration()
        cached = config
        return config
    }

    /// Serial write queue: the concurrent global queue could land two rapid
    /// saves on disk in reverse order — e.g. persisting a stale migration
    /// marker over a newer one.
    private static let persistQueue = DispatchQueue(
        label: "com.osaurus.browser.config-persist", qos: .utility)

    /// Test hook: block until every queued write has hit disk.
    public static func flushWritesForTests() {
        persistQueue.sync {}
    }

    public static func save(_ config: BrowserConfiguration) {
        cached = config
        let url = configurationFileURL()
        persistQueue.async {
            OsaurusPaths.ensureExistsSilent(url.deletingLastPathComponent())
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(config).write(to: url, options: [.atomic])
            } catch {
                print("[Osaurus] Failed to save BrowserConfiguration: \(error)")
            }
        }
    }

    private static func configurationFileURL() -> URL {
        if let dir = overrideDirectory {
            return dir.appendingPathComponent("browser.json")
        }
        return OsaurusPaths.browserConfigFile()
    }

    /// Test hook: drop the in-memory cache so the next read re-decodes.
    public static func resetCacheForTests() {
        cached = nil
    }
}
