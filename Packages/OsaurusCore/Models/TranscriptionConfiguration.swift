//
//  TranscriptionConfiguration.swift
//  osaurus
//
//  Configuration model for Transcription Mode.
//  Transcription mode enables hotkey-triggered voice-to-text input
//  directly into any focused text field using accessibility APIs.
//

import Foundation

/// Configuration settings for Transcription Mode
public struct TranscriptionConfiguration: Codable, Equatable, Sendable {
    /// Whether transcription mode is enabled globally
    public var transcriptionModeEnabled: Bool

    /// Global hotkey to activate transcription mode
    public var hotkey: Hotkey?

    private enum CodingKeys: String, CodingKey {
        case transcriptionModeEnabled
        case hotkey
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = TranscriptionConfiguration.default
        self.transcriptionModeEnabled =
            try container.decodeIfPresent(Bool.self, forKey: .transcriptionModeEnabled)
            ?? defaults.transcriptionModeEnabled
        self.hotkey =
            try container.decodeIfPresent(Hotkey.self, forKey: .hotkey)
    }

    public init(
        transcriptionModeEnabled: Bool = false,
        hotkey: Hotkey? = nil
    ) {
        self.transcriptionModeEnabled = transcriptionModeEnabled
        self.hotkey = hotkey
    }

    /// Default configuration
    public static var `default`: TranscriptionConfiguration {
        TranscriptionConfiguration(
            transcriptionModeEnabled: false,
            hotkey: nil
        )
    }
}

/// Handles persistence of `TranscriptionConfiguration`
@MainActor
public enum TranscriptionConfigurationStore {
    public static func load() -> TranscriptionConfiguration {
        let url = configurationFileURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            return TranscriptionConfiguration.default
        }
        do {
            return try JSONDecoder().decode(TranscriptionConfiguration.self, from: Data(contentsOf: url))
        } catch {
            print("[Osaurus] Failed to load TranscriptionConfiguration: \(error)")
            return TranscriptionConfiguration.default
        }
    }

    public static func save(_ configuration: TranscriptionConfiguration) {
        let url = configurationFileURL()
        OsaurusPaths.ensureExistsSilent(url.deletingLastPathComponent())
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(configuration).write(to: url, options: [.atomic])
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .transcriptionConfigurationChanged, object: nil)
            }
        } catch {
            print("[Osaurus] Failed to save TranscriptionConfiguration: \(error)")
        }
    }

    private static func configurationFileURL() -> URL {
        OsaurusPaths.resolvePath(new: OsaurusPaths.transcriptionConfigFile(), legacy: "TranscriptionConfiguration.json")
    }
}

// MARK: - Notification Name Extension

public extension Notification.Name {
    /// Posted when transcription configuration changes
    static let transcriptionConfigurationChanged = Notification.Name("transcriptionConfigurationChanged")
}
