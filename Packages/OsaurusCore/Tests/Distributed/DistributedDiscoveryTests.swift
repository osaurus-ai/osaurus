//
//  DistributedDiscoveryTests.swift
//  OsaurusCoreTests
//

import Foundation
import MLXLMCommon
import Network
import Testing

@testable import OsaurusCore

struct DistributedNodeAdvertTests {
    private let advert = DistributedNodeAdvert(
        nodeID: "node-1",
        host: "Studio’s MacBook Pro",
        appVersion: "0.25.0",
        thunderboltDomains: [DistributedFixtures.peerDomain, "00000009-0000-4000-8000-0000000000FF"],
        rdma: "enabled",
        memoryBytes: 137_438_953_472,
        modelID: "JANGQ-AI/Qwen3.8-Flash-Next-JANG_2L",
        modelFingerprint: "0123456789ab"
    )

    @Test func txtRoundTrips() {
        #expect(DistributedNodeAdvert.parse(advert.txtRecord()) == advert)
    }

    @Test func otherProtocolVersionsAndAnonymousRecordsAreIgnored() {
        var record = advert.txtRecord()
        record["v"] = "2"
        #expect(DistributedNodeAdvert.parse(record) == nil)
        record = advert.txtRecord()
        record["node"] = ""
        #expect(DistributedNodeAdvert.parse(record) == nil)
        #expect(DistributedNodeAdvert.parse([:]) == nil)
    }

    @Test func oversizeValuesAreDroppedNeverTruncated() {
        var long = advert
        long.modelID = String(repeating: "m", count: 300)
        let record = long.txtRecord()
        #expect(record["model"] == nil)
        #expect(record.allSatisfy { $0.key.utf8.count + 1 + $0.value.utf8.count <= 255 })
        #expect(DistributedNodeAdvert.parse(record)?.modelID == nil)
    }

    @Test func thunderboltListIsNormalised() {
        var record = advert.txtRecord()
        record["tb"] = " abc , ,DEF"
        #expect(DistributedNodeAdvert.parse(record)?.thunderboltDomains == ["ABC", "DEF"])
        record["mem"] = "lots"
        #expect(DistributedNodeAdvert.parse(record)?.memoryBytes == 0)
    }

    @Test func serviceTypeIsDeclaredInTheAppBundleInfoPlist() throws {
        let plist = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("App/osaurus/Info.plist")
        let info = try #require(NSDictionary(contentsOf: plist) as? [String: Any])
        let declared = try #require(info["NSBonjourServices"] as? [String])
        #expect(
            declared.contains(DistributedNodeAdvert.serviceType),
            "macOS refuses to browse or publish an undeclared Bonjour type"
        )
        #expect((info["NSLocalNetworkUsageDescription"] as? String)?.contains("distributed") == true)
    }
}

struct DiscoveredNodeTests {
    private var localPorts: [ThunderboltPort] {
        ThunderboltTopology.parse(Data(DistributedFixtures.localThunderbolt.utf8)) ?? []
    }

    private func advert(_ node: String, domains: [String], model: String? = nil, fingerprint: String? = nil)
        -> DistributedNodeAdvert
    {
        DistributedNodeAdvert(
            nodeID: node,
            host: node,
            appVersion: "1",
            thunderboltDomains: domains,
            rdma: "enabled",
            memoryBytes: 1,
            modelID: model,
            modelFingerprint: fingerprint
        )
    }

    @Test func peerOwningTheCabledDomainIsCableVerified() {
        let ports = DiscoveredNode.cabledPorts(
            for: advert("peer", domains: [DistributedFixtures.peerDomain]),
            ports: localPorts
        )
        #expect(ports.map(\.receptacle) == [2])
    }

    @Test func advertisingOurOwnDomainDoesNotVerifyACable() {
        // A spoofed or confused record claiming this Mac's domain is not the
        // host on the far end of the cable.
        let ports = DiscoveredNode.cabledPorts(
            for: advert("liar", domains: [DistributedFixtures.localDomain]),
            ports: localPorts
        )
        #expect(ports.isEmpty)
        #expect(DiscoveredNode.cabledPorts(for: advert("wifi", domains: []), ports: localPorts).isEmpty)
    }

