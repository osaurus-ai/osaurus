import Foundation
import XCTest
@testable import OsaurusCLICore

final class CoordinatorFeatureFlagsTests: XCTestCase {
    func testLoadMissingFlagsReturnsDefaults() throws {
        let store = CoordinatorFeatureFlagsStore(paths: try temporaryPaths())
        let flags = try store.load()

        XCTAssertEqual(flags["coordinator"], true)
        XCTAssertEqual(flags["heartbeat"], false)
    }

    func testSetPersistsFeatureFlag() throws {
        let paths = try temporaryPaths()
        let store = CoordinatorFeatureFlagsStore(paths: paths)

        _ = try store.set("heartbeat", enabled: true)
        let reloaded = try CoordinatorFeatureFlagsStore(paths: paths).load()

        XCTAssertEqual(reloaded["heartbeat"], true)
    }

    private func writeCorruptFlags(_ paths: CoordinatorPaths) throws {
        try FileManager.default.createDirectory(
            at: paths.stateDirectory,
            withIntermediateDirectories: true
        )
        try Data("{ this is not valid json".utf8).write(to: paths.featureFlagsFile)
    }

    func testLoadCorruptFlagsReturnsDefaults() throws {
        let paths = try temporaryPaths()
        try writeCorruptFlags(paths)

        let store = CoordinatorFeatureFlagsStore(paths: paths)
        let flags = try store.load()

        XCTAssertEqual(flags, CoordinatorFeatureFlags.defaults)
        XCTAssertEqual(flags["coordinator"], true)
    }

    func testSnapshotToleratesCorruptFlags() throws {
        let paths = try temporaryPaths()
        try writeCorruptFlags(paths)

        let snapshot = try CoordinatorStatusService(paths: paths).snapshot()

        XCTAssertEqual(snapshot.featureFlags, CoordinatorFeatureFlags.defaults.flags)
    }

    func testSetRepairsCorruptFlags() throws {
        let paths = try temporaryPaths()
        try writeCorruptFlags(paths)

        _ = try CoordinatorFeatureFlagsStore(paths: paths).set("heartbeat", enabled: true)
        let reloaded = try CoordinatorFeatureFlagsStore(paths: paths).load()

        XCTAssertEqual(reloaded["heartbeat"], true)
    }
}
