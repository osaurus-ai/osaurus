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
//  A sheet is also drawn inside the window that presents it and cut off at
//  that window's edges, so it is clamped to the window too: a 680pt sheet
//  over a 600pt window lost its header and its footer.
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

    /// Room left between a sheet and the edges of the window presenting it.
    static let windowInset: CGFloat = 32

    /// The designed size, clamped to the space `visibleSize` leaves after
    /// `screenInset` and `windowSize` (when known) leaves after
    /// `windowInset`, floored at `minimum`.
    static func fittedSize(
        desired: CGSize,
        visibleSize: CGSize,
        windowSize: CGSize? = nil,
        minimum: CGSize = minimumSize
    ) -> CGSize {
        func room(_ screen: CGFloat, _ window: CGFloat?) -> CGFloat {
            min(screen - screenInset, window.map { $0 - windowInset } ?? .infinity)
        }
        return CGSize(
            width: fit(desired.width, room: room(visibleSize.width, windowSize?.width), minimum: minimum.width),
            height: fit(desired.height, room: room(visibleSize.height, windowSize?.height), minimum: minimum.height)
        )
    }

    private static func fit(_ desired: CGFloat, room: CGFloat, minimum: CGFloat) -> CGFloat {
        // `max(minimum:)` is applied last so a screen smaller than the floor
        // still yields the floor rather than a degenerate or negative size.
        max(minimum, min(desired, room))
    }
}

/// The window a sheet is presented over, read once when the sheet is
/// built: then the presenting window is key (or, once the sheet itself is
/// key, its parent).
@MainActor
final class SheetPresenter {
    weak var window: NSWindow?
    let screenSize: CGSize?

    init() {
        var window = NSApp?.keyWindow
        while let parent = window?.sheetParent { window = parent }
        self.window = window
        screenSize = (window?.screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame.size
    }

    /// The tallest a sheet can be here; nil when nothing presents it.
    var maxSheetHeight: CGFloat? {
        guard let screenSize else { return nil }
        return SheetFitting.fittedSize(
            desired: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude), visibleSize: screenSize,
            windowSize: window?.frame.size
        ).height
    }
}

private struct FittedSheetFrame: ViewModifier {
    let desired: CGSize
    @State private var presenter = SheetPresenter()
    @State private var windowSize: CGSize?

    func body(content: Content) -> some View {
        let size = SheetFitting.fittedSize(
            desired: desired,
            visibleSize: presenter.screenSize ?? desired,
            windowSize: windowSize ?? presenter.window?.frame.size
        )
        content
            .frame(width: size.width, height: size.height)
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResizeNotification)) { note in
                guard let window = note.object as? NSWindow, window === presenter.window else { return }
                windowSize = window.frame.size
            }
    }
}

extension View {
    /// Sizes a modal sheet to its designed dimensions, clamped to the
    /// presenting screen and window so its header and pinned footer stay
    /// in view on small displays and in small windows.
    ///
    /// Drop-in replacement for `.frame(width:height:)` on a sheet's root
    /// view. With room for the designed size this is exactly the old
    /// behavior.
    @MainActor
    func fittedSheetFrame(width: CGFloat, height: CGFloat) -> some View {
        modifier(FittedSheetFrame(desired: CGSize(width: width, height: height)))
    }
}
