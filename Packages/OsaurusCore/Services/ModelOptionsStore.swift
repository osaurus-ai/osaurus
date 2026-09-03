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

    /// Return only choices written by the versioned, explicit-choice store,
    /// without consulting the model profile. This is intentionally narrower
    /// than `loadOptions`: launch-time UI normalization can run before the
    /// local-model capability scan lands, but the send path still needs to
    /// know whether an explicit Thinking choice exists so it can await the
    /// authoritative off-main capability resolution. Legacy unversioned
    /// payloads are excluded because they may contain historical injected
    /// defaults that require the migration in `loadOptions`.
    func storedExplicitOptions(for modelId: String) -> [String: ModelOptionValue]? {
        guard let data = userDefaults.data(forKey: prefix + modelId),
            let stored = try? JSONDecoder().decode(StoredOptions.self, from: data)
        else {
            return nil
        }
        return stored.options.isEmpty ? nil : stored.options
    }

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
                // Deliberately keep the stored payload even when normalization
                // drops everything: catalog-backed choices (e.g. a Codex
                // `ultra` effort) normalize to empty while the provider is
                // still disconnected and the dynamic capability catalog is
                // unpopulated. Deleting here would permanently lose the
                // user's choice before the catalog arrives to validate it.
                return normalized.isEmpty ? nil : normalized
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
            // Before stored options were versioned, Osaurus injected
            // `instruct` for every DSV4 model. The 0731 bundle's native
            // default is now `low`, so comparing only against the current
            // profile default would misclassify that historical injected
            // value as an explicit user choice. New explicit Off choices are
            // stored in `StoredOptions` and never enter this migration path.
            if key == "reasoningEffort",
                DSV4ReasoningProfile.matches(modelId: modelId),
                value.stringValue == "instruct"
            {
                return false
            }
            guard legacyDefaultKeys.contains(key), defaults[key] == value else { return true }
            return false
        }
    }
}
