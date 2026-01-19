//
//  ServerConfigurationStore.swift
//  osaurus
//
//  Persistence for ServerConfiguration
//

import Foundation

@MainActor
enum ServerConfigurationStore {
    static func load() -> ServerConfiguration? {
        let url = configurationFileURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try JSONDecoder().decode(ServerConfiguration.self, from: Data(contentsOf: url))
        } catch {
            print("[Osaurus] Failed to load ServerConfiguration: \(error)")
            return nil
        }
    }

    static func save(_ configuration: ServerConfiguration) {
        let url = configurationFileURL()
        OsaurusPaths.ensureExistsSilent(url.deletingLastPathComponent())
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(configuration).write(to: url, options: [.atomic])
        } catch {
            print("[Osaurus] Failed to save ServerConfiguration: \(error)")
        }
    }

    private static func configurationFileURL() -> URL {
        OsaurusPaths.resolveFile(new: OsaurusPaths.serverConfigFile(), legacy: "ServerConfiguration.json")
    }
}
