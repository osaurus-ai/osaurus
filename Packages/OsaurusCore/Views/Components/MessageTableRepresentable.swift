//
//  MessageTableRepresentable.swift
//  osaurus
//
//  NSViewRepresentable wrapping an NSTableView for the chat message thread.
//
//  Key design decisions:
//  - NSDiffableDataSource with block IDs for efficient structural updates.
//  - `usesAutomaticRowHeights` so Auto Layout derives row heights from
//    the hosting view's intrinsic content size (no manual estimation).
//  - Three update paths in `applyBlocks`:
//      1. No-change early return (skip if blocks are identical).
//      2. Streaming fast path (update a single cell in place).
//      3. Full snapshot (apply diff, restore scroll anchor).
//  - Streaming row heights are debounced via `noteHeightOfRows` so the
//    table re-measures at most once per `streamingHeightInterval`.
//

import AppKit
import SwiftUI

// MARK: - Supporting Types

/// Single-section identifier for the diffable data source.
enum MessageSection: Hashable {
    case main
}

/// Bundles all per-render context the coordinator needs to configure cells.
/// Avoids threading 12+ parameters through every method.
struct CellRenderingContext {
    let groupHeaderMap: [UUID: UUID]
    let width: CGFloat
    let personaName: String
    let theme: ThemeProtocol
    let onCopy: ((UUID) -> Void)?
    let onRegenerate: ((UUID) -> Void)?
    let onEdit: ((UUID) -> Void)?
    let onClarificationSubmit: ((String) -> Void)?
    let editingTurnId: UUID?
    let editText: Binding<String>?
    let onConfirmEdit: (() -> Void)?
    let onCancelEdit: (() -> Void)?
}

// MARK: - Hover-Tracking Table View

