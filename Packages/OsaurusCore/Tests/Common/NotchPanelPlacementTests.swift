//
//  NotchPanelPlacementTests.swift
//  osaurusTests
//
//  Regression tests for task-progress notch overlay placement. API-dispatched
//  background tasks render here; the panel must stay below the macOS menu bar.
//

import CoreGraphics
import Testing

@testable import OsaurusCore

struct NotchPanelPlacementTests {
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

    @Test func alertContentTopPaddingMatchesMenuBarGap() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let visibleFrame = CGRect(x: 0, y: 0, width: 1440, height: 868)

        let padding = NotchPanelPlacement.alertContentTopPadding(
            screenFrame: screenFrame,
            visibleFrame: visibleFrame
        )

        #expect(padding == 32)
    }

    @Test func alertContentTopPaddingFallsBackToZeroForEmptyVisibleFrame() {
        let padding = NotchPanelPlacement.alertContentTopPadding(
            screenFrame: CGRect(x: 100, y: -900, width: 1200, height: 900),
            visibleFrame: .zero
        )

        #expect(padding == 0)
    }
}
