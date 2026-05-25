//
//  ModelOptionsStore.swift
//  osaurus
//
//  Persists model-specific option preferences (like Thinking mode)
//  to UserDefaults so they are remembered per LLM.
//

import Foundation
import Combine

@MainActor
final class ModelOptionsStore: ObservableObject {
    static let shared = ModelOptionsStore()

    private struct StoredOptions: Codable, Equatable {
        var version: Int
        var options: [String: ModelOptionValue]
    }

    private let userDefaults = UserDefaults.standard
    private let prefix = "model_options_"

    private init() {}

    /// Load persisted options for a specific model ID
    func loadOptions(for modelId: String) -> [String: ModelOptionValue]? {
        guard let data = userDefaults.data(forKey: prefix + modelId) else { return nil }

        do {
            let decoder = JSONDecoder()
            if let stored = try? decoder.decode(StoredOptions.self, from: data) {
                let normalized = ModelProfileRegistry.normalizedOptions(
                    for: modelId,
                    persisted: stored.options
                )
                if normalized.isEmpty {
                    userDefaults.removeObject(forKey: prefix + modelId)
                    return nil
                }
                return normalized
            }

            let decoded = try decoder.decode([String: ModelOptionValue].self, from: data)
            let normalized = ModelProfileRegistry.normalizedOptions(for: modelId, persisted: decoded)
            let migrated = Self.dropLegacyInjectedDefaults(for: modelId, values: normalized)
            if migrated.isEmpty {
                userDefaults.removeObject(forKey: prefix + modelId)
                return nil
            }
            if migrated != decoded {
                saveOptions(migrated, for: modelId)
            }
            return migrated
        } catch {
            print("[ModelOptionsStore] Failed to decode options for \(modelId): \(error)")
            return nil
        }
    }

    /// Save options for a specific model ID
    func saveOptions(_ options: [String: ModelOptionValue], for modelId: String) {
        guard !options.isEmpty else {
            userDefaults.removeObject(forKey: prefix + modelId)
            return
        }

        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(StoredOptions(version: 1, options: options))
            userDefaults.set(data, forKey: prefix + modelId)
        } catch {
            print("[ModelOptionsStore] Failed to encode options for \(modelId): \(error)")
        }
    }

    private static func dropLegacyInjectedDefaults(
        for modelId: String,
        values: [String: ModelOptionValue]
    ) -> [String: ModelOptionValue] {
        let legacyDefaultKeys: Set<String> = ["disableThinking", "reasoningEffort"]
        let defaults = ModelProfileRegistry.defaults(for: modelId)
        return values.filter { key, value in
            guard legacyDefaultKeys.contains(key), defaults[key] == value else { return true }
            return false
        }
    }
}
