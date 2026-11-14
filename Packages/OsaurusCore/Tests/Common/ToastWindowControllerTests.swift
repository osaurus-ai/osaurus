//
//  ToastWindowControllerTests.swift
//  OsaurusCoreTests
//

import Foundation
import Testing

@testable import OsaurusCore

/// Guards APPLE-MACOS-13C: creating the screen-sized toast NSPanel performs a
/// synchronous WindowServer round-trip, so it must not happen during launch.
@Suite(.serialized)
@MainActor
struct ToastWindowControllerTests {
    @Test func setupDoesNotCreatePanelEagerly() {
        let controller = ToastWindowController.shared
        controller.teardown()
        controller.setup()
        #expect(controller.hasPanel == false)
        controller.teardown()
    }

    @Test func showOverlayIsNoOpBeforeSetup() {
        let controller = ToastWindowController.shared
        controller.teardown()
        controller.showOverlayIfNeeded()
        #expect(controller.hasPanel == false)
    }
}
