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
import os
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
    ///
    /// Lock-protected: `VMLXServerRuntimeSettings` is a (large) value type, so
    /// an unsynchronized `nonisolated(unsafe)` var let an off-actor reader tear
    /// a struct that a concurrent `save(_:)` was mid-write on. The unfair lock
    /// is only ever held for the pointer-sized optional copy in/out — never
    /// across file IO — so it adds no contention on the hot read path.
    private static let snapshotLock = OSAllocatedUnfairLock<VMLXServerRuntimeSettings?>(
        initialState: nil
    )

    private nonisolated static var cachedSnapshot: VMLXServerRuntimeSettings? {
        get { snapshotLock.withLock { $0 } }
        set { snapshotLock.withLock { $0 = newValue } }
    }

    /// File name. Versioned-ish: the contract version on
    /// `VMLXServerRuntimeSettings.contractVersion` controls the JSON
    /// shape so we don't need a separate filename bump for v1.
    private static let fileName = "server-runtime.json"
    private static let cacheDefaultsMigrationMarkerName =
        ".server-runtime-cache-defaults-v2-migrated"
    private static let pagedCacheDefaultOffMigrationMarkerName =
        ".server-runtime-paged-cache-default-off-v3-migrated"

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
        // Brand-new install (no settings file): run the freshly-migrated
        // settings through the same normalization as a loaded file so the
        // product defaults (q6 tied head, diffusion denoising budget, cache
        // repairs) are seeded on the very first launch, not only on reload.
        let migrated = normalizeLoadedSettings(
            migratedFromLegacy(
                serverConfiguration: ServerConfigurationStore.load() ?? .default,
                userDefaults: .standard
            )
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

    /// Pin the in-memory snapshot for THIS PROCESS ONLY, WITHOUT persisting to
    /// disk. Unlike `save(_:)`, this never writes `server-runtime.json`, so it
    /// cannot mutate the user's saved server settings. The eval CLI uses it to
    /// force a KV-cache regime (e.g. memory-only) for a run so the
    /// self-declared `OSAURUS_EVALS_KV_REGIME` provenance matches the actual
    /// runtime instead of silently inheriting the persisted/default config.
    public nonisolated static func overrideSnapshotInMemory(_ settings: VMLXServerRuntimeSettings) {
        cachedSnapshot = settings
    }

    public nonisolated static func modelLoadRAMThresholds() -> (soft: Double, hard: Double) {
        let configuration = diskBackedServerConfiguration() ?? .default
        return ServerConfiguration.normalizedModelLoadRAMThresholds(
            soft: configuration.modelLoadRAMSoftThreshold,
            hard: configuration.modelLoadRAMHardThreshold
        )
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
            normalized.mtp.acceptedTokensOnlyEnterBaseCache
        {
            normalized.mtp.mode = .auto
        }
        // Osaurus product default for block-diffusion models: 16 denoising
        // steps (~74 tok/s on diffusiongemma-26B-A4B MXFP4, coherent) vs the
        // bundle's 48 (~37 tok/s). Seeded exactly once; afterwards a blank
        // field is an explicit "use bundle default" choice.
        if normalized.generation.diffusionMaxDenoisingSteps == nil,
            !FileManager.default.fileExists(
                atPath: diffusionDefaultsMigrationMarkerURL().path
            )
        {
            normalized.generation.diffusionMaxDenoisingSteps = 16
            writeDiffusionDefaultsMigrationMarker()
        }
        // Osaurus product default: quantize the unquantized Gemma 4 QAT tied
        // head to q6 (GGUF Q6_K-parity head bandwidth) instead of fp16
        // passthrough. This is the safe speed lever — affine head quantization,
        // no compile/model-switch risk — and is the largest out-of-box Gemma 4
        // QAT speedup. Seeded once for installs that have never picked a codec
        // (nil performance, or the engine fp16 default); the marker keeps a
        // user's later explicit fp16 choice sticky.
        if (normalized.performance == nil
            || normalized.performance?.tiedHeadCodec == .fp16Passthrough),
            !FileManager.default.fileExists(
                atPath: tiedHeadDefaultsMigrationMarkerURL().path
            )
        {
            var perf = normalized.effectivePerformance
            perf.tiedHeadCodec = .q6
            normalized.performance = perf
            writeTiedHeadDefaultsMigrationMarker()
        }
        if shouldRepairLegacyCacheDefaults(normalized.cache) {
            // Keep companion-cache repair independent from the live KV codec.
            // Engine-selected is the default policy now, but ModelRuntime
            // only resolves it to TurboQuant for proven full-KV rows and
            // leaves hybrid/rotating/CCA/DSV4 rows on fp16 unless explicitly
            // overridden.
            normalized.cache.enableSSMReDerive = true
            writeCacheDefaultsMigrationMarker()
        }
        if shouldRepairPagedCacheDefault(normalized.cache) {
            normalized.cache.pagedKV.enabled = false
            writePagedCacheDefaultOffMigrationMarker()
        }
        return normalized
    }

    private nonisolated static func shouldRepairLegacyCacheDefaults(
        _ cache: VMLXServerCacheSettings
    ) -> Bool {
        guard !FileManager.default.fileExists(atPath: cacheDefaultsMigrationMarkerURL().path) else {
            return false
        }
        return cache.prefix.enabled
            && cache.prefix.legacyEntryCountCache == false
            && cache.prefix.memoryLimitMB == nil
            && cache.prefix.memoryPercent == 15.0
            && cache.prefix.ttlMinutes == nil
            && cache.pagedKV.enabled
            && cache.pagedKV.blockSize == nil
            && cache.pagedKV.maxBlocks == nil
            && cache.liveKVCodec == .none
            && cache.turboQuantKeyBits == nil
            && cache.turboQuantValueBits == nil
            && cache.defaultMaxKVSize == 65536
            && cache.longPromptMultiplier == 2.0
            && cache.storedKVCodec == .auto
            && cache.legacyDisk.enabled == false
            && cache.legacyDisk.maxSizeGB == nil
            && cache.blockDisk.enabled
            && cache.blockDisk.maxSizeGB == nil
            && cache.blockDisk.directory == nil
            && cache.enableSSMReDerive == false
    }

    private nonisolated static func writeCacheDefaultsMigrationMarker() {
        let url = cacheDefaultsMigrationMarkerURL()
        OsaurusPaths.ensureExistsSilent(url.deletingLastPathComponent())
        try? Data().write(to: url, options: [.atomic])
    }

    private nonisolated static func shouldRepairPagedCacheDefault(
        _ cache: VMLXServerCacheSettings
    ) -> Bool {
        guard !FileManager.default.fileExists(atPath: pagedCacheDefaultOffMigrationMarkerURL().path) else {
            return false
        }
        return cache.prefix.enabled
            && cache.prefix.legacyEntryCountCache == false
            && cache.prefix.memoryLimitMB == nil
            && cache.prefix.memoryPercent == 15.0
            && cache.prefix.ttlMinutes == nil
            && cache.pagedKV.enabled
            && cache.pagedKV.blockSize == nil
            && cache.pagedKV.maxBlocks == nil
            && (cache.liveKVCodec == .engineSelected || cache.liveKVCodec == .none)
            && cache.turboQuantKeyBits == nil
            && cache.turboQuantValueBits == nil
            && cache.defaultMaxKVSize == 65536
            && cache.longPromptMultiplier == 2.0
            && cache.storedKVCodec == .auto
            && cache.legacyDisk.enabled == false
            && cache.legacyDisk.maxSizeGB == nil
            && cache.blockDisk.enabled
            && cache.blockDisk.maxSizeGB == nil
            && cache.blockDisk.directory == nil
            && cache.enableSSMReDerive
    }

    private nonisolated static func writePagedCacheDefaultOffMigrationMarker() {
        let url = pagedCacheDefaultOffMigrationMarkerURL()
        OsaurusPaths.ensureExistsSilent(url.deletingLastPathComponent())
        try? Data().write(to: url, options: [.atomic])
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
        settings.generation.diffusionMaxDenoisingSteps = 16
        writeDiffusionDefaultsMigrationMarker()

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

        // Cache: seed the engine-owned topology with automatic policy.
        // Prefix, block-disk L2, and SSM rederive are on by default; paged
        // RAM KV is opt-in because it only helps materially for multibatch
        // workloads. Engine-selected live KV is resolved by ModelRuntime per
        // model family/topology: proven full-KV rows get TurboQuant, while
        // hybrid/rotating/CCA/DSV4 rows stay native/fp16 unless explicitly
        // overridden.
        settings.cache = VMLXServerCacheSettings(
            prefix: VMLXPrefixCacheSettings(
                enabled: true,
                legacyEntryCountCache: false,
                memoryLimitMB: nil,
                memoryPercent: 15,
                ttlMinutes: nil
            ),
            pagedKV: VMLXPagedKVCacheSettings(
                enabled: false,
                blockSize: nil,
                maxBlocks: nil
            ),
            liveKVCodec: .engineSelected,
            turboQuantKeyBits: nil,
            turboQuantValueBits: nil,
            // nil so the RAM-safety slider governs the default KV/context cap:
            // vmlx resolves `customDefaultMaxKVSize ?? cache.defaultMaxKVSize
            // ?? profile.defaultMaxKVSize`, so a non-nil seed here would pin the
            // cap and make the slider inert. The default slider position
            // (safe_auto) resolves to 65536, so the out-of-box cap is unchanged;
            // moving the slider (strict -> 16384, performance -> 131072,
            // diagnostic -> uncapped) now actually takes effect. Users can still
            // set an explicit cap in Cache settings, which overrides the slider.
            defaultMaxKVSize: nil,
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
            enableSSMReDerive: true
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
        updated.genTopP =
            settings.generation.topP.map(Float.init)
            ?? ServerConfiguration.default.genTopP
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

    private nonisolated static func cacheDefaultsMigrationMarkerURL() -> URL {
        directoryURL().appendingPathComponent(cacheDefaultsMigrationMarkerName)
    }

    /// One-shot seed of the Osaurus diffusion default (16 denoising steps,
    /// the measured speed/quality knee for diffusiongemma-26B-A4B). The
    /// marker keeps a user's later "blank = bundle default" choice sticky.
    static let diffusionDefaultsMigrationMarkerName =
        "diffusion-defaults-migrated.marker"

    private nonisolated static func diffusionDefaultsMigrationMarkerURL() -> URL {
        directoryURL().appendingPathComponent(diffusionDefaultsMigrationMarkerName)
    }

    private nonisolated static func writeDiffusionDefaultsMigrationMarker() {
        let url = diffusionDefaultsMigrationMarkerURL()
        OsaurusPaths.ensureExistsSilent(url.deletingLastPathComponent())
        try? Data().write(to: url, options: [.atomic])
    }

    /// Osaurus product default for the tied-LM-head codec: q6 (6-bit affine,
    /// the bandwidth/quality point matching the llama.cpp Q6_K output head used
    /// by the documented GGUF baselines). Gemma 4 QAT bundles ship the 262k
    /// tied head UNQUANTIZED (fp16), which streams ~1 GB/token; q6 is the safe
    /// speed lever (no model-switch-compile risk, unlike compiled decode).
    /// Seeded once; afterwards the user's explicit codec choice (including
    /// fp16 passthrough) stays sticky.
    static let tiedHeadDefaultsMigrationMarkerName =
        "tied-head-q6-default-migrated.marker"

    private nonisolated static func tiedHeadDefaultsMigrationMarkerURL() -> URL {
        directoryURL().appendingPathComponent(tiedHeadDefaultsMigrationMarkerName)
    }

    private nonisolated static func writeTiedHeadDefaultsMigrationMarker() {
        let url = tiedHeadDefaultsMigrationMarkerURL()
        OsaurusPaths.ensureExistsSilent(url.deletingLastPathComponent())
        try? Data().write(to: url, options: [.atomic])
    }

    private nonisolated static func pagedCacheDefaultOffMigrationMarkerURL() -> URL {
        directoryURL().appendingPathComponent(pagedCacheDefaultOffMigrationMarkerName)
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
