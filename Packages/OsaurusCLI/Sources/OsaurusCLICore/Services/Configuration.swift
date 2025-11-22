//
//  Configuration.swift
//  osaurus
//
//  Service for reading CLI configuration including server port and tools directory paths.
//

import Foundation

public struct Configuration {
    public static func resolveConfiguredPort() -> Int? {
        // Allow override for testing
        if let env = ProcessInfo.processInfo.environment["OSU_PORT"], let p = Int(env) {
            return p
        }

        // Read the same configuration the app persists
        // ~/Library/Application Support/com.dinoki.osaurus/ServerConfiguration.json
        let fm = FileManager.default
        guard let supportDir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else {
            return nil
        }
        let configURL =
            supportDir
            .appendingPathComponent("com.dinoki.osaurus", isDirectory: true)
            .appendingPathComponent("ServerConfiguration.json")

        guard fm.fileExists(atPath: configURL.path) else { return nil }

        struct PartialConfig: Decodable { let port: Int? }
        do {
            let data = try Data(contentsOf: configURL)
            let cfg = try JSONDecoder().decode(PartialConfig.self, from: data)
            return cfg.port
        } catch {
            return nil
        }
    }

    public static func toolsRootDirectory() -> URL {
        let fm = FileManager.default
        let supportDir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return
            supportDir
            .appendingPathComponent("com.dinoki.osaurus", isDirectory: true)
            .appendingPathComponent("Tools", isDirectory: true)
    }
}
