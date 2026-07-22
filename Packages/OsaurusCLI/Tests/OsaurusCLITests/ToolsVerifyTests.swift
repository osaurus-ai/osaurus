//
//  ToolsVerifyTests.swift
//  osaurus
//
//  Regression coverage for `osaurus tools verify`: missing/unreadable/
//  malformed receipts and dylibs must be reported as failures instead of
//  being silently skipped (which let broken installs verify clean).
//

import CryptoKit
import Foundation
import OsaurusRepository
import XCTest

@testable import OsaurusCLICore

final class ToolsVerifyTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-tools-verify-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        try super.tearDownWithError()
    }

    private func makeVersionDir(pluginId: String, version: String) throws -> URL {
        let dir = root.appendingPathComponent(pluginId, isDirectory: true)
            .appendingPathComponent(version, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeValidInstall(pluginId: String, version: String, dylibContents: String = "binary") throws
        -> URL
    {
        let dir = try makeVersionDir(pluginId: pluginId, version: version)
        let dylibData = Data(dylibContents.utf8)
        try dylibData.write(to: dir.appendingPathComponent("Plugin.dylib"))
        let sha = Data(SHA256.hash(data: dylibData)).map { String(format: "%02x", $0) }.joined()
        let receipt = PluginReceipt(
            plugin_id: pluginId,
            version: SemanticVersion.parse(version)!,
            installed_at: Date(),
            dylib_filename: "Plugin.dylib",
            dylib_sha256: sha,
            platform: "macos",
            arch: "arm64",
            public_keys: nil,
            artifact: .init(url: "file:///dev/null", sha256: sha, minisign: nil, size: dylibData.count)
        )
        try JSONEncoder().encode(receipt).write(to: dir.appendingPathComponent("receipt.json"))
        return dir
    }

    func testHealthyInstallVerifiesClean() throws {
        _ = try writeValidInstall(pluginId: "com.example.good", version: "1.0.0")

        let report = ToolsVerify.verifyInstalledTools(root: root)

        XCTAssertEqual(report.failures, 0)
        XCTAssertEqual(report.lines.count, 1)
        XCTAssertTrue(report.lines[0].hasPrefix("OK"))
    }

    func testMissingReceiptIsAFailure() throws {
        let dir = try makeVersionDir(pluginId: "com.example.noreceipt", version: "1.0.0")
        try Data("binary".utf8).write(to: dir.appendingPathComponent("Plugin.dylib"))

        let report = ToolsVerify.verifyInstalledTools(root: root)

        XCTAssertEqual(report.failures, 1)
        XCTAssertTrue(report.lines[0].contains("receipt.json missing"))
    }

    func testMalformedReceiptIsAFailure() throws {
        let dir = try makeVersionDir(pluginId: "com.example.badreceipt", version: "1.0.0")
        try Data("not json".utf8).write(to: dir.appendingPathComponent("receipt.json"))

        let report = ToolsVerify.verifyInstalledTools(root: root)

        XCTAssertEqual(report.failures, 1)
        XCTAssertTrue(report.lines[0].contains("receipt.json malformed"))
    }

    func testMissingDylibIsAFailure() throws {
        let dir = try writeValidInstall(pluginId: "com.example.nodylib", version: "1.0.0")
        try FileManager.default.removeItem(at: dir.appendingPathComponent("Plugin.dylib"))

        let report = ToolsVerify.verifyInstalledTools(root: root)

        XCTAssertEqual(report.failures, 1)
        XCTAssertTrue(report.lines[0].contains("Plugin.dylib missing"))
    }

    func testShaMismatchIsAFailure() throws {
        let dir = try writeValidInstall(pluginId: "com.example.tampered", version: "1.0.0")
        try Data("tampered".utf8).write(to: dir.appendingPathComponent("Plugin.dylib"))

        let report = ToolsVerify.verifyInstalledTools(root: root)

        XCTAssertEqual(report.failures, 1)
        XCTAssertTrue(report.lines[0].contains("expected"))
    }

    func testDanglingCurrentSymlinkIsAFailure() throws {
        _ = try writeValidInstall(pluginId: "com.example.dangling", version: "1.0.0")
        let pluginDir = root.appendingPathComponent("com.example.dangling", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            atPath: pluginDir.appendingPathComponent("current").path,
            withDestinationPath: "9.9.9"
        )

        let report = ToolsVerify.verifyInstalledTools(root: root)

        XCTAssertEqual(report.failures, 1)
        XCTAssertTrue(report.lines[0].contains("missing version 9.9.9"))
    }

    func testHealthyCurrentSymlinkChecksOnlyThatVersion() throws {
        _ = try writeValidInstall(pluginId: "com.example.linked", version: "1.0.0")
        _ = try writeValidInstall(pluginId: "com.example.linked", version: "2.0.0")
        let pluginDir = root.appendingPathComponent("com.example.linked", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            atPath: pluginDir.appendingPathComponent("current").path,
            withDestinationPath: "2.0.0"
        )

        let report = ToolsVerify.verifyInstalledTools(root: root)

        XCTAssertEqual(report.failures, 0)
        XCTAssertEqual(report.lines.count, 1)
    }
}
