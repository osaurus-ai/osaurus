//
//  ModelSharingConfiguration.swift
//  osaurus
//
//  Settings for sharing model files with other Macs on the local network,
//  persisted to `config/model-sharing.json`.
//

import Foundation

public struct ModelSharingConfiguration: Codable, Equatable, Sendable {
    /// Serve the models in `sharedItemIds` to Osaurus on this network.
    public var shareOnLocalNetwork: Bool
    /// Share ids (`<kind>:<id>`, see `ShareableModel.id`) the user chose to share.
    public var sharedItemIds: Set<String>
    /// Look for models on nearby Macs and copy files from them instead of the internet.
    public var useNearbyMacs: Bool

    public init(shareOnLocalNetwork: Bool = false, sharedItemIds: Set<String> = [], useNearbyMacs: Bool = true) {
        self.shareOnLocalNetwork = shareOnLocalNetwork
        self.sharedItemIds = sharedItemIds
        self.useNearbyMacs = useNearbyMacs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        shareOnLocalNetwork = try container.decodeIfPresent(Bool.self, forKey: .shareOnLocalNetwork) ?? false
        sharedItemIds = try container.decodeIfPresent(Set<String>.self, forKey: .sharedItemIds) ?? []
        useNearbyMacs = try container.decodeIfPresent(Bool.self, forKey: .useNearbyMacs) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(shareOnLocalNetwork, forKey: .shareOnLocalNetwork)
        try container.encode(sharedItemIds.sorted(), forKey: .sharedItemIds)
        try container.encode(useNearbyMacs, forKey: .useNearbyMacs)
    }

    private enum CodingKeys: String, CodingKey {
        case shareOnLocalNetwork, sharedItemIds, useNearbyMacs
    }

    func isShared(_ id: String) -> Bool { sharedItemIds.contains(id) }
}

public enum ModelSharingConfigurationStore {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: ModelSharingConfiguration?

    public static func load() -> ModelSharingConfiguration {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let url = OsaurusPaths.modelSharingConfigFile()
        let loaded =
            (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(ModelSharingConfiguration.self, from: $0) }
            ?? ModelSharingConfiguration()
        cached = loaded
        return loaded
    }

    public static func save(_ configuration: ModelSharingConfiguration) {
        let url = OsaurusPaths.modelSharingConfigFile()
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(configuration).write(to: url, options: .atomic)
        } catch {
            print("[ModelSharingConfigurationStore] Failed to save model sharing settings: \(error)")
        }
        lock.lock()
        cached = configuration
        lock.unlock()
    }

    static func resetCacheForTests() {
        lock.lock()
        cached = nil
        lock.unlock()
    }
}
