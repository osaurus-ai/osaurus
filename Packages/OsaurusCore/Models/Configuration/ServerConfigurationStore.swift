//
//  ServerConfigurationStore.swift
//  osaurus
//
//  Persistence for ServerConfiguration
//

import Foundation

@MainActor
enum ServerConfigurationStore {
    /// When set, configuration reads/writes use this directory instead of the default path.
    /// Tests write config files directly after pointing this at a fixture
    /// directory, so changing it drops the in-memory cache.
    static var overrideDirectory: URL? {
        didSet { cachedLoadResult = nil }
    }

    /// Memoized result of the last disk load. `load()` is called from hot
    /// main-actor paths (theme resolution, `ModelRuntime` feasibility checks,
    /// view bodies), and the uncached version re-read and re-decoded the JSON
    /// file every call — under disk pressure that is a user-visible hang.
    /// Double-optional: `.some(nil)` caches "no file on disk".
    private static var cachedLoadResult: ServerConfiguration??

    static func load() -> ServerConfiguration? {
        if let cached = cachedLoadResult { return cached }
        let loaded = loadFromDisk()
        cachedLoadResult = .some(loaded)
        return loaded
    }

    private static func loadFromDisk() -> ServerConfiguration? {
        let url = configurationFileURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            var configuration = try JSONDecoder().decode(ServerConfiguration.self, from: Data(contentsOf: url))
            if migrateLegacyImmediateIdleResidencyIfNeeded(&configuration) {
                save(configuration)
            }
            return configuration
        } catch {
            print("[Osaurus] Failed to load ServerConfiguration: \(error)")
            return nil
        }
    }

    static func save(_ configuration: ServerConfiguration) {
        cachedLoadResult = .some(configuration)
        let url = configurationFileURL()
        OsaurusPaths.ensureExistsSilent(url.deletingLastPathComponent())
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(configuration)
            // Persist off the main thread. Tests (override directory / root)
            // read the file back immediately, so they write synchronously.
            ConfigDiskWriter.write(
                data,
                to: url,
                synchronous: overrideDirectory != nil || OsaurusPaths.overrideRoot != nil,
                onError: { print("[Osaurus] Failed to save ServerConfiguration: \($0)") }
            )
        } catch {
            print("[Osaurus] Failed to save ServerConfiguration: \(error)")
        }
    }

    static func updateAppearanceMode(_ mode: AppearanceMode) {
        var configuration = load() ?? ServerConfiguration.default
        configuration.appearanceMode = mode
        save(configuration)
    }

    static func updateFontSizeMultiplier(_ multiplier: Double) {
        var configuration = load() ?? ServerConfiguration.default
        configuration.fontSizeMultiplier = ServerConfiguration.clampedFontSizeMultiplier(multiplier)
        save(configuration)
    }

    private static func configurationFileURL() -> URL {
        if let dir = overrideDirectory {
            return dir.appendingPathComponent("server.json")
        }
        return OsaurusPaths.resolvePath(new: OsaurusPaths.serverConfigFile(), legacy: "ServerConfiguration.json")
    }

    private static func migrateLegacyImmediateIdleResidencyIfNeeded(
        _ configuration: inout ServerConfiguration
    ) -> Bool {
        let markerURL = idleResidencyWarmDefaultMigrationMarkerURL()
        guard configuration.modelIdleResidencyPolicy == .immediately,
            !FileManager.default.fileExists(atPath: markerURL.path)
        else {
            return false
        }

        configuration.modelIdleResidencyPolicy = .defaultWarm
        OsaurusPaths.ensureExistsSilent(markerURL.deletingLastPathComponent())
        try? Data().write(to: markerURL, options: [.atomic])
        return true
    }

    private static func idleResidencyWarmDefaultMigrationMarkerURL() -> URL {
        configurationFileURL()
            .deletingLastPathComponent()
            .appendingPathComponent(".model-idle-residency-warm-default-migrated")
    }
}
