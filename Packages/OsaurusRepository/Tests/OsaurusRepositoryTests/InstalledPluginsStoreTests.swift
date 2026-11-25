//
//  InstalledPluginsStoreTests.swift
//  OsaurusRepository
//
//  Regression coverage for the dev-mode ("no receipt.json, detect a `.dylib`")
//  validity check: a *directory* or symlink merely named `*.dylib` must not be
//  mistaken for a loadable plugin binary.
//

import Foundation
import XCTest

@testable import OsaurusRepository

final class InstalledPluginsStoreTests: XCTestCase {
    private var tempRoot: URL!
    private var previousOverride: URL?

    override func setUpWithError() throws {
        try super.setUpWithError()
        let fm = FileManager.default
        tempRoot = fm.temporaryDirectory.appendingPathComponent(
            "osaurus-installed-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
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

    // MARK: - Helpers

    /// Creates `<tools>/<pluginId>/<version>/` with no receipt.json and returns the version dir.
    private func makeReceiptlessVersionDir(pluginId: String, version: String) throws -> URL {
        let dir = ToolsPaths.toolsRootDirectory()
            .appendingPathComponent(pluginId, isDirectory: true)
            .appendingPathComponent(version, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - installedVersions dev-mode detection

    /// A version directory whose only `.dylib`-suffixed entry is itself a DIRECTORY
    /// (not a loadable binary) must NOT be treated as an installed version.
    func test_installedVersions_excludesVersionWhoseDylibIsADirectory() throws {
        let dir = try makeReceiptlessVersionDir(pluginId: "devplug", version: "1.0.0")
        // A *directory* named like a dylib — string-suffix matching would wrongly accept it.
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("Plugin.dylib", isDirectory: true),
            withIntermediateDirectories: true
        )

        let versions = InstalledPluginsStore.shared.installedVersions(pluginId: "devplug")
        XCTAssertTrue(
            versions.isEmpty,
            "A directory named *.dylib must not count as a loadable plugin binary"
        )
    }

    /// A real (regular, non-symlink) `.dylib` file with no receipt is the legitimate
    /// "dev mode" install and MUST still be detected (guards against over-correction).
    func test_installedVersions_includesVersionWithRegularDylib() throws {
        let dir = try makeReceiptlessVersionDir(pluginId: "realplug", version: "2.0.0")
        try Data("not a real binary".utf8).write(
            to: dir.appendingPathComponent("Real.dylib", isDirectory: false)
        )

        let versions = InstalledPluginsStore.shared.installedVersions(pluginId: "realplug")
        XCTAssertEqual(
            versions.map(\.description),
            ["2.0.0"],
            "A regular .dylib file is a valid dev-mode install and must be detected"
        )
    }

    // MARK: - latestInstalledVersion current-symlink detection

    /// The `current` symlink fast-path must apply the same regular-file check: a
    /// `current` -> version dir whose only `.dylib` entry is a directory must not
    /// be accepted as the latest installed version.
    func test_latestInstalledVersion_currentSymlinkRejectsDirectoryNamedDylib() throws {
        let dir = try makeReceiptlessVersionDir(pluginId: "devsym", version: "1.0.0")
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("Plugin.dylib", isDirectory: true),
            withIntermediateDirectories: true
        )
        // current -> 1.0.0
        let currentLink = ToolsPaths.toolsRootDirectory()
            .appendingPathComponent("devsym", isDirectory: true)
            .appendingPathComponent("current", isDirectory: false)
        try FileManager.default.createSymbolicLink(
            atPath: currentLink.path,
            withDestinationPath: "1.0.0"
        )

        XCTAssertNil(
            InstalledPluginsStore.shared.latestInstalledVersion(pluginId: "devsym"),
            "current -> a version dir with no real .dylib must not be reported as latest"
        )
    }
}
