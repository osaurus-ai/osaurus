//
//  ScreenshotScopeTests.swift
//  OsaurusCoreTests — Computer Use
//
//  A capture scoped to an app or window never widens to a whole display: a
//  quit target would otherwise hand the model whatever app is on screen.
//

import XCTest

@testable import OsaurusCore

final class ScreenshotScopeTests: XCTestCase {

    func testAppScopedCaptureNeverFallsBackToTheDisplay() {
        var options = ScreenshotOptions()
        options.pid = 4242
        XCTAssertFalse(ScreenshotController.capturesDisplay(options))
    }

    func testWindowScopedCaptureNeverFallsBackToTheDisplay() {
        var options = ScreenshotOptions()
        options.windowId = 99
        XCTAssertFalse(ScreenshotController.capturesDisplay(options))
    }

    func testUnscopedCaptureTakesTheDisplay() {
        XCTAssertTrue(ScreenshotController.capturesDisplay(ScreenshotOptions()))
    }
}
