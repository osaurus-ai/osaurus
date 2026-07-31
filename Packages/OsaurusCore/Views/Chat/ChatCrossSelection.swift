//
//  ChatCrossSelection.swift
//  osaurus
//
//  Continuous drag-selection across the chat thread's block text views.
//
//  Each markdown block (paragraph, heading, code block, table cell) renders
//  in its own NSTextView, and each block is its own NSTableView row — so
//  AppKit's native mouse tracking can never extend a selection past the
//  block where the drag started (issue #2129). This controller takes over
//  the drag gesture from any participating text view and maintains one
//  logical selection spanning every block between the anchor and the
//  cursor, ChatGPT-style.
//
//  Rendering: each participating view is handed its slice of the logical
//  selection (`crossSelectionRange`) and paints it itself at the top of
//  `draw(_:)` — these views run with drawsBackground = false, which makes
//  AppKit skip the background pass where selection attributes would
//  normally render, so native selectedRange / temporary attributes never
//  show. Cmd+C is served from a snapshot string rebuilt on every drag
//  tick, so copying still works after cell recycling has torn down
//  off-screen block views.
//

import AppKit

/// Text views that participate in cross-block chat selection. Adopters must
/// route single-click (non-link) mouseDowns to
/// `ChatCrossSelection.shared.beginDrag(from:with:)`, and their `draw(_:)`
/// must call `drawCrossSelectionHighlight()` first — these views have
/// `drawsBackground = false`, which makes AppKit skip the background pass
/// where selection-style attributes would normally render, so the highlight
/// has to be painted explicitly.
protocol CrossSelectableTextView: NSTextView {
    /// This view's slice of the thread-wide selection; nil when none.
    var crossSelectionRange: NSRange? { get set }
}

extension NSTextView {
    /// Shared `cursorUpdate` body for chat block text views: I-beam over
    /// text, pointing hand over links. Legacy cursor rects
    /// (`resetCursorRects`) are unreliable inside layer-backed, recycled
    /// table cells, so these views drive the cursor from a `.cursorUpdate`
    /// tracking area instead.
    func chatTextCursorUpdate(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        if index < (textStorage?.length ?? 0),
            textStorage?.attribute(.link, at: index, effectiveRange: nil) != nil
        {
            NSCursor.pointingHand.set()
        } else {
            NSCursor.iBeam.set()
        }
    }
}

extension CrossSelectableTextView {
    /// Fills the line-fragment rects of `crossSelectionRange` with the
    /// view's selection color. Call at the top of `draw(_:)` so text renders
    /// on top of the highlight.
    func drawCrossSelectionHighlight() {
        guard let range = crossSelectionRange, range.length > 0,
            let lm = layoutManager, let tc = textContainer
        else { return }
        let color =
            (selectedTextAttributes[.backgroundColor] as? NSColor)
            ?? .selectedTextBackgroundColor
        color.setFill()
        let glyphs = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let origin = textContainerOrigin
        lm.enumerateEnclosingRects(
            forGlyphRange: glyphs, withinSelectedGlyphRange: glyphs, in: tc
        ) { rect, _ in
            rect.offsetBy(dx: origin.x, dy: origin.y).fill()
        }
    }
}

@MainActor
final class ChatCrossSelection {

    static let shared = ChatCrossSelection()
    private init() {}

    /// Views currently carrying a temporary-attribute highlight, with the
    /// highlighted range. Weak so recycled cells can die freely; their
    /// highlight is cleared on the next `clear()` if still alive.
    private struct AppliedHighlight {
        weak var view: (NSTextView & CrossSelectableTextView)?
        var range: NSRange
    }

    private var applied: [AppliedHighlight] = []
    /// Concatenated text of the current selection in document order.
    /// Rebuilt on every drag tick; survives view recycling.
    private(set) var selectionString: String = ""
    /// Window the current selection belongs to, so Cmd+C in one chat
    /// window can't copy a selection made in another.
    private weak var selectionWindow: NSWindow?

    var hasSelection: Bool { !selectionString.isEmpty }

    // MARK: - Drag gesture

    /// Owns the full drag gesture starting in `anchorView`. Blocks in a
    /// local event-tracking loop (same pattern as AppKit's own
    /// mouse-tracking) until mouse-up.
    func beginDrag(from anchorView: NSTextView, with event: NSEvent) {
        guard let window = anchorView.window else { return }
        clear()
        selectionWindow = window

        let anchorPoint = documentPoint(of: event, in: anchorView)
        let anchorIndex = anchorView.characterIndexForInsertion(
            at: anchorView.convert(event.locationInWindow, from: nil))

        // Anchor keeps a caret so keyboard focus behaves; the visible
        // highlight is painted per view via crossSelectionRange.
        anchorView.setSelectedRange(NSRange(location: anchorIndex, length: 0))

        while true {
            guard
                let next = window.nextEvent(
                    matching: [.leftMouseDragged, .leftMouseUp],
                    until: .distantFuture,
                    inMode: .eventTracking,
                    dequeue: true
                )
            else { break }
            if next.type == .leftMouseUp { break }
            autoscrollIfNeeded(for: next, anchorView: anchorView)
            updateSelection(
                anchorView: anchorView,
                anchorIndex: anchorIndex,
                anchorPoint: anchorPoint,
                focusEvent: next
            )
        }
    }

    /// Remove every painted highlight and drop the logical selection.
    func clear() {
        for entry in applied {
            entry.view?.crossSelectionRange = nil
        }
        applied = []
        selectionString = ""
        selectionWindow = nil
    }

    /// Copies the current cross-block selection if one exists for `window`.
    /// Returns true when the copy was handled.
    @discardableResult
    func copyIfActive(window: NSWindow?) -> Bool {
        guard hasSelection, let window, window === selectionWindow else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(selectionString, forType: .string)
        return true
    }

