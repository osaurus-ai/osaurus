//
//  AppConfiguration.swift
//  osaurus
//
//  Central cache for configuration loaded from disk. Loads once at startup,
//  refreshes only when config changes. Eliminates repeated file I/O in views.
//

import Foundation

extension Notification.Name {
    static let appConfigurationChanged = Notification.Name("appConfigurationChanged")
}

/// Central cache for configuration - loads from disk once, provides cached access
@MainActor
public final class AppConfiguration: ObservableObject {
    public static let shared = AppConfiguration()

    @Published public private(set) var chatConfig: ChatConfiguration
    public private(set) var foundationModelAvailable: Bool

    private init() {
        self.chatConfig = Self.loadFromDisk()
        self.foundationModelAvailable = FoundationModelService.isDefaultModelAvailable()
    }

    // MARK: - Public API

    public func reloadChatConfig() {
        chatConfig = Self.loadFromDisk()
        NotificationCenter.default.post(name: .appConfigurationChanged, object: nil)
    }

    public func updateChatConfig(_ config: ChatConfiguration) {
        chatConfig = config
        Self.saveToDisk(config)
        NotificationCenter.default.post(name: .appConfigurationChanged, object: nil)
    }

    public func refreshFoundationModelAvailable() {
        foundationModelAvailable = FoundationModelService.isDefaultModelAvailable()
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

        // Run the unavailable-Foundation cleanup unconditionally — it
        // fires on every cold start for users on macOS < 26 who still
        // have the historical `"foundation"` default persisted (root
        // cause for several #823 reports). Idempotent.
        config = clearUnavailableFoundationCoreModel(config)

        // Order matters: cleanup above can leave `coreModelName` nil,
        // which then re-enters the legacy memory.json migration so a
        // legacy install gets a chance to adopt an explicit chat-side
        // name before backfill takes over.
        if chatJsonNeedsLegacyMigration(rawData) {
            config = migrateCoreModelFromMemoryConfig(into: config)
            config = backfillFoundationCoreModelIfMissing(config)
        }

        if config != initial {
            saveToDisk(config)
        }
        return config
    }

    /// Clear a persisted `coreModelName == "foundation"` when this Mac
    /// can't actually run the Foundation Model (older macOS, Intel,
    /// Apple Intelligence not enabled). Pairs with the gated
    /// `ChatConfiguration.defaultCoreModelNameIfAvailable` so the
    /// chat-model fallback in `CoreModelService.generate` takes over
    /// instead of preflight silently failing — see GitHub issue #823.
    /// Idempotent: only touches `coreModelName` when it holds the
    /// literal default name AND Foundation isn't usable.
    static func clearUnavailableFoundationCoreModel(
        _ config: ChatConfiguration
    ) -> ChatConfiguration {
        let trimmed = config.coreModelName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard trimmed.caseInsensitiveCompare(ChatConfiguration.defaultCoreModelName) == .orderedSame,
            !FoundationModelService.isDefaultModelAvailable()
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
            try encoder.encode(config).write(to: url, options: .atomic)
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
