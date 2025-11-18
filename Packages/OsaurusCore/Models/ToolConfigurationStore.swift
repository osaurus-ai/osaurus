//
//  ToolConfigurationStore.swift
//  osaurus
//
//  Persistence for ToolConfiguration (Application Support bundle directory)
//

import Foundation

@MainActor
enum ToolConfigurationStore {
    static var overrideDirectory: URL?

    static func load() -> ToolConfiguration {
        let url = configurationFileURL()
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                let data = try Data(contentsOf: url)
                let decoder = JSONDecoder()
                return try decoder.decode(ToolConfiguration.self, from: data)
            } catch {
                print("[Osaurus] Failed to load ToolConfiguration: \(error)")
            }
        }
        // Defaults: all tools disabled (empty map implies disabled)
        let defaults = ToolConfiguration()
        save(defaults)
        return defaults
    }

    static func save(_ configuration: ToolConfiguration) {
        let url = configurationFileURL()
        do {
            try ensureDirectoryExists(url.deletingLastPathComponent())
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(configuration)
            try data.write(to: url, options: [.atomic])
        } catch {
            print("[Osaurus] Failed to save ToolConfiguration: \(error)")
        }
    }

    // MARK: - Private
    private static func configurationFileURL() -> URL {
        if let overrideDirectory {
            return overrideDirectory.appendingPathComponent("ToolConfiguration.json")
        }
        let fm = FileManager.default
        let supportDir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let bundleId = Bundle.main.bundleIdentifier ?? "osaurus"
        return supportDir.appendingPathComponent(bundleId, isDirectory: true)
            .appendingPathComponent("ToolConfiguration.json")
    }

    private static func ensureDirectoryExists(_ url: URL) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}
