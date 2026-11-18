//
//  ScrollAnchorManager.swift
//  osaurus
//
//  Manages scroll anchoring for the NSTableView-backed chat thread.
//
//  Responsibilities:
//  - Owns whether the thread follows its bottom edge, and keeps a following
//    reader there as the content or the viewport changes size.
//  - Fires callbacks when following starts / stops (for the scroll-to-bottom button).
//  - Saves / restores a scroll anchor so that applying a new diffable snapshot
//    preserves the user's reading position.
//
//  Following is explicit state. Only the reader changes it: scrolling toward
//  older content stops it, scrolling back to the bottom (or the
//  scroll-to-bottom button) resumes it. Content growth, clip-view clamps and
//  this manager's own scrolls never do, so a large height change can't drop
//  a following reader and a scrolled-up reader is never pulled back down.
//
//  The anchor is block-based: we record the block in the topmost visible row
//  and the pixel offset from that row's top edge. After a snapshot, we find
//  that block's (possibly shifted) row and recalculate the origin from its
//  rect. Resolving by id matters because a snapshot can insert rows above the
//  reader (e.g. the streaming block window widening when a run ends), which
//  would leave a bare row index pointing at older content.
//

import AppKit

@MainActor
final class ScrollAnchorManager {

    // MARK: - Public State

    /// Whether the thread follows its bottom edge.
    private(set) var isPinnedToBottom: Bool = true

    /// While true the reader never starts following. Set while a restored
    /// position settles: rows still measuring can briefly make the content
    /// shorter than the viewport, which would read as "at bottom".
    var holdUnpinned = false {
        didSet {
            guard oldValue != holdUnpinned else { return }
            if holdUnpinned {
                setFollowing(false)
            } else if distanceFromBottom <= 1 {
                setFollowing(true)
            }
        }
    }

    // MARK: - Callbacks

    var onScrolledToBottom: (() -> Void)?
    var onScrolledAwayFromBottom: (() -> Void)?

    /// Maps a table row to its block id. Must reflect the rows currently
    /// in the table at `saveAnchor()` time.
    var blockIdForRow: ((Int) -> String?)?

    /// Maps a block id to its row after a snapshot applies.
    var rowForBlockId: ((String) -> Int?)?

    // MARK: - Private State

    private weak var scrollView: NSScrollView?
    private weak var tableView: NSTableView?

    /// `nonisolated(unsafe)` so `deinit` can remove them without actor isolation.
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    /// Saved scroll anchor (row + pixel offset).
    private var savedAnchor: Anchor?

    private var lastOriginY: CGFloat = 0
    /// > 0 while this manager moves the origin itself.
    private var programmaticScrollDepth = 0
    /// > 0 while a disclosure toggle holds the origin still (see `beginHoldingPosition`).
    private var positionHoldDepth = 0
    private let scrollAnimator = ChatFrameAnimator()

    /// > 0 during a live scroll: a scroller drag or a trackpad gesture,
    /// momentum included.
    private var liveScrollDepth = 0
    /// End of the window after a wheel or keyboard scroll event in which
    /// origin changes are the reader's. A mouse-wheel notch and a page key
    /// both animate the origin after the event.
    private var userScrollUntil: CFTimeInterval = 0
    private static let userScrollWindow: CFTimeInterval = 0.4

    private var isUserScrolling: Bool {
        liveScrollDepth > 0 || CACurrentMediaTime() < userScrollUntil
    }

    private static let scrollAnimationDuration: CFTimeInterval = 0.25

    private struct Anchor {
        let row: Int
        let blockId: String?
        let offsetFromRowTop: CGFloat
    }

    // MARK: - Setup & Teardown

