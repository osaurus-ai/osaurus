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

        func context(isStreaming: Bool) -> CellRenderingContext {
            CellRenderingContext(
                width: 680,
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
}
