//
//  TableViewComponents.swift
//  osaurus
//
//  Shared AppKit components used by NSTableView-backed representables
//  (CapabilitiesTableRepresentable, ModelPickerTableRepresentable).
//

import AppKit
import SwiftUI

// MARK: - Hover-Tracking Table View

/// NSTableView subclass that forwards mouse-tracking events to closures
/// for centralized hover state management (wired by coordinators).
@MainActor
final class HoverTrackingTableView: NSTableView {

    var onMouseMoved: ((NSEvent) -> Void)?
    var onMouseExited: (() -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self {
            removeTrackingArea(area)
        }
        addTrackingArea(
            NSTrackingArea(
                rect: .zero,
                options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
        )
    }

    override func mouseMoved(with event: NSEvent) { onMouseMoved?(event) }
    override func mouseEntered(with event: NSEvent) { onMouseMoved?(event) }
    override func mouseExited(with event: NSEvent) { onMouseExited?() }

    /// Allow NSTextView and other editable/selectable subviews inside cells
    /// to become first responder without requiring the row to be selected first.
    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool {
        if responder is NSTextView || responder is NSTextField { return true }
        // code block copy buttons, tool row headers, etc.
        if responder is NSButton { return true }
        return super.validateProposedFirstResponder(responder, for: event)
    }

    /// True when our own code is performing an explicit scroll. Lets us
    /// distinguish intentional scrolls (`ScrollAnchorManager.scrollToRow`)
    /// from subview-initiated auto-scrolls (`NSTextView` showing its
    /// caret as it lays out during measurement, link-related text view
    /// movements, focus-driven `scrollRectToVisible`).
    nonisolated(unsafe) static var allowProgrammaticScroll: Bool = false

    /// Block subview-initiated auto-scrolls.
    ///
    /// NSTextView (used by `SelectableNSTextView`, `CodeNSTextView`,
    /// `CustomNSTextView` inside cells) calls `scrollRangeToVisible` to
    /// keep its caret/selection in view. During cell dequeue +
    /// measurement that walks up to our chat scroll view and yanks
    /// `clip.y` to the text view's y position — visible as a multi-row
    /// "snap to message top" mid-gesture (verified via NSLog instrumentation:
    /// −616pt single-frame jumps with no preceding `noteHeightOfRows` or
    /// self-mutation).
    ///
    /// Our chat scroll position is managed exclusively by
    /// `ScrollAnchorManager` (gestures + `scrollToBottom` / `scrollToRow`).
    /// Any other call to `scrollRectToVisible` originating
    /// from a subview is, by definition, unwanted, so we drop it.
    /// Programmatic callers gate the call with
    /// `allowProgrammaticScroll = true`.
    override func scrollToVisible(_ rect: NSRect) -> Bool {
        if Self.allowProgrammaticScroll {
            return super.scrollToVisible(rect)
        }
        return false
    }
}

// MARK: - Table Hosting Cell View (AnyView - Legacy)

/// NSTableCellView subclass that hosts SwiftUI row views via NSHostingView
/// using AnyView type erasure. Kept for backward compatibility with any
/// callers that pass heterogeneous view types through a single cell pool.
@MainActor
final class TableHostingCellView: NSTableCellView {

    static let reuseIdentifier = NSUserInterfaceItemIdentifier("TableHostingCellView")

    private var hostingView: NSHostingView<AnyView>?
    private(set) var rowId: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure<V: View>(id: String, content: V) {
        rowId = id

        let wrapped = AnyView(content)

        if let hostingView {
            hostingView.rootView = wrapped
        } else {
            createHostingView(rootView: wrapped)
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        rowId = nil
    }

    private func createHostingView(rootView: AnyView) {
        let hv = NSHostingView(rootView: rootView)
        hv.translatesAutoresizingMaskIntoConstraints = true
        hv.autoresizingMask = [.width, .height]
        hv.frame = bounds
        hv.layer?.backgroundColor = NSColor.clear.cgColor

        addSubview(hv)
        hostingView = hv
    }
}

// MARK: - Typed Hosting Cell View

/// Generic NSTableCellView that hosts a concrete SwiftUI view type via
/// NSHostingView<Content>. Preserves structural identity so SwiftUI can
/// diff efficiently (no AnyView erasure).
///
/// Each reuse identifier pool should map to exactly one Content type.
/// On reconfiguration, `rootView` is updated in place which is significantly
/// cheaper than recreating the hosting view hierarchy.
@MainActor
final class TypedHostingCellView<Content: View>: NSTableCellView {

    private var hostingView: NSHostingView<Content>?
    private(set) var rowId: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(id: String, content: Content) {
        rowId = id

        if let hostingView {
            hostingView.rootView = content
        } else {
            let hv = NSHostingView(rootView: content)
            hv.translatesAutoresizingMaskIntoConstraints = true
            hv.autoresizingMask = [.width, .height]
            hv.frame = bounds
            hv.layer?.backgroundColor = NSColor.clear.cgColor

            addSubview(hv)
            hostingView = hv
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        rowId = nil
    }
}
