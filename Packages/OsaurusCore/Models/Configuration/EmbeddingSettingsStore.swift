//
//  EmbeddingSettingsStore.swift
//  osaurus
//
//  Persists Model Defaults → Embedding Model. The running process reads it
//  once at launch (`EmbeddingService.launchState`); saving a new choice
//  takes effect on the next launch.
//

import Foundation
import os

public struct EmbeddingSettings: Codable, Equatable, Sendable {
    /// Repository id of the chosen model. `nil` means the built-in model.
    public var selectedModelId: String?
    /// Bundle directory at the time it was chosen, so models found outside
    /// the Osaurus models folder (Hugging Face cache, LM Studio) still
    /// resolve on the next launch.
    public var selectedModelPath: String?

    public init(selectedModelId: String? = nil, selectedModelPath: String? = nil) {
        self.selectedModelId = selectedModelId
        self.selectedModelPath = selectedModelPath
    }

    public static let `default` = EmbeddingSettings()

    /// The id this selection resolves to, with `nil` spelled as the built-in id.
    public var effectiveModelId: String {
        guard let selectedModelId, !EmbeddingProfile.isBuiltInId(selectedModelId) else {
            return EmbeddingProfile.builtInModelId
        }
        return selectedModelId
    }
}

enum EmbeddingSettingsStore {
    private struct State {
        var overrideDirectory: URL?
        var cached: EmbeddingSettings?
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())
    private static let fileName = "embedding.json"

    static func setOverrideDirectory(_ url: URL?) {
        state.withLock {
            $0.overrideDirectory = url
            $0.cached = nil
        }
    }

    static func snapshot() -> EmbeddingSettings {
        if let cached = state.withLock({ $0.cached }) { return cached }
        let url = fileURL()
        let loaded: EmbeddingSettings
        if let data = try? Data(contentsOf: url),
            let decoded = try? JSONDecoder().decode(EmbeddingSettings.self, from: data)
        {
            loaded = decoded
        } else {
            loaded = .default
        }
        state.withLock { $0.cached = loaded }
        return loaded
    }

    static func save(_ settings: EmbeddingSettings) {
        let normalized: EmbeddingSettings =
            settings.selectedModelId.map(EmbeddingProfile.isBuiltInId) ?? true ? .default : settings
        let url = fileURL()
        state.withLock { $0.cached = normalized }
        OsaurusPaths.ensureExistsSilent(url.deletingLastPathComponent())
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(normalized).write(to: url, options: [.atomic])
        } catch {
            print("[Osaurus] Failed to save embedding settings: \(error)")
        }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .embeddingSettingsChanged, object: nil)
        }
    }

    private static func fileURL() -> URL {
        let directory = state.withLock { $0.overrideDirectory } ?? OsaurusPaths.config()
        return directory.appendingPathComponent(fileName)
    }
}

extension Notification.Name {
    static let embeddingSettingsChanged = Notification.Name("embeddingSettingsChanged")
}
