//
//  SyncNetworkDirectory.swift
//  osaurus
//
//  Which relay and discovery servers Find Devices → Anywhere uses. Osaurus
//  publishes the list as JSON; this Mac caches the last good copy at
//  `config/sync-network.json` and falls back to the Osaurus servers built
//  in here. A new list applies the next time the sync core opens, never to
//  a running session.
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

    /// The Osaurus relays and discovery server. Every device must use the
    /// same discovery server to find the others over the internet, so the
    /// iPhone and Windows apps ship this same list.
    static let bundledDefault = SyncNetworkDirectory(
        version: supportedVersion,
        relays: [
            "https://relay-us.sync.osaurus.ai",
            "https://relay-eu.sync.osaurus.ai",
            "https://relay-ap.sync.osaurus.ai",
        ],
        discoveryServer: "https://dns.sync.osaurus.ai/pkarr",
        discoveryOrigin: "dns.sync.osaurus.ai"
    )

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
    /// build at a staging copy over HTTPS, or HTTP on this Mac.
    static var remoteURL: URL {
        remoteURL(override: ProcessInfo.processInfo.environment["OSAURUS_SYNC_NETWORK_URL"])
    }

    static func remoteURL(override: String?) -> URL {
        let published = URL(string: "https://osaurus.ai/sync/network.json")!
        guard let override, let url = URL(string: override), let host = url.host?.lowercased() else {
            return published
        }
        switch url.scheme?.lowercased() {
        case "https":
            return url
        case "http" where ["localhost", "127.0.0.1", "::1"].contains(host):
            return url
        default:
            log.error("OSAURUS_SYNC_NETWORK_URL ignored: it must be an https URL")
            return published
        }
    }

    typealias Fetch = @Sendable (URL) async throws -> Data

    /// Least time between two fetches after one failed.
    static let retryInterval: TimeInterval = 15 * 60

    private static let lock = NSLock()
    nonisolated(unsafe) private static var refreshTask: Task<Void, Never>?
    nonisolated(unsafe) private static var lastAttempt: Date?
    nonisolated(unsafe) private static var fetchedThisLaunch = false

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
            lock.withLock { fetchedThisLaunch = true }
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

    /// Fetches in the background until one fetch per launch succeeds. The
    /// result applies at the next open.
    static func refreshInBackground() {
        guard !RuntimeEnvironment.isUnderTests else { return }
        scheduleRefresh(now: Date(), fetch: defaultFetch)
    }

    /// Starts a fetch unless one is running, one already succeeded this
    /// launch, or the last one began within `retryInterval`.
    @discardableResult
    static func scheduleRefresh(now: Date, fetch: @escaping Fetch) -> Task<Void, Never>? {
        lock.withLock {
            guard refreshTask == nil, !fetchedThisLaunch else { return nil }
            if let lastAttempt, now.timeIntervalSince(lastAttempt) < retryInterval { return nil }
            lastAttempt = now
            let task = Task.detached(priority: .utility) {
                await refresh(fetch: fetch)
                lock.withLock { refreshTask = nil }
            }
            refreshTask = task
            return task
        }
    }

    static func _resetForTesting() {
        lock.withLock {
            refreshTask = nil
            lastAttempt = nil
            fetchedThisLaunch = false
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
