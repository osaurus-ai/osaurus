//
//  ScreenContextSettingsTests.swift
//  OsaurusCoreTests — Computer Use
//
//  The screen-context opt-in must default OFF and persist across instances,
//  so a relaunch never silently starts sampling the screen.
//

import Foundation
import XCTest

@testable import OsaurusCore

@MainActor
final class ScreenContextSettingsTests: XCTestCase {
    func testDefaultsOff() {
        let suite = "screen-context-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = ScreenContextSettings(defaults: defaults)
        XCTAssertFalse(settings.injectionEnabled)
    }

    func testSetEnabledPersistsAcrossInstances() {
        let suite = "screen-context-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = ScreenContextSettings(defaults: defaults)
        settings.setEnabled(true)
        XCTAssertTrue(settings.injectionEnabled)
        XCTAssertTrue(ScreenContextSettings(defaults: defaults).injectionEnabled)

        settings.setEnabled(false)
        XCTAssertFalse(settings.injectionEnabled)
        XCTAssertFalse(ScreenContextSettings(defaults: defaults).injectionEnabled)
    }
}
