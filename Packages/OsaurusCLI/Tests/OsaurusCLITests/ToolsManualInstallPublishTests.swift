//
//  ToolsManualInstallPublishTests.swift
//  osaurus
//
//  Regression coverage for the manual `tools install` publication path:
//  transactional replacement, explicit consent, and mandatory dylib/receipt.
//

import CryptoKit
import Foundation
import OsaurusRepository
import XCTest

@testable import OsaurusCLICore

final class ToolsManualInstallPublishTests: XCTestCase {
    private var tempRoot: URL!
    private var previousOverride: URL?

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-manual-publish-tests-\(UUID().uuidString)", isDirectory: true)
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

    private func makePayload(named name: String, dylibContents: String = "binary") throws -> URL {
        let payload = tempRoot.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        try Data(dylibContents.utf8).write(to: payload.appendingPathComponent("Plugin.dylib"))
        return payload
    }

    func testPublishInstallsReceiptAndSymlinkWithoutConsentByDefault() throws {
        let payload = try makePayload(named: "payload")
        let version = try XCTUnwrap(SemanticVersion.parse("1.0.0"))

        let installDir = try ToolsInstall.publishManualInstall(
            pluginRoot: payload,
            pluginId: "com.example.manual",
            version: version,
            grantConsent: false
        )

        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: installDir.appendingPathComponent("Plugin.dylib").path))
        XCTAssertTrue(fm.fileExists(atPath: installDir.appendingPathComponent("receipt.json").path))
        XCTAssertFalse(
            fm.fileExists(atPath: installDir.appendingPathComponent(".user_consent").path),
            "manual installs must not grant consent implicitly"
        )
        XCTAssertEqual(
            try fm.destinationOfSymbolicLink(
                atPath: PluginInstallManager.currentSymlinkURL(pluginId: "com.example.manual").path
            ),
            "1.0.0"
        )
        XCTAssertFalse(fm.fileExists(atPath: payload.path), "staged payload should have been moved into place")
    }

    func testPublishGrantsConsentOnlyWhenExplicitlyRequested() throws {
        let payload = try makePayload(named: "payload-consent")
        let version = try XCTUnwrap(SemanticVersion.parse("1.0.0"))

        let installDir = try ToolsInstall.publishManualInstall(
            pluginRoot: payload,
            pluginId: "com.example.consent",
            version: version,
            grantConsent: true
        )

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: installDir.appendingPathComponent(".user_consent").path)
        )
    }

    func testPublishReplacesExistingVersionAtomicallyAndKeepsItOnFailure() throws {
        let fm = FileManager.default
        let version = try XCTUnwrap(SemanticVersion.parse("1.0.0"))
        let pluginId = "com.example.replace"

        // First install
        let first = try makePayload(named: "first", dylibContents: "old-binary")
        let installDir = try ToolsInstall.publishManualInstall(
            pluginRoot: first,
            pluginId: pluginId,
            version: version,
            grantConsent: false
        )
        let oldDylib = try Data(contentsOf: installDir.appendingPathComponent("Plugin.dylib"))
        XCTAssertEqual(oldDylib, Data("old-binary".utf8))

        // A broken payload (no dylib) must fail BEFORE touching the existing install
        let broken = tempRoot.appendingPathComponent("broken", isDirectory: true)
        try fm.createDirectory(at: broken, withIntermediateDirectories: true)
        XCTAssertThrowsError(
            try ToolsInstall.publishManualInstall(
                pluginRoot: broken,
                pluginId: pluginId,
                version: version,
                grantConsent: false
            )
        )
        XCTAssertEqual(
            try Data(contentsOf: installDir.appendingPathComponent("Plugin.dylib")),
            Data("old-binary".utf8),
            "failed install must leave the existing version untouched"
        )

        // A valid payload replaces it
        let second = try makePayload(named: "second", dylibContents: "new-binary")
        _ = try ToolsInstall.publishManualInstall(
            pluginRoot: second,
            pluginId: pluginId,
            version: version,
            grantConsent: false
        )
        XCTAssertEqual(
            try Data(contentsOf: installDir.appendingPathComponent("Plugin.dylib")),
            Data("new-binary".utf8)
        )

        // No staging leftovers next to the version directories
        let leftovers = try fm.contentsOfDirectory(atPath: installDir.deletingLastPathComponent().path)
            .filter { $0.hasPrefix(".staging-") }
        XCTAssertTrue(leftovers.isEmpty)
    }
}
