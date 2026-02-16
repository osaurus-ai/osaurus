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
}

// MARK: - Table Hosting Cell View

/// Generic NSTableCellView subclass that hosts SwiftUI row views via
/// NSHostingView. Supports efficient cell reuse: on reconfiguration
/// we update `rootView` in place rather than tearing down the hosting view.
///
/// Uses autoresizing mask instead of Auto Layout to avoid constraint
/// conflicts between the hosting view's intrinsic content size and the
/// manually-specified row heights from `tableView(_:heightOfRow:)`.
@MainActor
final class TableHostingCellView: NSTableCellView {

    static let reuseIdentifier = NSUserInterfaceItemIdentifier("TableHostingCellView")

    // MARK: - Private State

    private var hostingView: NSHostingView<AnyView>?
    private(set) var rowId: String?

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - Configuration

    /// Configure with a SwiftUI view for the given row.
    ///
    /// If a hosting view already exists it updates `rootView` in place,
    /// which is significantly cheaper than recreating the view hierarchy.
    func configure<V: View>(id: String, content: V) {
        rowId = id

        let wrapped = AnyView(content)

        if let hostingView {
            hostingView.rootView = wrapped
        } else {
            createHostingView(rootView: wrapped)
        }
    }

    // MARK: - Reuse

    override func prepareForReuse() {
        super.prepareForReuse()
        rowId = nil
    }

    // MARK: - Private Helpers

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
