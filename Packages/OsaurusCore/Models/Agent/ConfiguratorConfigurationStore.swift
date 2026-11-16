//
//  ConfiguratorConfigurationStore.swift
//  osaurus
//
//  The Configurator's user settings at `~/.osaurus/config/configurator.json`:
//  extra instructions, model, and temperature (Settings → Configurator). Its
//  name, persona, and tool surface are fixed; the extra instructions are
//  appended after the persona.
//

import Foundation

public struct ConfiguratorConfiguration: Codable, Equatable, Sendable {
    /// Model id. Nil uses the Orchestrator's model.
    public var model: String?

    /// Sampling temperature. Nil uses the model's own default.
    public var temperature: Float?

    /// Extra instructions appended after the built-in Configurator persona.
    public var systemPrompt: String

    public init(model: String? = nil, temperature: Float? = nil, systemPrompt: String = "") {
        self.model = model
        self.temperature = temperature
        self.systemPrompt = systemPrompt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        temperature = try c.decodeIfPresent(Float.self, forKey: .temperature)
        systemPrompt = try c.decodeIfPresent(String.self, forKey: .systemPrompt) ?? ""
    }

    /// The trimmed model id, or nil when the Orchestrator's model applies.
    public var resolvedModel: String? {
        guard let model = model?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty
        else { return nil }
        return model
    }
}

@MainActor
public enum ConfiguratorConfigurationStore {
    /// Test seam, like `DefaultAgentConfigurationStore.overrideDirectory`.
    public static var overrideDirectory: URL?

    private static var cached: ConfiguratorConfiguration?
    private static let reloadGuard = ConfigFileReloadGuard()

    public static func load() -> ConfiguratorConfiguration {
        if let cached { return cached }
        let loaded = loadFromDisk()
        reloadGuard.noteLoaded(from: fileURL())
        cached = loaded
        return loaded
    }

    public static func save(_ configuration: ConfiguratorConfiguration) {
        cached = configuration
        do {
            let url = fileURL()
            try OsaurusPaths.ensureExists(url.deletingLastPathComponent())
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(configuration)
            reloadGuard.noteSaved(data)
            try data.write(to: url, options: .atomic)
            reloadGuard.noteLoaded(from: url)
        } catch {
            print("[Osaurus] Failed to save configurator.json: \(error)")
        }
        NotificationCenter.default.post(name: .appConfigurationChanged, object: nil)
    }

    /// Load-modify-write, so each settings control only touches its field.
    public static func update(_ change: (inout ConfiguratorConfiguration) -> Void) {
        var configuration = load()
        change(&configuration)
        save(configuration)
    }

    /// Re-read `configurator.json` when it changed on disk without going
    /// through `save`. Returns true when the cache changed.
    @discardableResult
    public static func reloadIfChangedOnDisk() -> Bool {
        guard cached != nil else { return false }
        guard let data = reloadGuard.externalChange(at: fileURL()),
            let decoded = try? JSONDecoder().decode(ConfiguratorConfiguration.self, from: data),
            decoded != cached
        else { return false }
        cached = decoded
        NotificationCenter.default.post(name: .appConfigurationChanged, object: nil)
        return true
    }

    /// Changes on every save or detected reload.
    public static var generation: Int { reloadGuard.generation }

    public static func resetCacheForTests() {
        cached = nil
        reloadGuard.reset()
    }

    private static func fileURL() -> URL {
        (overrideDirectory ?? OsaurusPaths.config()).appendingPathComponent("configurator.json")
    }

    private static func loadFromDisk() -> ConfiguratorConfiguration {
        guard let data = try? Data(contentsOf: fileURL()),
            let decoded = try? JSONDecoder().decode(ConfiguratorConfiguration.self, from: data)
        else { return ConfiguratorConfiguration() }
        return decoded
    }
}
