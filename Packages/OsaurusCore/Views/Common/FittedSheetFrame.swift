//
//  FittedSheetFrame.swift
//  osaurus
//
//  Shared sizing for modal sheets that declare a fixed size.
//
//  Usage:
//    VStack(spacing: 0) {
//        header
//        ScrollView { ... }
//        footer          // pinned, must stay reachable
//    }
//    .fittedSheetFrame(width: 720, height: 720)
//
//  macOS does not shrink a sheet whose content declares a fixed height —
//  it clips it. A sheet asking for 720pt on a 1024x666 display loses its
//  bottom ~80pt, and since pinned action footers are the last element in
//  the stack, the buttons are the first thing to disappear (#2424).
//
//  `fittedSheetFrame` keeps the designed size as the ideal and clamps it
//  to what the presenting screen can actually show, so the footer stays
//  on-screen and the sheet's own ScrollView absorbs the lost height.
//

import AppKit
import SwiftUI

/// Pure sizing math behind `fittedSheetFrame`, kept free of `NSScreen` so
/// it can be exercised against arbitrary screen geometry in tests.
enum SheetFitting {
    /// Breathing room left around a sheet so it never sits flush against the
    /// screen edges (and clears the menu bar, which `visibleFrame` excludes).
    static let screenInset: CGFloat = 48

    /// Floor for a clamped sheet. Below this a sheet is too cramped to be
    /// usable, and we would rather clip than render an unreadable dialog —
    /// on a screen this small the sheet is unusable either way.
    static let minimumSize = CGSize(width: 360, height: 320)

    /// The designed size, clamped to the space `visibleSize` leaves after
    /// `screenInset`, floored at `minimum`.
    static func fittedSize(
        desired: CGSize,
        visibleSize: CGSize,
        minimum: CGSize = minimumSize
    ) -> CGSize {
        CGSize(
            width: fit(desired.width, available: visibleSize.width, minimum: minimum.width),
            height: fit(desired.height, available: visibleSize.height, minimum: minimum.height)
        )
    }

    private static func fit(_ desired: CGFloat, available: CGFloat, minimum: CGFloat) -> CGFloat {
        let room = available - screenInset
        // `max(minimum:)` is applied last so a screen smaller than the floor
        // still yields the floor rather than a degenerate or negative size.
        return max(minimum, min(desired, room))
    }
}

extension View {
    /// Sizes a modal sheet to its designed dimensions, clamped to the
    /// presenting screen so pinned footers stay reachable on small displays.
    ///
    /// Drop-in replacement for `.frame(width:height:)` on a sheet's root
    /// view. On any screen with room for the designed size this is exactly
    /// the old behavior.
    @MainActor
    func fittedSheetFrame(width: CGFloat, height: CGFloat) -> some View {
        // The presenting window is key when its sheet is built, so
        // `NSScreen.main` is the screen the sheet will appear on.
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame.size
            ?? CGSize(width: width, height: height)
        let size = SheetFitting.fittedSize(
            desired: CGSize(width: width, height: height),
            visibleSize: visible
        )
        return frame(width: size.width, height: size.height)
    }
}
