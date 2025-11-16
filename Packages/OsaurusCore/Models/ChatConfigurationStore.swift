//
//  ChatConfigurationStore.swift
//  osaurus
//
//  Persistence for ChatConfiguration (Application Support bundle directory)
//

import Foundation

@MainActor
enum ChatConfigurationStore {
    static var overrideDirectory: URL?

    static func load() -> ChatConfiguration {
        let url = configurationFileURL()
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                let data = try Data(contentsOf: url)
                let decoder = JSONDecoder()
                return try decoder.decode(ChatConfiguration.self, from: data)
            } catch {
                print("[Osaurus] Failed to load ChatConfiguration: \(error)")
            }
        }
        // On first use, create defaults and persist
        let defaults = ChatConfiguration.default
        save(defaults)
        return defaults
    }

    static func save(_ configuration: ChatConfiguration) {
        let url = configurationFileURL()
        do {
            try ensureDirectoryExists(url.deletingLastPathComponent())
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(configuration)
            try data.write(to: url, options: [.atomic])
        } catch {
            print("[Osaurus] Failed to save ChatConfiguration: \(error)")
        }
    }

    // MARK: - Private
    private static func configurationFileURL() -> URL {
        if let overrideDirectory {
            return overrideDirectory.appendingPathComponent("ChatConfiguration.json")
        }
        let fm = FileManager.default
        let supportDir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let bundleId = Bundle.main.bundleIdentifier ?? "osaurus"
        return supportDir.appendingPathComponent(bundleId, isDirectory: true)
            .appendingPathComponent("ChatConfiguration.json")
    }

    private static func ensureDirectoryExists(_ url: URL) throws {
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}
