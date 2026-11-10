//
//  SyncNetworkDirectory.swift
//  osaurus
//
//  Which relay and discovery servers Find Devices → Anywhere uses. Osaurus
//  publishes the list as JSON; this Mac caches the last good copy at
//  `config/sync-network.json` and falls back to number0's public servers,
//  which ship with the sync library. A new list applies the next time the
//  sync core opens, never to a running session.
//

import Foundation
import OsaurusSync
import os

struct SyncNetworkDirectory: Codable, Equatable, Sendable {
    static let supportedVersion = 1
    static let maxRelays = 8

    var version: Int
    var relays: [String]
    var discoveryServer: String?
    var discoveryOrigin: String?

    /// number0's public relays and discovery server, from the sync library.
    static var bundledDefault: SyncNetworkDirectory {
        let net = n0PublicNetworkConfig()
        return SyncNetworkDirectory(
            version: supportedVersion,
            relays: net.relays,
            discoveryServer: net.discoveryServer,
            discoveryOrigin: net.discoveryOrigin
        )
    }

    /// A list this build can use: a known version, 1 to `maxRelays` HTTPS
    /// relays, and a discovery server and origin given together.
    var isValid: Bool {
        guard version == Self.supportedVersion,
            !relays.isEmpty, relays.count <= Self.maxRelays,
            relays.allSatisfy(Self.isHTTPSURL)
        else { return false }
        switch (discoveryServer, discoveryOrigin) {
        case (nil, nil):
            return true
        case let (server?, origin?):
            return Self.isHTTPSURL(server) && Self.isHostname(origin)
        default:
            return false
        }
    }

    func apply(to net: inout NetworkConfig) {
        net.relays = relays
        net.discoveryServer = discoveryServer
        net.discoveryOrigin = discoveryOrigin
    }

    private static func isHTTPSURL(_ string: String) -> Bool {
        guard let url = URL(string: string), url.scheme?.lowercased() == "https",
            let host = url.host, !host.isEmpty
        else { return false }
        return true
    }

    /// A DNS name, optionally fully qualified with a trailing dot.
    private static func isHostname(_ string: String) -> Bool {
        let name = string.hasSuffix(".") ? String(string.dropLast()) : string
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        return labels.count >= 2
            && labels.allSatisfy { label in
                !label.isEmpty && label.count <= 63
                    && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
            }
    }
}

enum SyncNetworkDirectoryStore {
    private static let log = Logger(subsystem: "ai.osaurus", category: "sync")

    /// Where Osaurus publishes the list. `OSAURUS_SYNC_NETWORK_URL` points a
    /// build at a staging copy.
    static var remoteURL: URL {
        if let override = ProcessInfo.processInfo.environment["OSAURUS_SYNC_NETWORK_URL"],
            let url = URL(string: override)
        {
            return url
        }
        return URL(string: "https://osaurus.ai/sync/network.json")!
    }

    typealias Fetch = @Sendable (URL) async throws -> Data

    private static let lock = NSLock()
    nonisolated(unsafe) private static var refreshTask: Task<Void, Never>?

    /// The cached list when it's valid, otherwise the bundled default.
    static func current() -> SyncNetworkDirectory {
        guard let data = try? Data(contentsOf: OsaurusPaths.syncNetworkFile()),
            let cached = try? JSONDecoder().decode(SyncNetworkDirectory.self, from: data),
            cached.isValid
        else { return .bundledDefault }
        return cached
    }

    /// Fetches the published list and caches it when it's valid and new.
    /// Returns true when the cache changed. Failures keep the last good copy.
    @discardableResult
    static func refresh(fetch: Fetch = defaultFetch) async -> Bool {
        do {
            let data = try await fetch(remoteURL)
            let fetched = try JSONDecoder().decode(SyncNetworkDirectory.self, from: data)
            guard fetched.isValid else {
                log.error("sync network list rejected: unsupported version or bad server URLs")
                return false
            }
            guard fetched != current() else { return false }
            try save(fetched)
            log.info("sync network list updated: \(fetched.relays.count) relays")
            return true
        } catch {
            log.error("sync network list fetch failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// One background refresh per launch; the result applies at the next open.
    static func refreshInBackground() {
        guard !RuntimeEnvironment.isUnderTests else { return }
        lock.withLock {
            guard refreshTask == nil else { return }
            refreshTask = Task.detached(priority: .utility) { await refresh() }
        }
    }

    static func save(_ directory: SyncNetworkDirectory) throws {
        let url = OsaurusPaths.syncNetworkFile()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(directory).write(to: url, options: .atomic)
    }

    static let defaultFetch: Fetch = { url in
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        guard data.count <= 64 * 1024 else { throw URLError(.dataLengthExceedsMaximum) }
        return data
    }
}
