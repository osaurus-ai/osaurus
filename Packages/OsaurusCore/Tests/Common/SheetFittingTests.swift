//
//  SheetFittingTests.swift
//  osaurusTests
//
//  Regression tests for #2424 — fixed-size sheets clipped their pinned
//  action footers off-screen on small displays.
//

import CoreGraphics
import Testing

@testable import OsaurusCore

struct SheetFittingTests {
    /// The reported case: the 720x720 model detail sheet on a 1024x666
    /// display. The height must come down far enough that the footer is
    /// still on-screen.
    @Test func modelDetailSheetFitsReportedSmallScreen() {
        // 666 minus the menu bar is what `visibleFrame` reports.
        let visible = CGSize(width: 1024, height: 641)
        let fitted = SheetFitting.fittedSize(
            desired: CGSize(width: 720, height: 720),
            visibleSize: visible
        )

        #expect(fitted.height == 641 - SheetFitting.screenInset)
        #expect(fitted.height < visible.height)
        // Width had room to spare, so it keeps the designed value.
        #expect(fitted.width == 720)
    }

    @Test func designedSizeSurvivesOnRoomyScreens() {
        let fitted = SheetFitting.fittedSize(
            desired: CGSize(width: 720, height: 720),
            visibleSize: CGSize(width: 2560, height: 1440)
        )

        #expect(fitted == CGSize(width: 720, height: 720))
    }

    @Test func clampsWidthOnNarrowScreens() {
        let fitted = SheetFitting.fittedSize(
            desired: CGSize(width: 980, height: 760),
            visibleSize: CGSize(width: 800, height: 600)
        )

        #expect(fitted.width == 800 - SheetFitting.screenInset)
        #expect(fitted.height == 600 - SheetFitting.screenInset)
    }

    /// A screen smaller than the floor must still produce a usable positive
    /// size rather than a degenerate or negative one.
    @Test func neverGoesBelowTheMinimum() {
        let fitted = SheetFitting.fittedSize(
            desired: CGSize(width: 720, height: 720),
            visibleSize: CGSize(width: 200, height: 100)
        )

        #expect(fitted == SheetFitting.minimumSize)
    }

    /// A sheet already smaller than the screen is never grown to fill it.
    @Test func smallSheetIsNotStretched() {
        let fitted = SheetFitting.fittedSize(
            desired: CGSize(width: 520, height: 430),
            visibleSize: CGSize(width: 2560, height: 1440)
        )

        #expect(fitted == CGSize(width: 520, height: 430))
    }
}
