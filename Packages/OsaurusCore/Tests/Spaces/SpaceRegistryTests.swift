// Copyright © 2026 osaurus.

import Foundation
import OsaurusRepository
import Testing

@testable import OsaurusCore

/// `SpaceRegistry.overrideDirectory` is process-global, so these tests must
/// not interleave. Every document uses a throwaway bundle id, never the test
/// runner's own, so a parallel suite resolving the active Space still gets
/// Default.
@Suite("Spaces registry and launch preparation", .serialized)
struct SpaceRegistryTests {
    private let spaceA = SpaceRegistry.newSpaceId()
    private let spaceB = SpaceRegistry.newSpaceId()

    // MARK: - Document

    @Test("Decoding tolerates a registry with missing fields")
    func decodesSparseDocument() throws {
        let json = #"{"spaces":[{"id":"\#(spaceA)","name":"Test","createdAt":"2026-11-05T00:00:00Z"}]}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let doc = try decoder.decode(OsaurusSpaceRegistryDocument.self, from: Data(json.utf8))
        #expect(doc.version == 1)
        #expect(doc.spaces.map(\.id) == [spaceA])
        #expect(doc.active.isEmpty && doc.pending.isEmpty && doc.swapInProgress.isEmpty)
    }

    @Test("An active id that names no Space falls back to Default")
    func unknownActiveFallsBack() {
        var doc = OsaurusSpaceRegistryDocument(spaces: [OsaurusSpace(id: spaceA, name: "A")])
        doc.active["b1"] = spaceB
        doc.active["b2"] = spaceA
        #expect(doc.activeSpaceId(bundleId: "b1") == SpaceRegistry.defaultSpaceId)
        #expect(doc.activeSpaceId(bundleId: "b2") == spaceA)
        #expect(doc.activeSpaceId(bundleId: "never-set") == SpaceRegistry.defaultSpaceId)
    }