    // MARK: - Selection computation

    private func updateSelection(
        anchorView: NSTextView,
        anchorIndex: Int,
        anchorPoint: NSPoint,
        focusEvent: NSEvent
    ) {
        guard let documentView = anchorView.enclosingScrollView?.documentView else { return }
        let focusPoint = documentPoint(of: focusEvent, in: anchorView)

        // Reading order in the flipped table document: smaller y first,
        // then smaller x. Normalize so `start` precedes `end`.
        let anchorFirst =
            anchorPoint.y != focusPoint.y
            ? anchorPoint.y < focusPoint.y : anchorPoint.x <= focusPoint.x
        let start = anchorFirst ? anchorPoint : focusPoint
        let end = anchorFirst ? focusPoint : anchorPoint

        var newApplied: [AppliedHighlight] = []
        var pieces: [String] = []

        for view in participatingViews(in: documentView) {
            guard let storage = view.textStorage, storage.length > 0 else { continue }
            let frame = view.convert(view.bounds, to: documentView)
            let range: NSRange?
            if frame.maxY <= start.y || frame.minY >= end.y {
                // Entirely before the start line or after the end line.
                range = nil
            } else {
                let containsStart = frame.minY <= start.y && start.y < frame.maxY
                let containsEnd = frame.minY <= end.y && end.y < frame.maxY
                let startIdx =
                    containsStart
                    ? clampedIndex(in: view, documentPoint: start, documentView: documentView)
                    : 0
                let endIdx =
                    containsEnd
                    ? clampedIndex(in: view, documentPoint: end, documentView: documentView)
                    : storage.length
                range = startIdx < endIdx
                    ? NSRange(location: startIdx, length: endIdx - startIdx) : nil
            }

            view.crossSelectionRange = range
            if let range {
                newApplied.append(AppliedHighlight(view: view, range: range))
                pieces.append((storage.string as NSString).substring(with: range))
            }
        }

        // Views highlighted last tick that fell out of this tick's sweep
        // (drag shrank past them, or their cell got recycled out of the
        // enumeration) — drop their highlight explicitly.
        for old in applied where !newApplied.contains(where: { $0.view === old.view }) {
            old.view?.crossSelectionRange = nil
        }

        applied = newApplied
        selectionString = pieces.joined(separator: "\n")
    }

    /// All participating text views under `root` in reading order.
    /// Only instantiated (visible or near-visible) cells exist in an
    /// NSTableView, which is exactly the set a drag can sweep without
    /// autoscrolling; autoscroll re-enumerates on every tick.
    private func participatingViews(in root: NSView) -> [NSTextView & CrossSelectableTextView] {
        var found: [NSTextView & CrossSelectableTextView] = []
        func walk(_ view: NSView) {
            if let match = view as? NSTextView & CrossSelectableTextView,
                !match.isHiddenOrHasHiddenAncestor
            {
                found.append(match)
                return
            }
            for sub in view.subviews { walk(sub) }
        }
        walk(root)
        return found.sorted { a, b in
            let fa = a.convert(a.bounds, to: root)
            let fb = b.convert(b.bounds, to: root)
            if abs(fa.minY - fb.minY) > 0.5 { return fa.minY < fb.minY }
            return fa.minX < fb.minX
        }
    }

    /// Character index in `view` for a point given in document coordinates,
    /// with the point clamped into the view's bounds so drags in margins
    /// and inter-block gaps resolve to sensible line ends.
    private func clampedIndex(in view: NSTextView, documentPoint: NSPoint, documentView: NSView) -> Int {
        var p = view.convert(documentPoint, from: documentView)
        p.x = min(max(p.x, view.bounds.minX), view.bounds.maxX)
        p.y = min(max(p.y, view.bounds.minY), view.bounds.maxY)
        return view.characterIndexForInsertion(at: p)
    }

    /// Event location in the chat table's (flipped) document coordinates.
    private func documentPoint(of event: NSEvent, in anyChatView: NSView) -> NSPoint {
        guard let documentView = anyChatView.enclosingScrollView?.documentView else {
            return anyChatView.convert(event.locationInWindow, from: nil)
        }
        return documentView.convert(event.locationInWindow, from: nil)
    }

    // MARK: - Autoscroll

    /// Nudge the chat scroll view when the drag nears its vertical edges so
    /// selections can extend beyond the viewport, mirroring native NSTextView
    /// autoscroll (which we bypass by owning the tracking loop).
    private func autoscrollIfNeeded(for event: NSEvent, anchorView: NSTextView) {
        guard let scrollView = anchorView.enclosingScrollView else { return }
        let clip = scrollView.contentView
        let inClip = clip.convert(event.locationInWindow, from: nil)
        let visible = clip.bounds
        let margin: CGFloat = 28
        var target = visible.origin
        if inClip.y < visible.minY + margin {
            target.y -= min(24, (visible.minY + margin) - inClip.y)
        } else if inClip.y > visible.maxY - margin {
            target.y += min(24, inClip.y - (visible.maxY - margin))
        } else {
            return
        }
        // Clamp to the scrollable extent on both ends — an unclamped
        // downward autoscroll kept pushing past the last row and opened
        // empty space under the conversation.
        let docHeight = scrollView.documentView?.frame.height ?? 0
        let insets = clip.contentInsets
        let minY = -insets.top
        let maxY = max(minY, docHeight + insets.bottom - visible.height)
        target.y = min(max(minY, target.y), maxY)
        guard abs(target.y - visible.origin.y) > 0.01 else { return }
        clip.scroll(to: target)
        scrollView.reflectScrolledClipView(clip)
    }
}
