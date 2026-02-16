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

    // MARK: - Callbacks

    var onScrolledToBottom: (() -> Void)?
    var onScrolledAwayFromBottom: (() -> Void)?

    // MARK: - Private State

    private weak var scrollView: NSScrollView?
    private weak var tableView: NSTableView?

    /// Observer token for clip-view bounds changes.
    /// `nonisolated(unsafe)` so `deinit` can access it without actor isolation.
    nonisolated(unsafe) private var boundsObserver: NSObjectProtocol?

    /// Saved scroll anchor (row + pixel offset).
    private var savedAnchor: Anchor?

    private struct Anchor {
        let row: Int
        let offsetFromRowTop: CGFloat
    }

    // MARK: - Setup & Teardown

    func attach(to scrollView: NSScrollView, tableView: NSTableView) {
        self.scrollView = scrollView
        self.tableView = tableView

        let clipView = scrollView.contentView
        clipView.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clipView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleBoundsChanged() }
        }
    }

    deinit {
        if let observer = boundsObserver {
            NotificationCenter.default.removeObserver(observer)
        }
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
        savedAnchor = Anchor(row: topRow, offsetFromRowTop: topY - rowRect.origin.y)
    }

    /// Restore position from the saved anchor. Call **after** the snapshot completes.
    func restoreAnchor() {
        guard let tableView, let scrollView, let anchor = savedAnchor else { return }
        savedAnchor = nil

        let clampedRow = min(anchor.row, tableView.numberOfRows - 1)
        guard clampedRow >= 0 else { return }

        let rowRect = tableView.rect(ofRow: clampedRow)
        let targetY = rowRect.origin.y + anchor.offsetFromRowTop

        // Skip if already at the target (within 1pt). This breaks a potential
        // feedback loop where setBoundsOrigin → boundsDidChange → SwiftUI
        // re-render → updateNSView → applyBlocks → restoreAnchor → ...
        guard abs(scrollView.contentView.bounds.origin.y - targetY) > 1.0 else { return }

        setScrollOriginY(targetY)
    }

    // MARK: - Scroll Actions

    /// Scroll to the very bottom of the content.
    /// Uses clip view bounds directly rather than `scrollRowToVisible`,
    /// which only ensures a row is visible but won't fully scroll to the end.
    func scrollToBottom(animated: Bool = false) {
        guard let scrollView, let documentView = scrollView.documentView else { return }
        let clipView = scrollView.contentView
        let maxY = max(0, documentView.frame.height - clipView.bounds.height)

        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.allowsImplicitAnimation = true
                clipView.setBoundsOrigin(NSPoint(x: clipView.bounds.origin.x, y: maxY))
            }
            scrollView.reflectScrolledClipView(clipView)
        } else {
            setScrollOriginY(maxY)
        }
    }

    /// Scroll so that the given row is visible.
    func scrollToRow(_ row: Int, animated: Bool = false) {
        guard let tableView, row >= 0, row < tableView.numberOfRows else { return }
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

    /// Re-check pinned state against the current scroll position.
    /// Call after the initial snapshot or any layout that doesn't trigger
    /// `boundsDidChangeNotification` (e.g. content growing while the
    /// clip view stays at origin 0,0).
    func checkPinnedState() {
        handleBoundsChanged()
    }

    // MARK: - Private Helpers

    /// Set the clip view's vertical scroll origin and notify the scroll view.
    private func setScrollOriginY(_ y: CGFloat) {
        guard let scrollView else { return }
        let clipView = scrollView.contentView
        clipView.setBoundsOrigin(NSPoint(x: clipView.bounds.origin.x, y: y))
        scrollView.reflectScrolledClipView(clipView)
    }

    /// Called on every clip-view bounds change (i.e. scroll). Fires pinned-state
    /// callbacks asynchronously to avoid mutating SwiftUI `@State` during a view update.
    private func handleBoundsChanged() {
        guard let scrollView else { return }
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
