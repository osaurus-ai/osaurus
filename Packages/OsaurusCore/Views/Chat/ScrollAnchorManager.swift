//
//  ScrollAnchorManager.swift
//  osaurus
//
//  Manages scroll anchoring for the NSTableView-backed chat thread.
//
//  Responsibilities:
//  - Tracks whether the user is "pinned" to the bottom of the scroll view.
//  - Fires callbacks when the pinned state transitions (for the scroll-to-bottom button).
//  - Saves / restores a scroll anchor so that applying a new diffable snapshot
//    preserves the user's reading position.
//
//  The anchor is row-based: we record the topmost visible row and the pixel
//  offset from that row's top edge. After a snapshot, we recalculate the
//  origin from the (possibly shifted) row rect.
//

import AppKit

@MainActor
final class ScrollAnchorManager {

    // MARK: - Public State

    /// Whether the scroll view is currently pinned to the bottom.
    private(set) var isPinnedToBottom: Bool = true

    /// Distance (in points) from the bottom within which we consider the
    /// user "pinned". A small tolerance prevents jitter.
    var bottomThreshold: CGFloat = 50

    /// Whether NSScrollView is currently in a live scroll session
    /// (active gesture or inertia). Bracketed by AppKit's
    /// `willStartLiveScrollNotification` / `didEndLiveScrollNotification`.
    ///
    /// Height-correction callers should skip absolute anchor restoration
    /// while this is true — applying an anchor mid-gesture fights the
    /// user's input and feels like a snap. After scroll ends, future
    /// height updates resume normal anchoring.
    ///
    /// Note: not every input device drives this notification.
    /// `willStartLiveScrollNotification` only fires reliably for trackpad
    /// gestures and scroller-knob dragging; discrete mouse-wheel ticks
    /// often arrive as plain bounds changes without bracketing
    /// notifications. Use `isUserScrollingRecently` for height-update
    /// gating — it covers both cases.
    private(set) var isLiveScrolling: Bool = false

    /// Returns true when the user has produced scroll motion within the
    /// last `userScrollGraceWindow` seconds. Bridges the gap left by
    /// devices that don't bracket scroll input with the live-scroll
    /// notifications (e.g. discrete mouse wheels) and also covers async
    /// cell measurements that fire shortly after a gesture ends.
    var isUserScrollingRecently: Bool {
        if isLiveScrolling { return true }
        guard let last = lastUserScrollTime else { return false }
        return CACurrentMediaTime() - last < userScrollGraceWindow
    }

    /// Grace window after the most recent user-driven bounds change.
    /// 350ms covers the typical inter-tick spacing of a discrete scroll
    /// wheel plus the latency of `DispatchQueue.main.async` measurement
    /// callbacks scheduled during the burst (chart / artifact cells).
    var userScrollGraceWindow: CFTimeInterval = 0.35

    // MARK: - Callbacks

    var onScrolledToBottom: (() -> Void)?
    var onScrolledAwayFromBottom: (() -> Void)?

    // MARK: - Private State

    private weak var scrollView: NSScrollView?
    private weak var tableView: NSTableView?

    /// Observer token for clip-view bounds changes.
    /// `nonisolated(unsafe)` so `deinit` can access it without actor isolation.
    nonisolated(unsafe) private var boundsObserver: NSObjectProtocol?

    /// Observer tokens for `NSScrollView`'s live-scroll notifications.
    /// `didEndLiveScroll` covers both gesture end and the trailing edge
    /// of inertial scroll, so we don't need a separate inertia tracker.
    nonisolated(unsafe) private var willStartLiveScrollObserver: NSObjectProtocol?
    nonisolated(unsafe) private var didEndLiveScrollObserver: NSObjectProtocol?

    /// Saved scroll anchor (row + pixel offset).
    private var savedAnchor: Anchor?

    /// One shot flag for coalesced `scrollToBottomCoalesced()`. multiple calls in
    /// the same runloop tick collapse to a single bounds mutation which avoids
    /// redundant clip view composites during streaming
    private var coalescedScrollPending: Bool = false

