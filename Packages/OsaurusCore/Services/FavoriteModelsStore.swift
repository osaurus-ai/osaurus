//
//  FavoriteModelsStore.swift
//  osaurus
//
//  Persists the user's favourite ("bookmarked") models so a few preferred
//  options can be pinned into a Favourites tab in the model picker instead of
//  being searched for repeatedly. Favourites are keyed by the cross-provider
//  unique key (source + id), never the bare id, so the same model id offered by
//  two providers stays distinct.
//

import Foundation
import Combine

@MainActor
final class FavoriteModelsStore: ObservableObject {
    static let shared = FavoriteModelsStore()

    /// Favourited model keys in the order they were added (oldest first). Kept
    /// as an ordered array so the Favourites tab renders in a stable sequence;
    /// membership tests go through `keySet`.
    @Published private(set) var favoriteKeys: [String]
    private var keySet: Set<String>

    private let userDefaults: UserDefaults
    private let storageKey = "favorite_model_keys"

    private struct Stored: Codable {
        var version: Int
        var keys: [String]
    }

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        let loaded = Self.load(from: userDefaults, key: storageKey)
        self.favoriteKeys = loaded
        self.keySet = Set(loaded)
    }

    /// Stable cross-provider favourite key: the source's unique key joined to
    /// the model id. Both `ModelPickerItem` and `ModelPickerRow` route through
    /// this so a favourite added from one surface is recognised on the other.
    nonisolated static func key(sourceKey: String, modelId: String) -> String {
        // Unit-separator join so the two components can never be confused with
        // literal characters in either the source key or the model id.
        "\(sourceKey)\u{1F}\(modelId)"
    }

    func isFavorite(_ key: String) -> Bool {
        keySet.contains(key)
    }

    /// Add the key when absent, remove it when present. Returns nothing — the
    /// caller observes `favoriteKeys` for the resulting state.
    func toggle(_ key: String) {
        if keySet.contains(key) {
            remove(key)
        } else {
            add(key)
        }
    }

    func add(_ key: String) {
        guard !keySet.contains(key) else { return }
        keySet.insert(key)
        favoriteKeys.append(key)
        persist()
    }

    func remove(_ key: String) {
        guard keySet.contains(key) else { return }
        keySet.remove(key)
        favoriteKeys.removeAll { $0 == key }
        persist()
    }

    // MARK: - Persistence

    private func persist() {
        do {
            let data = try JSONEncoder().encode(Stored(version: 1, keys: favoriteKeys))
            userDefaults.set(data, forKey: storageKey)
        } catch {
            print("[FavoriteModelsStore] Failed to encode favourites: \(error)")
        }
    }

    private static func load(from userDefaults: UserDefaults, key: String) -> [String] {
        guard let data = userDefaults.data(forKey: key) else { return [] }
        guard let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return [] }
        // Drop duplicates while preserving first-seen order in case a persisted
        // payload was ever written with repeats.
        var seen = Set<String>()
        return stored.keys.filter { seen.insert($0).inserted }
    }
}