    @Test("Resolution: inherited id, then this bundle's entry, then Default")
    func resolutionOrder() {
        var doc = OsaurusSpaceRegistryDocument(spaces: [OsaurusSpace(id: spaceA, name: "A")])
        doc.active["app"] = spaceA
        #expect(SpaceRegistry.resolveActiveSpaceId(inheritedSpaceId: nil, document: doc, bundleId: "app") == spaceA)
        #expect(
            SpaceRegistry.resolveActiveSpaceId(inheritedSpaceId: spaceB, document: doc, bundleId: "app") == spaceB)
        #expect(
            SpaceRegistry.resolveActiveSpaceId(inheritedSpaceId: "default", document: doc, bundleId: "app")
                == SpaceRegistry.defaultSpaceId)
        #expect(
            SpaceRegistry.resolveActiveSpaceId(inheritedSpaceId: "../etc", document: doc, bundleId: "app") == spaceA)
        #expect(
            SpaceRegistry.resolveActiveSpaceId(inheritedSpaceId: nil, document: nil, bundleId: "app")
                == SpaceRegistry.defaultSpaceId)
    }

    @Test("Only lowercase UUID ids map to a data root")
    func dataRootValidation() {
        #expect(SpaceRegistry.dataRoot(for: SpaceRegistry.defaultSpaceId) == nil)
        #expect(SpaceRegistry.dataRoot(for: "../../tmp") == nil)
        #expect(SpaceRegistry.dataRoot(for: spaceA.uppercased()) == nil)
        let root = SpaceRegistry.dataRoot(for: spaceA)
        #expect(root?.lastPathComponent == "data")
        #expect(root?.deletingLastPathComponent().lastPathComponent == spaceA)
    }

    @Test("The app root is the active Space root unless a test root is set")
    func testRootWinsOverSpaces() {
        // This suite runs under OSAURUS_TEST_ROOT or an XCTest marker, so
        // Spaces must stay out of the way for every other suite.
        #expect(!SpaceRegistry.isEnabled || SpaceRegistry.overrideDirectory != nil)
        #expect(SpaceRegistry.activeSpaceId() == SpaceRegistry.defaultSpaceId)
    }

    // MARK: - Edits

    @Test("Names are trimmed, required, and unique (including Default)")
    func nameValidation() throws {
        var doc = OsaurusSpaceRegistryDocument()
        let id = try doc.createSpace(named: "  Onboarding  ", bundleId: "app")
        #expect(doc.space(id: id)?.name == "Onboarding")
        #expect(doc.active["app"] == id)
        #expect(throws: SpaceEditError.emptyName) { try doc.createSpace(named: "   ", bundleId: "app") }
        #expect(throws: SpaceEditError.duplicateName) { try doc.createSpace(named: "onboarding", bundleId: "app") }
        #expect(throws: SpaceEditError.duplicateName) {
            try doc.createSpace(named: SpaceActions.defaultSpaceName, bundleId: "app")
        }
        try doc.renameSpace(id, to: "Onboarding")
        #expect(throws: SpaceEditError.defaultSpace) { try doc.renameSpace(SpaceRegistry.defaultSpaceId, to: "x") }
    }

    @Test("Deleting the current Space defers to the next launch; others go now")
    func deleteModes() throws {
        var doc = OsaurusSpaceRegistryDocument(spaces: [
            OsaurusSpace(id: spaceA, name: "A"), OsaurusSpace(id: spaceB, name: "B"),
        ])
        doc.active["app"] = spaceA
        #expect(try doc.requestDelete(of: spaceB, bundleId: "app", currentSpaceId: spaceA) == .immediate)
        #expect(doc.pending["app"] == nil)

        #expect(try doc.requestDelete(of: spaceA, bundleId: "app", currentSpaceId: spaceA) == .afterRelaunch)
        #expect(doc.active["app"] == SpaceRegistry.defaultSpaceId)
        #expect(doc.pending["app"] == [OsaurusSpacePendingOperation(kind: .delete, spaceId: spaceA)])

        #expect(throws: SpaceEditError.defaultSpace) {
            try doc.requestDelete(of: SpaceRegistry.defaultSpaceId, bundleId: "app", currentSpaceId: spaceA)
        }
    }

    @Test("A Space open in another bundle can't be reset or deleted")
    func inUseElsewhere() {
        var doc = OsaurusSpaceRegistryDocument(spaces: [OsaurusSpace(id: spaceA, name: "A")])
        doc.active["beta"] = spaceA
        #expect(throws: SpaceEditError.inUseElsewhere(bundleIds: ["beta"])) {
            try doc.requestReset(of: spaceA, bundleId: "app")
        }
        #expect(throws: SpaceEditError.inUseElsewhere(bundleIds: ["beta"])) {
            _ = try doc.requestDelete(of: spaceA, bundleId: "app", currentSpaceId: SpaceRegistry.defaultSpaceId)
        }
    }

    // MARK: - Launch preparation

    private struct Fixture {
        let directory: URL
        let bundleId: String
        let defaults: UserDefaults

        init() {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("osaurus-spaces-\(UUID().uuidString)", isDirectory: true)
            bundleId = "ai.osaurus.tests.spaces.\(UUID().uuidString.lowercased())"
            defaults = UserDefaults(suiteName: bundleId)!
            SpaceRegistry.overrideDirectory = directory
        }

        var live: [String: Any] { defaults.persistentDomain(forName: bundleId) ?? [:] }

        func setLive(_ domain: [String: Any]) {
            defaults.setPersistentDomain(domain, forName: bundleId)
        }

        func parked(_ spaceId: String) -> [String: Any]? {
            let url = SpaceRegistry.preferencesFile(spaceId: spaceId, bundleId: bundleId)
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        }

        func cleanUp() {
            defaults.removePersistentDomain(forName: bundleId)
            try? FileManager.default.removeItem(at: directory)
            SpaceRegistry.overrideDirectory = nil
            SpaceRegistry._resetCacheForTesting()
        }
    }

    @Test("Switching parks the live preferences and back restores them exactly")
    func swapRoundTrip() throws {
        let fx = Fixture()
        defer { fx.cleanUp() }
        fx.setLive(["hasCompletedOnboarding": true, "SUEnableAutomaticChecks": true, "AppleLanguages": ["de"]])

        var doc = OsaurusSpaceRegistryDocument(spaces: [OsaurusSpace(id: spaceA, name: "A")])
        doc.active[fx.bundleId] = spaceA
        #expect(SpaceLauncher.prepare(&doc, bundleId: fx.bundleId, defaults: fx.defaults) == spaceA)

        // The new Space starts fresh except for carried-over keys.
        #expect(fx.live["hasCompletedOnboarding"] == nil)
        #expect(fx.live["SUEnableAutomaticChecks"] as? Bool == true)
        #expect(fx.live["AppleLanguages"] as? [String] == ["de"])
        #expect(fx.parked(SpaceRegistry.defaultSpaceId)?["hasCompletedOnboarding"] as? Bool == true)
        #expect(doc.defaultsOwner[fx.bundleId] == spaceA)
        #expect(doc.swapInProgress[fx.bundleId] == nil)

        var live = fx.live
        live["hasCompletedOnboarding"] = true
        live["onboardingVersion"] = 3
        fx.setLive(live)

        doc.active[fx.bundleId] = SpaceRegistry.defaultSpaceId
        #expect(SpaceLauncher.prepare(&doc, bundleId: fx.bundleId, defaults: fx.defaults) == "default")
        #expect(fx.live["hasCompletedOnboarding"] as? Bool == true)
        #expect(fx.live["onboardingVersion"] == nil)
        #expect(fx.parked(spaceA)?["onboardingVersion"] as? Int == 3)

        // The registry on disk matches what the launcher returned.
        let saved = try #require(try SpaceRegistry.load())
        #expect(saved.defaultsOwner[fx.bundleId] == SpaceRegistry.defaultSpaceId)
    }

    @Test("A crash mid-swap finishes loading the target without re-parking")
    func crashRecovery() throws {
        let fx = Fixture()
        defer { fx.cleanUp() }
        var doc = OsaurusSpaceRegistryDocument(spaces: [OsaurusSpace(id: spaceA, name: "A")])
        doc.active[fx.bundleId] = spaceA
        doc.defaultsOwner[fx.bundleId] = SpaceRegistry.defaultSpaceId
        doc.swapInProgress[fx.bundleId] = OsaurusSpaceSwap(from: SpaceRegistry.defaultSpaceId, to: spaceA)

        let defaultURL = SpaceRegistry.preferencesFile(spaceId: "default", bundleId: fx.bundleId)
        try FileManager.default.createDirectory(
            at: defaultURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["personal": true], format: .binary, options: 0)
            .write(to: defaultURL)
        // Whatever is live now may already be partly the target's.
        fx.setLive(["half-swapped": true])

        #expect(SpaceLauncher.prepare(&doc, bundleId: fx.bundleId, defaults: fx.defaults) == spaceA)
        #expect(fx.parked(SpaceRegistry.defaultSpaceId)?["personal"] as? Bool == true)
        #expect(fx.parked(SpaceRegistry.defaultSpaceId)?["half-swapped"] == nil)
        #expect(doc.defaultsOwner[fx.bundleId] == spaceA)
        #expect(doc.swapInProgress[fx.bundleId] == nil)
    }

    @Test("Pending reset wipes the Space's data and preferences but keeps it")
    func pendingReset() throws {
        let fx = Fixture()
        defer { fx.cleanUp() }
        let data = try #require(SpaceRegistry.dataRoot(for: spaceA))
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try Data("chat".utf8).write(to: data.appendingPathComponent("chat.db"))
        fx.setLive(["hasCompletedOnboarding": true, "SUFeedURL": "x"])

        var doc = OsaurusSpaceRegistryDocument(spaces: [OsaurusSpace(id: spaceA, name: "A")])
        doc.active[fx.bundleId] = spaceA
        doc.defaultsOwner[fx.bundleId] = spaceA
        try doc.requestReset(of: spaceA, bundleId: fx.bundleId)

        #expect(SpaceLauncher.prepare(&doc, bundleId: fx.bundleId, defaults: fx.defaults) == spaceA)
        #expect(!FileManager.default.fileExists(atPath: data.path))
        #expect(fx.live["hasCompletedOnboarding"] == nil)
        #expect(fx.live["SUFeedURL"] as? String == "x")
        #expect(doc.space(id: spaceA) != nil)
        #expect(doc.pending[fx.bundleId] == nil)
    }

    @Test("Pending delete of the current Space restores Default without parking")
    func pendingDeleteOfCurrent() throws {
        let fx = Fixture()
        defer { fx.cleanUp() }
        let defaultURL = SpaceRegistry.preferencesFile(spaceId: "default", bundleId: fx.bundleId)
        try FileManager.default.createDirectory(
            at: defaultURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["personal": true], format: .binary, options: 0)
            .write(to: defaultURL)
        let folder = SpaceRegistry.spaceDirectory(for: spaceA)
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent("data"), withIntermediateDirectories: true)
        fx.setLive(["test-space-only": true])

        var doc = OsaurusSpaceRegistryDocument(spaces: [OsaurusSpace(id: spaceA, name: "A")])
        doc.active[fx.bundleId] = spaceA
        doc.defaultsOwner[fx.bundleId] = spaceA
        _ = try doc.requestDelete(of: spaceA, bundleId: fx.bundleId, currentSpaceId: spaceA)

        #expect(SpaceLauncher.prepare(&doc, bundleId: fx.bundleId, defaults: fx.defaults) == "default")
        #expect(doc.spaces.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(fx.live["personal"] as? Bool == true)
        #expect(fx.live["test-space-only"] == nil)
        #expect(fx.parked(SpaceRegistry.defaultSpaceId)?["test-space-only"] == nil)
    }

    @Test("A launch with nothing to do leaves preferences untouched")
    func noOpLaunch() {
        let fx = Fixture()
        defer { fx.cleanUp() }
        fx.setLive(["keep": 1])
        var doc = OsaurusSpaceRegistryDocument()
        #expect(SpaceLauncher.prepare(&doc, bundleId: fx.bundleId, defaults: fx.defaults) == "default")
        #expect(fx.live["keep"] as? Int == 1)
        #expect(!FileManager.default.fileExists(atPath: SpaceRegistry.registryFile().path))
    }
}
