//
//  SyncConfiguration.swift
//  osaurus
//
//  User settings for Osaurus Sync, persisted to `config/sync.json`.
//

import Foundation

public struct SyncConfiguration: Codable, Equatable, Sendable {
    /// Which servers devices use to find each other beyond the local network.
    public enum NetworkMode: String, Codable, CaseIterable, Sendable {
        /// mDNS only: devices sync while they share a network.
        case localNetworkOnly
        /// Also relay and discovery servers, from `SyncNetworkDirectory`, so
        /// devices on other networks find each other. Shown as Anywhere (Beta).
        case anywhere = "developmentServers"
    }

    /// Bring the sync network up. Off keeps every conversation on this Mac.
    public var networkEnabled: Bool
    public var networkMode: NetworkMode
    /// Let the user's other devices chat with this Mac's agents, which run here.
    public var hostAgentsForOtherDevices: Bool
    /// The sync identity is the one the Osaurus wallet derives
    /// (`SyncWalletLink`), so the wallet's recovery phrase restores sync.
    public var walletLinked: Bool
    /// The user key the link adopted, to tell a later identity change apart.
    public var walletUserKey: String?

    public init(
        networkEnabled: Bool = true,
        networkMode: NetworkMode = .localNetworkOnly,
        hostAgentsForOtherDevices: Bool = true,
        walletLinked: Bool = false,
        walletUserKey: String? = nil
    ) {
        self.networkEnabled = networkEnabled
        self.networkMode = networkMode
        self.hostAgentsForOtherDevices = hostAgentsForOtherDevices
        self.walletLinked = walletLinked
        self.walletUserKey = walletUserKey
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        networkEnabled = try container.decodeIfPresent(Bool.self, forKey: .networkEnabled) ?? true
        networkMode =
            (try? container.decodeIfPresent(NetworkMode.self, forKey: .networkMode)) ?? .localNetworkOnly
        hostAgentsForOtherDevices =
            try container.decodeIfPresent(Bool.self, forKey: .hostAgentsForOtherDevices) ?? true
        walletLinked = try container.decodeIfPresent(Bool.self, forKey: .walletLinked) ?? false
        walletUserKey = try container.decodeIfPresent(String.self, forKey: .walletUserKey)
    }

    private enum CodingKeys: String, CodingKey {
        case networkEnabled, networkMode, hostAgentsForOtherDevices, walletLinked, walletUserKey
    }
}

public enum SyncConfigurationStore {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: SyncConfiguration?

    public static func load() -> SyncConfiguration {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let url = OsaurusPaths.syncConfigFile()
        let loaded =
            (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(SyncConfiguration.self, from: $0) }
            ?? SyncConfiguration()
        cached = loaded
        return loaded
    }

    public static func save(_ configuration: SyncConfiguration) {
        let url = OsaurusPaths.syncConfigFile()
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(configuration).write(to: url, options: .atomic)
        } catch {
            print("[SyncConfigurationStore] Failed to save sync settings: \(error)")
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
