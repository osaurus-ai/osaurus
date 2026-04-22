//
//  PluginInstallManagerTests.swift
//  OsaurusRepository
//
//  Regression coverage for the `current` symlink lifecycle:
//    - replacing dangling symlinks (the v1→v2 plugin upgrade bug)
//    - the launch-time self-heal pass
//

import Foundation
import XCTest

@testable import OsaurusRepository

final class PluginInstallManagerTests: XCTestCase {
    private var tempRoot: URL!
    private var previousOverride: URL?

    override func setUpWithError() throws {
        try super.setUpWithError()
        let fm = FileManager.default
        tempRoot = fm.temporaryDirectory.appendingPathComponent(
            "osaurus-tests-\(UUID().uuidString)",
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

    private func pluginDir(_ pluginId: String) -> URL {
        let dir = PluginInstallManager.toolsPluginDirectory(pluginId: pluginId)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeVersionDir(pluginId: String, version: String, withReceipt: Bool = true) throws
        -> URL
    {
        let semver = SemanticVersion.parse(version)!
        let dir = PluginInstallManager.toolsVersionDirectory(pluginId: pluginId, version: semver)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if withReceipt {
            // Minimal receipt that satisfies InstalledPluginsStore's "valid version" check.
            let receipt = PluginReceipt(
                plugin_id: pluginId,
                version: semver,
                installed_at: Date(),
                dylib_filename: "Plugin.dylib",
                dylib_sha256: String(repeating: "0", count: 64),
                platform: "macos",
                arch: "arm64",
                public_keys: nil,
                artifact: .init(
                    url: "https://example.invalid/\(pluginId)-\(version).zip",
                    sha256: String(repeating: "0", count: 64),
                    minisign: nil,
                    size: 0
                )
            )
            let data = try JSONEncoder().encode(receipt)
            try data.write(to: dir.appendingPathComponent("receipt.json", isDirectory: false))
        }
        return dir
    }

    private func sv(_ s: String) -> SemanticVersion { SemanticVersion.parse(s)! }

    // MARK: - updateCurrentSymlink

    /// Reproduces the v1→v2 upgrade bug: `current` points at a deleted version dir
    /// (dangling symlink), and the next `updateCurrentSymlink` must succeed without
    /// throwing the cryptic "file already exists" Cocoa error.
    func test_updateCurrentSymlink_replacesDanglingSymlink() throws {
        let fm = FileManager.default
        let pluginId = "osaurus.time"
        _ = pluginDir(pluginId)
        let link = PluginInstallManager.currentSymlinkURL(pluginId: pluginId)

        // Create the dangling symlink: target version dir does NOT exist.
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "1.0.0")
        XCTAssertFalse(
            fm.fileExists(atPath: link.path),
            "Precondition: fileExists follows symlinks, so a dangling link reports as missing — this is the bug condition the fix must handle."
        )
        XCTAssertNotNil(
            try? fm.destinationOfSymbolicLink(atPath: link.path),
            "Precondition: the symlink itself must exist on disk"
        )

        XCTAssertNoThrow(
            try PluginInstallManager.updateCurrentSymlink(pluginId: pluginId, version: sv("2.0.0"))
        )

        let dest = try fm.destinationOfSymbolicLink(atPath: link.path)
        XCTAssertEqual(dest, "2.0.0")
    }

    func test_updateCurrentSymlink_replacesLiveSymlink() throws {
        let fm = FileManager.default
        let pluginId = "osaurus.time"
        let v1Dir = try makeVersionDir(pluginId: pluginId, version: "1.0.0")
        let link = PluginInstallManager.currentSymlinkURL(pluginId: pluginId)

        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "1.0.0")

        try PluginInstallManager.updateCurrentSymlink(pluginId: pluginId, version: sv("2.0.0"))

        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: link.path), "2.0.0")
        XCTAssertTrue(
            fm.fileExists(atPath: v1Dir.path),
            "Old version directory must not be touched by symlink update"
        )
    }

    func test_updateCurrentSymlink_createsWhenAbsent() throws {
        let fm = FileManager.default
        let pluginId = "osaurus.time"
        _ = pluginDir(pluginId)
        let link = PluginInstallManager.currentSymlinkURL(pluginId: pluginId)
        XCTAssertNil(try? fm.destinationOfSymbolicLink(atPath: link.path))

        try PluginInstallManager.updateCurrentSymlink(pluginId: pluginId, version: sv("1.0.0"))

        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: link.path), "1.0.0")
    }

    func test_updateCurrentSymlink_createsParentDirectoryIfMissing() throws {
        let fm = FileManager.default
        let pluginId = "osaurus.time"
        let link = PluginInstallManager.currentSymlinkURL(pluginId: pluginId)

        // Note: not calling pluginDir() — parent doesn't exist yet.
        XCTAssertFalse(
            fm.fileExists(atPath: PluginInstallManager.toolsPluginDirectory(pluginId: pluginId).path)
        )

        try PluginInstallManager.updateCurrentSymlink(pluginId: pluginId, version: sv("1.0.0"))

        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: link.path), "1.0.0")
    }

    // MARK: - repairDanglingCurrentSymlinks

    func test_repair_repointsToHighestInstalledVersion() throws {
        let fm = FileManager.default
        let pluginId = "osaurus.time"
        _ = try makeVersionDir(pluginId: pluginId, version: "1.0.0")
        _ = try makeVersionDir(pluginId: pluginId, version: "2.0.0")

        let link = PluginInstallManager.currentSymlinkURL(pluginId: pluginId)
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "9.9.9")

        PluginInstallManager.repairDanglingCurrentSymlinks()

        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: link.path), "2.0.0")
    }

    func test_repair_removesLinkWhenNoVersionsRemain() throws {
        let fm = FileManager.default
        let pluginId = "osaurus.time"
        _ = pluginDir(pluginId)
        let link = PluginInstallManager.currentSymlinkURL(pluginId: pluginId)
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "1.0.0")

        PluginInstallManager.repairDanglingCurrentSymlinks()

        XCTAssertNil(try? fm.destinationOfSymbolicLink(atPath: link.path))
    }

    func test_repair_leavesHealthyLinkAlone() throws {
        let fm = FileManager.default
        let pluginId = "osaurus.time"
        _ = try makeVersionDir(pluginId: pluginId, version: "1.0.0")
        let link = PluginInstallManager.currentSymlinkURL(pluginId: pluginId)
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "1.0.0")

        PluginInstallManager.repairDanglingCurrentSymlinks()

        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: link.path), "1.0.0")
    }

    func test_repair_isIdempotent() throws {
        let fm = FileManager.default
        let pluginId = "osaurus.time"
        _ = try makeVersionDir(pluginId: pluginId, version: "1.0.0")
        let link = PluginInstallManager.currentSymlinkURL(pluginId: pluginId)
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "9.9.9")

        PluginInstallManager.repairDanglingCurrentSymlinks()
        PluginInstallManager.repairDanglingCurrentSymlinks()

        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: link.path), "1.0.0")
    }

    func test_repair_handlesMissingToolsRoot() {
        // Fresh tempRoot; Tools/ directory does not yet exist.
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: ToolsPaths.toolsRootDirectory().path)
        )
        // Must not throw.
        PluginInstallManager.repairDanglingCurrentSymlinks()
    }
}
