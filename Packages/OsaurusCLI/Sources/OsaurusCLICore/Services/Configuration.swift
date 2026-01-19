//
//  Configuration.swift
//  osaurus
//
//  Service for reading CLI configuration including server port and tools directory paths.
//

import Foundation
import OsaurusRepository

public struct Configuration {
    /// The canonical bundle identifier for Osaurus
    public static let bundleId = "com.dinoki.osaurus"

    /// Application Support root directory for Osaurus
    public static func appSupportRoot() -> URL {
        ToolsPaths.appSupportRoot()
    }

    public static func resolveConfiguredPort() -> Int? {
        // Allow override for testing
        if let env = ProcessInfo.processInfo.environment["OSU_PORT"], let p = Int(env) {
            return p
        }

        // Read the same configuration the app persists
        // Check new location first: ~/Library/Application Support/com.dinoki.osaurus/config/server.json
        // Then legacy: ~/Library/Application Support/com.dinoki.osaurus/ServerConfiguration.json
        let fm = FileManager.default
        let root = appSupportRoot()
        let newConfigURL = root.appendingPathComponent("config", isDirectory: true)
            .appendingPathComponent("server.json")
        let legacyConfigURL = root.appendingPathComponent("ServerConfiguration.json")

        // Try new location first, then legacy
        let configURL: URL
        if fm.fileExists(atPath: newConfigURL.path) {
            configURL = newConfigURL
        } else if fm.fileExists(atPath: legacyConfigURL.path) {
            configURL = legacyConfigURL
        } else {
            return nil
        }

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
        ToolsPaths.toolsRootDirectory()
    }
}
