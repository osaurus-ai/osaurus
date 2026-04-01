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
//      2. In-place update (IDs unchanged, reconfigure changed cells directly).
//      3. Full snapshot (apply diff, handle scroll anchoring).
//  - Streaming row heights are debounced via `noteHeightOfRows` so the
//    table re-measures at most once per `streamingHeightInterval`.
//

import AppKit
import Combine
import SwiftUI

// MARK: - Supporting Types

/// Single-section identifier for the diffable data source.
enum MessageSection: Hashable {
    case main
}

// MARK: - MessageTableRepresentable

struct MessageTableRepresentable: NSViewRepresentable {

    // Content
    let blocks: [ContentBlock]
    let groupHeaderMap: [UUID: UUID]
    let width: CGFloat
    let agentName: String
    let isStreaming: Bool
    let lastAssistantTurnId: UUID?
    let autoScrollEnabled: Bool
    let theme: ThemeProtocol
    let expandedBlocksStore: ExpandedBlocksStore

    // Scroll
    let scrollToBottomTrigger: Int
    let onScrolledToBottom: () -> Void
    let onScrolledAwayFromBottom: () -> Void

    // Message action callbacks
    let onCopy: ((UUID) -> Void)?
    let onRegenerate: ((UUID) -> Void)?
    let onEdit: ((UUID) -> Void)?
    let onDelete: ((UUID) -> Void)?

    // Inline editing state
    let editingTurnId: UUID?
    let editText: Binding<String>?
    let onConfirmEdit: (() -> Void)?
    let onCancelEdit: (() -> Void)?
    var onUserImagePreview: ((String) -> Void)? = nil

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

        // sync session store into coordinator's expand cache for the initial load
        coordinator.expandedIds = expandedBlocksStore.expandedIds
        coordinator.sessionExpandedStore = expandedBlocksStore

        coordinator.applyBlocks(
            blocks,
            groupHeaderMap: groupHeaderMap,
            context: renderingContext(for: coordinator),
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
        coordinator.sessionExpandedStore = expandedBlocksStore

        // Detect scroll-to-bottom button tap.
        if scrollToBottomTrigger != coordinator.lastScrollToBottomTrigger {
            coordinator.lastScrollToBottomTrigger = scrollToBottomTrigger
            coordinator.scrollAnchor.scrollToBottom(animated: true)
        }

        // Sync any external expand-state changes (e.g. session load resets the store)
        if expandedBlocksStore.expandedIds != coordinator.expandedIds {
            coordinator.expandedIds = expandedBlocksStore.expandedIds
        }

        coordinator.applyBlocks(
            blocks,
            groupHeaderMap: groupHeaderMap,
            context: renderingContext(for: coordinator),
            isStreaming: isStreaming,
            lastAssistantTurnId: lastAssistantTurnId,
            autoScrollEnabled: autoScrollEnabled
        )
    }

    // MARK: - View Factory Helpers

    private func renderingContext(for coordinator: Coordinator) -> CellRenderingContext {
        CellRenderingContext(
            width: max(100, width),
            agentName: agentName,
            isStreaming: isStreaming,
            lastAssistantTurnId: lastAssistantTurnId,
            theme: theme,
            expandedIds: coordinator.expandedIds,
            onToggleExpand: { [weak coordinator] id in
                coordinator?.toggleExpand(id: id, sessionStore: expandedBlocksStore)
            },
            onHeightMeasured: { [weak coordinator] height, blockId in
                guard let coordinator else { return }
                coordinator.reportMeasuredHeight(height, forBlockId: blockId)
            },
            editingTurnId: editingTurnId,
            editText: editText.map { b in ({ b.wrappedValue }, { b.wrappedValue = $0 }) },
            onConfirmEdit: onConfirmEdit,
            onCancelEdit: onCancelEdit,
            onCopy: onCopy,
            onRegenerate: onRegenerate,
            onEdit: onEdit,
            onDelete: onDelete,
            onUserImagePreview: onUserImagePreview
        )
    }