    @Test func nodesMergeInterfacesDropSelfAndSortVerifiedFirst() {
        let peer = advert("peer", domains: [DistributedFixtures.peerDomain])
        let other = advert("aaa-lan-only", domains: ["FFFF"])
        let me = advert("me", domains: [DistributedFixtures.localDomain])
        let nodes = DistributedNodeScanner.nodes(
            from: [(peer, ["en0"]), (other, ["en0"]), (peer, ["bridge0", "en0"]), (me, ["en0"])],
            ownNodeID: "me",
            ports: localPorts
        )
        #expect(nodes.map(\.id) == ["peer", "aaa-lan-only"])
        #expect(nodes[0].interfaces == ["bridge0", "en0"])
        #expect(nodes[0].isCableVerified)
        #expect(!nodes[1].isCableVerified)
    }

    @Test func modelMatchNeverAssumesIdentityFromTheName() {
        let same = DiscoveredNode(
            advert: advert("p", domains: [], model: "m", fingerprint: "abc"),
            interfaces: [],
            cabledPorts: []
        )
        #expect(same.modelMatch(localModelID: "m", localFingerprint: "abc") == .sameBundle)
        #expect(same.modelMatch(localModelID: "m", localFingerprint: "abd") == .differentBundle)
        #expect(same.modelMatch(localModelID: "m", localFingerprint: nil) == .unverified)
        #expect(same.modelMatch(localModelID: "x", localFingerprint: "abc") == .differentModel("m"))
        #expect(same.modelMatch(localModelID: nil, localFingerprint: nil) == .noLocalSelection)
        let unreported = DiscoveredNode(advert: advert("p", domains: [], model: "m"), interfaces: [], cabledPorts: [])
        #expect(unreported.modelMatch(localModelID: "m", localFingerprint: "abc") == .unverified)
        let none = DiscoveredNode(advert: advert("p", domains: []), interfaces: [], cabledPorts: [])
        #expect(none.modelMatch(localModelID: "m", localFingerprint: "abc") == .peerHasNoSelection)
    }

    @Test func localNetworkDenialIsTyped() {
        #expect(
            DistributedDiscoveryError.classify(.dns(DNSServiceErrorType(kDNSServiceErr_PolicyDenied)))
                == .localNetworkDenied
        )
        #expect(
            DistributedDiscoveryError.classify(.dns(DNSServiceErrorType(kDNSServiceErr_NoAuth))) == .localNetworkDenied
        )
        guard case .failed = DistributedDiscoveryError.classify(.posix(.ECONNREFUSED)) else {
            Issue.record("other errors must not read as a permission problem")
            return
        }
    }
}

@MainActor
struct DistributedAdvertiserPersistenceTests {
    private func defaults() -> UserDefaults {
        let name = "distributed-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func offByDefaultAndNodeIDIsStable() {
        let store = defaults()
        let first = DistributedNodeAdvertiser(defaults: store)
        #expect(!first.isEnabled)
        #expect(first.state == .off)
        let id = first.nodeID
        #expect(UUID(uuidString: id) != nil)
        #expect(DistributedNodeAdvertiser(defaults: store).nodeID == id)
        #expect(DistributedNodeAdvertiser(defaults: defaults()).nodeID != id)
    }

    @Test func enablingWithoutAnAdvertPersistsButDoesNotPublish() {
        let store = defaults()
        let advertiser = DistributedNodeAdvertiser(defaults: store)
        advertiser.setEnabled(true, advert: nil)
        #expect(store.bool(forKey: DistributedNodeAdvertiser.enabledKey))
        #expect(advertiser.state == .off, "nothing is published until the local snapshot exists")
        advertiser.setEnabled(false, advert: nil)
        #expect(!store.bool(forKey: DistributedNodeAdvertiser.enabledKey))
        #expect(advertiser.state == .off)
    }

