//
//  NotchPanelPlacementTests.swift
//  osaurusTests
//
//  Regression tests for task-progress notch overlay placement. API-dispatched
//  background tasks render here; the panel must stay below the macOS menu bar.
//

import AppKit
import CoreGraphics
import Testing

@testable import OsaurusCore

struct NotchPanelPlacementTests {
    @Test @MainActor func notchPanelCanBecomeKeyForInlineTextInput() {
        let panel = NotchPanel(
            contentRect: CGRect(x: 0, y: 0, width: 600, height: 500),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        let field = NSTextField(frame: CGRect(x: 20, y: 20, width: 200, height: 28))
        panel.contentView = NSView(frame: panel.contentRect(forFrameRect: panel.frame))
        panel.contentView?.addSubview(field)

        #expect(panel.canBecomeKey)
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        panel.makeKeyAndOrderFront(nil)
        #expect(panel.makeFirstResponder(field))
        #expect(panel.firstResponder === field.currentEditor())
        panel.close()
    }

    @Test func notchSessionKeyboardNavigationRequiresExactCommandArrow() {
        #expect(
            NotchWindowController.sessionNavigationDirection(
                keyCode: 123,
                modifierFlags: .command
            ) == .previous
        )
        #expect(
            NotchWindowController.sessionNavigationDirection(
                keyCode: 124,
                modifierFlags: .command
            ) == .next
        )
        #expect(
            NotchWindowController.sessionNavigationDirection(
                keyCode: 123,
                modifierFlags: [.command, .shift]
            ) == nil
        )
        #expect(
            NotchWindowController.sessionNavigationDirection(
                keyCode: 124,
                modifierFlags: []
            ) == nil
        )
    }

    @Test func placementDefaultAttachesOnlyToHardwareNotches() {
        #expect(NotchOverlayPlacement.defaultPlacement(hasHardwareNotch: true) == .onMenuBar)
        #expect(NotchOverlayPlacement.defaultPlacement(hasHardwareNotch: false) == .belowMenuBar)
    }

    @Test func panelAnchorsToVisibleFrameBelowMenuBar() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let visibleFrame = CGRect(x: 0, y: 0, width: 1440, height: 868)

        let placement = NotchPanelPlacement.panelRect(
            screenFrame: screenFrame,
            visibleFrame: visibleFrame,
            preferredSize: CGSize(width: 600, height: 500)
        )

        #expect(placement.frame.maxY == visibleFrame.maxY)
        #expect(placement.frame.maxY < screenFrame.maxY)
        #expect(placement.frame.origin.y == 368)
        #expect(placement.frame.midX == visibleFrame.midX)
    }

    @Test func panelHandlesDisplaysWithNegativeOrigin() {
        let screenFrame = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let visibleFrame = CGRect(x: -1920, y: 0, width: 1920, height: 1040)

        let placement = NotchPanelPlacement.panelRect(
            screenFrame: screenFrame,
            visibleFrame: visibleFrame,
            preferredSize: CGSize(width: 600, height: 500)
        )

        #expect(placement.frame.maxY == visibleFrame.maxY)
        #expect(placement.frame.midX == visibleFrame.midX)
        #expect(placement.frame.minX >= visibleFrame.minX)
        #expect(placement.frame.maxX <= visibleFrame.maxX)
        #expect(placement.frame.minY >= visibleFrame.minY)
        #expect(placement.frame.maxY <= visibleFrame.maxY)
    }

    @Test func panelConstrainsToNarrowVisibleFrame() {
        let screenFrame = CGRect(x: 0, y: 0, width: 500, height: 800)
        let visibleFrame = CGRect(x: 0, y: 0, width: 500, height: 778)

        let placement = NotchPanelPlacement.panelRect(
            screenFrame: screenFrame,
            visibleFrame: visibleFrame,
            preferredSize: CGSize(width: 600, height: 900)
        )

        #expect(placement.frame.width == visibleFrame.width)
        #expect(placement.frame.height == visibleFrame.height)
        #expect(placement.frame.minX == visibleFrame.minX)
        #expect(placement.frame.maxX == visibleFrame.maxX)
        #expect(placement.frame.maxY == visibleFrame.maxY)
    }

    @Test func emptyVisibleFrameFallsBackToScreenFrame() {
        let screenFrame = CGRect(x: 100, y: -900, width: 1200, height: 900)

        let placement = NotchPanelPlacement.panelRect(
            screenFrame: screenFrame,
            visibleFrame: .zero,
            preferredSize: CGSize(width: 600, height: 500)
        )

        #expect(placement.frame.maxY == screenFrame.maxY)
        #expect(placement.frame.midX == screenFrame.midX)
    }

    @Test func panelReservesRevealStripWhenMenuBarAutoHides() {
        // Auto-hidden menu bar: visibleFrame extends to the top of the screen.
        let screenFrame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let visibleFrame = screenFrame

        let placement = NotchPanelPlacement.panelRect(
            screenFrame: screenFrame,
            visibleFrame: visibleFrame,
            preferredSize: CGSize(width: 600, height: 500),
            hiddenMenuBarInset: 32
        )

        #expect(placement.frame.maxY == screenFrame.maxY - 32)
        #expect(placement.frame.midX == screenFrame.midX)
    }

    @Test func panelIgnoresInsetWhenMenuBarIsVisible() {
        // Visible menu bar already reserves the strip; the inset must not
        // push the panel down a second time.
        let screenFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let visibleFrame = CGRect(x: 0, y: 0, width: 1440, height: 868)

        let placement = NotchPanelPlacement.panelRect(
            screenFrame: screenFrame,
            visibleFrame: visibleFrame,
            preferredSize: CGSize(width: 600, height: 500),
            hiddenMenuBarInset: 32
        )

        #expect(placement.frame.maxY == visibleFrame.maxY)
    }

    @Test func panelAnchorsToScreenTopWhenPlacedOnMenuBar() {
        // Opt-in on-menu-bar placement (issue #1951): the panel anchors to the
        // physical top of the display, ignoring the visible-frame / auto-hide
        // insets so it sits on the menu bar.
        let screenFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let visibleFrame = CGRect(x: 0, y: 0, width: 1440, height: 868)

        let placement = NotchPanelPlacement.panelRect(
            screenFrame: screenFrame,
            visibleFrame: visibleFrame,
            preferredSize: CGSize(width: 600, height: 500),
            hiddenMenuBarInset: 32,
            overMenuBar: true
        )

        #expect(placement.frame.maxY == screenFrame.maxY)
        #expect(placement.frame.midX == screenFrame.midX)
    }

    @Test func alertContentTopPaddingMatchesMenuBarGap() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let visibleFrame = CGRect(x: 0, y: 0, width: 1440, height: 868)

        let padding = NotchPanelPlacement.alertContentTopPadding(
            screenFrame: screenFrame,
            visibleFrame: visibleFrame
        )

        #expect(padding == 32)
    }

    @Test func alertKeepsOnMenuBarNotchAttachedToScreenTop() {
        let padding = NotchPanelPlacement.alertContentTopPadding(
            screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 868),
            overMenuBar: true
        )

        #expect(padding == 0)
    }

    @Test func alertContentTopPaddingFallsBackToZeroForEmptyVisibleFrame() {
        let padding = NotchPanelPlacement.alertContentTopPadding(
            screenFrame: CGRect(x: 100, y: -900, width: 1200, height: 900),
            visibleFrame: .zero
        )

        #expect(padding == 0)
    }
}
