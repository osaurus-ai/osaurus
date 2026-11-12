//
//  SyncNetworkDirectoryTests.swift
//  OsaurusCoreTests
//
//  The relay and discovery list behind Find Devices → Anywhere: the bundled
//  default, the cached copy, validation, and refresh.
//

import Foundation
import OsaurusSync
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct SyncNetworkDirectoryTests {
    private static let published = SyncNetworkDirectory(
        version: 1,
        relays: ["https://relay-us.osaurus.ai", "https://relay-eu.osaurus.ai"],
        discoveryServer: "https://dns.osaurus.ai/pkarr",
        discoveryOrigin: "dns.osaurus.ai"
    )

    private func withRoot(_ body: @Sendable () async throws -> Void) async throws {
        try await StoragePathsTestLock.shared.run {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("osu-sync-network-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            OsaurusPaths.overrideRoot = root
            defer {
                OsaurusPaths.overrideRoot = nil
                try? FileManager.default.removeItem(at: root)
            }
            try await body()
        }
    }

    private static func fetching(_ value: some Encodable) -> SyncNetworkDirectoryStore.Fetch {
        let data = try! JSONEncoder().encode(value)
        return { _ in data }
    }

    @Test
    func bundledDefaultIsTheOsaurusServersAndValid() {
        let bundled = SyncNetworkDirectory.bundledDefault
        #expect(bundled.isValid)
        #expect(bundled.relays.count == 3)
        #expect(bundled.relays.allSatisfy { URL(string: $0)?.host?.hasSuffix(".sync.osaurus.ai") == true })
        #expect(bundled.discoveryServer == "https://dns.sync.osaurus.ai/pkarr")
        #expect(bundled.discoveryOrigin == "dns.sync.osaurus.ai")
        #expect(bundled.relays != n0PublicNetworkConfig().relays)

        var net = defaultNetworkConfig()
        bundled.apply(to: &net)
        #expect(net.publish == .relayOnly, "a user device's record mustn't reveal its addresses")
    }

    @Test
    func validationRejectsListsThisBuildCantUse() {
        #expect(Self.published.isValid)
        var list = Self.published
        list.version = 2
        #expect(!list.isValid, "unknown version")
        list = Self.published
        list.relays = []
        #expect(!list.isValid, "no relays")
        list.relays = ["http://relay.example.com"]
        #expect(!list.isValid, "plain http relay")
        list = Self.published
        list.discoveryOrigin = nil
        #expect(!list.isValid, "server without origin")
        list.discoveryServer = nil
        #expect(list.isValid, "relays only is fine")
        list = Self.published
        list.discoveryOrigin = "not a host"
        #expect(!list.isValid)
        list = Self.published
        list.relays = Array(repeating: "https://relay.example.com", count: SyncNetworkDirectory.maxRelays + 1)
        #expect(!list.isValid, "too many relays")
    }

    @Test
    func refreshCachesAValidListAndAnywhereUsesIt() async throws {
        try await withRoot {
            #expect(SyncNetworkDirectoryStore.current() == .bundledDefault)
            #expect(await SyncNetworkDirectoryStore.refresh(fetch: Self.fetching(Self.published)))
            #expect(SyncNetworkDirectoryStore.current() == Self.published)
            #expect(!(await SyncNetworkDirectoryStore.refresh(fetch: Self.fetching(Self.published))), "unchanged")

            var net = defaultNetworkConfig()
            SyncNetworkDirectoryStore.current().apply(to: &net)
            #expect(net.relays == Self.published.relays)
            #expect(net.discoveryServer == Self.published.discoveryServer)
            #expect(net.discoveryOrigin == Self.published.discoveryOrigin)
            #expect(net.mdns, "Anywhere keeps local discovery")
        }
    }

    @Test
    func badFetchesKeepTheLastGoodList() async throws {
        try await withRoot {
            try SyncNetworkDirectoryStore.save(Self.published)
            var insecure = Self.published
            insecure.relays = ["http://relay.example.com"]
            #expect(!(await SyncNetworkDirectoryStore.refresh(fetch: Self.fetching(insecure))))
            #expect(!(await SyncNetworkDirectoryStore.refresh(fetch: { _ in Data("not json".utf8) })))
            #expect(!(await SyncNetworkDirectoryStore.refresh(fetch: { _ in throw URLError(.notConnectedToInternet) })))
            #expect(SyncNetworkDirectoryStore.current() == Self.published)
        }
    }

    @Test
    func aFailedFetchIsRetriedLaterAndASuccessEndsTheLaunchsFetches() async throws {
        try await withRoot {
            SyncNetworkDirectoryStore._resetForTesting()
            defer { SyncNetworkDirectoryStore._resetForTesting() }
            let start = Date()
            let offline: SyncNetworkDirectoryStore.Fetch = { _ in throw URLError(.notConnectedToInternet) }
            await SyncNetworkDirectoryStore.scheduleRefresh(now: start, fetch: offline)?.value
            #expect(
                SyncNetworkDirectoryStore.scheduleRefresh(now: start.addingTimeInterval(60), fetch: offline) == nil,
                "too soon after a failure")

            let later = start.addingTimeInterval(SyncNetworkDirectoryStore.retryInterval)
            await SyncNetworkDirectoryStore.scheduleRefresh(now: later, fetch: Self.fetching(Self.published))?.value
            #expect(SyncNetworkDirectoryStore.current() == Self.published)
            #expect(
                SyncNetworkDirectoryStore.scheduleRefresh(
                    now: later.addingTimeInterval(SyncNetworkDirectoryStore.retryInterval),
                    fetch: Self.fetching(Self.published)) == nil,
                "one successful fetch per launch")
        }
    }

    @Test
    func theOverrideURLMustBeHTTPS() {
        let published = URL(string: "https://osaurus.ai/sync/network.json")!
        #expect(SyncNetworkDirectoryStore.remoteURL(override: nil) == published)
        #expect(
            SyncNetworkDirectoryStore.remoteURL(override: "https://staging.osaurus.ai/n.json")
                == URL(string: "https://staging.osaurus.ai/n.json"))
        #expect(SyncNetworkDirectoryStore.remoteURL(override: "http://evil.example.com/n.json") == published)
        #expect(SyncNetworkDirectoryStore.remoteURL(override: "file:///tmp/n.json") == published)
        #expect(
            SyncNetworkDirectoryStore.remoteURL(override: "http://localhost:8080/n.json")
                == URL(string: "http://localhost:8080/n.json"))
    }

    @Test
    func damagedCacheFallsBackToTheBundledDefault() async throws {
        try await withRoot {
            let url = OsaurusPaths.syncNetworkFile()
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("{\"version\":1,\"relays\":[]}".utf8).write(to: url)
            #expect(SyncNetworkDirectoryStore.current() == .bundledDefault)
        }
    }

    @Test
    func savedModeKeepsItsOnDiskName() throws {
        let decoded = try JSONDecoder().decode(
            SyncConfiguration.self, from: Data(#"{"networkEnabled":true,"networkMode":"developmentServers"}"#.utf8))
        #expect(decoded.networkMode == .anywhere)
        let encoded = String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self)
        #expect(encoded.contains("developmentServers"))
    }
}
