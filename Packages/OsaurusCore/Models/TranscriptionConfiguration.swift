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

/// Handles persistence of `TranscriptionConfiguration` to Application Support
@MainActor
public enum TranscriptionConfigurationStore {
    /// Optional directory override for tests
    static var overrideDirectory: URL?

    public static func load() -> TranscriptionConfiguration {
        let url = configurationFileURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            return TranscriptionConfiguration.default
        }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            return try decoder.decode(TranscriptionConfiguration.self, from: data)
        } catch {
            print("[Osaurus] Failed to load TranscriptionConfiguration: \(error)")
            return TranscriptionConfiguration.default
        }
    }

    public static func save(_ configuration: TranscriptionConfiguration) {
        let url = configurationFileURL()
        do {
            try ensureDirectoryExists(url.deletingLastPathComponent())
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(configuration)
            try data.write(to: url, options: [.atomic])

            // Notify observers of configuration change
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .transcriptionConfigurationChanged, object: nil)
            }
        } catch {
            print("[Osaurus] Failed to save TranscriptionConfiguration: \(error)")
        }
    }

    // MARK: - Private

    private static func configurationFileURL() -> URL {
        if let overrideDirectory {
            return overrideDirectory.appendingPathComponent("TranscriptionConfiguration.json")
        }
        let fm = FileManager.default
        let supportDir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let bundleId = Bundle.main.bundleIdentifier ?? "osaurus"
        return supportDir.appendingPathComponent(bundleId, isDirectory: true)
            .appendingPathComponent("TranscriptionConfiguration.json")
    }

    private static func ensureDirectoryExists(_ url: URL) throws {
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}

// MARK: - Notification Name Extension

public extension Notification.Name {
    /// Posted when transcription configuration changes
    static let transcriptionConfigurationChanged = Notification.Name("transcriptionConfigurationChanged")
}
