//
//  AppConfiguration.swift
//  osaurus
//
//  Central cache for configuration loaded from disk. Loads once at startup,
//  refreshes only when config changes. Eliminates repeated file I/O in views.
//

import Foundation

extension Notification.Name {
    static let appConfigurationChanged = Notification.Name("appConfigurationChanged")
}

/// Central cache for configuration - loads from disk once, provides cached access
@MainActor
public final class AppConfiguration: ObservableObject {
    public static let shared = AppConfiguration()

    @Published public private(set) var chatConfig: ChatConfiguration
    public private(set) var foundationModelAvailable: Bool

    private init() {
        self.chatConfig = Self.loadFromDisk()
        self.foundationModelAvailable = FoundationModelService.isDefaultModelAvailable()
    }

    // MARK: - Public API

    public func reloadChatConfig() {
        chatConfig = Self.loadFromDisk()
        NotificationCenter.default.post(name: .appConfigurationChanged, object: nil)
    }

    public func updateChatConfig(_ config: ChatConfiguration) {
        chatConfig = config
        Self.saveToDisk(config)
        NotificationCenter.default.post(name: .appConfigurationChanged, object: nil)
    }

    public func refreshFoundationModelAvailable() {
        foundationModelAvailable = FoundationModelService.isDefaultModelAvailable()
    }

    // MARK: - Private

    private static func loadFromDisk() -> ChatConfiguration {
        let url = configFileURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            let defaults = ChatConfiguration.default
            saveToDisk(defaults)
            return defaults
        }
        do {
            let data = try Data(contentsOf: url)
            var config = try JSONDecoder().decode(ChatConfiguration.self, from: data)

            // One-time migration: if chat.json is missing either core model key,
            // copy values from memory.json so existing users keep their choice.
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                json["coreModelProvider"] as? String == nil || json["coreModelName"] as? String == nil
            {
                config = migrateCoreModelFromMemoryConfig(into: config)
                saveToDisk(config)
            }

            return config
        } catch {
            print("[Osaurus] Failed to load ChatConfiguration: \(error)")
            return ChatConfiguration.default
        }
    }

    /// Reads core model fields from memory.json and writes them into the chat config.
    private static func migrateCoreModelFromMemoryConfig(into config: ChatConfiguration) -> ChatConfiguration {
        let memoryURL = OsaurusPaths.memoryConfigFile()
        guard FileManager.default.fileExists(atPath: memoryURL.path),
            let data = try? Data(contentsOf: memoryURL),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return config }

        var migrated = config
        if let provider = json["coreModelProvider"] as? String {
            migrated.coreModelProvider = provider
        }
        if let name = json["coreModelName"] as? String {
            migrated.coreModelName = name
        }
        print("[Osaurus] Migrated core model from memory.json: \(migrated.coreModelIdentifier ?? "none")")
        return migrated
    }

    private static func saveToDisk(_ config: ChatConfiguration) {
        let url = configFileURL()
        do {
            let dir = url.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: dir.path) {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(config).write(to: url, options: .atomic)
        } catch {
            print("[Osaurus] Failed to save ChatConfiguration: \(error)")
        }
    }

    private static func configFileURL() -> URL {
        OsaurusPaths.resolvePath(new: OsaurusPaths.chatConfigFile(), legacy: "ChatConfiguration.json")
    }
}
