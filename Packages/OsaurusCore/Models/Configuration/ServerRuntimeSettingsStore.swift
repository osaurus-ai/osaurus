//
//  ServerRuntimeSettingsStore.swift
//  osaurus
//
//  Persistence for `VMLXServerRuntimeSettings` — the centralized
//  server/API runtime contract from vmlx-swift. This is the single
//  source of truth for every server-side knob exposed in
//  `ServerView`'s Settings tab.
//
//  Storage layout: `~/.osaurus/config/server-runtime.json`
//
//  Legacy `server.json` (`ServerConfiguration`) keeps owning the NIO
//  socket fields (port, expose, allowedOrigins, eviction, idle
//  residency, body limits, app-shell prefs). On every save here we
//  also project the network/generation fields back into `server.json`
//  so the existing `OsaurusServer` start path keeps working unchanged.
//

import Foundation
@preconcurrency import MLXLMCommon

/// Centralized persistence for `VMLXServerRuntimeSettings`.
public enum ServerRuntimeSettingsStore {
    /// When set, configuration reads/writes use this directory instead
    /// of the default. Used by tests.
    /// Note: nonisolated(unsafe) since this is only set during test
    /// setup before any concurrent access, matching the pattern used
    /// by `OsaurusPaths.overrideRoot`.
    public nonisolated(unsafe) static var overrideDirectory: URL?

    /// Hot snapshot accessed by non-MainActor runtime code paths
    /// (`ModelRuntime.buildCacheCoordinatorConfig`, `MLXBatchAdapter`).
    /// Updated on every `save(_:)`.
    private nonisolated(unsafe) static var cachedSnapshot: VMLXServerRuntimeSettings?

    /// File name. Versioned-ish: the contract version on
    /// `VMLXServerRuntimeSettings.contractVersion` controls the JSON
    /// shape so we don't need a separate filename bump for v1.
    private static let fileName = "server-runtime.json"

    // MARK: - Load / Save

