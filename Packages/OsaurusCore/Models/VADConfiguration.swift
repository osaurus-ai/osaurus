//
//  VADConfiguration.swift
//  osaurus
//
//  Configuration model for Voice Activity Detection (VAD) mode.
//  VAD mode enables wake-word agent activation - users can speak
//  a agent's name to automatically open chat with that agent.
//

import Foundation

/// Configuration settings for VAD (Voice Activity Detection) mode
/// Note: Sensitivity is now shared via SpeechConfiguration in the Audio Settings tab.
public struct VADConfiguration: Codable, Equatable, Sendable {
    /// Whether VAD mode is enabled globally
    public var vadModeEnabled: Bool

    /// IDs of agents that respond to wake-word activation
    public var enabledAgentIds: [UUID]

    /// Whether to automatically start voice input after agent activation
    public var autoStartVoiceInput: Bool

    /// Custom wake phrase (e.g., "Hey Osaurus"). Empty = use agent names only
    public var customWakePhrase: String

    private enum CodingKeys: String, CodingKey {
        case vadModeEnabled
        case enabledAgentIds
        case enabledPersonaIds  // legacy key for migration
        case wakeWordSensitivity  // Kept for backward compatibility (ignored on decode)
        case autoStartVoiceInput
        case customWakePhrase
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = VADConfiguration.default
        self.vadModeEnabled =
            try container.decodeIfPresent(Bool.self, forKey: .vadModeEnabled)
            ?? defaults.vadModeEnabled
        self.enabledAgentIds =
            try container.decodeIfPresent([UUID].self, forKey: .enabledAgentIds)
            ?? container.decodeIfPresent([UUID].self, forKey: .enabledPersonaIds)
            ?? defaults.enabledAgentIds
        // wakeWordSensitivity is ignored - now uses shared sensitivity from SpeechConfiguration
        self.autoStartVoiceInput =
            try container.decodeIfPresent(Bool.self, forKey: .autoStartVoiceInput)
            ?? defaults.autoStartVoiceInput
        self.customWakePhrase =
            try container.decodeIfPresent(String.self, forKey: .customWakePhrase)
            ?? defaults.customWakePhrase
    }

    public init(
        vadModeEnabled: Bool = false,
        enabledAgentIds: [UUID] = [],
        autoStartVoiceInput: Bool = true,
        customWakePhrase: String = ""
    ) {
        self.vadModeEnabled = vadModeEnabled
        self.enabledAgentIds = enabledAgentIds
        self.autoStartVoiceInput = autoStartVoiceInput
        self.customWakePhrase = customWakePhrase
    }

    /// Default configuration
    public static var `default`: VADConfiguration {
        VADConfiguration(
            vadModeEnabled: false,
            enabledAgentIds: [],
            autoStartVoiceInput: true,
            customWakePhrase: ""
        )
    }

    // Custom encoding to exclude the deprecated wakeWordSensitivity
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(vadModeEnabled, forKey: .vadModeEnabled)
        try container.encode(enabledAgentIds, forKey: .enabledAgentIds)
        try container.encode(autoStartVoiceInput, forKey: .autoStartVoiceInput)
        try container.encode(customWakePhrase, forKey: .customWakePhrase)
    }
}

/// Handles persistence of `VADConfiguration`
@MainActor
public enum VADConfigurationStore {
    public static func load() -> VADConfiguration {
        let url = configurationFileURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            return VADConfiguration.default
        }
        do {
            return try JSONDecoder().decode(VADConfiguration.self, from: Data(contentsOf: url))
        } catch {
            print("[Osaurus] Failed to load VADConfiguration: \(error)")
            return VADConfiguration.default
        }
    }

    public static func save(_ configuration: VADConfiguration) {
        let url = configurationFileURL()
        OsaurusPaths.ensureExistsSilent(url.deletingLastPathComponent())
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(configuration).write(to: url, options: [.atomic])
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .voiceConfigurationChanged, object: nil)
            }
        } catch {
            print("[Osaurus] Failed to save VADConfiguration: \(error)")
        }
    }

    private static func configurationFileURL() -> URL {
        OsaurusPaths.resolvePath(new: OsaurusPaths.vadConfigFile(), legacy: "VADConfiguration.json")
    }
}
