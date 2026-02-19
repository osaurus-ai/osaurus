//
//  MessageCellView.swift
//  osaurus
//
//  NSTableCellView subclass that hosts a SwiftUI ContentBlockView
//  via NSHostingView. Supports efficient cell reuse: on reconfiguration
//  we update `rootView` in place rather than tearing down the hosting view.
//
//  Row heights are derived automatically via `usesAutomaticRowHeights`
//  on the table view -- the hosting view's intrinsic content size drives
//  the row height through pinned Auto Layout constraints.
//

import AppKit
import SwiftUI

@MainActor
final class MessageCellView: NSTableCellView {

    static let reuseIdentifier = NSUserInterfaceItemIdentifier("MessageCellView")

    // MARK: - Private State

    /// The embedded hosting view rendering the SwiftUI content.
    private var hostingView: NSHostingView<AnyView>?

    /// Block ID currently displayed; used to detect reuse externally.
    private(set) var blockId: String?

    /// Horizontal padding (mirrors the original `.padding(.horizontal, 12)`).
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

    /// Configure with a content block and all required rendering context.
    ///
    /// If a hosting view already exists it updates `rootView` in place,
    /// which is significantly cheaper than recreating the view hierarchy.
    func configure(
        block: ContentBlock,
        width: CGFloat,
        agentName: String,
        isTurnHovered: Bool,
        theme: ThemeProtocol,
        expandedBlocksStore: ExpandedBlocksStore,
        onCopy: ((UUID) -> Void)?,
        onRegenerate: ((UUID) -> Void)?,
        onEdit: ((UUID) -> Void)?,
        onDelete: ((UUID) -> Void)?,
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
            agentName: agentName,
            isTurnHovered: isTurnHovered,
            onCopy: onCopy,
            onRegenerate: onRegenerate,
            onEdit: onEdit,
            onDelete: onDelete,
            onClarificationSubmit: onClarificationSubmit,
            editingTurnId: editingTurnId,
            editText: editText,
            onConfirmEdit: onConfirmEdit,
            onCancelEdit: onCancelEdit
        )
        .environment(\.theme, theme)
        .environmentObject(expandedBlocksStore)
        .padding(.horizontal, horizontalPadding)

        let wrapped = AnyView(contentView)

        if let hostingView {
            hostingView.rootView = wrapped
        } else {
            createHostingView(rootView: wrapped)
        }
    }

    // MARK: - Reuse

    override func prepareForReuse() {
        super.prepareForReuse()
        blockId = nil
        // Intentionally keep the hosting view alive -- updating rootView
        // on the next configure() is much cheaper than teardown + rebuild.
    }

    // MARK: - Private Helpers

    private func createHostingView(rootView: AnyView) {
        let hv = NSHostingView(rootView: rootView)
        hv.translatesAutoresizingMaskIntoConstraints = false
        hv.layer?.backgroundColor = NSColor.clear.cgColor

        addSubview(hv)

        // Pin all four edges. The table's `usesAutomaticRowHeights` derives
        // row height from these constraints + the hosting view's intrinsic
        // content size, so the row is always exactly as tall as its content.
        NSLayoutConstraint.activate([
            hv.topAnchor.constraint(equalTo: topAnchor),
            hv.leadingAnchor.constraint(equalTo: leadingAnchor),
            hv.trailingAnchor.constraint(equalTo: trailingAnchor),
            hv.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        hostingView = hv
    }
}