    /// Loads the persisted settings. Returns `nil` when no file exists
    /// and no migration source is present (caller should fall back to
    /// `migratedFromLegacy(...)`).
    public nonisolated static func load() -> VMLXServerRuntimeSettings? {
        let url = fileURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let raw = try JSONDecoder().decode(VMLXServerRuntimeSettings.self, from: Data(contentsOf: url))
            let decoded = normalizeLoadedSettings(raw)
            if decoded != raw {
                save(decoded)
            }
            cachedSnapshot = decoded
            return decoded
        } catch {
            print("[Osaurus] Failed to load ServerRuntimeSettings: \(error)")
            return nil
        }
    }

    /// Loads or builds the settings, performing one-time migration from
    /// `ServerConfiguration` + `UserDefaults` when no file exists. The
    /// returned value is always non-nil. `ServerConfigurationStore` is
    /// `@MainActor`, so this helper must be called from the main actor.
    @MainActor
    public static func loadOrMigrate() -> VMLXServerRuntimeSettings {
        if let existing = load() { return existing }
        let migrated = migratedFromLegacy(
            serverConfiguration: ServerConfigurationStore.load() ?? .default,
            userDefaults: .standard
        )
        save(migrated)
        return migrated
    }

    /// Persists the settings to disk and updates the nonisolated
    /// snapshot consumed by `ModelRuntime`.
    public nonisolated static func save(_ settings: VMLXServerRuntimeSettings) {
        let url = fileURL()
        OsaurusPaths.ensureExistsSilent(url.deletingLastPathComponent())
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(settings).write(to: url, options: [.atomic])
            cachedSnapshot = settings
        } catch {
            print("[Osaurus] Failed to save ServerRuntimeSettings: \(error)")
        }
    }

    // MARK: - Nonisolated snapshot

    /// Latest snapshot. Safe to call from any actor context; the value
    /// is updated on every `save(_:)` so the runtime always sees the
    /// last persisted configuration without a MainActor hop.
    public nonisolated static func snapshot() -> VMLXServerRuntimeSettings {
        if let cached = cachedSnapshot { return cached }
        // Cold path: read from disk synchronously the first time the
        // runtime needs the snapshot before any `MainActor` consumer
        // has loaded it. JSON decode is cheap enough to do off-actor.
        let url = directoryURL().appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: url.path),
            let data = try? Data(contentsOf: url),
            let raw = try? JSONDecoder().decode(VMLXServerRuntimeSettings.self, from: data)
        {
            let normalized = normalizeLoadedSettings(raw)
            if normalized != raw {
                save(normalized)
            }
            cachedSnapshot = normalized
            return normalized
        }
        let fallback = migratedFromLegacy(
            serverConfiguration: diskBackedServerConfiguration() ?? .default,
            userDefaults: .standard
        )
        cachedSnapshot = fallback
        return fallback
    }

    /// Reset the in-memory snapshot. Tests use this to force the next
    /// call to re-read from disk.
    public nonisolated static func invalidateSnapshot() {
        cachedSnapshot = nil
    }

    private nonisolated static func normalizeLoadedSettings(
        _ settings: VMLXServerRuntimeSettings
    ) -> VMLXServerRuntimeSettings {
        var normalized = settings
        // vmlx-swift e095d0f changed the engine default from "MTP off" to
        // "auto". Existing Osaurus installs persisted the old default exactly,
        // so without this repair tuned MXFP8/MTP bundles still never reach the
        // tensor+tuning-gated autodetect path after upgrade.
        if normalized.mtp.mode == .off,
           normalized.mtp.draftTokenLimit == nil,
           normalized.mtp.keepDraftCacheSeparate,
           normalized.mtp.acceptedTokensOnlyEnterBaseCache {
            normalized.mtp.mode = .auto
        }
        return normalized
    }

    // MARK: - Migration

    /// Builds a settings value from the legacy `ServerConfiguration`
    /// fields + `UserDefaults`. Fields with no legacy counterpart
    /// inherit the vmlx defaults.
    public nonisolated static func migratedFromLegacy(
        serverConfiguration: ServerConfiguration,
        userDefaults: UserDefaults
    ) -> VMLXServerRuntimeSettings {
        var settings = VMLXServerRuntimeSettings()

        // Network: project port + exposeToNetwork + CORS into vmlx
        // network settings.
        settings.network = VMLXServerNetworkSettings(
            host: serverConfiguration.exposeToNetwork ? "0.0.0.0" : "127.0.0.1",
            port: serverConfiguration.port,
            apiKey: nil,
            servedModelName: nil,
            rateLimitRequestsPerMinute: nil,
            timeoutSeconds: nil,
            logLevel: .info,
            corsOrigins: serverConfiguration.allowedOrigins.isEmpty
                ? ["*"]
                : serverConfiguration.allowedOrigins
        )

        // Generation defaults: only `genTopP` had a legacy override
        // surfaced in the UI. Everything else stays nil so model
        // defaults still win.
        let defaultTopP = ServerConfiguration.default.genTopP
        settings.generation = VMLXServerGenerationDefaults(
            streamInterval: 1,
            maxTokens: nil,
            temperature: nil,
            topP: serverConfiguration.genTopP == defaultTopP
                ? nil
                : Double(serverConfiguration.genTopP),
            topK: nil,
            minP: nil,
            repetitionPenalty: nil
        )

        // Concurrency: legacy UserDefaults key for BatchEngine max
        // batch size. Falls back to nil so vmlx's coordinator chooses
        // the default when the user never set anything.
        let rawMaxBatch = userDefaults.integer(
            forKey: "ai.osaurus.scheduler.mlxBatchEngineMaxBatchSize"
        )
        settings.concurrency = VMLXServerConcurrencySettings(
            maxConcurrentSequences: rawMaxBatch > 0 ? min(rawMaxBatch, 32) : nil,
            prefillBatchSize: nil,
            prefillStepSize: nil,
            completionBatchSize: nil,
            continuousBatching: true,
            smeltMode: .engineSelected
        )

        // Cache: mirror the previously-hardcoded
        // `ModelRuntime.buildCacheCoordinatorConfig` defaults so the
        // first migrated config reproduces today's behavior exactly.
        // Paged KV + block disk on, legacy disk off, SSM rederive off,
        // fp16 KV, 64K rotating window, 2.0 long-prompt multiplier.
        settings.cache = VMLXServerCacheSettings(
            prefix: VMLXPrefixCacheSettings(
                enabled: true,
                legacyEntryCountCache: false,
                memoryLimitMB: nil,
                memoryPercent: 15,
                ttlMinutes: nil
            ),
            pagedKV: VMLXPagedKVCacheSettings(
                enabled: true,
                blockSize: nil,
                maxBlocks: nil
            ),
            liveKVCodec: .none,
            turboQuantKeyBits: nil,
            turboQuantValueBits: nil,
            defaultMaxKVSize: 65536,
            longPromptMultiplier: 2.0,
            storedKVCodec: .auto,
            legacyDisk: VMLXDiskCacheSettings(
                enabled: false,
                maxSizeGB: nil,
                directory: nil
            ),
            blockDisk: VMLXBlockDiskCacheSettings(
                enabled: true,
                maxSizeGB: nil,
                directory: nil
            ),
            enableSSMReDerive: false
        )

        // Multimodal: keep media-salt requirement on (paired with any
        // reuse tier) and default to vmlx auto behavior.
        settings.multimodal = VMLXServerMultimodalSettings(
            vlmMode: .auto,
            requireMediaSaltForCache: true,
            enableVideo: true,
            enableAudio: true
        )

        // MTP / Power / Tools: vmlx defaults are good starting values.
        settings.mtp = VMLXServerMTPSettings()
        settings.power = VMLXServerPowerSettings()
        settings.tools = VMLXServerToolSettings()

        return settings
    }

    /// Project the vmlx runtime settings back into the legacy
    /// `ServerConfiguration` JSON so the NIO socket + CORS middleware
    /// keep reading from the same source after the new UI saves.
    public nonisolated static func projectIntoLegacy(
        _ settings: VMLXServerRuntimeSettings,
        base: ServerConfiguration
    ) -> ServerConfiguration {
        var updated = base
        if let port = settings.network.port {
            updated.port = port
        }
        updated.exposeToNetwork = settings.network.host == "0.0.0.0"
        // CORS: drop the wildcard sentinel ("*") when projecting back
        // since legacy code uses an empty array to mean "no extra
        // origins". The new UI keeps "*" as an explicit allow-all.
        let projectedOrigins = settings.network.corsOrigins
            .filter { $0 != "*" }
        updated.allowedOrigins = projectedOrigins
        if let topP = settings.generation.topP {
            updated.genTopP = Float(topP)
        }
        return updated
    }

    // MARK: - Paths

    private nonisolated static func directoryURL() -> URL {
        if let override = overrideDirectory { return override }
        return OsaurusPaths.config()
    }

    private nonisolated static func fileURL() -> URL {
        directoryURL().appendingPathComponent(fileName)
    }

    private nonisolated static func legacyConfigurationFileURL() -> URL {
        if let override = overrideDirectory {
            return override.appendingPathComponent("server.json")
        }
        return OsaurusPaths.resolvePath(new: OsaurusPaths.serverConfigFile(), legacy: "ServerConfiguration.json")
    }

    private nonisolated static func diskBackedServerConfiguration() -> ServerConfiguration? {
        let url = legacyConfigurationFileURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? JSONDecoder().decode(ServerConfiguration.self, from: Data(contentsOf: url))
    }
}
