//
//  AppConfiguration.swift
//  osaurus
//
//  Central cache for configuration loaded from disk. Loads once at startup,
//  refreshes only when config changes. Eliminates repeated file I/O in views.
//

import AppKit
import Foundation

extension Notification.Name {
    static let appConfigurationChanged = Notification.Name("appConfigurationChanged")
    /// Posted (main queue) when `AppConfiguration.foundationModelAvailable`
    /// flips, so catalogs that list the `foundation` entry can rebuild.
    static let foundationModelAvailabilityChanged = Notification.Name("foundationModelAvailabilityChanged")
}

/// Central cache for configuration - loads from disk once, provides cached access
@MainActor
public final class AppConfiguration: ObservableObject {
    public static let shared = AppConfiguration()

    @Published public private(set) var chatConfig: ChatConfiguration
    @Published public private(set) var foundationModelAvailable: Bool

    private init() {
        self.chatConfig = Self.loadFromDisk()
        // The FoundationModels availability probe can block on XPC to the
        // model daemon, and the first touch of `shared` happens on the main
        // thread during launch — probe off-main and publish the result.
        self.foundationModelAvailable = false
        refreshFoundationModelAvailable(clearingUnavailableCoreModel: true)
        // Apple Intelligence can be toggled in System Settings (and the model
        // finishes downloading) while Osaurus is running. Re-probe whenever
        // the user comes back so the model picker, the "Use Foundation"
        // affordances, and the Core Model picker's unavailable hint track
        // the real state without a relaunch. The runtime router already
        // reads availability live per request.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                AppConfiguration.shared.refreshFoundationModelAvailable()
            }
        }
    }

    // MARK: - Public API

    public func reloadChatConfig() {
        chatConfig = Self.loadFromDisk()
        NotificationCenter.default.post(name: .appConfigurationChanged, object: nil)
        refreshFoundationModelAvailable(clearingUnavailableCoreModel: true)
    }

    public func updateChatConfig(_ config: ChatConfiguration) {
        chatConfig = config
        Self.saveToDisk(config)
        NotificationCenter.default.post(name: .appConfigurationChanged, object: nil)
    }

    /// `clearingUnavailableCoreModel` is only for the load paths: a transient
    /// `modelNotReady` seen on app activation must not erase the saved choice.
    public func refreshFoundationModelAvailable(clearingUnavailableCoreModel: Bool = false) {
        Task.detached(priority: .userInitiated) {
            let available = FoundationModelService.isDefaultModelAvailable()
            await MainActor.run {
                let appConfig = AppConfiguration.shared
                // Clear a persisted-but-unrunnable "foundation" core model
                // here, with the availability probed off-main, instead of in
                // `loadFromDisk` — that runs inside the lazy `shared`
                // initializer on the main thread, where the FoundationModels
                // XPC probe caused multi-second app hangs.
                if clearingUnavailableCoreModel {
                    let cleaned = AppConfiguration.clearUnavailableFoundationCoreModel(
                        appConfig.chatConfig,
                        isAvailable: available
                    )
                    if cleaned != appConfig.chatConfig {
                        appConfig.updateChatConfig(cleaned)
                    }
                }
                // Only publish a change; the activation observer fires on
                // every app switch and must not re-render subscribers for
                // an unchanged value.
                guard appConfig.foundationModelAvailable != available else { return }
                appConfig.foundationModelAvailable = available
                NotificationCenter.default.post(name: .foundationModelAvailabilityChanged, object: nil)
            }
        }
    }

    // MARK: - Constants

    /// JSON keys for the legacy core-model fields that used to live in
    /// memory.json before the schema move to ChatConfiguration.
    /// Centralised here so the migration / scrub helpers and their
    /// tests reference exactly the same strings.
    private enum LegacyKey {
        static let provider = "coreModelProvider"
        static let name = "coreModelName"
    }

    /// An explicit chat-model fallback must survive the legacy migration.
    /// Delegate all fields to the normal encoder, adding only the otherwise
    /// omitted nil choice so it differs from an old, never-configured file.
    private struct PersistedChatConfiguration: Encodable {
        let config: ChatConfiguration

        private enum CodingKeys: String, CodingKey {
            case coreModelName
        }

        func encode(to encoder: Encoder) throws {
            try config.encode(to: encoder)
            if config.coreModelName == nil {
                var values = encoder.container(keyedBy: CodingKeys.self)
                try values.encodeNil(forKey: .coreModelName)
            }
        }
    }

    // MARK: - Load / save

    private static func loadFromDisk() -> ChatConfiguration {
        let url = configFileURL()
        // CRITICAL: see RemoteProviderConfigurationStore.load — never
        // auto-save an empty default on missing-file. The 2026-04
        // storage-migration recovery race showed this pattern can
        // permanently destroy user data.
        guard FileManager.default.fileExists(atPath: url.path),
            let data = try? Data(contentsOf: url)
        else {
            return ChatConfiguration.default
        }

        let config: ChatConfiguration
        do {
            config = try JSONDecoder().decode(ChatConfiguration.self, from: data)
        } catch {
            print("[Osaurus] Failed to load ChatConfiguration: \(error)")
            return ChatConfiguration.default
        }

        let migrated = applyChatConfigMigrations(initial: config, rawData: data)

        // Independently of the chat-side migration, scrub any legacy
        // core-model keys still sitting in memory.json. Idempotent;
        // see `stripLegacyCoreModelKeysFromMemoryConfig` for the
        // footgun rationale.
        stripLegacyCoreModelKeysFromMemoryConfig()

        return migrated
    }

    /// Run every chat-side migration in order and persist the result.
    /// Pulled out of `loadFromDisk` so the load path reads as
    /// `decode → migrate → return` instead of mixing five concerns.
    private static func applyChatConfigMigrations(
        initial: ChatConfiguration,
        rawData: Data
    ) -> ChatConfiguration {
        var config = initial

        // NOTE: the unavailable-Foundation cleanup (#823) is NOT run here.
        // It needs `FoundationModelService.isDefaultModelAvailable()`, an
        // XPC probe that can block for seconds, and this path runs on the
        // main thread inside the lazy `AppConfiguration.shared` initializer.
        // `refreshFoundationModelAvailable(clearingUnavailableCoreModel:)`
        // applies it once the off-main probe completes after a load.
        if chatJsonNeedsLegacyMigration(rawData) {
            config = migrateCoreModelFromMemoryConfig(into: config)
            config = backfillFoundationCoreModelIfMissing(config)
        }

        config = clearLegacyDefaultChatMaxTokens(config)

        if config != initial {
            saveToDisk(config)
        }
        return config
    }

    /// Older defaults persisted `maxTokens=16384`, which makes ordinary chat
    /// requests look client-explicit and prevents local model generation_config
    /// from supplying its own max_new_tokens. Treat that historical default as
    /// automatic; users can still set another explicit cap.
    static func clearLegacyDefaultChatMaxTokens(_ config: ChatConfiguration) -> ChatConfiguration {
        guard config.maxTokens == 16_384 else { return config }
        var updated = config
        updated.maxTokens = nil
        return updated
    }

    /// Clear a persisted `coreModelName == "foundation"` when this Mac
    /// can't actually run the Foundation Model (older macOS, Intel,
    /// Apple Intelligence not enabled). Pairs with the gated
    /// `ChatConfiguration.defaultCoreModelNameIfAvailable` so the
    /// chat-model fallback in `CoreModelService.generate` takes over
    /// instead of preflight silently failing — see GitHub issue #823.
    /// Idempotent: only touches `coreModelName` when it holds the
    /// literal default name AND Foundation isn't usable.
    /// `isAvailable` must come from a probe made off the main thread (see
    /// `refreshFoundationModelAvailable`); this function never probes.
    static func clearUnavailableFoundationCoreModel(
        _ config: ChatConfiguration,
        isAvailable: Bool
    ) -> ChatConfiguration {
        let trimmed = config.coreModelName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard trimmed.caseInsensitiveCompare(ChatConfiguration.defaultCoreModelName) == .orderedSame,
            !isAvailable
        else {
            return config
        }
        var updated = config
        updated.coreModelName = nil
        updated.coreModelProvider = nil
        print(
            "[Osaurus] Cleared persisted core model 'foundation' "
                + "(Foundation Models unavailable on this Mac); "
                + "preflight will fall back to the active chat model"
        )
        return updated
    }

    /// Trigger condition for the legacy `memory.json` → `chat.json`
    /// migration.
    ///
    /// MUST be "name missing", NOT "either key missing". Local models
    /// (Foundation, MLX) have no provider, so `coreModelProvider` is
    /// correctly nil and gets omitted from JSON encoding. The earlier
    /// "either missing" condition fired on every launch for
    /// local-model users, re-pulled the legacy
    /// `anthropic/claude-haiku-4-5` tuple from memory.json, and
    /// silently overwrote the user's saved Foundation choice
    /// (2026-04 user report → `migrateCoreModelFromMemoryConfig`).
    private static func chatJsonNeedsLegacyMigration(_ data: Data) -> Bool {
        guard let json = loadJSONObject(from: data) else { return false }
        // A saved null means the user chose "Use chat model". Missing keys
        // still allow migration from the older memory.json configuration.
        if json[LegacyKey.name] is NSNull { return false }
        return (json[LegacyKey.name] as? String)?.isEmpty != false
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
            let data = try encoder.encode(PersistedChatConfiguration(config: config))
            // Persist off the main thread; the `@Published chatConfig` cache is
            // already updated, so in-process reads see the new value at once.
            // Tests run against an override root and write synchronously.
            ConfigDiskWriter.write(
                data,
                to: url,
                synchronous: OsaurusPaths.overrideRoot != nil,
                onError: { print("[Osaurus] Failed to save ChatConfiguration: \($0)") }
            )
        } catch {
            print("[Osaurus] Failed to save ChatConfiguration: \(error)")
        }
    }

    private static func configFileURL() -> URL {
        OsaurusPaths.resolvePath(new: OsaurusPaths.chatConfigFile(), legacy: "ChatConfiguration.json")
    }

    // MARK: - Migration helpers
    //
    // These three are `internal` (not `private`) so the migration
    // tests in `Tests/Configuration` can drive them without going
    // through the `@MainActor` singleton's init lifecycle (which
    // makes test ordering matter).

    /// Backfill the new default `"foundation"` core model when the
    /// chat config still has no name. Only fires for legacy installs
    /// that were created before `ChatConfiguration.default.coreModelName`
    /// gained a value — without this they'd run with
    /// `coreModelIdentifier == nil`, which silently disables memory
    /// consolidation, preflight tool selection, and transcription
    /// cleanup. On pre-macOS-26 systems Foundation isn't available;
    /// the router throws a clear `modelUnavailable` instead of
    /// hanging, so the UX is "clear nudge" rather than "silent break".
    static func backfillFoundationCoreModelIfMissing(
        _ config: ChatConfiguration
    ) -> ChatConfiguration {
        let name = config.coreModelName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard name.isEmpty else { return config }
        var updated = config
        updated.coreModelProvider = nil
        updated.coreModelName = ChatConfiguration.defaultCoreModelName
        print(
            "[Osaurus] Backfilled core model to "
                + "'\(ChatConfiguration.defaultCoreModelName)' (legacy install)"
        )
        return updated
    }

    /// Read the legacy `coreModelProvider` / `coreModelName` fields
    /// from memory.json and copy them into `config` — only when the
    /// chat-side name is empty. Never overwrites an existing
    /// chat-side value.
    ///
    /// "Fill, don't overwrite" is the second half of the 2026-04
    /// fix: even with the corrected trigger condition, a half-set
    /// chat config (name present, provider missing) must not have
    /// its name blown away by stale legacy data.
    static func migrateCoreModelFromMemoryConfig(into config: ChatConfiguration) -> ChatConfiguration {
        guard let json = loadJSONObject(from: OsaurusPaths.memoryConfigFile()) else { return config }

        let chatNameEmpty = (config.coreModelName?.isEmpty ?? true)
        guard chatNameEmpty,
            let legacyName = json[LegacyKey.name] as? String,
            !legacyName.isEmpty
        else { return config }

        var migrated = config
        migrated.coreModelName = legacyName
        // Only adopt the legacy provider when we just adopted the
        // legacy name — otherwise we'd attach e.g. "anthropic" to a
        // user-saved local-model name.
        if let provider = json[LegacyKey.provider] as? String, !provider.isEmpty {
            migrated.coreModelProvider = provider
        }
        print(
            "[Osaurus] Migrated core model from memory.json: "
                + "\(migrated.coreModelIdentifier ?? "none")"
        )
        return migrated
    }

    /// Remove the legacy `coreModelProvider` / `coreModelName` keys
    /// from `~/.osaurus/config/memory.json`. They were moved to
    /// `ChatConfiguration` long ago but lingered in the file —
    /// historically harmless, but the active footgun behind the
    /// 2026-04 outage. Idempotent: no-op when the file doesn't
    /// exist or doesn't contain the keys.
    static func stripLegacyCoreModelKeysFromMemoryConfig() {
        let memoryURL = OsaurusPaths.memoryConfigFile()
        guard var json = loadJSONObject(from: memoryURL) else { return }

        // CRITICAL: `||` short-circuits. Evaluate both `removeValue`
        // calls into separate `let`s before OR-ing the booleans —
        // otherwise the second key is never removed when the first
        // one was present, leaving `coreModelName: "claude-haiku-4-5"`
        // sitting in memory.json and re-tripping the migration on
        // every launch.
        let removedProvider = json.removeValue(forKey: LegacyKey.provider) != nil
        let removedName = json.removeValue(forKey: LegacyKey.name) != nil
        guard removedProvider || removedName else { return }

        do {
            let cleaned = try JSONSerialization.data(
                withJSONObject: json,
                options: [.prettyPrinted, .sortedKeys]
            )
            try cleaned.write(to: memoryURL, options: .atomic)
            print("[Osaurus] Removed legacy core-model keys from memory.json")
        } catch {
            print("[Osaurus] Failed to scrub memory.json legacy keys: \(error)")
        }
    }

    // MARK: - Internal utilities

    /// Decode a top-level JSON object dictionary from `url`, or `nil`
    /// when the file is absent / unreadable / not a JSON object. The
    /// migration helpers all need this same defensive read pattern.
    private static func loadJSONObject(from url: URL) -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: url.path),
            let data = try? Data(contentsOf: url)
        else { return nil }
        return loadJSONObject(from: data)
    }

    private static func loadJSONObject(from data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