    // keep a convenience var for compatibility with init path which doesn't have a coordinator ref
    private var renderingContext: CellRenderingContext {
        CellRenderingContext(
            width: max(100, width),
            agentName: agentName,
            isStreaming: isStreaming,
            lastAssistantTurnId: lastAssistantTurnId,
            theme: theme,
            expandedIds: expandedBlocksStore.expandedIds,
            onToggleExpand: { _ in },
            editingTurnId: editingTurnId,
            editText: editText.map { b in ({ b.wrappedValue }, { b.wrappedValue = $0 }) },
            onConfirmEdit: onConfirmEdit,
            onCancelEdit: onCancelEdit,
            onCopy: onCopy,
            onRegenerate: onRegenerate,
            onEdit: onEdit,
            onDelete: onDelete,
            onUserImagePreview: onUserImagePreview
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
        tv.allowsMultipleSelection = false
        tv.allowsEmptySelection = true
        tv.gridStyleMask = []
        // Use the height delegate (tableView(_:heightOfRow:)) instead of
        // usesAutomaticRowHeights to avoid layout cascade on every scroll event.
        tv.usesAutomaticRowHeights = false
        tv.rowHeight = 44  // default fallback; overridden per-row by delegate

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
        sv.contentInsets = NSEdgeInsets(top: 8, left: 0, bottom: 60, right: 0)
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

        // MARK: Scroll State

        let scrollAnchor = ScrollAnchorManager()
        /// Tracks the last observed trigger value so we only scroll once per tap.
        var lastScrollToBottomTrigger: Int = 0

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

        private var ctx = CellRenderingContext(
            width: 400,
            agentName: "",
            isStreaming: false,
            lastAssistantTurnId: nil,
            theme: LightTheme(),
            expandedIds: [],
            onToggleExpand: { _ in },
            editingTurnId: nil,
            editText: nil,
            onConfirmEdit: nil,
            onCancelEdit: nil,
            onCopy: nil,
            onRegenerate: nil,
            onEdit: nil,
            onDelete: nil,
            onUserImagePreview: nil
        )

        // groupHeaderMap is still needed for hover group resolution
        var groupHeaderMap: [UUID: UUID] = [:]

        // MARK: Hover

        private var hoveredGroupId: UUID?

        // MARK: Expand/Collapse State

        /// Coordinator-owned snapshot of expanded IDs.
        /// Synced from the session store on each updateNSView and updated
        /// immediately when a cell proxy fires onToggle.
        var expandedIds: Set<String> = []

        /// Weak reference to the session-level store for forwarding toggles.
        weak var sessionExpandedStore: ExpandedBlocksStore?

        // (no AnyCancellable subscription needed — expand events flow through the proxy callback)

        // MARK: Row Height Cache

        /// Caches measured row heights to avoid calling fittingSize on every scroll.
        private var heightCache: [String: CGFloat] = [:]

        // MARK: Streaming Height Debounce

        private var streamingHeightWorkItem: DispatchWorkItem?
        private let streamingHeightInterval: TimeInterval = 0.06

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

        func setupHoverTracking(on tableView: HoverTrackingTableView) {
            tableView.onMouseMoved = { [weak self] event in
                self?.handleMouseMoved(with: event)
            }
            tableView.onMouseExited = { [weak self] in
                self?.setHoveredGroup(nil)
            }
        }

        /// Called by a cell proxy when the user toggles an expand/collapse item.
        /// Forwards the toggle to the session store and invalidates the row height.
        func toggleExpand(id: String, sessionStore: ExpandedBlocksStore) {
            sessionStore.toggle(id)
            expandedIds = sessionStore.expandedIds

            // find row: block id (thinking, etc.) or tool call id inside a toolCallGroup block
            let row = blockIds.firstIndex(where: { bid in
                guard let b = blockLookup[bid] else { return false }
                if b.id == id { return true }
                if case .toolCallGroup(let calls) = b.kind {
                    return calls.contains { $0.call.id == id }
                }
                return false
            })

            if let row {
                let blockId = blockIds[row]
                heightCache.removeValue(forKey: blockId)
                if let cell = tableView?.view(atColumn: 0, row: row, makeIfNecessary: false) as? NativeMessageCellView,
                    let block = blockLookup[blockId]
                {
                    configureCell(cell, with: block)
                }
                // let the hosting view settle before re-measuring
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    self?.noteRowHeightsChanged(IndexSet(integer: row))
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                    self?.noteRowHeightsChanged(IndexSet(integer: row))
                }
            }
        }

        /// Tell the table to re-measure all currently visible rows.
        private func noteVisibleRowHeightsChanged() {
            guard let tableView else { return }
            let visible = tableView.rows(in: tableView.visibleRect)
            guard visible.length > 0 else { return }
            let rows = IndexSet(integersIn: visible.location ..< visible.location + visible.length)
            for row in rows {
                if row < blockIds.count {
                    heightCache.removeValue(forKey: blockIds[row])
                }
            }
            noteRowHeightsChanged(rows)
        }

        /// Re-measure specific rows without animation.
        private func noteRowHeightsChanged(_ rows: IndexSet) {
            guard let tableView else { return }
            NSAnimationContext.beginGrouping()
            NSAnimationContext.current.duration = 0
            tableView.noteHeightOfRows(withIndexesChanged: rows)
            NSAnimationContext.endGrouping()
        }

        // MARK: - Apply Blocks (Main Entry Point)

        /// Called from both `makeNSView` and `updateNSView`. Determines which
        /// update path to take:
        ///   1. No-change early return
        ///   2. In-place update (reconfigure changed cells directly)
        ///   3. Full snapshot (diffable data source apply + scroll anchoring)
        func applyBlocks(
            _ blocks: [ContentBlock],
            groupHeaderMap: [UUID: UUID],
            context: CellRenderingContext,
            isStreaming: Bool,
            lastAssistantTurnId: UUID?,
            autoScrollEnabled: Bool
        ) {
            let widthChanged = abs(ctx.width - context.width) > 1.0
            let expandedIdsChanged = context.expandedIds != ctx.expandedIds
            let previousEditingTurnId = ctx.editingTurnId
            let previousStreaming = ctx.isStreaming
            let previousLastAssistantTurnId = ctx.lastAssistantTurnId

            // if width changed, invalidate the entire height cache
            if widthChanged { heightCache.removeAll() }

            ctx = context
            self.groupHeaderMap = groupHeaderMap

            // Editing state lives in the context, not in the blocks themselves.
            // Reconfigure affected cells immediately so the UI responds without
            // waiting for a block-level change.
            if context.editingTurnId != previousEditingTurnId {
                reconfigureCellsForTurn(previousEditingTurnId)
                reconfigureCellsForTurn(context.editingTurnId)
            }

            let newIds = blocks.map(\.id)
            let newLookup = Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, $0) })
            let newStreamingBlockId = Self.detectStreamingBlockId(in: blocks, isStreaming: isStreaming)

            // Detect streaming-ended transition before any state mutations.
            let streamingJustEnded = streamingBlockId != nil && newStreamingBlockId == nil
            let previousStreamingBlockId = streamingBlockId

            // If the streaming block changed, flush the pending height update
            // so the old row settles. If streaming ended entirely, just cancel
            // the pending work — the post-streaming fix will do a single
            // authoritative measurement with final content, avoiding a
            // double-snap from stale-then-final heights.
            if streamingBlockId != nil, newStreamingBlockId != streamingBlockId {
                if streamingJustEnded {
                    streamingHeightWorkItem?.cancel()
                    streamingHeightWorkItem = nil
                } else {
                    flushPendingHeightUpdate()
                }
            }

            // --- Path 1: No-change early return ---
            if !widthChanged, newIds == blockIds, !hasContentChanges(newLookup: newLookup) {
                let contextAffectsCells =
                    previousStreaming != context.isStreaming
                    || previousLastAssistantTurnId != context.lastAssistantTurnId
                    || expandedIdsChanged
                if contextAffectsCells {
                    reconfigureAllCellsFromLookup(newLookup)
                }
                streamingBlockId = newStreamingBlockId
                return
            }

            // --- Path 1b: width-only (same IDs, same block data) ---
            // Path 3 applies a snapshot but only reconfigures rows whose ContentBlock
            // changed; when only SwiftUI's layout width changes (e.g. sidebar toggle),
            // stableChangedIds is empty so cells would keep stale layout width until
            // some later content update — visible as a gap on the first resize.
            if widthChanged, newIds == blockIds, !hasContentChanges(newLookup: newLookup) {
                blockLookup = newLookup
                streamingBlockId = newStreamingBlockId
                reconfigureAllCellsFromLookup(newLookup)
                return
            }

            // --- Path 2: In-place update (IDs unchanged, content changed) ---
            if !widthChanged, newIds == blockIds {
                reconfigureChangedCells(newLookup: newLookup, streamId: newStreamingBlockId)
                blockLookup = newLookup
                streamingBlockId = newStreamingBlockId
                return
            }

            // --- Path 3: Full snapshot ---
            applyFullSnapshot(
                newIds: newIds,
                newLookup: newLookup,
                newStreamingBlockId: newStreamingBlockId,
                lastAssistantTurnId: lastAssistantTurnId,
                autoScrollEnabled: autoScrollEnabled,
                streamingJustEnded: streamingJustEnded,
                previousStreamingBlockId: previousStreamingBlockId
            )
        }

        // MARK: - Update Paths (Private)

        private func hasContentChanges(newLookup: [String: ContentBlock]) -> Bool {
            for id in blockIds {
                if newLookup[id] != blockLookup[id] { return true }
            }
            return false
        }

        /// Path 2: Reconfigure all cells whose content changed without a snapshot reapply.
        /// Streaming cells get debounced height updates; others update height immediately.
        private func reconfigureChangedCells(newLookup: [String: ContentBlock], streamId: String?) {
            guard let tableView else { return }
            var nonStreamingRows = IndexSet()

            for (index, id) in blockIds.enumerated() {
                guard newLookup[id] != blockLookup[id],
                    let block = newLookup[id],
                    let cell = tableView.view(atColumn: 0, row: index, makeIfNecessary: false) as? NativeMessageCellView
                else { continue }

                // invalidate height cache for changed block
                heightCache.removeValue(forKey: id)
                configureCell(cell, with: block)

                if id == streamId {
                    scheduleStreamingHeightUpdate(row: index)
                } else {
                    nonStreamingRows.insert(index)
                }
            }

            if !nonStreamingRows.isEmpty {
                noteRowHeightsChanged(nonStreamingRows)
                if scrollAnchor.isPinnedToBottom {
                    scrollAnchor.scrollToBottom()
                }
            }
        }

        /// Path 3: Apply a new diffable snapshot and handle scroll anchoring.
        /// After the snapshot is applied, existing cells whose content changed
        /// (but whose ID survived the diff) are reconfigured in place so
        /// tool-call rows update without cell destruction/recreation.
        private func applyFullSnapshot(
            newIds: [String],
            newLookup: [String: ContentBlock],
            newStreamingBlockId: String?,
            lastAssistantTurnId: UUID?,
            autoScrollEnabled: Bool,
            streamingJustEnded: Bool = false,
            previousStreamingBlockId: String? = nil
        ) {
            let oldLookup = blockLookup
            let oldIdSet = Set(blockIds)

            blockLookup = newLookup
            blockIds = newIds
            streamingBlockId = newStreamingBlockId

            let stableChangedIds = newIds.filter { id in
                oldIdSet.contains(id) && newLookup[id] != oldLookup[id]
            }

            let wasPinnedToBottom = scrollAnchor.isPinnedToBottom
            scrollAnchor.saveAnchor()

            var snapshot = NSDiffableDataSourceSnapshot<MessageSection, String>()
            snapshot.appendSections([.main])
            snapshot.appendItems(newIds, toSection: .main)

            dataSource?.apply(snapshot, animatingDifferences: false) { [weak self] in
                guard let self else { return }

                if !stableChangedIds.isEmpty {
                    var reconfiguredRows = IndexSet()
                    for id in stableChangedIds {
                        if let row = self.blockIds.firstIndex(of: id),
                            let block = self.blockLookup[id],
                            let cell = self.tableView?.view(
                                atColumn: 0,
                                row: row,
                                makeIfNecessary: false
                            ) as? NativeMessageCellView
                        {
                            self.heightCache.removeValue(forKey: id)
                            self.configureCell(cell, with: block)
                            reconfiguredRows.insert(row)
                        }
                    }
                    if !reconfiguredRows.isEmpty {
                        self.noteRowHeightsChanged(reconfiguredRows)
                    }
                }

                self.handlePostSnapshotScroll(
                    lastAssistantTurnId: lastAssistantTurnId,
                    autoScrollEnabled: autoScrollEnabled,
                    wasPinnedToBottom: wasPinnedToBottom
                )

                // When streaming ends, the last throttled height measurement
                // may not reflect the final content. Reconfigure the cell and
                // schedule a deferred re-measurement after the hosting view's
                // layout has settled, then re-pin scroll position.
                if streamingJustEnded, let streamId = previousStreamingBlockId,
                    let row = self.blockIds.firstIndex(of: streamId)
                {
                    self.schedulePostStreamingHeightFix(
                        streamId: streamId,
                        row: row,
                        wasPinnedToBottom: wasPinnedToBottom
                    )
                }
            }
        }

        /// Post-snapshot scroll: new turn with header → scroll to header;
        /// pinned to bottom → stay at bottom; otherwise → restore anchor.
        /// `wasPinnedToBottom` must be captured before `apply()` since the
        /// snapshot may shift bounds first.
        private func handlePostSnapshotScroll(
            lastAssistantTurnId: UUID?,
            autoScrollEnabled: Bool,
            wasPinnedToBottom: Bool
        ) {
            if autoScrollEnabled,
                let turnId = lastAssistantTurnId,
                turnId != lastScrolledToTurnId
            {
                lastScrolledToTurnId = turnId
                let headerId = "header-\(turnId.uuidString)"
                if let row = blockIds.firstIndex(of: headerId) {
                    scrollAnchor.scrollToRow(row, animated: true)
                } else if wasPinnedToBottom {
                    scrollAnchor.scrollToBottom()
                } else {
                    scrollAnchor.restoreAnchor()
                }
            } else if wasPinnedToBottom {
                scrollAnchor.scrollToBottom()
            } else {
                scrollAnchor.restoreAnchor()
            }

            scrollAnchor.checkPinnedState()
        }

        // MARK: - Cell Factory

        private func dequeueAndConfigure(tableView: NSTableView, row: Int, blockId: String) -> NSView {
            let cell: NativeMessageCellView
            if let reused = tableView.makeView(
                withIdentifier: NativeMessageCellView.reuseId,
                owner: nil
            ) as? NativeMessageCellView {
                cell = reused
            } else {
                cell = NativeMessageCellView(frame: .zero)
                cell.identifier = NativeMessageCellView.reuseId
            }

            if let block = blockLookup[blockId] {
                configureCell(cell, with: block)
            }
            return cell
        }

        private func configureCell(_ cell: NativeMessageCellView, with block: ContentBlock) {
            let groupId = groupHeaderMap[block.turnId] ?? block.turnId
            var context = ctx
            context.expandedIds = expandedIds
            context.isTurnHovered = hoveredGroupId == groupId
            cell.configure(block: block, context: context)
        }

        // MARK: - Context-Driven Reconfiguration

        private func reconfigureCellsForTurn(_ turnId: UUID?) {
            guard let turnId, let tableView else { return }
            var affectedRows = IndexSet()
            for (index, blockId) in blockIds.enumerated() {
                guard let block = blockLookup[blockId], block.turnId == turnId else { continue }
                if let cell = tableView.view(atColumn: 0, row: index, makeIfNecessary: false) as? NativeMessageCellView
                {
                    heightCache.removeValue(forKey: blockId)
                    configureCell(cell, with: block)
                }
                affectedRows.insert(index)
            }
            guard !affectedRows.isEmpty else { return }
            noteRowHeightsChanged(affectedRows)
        }

        /// Reconfigure every visible row when block data is unchanged but `CellRenderingContext` changed
        /// (e.g. `isStreaming`, `lastAssistantTurnId`).
        private func reconfigureAllCellsFromLookup(_ newLookup: [String: ContentBlock]) {
            guard let tableView else { return }
            var affectedRows = IndexSet()
            for (index, id) in blockIds.enumerated() {
                guard let block = newLookup[id],
                    let cell = tableView.view(atColumn: 0, row: index, makeIfNecessary: false) as? NativeMessageCellView
                else { continue }
                heightCache.removeValue(forKey: id)
                configureCell(cell, with: block)
                affectedRows.insert(index)
            }
            guard !affectedRows.isEmpty else { return }
            noteRowHeightsChanged(affectedRows)
            if scrollAnchor.isPinnedToBottom {
                scrollAnchor.scrollToBottom()
            }
        }

        // MARK: - Streaming Height Updates

        private func scheduleStreamingHeightUpdate(row: Int) {
            streamingHeightWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, let tv = self.tableView, row < tv.numberOfRows else { return }
                // Force the hosting view to flush its SwiftUI layout cycle so the
                // new intrinsic content size (driven by streamingContentHeight) is
                // committed before we ask the table to re-measure the row.
                self.noteRowHeightsChanged(IndexSet(integer: row))

                if self.scrollAnchor.isPinnedToBottom {
                    self.scrollAnchor.scrollToBottom()
                }
            }
            streamingHeightWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + streamingHeightInterval, execute: work)
        }

        private func flushPendingHeightUpdate() {
            guard let work = streamingHeightWorkItem else { return }
            work.cancel()
            streamingHeightWorkItem = nil

            guard let tv = tableView, let streamId = streamingBlockId,
                let row = blockIds.firstIndex(of: streamId),
                row < tv.numberOfRows
            else { return }

            noteRowHeightsChanged(IndexSet(integer: row))
        }

        /// After streaming ends, reconfigure the previously streaming cell
        /// with its final content and re-measure its height in one shot.
        /// Called from the snapshot-apply completion handler so it runs
        /// *after* the diffable data source has finished updating.
        private func schedulePostStreamingHeightFix(streamId: String, row: Int, wasPinnedToBottom: Bool) {
            guard let block = blockLookup[streamId],
                let tv = tableView, row < tv.numberOfRows
            else { return }

            // Reconfigure the cell with final content (isStreaming: false).
            // Path 3's snapshot apply doesn't reconfigure cells whose IDs
            // haven't changed, so the cell may still show stale state.
            if let cell = tv.view(atColumn: 0, row: row, makeIfNecessary: false) as? NativeMessageCellView {
                heightCache.removeValue(forKey: streamId)
                configureCell(cell, with: block)
            }

            noteRowHeightsChanged(IndexSet(integer: row))

            if wasPinnedToBottom {
                scrollAnchor.scrollToBottom()
            }
        }

        // MARK: - Hover Tracking

        private func handleMouseMoved(with event: NSEvent) {
            guard let tableView else { return setHoveredGroup(nil) }
            let point = tableView.convert(event.locationInWindow, from: nil)
            let row = tableView.row(at: point)

            guard row >= 0, row < blockIds.count,
                let block = blockLookup[blockIds[row]]
            else {
                return setHoveredGroup(nil)
            }
            setHoveredGroup(groupHeaderMap[block.turnId] ?? block.turnId)
        }

        private func setHoveredGroup(_ newGroupId: UUID?) {
            guard hoveredGroupId != newGroupId else { return }
            let oldGroupId = hoveredGroupId
            hoveredGroupId = newGroupId

            guard let tableView else { return }
            let range = tableView.rows(in: tableView.visibleRect)
            for row in range.location ..< (range.location + range.length) {
                guard row < blockIds.count,
                    let block = blockLookup[blockIds[row]]
                else { continue }
                let groupId = groupHeaderMap[block.turnId] ?? block.turnId
                guard groupId == oldGroupId || groupId == newGroupId else { continue }
                guard
                    let cell = tableView.view(
                        atColumn: 0,
                        row: row,
                        makeIfNecessary: false
                    ) as? NativeMessageCellView
                else { continue }

                // for header rows, use the fast hover path
                if case .header = block.kind {
                    cell.setTurnHovered(groupId == newGroupId)
                } else {
                    configureCell(cell, with: block)
                }
            }
        }

        // MARK: - NSTableViewDelegate

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

        /// Height delegate — avoids Auto Layout cascade on every scroll event.
        /// Returns cached heights where available, otherwise uses the estimator.
        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard row < blockIds.count,
                let block = blockLookup[blockIds[row]]
            else { return 44 }

            // return cached height if we have it
            if let cached = heightCache[block.id] { return cached }

            // estimate height and cache it
            let isExpanded = expandedIds.contains(block.id)
            let h = NativeCellHeightEstimator.estimatedHeight(
                for: block,
                width: ctx.width,
                theme: ctx.theme,
                isExpanded: isExpanded
            )
            heightCache[block.id] = h
            return h
        }

        /// Called by a cell after it has been laid out to update the height cache.
        /// Triggers a height invalidation if the actual height differs from the estimate.
        func reportMeasuredHeight(_ height: CGFloat, forBlockId blockId: String, row: Int) {
            guard let tv = tableView, row < tv.numberOfRows else { return }
            let existing = heightCache[blockId]
            let delta = abs((existing ?? 0) - height)
            heightCache[blockId] = height
            // 2pt was too coarse — short rows (user bubble + corner stroke) looked clipped before the next scroll
            if delta > 0.5 {
                NSAnimationContext.beginGrouping()
                NSAnimationContext.current.duration = 0
                tv.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row))
                NSAnimationContext.endGrouping()
            }
        }

        /// Overload called from native cells that only know their blockId.
        /// Looks up the row from the coordinator's blockIds array.
        func reportMeasuredHeight(_ height: CGFloat, forBlockId blockId: String) {
            guard let row = blockIds.firstIndex(of: blockId) else { return }
            reportMeasuredHeight(height, forBlockId: blockId, row: row)
        }

        // MARK: - Helpers

        private static func detectStreamingBlockId(in blocks: [ContentBlock], isStreaming: Bool) -> String? {
            guard isStreaming else { return nil }
            return blocks.last(where: {
                if case .paragraph(_, _, true, _) = $0.kind { return true }
                if case .thinking(_, _, true) = $0.kind { return true }
                if case .typingIndicator = $0.kind { return true }
                return false
            })?.id
        }
    }
}