    @Test func modelSelectionPersistsThroughTheSharedKey() {
        let store = defaults()
        let service = DistributedPreviewService(defaults: store, advertiser: DistributedNodeAdvertiser(defaults: store))
        #expect(service.selectedModelID.isEmpty)
        service.selectedModelID = "OsaurusAI/Example"
        #expect(store.string(forKey: DistributedPreviewService.selectedModelKey) == "OsaurusAI/Example")
        let reopened = DistributedPreviewService(
            defaults: store,
            advertiser: DistributedNodeAdvertiser(defaults: store)
        )
        #expect(reopened.selectedModelID == "OsaurusAI/Example")
        service.stop()
        reopened.stop()
    }

    @Test func localModelsAreDeduplicatedCaseInsensitivelyAndSorted() {
        let root = URL(fileURLWithPath: "/tmp/models")
        let catalog = [
            MLXModel(id: "b/Model-10", name: "", description: "", downloadURL: "", rootDirectory: root),
            MLXModel(id: "b/model-2", name: "", description: "", downloadURL: "", rootDirectory: root),
            MLXModel(id: "B/MODEL-10", name: "", description: "", downloadURL: "", rootDirectory: root),
        ]
        let models = DistributedPreviewService.localModels(catalog)
        #expect(models.map(\.id) == ["b/model-2", "b/Model-10"])
        #expect(models[0].directory.path == "/tmp/models/b/model-2")
    }
}

struct DistributedPresentationTests {
    @Test func missingVolumeWordingNamesTheDiskAndPromisesNoRedirect() {
        let report = CacheVolumeReport(
            configuredPath: "/Volumes/Work/cache",
            resolvedPath: "/Volumes/Work/cache",
            reuseEnabled: true,
            state: .volumeMissing(expectedMount: "/Volumes/Work"),
            mountPoint: nil
        )
        let text = DistributedText.cacheState(report)
        #expect(text.contains("/Volumes/Work"))
        #expect(text.contains("not connected"))
        #expect(DistributedText.cacheTone(report) == .bad)
    }

    @Test func localNetworkIsAllowedOnlyWhenSomethingWasSeen() {
        func verdict(
            _ scan: DistributedNodeScanner.Phase,
            _ adv: DistributedNodeAdvertiser.State,
            discoverable: Bool = true,
            sawSelf: Bool = false,
            peers: Bool = false
        ) -> DistributedTone {
            DistributedText.localNetwork(
                scan: scan,
                advertiser: adv,
                discoverable: discoverable,
                sawOwnAdvert: sawSelf,
                foundPeers: peers
            ).1
        }
        // An empty finished scan while publishing is the silent-block case seen live on macOS 27.
        #expect(verdict(.finished, .publishing) == .bad)
        #expect(verdict(.finished, .publishing, sawSelf: true) == .good)
        #expect(verdict(.idle, .advertising(port: 1)) == .good)
        #expect(verdict(.idle, .notVisible) == .bad)
        #expect(verdict(.failed(.localNetworkDenied), .off, discoverable: false) == .bad)
        // Not discoverable and nothing found: unknown, never "Allowed".
        #expect(verdict(.finished, .off, discoverable: false) == .neutral)
        #expect(verdict(.idle, .publishing) == .neutral)
        #expect(verdict(.finished, .off, discoverable: false, peers: true) == .good)
    }

    @Test func disabledReuseNeverPromisesWrites() {
        var report = CacheVolumeReport(
            configuredPath: "/Volumes/Work/c",
            resolvedPath: "/Volumes/Work/c",
            reuseEnabled: false,
            state: .notCreated(volumeRoot: "/Volumes/Work"),
            mountPoint: "/Volumes/Work"
        )
        #expect(DistributedText.cacheState(report).contains("Disk reuse is off"))
        #expect(!DistributedText.cacheState(report).contains("creates it"))
        #expect(DistributedText.reuseTone(report) == .warn)
        report.reuseEnabled = true
        #expect(DistributedText.cacheState(report).contains("creates it on /Volumes/Work"))
        #expect(DistributedText.reuseTone(report) == .good)
        report.state = .volumeMissing(expectedMount: "/Volumes/Work")
        #expect(DistributedText.reuseTone(report) == .warn, "enabled reuse on a missing disk is not fine")
    }

