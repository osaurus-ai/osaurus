//
//  VADConfiguration.swift
//  osaurus
//
//  Configuration model for Voice Activity Detection (VAD) mode.
//  VAD mode enables wake-word persona activation - users can speak
//  a persona's name to automatically open chat with that persona.
//

import Foundation

/// Configuration settings for VAD (Voice Activity Detection) mode
public struct VADConfiguration: Codable, Equatable, Sendable {
    /// Whether VAD mode is enabled globally
    public var vadModeEnabled: Bool

    /// IDs of personas that respond to wake-word activation
    public var enabledPersonaIds: [UUID]

    /// Sensitivity level for wake-word detection
    public var wakeWordSensitivity: VoiceSensitivity

    /// Whether to automatically start voice input after persona activation
    public var autoStartVoiceInput: Bool

    /// Custom wake phrase (e.g., "Hey Osaurus"). Empty = use persona names only
    public var customWakePhrase: String

    private enum CodingKeys: String, CodingKey {
        case vadModeEnabled
        case enabledPersonaIds
        case wakeWordSensitivity
        case autoStartVoiceInput
        case customWakePhrase
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = VADConfiguration.default
        self.vadModeEnabled =
            try container.decodeIfPresent(Bool.self, forKey: .vadModeEnabled)
            ?? defaults.vadModeEnabled
        self.enabledPersonaIds =
            try container.decodeIfPresent([UUID].self, forKey: .enabledPersonaIds)
            ?? defaults.enabledPersonaIds
        self.wakeWordSensitivity =
            try container.decodeIfPresent(VoiceSensitivity.self, forKey: .wakeWordSensitivity)
            ?? defaults.wakeWordSensitivity
        self.autoStartVoiceInput =
            try container.decodeIfPresent(Bool.self, forKey: .autoStartVoiceInput)
            ?? defaults.autoStartVoiceInput
        self.customWakePhrase =
            try container.decodeIfPresent(String.self, forKey: .customWakePhrase)
            ?? defaults.customWakePhrase
    }

    public init(
        vadModeEnabled: Bool = false,
        enabledPersonaIds: [UUID] = [],
        wakeWordSensitivity: VoiceSensitivity = .medium,
        autoStartVoiceInput: Bool = true,
        customWakePhrase: String = ""
    ) {
        self.vadModeEnabled = vadModeEnabled
        self.enabledPersonaIds = enabledPersonaIds
        self.wakeWordSensitivity = wakeWordSensitivity
        self.autoStartVoiceInput = autoStartVoiceInput
        self.customWakePhrase = customWakePhrase
    }

    /// Default configuration
    public static var `default`: VADConfiguration {
        VADConfiguration(
            vadModeEnabled: false,
            enabledPersonaIds: [],
            wakeWordSensitivity: .medium,
            autoStartVoiceInput: true,
            customWakePhrase: ""
        )
    }

    // MARK: - Helpers

    /// Check if a specific persona is enabled for VAD
    public func isPersonaEnabled(_ personaId: UUID) -> Bool {
        enabledPersonaIds.contains(personaId)
    }

    /// Toggle a persona's VAD activation status
    public mutating func togglePersona(_ personaId: UUID) {
        if let index = enabledPersonaIds.firstIndex(of: personaId) {
            enabledPersonaIds.remove(at: index)
        } else {
            enabledPersonaIds.append(personaId)
        }
    }
}

/// Handles persistence of `VADConfiguration` to Application Support
@MainActor
public enum VADConfigurationStore {
    /// Optional directory override for tests
    static var overrideDirectory: URL?

    public static func load() -> VADConfiguration {
        let url = configurationFileURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            return VADConfiguration.default
        }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            return try decoder.decode(VADConfiguration.self, from: data)
        } catch {
            print("[Osaurus] Failed to load VADConfiguration: \(error)")
            return VADConfiguration.default
        }
    }

    public static func save(_ configuration: VADConfiguration) {
        let url = configurationFileURL()
        do {
            try ensureDirectoryExists(url.deletingLastPathComponent())
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(configuration)
            try data.write(to: url, options: [.atomic])

            // Notify observers of configuration change
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .voiceConfigurationChanged, object: nil)
            }
        } catch {
            print("[Osaurus] Failed to save VADConfiguration: \(error)")
        }
    }

    // MARK: - Private

    private static func configurationFileURL() -> URL {
        if let overrideDirectory {
            return overrideDirectory.appendingPathComponent("VADConfiguration.json")
        }
        let fm = FileManager.default
        let supportDir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let bundleId = Bundle.main.bundleIdentifier ?? "osaurus"
        return supportDir.appendingPathComponent(bundleId, isDirectory: true)
            .appendingPathComponent("VADConfiguration.json")
    }

    private static func ensureDirectoryExists(_ url: URL) throws {
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}
