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
            return try JSONDecoder().decode(ChatConfiguration.self, from: data)
        } catch {
            print("[Osaurus] Failed to load ChatConfiguration: \(error)")
            return ChatConfiguration.default
        }
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