    /// Wall-clock timestamp (CACurrentMediaTime) of the most recent
    /// user-driven bounds change. Set whenever `boundsDidChange` fires
    /// outside our own `setScrollOriginY` mutation, regardless of whether
    /// `willStartLiveScrollNotification` did.
    private var lastUserScrollTime: CFTimeInterval?

    /// True while we're actively mutating the scroll origin from this
    /// manager. Prevents our own bounds change from being mis-classified
    /// as a user scroll (which would extend the grace window forever).
    private var isMutatingScrollOrigin: Bool = false

    /// Snapshot of the topmost visible row + pixel offset from its top edge
    /// to the clip view's top. Used by `saveAnchor`/`restoreAnchor` and
    /// exposed via `captureAnchor`/`applyAnchor` for stateless preservation
    /// across snapshot diffs and synchronous height bursts.
    ///
    /// Note: `applyAnchor` is **absolute** — it snaps `clip.y` to
    /// `rowOrigin + offset`. Callers must guard against applying an anchor
    /// that was captured before the user scrolled (it would yank them back).
    /// `restoreAnchor` and `noteRowHeightsChanged` both gate on
    /// `isUserScrollingRecently` for that reason.
    struct Anchor {
        let row: Int
        let offsetFromRowTop: CGFloat
    }

    // MARK: - Setup & Teardown

