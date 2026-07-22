//
//  Configuration.swift
//  osaurus
//
//  Service for reading CLI configuration including server port and tools directory paths.
//

import Foundation
import OsaurusRepository

public struct Configuration {
    /// Root data directory for Osaurus (`~/.osaurus/`)
    public static func root() -> URL {
        ToolsPaths.root()
    }

    /// The previous root directory before migration to `~/.osaurus/`.
    private static func legacyRoot() -> URL {
        let fm = FileManager.default
        let supportDir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return supportDir.appendingPathComponent("com.dinoki.osaurus", isDirectory: true)
    }

    public static func resolveConfiguredPort() -> Int? {
        if let env = ProcessInfo.processInfo.environment["OSU_PORT"], let p = Int(env) {
            return p
        }

        let fm = FileManager.default
        let root = root()
        let oldRoot = legacyRoot()

        // Check ~/.osaurus/config/server.json first, then legacy Application Support locations
        let candidates: [URL] = [
            root.appendingPathComponent("config/server.json"),
            root.appendingPathComponent("ServerConfiguration.json"),
            oldRoot.appendingPathComponent("config/server.json"),
            oldRoot.appendingPathComponent("ServerConfiguration.json"),
        ]

        guard let configURL = candidates.first(where: { fm.fileExists(atPath: $0.path) }) else {
            return nil
        }

        struct PartialConfig: Decodable {
            let port: Int?
            let exposeToNetwork: Bool?
        }
        do {
            let data = try Data(contentsOf: configURL)
            let cfg = try JSONDecoder().decode(PartialConfig.self, from: data)
            return cfg.port
        } catch {
            return nil
        }
    }

    /// Whether the Osaurus HTTP server is exposed beyond loopback. Used by
    /// `osaurus mcp` to avoid printing a misleading loopback-trust message.
    public static func resolveExposeToNetwork() -> Bool {
        let fm = FileManager.default
        let root = root()
        let oldRoot = legacyRoot()
        let candidates: [URL] = [
            root.appendingPathComponent("config/server.json"),
            root.appendingPathComponent("ServerConfiguration.json"),
            oldRoot.appendingPathComponent("config/server.json"),
            oldRoot.appendingPathComponent("ServerConfiguration.json"),
        ]
        guard let configURL = candidates.first(where: { fm.fileExists(atPath: $0.path) }) else {
            return false
        }
        struct PartialConfig: Decodable { let exposeToNetwork: Bool? }
        do {
            let data = try Data(contentsOf: configURL)
            let cfg = try JSONDecoder().decode(PartialConfig.self, from: data)
            return cfg.exposeToNetwork ?? false
        } catch {
            return false
        }
    }

    public static func toolsRootDirectory() -> URL {
        ToolsPaths.toolsRootDirectory()
    }

    struct ModelsDirectoryResolution: Equatable, Sendable {
        let url: URL
        let source: String
    }

    public static func resolveModelsDirectory() -> URL {
        resolveModelsDirectoryWithSource().url
    }

    static func resolveModelsDirectoryWithSource(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        appDefaults: UserDefaults? = UserDefaults(suiteName: "com.dinoki.osaurus"),
        sharedDefaults: UserDefaults? = UserDefaults(suiteName: "group.com.osaurus.shared"),
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> ModelsDirectoryResolution {
        if let raw = environment["OSU_MODELS_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            return .init(
                url: URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true),
                source: "environment"
            )
        }
        if let bookmarkData = appDefaults?.data(forKey: "ModelDirectoryBookmark"),
            let bookmarked = resolveModelDirectoryBookmark(bookmarkData)
        {
            return .init(url: bookmarked, source: "app_bookmark")
        }
        if let stored = sharedDefaults?.string(forKey: "modelsDirectoryPath"), !stored.isEmpty {
            return .init(
                url: URL(fileURLWithPath: (stored as NSString).expandingTildeInPath, isDirectory: true),
                source: "shared_cli_setting"
            )
        }

        let fm = FileManager.default
        let current = home.appendingPathComponent("MLXModels", isDirectory: true)
        let legacy = home.appendingPathComponent("Documents/MLXModels", isDirectory: true)
        let cliFallback = home.appendingPathComponent(".osaurus/models", isDirectory: true)
        if directoryHasVisibleContents(current, fileManager: fm) { return .init(url: current, source: "app_default") }
        if directoryHasVisibleContents(legacy, fileManager: fm) { return .init(url: legacy, source: "legacy_app_default") }
        if directoryHasVisibleContents(cliFallback, fileManager: fm) {
            return .init(url: cliFallback, source: "cli_default")
        }
        if fm.fileExists(atPath: current.path) { return .init(url: current, source: "app_default") }
        if fm.fileExists(atPath: legacy.path) { return .init(url: legacy, source: "legacy_app_default") }
        if fm.fileExists(atPath: cliFallback.path) { return .init(url: cliFallback, source: "cli_default") }
        return .init(url: current, source: "app_default")
    }

    private static func resolveModelDirectoryBookmark(_ data: Data) -> URL? {
        var stale = false
        if let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ), !stale {
            return url
        }
        stale = false
        return try? URL(
            resolvingBookmarkData: data,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
    }

    private static func directoryHasVisibleContents(_ url: URL, fileManager: FileManager) -> Bool {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return false }
        return !contents.isEmpty
    }
}
