//
//  PluginInstallManagerTests.swift
//  OsaurusRepository
//
//  Regression coverage for the `current` symlink lifecycle:
//    - atomic publication and rollback when the pointer swap fails
//    - replacing dangling symlinks (the v1→v2 plugin upgrade bug)
//    - the launch-time self-heal pass
//

import Foundation
import XCTest

@testable import OsaurusRepository

final class PluginInstallManagerTests: XCTestCase {
    private enum PublicationFailure: Error {
        case injected
    }

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

    private func stagedCurrentEntries(pluginId: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(
            atPath: PluginInstallManager.toolsPluginDirectory(pluginId: pluginId).path
        ).filter { $0.hasPrefix(".current.") && $0.hasSuffix(".tmp") }
    }

    private func assertLayoutInvalid(
        _ error: Error,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let installError = error as? PluginInstallError else {
            return XCTFail("Expected PluginInstallError, got \(error)", file: file, line: line)
        }
        guard case .layoutInvalid = installError else {
            return XCTFail("Expected layoutInvalid, got \(installError)", file: file, line: line)
        }
    }

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
        XCTAssertEqual(try stagedCurrentEntries(pluginId: pluginId), [])
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

    func test_updateCurrentSymlink_replacesRegularFileAtomically() throws {
        let fm = FileManager.default
        let pluginId = "osaurus.time"
        _ = pluginDir(pluginId)
        let link = PluginInstallManager.currentSymlinkURL(pluginId: pluginId)
        try Data("stale".utf8).write(to: link)

        try PluginInstallManager.updateCurrentSymlink(pluginId: pluginId, version: sv("1.0.0"))

        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: link.path), "1.0.0")
        XCTAssertEqual(try stagedCurrentEntries(pluginId: pluginId), [])
    }

    func test_replaceCurrentSymlink_failedCommitPreservesLivePointer() throws {
        let fm = FileManager.default
        let pluginId = "osaurus.rollback"
        let oldVersion = try makeVersionDir(pluginId: pluginId, version: "1.0.0")
        _ = try makeVersionDir(pluginId: pluginId, version: "2.0.0")
        let link = PluginInstallManager.currentSymlinkURL(pluginId: pluginId)
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "1.0.0")
        var commitAttempted = false

        XCTAssertThrowsError(
            try PluginInstallManager.replaceCurrentSymlink(
                pluginId: pluginId,
                version: sv("2.0.0")
            ) { stagedPath, currentPath in
                commitAttempted = true
                XCTAssertEqual(
                    try fm.destinationOfSymbolicLink(atPath: stagedPath),
                    "2.0.0"
                )
                XCTAssertEqual(currentPath, link.path)
                throw PublicationFailure.injected
            }
        ) { error in
            self.assertLayoutInvalid(error)
        }

        XCTAssertTrue(commitAttempted)
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: link.path), "1.0.0")
        XCTAssertTrue(fm.fileExists(atPath: oldVersion.path))
        XCTAssertEqual(try stagedCurrentEntries(pluginId: pluginId), [])
    }

    func test_replaceCurrentSymlink_failedFirstCommitLeavesPointerAbsent() throws {
        let fm = FileManager.default
        let pluginId = "osaurus.first-publication"
        _ = pluginDir(pluginId)
        let link = PluginInstallManager.currentSymlinkURL(pluginId: pluginId)

        XCTAssertThrowsError(
            try PluginInstallManager.replaceCurrentSymlink(
                pluginId: pluginId,
                version: sv("1.0.0")
            ) { _, _ in
                throw PublicationFailure.injected
            }
        ) { error in
            self.assertLayoutInvalid(error)
        }

        XCTAssertNil(try? fm.destinationOfSymbolicLink(atPath: link.path))
        XCTAssertEqual(try stagedCurrentEntries(pluginId: pluginId), [])
    }

    func test_replaceCurrentSymlink_failedCommitPreservesDanglingPointer() throws {
        let fm = FileManager.default
        let pluginId = "osaurus.dangling-rollback"
        _ = pluginDir(pluginId)
        let link = PluginInstallManager.currentSymlinkURL(pluginId: pluginId)
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "1.0.0")
        XCTAssertFalse(fm.fileExists(atPath: link.path))

        XCTAssertThrowsError(
            try PluginInstallManager.replaceCurrentSymlink(
                pluginId: pluginId,
                version: sv("2.0.0")
            ) { _, _ in
                throw PublicationFailure.injected
            }
        ) { error in
            self.assertLayoutInvalid(error)
        }

        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: link.path), "1.0.0")
        XCTAssertEqual(try stagedCurrentEntries(pluginId: pluginId), [])
    }

    func test_updateCurrentSymlink_refusesToReplaceDirectory() throws {
        let fm = FileManager.default
        let pluginId = "osaurus.invalid-current"
        let link = PluginInstallManager.currentSymlinkURL(pluginId: pluginId)
        try fm.createDirectory(at: link, withIntermediateDirectories: true)
        let marker = link.appendingPathComponent("keep.txt", isDirectory: false)
        try Data("keep".utf8).write(to: marker)

        XCTAssertThrowsError(
            try PluginInstallManager.updateCurrentSymlink(
                pluginId: pluginId,
                version: sv("2.0.0")
            )
        ) { error in
            self.assertLayoutInvalid(error)
        }

        XCTAssertTrue(fm.fileExists(atPath: marker.path))
        XCTAssertNil(try? fm.destinationOfSymbolicLink(atPath: link.path))
        XCTAssertEqual(try stagedCurrentEntries(pluginId: pluginId), [])
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

    // MARK: - artifact download bounds

    func test_validatedDeclaredArtifactSize_rejectsOversizedManifestValue() {
        let tooLarge = Int(PluginInstallManager.maximumArtifactArchiveBytes + 1)

        XCTAssertThrowsError(
            try PluginInstallManager.validatedDeclaredArtifactSize(tooLarge)
        ) { error in
            XCTAssertTrue(
                String(describing: error).contains("install limit"),
                "Oversized registry values should fail before network or disk work begins"
            )
        }
    }

    func test_validatedDeclaredArtifactSize_rejectsNegativeManifestValue() {
        XCTAssertThrowsError(
            try PluginInstallManager.validatedDeclaredArtifactSize(-1)
        ) { error in
            XCTAssertTrue(
                String(describing: error).contains("negative"),
                "Negative registry sizes are malformed, not an unknown length"
            )
        }
    }

    func test_validateArtifactSize_rejectsOversizedContentLength() {
        XCTAssertThrowsError(
            try PluginInstallManager.validateArtifactSize(
                declaredSize: nil,
                responseSize: PluginInstallManager.maximumArtifactArchiveBytes + 1,
                actualSize: nil
            )
        ) { error in
            XCTAssertTrue(
                String(describing: error).contains("response"),
                "A too-large Content-Length should be rejected before the installer persists the archive"
            )
        }
    }

    func test_validateArtifactSize_rejectsDeclaredResponseMismatch() {
        XCTAssertThrowsError(
            try PluginInstallManager.validateArtifactSize(
                declaredSize: 128,
                responseSize: 127,
                actualSize: nil
            )
        ) { error in
            XCTAssertTrue(
                String(describing: error).contains("response size mismatch"),
                "Registry size and server Content-Length must agree for immutable plugin artifacts"
            )
        }
    }

    func test_validateArtifactSize_rejectsDeclaredActualMismatch() {
        XCTAssertThrowsError(
            try PluginInstallManager.validateArtifactSize(
                declaredSize: 128,
                responseSize: nil,
                actualSize: 129
            )
        ) { error in
            XCTAssertTrue(
                String(describing: error).contains("archive size mismatch"),
                "The final archive size is authoritative when the server omits Content-Length"
            )
        }
    }

    func test_validateArtifactSize_allowsUnknownDeclaredSizeWithinLimit() throws {
        XCTAssertNoThrow(
            try PluginInstallManager.validateArtifactSize(
                declaredSize: nil,
                responseSize: nil,
                actualSize: PluginInstallManager.maximumArtifactArchiveBytes
            )
        )
    }

    func test_sha256Hex_readsFileFromDisk() throws {
        let url = tempRoot.appendingPathComponent("artifact.zip", isDirectory: false)
        try Data("osaurus".utf8).write(to: url)

        let digest = try PluginInstallManager.sha256Hex(ofFile: url)

        XCTAssertEqual(digest, "76f6ce2a444b4bfcfa21c40ac4df5adc5f4e897fdeb28c3211d69252d09304ca")
    }

    func test_isRegularPayloadFile_acceptsRegularFiles() throws {
        let url = tempRoot.appendingPathComponent("Plugin.dylib", isDirectory: false)
        try Data("binary".utf8).write(to: url)

        XCTAssertTrue(PluginInstallManager.isRegularPayloadFile(url))
    }

    func test_isRegularPayloadFile_rejectsSymlinkedPayloads() throws {
        let target = tempRoot.appendingPathComponent("outside.dylib", isDirectory: false)
        let link = tempRoot.appendingPathComponent("Plugin.dylib", isDirectory: false)
        try Data("binary".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)

        XCTAssertFalse(PluginInstallManager.isRegularPayloadFile(link))
    }
}
