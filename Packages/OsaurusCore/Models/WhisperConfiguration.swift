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

    /// Task type: "transcribe" or "translate"
    public var task: TranscriptionTask

    /// Selected audio input device unique ID (nil = system default)
    public var selectedInputDeviceId: String?

    private enum CodingKeys: String, CodingKey {
        case defaultModel
        case languageHint
        case enabled
        case wordTimestamps
        case task
        case selectedInputDeviceId
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = WhisperConfiguration.default
        self.defaultModel = try container.decodeIfPresent(String.self, forKey: .defaultModel)
        self.languageHint = try container.decodeIfPresent(String.self, forKey: .languageHint)
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? defaults.enabled
        self.wordTimestamps =
            try container.decodeIfPresent(Bool.self, forKey: .wordTimestamps) ?? defaults.wordTimestamps
        self.task = try container.decodeIfPresent(TranscriptionTask.self, forKey: .task) ?? defaults.task
        self.selectedInputDeviceId = try container.decodeIfPresent(String.self, forKey: .selectedInputDeviceId)
    }

    public init(
        defaultModel: String? = nil,
        languageHint: String? = nil,
        enabled: Bool = true,
        wordTimestamps: Bool = false,
        task: TranscriptionTask = .transcribe,
        selectedInputDeviceId: String? = nil
    ) {
        self.defaultModel = defaultModel
        self.languageHint = languageHint
        self.enabled = enabled
        self.wordTimestamps = wordTimestamps
        self.task = task
        self.selectedInputDeviceId = selectedInputDeviceId
    }

    /// Default configuration
    public static var `default`: WhisperConfiguration {
        WhisperConfiguration(
            defaultModel: nil,
            languageHint: nil,
            enabled: true,
            wordTimestamps: false,
            task: .transcribe,
            selectedInputDeviceId: nil
        )
    }
}

/// Transcription task type
public enum TranscriptionTask: String, Codable, CaseIterable, Sendable {
    /// Transcribe audio to text in the original language
    case transcribe
    /// Translate audio to English text
    case translate

    public var displayName: String {
        switch self {
        case .transcribe: return "Transcribe"
        case .translate: return "Translate to English"
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
