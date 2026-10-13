//
//  ManagementWindowFloorTests.swift
//  osaurusTests
//
//  Regression coverage for Sentry APPLE-MACOS-1ZM (NSGenericException
//  "more Update Constraints in Window passes than there are views"): the
//  settings window's hosting controller must not let SwiftUI drive the
//  window frame — no `NSHostingSizingOptions` at all — while the floor the
//  root enforces still reaches `contentMinSize` through the controller's
//  `preferredMinimumSize`, and keeps following the screen-clamped value
//  `ManagementStateManager` publishes.
//

import AppKit
import SwiftUI
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct ManagementWindowFloorTests {

    /// Creates the settings window the way the app does and tears it down
    /// so the shared manager is left as found.
    private func withManagementWindow(_ body: (NSWindow, ManagementStateManager) throws -> Void) throws {
        let manager = ManagementStateManager.shared
        let windowManager = WindowManager.shared
        manager.updateMinimumContentSize(availableContentSize: .zero)
        let window = windowManager.createWindow(config: .management) {
            Color.clear.frame(
                minWidth: manager.minimumContentSize.width,
                maxWidth: .infinity,
                minHeight: manager.minimumContentSize.height,
                maxHeight: .infinity)
        }
        defer {
            windowManager.unregister(.management)
            window.contentViewController = nil
            window.close()
            manager.updateMinimumContentSize(availableContentSize: .zero)
        }
        try body(window, manager)
    }

    private func chrome(of window: NSWindow) -> CGFloat {
        max(0, window.frame.height - window.contentLayoutRect.height)
    }

    @Test("the settings window gives SwiftUI no sizing options")
    func hostingControllerHasNoSizingOptions() throws {
        try withManagementWindow { window, _ in
            let host = try #require(window.contentViewController as? any AppKitOwnedWindowHosting)
            #expect(host.effectiveSizingOptions.isEmpty)
        }
    }

    @Test("the AppKit floor equals the clamped root floor plus titlebar chrome")
    func contentMinSizeMirrorsClampedFloor() throws {
        try withManagementWindow { window, manager in
            window.layoutIfNeeded()
            let expected = manager.minimumContentSize
            #expect(window.contentMinSize.width == expected.width)
            #expect(window.contentMinSize.height == expected.height + chrome(of: window))
            #expect(expected == ManagementStateManager.designMinimumContentSize)
        }
    }

    @Test("re-clamping the floor for a smaller screen updates contentMinSize without SwiftUI")
    func contentMinSizeFollowsPublishedFloor() throws {
        try withManagementWindow { window, manager in
            window.layoutIfNeeded()
            manager.updateMinimumContentSize(availableContentSize: CGSize(width: 800, height: 500))
            // The subscription delivers on the main run loop; drain one turn.
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            #expect(manager.minimumContentSize == CGSize(width: 800, height: 500))
            #expect(window.contentMinSize.width == 800)
            #expect(window.contentMinSize.height == 500 + chrome(of: window))
        }
    }

    @Test("layout passes never move the window frame when it is below the floor")
    func layoutDoesNotResizeWindowBelowFloor() throws {
        // With `.minSize` on, `NSHostingView.windowDidLayout` resized a window
        // that was smaller than the root's floor; a floor the screen clamps
        // straight back made that a loop. The frame must now be AppKit's alone.
        try withManagementWindow { window, _ in
            let small = NSRect(x: 100, y: 100, width: 300, height: 200)
            window.setFrame(small, display: false)
            for _ in 0 ..< 5 {
                window.layoutIfNeeded()
                window.contentView?.layoutSubtreeIfNeeded()
            }
            #expect(window.frame == small)
        }
    }

    @Test("the deeplink replacement controller is the same AppKit-owned kind")
    func replacementControllerHasNoSizingOptions() throws {
        let controller = WindowManager.shared.makeHostingController(for: .management, rootView: Color.clear)
        defer { WindowManager.shared.unregister(.management) }
        let host = try #require(controller as? any AppKitOwnedWindowHosting)
        #expect(host.effectiveSizingOptions.isEmpty)
        #expect(host.minimumContentSize == ManagementStateManager.shared.minimumContentSize)
    }
}
