//
//  SpeechConfiguration.swift
//  osaurus
//
//  Configuration model for FluidAudio voice transcription settings.
//

import Foundation

/// ASR model version for FluidAudio Parakeet models
public enum SpeechModelVersion: String, Codable, Equatable, CaseIterable, Sendable {
    /// Parakeet TDT v2 (0.6B) - English-only, highest recall
    case v2
    /// Parakeet TDT v3 (0.6B) - Multilingual, 25 European languages
    case v3

    public var displayName: String {
        switch self {
        case .v2: return "Parakeet v2 (English)"
        case .v3: return "Parakeet v3 (Multilingual)"
        }
    }

    public var description: String {
        switch self {
        case .v2: return "English-only model with highest recall"
        case .v3: return "Multilingual model supporting 25 European languages"
        }
    }
}

/// Configuration settings for FluidAudio voice transcription
public struct SpeechConfiguration: Codable, Equatable, Sendable {
    /// ASR model version (.v2 English-only or .v3 multilingual)
    public var modelVersion: SpeechModelVersion

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

    /// Seconds of silence before closing voice input (0 = disabled, 10-120 seconds)
    public var silenceTimeoutSeconds: Double

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = SpeechConfiguration.default
        self.modelVersion =
            try container.decodeIfPresent(SpeechModelVersion.self, forKey: .modelVersion)
            ?? defaults.modelVersion
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
        self.silenceTimeoutSeconds =
            try container.decodeIfPresent(Double.self, forKey: .silenceTimeoutSeconds)
            ?? defaults.silenceTimeoutSeconds
    }

    public init(
        modelVersion: SpeechModelVersion = .v3,
        selectedInputDeviceId: String? = nil,
        selectedInputSource: AudioInputSource = .microphone,
        sensitivity: VoiceSensitivity = .medium,
        voiceInputEnabled: Bool = true,
        pauseDuration: Double = 1.5,
        confirmationDelay: Double = 2.0,
        silenceTimeoutSeconds: Double = 30.0
    ) {
        self.modelVersion = modelVersion
        self.selectedInputDeviceId = selectedInputDeviceId
        self.selectedInputSource = selectedInputSource
        self.sensitivity = sensitivity
        self.voiceInputEnabled = voiceInputEnabled
        self.pauseDuration = pauseDuration
        self.confirmationDelay = confirmationDelay
        self.silenceTimeoutSeconds = silenceTimeoutSeconds
    }

    public static var `default`: SpeechConfiguration {
        SpeechConfiguration(
            modelVersion: .v3,
            selectedInputDeviceId: nil,
            selectedInputSource: .microphone,
            sensitivity: .medium,
            voiceInputEnabled: true,
            pauseDuration: 1.5,
            confirmationDelay: 2.0,
            silenceTimeoutSeconds: 30.0
        )
    }
}

/// Audio input source type
public enum AudioInputSource: String, Codable, Equatable, CaseIterable, Sendable {
    case microphone
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
    case low
    case medium
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

    /// VAD threshold for FluidAudio's Silero VAD (higher = less sensitive)
    public var vadThreshold: Float {
        switch self {
        case .low: return 0.85
        case .medium: return 0.75
        case .high: return 0.55
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

/// Handles persistence of `SpeechConfiguration` with caching
@MainActor
public enum SpeechConfigurationStore {
    private static var cachedConfig: SpeechConfiguration?

    public static func load() -> SpeechConfiguration {
        if let cached = cachedConfig { return cached }
        let config = loadFromDisk()
        cachedConfig = config
        return config
    }

    public static func save(_ configuration: SpeechConfiguration) {
        cachedConfig = configuration
        saveToDisk(configuration)
    }

    private static func loadFromDisk() -> SpeechConfiguration {
        let url = configurationFileURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            return SpeechConfiguration.default
        }
        do {
            return try JSONDecoder().decode(SpeechConfiguration.self, from: Data(contentsOf: url))
        } catch {
            print("[Osaurus] Failed to load SpeechConfiguration: \(error)")
            return SpeechConfiguration.default
        }
    }

    private static func saveToDisk(_ configuration: SpeechConfiguration) {
        let url = configurationFileURL()
        OsaurusPaths.ensureExistsSilent(url.deletingLastPathComponent())
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(configuration).write(to: url, options: [.atomic])
        } catch {
            print("[Osaurus] Failed to save SpeechConfiguration: \(error)")
        }
    }

    private static func configurationFileURL() -> URL {
        OsaurusPaths.speechConfigFile()
    }
}
