//
//  MessageTableHeightNoteCascadeTests.swift
//
//  Drives the real `MessageTableRepresentable.Coordinator` against a counting
//  `NSTableView` in an offscreen window with expanded activity groups
//  (thinking + tool calls per assistant turn), the transcript shape behind the
//  Sentry main-thread hangs APPLE-MACOS-4M / 1JW / 1JV / 2AS / 1D0 / 2FM / 1KZ
//  / 1M1. Every nested child view (thinking markdown, each tool-call row)
//  reports its height through `onHeightChanged` while its parent is still
//  being configured; each report reached `reportMeasuredHeight`, which called
//  `tableView.noteHeightOfRows` synchronously — a full table re-tile and scroll
//  view `tile()` per child, per cell, per `applyBlocks`.
//
//  The counts here are the receipt: one `applyBlocks` must issue a bounded
//  number of `noteHeightOfRows` calls regardless of how many children the
//  materialised cells contain.
//

import AppKit
import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct MessageTableHeightNoteCascadeTests {

    /// Counts the table-level work the coordinator triggers.
    final class CountingTableView: NSTableView {
        var noteCalls = 0
        var noteRows = 0
        var tileCalls = 0

        override func noteHeightOfRows(withIndexesChanged indexSet: IndexSet) {
            noteCalls += 1
            noteRows += indexSet.count
            super.noteHeightOfRows(withIndexesChanged: indexSet)
        }

        override func tile() {
            tileCalls += 1
            super.tile()
        }

        func reset() {
            noteCalls = 0
            noteRows = 0
            tileCalls = 0
        }
    }

    @MainActor
    private final class Harness {
        let window: NSWindow
        let scrollView: NSScrollView
        let tableView: CountingTableView
        let coordinator: MessageTableRepresentable.Coordinator
        let memoizer = BlockMemoizer()
        var turns: [ChatTurn] = []
        var toolCounter = 0

        init(viewportHeight: CGFloat = 1600) {
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 700, height: viewportHeight),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            scrollView = NSScrollView(frame: window.contentView!.bounds)
            tableView = CountingTableView(frame: scrollView.bounds)
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("message"))
            column.width = 680
            tableView.addTableColumn(column)
            tableView.headerView = nil
            tableView.style = .plain
            tableView.usesAutomaticRowHeights = false
            scrollView.documentView = tableView
            window.contentView?.addSubview(scrollView)

            coordinator = MessageTableRepresentable.Coordinator()
            coordinator.tableView = tableView
            coordinator.scrollView = scrollView
            coordinator.setupDataSource(for: tableView)
            coordinator.setupScrollAnchor(
                scrollView: scrollView,
                tableView: tableView,
                onScrolledToBottom: {},
                onScrolledAwayFromBottom: {}
            )
            coordinator.lastSwiftUIWidth = 680
        }

        var width: CGFloat = 680

        func context(isStreaming: Bool) -> CellRenderingContext {
            CellRenderingContext(
                width: width,
                agentName: "Osaurus",
                agentAvatar: nil,
                agentCustomAvatarPath: nil,
                isStreaming: isStreaming,
                lastAssistantTurnId: turns.last(where: { $0.role == .assistant })?.id,
                theme: ThemeManager.shared.currentTheme,
                expandedIds: coordinator.expandedIds,
                onToggleExpand: { _ in },
                onHeightMeasured: { [weak coordinator] height, id in
                    coordinator?.reportMeasuredHeight(height, forBlockId: id)
                }
            )
        }

        func blocks(streamingTurnId: UUID? = nil) -> [ContentBlock] {
            memoizer.blocks(from: turns, streamingTurnId: streamingTurnId, agentName: "Osaurus")
        }

        @discardableResult
        func apply(streamingTurnId: UUID? = nil) -> [ContentBlock] {
            let blocks = blocks(streamingTurnId: streamingTurnId)
            coordinator.applyBlocks(
                blocks,
                groupHeaderMap: memoizer.groupHeaderMap,
                context: context(isStreaming: streamingTurnId != nil),
                isStreaming: streamingTurnId != nil,
                lastAssistantTurnId: turns.last(where: { $0.role == .assistant })?.id,
                autoScrollEnabled: true
            )
            return blocks
        }

        func layout() {
            window.contentView?.layoutSubtreeIfNeeded()
            tableView.layoutSubtreeIfNeeded()
            tableView.displayIfNeeded()
        }

        /// Expand every activity group, its thinking children and each tool
        /// call so the cells build the full nested view tree.
        func expandEverything(in blocks: [ContentBlock]) {
            var ids = coordinator.expandedIds
            for block in blocks {
                guard case let .activityGroup(children) = block.kind else { continue }
                ids.insert(block.id)
                for child in children {
                    switch child.kind {
                    case .thinking:
                        ids.insert(child.id)
                    case let .toolCallGroup(calls):
                        for call in calls { ids.insert(call.call.id) }
                    default:
                        break
                    }
                }
            }
            coordinator.expandedIds = ids
        }

        func addToolExchange(_ n: Int, toolCalls: Int) {
            turns.append(ChatTurn(role: .user, content: "Task \(n): inspect the repository and summarise."))
            let answer = ChatTurn(role: .assistant, content: "")
            answer.appendThinking(
                "Step \(n): I should read the files first, then compare the results.\n\n"
                    + "The listing is long, so I will check each candidate in turn and "
                    + "keep notes on what differs between them before answering."
            )
            var calls: [ToolCall] = []
            for _ in 0 ..< toolCalls {
                toolCounter += 1
                let id = "call_\(n)_\(toolCounter)"
                calls.append(
                    ToolCall(
                        id: id,
                        type: "function",
                        function: ToolCallFunction(
                            name: "file_read",
                            arguments: "{\"path\": \"src/module\(toolCounter).swift\", \"offset\": 0}"
                        )
                    )
                )
            }
            answer.toolCalls = calls
            for call in calls {
                answer.setToolResult(
                    "line 1: import Foundation\nline 2: struct Module\(toolCounter) {}\nline 3: // end",
                    for: call.id
                )
            }
            answer.appendContent(
                "Answer \(n): the modules differ in their initialisers.\n\nSecond paragraph for turn \(n)."
            )
            turns.append(answer)
        }

        func materialisedCells() -> Int {
            var count = 0
            for row in 0 ..< tableView.numberOfRows
            where tableView.view(atColumn: 0, row: row, makeIfNecessary: false) != nil {
                count += 1
            }
            return count
        }
    }

    private struct Measurement {
        let phase: String
        let noteCalls: Int
        let noteRows: Int
        let tileCalls: Int
        let ms: Double
        let cells: Int
        let rows: Int

        func report() {
            print(
                "[height-note-cascade] phase=\(phase) rows=\(rows) cells=\(cells) "
                    + "noteHeightOfRows=\(noteCalls) notedRows=\(noteRows) tableTile=\(tileCalls) "
                    + "ms=\(String(format: "%.1f", ms))"
            )
        }
    }

    private func measure(_ phase: String, _ h: Harness, _ body: () -> Void) -> Measurement {
        h.tableView.reset()
        let start = CFAbsoluteTimeGetCurrent()
        body()
        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
        let m = Measurement(
            phase: phase,
            noteCalls: h.tableView.noteCalls,
            noteRows: h.tableView.noteRows,
            tileCalls: h.tableView.tileCalls,
            ms: ms,
            cells: h.materialisedCells(),
            rows: h.tableView.numberOfRows
        )
        m.report()
        return m
    }

    /// Force the activity rollup on for the test (default-on, but a developer
    /// machine may have opted out) and restore the previous value afterwards.
    private func withActivityRollup<T>(_ body: () throws -> T) rethrows -> T {
        let key = ContentBlock.ActivityRollupSetting.defaultsKey
        let previous = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(true, forKey: key)
        ContentBlock.ActivityRollupSetting.invalidate()
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
            ContentBlock.ActivityRollupSetting.invalidate()
        }
        return try body()
    }

    @Test func expandedActivityGroupsIssueABoundedNumberOfHeightNotesPerApply() {
        withActivityRollup {
            let h = Harness()
            let exchanges = 12
            let toolsPerTurn = 8
            for i in 1 ... exchanges { h.addToolExchange(i, toolCalls: toolsPerTurn) }
            let first = h.blocks()
            #expect(first.contains { if case .activityGroup = $0.kind { return true } else { return false } })
            h.expandEverything(in: first)

            let initial = measure("initialApply", h) {
                h.apply()
                h.layout()
            }
            #expect(initial.cells > 0, "row views should be materialised in the offscreen window")

            // Path 3: a new exchange arrives (ids change) while every
            // materialised cell holds an expanded activity group.
            h.addToolExchange(exchanges + 1, toolCalls: toolsPerTurn)
            let blocksAfterAppend = h.blocks()
            h.expandEverything(in: blocksAfterAppend)
            let append = measure("path3.appendExchange", h) {
                h.apply()
                h.layout()
            }

            // Path 2: streaming thinking inside the last (expanded) activity
            // group — the shape of every token update during an agent run.
            // The reader is at the bottom, so the streaming cell is
            // materialised and reconfigured on every token.
            h.turns.append(ChatTurn(role: .user, content: "Final task: wrap up."))
            let streaming = ChatTurn(role: .assistant, content: "")
            h.turns.append(streaming)
            // One finished tool call plus the live thinking segment: two
            // steps, so the memoizer rolls them into an activity group with a
            // streaming thinking child (the agent-run shape in the samples).
            let liveCall = ToolCall(
                id: "call_live_1",
                type: "function",
                function: ToolCallFunction(name: "file_read", arguments: "{\"path\": \"README.md\"}")
            )
            streaming.toolCalls = [liveCall]
            streaming.setToolResult("# Project\n\nReadme body.", for: liveCall.id)
            streaming.appendThinking("Let me think about this carefully. ")
            var streamingBlocks = h.blocks(streamingTurnId: streaming.id)
            h.expandEverything(in: streamingBlocks)
            h.apply(streamingTurnId: streaming.id)
            h.layout()
            h.coordinator.scrollAnchor.scrollToBottom()
            h.coordinator.scrollAnchor.checkPinnedState()
            h.layout()
            let streamingRow = h.coordinator.blockIds.firstIndex { id in
                guard case .activityGroup = h.coordinator.blockLookup[id]?.kind else { return false }
                return h.coordinator.blockLookup[id]?.turnId == streaming.id
            }
            #expect(streamingRow != nil)
            if let streamingRow {
                #expect(
                    h.tableView.view(atColumn: 0, row: streamingRow, makeIfNecessary: false) != nil,
                    "the streaming activity group must be materialised for the streaming measurement"
                )
            }
            let tokens = 40
            let stream = measure("path2.streamThinking(\(tokens) tokens)", h) {
                for t in 0 ..< tokens {
                    streaming.appendThinking("token \(t) ")
                    if t % 7 == 6 { streaming.appendThinking("\n\nNew paragraph. ") }
                    streamingBlocks = h.blocks(streamingTurnId: streaming.id)
                    h.expandEverything(in: streamingBlocks)
                    h.apply(streamingTurnId: streaming.id)
                }
                h.layout()
            }

            // Each applyBlocks coalesces the measured heights it receives into
            // a single noteHeightOfRows; the layout pass that follows may add
            // a few more as widths settle. Tool rows and thinking children
            // must not multiply that count.
            #expect(
                initial.noteCalls < initial.cells,
                "initial apply issued \(initial.noteCalls) noteHeightOfRows calls for \(initial.cells) cells (the per-child cascade issued several per cell)"
            )
            #expect(
                append.noteCalls <= 4,
                "path 3 apply issued \(append.noteCalls) noteHeightOfRows calls for \(append.cells) cells"
            )
            #expect(
                stream.noteCalls <= tokens + 4,
                "path 2 streaming issued \(stream.noteCalls) noteHeightOfRows calls for \(tokens) token updates"
            )
            #expect(h.tableView.numberOfRows == h.coordinator.blockIds.count)
        }
    }

    /// The measured heights still land: after the coalesced note, every
    /// materialised activity-group row is at least as tall as its cell's
    /// fitted content, exactly as the synchronous notes left it.
    @Test func coalescedHeightNotesStillApplyMeasuredHeights() {
        withActivityRollup {
            let h = Harness(viewportHeight: 600)
            for i in 1 ... 3 { h.addToolExchange(i, toolCalls: 3) }
            let first = h.blocks()
            h.expandEverything(in: first)
            h.apply()
            h.layout()

            h.addToolExchange(4, toolCalls: 3)
            let blocks = h.blocks()
            h.expandEverything(in: blocks)
            h.apply()
            h.layout()

            for row in 0 ..< h.tableView.numberOfRows {
                guard let cell = h.tableView.view(atColumn: 0, row: row, makeIfNecessary: false) else { continue }
                let rowHeight = h.tableView.rect(ofRow: row).height
                let id = h.coordinator.blockIds[row]
                guard case .activityGroup = h.coordinator.blockLookup[id]?.kind else { continue }
                let fitted = cell.fittingSize.height
                #expect(
                    rowHeight + 0.5 >= fitted,
                    "row \(row) (\(id)) is \(rowHeight)pt but its cell fits \(fitted)pt"
                )
            }
            #expect(h.tableView.numberOfRows == h.coordinator.blockIds.count)
        }
    }

    /// Narrowing the thread (a window or pane resize) re-heights the rows
    /// that were off screen too: scrolled back into view, none keeps the
    /// wider width's height while its text wraps at the new one.
    @Test func narrowingReheightsRowsThatWereOffScreen() {
        let h = Harness(viewportHeight: 300)
        let paragraph =
            "The failed run received an order record, not a GitHub repository URL. I'll make the workflow "
            + "handle accidental or pasted mixed input gracefully: it will extract a repository URL when one "
            + "is present, and otherwise explain what it needs."
        for i in 1 ... 8 {
            h.turns.append(ChatTurn(role: .user, content: "Question \(i)"))
            h.turns.append(ChatTurn(role: .assistant, content: "\(paragraph) \(paragraph)"))
        }
        h.apply()
        h.layout()
        h.coordinator.scrollAnchor.scrollToBottom()
        h.layout()

        h.width = 300
        h.tableView.tableColumns.first?.width = 300
        h.apply()
        h.layout()
        h.tableView.scroll(.zero)
        h.layout()

        var checked = 0
        for row in 0 ..< h.tableView.numberOfRows {
            guard let cell = h.tableView.view(atColumn: 0, row: row, makeIfNecessary: false) else { continue }
            let rowHeight = h.tableView.rect(ofRow: row).height
            let fitted = cell.fittingSize.height
            checked += 1
            #expect(rowHeight + 0.5 >= fitted, "row \(row) is \(rowHeight)pt but its cell fits \(fitted)pt")
        }
        #expect(checked > 0)
    }

    /// The same through the app's own table and scroll view, narrowed the
    /// way a window resize narrows the Architect's chat column: AppKit tiles
    /// the new width first, then SwiftUI passes it in.
    /// With always-visible scrollers the column narrows when the scroller
    /// shows. A transcript whose height sits at the edge of the visible
    /// area (a prompt card just opened above the input) must settle, not
    /// show and hide the scroller, re-wrapping every row each time.
    @Test func legacyScrollerAtTheOverflowEdgeSettles() {
        let tableView = MessageTableRepresentable.makeTableView()
        let scrollView = MessageTableRepresentable.makeScrollView(documentView: tableView)
        scrollView.sideInset = 16
        scrollView.contentInsets = NSEdgeInsetsZero
        scrollView.scrollerStyle = .legacy
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 900), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        scrollView.frame = window.contentView!.bounds
        scrollView.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(scrollView)

        let coordinator = MessageTableRepresentable.Coordinator()
        coordinator.tableView = tableView
        coordinator.scrollView = scrollView
        coordinator.setupDataSource(for: tableView)
        coordinator.setupScrollAnchor(
            scrollView: scrollView, tableView: tableView, onScrolledToBottom: {}, onScrolledAwayFromBottom: {})
        var widthChanges = 0
        scrollView.onContentWidthChanged = { [weak coordinator] in
            widthChanges += 1
            coordinator?.tiledContentWidthDidChange($0)
        }

        let memoizer = BlockMemoizer()
        let paragraph =
            "The revised listing is now explicit: it creates an approved draft ready to send and does not claim "
            + "to send the newsletter itself. The workflow still uses the selected model."
        var turns: [ChatTurn] = []
        for i in 1 ... 3 {
            turns.append(ChatTurn(role: .user, content: "Question \(i)"))
            turns.append(ChatTurn(role: .assistant, content: "\(paragraph)\n\n1. Rename it\n2. Rewrite it\n3. \(paragraph)"))
        }
        func settle(_ seconds: TimeInterval) {
            window.contentView?.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(seconds))
            window.contentView?.layoutSubtreeIfNeeded()
        }
        coordinator.lastSwiftUIWidth = 360
        var context = CellRenderingContext(
            width: coordinator.resolvedContentWidth(swiftUIWidth: 360),
            agentName: "Architect", agentAvatar: nil, agentCustomAvatarPath: nil, isStreaming: false,
            lastAssistantTurnId: turns.last?.id, theme: ThemeManager.shared.currentTheme,
            expandedIds: coordinator.expandedIds, onToggleExpand: { _ in },
            onHeightMeasured: { [weak coordinator] height, id in
                coordinator?.reportMeasuredHeight(height, forBlockId: id)
            })
        context.fullWidthMessages = true
        settle(0.2)
        coordinator.applyBlocks(
            memoizer.blocks(from: turns, streamingTurnId: nil, agentName: "Architect"),
            groupHeaderMap: memoizer.groupHeaderMap, context: context,
            isStreaming: false, lastAssistantTurnId: turns.last?.id, autoScrollEnabled: true)
        settle(0.4)

        let fullHeight = tableView.rect(ofRow: tableView.numberOfRows - 1).maxY
        var unsettled: [String] = []
        for height in stride(from: fullHeight + 40, through: fullHeight - 40, by: -4) {
            window.setContentSize(NSSize(width: 360, height: height))
            settle(0.4)
            widthChanges = 0
            settle(0.8)
            if widthChanges > 1 { unsettled.append("\(Int(height))pt: \(widthChanges) width changes while idle") }
        }
        #expect(unsettled.isEmpty, "\(unsettled)")
        window.close()
    }

    @Test func windowResizeReheightsTheArchitectChatColumn() {
        let tableView = MessageTableRepresentable.makeTableView()
        let scrollView = MessageTableRepresentable.makeScrollView(documentView: tableView)
        scrollView.sideInset = 16
        scrollView.configureWorkflowScrollbar(true)
        scrollView.contentInsets = NSEdgeInsetsZero
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 488, height: 420), styleMask: [.titled], backing: .buffered,
            defer: false)
        scrollView.frame = window.contentView!.bounds
        scrollView.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(scrollView)

        let coordinator = MessageTableRepresentable.Coordinator()
        coordinator.tableView = tableView
        coordinator.scrollView = scrollView
        coordinator.setupDataSource(for: tableView)
        coordinator.setupScrollAnchor(
            scrollView: scrollView, tableView: tableView, onScrolledToBottom: {}, onScrolledAwayFromBottom: {})
        scrollView.onContentWidthChanged = { [weak coordinator] in coordinator?.tiledContentWidthDidChange($0) }

        let memoizer = BlockMemoizer()
        var turns: [ChatTurn] = []
        let paragraph =
            "The failed run received an order record, not a GitHub repository URL. I'll make the workflow "
            + "handle accidental or pasted mixed input gracefully: it will extract a repository URL when one "
            + "is present, and otherwise explain what it needs."
        for i in 1 ... 8 {
            turns.append(ChatTurn(role: .user, content: "Question \(i)"))
            let answer = ChatTurn(role: .assistant, content: "")
            let calls = (1 ... 3).map { n in
                ToolCall(
                    id: "call_\(i)_\(n)", type: "function",
                    function: ToolCallFunction(name: "workflow_edit", arguments: "{\"step\": \(n)}"))
            }
            answer.toolCalls = calls
            for call in calls { answer.setToolResult("ok", for: call.id) }
            answer.appendContent(
                "\(paragraph)\n\n**What changed:** \(paragraph)\n\n- A normal URL\n- A URL inside pasted text\n- Unrelated data")
            turns.append(answer)
        }
        func settle(_ seconds: TimeInterval = 0.3) {
            window.contentView?.layoutSubtreeIfNeeded()
            tableView.layoutSubtreeIfNeeded()
            tableView.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(seconds))
            window.contentView?.layoutSubtreeIfNeeded()
            tableView.layoutSubtreeIfNeeded()
            tableView.displayIfNeeded()
        }
        func apply(swiftUIWidth: CGFloat) {
            coordinator.lastSwiftUIWidth = swiftUIWidth
            var context = CellRenderingContext(
                    width: coordinator.resolvedContentWidth(swiftUIWidth: swiftUIWidth),
                    agentName: "Architect", agentAvatar: nil, agentCustomAvatarPath: nil, isStreaming: false,
                    lastAssistantTurnId: turns.last?.id, theme: ThemeManager.shared.currentTheme,
                    expandedIds: coordinator.expandedIds, onToggleExpand: { _ in },
                    onHeightMeasured: { [weak coordinator] height, id in
                        coordinator?.reportMeasuredHeight(height, forBlockId: id)
                    })
            context.fullWidthMessages = true
            coordinator.applyBlocks(
                memoizer.blocks(from: turns, streamingTurnId: nil, agentName: "Architect"),
                groupHeaderMap: memoizer.groupHeaderMap, context: context,
                isStreaming: false, lastAssistantTurnId: turns.last?.id, autoScrollEnabled: true)
        }

        settle()
        apply(swiftUIWidth: 488)
        settle()
        coordinator.scrollAnchor.scrollToBottom()
        settle()

        for width in stride(from: 480, through: 308, by: -12).map(CGFloat.init) + [308] {
            window.setContentSize(NSSize(width: width, height: 420))
            settle(0.01)
            apply(swiftUIWidth: width)
        }
        settle()
        tableView.scroll(.zero)
        settle()

        var checked = 0
        for row in 0 ..< tableView.numberOfRows {
            guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) else { continue }
            let rowRect = tableView.rect(ofRow: row)
            checked += Self.textViews(in: cell)
            for overflow in Self.clippedText(in: cell, rowRect: rowRect, tableView: tableView) {
                Issue.record("row \(row): \(overflow)")
            }
        }
        #expect(checked > 0)
        #expect(abs((tableView.tableColumns.first?.width ?? 0) - (308 - 32)) <= 1)
    }

    static func textViews(in view: NSView) -> Int {
        (view is NSTextView ? 1 : 0) + view.subviews.reduce(0) { $0 + textViews(in: $1) }
    }

    /// Every text view in `cell` whose laid-out text runs past its own frame
    /// or past the row: text the reader can't see.
    static func clippedText(in cell: NSView, rowRect: NSRect, tableView: NSTableView) -> [String] {
        var out: [String] = []
        func visit(_ view: NSView) {
            if let text = view as? NSTextView, let manager = text.layoutManager, let container = text.textContainer,
                !text.isHidden, !(text.string.isEmpty)
            {
                manager.ensureLayout(for: container)
                let needed = manager.usedRect(for: container).height + 2 * text.textContainerInset.height
                let inTable = text.convert(text.bounds, to: tableView)
                if needed > text.bounds.height + 1 {
                    out.append("text needs \(needed)pt, its frame is \(text.bounds.height)pt: \(text.string.prefix(40))")
                } else if inTable.maxY > rowRect.maxY + 1 || inTable.minY < rowRect.minY - 1 {
                    out.append("text spans \(inTable.minY)–\(inTable.maxY), row \(rowRect.minY)–\(rowRect.maxY)")
                }
                if container.size.width > text.bounds.width + 1 {
                    out.append("text wraps at \(container.size.width)pt in a \(text.bounds.width)pt frame")
                }
            }
            view.subviews.forEach(visit)
        }
        visit(cell)
        return out
    }
}
