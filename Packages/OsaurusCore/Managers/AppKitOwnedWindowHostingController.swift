//
//  AppKitOwnedWindowHostingController.swift
//  osaurus
//
//  Hosts a SwiftUI root inside a window whose SIZE belongs to AppKit
//  (`defaultSize` + frame autosave + the user's resizing), while still
//  giving that window a minimum size the user cannot drag below.
//
//  Why not `NSHostingController` with `sizingOptions = [.minSize]`:
//  with any sizing option on, `NSHostingView.windowDidLayout` compares
//  the window against the size SwiftUI wants and, when they differ,
//  resizes the window itself (`updateAnimatedWindowSize` →
//  `-[NSWindow _setFrameCommon:]`). Every such resize re-derives the
//  hosting view's safe-area insets (`NSHostingView.didChangeValue` →
//  `invalidateSafeAreaInsets`), which invalidates the SwiftUI graph and
//  requests another update-constraints pass. When the size SwiftUI
//  wants is one the window cannot hold — a floor taller than the screen
//  that AppKit clamps straight back, or a fill-style root whose measured
//  width grows with the window — the two sides never agree, the passes
//  pile up inside one display cycle, and AppKit raises
//  `NSGenericException: The window has been marked as needing another
//  Update Constraints in Window pass, but it has already had more Update
//  Constraints in Window passes than there are views in the window`
//  (Sentry APPLE-MACOS-1ZM: 12 crashes / 11 users; the 0.25.0 events
//  carried ChatPanel frames 4,261 to 118,594 pt wide, the 0.25.11 and
//  0.25.20 events the settings window at `[.minSize]`, both with the
//  `windowDidLayout → updateAnimatedWindowSize → setFrameSize →
//  invalidateSafeAreaInsets → setNeedsUpdateConstraints` stack).
//
//  Here `sizingOptions` is empty, so SwiftUI never touches the window
//  frame, and the floor is supplied through `preferredMinimumSize` —
//  the property AppKit mirrors into `contentMinSize` for a window's
//  content view controller. `minimumContentSize` is the SwiftUI root's
//  own minimum (what `.frame(minWidth:minHeight:)` enforces); the
//  controller adds the titlebar strip the root sits below in a
//  `.fullSizeContentView` window, so the floor the user hits is the one
//  the root actually needs.
//

import AppKit
import SwiftUI

/// Read-only view of the controller for tests and diagnostics, usable
/// without naming the generic `Content`.
@MainActor
protocol AppKitOwnedWindowHosting: AnyObject {
    /// The SwiftUI root's minimum content size, before window chrome.
    var minimumContentSize: CGSize { get }
    /// The `NSHostingSizingOptions` in effect; always empty for this
    /// controller — SwiftUI must not drive the window frame.
    var effectiveSizingOptions: NSHostingSizingOptions { get }
}

final class AppKitOwnedWindowHostingController<Content: View>: NSHostingController<Content>,
    AppKitOwnedWindowHosting
{
    /// The floor the SwiftUI root enforces, excluding window chrome.
    /// Setting it re-mirrors the window's `contentMinSize` at once.
    var minimumContentSize: CGSize {
        didSet {
            guard minimumContentSize != oldValue else { return }
            mirrorMinimumSizeIntoWindow()
        }
    }

    var effectiveSizingOptions: NSHostingSizingOptions { sizingOptions }

    init(rootView: Content, minimumContentSize: CGSize) {
        self.minimumContentSize = minimumContentSize
        super.init(rootView: rootView)
        // The whole point: AppKit owns the frame. See the header comment.
        sizingOptions = []
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("AppKitOwnedWindowHostingController does not support NSCoding")
    }

    /// AppKit reads this for the window's `contentMinSize`. With
    /// `.fullSizeContentView` the content view (this controller's view)
    /// spans the titlebar too, while the SwiftUI root lays out inside the
    /// safe area below it, so the root's floor plus that strip is the
    /// smallest content view that still shows the whole root.
    override var preferredMinimumSize: NSSize {
        NSSize(
            width: minimumContentSize.width,
            height: minimumContentSize.height + titlebarChromeHeight
        )
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // The titlebar strip is only known once the view is in a window
        // that has laid out; re-mirror so the first measurement lands.
        mirrorMinimumSizeIntoWindow()
    }

    private var titlebarChromeHeight: CGFloat {
        guard let window = view.window else { return 0 }
        return max(0, window.frame.height - window.contentLayoutRect.height)
    }

    /// Pushes `preferredMinimumSize` into the window. AppKit mirrors the
    /// property on its own when it changes under KVO, so this also posts
    /// the change notification; the direct assignment makes the floor
    /// take effect immediately for callers that read `contentMinSize`
    /// right after setting `minimumContentSize`.
    private func mirrorMinimumSizeIntoWindow() {
        guard let window = view.window else { return }
        let floor = preferredMinimumSize
        guard window.contentMinSize != floor else { return }
        willChangeValue(for: \.preferredMinimumSize)
        window.contentMinSize = floor
        didChangeValue(for: \.preferredMinimumSize)
    }
}
