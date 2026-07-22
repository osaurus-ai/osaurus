//
//  TTSConfiguration.swift
//  osaurus
//
//  Configuration model for FluidAudio PocketTTS text-to-speech.
//

import Foundation

/// Which engine synthesizes speech.
public enum TTSProvider: String, Codable, Equatable, Sendable, CaseIterable {
    /// Built-in FluidAudio PocketTTS running on-device.
    case pocketTTS
    /// Any server exposing the OpenAI `/v1/audio/speech` API
    /// (openai-edge-tts, Kokoro-FastAPI, LocalAI, OpenAI itself, …).
    case openAICompatible
}

/// Configuration settings for text-to-speech.
public struct TTSConfiguration: Codable, Equatable, Sendable {
    /// Master enable toggle. When false, speaker buttons are hidden from message cells.
    public var enabled: Bool

    /// Active synthesis engine.
    public var provider: TTSProvider

    /// PocketTTS voice identifier.
    public var voice: String

    /// Generation temperature (0.1 – 1.2). Higher = more variation. PocketTTS only.
    public var temperature: Double

    /// Base URL of the OpenAI-compatible server, without the `/v1/audio/speech`
    /// path (e.g. `http://localhost:5050`).
    public var remoteEndpoint: String

    /// Model name sent to the remote server.
    public var remoteModel: String

    /// Voice identifier sent to the remote server. Free-form: each server has
    /// its own catalog (OpenAI names, edge-tts names, …).
    public var remoteVoice: String

    /// Playback speed multiplier sent to the remote server (0.25 – 4.0).
    public var remoteSpeed: Double

    public static let defaultVoice = "alba"
    public static let defaultRemoteEndpoint = "http://localhost:5050"
    public static let defaultRemoteModel = "tts-1"
    public static let defaultRemoteVoice = "alloy"

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = TTSConfiguration.default
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? defaults.enabled
        self.provider =
            try container.decodeIfPresent(TTSProvider.self, forKey: .provider) ?? defaults.provider
        self.voice = try container.decodeIfPresent(String.self, forKey: .voice) ?? defaults.voice
        self.temperature =
            try container.decodeIfPresent(Double.self, forKey: .temperature) ?? defaults.temperature
        self.remoteEndpoint =
            try container.decodeIfPresent(String.self, forKey: .remoteEndpoint)
            ?? defaults.remoteEndpoint
        self.remoteModel =
            try container.decodeIfPresent(String.self, forKey: .remoteModel) ?? defaults.remoteModel
        self.remoteVoice =
            try container.decodeIfPresent(String.self, forKey: .remoteVoice) ?? defaults.remoteVoice
        self.remoteSpeed =
            try container.decodeIfPresent(Double.self, forKey: .remoteSpeed) ?? defaults.remoteSpeed
    }

    public init(
        enabled: Bool = true,
        provider: TTSProvider = .pocketTTS,
        voice: String = TTSConfiguration.defaultVoice,
        temperature: Double = 0.7,
        remoteEndpoint: String = TTSConfiguration.defaultRemoteEndpoint,
        remoteModel: String = TTSConfiguration.defaultRemoteModel,
        remoteVoice: String = TTSConfiguration.defaultRemoteVoice,
        remoteSpeed: Double = 1.0
    ) {
        self.enabled = enabled
        self.provider = provider
        self.voice = voice
        self.temperature = temperature
        self.remoteEndpoint = remoteEndpoint
        self.remoteModel = remoteModel
        self.remoteVoice = remoteVoice
        self.remoteSpeed = remoteSpeed
    }

    public static var `default`: TTSConfiguration { TTSConfiguration() }
}

/// API key for the OpenAI-compatible TTS server. Kept in the keychain, never
/// in the JSON config file. Empty/whitespace writes clear the stored key.
///
/// Every SecItem call goes through `queue`: keychain reads and writes are
/// synchronous XPC to securityd that can block for seconds under contention,
/// which on the main thread shows up as Sentry app-hang events. The serial
/// queue also orders a save against a following load.
public enum TTSRemoteAPIKeyStore {
    private static let service = "ai.osaurus.tts.remote"
    private static let account = "apiKey"
    private static let queue = DispatchQueue(label: "ai.osaurus.tts.keychain", qos: .utility)

    /// Synchronous read. Never call on the main thread; use `load(completion:)`
    /// or call from an already-background context.
    public static func loadSync() -> String? {
        guard let data = Keychain.read(service: service, account: account),
            let key = String(data: data, encoding: .utf8),
            !key.isEmpty
        else { return nil }
        return key
    }

    /// Read off the main thread and deliver on the main actor.
    public static func load(completion: @escaping @MainActor (String?) -> Void) {
        queue.async {
            let key = loadSync()
            Task { @MainActor in completion(key) }
        }
    }

    /// Fire-and-forget upsert/delete off the caller's thread.
    public static func save(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        queue.async {
            if trimmed.isEmpty {
                Keychain.delete(service: service, account: account)
            } else {
                Keychain.write(service: service, account: account, data: Data(trimmed.utf8))
            }
        }
    }
}

/// Handles persistence of `TTSConfiguration` with in-memory caching.
@MainActor
public enum TTSConfigurationStore {
    private static var cachedConfig: TTSConfiguration?

    /// Serializes disk writes off the main actor. The cache is authoritative
    /// for readers, so the file write is fire-and-forget; the settings UI
    /// saves on every keystroke, which must never mean per-keystroke disk
    /// I/O on the main thread.
    private static let diskQueue = DispatchQueue(label: "ai.osaurus.tts.config", qos: .utility)

    public static func load() -> TTSConfiguration {
        if let cached = cachedConfig { return cached }
        let config = loadFromDisk()
        cachedConfig = config
        return config
    }

    public static func save(_ configuration: TTSConfiguration) {
        cachedConfig = configuration
        diskQueue.async { saveToDisk(configuration) }
        NotificationCenter.default.post(name: .ttsConfigurationChanged, object: nil)
    }

    private static func loadFromDisk() -> TTSConfiguration {
        let url = OsaurusPaths.ttsConfigFile()
        guard FileManager.default.fileExists(atPath: url.path) else {
            return TTSConfiguration.default
        }
        do {
            return try JSONDecoder().decode(TTSConfiguration.self, from: Data(contentsOf: url))
        } catch {
            print("[Osaurus] Failed to load TTSConfiguration: \(error)")
            return TTSConfiguration.default
        }
    }

    nonisolated private static func saveToDisk(_ configuration: TTSConfiguration) {
        let url = OsaurusPaths.ttsConfigFile()
        OsaurusPaths.ensureExistsSilent(url.deletingLastPathComponent())
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(configuration).write(to: url, options: [.atomic])
        } catch {
            print("[Osaurus] Failed to save TTSConfiguration: \(error)")
        }
    }
}

extension Notification.Name {
    public static let ttsConfigurationChanged = Notification.Name("osaurus.ttsConfigurationChanged")
}
