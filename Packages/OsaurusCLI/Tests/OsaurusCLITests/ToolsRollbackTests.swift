//
//  ToolsRollbackTests.swift
//  osaurus
//
//  `tools rollback` must step down from the *currently active* version (the
//  `current` symlink), not blindly from the highest installed version.
//

import Foundation
import XCTest

import OsaurusRepository

@testable import OsaurusCLICore

final class ToolsRollbackTests: XCTestCase {
    private let pluginId = "osaurus.example"
    private var tempRoot: URL!
    private var previousOverride: URL?

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-rollback-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        previousOverride = ToolsPaths.overrideRoot
        ToolsPaths.overrideRoot = tempRoot
    }

    override func tearDownWithError() throws {
        ToolsPaths.overrideRoot = previousOverride
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        try super.tearDownWithError()
    }

    private func makeVersion(_ version: String) throws {
        let semver = try XCTUnwrap(SemanticVersion.parse(version))
        let dir = PluginInstallManager.toolsVersionDirectory(pluginId: pluginId, version: semver)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // A .dylib is enough for installedVersions to treat the dir as installed.
        try Data().write(to: dir.appendingPathComponent("Plugin.dylib", isDirectory: false))
    }

    private func setCurrent(_ version: String) throws {
        try PluginInstallManager.updateCurrentSymlink(
            pluginId: pluginId,
            version: try XCTUnwrap(SemanticVersion.parse(version))
        )
    }

    /// The active version diverges from the highest installed one (e.g. after a
    /// previous rollback, or a newer version installed without moving `current`).
    /// Rollback must target the version below the active one, not the active
    /// version itself.
    func test_rollsBackBelowActiveVersion_notSecondHighest() throws {
        try makeVersion("3.0.0")
        try makeVersion("2.0.0")
        try makeVersion("1.0.0")
        try setCurrent("2.0.0")

        XCTAssertEqual(ToolsRollback.previousVersion(pluginId: pluginId), SemanticVersion.parse("1.0.0"))
    }

    /// Common case: when `current` is the highest version, behavior is unchanged
    /// (roll back to the second-highest).
    func test_commonCase_activeIsHighest_rollsBackToSecondHighest() throws {
        try makeVersion("3.0.0")
        try makeVersion("2.0.0")
        try makeVersion("1.0.0")
        try setCurrent("3.0.0")

        XCTAssertEqual(ToolsRollback.previousVersion(pluginId: pluginId), SemanticVersion.parse("2.0.0"))
    }

    /// When the active version is already the oldest, there is nothing below it.
    func test_activeIsOldest_hasNoPreviousVersion() throws {
        try makeVersion("2.0.0")
        try makeVersion("1.0.0")
        try setCurrent("1.0.0")

        XCTAssertNil(ToolsRollback.previousVersion(pluginId: pluginId))
    }
}