    func attach(to scrollView: NSScrollView, tableView: NSTableView) {
        self.scrollView = scrollView
        self.tableView = tableView

        let clipView = scrollView.contentView
        clipView.postsBoundsChangedNotifications = true
        // Synchronous delivery (queue: nil) — AppKit posts boundsDidChange
        // on the main thread during the scroll mutation itself, so the
        // observer block runs inline. That's required for
        // `isMutatingScrollOrigin` to correctly filter our own scroll
        // mutations: with `queue: .main` the block is enqueued for the
        // next runloop tick, by which time the flag has already been
        // cleared and our self-induced bounds change gets mis-classified
        // as a user scroll, locking out anchor restores forever.
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clipView,
            queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleBoundsChanged() }
        }

        willStartLiveScrollObserver = NotificationCenter.default.addObserver(
            forName: NSScrollView.willStartLiveScrollNotification,
            object: scrollView,
            queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.isLiveScrolling = true }
        }
        didEndLiveScrollObserver = NotificationCenter.default.addObserver(
            forName: NSScrollView.didEndLiveScrollNotification,
            object: scrollView,
            queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.isLiveScrolling = false }
        }
    }

    deinit {
        let center = NotificationCenter.default
        if let observer = boundsObserver { center.removeObserver(observer) }
        if let observer = willStartLiveScrollObserver { center.removeObserver(observer) }
        if let observer = didEndLiveScrollObserver { center.removeObserver(observer) }
    }

    // MARK: - Anchor Capture / Apply

    /// Capture a stateless snapshot of the topmost visible row + pixel offset
    /// from its top edge. Returns nil when there's no scroll view or the
    /// topmost-visible row can't be determined (empty thread).
    ///
    /// Stateless: callers hold the returned `Anchor?` themselves and pass it
    /// back to `applyAnchor(_:)`. Use this when you want to preserve scroll
    /// position across a height/layout change without disturbing the
    /// `saveAnchor`/`restoreAnchor` field — for example, snapshot diffs.
    func captureAnchor() -> Anchor? {
        guard let tableView, let scrollView else { return nil }
        let topY = scrollView.contentView.bounds.origin.y
        let topRow = tableView.row(at: NSPoint(x: 0, y: topY))
        guard topRow >= 0 else { return nil }
        let rowRect = tableView.rect(ofRow: topRow)
        return Anchor(row: topRow, offsetFromRowTop: topY - rowRect.origin.y)
    }

    /// Scroll the clip view so the anchor row sits at its recorded offset
    /// below the visible top. **Absolute** — overwrites any user scroll that
    /// happened between capture and apply.
    ///
    /// Skipped when already within 1pt of the target to avoid a feedback loop
    /// where `setBoundsOrigin` → `boundsDidChange` → SwiftUI re-render →
    /// `updateNSView` → `applyBlocks` → ... loops back here.
    func applyAnchor(_ anchor: Anchor) {
        guard let tableView, let scrollView else { return }
        let clampedRow = min(anchor.row, tableView.numberOfRows - 1)
        guard clampedRow >= 0 else { return }
        let rowRect = tableView.rect(ofRow: clampedRow)
        let targetY = rowRect.origin.y + anchor.offsetFromRowTop
        let curY = scrollView.contentView.bounds.origin.y
        guard abs(curY - targetY) > 1.0 else { return }
        setScrollOriginY(targetY)
    }

    // MARK: - Anchor Save / Restore (stored)

    /// Save the topmost visible row + offset. Call **before** applying a snapshot.
    /// When pinned to bottom, no anchor is saved -- `scrollToBottom()` handles that case.
    func saveAnchor() {
        savedAnchor = captureAnchor()
    }

    /// Restore position from the saved anchor. Call **after** the snapshot completes.
    ///
    /// Skipped (and the saved anchor discarded) when the user is actively
    /// scrolling or just stopped — restoring to a stale pre-scroll
    /// position in that window snaps them back to where they came from,
    /// which feels like a "jump to message top" against an upward scroll.
    /// The next snapshot apply will capture and restore relative to the
    /// user's current scroll position.
    func restoreAnchor() {
        guard let anchor = savedAnchor else { return }
        savedAnchor = nil
        if isUserScrollingRecently { return }
        applyAnchor(anchor)
    }

    // MARK: - Scroll Actions

    /// Scroll to the very bottom of the content.
    /// Uses clip view bounds directly rather than `scrollRowToVisible`,
    /// which only ensures a row is visible but won't fully scroll to the end.
    func scrollToBottom(animated: Bool = false) {
        guard let scrollView, let documentView = scrollView.documentView else { return }
        let clipView = scrollView.contentView
        let maxY = max(0, documentView.frame.height - clipView.bounds.height)

        // if already within 1pt of the target — skip. streaming height updates fire
        // this repeatedly even when the row grew by less than a pixel, and each
        // call would otherwise re-damage the full clip view via
        // `reflectScrolledClipView`
        if !animated, abs(clipView.bounds.origin.y - maxY) <= 1.0 {
            return
        }

        if animated {
            isMutatingScrollOrigin = true
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.allowsImplicitAnimation = true
                clipView.setBoundsOrigin(NSPoint(x: clipView.bounds.origin.x, y: maxY))
            }
            scrollView.reflectScrolledClipView(clipView)
            isMutatingScrollOrigin = false
        } else {
            setScrollOriginY(maxY)
        }
    }

    /// Coalesced variant: multiple calls within the same runloop tick collapse
    /// to a single trailing-edge `scrollToBottom()`. Use from per-token paths
    /// (streaming height update + path 2 reconfigures can fire back-to-back
    /// within a few ms of each other).
    func scrollToBottomCoalesced() {
        guard !coalescedScrollPending else { return }
        coalescedScrollPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.coalescedScrollPending = false
            self.scrollToBottom()
        }
    }

    /// Scroll so that the given row is visible.
    ///
    /// `HoverTrackingTableView.allowProgrammaticScroll` gates the
    /// `scrollRowToVisible` call past our subview-initiated-scroll
    /// blocker (see `HoverTrackingTableView.scrollToVisible`). Without
    /// this gate, the override would short-circuit the scroll and the
    /// row wouldn't move into view.
    func scrollToRow(_ row: Int, animated: Bool = false) {
        guard let tableView, row >= 0, row < tableView.numberOfRows else { return }
        isMutatingScrollOrigin = true
        HoverTrackingTableView.allowProgrammaticScroll = true
        defer {
            HoverTrackingTableView.allowProgrammaticScroll = false
            isMutatingScrollOrigin = false
        }
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.allowsImplicitAnimation = true
                tableView.scrollRowToVisible(row)
            }
        } else {
            tableView.scrollRowToVisible(row)
        }
    }

    /// Animated scroll to an arbitrary y-origin. Used by minimap-driven
    /// jumps that target a row's `rect(ofRow:)` plus a small offset rather
    /// than `scrollRowToVisible`'s "any-edge" semantics.
    ///
    /// Brackets the bounds mutation with `isMutatingScrollOrigin` so the
    /// resulting bounds change isn't classified as user input (which would
    /// extend the live-scroll grace window and suppress legitimate
    /// post-jump anchor restores).
    func scrollToY(_ y: CGFloat, animated: Bool) {
        guard let scrollView else { return }
        let clipView = scrollView.contentView
        if animated {
            isMutatingScrollOrigin = true
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                ctx.allowsImplicitAnimation = true
                clipView.setBoundsOrigin(NSPoint(x: clipView.bounds.origin.x, y: y))
            }
            scrollView.reflectScrolledClipView(clipView)
            isMutatingScrollOrigin = false
        } else {
            setScrollOriginY(y)
        }
    }

    /// Force unpin from the bottom (i.e user jumped to a specific turn via
    /// the minimap). Subsequent snapshot applies will preserve the anchor
    /// instead of re-snapping to bottom. Fires `onScrolledAwayFromBottom`
    /// if we were previously pinned.
    func unpinFromBottom() {
        guard isPinnedToBottom else { return }
        isPinnedToBottom = false
        let cb = onScrolledAwayFromBottom
        DispatchQueue.main.async { cb?() }
    }

    /// Re-check pinned state against the current scroll position.
    /// Call after the initial snapshot or any layout that doesn't trigger
    /// `boundsDidChangeNotification` (e.g. content growing while the
    /// clip view stays at origin 0,0).
    func checkPinnedState() {
        handleBoundsChanged()
    }

    // MARK: - Private Helpers

    /// Set the clip view's vertical scroll origin and notify the scroll view.
    /// Brackets the mutation with `isMutatingScrollOrigin` so the resulting
    /// bounds-change notification doesn't get mis-classified as a user
    /// scroll (which would extend the live-scroll grace window forever).
    private func setScrollOriginY(_ y: CGFloat) {
        guard let scrollView else { return }
        let clipView = scrollView.contentView
        isMutatingScrollOrigin = true
        clipView.setBoundsOrigin(NSPoint(x: clipView.bounds.origin.x, y: y))
        scrollView.reflectScrolledClipView(clipView)
        isMutatingScrollOrigin = false
    }

    /// Called on every clip-view bounds change (i.e. scroll). Fires pinned-state
    /// callbacks asynchronously to avoid mutating SwiftUI `@State` during a view update.
    ///
    /// Also records the timestamp of user-driven changes so
    /// `isUserScrollingRecently` can gate height-correction anchoring even
    /// when `willStartLiveScrollNotification` doesn't fire (e.g. for
    /// discrete mouse-wheel ticks).
    private func handleBoundsChanged() {
        guard let scrollView else { return }
        if !isMutatingScrollOrigin {
            lastUserScrollTime = CACurrentMediaTime()
        }
        let wasPinned = isPinnedToBottom
        isPinnedToBottom = isAtBottom(scrollView: scrollView)

        if isPinnedToBottom, !wasPinned {
            let cb = onScrolledToBottom
            DispatchQueue.main.async { cb?() }
        } else if !isPinnedToBottom, wasPinned {
            let cb = onScrolledAwayFromBottom
            DispatchQueue.main.async { cb?() }
        }
    }

    private func isAtBottom(scrollView: NSScrollView) -> Bool {
        let clipView = scrollView.contentView
        let contentHeight = scrollView.documentView?.frame.height ?? 0
        let distanceFromBottom = contentHeight - (clipView.bounds.origin.y + clipView.bounds.height)
        return distanceFromBottom <= bottomThreshold
    }
}
