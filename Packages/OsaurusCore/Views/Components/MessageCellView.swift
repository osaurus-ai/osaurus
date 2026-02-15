//
//  MessageCellView.swift
//  osaurus
//
//  NSTableCellView subclass that hosts a SwiftUI ContentBlockView
//  via NSHostingView. Supports efficient cell reuse by updating
//  the hosting view's rootView on reconfiguration.
//

import AppKit
import SwiftUI

@MainActor
final class MessageCellView: NSTableCellView {

    static let reuseIdentifier = NSUserInterfaceItemIdentifier("MessageCellView")

    /// The embedded hosting view that renders the SwiftUI ContentBlockView.
    private var hostingView: NSHostingView<AnyView>?

    /// The block ID currently displayed, used to detect reuse.
    private(set) var blockId: String?

    /// Horizontal padding applied by the parent (mirrors `.padding(.horizontal, 12)` from original).
    private let horizontalPadding: CGFloat = 12

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

    /// Configure this cell with a content block and all required context.
    /// If the cell already has a hosting view, it updates `rootView` in place
    /// (avoiding teardown / rebuild). Otherwise, it creates the hosting view.
    func configure(
        block: ContentBlock,
        width: CGFloat,
        personaName: String,
        isTurnHovered: Bool,
        theme: ThemeProtocol,
        onCopy: ((UUID) -> Void)?,
        onRegenerate: ((UUID) -> Void)?,
        onEdit: ((UUID) -> Void)?,
        onClarificationSubmit: ((String) -> Void)?,
        editingTurnId: UUID?,
        editText: Binding<String>?,
        onConfirmEdit: (() -> Void)?,
        onCancelEdit: (() -> Void)?
    ) {
        blockId = block.id

        let contentView = ContentBlockView(
            block: block,
            width: width,
            personaName: personaName,
            isTurnHovered: isTurnHovered,
            onCopy: onCopy,
            onRegenerate: onRegenerate,
            onEdit: onEdit,
            onClarificationSubmit: onClarificationSubmit,
            editingTurnId: editingTurnId,
            editText: editText,
            onConfirmEdit: onConfirmEdit,
            onCancelEdit: onCancelEdit
        )
        .environment(\.theme, theme)
        .padding(.horizontal, horizontalPadding)

        let wrappedView = AnyView(contentView)

        if let hostingView = hostingView {
            hostingView.rootView = wrappedView
        } else {
            let hv = NSHostingView(rootView: wrappedView)
            hv.translatesAutoresizingMaskIntoConstraints = false
            // Transparent background so the table view's own background shows through.
            hv.layer?.backgroundColor = NSColor.clear.cgColor
            addSubview(hv)
            NSLayoutConstraint.activate([
                hv.topAnchor.constraint(equalTo: topAnchor),
                hv.leadingAnchor.constraint(equalTo: leadingAnchor),
                hv.trailingAnchor.constraint(equalTo: trailingAnchor),
                hv.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            hostingView = hv
        }
    }

    // MARK: - Height Measurement

    /// Measures the intrinsic height of the hosted SwiftUI content for the given width.
    /// Returns `nil` if the hosting view has not been created yet.
    func measuredHeight(forWidth width: CGFloat) -> CGFloat? {
        guard let hostingView else { return nil }
        let fitting = hostingView.fittingSize
        // fittingSize can return zero before first layout pass
        guard fitting.height > 0 else { return nil }
        return fitting.height
    }

    // MARK: - Reuse

    override func prepareForReuse() {
        super.prepareForReuse()
        blockId = nil
        // We intentionally do NOT remove the hosting view here.
        // It will be reconfigured via configure() which is cheaper
        // than tearing down and re-creating the NSHostingView.
    }
}
