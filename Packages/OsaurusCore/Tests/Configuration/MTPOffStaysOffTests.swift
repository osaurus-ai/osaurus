//
//  MTPOffStaysOffTests.swift
//  OsaurusCoreTests
//
//  Turning native MTP off did not stay off.
//
//  Native MTP defaults Off. Both current settings and legacy settings must
//  preserve Off through the real store load path, including repeated reloads.
//  These regressions cover the retired Off-to-Auto migration.
//

import Foundation
import MLXLMCommon
import XCTest

@testable import OsaurusCore

final class MTPOffStaysOffTests: XCTestCase {

    private var root: URL!
    /// Whatever `OSAURUS_TEST_ROOT` was before this suite ran. CI may set it
    /// globally, and unsetting it unconditionally in tearDown would strip it
    /// for every test that runs afterwards — server tests then fail with
    /// `.notRunning`, far from the suite that caused it.
    private var previousTestRoot: String?

    private func settingsFileURL() -> URL {
        root.appendingPathComponent("config/server-runtime.json")
    }

    override func setUpWithError() throws {
        previousTestRoot = ProcessInfo.processInfo.environment["OSAURUS_TEST_ROOT"]
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mtp-off-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("config"), withIntermediateDirectories: true)
        setenv("OSAURUS_TEST_ROOT", root.path, 1)
    }

    override func tearDownWithError() throws {
        if let previousTestRoot {
            setenv("OSAURUS_TEST_ROOT", previousTestRoot, 1)
        } else {
            unsetenv("OSAURUS_TEST_ROOT")
        }
        try? FileManager.default.removeItem(at: root)
    }

    /// A settings file shaped like a user who opened Settings, switched native
    /// MTP off, and changed nothing else. `schemaVersion` is current, so this
    /// is NOT a legacy install needing repair.
    private func writeUserTurnedMTPOff() throws {
        var settings = VMLXServerRuntimeSettings()
        settings.schemaVersion = VMLXServerRuntimeSettings.contractVersion
        settings.mtp.mode = .off
        let data = try JSONEncoder().encode(settings)
        try data.write(to: settingsFileURL())
    }

    /// THE test: off must still be off after a reload.
    func testUserChoiceOfOffSurvivesReload() throws {
        try writeUserTurnedMTPOff()

        let loaded = try XCTUnwrap(ServerRuntimeSettingsStore.load())

        XCTAssertEqual(
            loaded.mtp.mode, .off,
            "load() flipped the user's explicit MTP off back to auto")
    }

    /// And it must survive REPEATED reloads — the failure mode is a repair
    /// that re-fires every time, so one reload could pass by luck.
    func testOffSurvivesRepeatedReloads() throws {
        try writeUserTurnedMTPOff()

        for attempt in 1...3 {
            let loaded = try XCTUnwrap(ServerRuntimeSettingsStore.load())
            XCTAssertEqual(
                loaded.mtp.mode, .off,
                "MTP mode was rewritten to auto on reload #\(attempt)")
        }
    }

    /// Legacy settings also remain opt-in; schema migration must not activate MTP.
    func testLegacyInstallKeepsMTPOff() throws {
        var settings = VMLXServerRuntimeSettings()
        settings.schemaVersion = nil
        settings.mtp.mode = .off
        try JSONEncoder().encode(settings).write(to: settingsFileURL())
        for _ in 0..<3 {
            XCTAssertEqual(try XCTUnwrap(ServerRuntimeSettingsStore.load()).mtp.mode, .off)
        }
    }
}
