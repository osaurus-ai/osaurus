//
//  ManagementStateManagerMinimumSizeTests.swift
//  osaurusTests
//
//  The settings root view's `.frame(minWidth:minHeight:)` floor is mirrored
//  into the window's `contentMinSize`, so it must never exceed what the
//  window's screen can show: a 1024x666 display otherwise gets a window
//  AppKit cannot shrink to fit, with its title bar under the menu bar and
//  the bottom of the sidebar cut off. Regression coverage for #2761.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct ManagementStateManagerMinimumSizeTests {

    /// The manager is a process-wide singleton, so every test restores the
    /// design minimum on exit to keep the suite order-independent.
    private func withManager(_ body: (ManagementStateManager) -> Void) {
        let manager = ManagementStateManager.shared
        defer { manager.updateMinimumContentSize(availableContentSize: .zero) }
        manager.updateMinimumContentSize(availableContentSize: .zero)
        body(manager)
    }

    @Test("starts at the design minimum")
    func initialFloor_isDesignMinimum() {
        withManager { manager in
            #expect(manager.minimumContentSize == ManagementStateManager.designMinimumContentSize)
            #expect(ManagementStateManager.designMinimumContentSize == CGSize(width: 940, height: 640))
        }
    }

    @Test("a screen larger than the design minimum keeps it verbatim")
    func largeScreen_keepsDesignMinimum() {
        withManager { manager in
            manager.updateMinimumContentSize(availableContentSize: CGSize(width: 1512, height: 900))
            #expect(manager.minimumContentSize == ManagementStateManager.designMinimumContentSize)
        }
    }

    @Test("a small screen clamps the floor to what it can show")
    func smallScreen_clampsFloor() {
        withManager { manager in
            // 13" MacBook Air at "Larger Text": 1024x666 screen, 25pt menu
            // bar, 28pt titlebar chrome -> 613pt of content height.
            manager.updateMinimumContentSize(availableContentSize: CGSize(width: 1024, height: 613.5))
            #expect(manager.minimumContentSize == CGSize(width: 940, height: 613))
        }
    }

    @Test("both axes clamp independently")
    func narrowAndShortScreen_clampsBothAxes() {
        withManager { manager in
            manager.updateMinimumContentSize(availableContentSize: CGSize(width: 800, height: 500))
            #expect(manager.minimumContentSize == CGSize(width: 800, height: 500))
        }
    }

    @Test("moving back to a large screen restores the design minimum")
    func largerScreen_restoresDesignMinimum() {
        withManager { manager in
            manager.updateMinimumContentSize(availableContentSize: CGSize(width: 1024, height: 613))
            manager.updateMinimumContentSize(availableContentSize: CGSize(width: 1920, height: 1055))
            #expect(manager.minimumContentSize == ManagementStateManager.designMinimumContentSize)
        }
    }

    @Test("a missing or degenerate measurement leaves the floor alone")
    func zeroMeasurement_isIgnored() {
        withManager { manager in
            manager.updateMinimumContentSize(availableContentSize: CGSize(width: 1024, height: 613))
            manager.updateMinimumContentSize(availableContentSize: .zero)
            // No screen known: each axis keeps the design value rather than
            // collapsing to zero.
            #expect(manager.minimumContentSize == ManagementStateManager.designMinimumContentSize)
            manager.updateMinimumContentSize(availableContentSize: CGSize(width: -10, height: 400))
            #expect(manager.minimumContentSize == CGSize(width: 940, height: 400))
        }
    }
}
