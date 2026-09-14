//
//  MTPOffStaysOffTests.swift
//  OsaurusCoreTests
//
//  Turning native MTP off did not stay off.
//
//  `ServerRuntimeSettingsStore` used to carry a repair for installs that persisted
//  the pre-e095d0f engine default ("MTP off") before the default became
//  "auto". It fires whenever `mode == .off` and the other three MTP fields are
//  at their defaults — which is ALSO exactly the shape of a user who just
//  toggled MTP off and touched nothing else. The repair cannot tell those two
//  apart, it ran on every `load()`, and `load()` persists what it changed. So
//  the user's choice was silently rewritten to `.auto`, permanently.
//
//  Off is now the product default. Neither current nor legacy Off may be
//  rewritten to Auto. Factory Auto/family D3 retirement is tested separately.
//
//  These go through the store's real load path, because a test that calls the
//  normalizer directly would prove it is correct, not that the user's setting
//  survives.
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

    /// Old Off is also Off: a schema migration is not an activation request.
    func testLegacyInstallKeepsMTPOff() throws {
        var settings = VMLXServerRuntimeSettings()
        settings.schemaVersion = nil  // never migrated
        settings.mtp.mode = .off
        let data = try JSONEncoder().encode(settings)
        try data.write(to: settingsFileURL())

        let loaded = try XCTUnwrap(ServerRuntimeSettingsStore.load())

        XCTAssertEqual(
            loaded.mtp.mode, .off,
            "a legacy settings migration silently enabled MTP")
    }
}