/// NSTableView subclass that forwards mouse tracking events
/// to closures (wired to the coordinator) for hover state.
@MainActor
fileprivate final class HoverTrackingTableView: NSTableView {

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

// MARK: - MessageTableRepresentable

struct MessageTableRepresentable: NSViewRepresentable {

    // Content
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

    // MARK: - NSViewRepresentable Lifecycle

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator
        let tableView = Self.makeTableView()
        let scrollView = Self.makeScrollView(documentView: tableView)

        coordinator.tableView = tableView
        coordinator.scrollView = scrollView
        coordinator.setupDataSource(for: tableView)
        coordinator.setupScrollAnchor(
            scrollView: scrollView,
            tableView: tableView,
            onScrolledToBottom: onScrolledToBottom,
            onScrolledAwayFromBottom: onScrolledAwayFromBottom
        )
        coordinator.setupHoverTracking(on: tableView)

        coordinator.applyBlocks(
            blocks,
            context: renderingContext,
            isStreaming: isStreaming,
            lastAssistantTurnId: lastAssistantTurnId,
            autoScrollEnabled: autoScrollEnabled
        )
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.scrollAnchor.onScrolledToBottom = onScrolledToBottom
        coordinator.scrollAnchor.onScrolledAwayFromBottom = onScrolledAwayFromBottom

        coordinator.applyBlocks(
            blocks,
            context: renderingContext,
            isStreaming: isStreaming,
            lastAssistantTurnId: lastAssistantTurnId,
            autoScrollEnabled: autoScrollEnabled
        )
    }

    // MARK: - Private Helpers

    private var renderingContext: CellRenderingContext {
        CellRenderingContext(
            groupHeaderMap: groupHeaderMap,
            width: max(100, width - 64),
            personaName: personaName,
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

    private static func makeTableView() -> HoverTrackingTableView {
        let tv = HoverTrackingTableView()
        tv.style = .plain
        tv.headerView = nil
        tv.rowSizeStyle = .custom
        tv.selectionHighlightStyle = .none
        tv.backgroundColor = .clear
        tv.intercellSpacing = .zero
        tv.usesAlternatingRowBackgroundColors = false
        tv.refusesFirstResponder = true
        tv.allowsMultipleSelection = false
        tv.allowsEmptySelection = true
        tv.gridStyleMask = []
        tv.usesAutomaticRowHeights = true

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("MessageColumn"))
        column.resizingMask = .autoresizingMask
        tv.addTableColumn(column)
        return tv
    }

    private static func makeScrollView(documentView: NSView) -> NSScrollView {
        let sv = NSScrollView()
        sv.documentView = documentView
        sv.hasVerticalScroller = true
        sv.hasHorizontalScroller = false
        sv.autohidesScrollers = true
        sv.drawsBackground = false
        sv.contentView.drawsBackground = false
        sv.contentInsets = NSEdgeInsets(top: 8, left: 0, bottom: 24, right: 0)
        return sv
    }
}

// MARK: - Coordinator

extension MessageTableRepresentable {

    @MainActor
    final class Coordinator: NSObject, NSTableViewDelegate {

        // MARK: AppKit References

        weak var tableView: NSTableView?
        weak var scrollView: NSScrollView?
        private(set) var dataSource: NSTableViewDiffableDataSource<MessageSection, String>?

        // MARK: Scroll

        let scrollAnchor = ScrollAnchorManager()

        // MARK: Block State

        /// Ordered block IDs matching the current snapshot.
        private(set) var blockIds: [String] = []
        /// Block lookup keyed by block ID.
        private(set) var blockLookup: [String: ContentBlock] = [:]
        /// The block ID currently streaming (for fast-path updates).
        private var streamingBlockId: String?
        /// The assistant turn ID we already scrolled to (fire-once guard).
        private var lastScrolledToTurnId: UUID?

        // MARK: Rendering Context

        /// Current cell rendering context, updated every `applyBlocks` call.
        private var ctx = CellRenderingContext(
            groupHeaderMap: [:],
            width: 400,
            personaName: "",
            theme: LightTheme(),
            onCopy: nil,
            onRegenerate: nil,
            onEdit: nil,
            onClarificationSubmit: nil,
            editingTurnId: nil,
            editText: nil,
            onConfirmEdit: nil,
            onCancelEdit: nil
        )

        // MARK: Hover

        private var hoveredGroupId: UUID?

        // MARK: Streaming Height Debounce

        private var streamingHeightWorkItem: DispatchWorkItem?
        private let streamingHeightInterval: TimeInterval = 0.12

        // MARK: - Setup

        func setupDataSource(for tableView: NSTableView) {
            dataSource = NSTableViewDiffableDataSource<MessageSection, String>(
                tableView: tableView
            ) { [weak self] tableView, _, row, itemId in
                self?.dequeueAndConfigure(tableView: tableView, row: row, blockId: itemId)
                    ?? NSView()
            }
            tableView.delegate = self
        }

        func setupScrollAnchor(
            scrollView: NSScrollView,
            tableView: NSTableView,
            onScrolledToBottom: @escaping () -> Void,
            onScrolledAwayFromBottom: @escaping () -> Void
        ) {
            scrollAnchor.onScrolledToBottom = onScrolledToBottom
            scrollAnchor.onScrolledAwayFromBottom = onScrolledAwayFromBottom
            scrollAnchor.attach(to: scrollView, tableView: tableView)
        }

        fileprivate func setupHoverTracking(on tableView: HoverTrackingTableView) {
            tableView.onMouseMoved = { [weak self] event in
                self?.handleMouseMoved(with: event)
            }
            tableView.onMouseExited = { [weak self] in
                self?.setHoveredGroup(nil)
            }
        }

        // MARK: - Apply Blocks (Main Entry Point)

        /// Called from both `makeNSView` and `updateNSView`. Determines which
        /// update path to take (no-change / streaming fast path / full snapshot).
        func applyBlocks(
            _ blocks: [ContentBlock],
            context: CellRenderingContext,
            isStreaming: Bool,
            lastAssistantTurnId: UUID?,
            autoScrollEnabled: Bool
        ) {
            let widthChanged = abs(ctx.width - context.width) > 1.0
            ctx = context

            let newIds = blocks.map(\.id)
            let newLookup = Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, $0) })
            let newStreamingBlockId = Self.detectStreamingBlockId(in: blocks, isStreaming: isStreaming)

            // Flush pending height update if the streaming block changed or ended.
            if streamingBlockId != nil, newStreamingBlockId != streamingBlockId {
                flushPendingHeightUpdate()
            }

            // --- Path 1: No-change early return ---
            if !widthChanged, newIds == blockIds, !hasContentChanges(newLookup: newLookup) {
                streamingBlockId = newStreamingBlockId
                return
            }

            // --- Path 2: Streaming fast path ---
            if !widthChanged,
                newIds == blockIds,
                let streamId = newStreamingBlockId,
                let newBlock = newLookup[streamId],
                blockLookup[streamId] != newBlock
            {
                blockLookup = newLookup
                streamingBlockId = streamId
                updateStreamingCell(streamId: streamId, block: newBlock)
                return
            }

            // --- Path 3: Full snapshot ---
            applyFullSnapshot(
                newIds: newIds,
                newLookup: newLookup,
                newStreamingBlockId: newStreamingBlockId,
                lastAssistantTurnId: lastAssistantTurnId,
                autoScrollEnabled: autoScrollEnabled
            )
        }

        // MARK: - Update Paths (Private)

        /// Checks whether any block content differs from the current lookup.
        private func hasContentChanges(newLookup: [String: ContentBlock]) -> Bool {
            for id in blockIds {
                if newLookup[id] != blockLookup[id] { return true }
            }
            return false
        }

        /// Path 2: Update the streaming cell directly without a snapshot reapply.
        private func updateStreamingCell(streamId: String, block: ContentBlock) {
            guard let row = blockIds.firstIndex(of: streamId),
                let tableView,
                let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? MessageCellView
            else { return }

            configureCell(cell, with: block)
            scheduleStreamingHeightUpdate(row: row)
        }

        /// Path 3: Apply a new diffable snapshot and handle scroll anchoring.
        private func applyFullSnapshot(
            newIds: [String],
            newLookup: [String: ContentBlock],
            newStreamingBlockId: String?,
            lastAssistantTurnId: UUID?,
            autoScrollEnabled: Bool
        ) {
            blockLookup = newLookup
            blockIds = newIds
            streamingBlockId = newStreamingBlockId

            scrollAnchor.saveAnchor()

            var snapshot = NSDiffableDataSourceSnapshot<MessageSection, String>()
            snapshot.appendSections([.main])
            snapshot.appendItems(newIds, toSection: .main)

            dataSource?.apply(snapshot, animatingDifferences: false) { [weak self] in
                guard let self else { return }
                self.handlePostSnapshotScroll(
                    lastAssistantTurnId: lastAssistantTurnId,
                    autoScrollEnabled: autoScrollEnabled
                )
            }
        }

        /// After a snapshot is applied, either scroll to the new assistant
        /// header (once) or restore the previous scroll position.
        private func handlePostSnapshotScroll(
            lastAssistantTurnId: UUID?,
            autoScrollEnabled: Bool
        ) {
            if autoScrollEnabled,
                let turnId = lastAssistantTurnId,
                turnId != lastScrolledToTurnId
            {
                lastScrolledToTurnId = turnId
                let headerId = "header-\(turnId.uuidString)"
                if let row = blockIds.firstIndex(of: headerId) {
                    scrollAnchor.scrollToRow(row, animated: true)
                }
            } else {
                scrollAnchor.restoreAnchor()
            }
        }

        // MARK: - Cell Factory

        /// Dequeues or creates a cell, then configures it for the given block.
        private func dequeueAndConfigure(tableView: NSTableView, row: Int, blockId: String) -> NSView {
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

            if let block = blockLookup[blockId] {
                configureCell(cell, with: block)
            }
            return cell
        }

        /// Configures a cell with the current rendering context and hover state.
        private func configureCell(_ cell: MessageCellView, with block: ContentBlock) {
            let groupId = ctx.groupHeaderMap[block.turnId] ?? block.turnId
            cell.configure(
                block: block,
                width: ctx.width,
                personaName: ctx.personaName,
                isTurnHovered: hoveredGroupId == groupId,
                theme: ctx.theme,
                onCopy: ctx.onCopy,
                onRegenerate: ctx.onRegenerate,
                onEdit: ctx.onEdit,
                onClarificationSubmit: ctx.onClarificationSubmit,
                editingTurnId: ctx.editingTurnId,
                editText: ctx.editText,
                onConfirmEdit: ctx.onConfirmEdit,
                onCancelEdit: ctx.onCancelEdit
            )
        }

        // MARK: - Streaming Height Updates

        /// Tell the table to re-measure the streaming row after a short delay.
        private func scheduleStreamingHeightUpdate(row: Int) {
            streamingHeightWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, let tv = self.tableView, row < tv.numberOfRows else { return }
                NSAnimationContext.beginGrouping()
                NSAnimationContext.current.duration = 0
                tv.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row))
                NSAnimationContext.endGrouping()
            }
            streamingHeightWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + streamingHeightInterval, execute: work)
        }

        /// Immediately flush any pending streaming height update.
        private func flushPendingHeightUpdate() {
            guard let work = streamingHeightWorkItem else { return }
            work.cancel()
            streamingHeightWorkItem = nil

            guard let tv = tableView, let streamId = streamingBlockId,
                let row = blockIds.firstIndex(of: streamId),
                row < tv.numberOfRows
            else { return }

            NSAnimationContext.beginGrouping()
            NSAnimationContext.current.duration = 0
            tv.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row))
            NSAnimationContext.endGrouping()
        }

        // MARK: - Hover Tracking

        func handleMouseMoved(with event: NSEvent) {
            guard let tableView else { return setHoveredGroup(nil) }
            let point = tableView.convert(event.locationInWindow, from: nil)
            let row = tableView.row(at: point)

            guard row >= 0, row < blockIds.count,
                let block = blockLookup[blockIds[row]]
            else {
                return setHoveredGroup(nil)
            }
            setHoveredGroup(ctx.groupHeaderMap[block.turnId] ?? block.turnId)
        }

        func setHoveredGroup(_ newGroupId: UUID?) {
            guard hoveredGroupId != newGroupId else { return }
            let oldGroupId = hoveredGroupId
            hoveredGroupId = newGroupId

            guard let tableView else { return }
            let range = tableView.rows(in: tableView.visibleRect)
            for row in range.location ..< (range.location + range.length) {
                guard row < blockIds.count,
                    let block = blockLookup[blockIds[row]]
                else { continue }
                let groupId = ctx.groupHeaderMap[block.turnId] ?? block.turnId
                guard groupId == oldGroupId || groupId == newGroupId else { continue }
                if let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? MessageCellView {
                    configureCell(cell, with: block)
                }
            }
        }

        // MARK: - NSTableViewDelegate

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

        // MARK: - Helpers

        /// Finds the block ID that is currently streaming (last paragraph/thinking marked streaming).
        private static func detectStreamingBlockId(in blocks: [ContentBlock], isStreaming: Bool) -> String? {
            guard isStreaming else { return nil }
            return blocks.last(where: {
                if case .paragraph(_, _, true, _) = $0.kind { return true }
                if case .thinking(_, _, true) = $0.kind { return true }
                return false
            })?.id
        }
    }
}
