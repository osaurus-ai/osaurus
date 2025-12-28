//
//  WhisperConfiguration.swift
//  osaurus
//
//  Configuration model for WhisperKit voice transcription settings.
//

import Foundation

/// Configuration settings for WhisperKit voice transcription
public struct WhisperConfiguration: Codable, Equatable, Sendable {
    /// Default model to use for transcription (e.g., "openai_whisper-large-v3")
    public var defaultModel: String?

    /// Language hint for transcription (ISO 639-1 code, e.g., "en", "es", "ja")
    public var languageHint: String?

    /// Whether voice features are enabled
    public var enabled: Bool

    /// Whether to use word-level timestamps
    public var wordTimestamps: Bool

    /// Selected audio input device unique ID (nil = system default)
    public var selectedInputDeviceId: String?

    /// Selected audio input source type (microphone or system audio)
    public var selectedInputSource: AudioInputSource

    /// Voice activity detection sensitivity level
    public var sensitivity: VoiceSensitivity

    // MARK: - Voice Input Settings (for ChatView)

    /// Whether voice input is enabled in ChatView
    public var voiceInputEnabled: Bool

    /// Seconds of silence before triggering auto-send (0 = disabled, manual send only)
    public var pauseDuration: Double

    /// Seconds to show confirmation before auto-sending (1-5 seconds)
    public var confirmationDelay: Double

    private enum CodingKeys: String, CodingKey {
        case defaultModel
        case languageHint
        case enabled
        case wordTimestamps
        case selectedInputDeviceId
        case selectedInputSource
        case sensitivity
        case voiceInputEnabled
        case pauseDuration
        case confirmationDelay
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = WhisperConfiguration.default
        self.defaultModel = try container.decodeIfPresent(String.self, forKey: .defaultModel)
        self.languageHint = try container.decodeIfPresent(String.self, forKey: .languageHint)
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? defaults.enabled
        self.wordTimestamps =
            try container.decodeIfPresent(Bool.self, forKey: .wordTimestamps) ?? defaults.wordTimestamps
        self.selectedInputDeviceId = try container.decodeIfPresent(String.self, forKey: .selectedInputDeviceId)
        self.selectedInputSource =
            try container.decodeIfPresent(AudioInputSource.self, forKey: .selectedInputSource)
            ?? defaults.selectedInputSource
        self.sensitivity =
            try container.decodeIfPresent(VoiceSensitivity.self, forKey: .sensitivity)
            ?? defaults.sensitivity
        self.voiceInputEnabled =
            try container.decodeIfPresent(Bool.self, forKey: .voiceInputEnabled)
            ?? defaults.voiceInputEnabled
        self.pauseDuration =
            try container.decodeIfPresent(Double.self, forKey: .pauseDuration)
            ?? defaults.pauseDuration
        self.confirmationDelay =
            try container.decodeIfPresent(Double.self, forKey: .confirmationDelay)
            ?? defaults.confirmationDelay
    }

    public init(
        defaultModel: String? = nil,
        languageHint: String? = nil,
        enabled: Bool = true,
        wordTimestamps: Bool = false,
        selectedInputDeviceId: String? = nil,
        selectedInputSource: AudioInputSource = .microphone,
        sensitivity: VoiceSensitivity = .medium,
        voiceInputEnabled: Bool = true,
        pauseDuration: Double = 1.5,
        confirmationDelay: Double = 2.0
    ) {
        self.defaultModel = defaultModel
        self.languageHint = languageHint
        self.enabled = enabled
        self.wordTimestamps = wordTimestamps
        self.selectedInputDeviceId = selectedInputDeviceId
        self.selectedInputSource = selectedInputSource
        self.sensitivity = sensitivity
        self.voiceInputEnabled = voiceInputEnabled
        self.pauseDuration = pauseDuration
        self.confirmationDelay = confirmationDelay
    }

    /// Default configuration
    public static var `default`: WhisperConfiguration {
        WhisperConfiguration(
            defaultModel: nil,
            languageHint: nil,
            enabled: true,
            wordTimestamps: false,
            selectedInputDeviceId: nil,
            selectedInputSource: .microphone,
            sensitivity: .medium,
            voiceInputEnabled: true,
            pauseDuration: 1.5,
            confirmationDelay: 2.0
        )
    }
}

/// Audio input source type
public enum AudioInputSource: String, Codable, Equatable, CaseIterable, Sendable {
    /// Microphone input (built-in or external)
    case microphone
    /// System audio capture (audio from apps, browser, etc.)
    case systemAudio

    public var displayName: String {
        switch self {
        case .microphone: return "Microphone"
        case .systemAudio: return "System Audio"
        }
    }

    public var iconName: String {
        switch self {
        case .microphone: return "mic.fill"
        case .systemAudio: return "speaker.wave.2.fill"
        }
    }
}

/// Voice activity detection sensitivity level
public enum VoiceSensitivity: String, Codable, CaseIterable, Sendable {
    /// Less sensitive - requires louder, clearer speech
    case low
    /// Balanced sensitivity (default)
    case medium
    /// More sensitive - picks up quieter speech, longer pauses
    case high

    public var displayName: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }

    public var description: String {
        switch self {
        case .low: return "Requires louder speech, faster response"
        case .medium: return "Balanced for normal conversation"
        case .high: return "Picks up quiet speech, waits longer for pauses"
        }
    }

    /// Energy threshold for voice detection (lower = more sensitive)
    public var energyThreshold: Float {
        switch self {
        case .low: return 0.08
        case .medium: return 0.05
        case .high: return 0.02
        }
    }

    /// Silence duration to consider speech ended (higher = waits longer)
    public var silenceThresholdSeconds: Double {
        switch self {
        case .low: return 0.3
        case .medium: return 0.5
        case .high: return 0.8
        }
    }
}

/// Handles persistence of `WhisperConfiguration` to Application Support
@MainActor
public enum WhisperConfigurationStore {
    /// Optional directory override for tests
    static var overrideDirectory: URL?

    public static func load() -> WhisperConfiguration {
        let url = configurationFileURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            return WhisperConfiguration.default
        }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            return try decoder.decode(WhisperConfiguration.self, from: data)
        } catch {
            print("[Osaurus] Failed to load WhisperConfiguration: \(error)")
            return WhisperConfiguration.default
        }
    }

    public static func save(_ configuration: WhisperConfiguration) {
        let url = configurationFileURL()
        do {
            try ensureDirectoryExists(url.deletingLastPathComponent())
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(configuration)
            try data.write(to: url, options: [.atomic])
        } catch {
            print("[Osaurus] Failed to save WhisperConfiguration: \(error)")
        }
    }

    // MARK: - Private

    private static func configurationFileURL() -> URL {
        if let overrideDirectory {
            return overrideDirectory.appendingPathComponent("WhisperConfiguration.json")
        }
        let fm = FileManager.default
        let supportDir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let bundleId = Bundle.main.bundleIdentifier ?? "osaurus"
        return supportDir.appendingPathComponent(bundleId, isDirectory: true)
            .appendingPathComponent("WhisperConfiguration.json")
    }

    private static func ensureDirectoryExists(_ url: URL) throws {
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}
