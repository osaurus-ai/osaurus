//
//  MessageTableSnapshotApplyTests.swift
//
//  Drives the real `MessageTableRepresentable.Coordinator` against a real
//  `NSTableView` in an offscreen window, through `applyBlocks` → path 3
//  (`applyFullSnapshot`). Pins the fix for the APPLE-MACOS-4M / 14J
//  main-thread hangs: the diffable snapshot is applied incrementally
//  (`animatingDifferences: true`, `defaultRowAnimation = []`) instead of via
//  `reloadData`, so cells for rows that did not change survive a new block,
//  the completion still runs synchronously, and the document frame is
//  current when the post-snapshot scroll runs.
//

import AppKit
import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct MessageTableSnapshotApplyTests {

    @MainActor
    private final class Harness {
        let window: NSWindow
        let scrollView: NSScrollView
        let tableView: NSTableView
        let coordinator: MessageTableRepresentable.Coordinator
        let memoizer = BlockMemoizer()
        var turns: [ChatTurn] = []
        var scrolledToBottom = 0
        var scrolledAway = 0

        init() {
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 700, height: 400),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            scrollView = NSScrollView(frame: window.contentView!.bounds)
            tableView = NSTableView(frame: scrollView.bounds)
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("message"))
            column.width = 680
            tableView.addTableColumn(column)
            tableView.headerView = nil
            tableView.style = .plain
            scrollView.documentView = tableView
            window.contentView?.addSubview(scrollView)

            coordinator = MessageTableRepresentable.Coordinator()
            coordinator.tableView = tableView
            coordinator.scrollView = scrollView
            coordinator.setupDataSource(for: tableView)
            coordinator.setupScrollAnchor(
                scrollView: scrollView,
                tableView: tableView,
                onScrolledToBottom: { [unowned self] in scrolledToBottom += 1 },
                onScrolledAwayFromBottom: { [unowned self] in scrolledAway += 1 }
            )
            coordinator.lastSwiftUIWidth = 680
        }

        func context(isStreaming: Bool, theme: any ThemeProtocol = ThemeManager.shared.currentTheme)
            -> CellRenderingContext
        {
            CellRenderingContext(
                width: 680,
                agentName: "Osaurus",
                agentAvatar: nil,
                agentCustomAvatarPath: nil,
                isStreaming: isStreaming,
                lastAssistantTurnId: turns.last(where: { $0.role == .assistant })?.id,
                theme: theme,
                expandedIds: coordinator.expandedIds,
                onToggleExpand: { _ in },
                onHeightMeasured: { [weak coordinator] height, id in
                    coordinator?.reportMeasuredHeight(height, forBlockId: id)
                }
            )
        }

        /// The ChatView → applyBlocks hop, using the same BlockMemoizer the
        /// live window uses.
        @discardableResult
        func apply(streamingTurnId: UUID? = nil, theme: any ThemeProtocol = ThemeManager.shared.currentTheme)
            -> [ContentBlock]
        {
            let blocks = memoizer.blocks(
                from: turns,
                streamingTurnId: streamingTurnId,
                agentName: "Osaurus"
            )
            coordinator.applyBlocks(
                blocks,
                groupHeaderMap: memoizer.groupHeaderMap,
                context: context(isStreaming: streamingTurnId != nil, theme: theme),
                isStreaming: streamingTurnId != nil,
                lastAssistantTurnId: turns.last(where: { $0.role == .assistant })?.id,
                autoScrollEnabled: true
            )
            return blocks
        }

        /// Force AppKit to materialise row views for the visible rect.
        func layout() {
            window.contentView?.layoutSubtreeIfNeeded()
            tableView.layoutSubtreeIfNeeded()
            tableView.displayIfNeeded()
        }

        func cellObjects() -> [String: ObjectIdentifier] {
            var out: [String: ObjectIdentifier] = [:]
            for row in 0 ..< tableView.numberOfRows {
                guard let id = coordinator.blockIds.indices.contains(row) ? coordinator.blockIds[row] : nil,
                    let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false)
                else { continue }
                out[id] = ObjectIdentifier(cell)
            }
            return out
        }

        func addExchange(_ n: Int) {
            turns.append(ChatTurn(role: .user, content: "Question \(n): what is \(n) squared?"))
            let answer = ChatTurn(role: .assistant, content: "")
            answer.appendContent("Answer \(n): \(n * n).\n\nSecond paragraph for turn \(n).")
            turns.append(answer)
        }
    }

    @Test func appendingABlockKeepsExistingCells() {
        let h = Harness()
        for i in 1 ... 4 { h.addExchange(i) }
        let first = h.apply()
        h.layout()
        #expect(h.tableView.numberOfRows == first.count)
        #expect(h.tableView.numberOfRows > 0)
        let before = h.cellObjects()
        #expect(!before.isEmpty, "row views should be materialised in the offscreen window")

        // A new exchange lands: path 3 (ids changed) → applyFullSnapshot.
        h.addExchange(5)
        let second = h.apply()
        h.layout()
        #expect(h.tableView.numberOfRows == second.count)
        #expect(second.count > first.count)

        let after = h.cellObjects()
        let rebuilt = before.filter { id, obj in after[id] != nil && after[id] != obj }
        #expect(
            rebuilt.isEmpty,
            "reloadData would have rebuilt every visible cell; incremental apply must keep them: \(rebuilt.keys.sorted())"
        )
    }

    @Test func documentFrameIsCurrentAfterApply() {
        let h = Harness()
        for i in 1 ... 3 { h.addExchange(i) }
        h.apply()
        h.layout()
        let heightBefore = h.tableView.frame.height

        let rowsBefore = h.tableView.numberOfRows
        h.addExchange(4)
        h.apply()
        // No layout pass here on purpose: applyFullSnapshot tiles the table so
        // `scrollToBottom` / `restoreAnchor` read a current document height.
        let heightAfter = h.tableView.frame.height
        let rowsAfter = h.tableView.numberOfRows
        #expect(rowsAfter > rowsBefore)
        #expect(
            heightAfter > heightBefore,
            "rows \(rowsBefore)->\(rowsAfter) height \(heightBefore)->\(heightAfter); after explicit tile: \({ h.tableView.tile(); return h.tableView.frame.height }()) after layout: \({ h.layout(); return h.tableView.frame.height }())"
        )
        #expect(h.tableView.numberOfRows == h.coordinator.blockIds.count)
    }

    /// A tool-call/paragraph row that changed content (same block id) while a
    /// new block arrived: the reconfigure path calls `noteHeightOfRows` right
    /// after the diff is applied. Doing that inside AppKit's apply completion
    /// recursed until the stack overflowed; it must be a plain call now.
    @Test func reconfiguringChangedRowsAlongsideInsertDoesNotRecurse() {
        let h = Harness()
        for i in 1 ... 3 { h.addExchange(i) }
        h.apply()
        h.layout()
        let before = h.cellObjects()

        // Same turn (same block ids), different text → stableChangedIds.
        let edited = h.turns[1]
        edited.content = "Answer 1: 1. Edited in place with a longer body so the height changes.\n\nSecond paragraph for turn 1."
        h.addExchange(4)
        let blocks = h.apply()
        h.layout()

        #expect(h.tableView.numberOfRows == blocks.count)
        let after = h.cellObjects()
        for (id, obj) in before where after[id] != nil {
            #expect(after[id] == obj, "row \(id) should have been reconfigured in place, not rebuilt")
        }
    }

    @Test func removingTurnsShrinksTheTableWithoutRebuildingSurvivors() {
        let h = Harness()
        for i in 1 ... 5 { h.addExchange(i) }
        h.apply()
        h.layout()
        let before = h.cellObjects()
        let survivorsBefore = h.coordinator.blockIds

        // Truncate the last two exchanges (delete a user turn and everything after).
        h.turns.removeLast(4)
        let blocks = h.apply()
        h.layout()
        #expect(h.tableView.numberOfRows == blocks.count)
        #expect(blocks.count < survivorsBefore.count)

        let after = h.cellObjects()
        for (id, obj) in after {
            if let old = before[id] {
                #expect(old == obj, "surviving row \(id) was rebuilt")
            }
        }
    }

    @Test func streamingTurnThenNewBlockKeepsPinnedToBottom() {
        let h = Harness()
        for i in 1 ... 6 { h.addExchange(i) }
        h.apply()
        h.layout()
        h.coordinator.scrollAnchor.scrollToBottom()
        h.coordinator.scrollAnchor.checkPinnedState()
        #expect(h.coordinator.scrollAnchor.isPinnedToBottom)

        // Streaming answer that grows a paragraph (path 2) and then adds a
        // second block (path 3) while pinned.
        h.turns.append(ChatTurn(role: .user, content: "Question 7"))
        let streaming = ChatTurn(role: .assistant, content: "")
        h.turns.append(streaming)
        h.apply(streamingTurnId: streaming.id)
        h.layout()
        streaming.appendContent("Streaming answer body that keeps growing ")
        h.apply(streamingTurnId: streaming.id)
        streaming.appendContent("and growing.\n\n```swift\nlet x = 1\n```\n")
        h.apply(streamingTurnId: streaming.id)
        h.layout()
        h.apply()  // stream ended
        h.layout()

        #expect(h.tableView.numberOfRows == h.coordinator.blockIds.count)
        let clip = h.scrollView.contentView
        let maxY = max(0, h.tableView.frame.height - clip.bounds.height)
        #expect(abs(clip.bounds.origin.y - maxY) <= 2, "expected to stay pinned: y=\(clip.bounds.origin.y) maxY=\(maxY)")
        #expect(h.coordinator.scrollAnchor.isPinnedToBottom)
    }

    @Test func repeatedApplyWithUnchangedBlocksIsANoOp() {
        let h = Harness()
        for i in 1 ... 3 { h.addExchange(i) }
        h.apply()
        h.layout()
        let before = h.cellObjects()
        h.apply()
        h.apply()
        h.layout()
        #expect(h.cellObjects() == before)
    }
}