    func attach(to scrollView: NSScrollView, tableView: NSTableView) {
        self.scrollView = scrollView
        self.tableView = tableView

        let clipView = scrollView.contentView
        clipView.postsBoundsChangedNotifications = true
        clipView.postsFrameChangedNotifications = true
        tableView.postsFrameChangedNotifications = true
        // Synchronous (queue: nil): a following reader is re-pinned inside the
        // same layout pass that changed the size, so no frame is drawn with
        // the bottom out of place.
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSView.boundsDidChangeNotification, object: clipView, queue: nil) {
                [weak self] _ in MainActor.assumeIsolated { self?.handleBoundsChanged() }
            },
            center.addObserver(forName: NSView.frameDidChangeNotification, object: clipView, queue: nil) {
                [weak self] _ in MainActor.assumeIsolated { self?.followBottomIfNeeded() }
            },
            center.addObserver(forName: NSView.frameDidChangeNotification, object: tableView, queue: nil) {
                [weak self] _ in MainActor.assumeIsolated { self?.followBottomIfNeeded() }
            },
            center.addObserver(forName: NSScrollView.willStartLiveScrollNotification, object: scrollView, queue: nil) {
                [weak self] _ in
                MainActor.assumeIsolated {
                    self?.liveScrollDepth += 1
                    self?.scrollAnimator.stop()
                }
            },
            center.addObserver(forName: NSScrollView.didEndLiveScrollNotification, object: scrollView, queue: nil) {
                [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.liveScrollDepth = max(0, self.liveScrollDepth - 1)
                }
            },
        ]
        lastOriginY = clipView.bounds.origin.y
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Geometry

    /// The resting origin at the bottom: the last row clears the bottom
    /// content inset, and a thread shorter than the viewport stays at the
    /// top inset. This is also the furthest the clip view lets the reader
    /// scroll, so a reader at the true bottom and a following reader agree.
    var bottomOriginY: CGFloat {
        guard let scrollView, let documentView = scrollView.documentView else { return 0 }
        let insets = scrollView.contentInsets
        let clipHeight = scrollView.contentView.bounds.height
        return max(-insets.top, documentView.frame.height - clipHeight + insets.bottom)
    }

    var distanceFromBottom: CGFloat {
        guard let scrollView else { return 0 }
        return bottomOriginY - scrollView.contentView.bounds.origin.y
    }

    // MARK: - Anchor Save / Restore

    /// Save the topmost visible row + offset. Call **before** applying a snapshot.
    /// When pinned to bottom, no anchor is saved -- `scrollToBottom()` handles that case.
    func saveAnchor() {
        guard let tableView, let scrollView else {
            savedAnchor = nil
            return
        }

        let topY = scrollView.contentView.bounds.origin.y
        let topRow = tableView.row(at: NSPoint(x: 0, y: topY))
        guard topRow >= 0 else { savedAnchor = nil; return }

        let rowRect = tableView.rect(ofRow: topRow)
        savedAnchor = Anchor(
            row: topRow,
            blockId: blockIdForRow?(topRow),
            offsetFromRowTop: topY - rowRect.origin.y
        )
    }

    /// Restore position from the saved anchor. Call **after** the snapshot completes.
    func restoreAnchor() {
        guard let tableView, let scrollView, let anchor = savedAnchor else { return }
        savedAnchor = nil

        // Prefer the anchored block's new row; fall back to the old index
        // only when that block left the thread.
        let row: Int
        if let blockId = anchor.blockId, let resolved = rowForBlockId?(blockId),
            resolved < tableView.numberOfRows
        {
            row = resolved
        } else {
            row = min(anchor.row, tableView.numberOfRows - 1)
        }
        guard row >= 0 else { return }

        let rowRect = tableView.rect(ofRow: row)
        let targetY = rowRect.origin.y + anchor.offsetFromRowTop
        let curY = scrollView.contentView.bounds.origin.y

        // Skip if already at the target (within 1pt). This breaks a potential
        // feedback loop where setBoundsOrigin → boundsDidChange → SwiftUI
        // re-render → updateNSView → applyBlocks → restoreAnchor → ...
        guard abs(curY - targetY) > 1.0 else { return }

        setScrollOriginY(targetY)
    }

    // MARK: - Position Save / Restore (across mounts)

    /// Snapshot the reading position so a later mount of the same session
    /// can restore it. Returns nil when there is nothing to anchor to.
    func capturePosition(blockIdForRow: (Int) -> String?) -> ThreadScrollPosition? {
        guard let tableView, let scrollView, tableView.numberOfRows > 0 else { return nil }
        if isPinnedToBottom { return .bottom }

        // The origin can sit above row 0 (top content inset), where
        // `row(at:)` finds nothing, so probe at 0 and keep the negative
        // offset to land back in the inset.
        let topY = scrollView.contentView.bounds.origin.y
        let topRow = tableView.row(at: NSPoint(x: 0, y: max(topY, 0)))
        guard topRow >= 0, let blockId = blockIdForRow(topRow) else { return nil }
        let rowRect = tableView.rect(ofRow: topRow)
        return ThreadScrollPosition(
            isPinnedToBottom: false,
            blockId: blockId,
            offsetFromRowTop: topY - rowRect.origin.y
        )
    }

    /// Put the reader back at a position from `capturePosition`. Returns
    /// false when the anchored block is gone, so the caller can fall back to
    /// the bottom.
    func restorePosition(_ position: ThreadScrollPosition, rowForBlockId: (String) -> Int?) -> Bool {
        guard let tableView else { return false }
        if position.isPinnedToBottom {
            scrollToBottom()
            return true
        }
        guard let blockId = position.blockId, let row = rowForBlockId(blockId),
            row < tableView.numberOfRows
        else { return false }

        let rowRect = tableView.rect(ofRow: row)
        let targetY = rowRect.origin.y + position.offsetFromRowTop
        // Re-applied on every layout change while settling; skip no-ops so
        // the bounds callback it triggers can't loop.
        if let scrollView, abs(scrollView.contentView.bounds.origin.y - targetY) > 0.5 {
            setScrollOriginY(targetY)
        }
        unpinFromBottom()
        return true
    }

    // MARK: - Scroll Actions

    /// Follow the bottom from here on and scroll there. An animated scroll
    /// tracks the bottom as it moves, so content arriving mid-animation is
    /// part of the same motion rather than a snap at its end.
    func scrollToBottom(animated: Bool = false) {
        guard let scrollView else { return }
        setFollowing(true)
        let startY = scrollView.contentView.bounds.origin.y
        guard abs(startY - bottomOriginY) > 0.5 else {
            scrollAnimator.stop()
            return
        }
        guard animated, !ChatFrameAnimator.reduceMotion else {
            scrollAnimator.stop()
            setScrollOriginY(bottomOriginY)
            return
        }
        ChatPerfTrace.shared.count("scrollAnchor.animateToBottom")
        scrollAnimator.run(
            duration: Self.scrollAnimationDuration,
            curve: .easeOut,
            on: scrollView,
            step: { [weak self] progress in
                guard let self else { return }
                self.setScrollOriginY(startY + (self.bottomOriginY - startY) * progress)
            },
            completion: { [weak self] in self?.followBottomIfNeeded() }
        )
    }

    /// Stop following (the reader jumped to a specific turn via the minimap
    /// or find bar). Snapshot applies then preserve the anchor instead of
    /// going back to the bottom.
    func unpinFromBottom() {
        scrollAnimator.stop()
        setFollowing(false)
    }

    /// A wheel, trackpad or keyboard scroll event: the reader takes over from
    /// a scroll animation still running, and the origin changes it causes
    /// count as theirs.
    func userWillScroll() {
        scrollAnimator.stop()
        userScrollUntil = CACurrentMediaTime() + Self.userScrollWindow
    }

    /// The reader is scrolling toward older content with the wheel or
    /// trackpad. Called when the event arrives, before the view moves: a
    /// mouse-wheel notch animates, so the origin hasn't moved yet.
    /// Ignored when there is nothing above to scroll to.
    func userScrolledUp() {
        guard let scrollView else { return }
        guard scrollView.contentView.bounds.origin.y > -scrollView.contentInsets.top + 0.5 else { return }
        scrollAnimator.stop()
        setFollowing(false)
    }

    /// Hold the origin still while a disclosure row changes height, so the
    /// header the reader clicked stays under the pointer instead of being
    /// carried along by the follow-the-bottom re-pin. Pair with
    /// `endHoldingPosition`.
    func beginHoldingPosition() {
        positionHoldDepth += 1
        scrollAnimator.stop()
    }

    /// End a hold. A reader the change left at the bottom follows (a
    /// collapse undoing an expand returns them there). A following reader
    /// keeps following when `resumeFollowing` asks for it (a collapse); one
    /// whose bottom content moved below the viewport (an expand) stops, so
    /// the next streamed token doesn't scroll the expanded row away.
    func endHoldingPosition(resumeFollowing: Bool) {
        guard positionHoldDepth > 0 else { return }
        positionHoldDepth -= 1
        guard positionHoldDepth == 0 else { return }
        if distanceFromBottom <= 1 {
            if isPinnedToBottom { followBottomIfNeeded() } else if !holdUnpinned { setFollowing(true) }
            return
        }
        guard isPinnedToBottom else { return }
        if resumeFollowing {
            scrollToBottom(animated: true)
        } else {
            setFollowing(false)
        }
    }

    /// Run `changeHeights`, which re-notes `rows`, without moving what the
    /// reader sees. NSTableView keeps the scroll origin, so a row above the
    /// viewport that grows or shrinks would shift everything below it.
    /// A following reader is re-pinned by the document frame change instead.
    func keepingVisibleContent(whileChanging rows: IndexSet, _ changeHeights: () -> Void) {
        let following = isPinnedToBottom && positionHoldDepth == 0
        guard !following, let tableView, let scrollView, let firstChanged = rows.first else {
            changeHeights()
            return
        }
        let topY = scrollView.contentView.bounds.origin.y
        let topRow = tableView.row(at: NSPoint(x: 0, y: max(topY, 0)))
        guard topRow > firstChanged else {
            changeHeights()
            return
        }
        let rowTopBefore = tableView.rect(ofRow: topRow).origin.y
        changeHeights()
        let shift = tableView.rect(ofRow: topRow).origin.y - rowTopBefore
        guard abs(shift) > 0.5 else { return }
        ChatPerfTrace.shared.count("scrollAnchor.keepVisible")
        setScrollOriginY(scrollView.contentView.bounds.origin.y + shift)
    }

    /// Re-pin a following reader. For geometry changes that don't resize the
    /// document or the clip view (content insets changing, first mount).
    func checkPinnedState() {
        followBottomIfNeeded()
    }

    // MARK: - Private Helpers

    /// Keep a following reader at the bottom. Runs synchronously from the
    /// document and clip-view frame changes, so every height change, row
    /// insert and viewport resize re-pins in the pass that caused it.
    private func followBottomIfNeeded() {
        guard isPinnedToBottom, positionHoldDepth == 0, !holdUnpinned, !scrollAnimator.isRunning,
            let scrollView
        else { return }
        let target = bottomOriginY
        guard abs(scrollView.contentView.bounds.origin.y - target) > 0.5 else { return }
        ChatPerfTrace.shared.count("scrollAnchor.follow")
        setScrollOriginY(target)
    }

    /// Set the clip view's vertical scroll origin and notify the scroll view.
    private func setScrollOriginY(_ y: CGFloat) {
        guard let scrollView else { return }
        let clipView = scrollView.contentView
        programmaticScrollDepth += 1
        defer { programmaticScrollDepth -= 1 }
        clipView.setBoundsOrigin(NSPoint(x: clipView.bounds.origin.x, y: y))
        scrollView.reflectScrolledClipView(clipView)
    }

    /// Classify a bounds change. Only one made while the reader is scrolling
    /// changes following: up and short of the bottom stops it, down onto the
    /// bottom resumes it. Everything else is ours (re-pin, anchor restore,
    /// scroll animation) or AppKit's (clamping to a resized document or clip
    /// view, shifting for a changed content inset); those can move the
    /// origin either way, so a following reader is put back on the bottom.
    private func handleBoundsChanged() {
        guard let scrollView else { return }
        let originY = scrollView.contentView.bounds.origin.y
        let delta = originY - lastOriginY
        lastOriginY = originY
        guard programmaticScrollDepth == 0, !scrollAnimator.isRunning, abs(delta) > 0.5 else { return }
        guard isUserScrolling else {
            followBottomIfNeeded()
            return
        }
        let distance = distanceFromBottom
        if delta < 0, distance > 1 {
            setFollowing(false)
        } else if delta > 0, distance <= 1, !holdUnpinned {
            setFollowing(true)
        }
    }

    /// Fires the callbacks asynchronously to avoid mutating SwiftUI `@State`
    /// during a view update.
    private func setFollowing(_ following: Bool) {
        guard following != isPinnedToBottom else { return }
        isPinnedToBottom = following
        let callback = following ? onScrolledToBottom : onScrolledAwayFromBottom
        DispatchQueue.main.async { callback?() }
    }
}
