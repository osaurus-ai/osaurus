//
//  MessageTableRepresentable.swift
//  osaurus
//
//  NSViewRepresentable that wraps an NSTableView for virtualized,
//  cell-reusing chat message rendering. Uses NSDiffableDataSource
//  for efficient updates and provides stable scroll anchoring
//  during streaming.
//

import AppKit
import SwiftUI

// MARK: - Section Identifier

/// Single-section enum for the diffable data source.
enum MessageSection: Hashable {
    case main
}

// MARK: - Hover-Tracking Table View

/// Custom NSTableView subclass that forwards mouse tracking events
/// to the coordinator for hover state management.
@MainActor
private final class HoverTrackingTableView: NSTableView {

    /// Callback invoked on mouse move / enter (passes the event).
    var onMouseMoved: ((NSEvent) -> Void)?
    /// Callback invoked on mouse exit.
    var onMouseExited: (() -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // Remove old tracking areas owned by this view.
        for area in trackingAreas where area.owner === self {
            removeTrackingArea(area)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    override func mouseMoved(with event: NSEvent) {
        onMouseMoved?(event)
    }

    override func mouseEntered(with event: NSEvent) {
        onMouseMoved?(event)
    }

    override func mouseExited(with event: NSEvent) {
        onMouseExited?()
    }
}

// MARK: - MessageTableRepresentable

struct MessageTableRepresentable: NSViewRepresentable {

    let blocks: [ContentBlock]
    let groupHeaderMap: [UUID: UUID]
    let width: CGFloat
    let personaName: String
    let isStreaming: Bool
    let lastAssistantTurnId: UUID?
    let autoScrollEnabled: Bool
    let theme: ThemeProtocol

    // Scroll callbacks
    let onScrolledToBottom: () -> Void
    let onScrolledAwayFromBottom: () -> Void

    // Message action callbacks
    let onCopy: ((UUID) -> Void)?
    let onRegenerate: ((UUID) -> Void)?
    let onEdit: ((UUID) -> Void)?
    let onClarificationSubmit: ((String) -> Void)?

    // Inline editing state
    let editingTurnId: UUID?
    let editText: Binding<String>?
    let onConfirmEdit: (() -> Void)?
    let onCancelEdit: (() -> Void)?

    // MARK: - NSViewRepresentable

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator

        // --- Table View ---
        let tableView = HoverTrackingTableView()
        tableView.style = .plain
        tableView.headerView = nil              // No column headers
        tableView.rowSizeStyle = .custom
        tableView.selectionHighlightStyle = .none
        tableView.backgroundColor = .clear
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.refusesFirstResponder = true  // Don't steal focus from input
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.gridStyleMask = []

        // Single column that fills the width.
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("MessageColumn"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        tableView.delegate = coordinator

        // --- Scroll View ---
        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        // Extra inset at top and bottom to mirror the original padding.
        scrollView.contentInsets = NSEdgeInsets(top: 8, left: 0, bottom: 24, right: 0)

        // Store references.
        coordinator.tableView = tableView
        coordinator.scrollView = scrollView

        // --- Diffable Data Source ---
        coordinator.dataSource = NSTableViewDiffableDataSource<MessageSection, String>(
            tableView: tableView
        ) { tableView, tableColumn, row, itemIdentifier in
            coordinator.makeOrConfigureCell(tableView: tableView, row: row, blockId: itemIdentifier)
        }

        // --- Scroll Anchor Manager ---
        coordinator.scrollAnchor.onScrolledToBottom = onScrolledToBottom
        coordinator.scrollAnchor.onScrolledAwayFromBottom = onScrolledAwayFromBottom
        coordinator.scrollAnchor.attach(to: scrollView, tableView: tableView)

        // --- Hover Tracking ---
        tableView.onMouseMoved = { [weak coordinator] event in
            coordinator?.handleMouseMoved(with: event)
        }
        tableView.onMouseExited = { [weak coordinator] in
            coordinator?.setHoveredGroup(nil)
        }

        // Initial snapshot.
        coordinator.applyBlocks(
            blocks,
            groupHeaderMap: groupHeaderMap,
            width: width,
            personaName: personaName,
            isStreaming: isStreaming,
            lastAssistantTurnId: lastAssistantTurnId,
            autoScrollEnabled: autoScrollEnabled,
            theme: theme,
            onCopy: onCopy,
            onRegenerate: onRegenerate,
            onEdit: onEdit,
            onClarificationSubmit: onClarificationSubmit,
            editingTurnId: editingTurnId,
            editText: editText,
            onConfirmEdit: onConfirmEdit,
            onCancelEdit: onCancelEdit
        )

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator

        // Update scroll callbacks (these may be recreated each SwiftUI pass).
        coordinator.scrollAnchor.onScrolledToBottom = onScrolledToBottom
        coordinator.scrollAnchor.onScrolledAwayFromBottom = onScrolledAwayFromBottom

        coordinator.applyBlocks(
            blocks,
            groupHeaderMap: groupHeaderMap,
            width: width,
            personaName: personaName,
            isStreaming: isStreaming,
            lastAssistantTurnId: lastAssistantTurnId,
            autoScrollEnabled: autoScrollEnabled,
            theme: theme,
            onCopy: onCopy,
            onRegenerate: onRegenerate,
            onEdit: onEdit,
            onClarificationSubmit: onClarificationSubmit,
            editingTurnId: editingTurnId,
            editText: editText,
            onConfirmEdit: onConfirmEdit,
            onCancelEdit: onCancelEdit
        )
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTableViewDelegate {

        // --- AppKit references ---
        weak var tableView: NSTableView?
        weak var scrollView: NSScrollView?

        var dataSource: NSTableViewDiffableDataSource<MessageSection, String>?

        // --- State ---
        let scrollAnchor = ScrollAnchorManager()

        /// Lookup from block.id → ContentBlock for the current snapshot.
        var blockLookup: [String: ContentBlock] = [:]

        /// Ordered block IDs (mirrors the current snapshot).
        var blockIds: [String] = []

        /// Height cache keyed by block ID.
        var heightCache: [String: CGFloat] = [:]

        /// The block ID currently being streamed (for fast-path updates).
        var streamingBlockId: String?

        /// The last assistant turn ID we scrolled to (to avoid repeated scrolls).
        var lastScrolledToTurnId: UUID?

        // --- Rendering context (updated each pass) ---
        var currentGroupHeaderMap: [UUID: UUID] = [:]
        var currentWidth: CGFloat = 400
        var currentPersonaName: String = ""
        var currentTheme: ThemeProtocol = LightTheme()
        var currentOnCopy: ((UUID) -> Void)?
        var currentOnRegenerate: ((UUID) -> Void)?
        var currentOnEdit: ((UUID) -> Void)?
        var currentOnClarificationSubmit: ((String) -> Void)?
        var currentEditingTurnId: UUID?
        var currentEditText: Binding<String>?
        var currentOnConfirmEdit: (() -> Void)?
        var currentOnCancelEdit: (() -> Void)?

        // --- Hover state ---
        var hoveredGroupId: UUID?

        // MARK: - Apply Blocks

        func applyBlocks(
            _ blocks: [ContentBlock],
            groupHeaderMap: [UUID: UUID],
            width: CGFloat,
            personaName: String,
            isStreaming: Bool,
            lastAssistantTurnId: UUID?,
            autoScrollEnabled: Bool,
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
            // Update rendering context.
            currentGroupHeaderMap = groupHeaderMap
            let contentWidth = max(100, width - 64)
            let widthChanged = abs(currentWidth - contentWidth) > 1.0
            currentWidth = contentWidth
            currentPersonaName = personaName
            currentTheme = theme
            currentOnCopy = onCopy
            currentOnRegenerate = onRegenerate
            currentOnEdit = onEdit
            currentOnClarificationSubmit = onClarificationSubmit
            currentEditingTurnId = editingTurnId
            currentEditText = editText
            currentOnConfirmEdit = onConfirmEdit
            currentOnCancelEdit = onCancelEdit

            // Build new lookup.
            let newIds = blocks.map(\.id)
            var newLookup: [String: ContentBlock] = [:]
            newLookup.reserveCapacity(blocks.count)
            for block in blocks {
                newLookup[block.id] = block
            }

            // If width changed, invalidate the entire height cache.
            if widthChanged {
                heightCache.removeAll(keepingCapacity: true)
            }

            // Detect streaming block (last paragraph that is marked streaming).
            let newStreamingBlockId: String? = {
                if isStreaming, let last = blocks.last(where: {
                    if case .paragraph(_, _, true, _) = $0.kind { return true }
                    if case .thinking(_, _, true) = $0.kind { return true }
                    return false
                }) {
                    return last.id
                }
                return nil
            }()

            // --- Streaming fast path ---
            // If only the streaming block content changed (same block set, same IDs),
            // update just that cell directly without a full snapshot reapply.
            if !widthChanged,
               newIds == blockIds,
               let streamId = newStreamingBlockId,
               let newBlock = newLookup[streamId],
               let oldBlock = blockLookup[streamId],
               newBlock != oldBlock
            {
                blockLookup = newLookup
                streamingBlockId = streamId

                // Direct cell update.
                if let row = blockIds.firstIndex(of: streamId),
                   let tableView,
                   let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? MessageCellView
                {
                    let groupId = currentGroupHeaderMap[newBlock.turnId] ?? newBlock.turnId
                    cell.configure(
                        block: newBlock,
                        width: currentWidth,
                        personaName: currentPersonaName,
                        isTurnHovered: hoveredGroupId == groupId,
                        theme: currentTheme,
                        onCopy: currentOnCopy,
                        onRegenerate: currentOnRegenerate,
                        onEdit: currentOnEdit,
                        onClarificationSubmit: currentOnClarificationSubmit,
                        editingTurnId: currentEditingTurnId,
                        editText: currentEditText,
                        onConfirmEdit: currentOnConfirmEdit,
                        onCancelEdit: currentOnCancelEdit
                    )

                    // Schedule height re-measurement on next layout pass.
                    DispatchQueue.main.async { [weak self] in
                        self?.remeasureRowHeight(row: row, blockId: streamId)
                    }
                }

                // Keep scroll pinned to bottom during streaming.
                if scrollAnchor.isPinnedToBottom {
                    scrollAnchor.scrollToBottom()
                }
                return
            }

            // --- Full snapshot path ---
            let oldLookup = blockLookup
            blockLookup = newLookup
            blockIds = newIds
            streamingBlockId = newStreamingBlockId

            // Invalidate heights for blocks that changed content.
            for id in newIds {
                if let newBlock = newLookup[id], let oldBlock = oldLookup[id], newBlock != oldBlock {
                    heightCache.removeValue(forKey: id)
                }
            }

            // Save scroll anchor before snapshot changes layout.
            scrollAnchor.saveAnchor()

            // Apply diffable snapshot.
            var snapshot = NSDiffableDataSourceSnapshot<MessageSection, String>()
            snapshot.appendSections([.main])
            snapshot.appendItems(newIds, toSection: .main)

            dataSource?.apply(snapshot, animatingDifferences: false) { [weak self] in
                guard let self else { return }

                if self.scrollAnchor.isPinnedToBottom {
                    self.scrollAnchor.scrollToBottom()
                } else {
                    self.scrollAnchor.restoreAnchor()
                }

                // Scroll to new assistant response if needed.
                if autoScrollEnabled,
                   let turnId = lastAssistantTurnId,
                   turnId != self.lastScrolledToTurnId
                {
                    self.lastScrolledToTurnId = turnId
                    let headerId = "header-\(turnId.uuidString)"
                    if let row = self.blockIds.firstIndex(of: headerId) {
                        self.scrollAnchor.scrollToRow(row, animated: true)
                    }
                }
            }
        }

        // MARK: - Cell Factory

        func makeOrConfigureCell(tableView: NSTableView, row: Int, blockId: String) -> NSView {
            let cell: MessageCellView
            if let reused = tableView.makeView(
                withIdentifier: MessageCellView.reuseIdentifier,
                owner: nil
            ) as? MessageCellView {
                cell = reused
            } else {
                cell = MessageCellView(frame: .zero)
                cell.identifier = MessageCellView.reuseIdentifier
            }

            guard let block = blockLookup[blockId] else { return cell }

            let groupId = currentGroupHeaderMap[block.turnId] ?? block.turnId
            cell.configure(
                block: block,
                width: currentWidth,
                personaName: currentPersonaName,
                isTurnHovered: hoveredGroupId == groupId,
                theme: currentTheme,
                onCopy: currentOnCopy,
                onRegenerate: currentOnRegenerate,
                onEdit: currentOnEdit,
                onClarificationSubmit: currentOnClarificationSubmit,
                editingTurnId: currentEditingTurnId,
                editText: currentEditText,
                onConfirmEdit: currentOnConfirmEdit,
                onCancelEdit: currentOnCancelEdit
            )

            // Schedule post-layout height correction.
            DispatchQueue.main.async { [weak self] in
                self?.remeasureRowHeight(row: row, blockId: blockId)
            }

            return cell
        }

        // MARK: - NSTableViewDelegate (Height)

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard row < blockIds.count else { return 44 }
            let blockId = blockIds[row]

            // Tier 1: cached height.
            if let cached = heightCache[blockId] {
                return cached
            }

            // Tier 2: estimate based on block kind.
            guard let block = blockLookup[blockId] else { return 44 }
            return estimateHeight(for: block)
        }

        /// Returns a reasonable height estimate for the given block kind,
        /// used before the first layout pass measures the actual height.
        private func estimateHeight(for block: ContentBlock) -> CGFloat {
            switch block.kind {
            case .groupSpacer:
                return 16
            case .header:
                return 48
            case .typingIndicator:
                return 48
            case let .paragraph(_, text, _, _):
                // Rough estimate: ~60 chars per line at typical width, ~20pt per line.
                let lineEstimate = max(1, CGFloat(text.count) / 60.0)
                return max(44, lineEstimate * 20 + 24)
            case let .thinking(_, text, _):
                let lineEstimate = max(1, CGFloat(text.count) / 60.0)
                return max(44, lineEstimate * 20 + 28)
            case let .toolCallGroup(calls):
                return CGFloat(calls.count) * 36 + 28
            case .clarification:
                return 120
            case .image:
                return 170
            }
        }

        // MARK: - Height Re-measurement

        /// After a cell lays out, measure its actual height and update the
        /// cache + table view if it differs from the current row height.
        private func remeasureRowHeight(row: Int, blockId: String) {
            guard let tableView,
                  row < tableView.numberOfRows,
                  let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? MessageCellView
            else { return }

            guard let measured = cell.measuredHeight(forWidth: tableView.bounds.width) else { return }

            let current = heightCache[blockId] ?? tableView.rect(ofRow: row).height
            guard abs(measured - current) > 1.0 else { return }

            heightCache[blockId] = measured

            NSAnimationContext.beginGrouping()
            NSAnimationContext.current.duration = 0
            tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row))
            NSAnimationContext.endGrouping()

            // Keep pinned to bottom after height adjustments.
            if scrollAnchor.isPinnedToBottom {
                scrollAnchor.scrollToBottom()
            }
        }

        // MARK: - Hover Tracking

        func handleMouseMoved(with event: NSEvent) {
            guard let tableView else {
                setHoveredGroup(nil)
                return
            }

            let locationInTable = tableView.convert(event.locationInWindow, from: nil)
            let row = tableView.row(at: locationInTable)

            guard row >= 0, row < blockIds.count else {
                setHoveredGroup(nil)
                return
            }

            let blockId = blockIds[row]
            guard let block = blockLookup[blockId] else {
                setHoveredGroup(nil)
                return
            }

            let groupId = currentGroupHeaderMap[block.turnId] ?? block.turnId
            setHoveredGroup(groupId)
        }

        func setHoveredGroup(_ newGroupId: UUID?) {
            guard hoveredGroupId != newGroupId else { return }
            let oldGroupId = hoveredGroupId
            hoveredGroupId = newGroupId

            // Reconfigure visible cells whose hover state changed.
            guard let tableView else { return }
            let visibleRange = tableView.rows(in: tableView.visibleRect)
            guard visibleRange.length > 0 else { return }

            for row in visibleRange.location ..< (visibleRange.location + visibleRange.length) {
                guard row < blockIds.count else { continue }
                let blockId = blockIds[row]
                guard let block = blockLookup[blockId] else { continue }

                let groupId = currentGroupHeaderMap[block.turnId] ?? block.turnId

                // Only reconfigure cells that belong to the old or new hovered group.
                guard groupId == oldGroupId || groupId == newGroupId else { continue }

                if let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? MessageCellView {
                    cell.configure(
                        block: block,
                        width: currentWidth,
                        personaName: currentPersonaName,
                        isTurnHovered: hoveredGroupId == groupId,
                        theme: currentTheme,
                        onCopy: currentOnCopy,
                        onRegenerate: currentOnRegenerate,
                        onEdit: currentOnEdit,
                        onClarificationSubmit: currentOnClarificationSubmit,
                        editingTurnId: currentEditingTurnId,
                        editText: currentEditText,
                        onConfirmEdit: currentOnConfirmEdit,
                        onCancelEdit: currentOnCancelEdit
                    )
                }
            }
        }

        // MARK: - NSTableViewDelegate (Selection)

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
            false // Chat rows are not selectable.
        }
    }
}
