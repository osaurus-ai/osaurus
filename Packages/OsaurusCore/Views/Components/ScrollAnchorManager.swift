//
//  ScrollAnchorManager.swift
//  osaurus
//
//  Manages scroll anchoring for the NSTableView-backed chat thread.
//  Tracks whether the user is pinned to the bottom, and preserves
//  scroll position when content above the viewport changes.
//

import AppKit

@MainActor
final class ScrollAnchorManager {

    // MARK: - Public State

    /// Whether the scroll view is currently pinned to the bottom (within threshold).
    private(set) var isPinnedToBottom: Bool = true

    /// Threshold (in points) within which the user is considered "at the bottom".
    var bottomThreshold: CGFloat = 50

    // MARK: - Callbacks

    var onScrolledToBottom: (() -> Void)?
    var onScrolledAwayFromBottom: (() -> Void)?

    // MARK: - Private State

    private weak var scrollView: NSScrollView?
    private weak var tableView: NSTableView?
    /// Observer token for clip view bounds changes.
    /// Marked `nonisolated(unsafe)` so `deinit` can access it without actor isolation.
    nonisolated(unsafe) private var boundsObserver: NSObjectProtocol?

    /// Anchor used to preserve position when not pinned to bottom.
    private struct ScrollAnchor {
        let row: Int
        let offsetFromTop: CGFloat
    }
    private var savedAnchor: ScrollAnchor?

    // MARK: - Setup

    func attach(to scrollView: NSScrollView, tableView: NSTableView) {
        self.scrollView = scrollView
        self.tableView = tableView

        // Observe clip view bounds changes (scroll events).
        let clipView = scrollView.contentView
        clipView.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clipView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleBoundsChanged()
            }
        }
    }

    deinit {
        if let observer = boundsObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Scroll Position Queries

    /// Recalculates pinned state from the current scroll position.
    private func handleBoundsChanged() {
        guard let scrollView else { return }
        let wasPinned = isPinnedToBottom
        isPinnedToBottom = isAtBottom(scrollView: scrollView)

        if isPinnedToBottom && !wasPinned {
            onScrolledToBottom?()
        } else if !isPinnedToBottom && wasPinned {
            onScrolledAwayFromBottom?()
        }
    }

    private func isAtBottom(scrollView: NSScrollView) -> Bool {
        let clipView = scrollView.contentView
        let contentHeight = scrollView.documentView?.frame.height ?? 0
        let visibleHeight = clipView.bounds.height
        let scrollOffset = clipView.bounds.origin.y

        // In a flipped coordinate system (NSTableView is flipped),
        // we're at the bottom when scrollOffset + visibleHeight >= contentHeight - threshold.
        let distanceFromBottom = contentHeight - (scrollOffset + visibleHeight)
        return distanceFromBottom <= bottomThreshold
    }

    // MARK: - Anchor Save / Restore

    /// Save the current scroll anchor (topmost visible row + offset).
    /// Call this BEFORE applying a snapshot that may change row heights above the viewport.
    func saveAnchor() {
        guard let tableView, let scrollView, !isPinnedToBottom else {
            savedAnchor = nil
            return
        }

        let clipBounds = scrollView.contentView.bounds
        let visibleRect = clipBounds
        let topY = visibleRect.origin.y

        // Find the row at the top of the visible area.
        let topRow = tableView.row(at: NSPoint(x: 0, y: topY))
        guard topRow >= 0 else {
            savedAnchor = nil
            return
        }

        let rowRect = tableView.rect(ofRow: topRow)
        let offset = topY - rowRect.origin.y
        savedAnchor = ScrollAnchor(row: topRow, offsetFromTop: offset)
    }

    /// Restore scroll position from the saved anchor.
    /// Call this AFTER applying a snapshot and reloading changed rows.
    func restoreAnchor() {
        guard let tableView, let scrollView, let anchor = savedAnchor else { return }
        savedAnchor = nil

        // Clamp the anchor row in case rows were removed.
        let clampedRow = min(anchor.row, tableView.numberOfRows - 1)
        guard clampedRow >= 0 else { return }

        let rowRect = tableView.rect(ofRow: clampedRow)
        let newY = rowRect.origin.y + anchor.offsetFromTop

        let clipView = scrollView.contentView
        clipView.setBoundsOrigin(NSPoint(x: clipView.bounds.origin.x, y: newY))
        scrollView.reflectScrolledClipView(clipView)
    }

    // MARK: - Scroll Actions

    /// Scroll to the very bottom of the table.
    func scrollToBottom(animated: Bool = false) {
        guard let tableView, tableView.numberOfRows > 0 else { return }
        let lastRow = tableView.numberOfRows - 1

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                context.allowsImplicitAnimation = true
                tableView.scrollRowToVisible(lastRow)
            }
        } else {
            tableView.scrollRowToVisible(lastRow)
        }
    }

    /// Scroll so that the given row is visible at the top of the viewport.
    func scrollToRow(_ row: Int, animated: Bool = false) {
        guard let tableView, row >= 0, row < tableView.numberOfRows else { return }

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.allowsImplicitAnimation = true
                tableView.scrollRowToVisible(row)
            }
        } else {
            tableView.scrollRowToVisible(row)
        }
    }
}