    @Test func cacheSizesMatchTheServerCacheSection() {
        // Live: Server showed "432.2 GB" while the panel showed "464.07 GB" for the same bytes.
        // Automatic = 30% of (free + own): 0.30 × 1,546.9 GB = 464.07 GB.
        let resolution = DiskCacheCapPolicy.resolve(
            percent: nil,
            legacyGB: nil,
            totalBytes: 4_000_000_000_000,
            freeBytes: 1_546_900_000_000,
            ownBytes: 0
        )
        #expect(resolution.rule == .automatic)
        #expect(resolution.capBytes == 464_070_000_000)
        #expect(DistributedText.quota(resolution) == DiskCacheUsage.format(bytes: 464_070_000_000) + " (automatic)")
        #expect(DistributedText.quota(resolution).hasPrefix("432.2 GB"))
        #expect(DistributedText.cacheBytes(1_073_741_824, of: 2_147_483_648) == "1.0 GB of 2.0 GB")
        #expect(DistributedText.cacheBytes(nil, of: 5) == "Unknown")
    }

    @Test func interfacesUseHardwarePortNames() {
        let ports = HardwarePortMap.parse(DistributedFixtures.hardwarePorts)
        #expect(
            DistributedText.interfaces(["bridge0", "en0", "utun3"], ports: ports)
                == "Thunderbolt Bridge (bridge0), Wi-Fi (en0), utun3"
        )
        #expect(DistributedText.interfaces([], ports: ports) == "Unknown interface")
    }

    @Test func linkDetailForTheRealCabledPort() throws {
        let ports = try #require(ThunderboltTopology.parse(Data(DistributedFixtures.localThunderbolt.utf8)))
        let links = ThunderboltLinkSummary.build(
            ports: ports,
            hardwarePorts: HardwarePortMap.parse(DistributedFixtures.hardwarePorts),
            rdmaDevices: [],
            addresses: [:]
        )
        let cabled = try #require(links.first { $0.cabledMac != nil })
        let text = DistributedText.linkDetail(cabled)
        #expect(text.contains("Cabled to MacBook Pro (Mac17,6)"))
        #expect(text.contains("No RDMA device for this port"))
        #expect(DistributedText.linkSpeed(cabled.port) == "80 Gb/s link")
        let idle = try #require(links.first { $0.port.receptacle == 1 })
        #expect(DistributedText.linkSpeed(idle.port) == "Nothing connected")
    }
}

struct DistributedNavigationTests {
    @Test func tabLivesInModelsSectionWithStableTelemetry() {
        #expect(ManagementTab.distributed.section == .models)
        #expect(ManagementSection.models.tabs == [.models, .providers, .distributed, .imageGeneration])
        #expect(ManagementTab.visibleCases.contains(.distributed))
    }

    @Test func everyDistributedRowIsDisambiguatedFromPeerSharing() {
        let rows = SettingsSearchIndex.entries.filter { $0.tab == .distributed }
        #expect(rows.count == 16)
        #expect(rows.allSatisfy { $0.disambiguation?.contains("Share my models for inference") == true })
        #expect(rows.allSatisfy { $0.declarativeSection == nil }, "preview controls are Settings-UI only")
    }

    @Test func searchReachesThePanelByFeatureWords() {
        for query in ["tensor parallel", "rdma", "tb5", "thunderbolt 5", "distributed inference"] {
            #expect(SettingsSearchIndex.search(query).contains { $0.tab == .distributed }, "\(query)")
        }
    }

    @Test func guideNamesEveryDistributedControl() throws {
        let guide = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Guide/guide-settings.md")
        let text = try String(contentsOf: guide, encoding: .utf8)
        let missing = SettingsSearchIndex.entries.filter { $0.tab == .distributed && !text.contains($0.title) }.map(
            \.title
        )
        #expect(missing.isEmpty, "guide-settings.md does not mention: \(missing)")
    }

    @Test func configureCacheTargetsARealServerSection() {
        #expect(ServerSettingsSection(rawValue: "cache") != nil)
        #expect(
            SettingsSearchIndex.entries.contains {
                $0.id == "settings.server.diskCacheDirectory" && $0.subTab == "cache"
            }
        )
    }
}
