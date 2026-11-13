//
//  ChatThreadSmoothnessTests.swift
//  osaurusTests
//
//  Pin the chat thread's motion contracts: a following reader rests with
//  the last row clear of the bottom padding and stays there as the content
//  or the viewport changes size, a frame change that leaves the column
//  where it is does no cell work, a column width change re-wraps once, and
//  a disclosure toggle touches only its own row and never scrolls.
//

import AppKit
import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct ChatThreadSmoothnessTests {

    final class CountingTableView: NSTableView {
        var notedRows: [IndexSet] = []

        override func noteHeightOfRows(withIndexesChanged indexSet: IndexSet) {
            notedRows.append(indexSet)
            super.noteHeightOfRows(withIndexesChanged: indexSet)
        }
    }

    /// The app's table and scroll view, with the production content insets.
    @MainActor
    final class Thread {
        let window: NSWindow
        let tableView = CountingTableView()
        let scrollView: CenteredMessageScrollView
        let coordinator = MessageTableRepresentable.Coordinator()
        let memoizer = BlockMemoizer()
        let store = ExpandedBlocksStore()
        var turns: [ChatTurn] = []

        init(width: CGFloat = 700, height: CGFloat = 400) {
            MessageTableRepresentable.configureTableView(tableView)
            scrollView = MessageTableRepresentable.makeScrollView(documentView: tableView)
            // A connected mouse makes the system style legacy; pin it so the
            // column widths below don't depend on the machine.
            scrollView.scrollerStyle = .overlay
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled],
                backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            scrollView.frame = window.contentView!.bounds
            scrollView.autoresizingMask = [.width, .height]
            window.contentView?.addSubview(scrollView)
            coordinator.tableView = tableView
            coordinator.scrollView = scrollView
            coordinator.setupDataSource(for: tableView)
            coordinator.setupScrollAnchor(
                scrollView: scrollView, tableView: tableView, onScrolledToBottom: {}, onScrolledAwayFromBottom: {})
            scrollView.onUserScroll = { [weak coordinator] in coordinator?.userDidScroll() }
            scrollView.onUserScrolledUp = { [weak coordinator] in coordinator?.userDidScrollUp() }
            coordinator.sessionExpandedStore = store
            coordinator.lastSwiftUIWidth = CenteredMessageScrollView.contentWidth(in: width)
        }

        func apply(streaming: ChatTurn? = nil, appending extra: [ContentBlock] = []) {
            let context = CellRenderingContext(
                width: coordinator.resolvedContentWidth(swiftUIWidth: coordinator.lastSwiftUIWidth),
                agentName: "Osaurus", agentAvatar: nil, agentCustomAvatarPath: nil, isStreaming: streaming != nil,
                lastAssistantTurnId: turns.last(where: { $0.role == .assistant })?.id,
                theme: ThemeManager.shared.currentTheme,
                expandedIds: coordinator.expandedIds,
                onToggleExpand: { [weak self] id in
                    guard let self else { return }
                    self.coordinator.toggleExpand(id: id, sessionStore: self.store)
                },
                onHeightMeasured: { [weak coordinator] height, id in
                    coordinator?.reportMeasuredHeight(height, forBlockId: id)
                })
            coordinator.applyBlocks(
                memoizer.blocks(from: turns, streamingTurnId: streaming?.id, agentName: "Osaurus") + extra,
                groupHeaderMap: memoizer.groupHeaderMap, context: context, isStreaming: streaming != nil,
                lastAssistantTurnId: turns.last(where: { $0.role == .assistant })?.id, autoScrollEnabled: true)
        }

        func layout() {
            window.contentView?.layoutSubtreeIfNeeded()
            tableView.layoutSubtreeIfNeeded()
        }

        /// Suspends rather than spinning the run loop, so the main-queue work
        /// the thread schedules for itself gets to run.
        func settle(_ seconds: TimeInterval = 0.2) async {
            layout()
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            layout()
        }

        /// The SwiftUI side of a frame change: the target width first, then
        /// the frame steps there the way an animation moves it.
        func resize(toWidth width: CGFloat, steps: Int = 8) async {
            let from = scrollView.frame.width
            coordinator.lastSwiftUIWidth = CenteredMessageScrollView.contentWidth(in: width)
            coordinator.swiftUIWidthDidChange()
            apply()
            for step in 1 ... steps {
                let w = from + (width - from) * CGFloat(step) / CGFloat(steps)
                window.setContentSize(NSSize(width: w, height: window.contentView!.frame.height))
                await settle(0.01)
            }
            await settle(0.3)
        }

        /// The reader moving the thread (a scroller drag or keyboard scroll).
        func userScroll(toY y: CGFloat) {
            coordinator.userDidScroll()
            clip.setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: y))
            scrollView.reflectScrolledClipView(clip)
        }

        var clip: NSClipView { scrollView.contentView }
        var originY: CGFloat { clip.bounds.origin.y }
        var anchor: ScrollAnchorManager { coordinator.scrollAnchor }

        func addExchanges(_ count: Int, answer: String = Thread.paragraph) {
            for i in 0 ..< count {
                turns.append(ChatTurn(role: .user, content: "Question \(turns.count) \(i)"))
                turns.append(ChatTurn(role: .assistant, content: "\(answer)\n\n\(answer)"))
            }
        }

        /// An exchange whose answer thinks and calls two tools, which renders
        /// as one collapsed activity group row.
        func addToolExchange() {
            let n = turns.count
            turns.append(ChatTurn(role: .user, content: "Task \(n): inspect the repository."))
            let answer = ChatTurn(role: .assistant, content: "")
            answer.appendThinking("I should read the files first, then compare them.\n\n" + Thread.paragraph)
            let calls = (0 ..< 2).map { i in
                ToolCall(
                    id: "call_\(n)_\(i)", type: "function",
                    function: ToolCallFunction(name: "file_read", arguments: "{\"path\": \"src/m\(n)_\(i).swift\"}"))
            }
            answer.toolCalls = calls
            for call in calls {
                answer.setToolResult("line 1: import Foundation\nline 2: struct M {}\nline 3: // end", for: call.id)
            }
            answer.appendContent("Answer \(n): the modules differ in their initialisers.")
            turns.append(answer)
        }

        /// Rows rendering an activity group, top to bottom, with their block ids.
        var activityRows: [(row: Int, id: String)] {
            coordinator.blockIds.enumerated().compactMap { row, id in
                guard case .activityGroup = coordinator.blockLookup[id]?.kind else { return nil }
                return (row, id)
            }
        }

        /// Toggle `id` and sample the row and the scroll origin every few
        /// milliseconds until the disclosure has settled.
        func toggleAndSample(_ id: String, row: Int) async -> (heights: [CGFloat], headerOffsets: [CGFloat]) {
            var heights: [CGFloat] = []
            var offsets: [CGFloat] = []
            coordinator.toggleExpand(id: id, sessionStore: store)
            let end = Date().addingTimeInterval(DisclosureHeightAnimation.duration + 0.25)
            while Date() < end {
                layout()
                let rect = tableView.rect(ofRow: row)
                heights.append(rect.height)
                offsets.append(rect.minY - originY)
                try? await Task.sleep(nanoseconds: 4_000_000)
            }
            await settle(0.1)
            return (heights, offsets)
        }

        static let paragraph =
            "The failed run received an order record, not a GitHub repository URL. I'll make the workflow "
            + "handle pasted mixed input gracefully and explain what it needs when nothing usable is present."
    }

    // MARK: - Bottom rest

    @Test func followingReaderRestsWithTheLastRowClearOfTheBottomPadding() async {
        for exchanges in [1, 2, 4, 8] {
            let t = Thread()
            defer { t.window.close() }
            t.addExchanges(exchanges)
            t.apply()
            await t.settle()
            t.anchor.scrollToBottom()
            await t.settle()

            let insets = t.scrollView.contentInsets
            let last = t.tableView.rect(ofRow: t.tableView.numberOfRows - 1)
            let overflows = t.tableView.frame.height + insets.top + insets.bottom > t.clip.bounds.height
            #expect(t.anchor.isPinnedToBottom)
            #expect(abs(t.originY - t.anchor.bottomOriginY) <= 0.5, "\(exchanges): rest \(t.originY)")
            if overflows {
                #expect(
                    abs(last.maxY - (t.clip.bounds.maxY - insets.bottom)) <= 0.5,
                    "\(exchanges): last row ends at \(last.maxY), viewport padding starts at \(t.clip.bounds.maxY - insets.bottom)")
            } else {
                #expect(abs(t.originY + insets.top) <= 0.5, "\(exchanges): a short thread keeps its top padding")
            }
        }
    }

    /// A new window lays the thread out at zero size first. AppKit clamping
    /// the origin as the viewport grows is not the reader scrolling up.
    @Test func aThreadMountedAtZeroSizeKeepsFollowing() async {
        let t = Thread(width: 960, height: 600)
        defer { t.window.close() }
        t.scrollView.frame = .zero
        t.layout()
        t.addExchanges(1)
        t.apply()
        t.layout()
        for height: CGFloat in [10, 100, 300, 600] {
            t.scrollView.frame = NSRect(x: 0, y: 0, width: 960, height: height)
            t.layout()
            #expect(t.anchor.isPinnedToBottom, "\(height)pt viewport")
        }
        // Content arriving after the first layout (the onboarding panel) is followed.
        t.addExchanges(3)
        t.apply()
        await t.settle()
        #expect(t.anchor.isPinnedToBottom)
        #expect(abs(t.anchor.distanceFromBottom) <= 0.5)
    }

    /// AppKit shifts the origin when the top inset changes (the floating
    /// pill stack mounting); that is not the reader scrolling either.
    @Test func aContentInsetChangeKeepsAFollowingReaderAtTheBottom() async {
        let t = Thread(width: 960, height: 600)
        defer { t.window.close() }
        t.scrollView.contentInsets = NSEdgeInsetsZero
        t.addExchanges(2)
        t.apply()
        await t.settle()
        for top: CGFloat in [32, 80, 32] {
            t.scrollView.contentInsets = NSEdgeInsets(top: top, left: 0, bottom: 60, right: 0)
            t.layout()
            #expect(t.anchor.isPinnedToBottom, "\(top)pt top inset")
            #expect(abs(t.anchor.distanceFromBottom) <= 0.5, "\(top)pt top inset: \(t.anchor.distanceFromBottom)pt off")
        }
    }

    /// The band where the document is shorter than the viewport but taller
    /// than the viewport less its padding: only an inset-aware bottom keeps
    /// the streaming row clear of the bottom padding there.
    @Test func streamingThroughThePaddingBandKeepsTheLastRowVisible() async {
        let t = Thread(height: 400)
        defer { t.window.close() }
        t.turns.append(ChatTurn(role: .user, content: "Write a little"))
        let streaming = ChatTurn(role: .assistant, content: "Starting. ")
        t.turns.append(streaming)
        t.apply(streaming: streaming)
        await t.settle()
        let insets = t.scrollView.contentInsets
        var sawBand = false
        for n in 0 ..< 120 where t.tableView.frame.height < t.clip.bounds.height + 40 {
            streaming.appendContent(n % 9 == 8 ? "\n\nNext part. " : "word\(n) and a few more ")
            t.apply(streaming: streaming)
            await t.settle(0.02)
            let docH = t.tableView.frame.height
            let clipH = t.clip.bounds.height
            let last = t.tableView.rect(ofRow: t.tableView.numberOfRows - 1)
            if docH > clipH - insets.top - insets.bottom, docH < clipH { sawBand = true }
            #expect(t.anchor.isPinnedToBottom, "step \(n)")
            #expect(
                last.maxY <= t.clip.bounds.maxY - insets.bottom + 0.5,
                "step \(n): last row ends at \(last.maxY), padding starts at \(t.clip.bounds.maxY - insets.bottom)")
        }
        #expect(sawBand, "the content never passed through the padding band")
    }

    @Test func readerAtTheTrueBottomFollowsWithoutASnap() async {
        let t = Thread()
        defer { t.window.close() }
        t.addExchanges(6)
        t.turns.append(ChatTurn(role: .user, content: "Keep going"))
        let streaming = ChatTurn(role: .assistant, content: "Starting. ")
        t.turns.append(streaming)
        t.apply(streaming: streaming)
        await t.settle(0.5)
        // The reader scrolls up, then back down to the very end themselves.
        t.userScroll(toY: t.anchor.bottomOriginY - 120)
        #expect(!t.anchor.isPinnedToBottom)
        t.userScroll(toY: t.anchor.bottomOriginY)
        #expect(t.anchor.isPinnedToBottom, "reaching the bottom resumes following")

        var worst: CGFloat = 0
        for n in 0 ..< 40 {
            streaming.appendContent("word\(n) and more ")
            t.apply(streaming: streaming)
            await t.settle(0.02)
            worst = max(worst, abs(t.anchor.distanceFromBottom))
        }
        #expect(worst <= 1, "the following reader drifted \(worst)pt from the bottom")
    }

    @Test func aLargeJumpInContentKeepsFollowing() async {
        let t = Thread()
        defer { t.window.close() }
        t.addExchanges(4)
        t.turns.append(ChatTurn(role: .user, content: "Long answer please"))
        let streaming = ChatTurn(role: .assistant, content: "Starting. ")
        t.turns.append(streaming)
        t.apply(streaming: streaming)
        await t.settle()
        t.anchor.scrollToBottom()
        await t.settle()

        streaming.appendContent(String(repeating: "\n\n" + Thread.paragraph, count: 8))
        t.apply(streaming: streaming)
        await t.settle()
        #expect(t.anchor.isPinnedToBottom, "a single large height change must not drop following")
        #expect(abs(t.anchor.distanceFromBottom) <= 1)
    }

    // MARK: - Viewport

    @Test func viewportResizeKeepsAFollowingReaderAtTheBottom() async {
        let t = Thread()
        defer { t.window.close() }
        t.addExchanges(8)
        t.apply()
        await t.settle()
        t.anchor.scrollToBottom()
        await t.settle()

        for height: CGFloat in [300, 220, 360, 400] {
            t.window.setContentSize(NSSize(width: 700, height: height))
            // Same layout pass, no run-loop turn: nothing is drawn off the bottom.
            t.layout()
            #expect(abs(t.anchor.distanceFromBottom) <= 0.5, "\(height)pt viewport: \(t.anchor.distanceFromBottom)pt off")
        }
        #expect(t.anchor.isPinnedToBottom)
    }

    @Test func viewportResizeLeavesAScrolledUpReaderAlone() async {
        let t = Thread()
        defer { t.window.close() }
        t.addExchanges(8)
        t.apply()
        await t.settle()
        t.coordinator.userDidScrollUp()
        t.userScroll(toY: 200)
        await t.settle()
        let readingAt = t.originY

        t.window.setContentSize(NSSize(width: 700, height: 300))
        await t.settle()
        #expect(!t.anchor.isPinnedToBottom)
        #expect(abs(t.originY - readingAt) <= 0.5)
    }

    // MARK: - Width

    @Test func frameChangesThatKeepTheColumnDoNoCellWork() async {
        // Past the 800pt readable column the column width doesn't change.
        let t = Thread(width: 1400)
        defer { t.window.close() }
        t.addExchanges(8)
        t.apply()
        await t.settle()
        t.anchor.scrollToBottom()
        await t.settle()
        let column = t.tableView.tableColumns.first!.width
        let committed = t.coordinator.committedWidth

        t.tableView.notedRows.removeAll()
        await t.resize(toWidth: 1000)
        await t.resize(toWidth: 1300)

        #expect(t.tableView.tableColumns.first!.width == column)
        #expect(t.coordinator.committedWidth == committed)
        #expect(t.tableView.notedRows.isEmpty, "re-noted \(t.tableView.notedRows.map(\.count)) rows")
        #expect(abs(t.anchor.distanceFromBottom) <= 0.5)
    }

    @Test func aNarrowingFrameCommitsOneWidthBeforeItMoves() async {
        let t = Thread(width: 760)
        defer { t.window.close() }
        t.addExchanges(8)
        t.apply()
        await t.settle()
        t.anchor.scrollToBottom()
        await t.settle()

        var committed: [CGFloat] = []
        let from = t.coordinator.committedWidth
        t.coordinator.lastSwiftUIWidth = CenteredMessageScrollView.contentWidth(in: 560)
        t.coordinator.swiftUIWidthDidChange()
        committed.append(t.coordinator.committedWidth)
        for step in 1 ... 8 {
            let w = 760 - 200 * CGFloat(step) / 8
            t.window.setContentSize(NSSize(width: w, height: 400))
            await t.settle(0.01)
            if committed.last != t.coordinator.committedWidth { committed.append(t.coordinator.committedWidth) }
        }
        await t.settle(0.3)

        #expect(from > 600)
        #expect(committed == [520], "committed \(committed)")
        #expect(t.tableView.tableColumns.first!.width == 520)
        #expect(t.anchor.isPinnedToBottom)
        #expect(abs(t.anchor.distanceFromBottom) <= 1)
    }

    @Test func aWideningFrameKeepsTheColumnCenteredThenCommitsOnce() async {
        let t = Thread(width: 560)
        defer { t.window.close() }
        t.addExchanges(8)
        t.apply()
        await t.settle()
        t.anchor.scrollToBottom()
        await t.settle()
        #expect(t.coordinator.committedWidth == 520)

        var committed: [CGFloat] = []
        t.coordinator.lastSwiftUIWidth = CenteredMessageScrollView.contentWidth(in: 760)
        t.coordinator.swiftUIWidthDidChange()
        for step in 1 ... 8 {
            let w = 560 + 200 * CGFloat(step) / 8
            t.window.setContentSize(NSSize(width: w, height: 400))
            t.layout()
            if step < 8 {
                // Mid-animation: the committed column, centered in the wider frame.
                let insets = t.scrollView.contentInsets
                #expect(t.tableView.tableColumns.first!.width == 520, "step \(step)")
                #expect(abs(insets.left - insets.right) <= 0.5)
            }
            await t.settle(0.01)
            if committed.last != t.coordinator.committedWidth { committed.append(t.coordinator.committedWidth) }
        }
        await t.settle(0.3)

        #expect(committed.last == 720)
        #expect(committed.filter { $0 != 520 } == [720], "committed \(committed)")
        #expect(t.tableView.tableColumns.first!.width == 720)
        #expect(abs(t.anchor.distanceFromBottom) <= 1)
    }

    @Test func returningToAWidthRestoresItsMeasuredHeights() async {
        let t = Thread(width: 760)
        defer { t.window.close() }
        t.addExchanges(10)
        t.apply()
        await t.settle()
        // Bring every row on screen once so each is measured at this width,
        // not just estimated.
        var y = -t.scrollView.contentInsets.top
        while y < t.anchor.bottomOriginY {
            t.userScroll(toY: y)
            await t.settle(0.05)
            y += 200
        }
        t.anchor.scrollToBottom()
        await t.settle()
        let heightAtWide = t.tableView.frame.height

        await t.resize(toWidth: 560)
        #expect(t.tableView.frame.height > heightAtWide, "narrower text should wrap taller")
        await t.resize(toWidth: 760)
        #expect(abs(t.tableView.frame.height - heightAtWide) <= 1, "\(t.tableView.frame.height) vs \(heightAtWide)")
    }

    // MARK: - Disclosure

    @Test func aToggleMovesOnlyItsOwnRowAndKeepsItsHeaderStill() async throws {
        let t = Thread(height: 600)
        defer { t.window.close() }
        for _ in 0 ..< 4 { t.addToolExchange() }
        t.apply()
        await t.settle()
        let (row, id) = try #require(t.activityRows.dropFirst().first)
        // Reading with the group near the top of the viewport.
        t.coordinator.userDidScrollUp()
        t.userScroll(toY: t.tableView.rect(ofRow: row).minY - 40)
        await t.settle()
        let collapsedHeight = t.tableView.rect(ofRow: row).height
        let headerAt = t.tableView.rect(ofRow: row).minY - t.originY

        t.tableView.notedRows.removeAll()
        let open = await t.toggleAndSample(id, row: row)
        let expandedHeight = t.tableView.rect(ofRow: row).height
        #expect(expandedHeight > collapsedHeight + 40)
        #expect(t.tableView.notedRows.allSatisfy { $0 == IndexSet(integer: row) }, "noted \(t.tableView.notedRows)")
        #expect(open.headerOffsets.allSatisfy { abs($0 - headerAt) <= 0.5 }, "header moved: \(open.headerOffsets)")
        #expect(zip(open.heights, open.heights.dropFirst()).allSatisfy { $1 >= $0 - 0.5 }, "expand reversed")
        if !ChatFrameAnimator.reduceMotion {
            let between = Set(open.heights.filter { $0 > collapsedHeight + 1 && $0 < expandedHeight - 1 })
            #expect(between.count >= 3, "expand jumped: \(open.heights)")
        }

        t.tableView.notedRows.removeAll()
        let close = await t.toggleAndSample(id, row: row)
        #expect(abs(t.tableView.rect(ofRow: row).height - collapsedHeight) <= 0.5)
        #expect(
            t.tableView.notedRows.allSatisfy { $0 == IndexSet(integer: row) },
            "row \(row), noted \(t.tableView.notedRows.map { Array($0) })")
        #expect(close.headerOffsets.allSatisfy { abs($0 - headerAt) <= 0.5 }, "header moved: \(close.headerOffsets)")
        #expect(zip(close.heights, close.heights.dropFirst()).allSatisfy { $1 <= $0 + 0.5 }, "collapse reversed")
    }

    @Test func aToggleWhileFollowingNeverScrolls() async throws {
        let t = Thread(height: 600)
        defer { t.window.close() }
        for _ in 0 ..< 4 { t.addToolExchange() }
        t.apply()
        await t.settle()
        t.anchor.scrollToBottom()
        await t.settle()
        let (row, id) = try #require(t.activityRows.last)
        #expect(t.anchor.isPinnedToBottom)
        let origin = t.originY

        let open = await t.toggleAndSample(id, row: row)
        #expect(abs(t.originY - origin) <= 0.5, "expanding scrolled the thread by \(t.originY - origin)pt")
        #expect(Set(open.headerOffsets.map { ($0 * 2).rounded() }).count == 1, "header moved: \(open.headerOffsets)")
        #expect(!t.anchor.isPinnedToBottom, "content pushed below the viewport stops following")

        // Collapsing it again returns the reader to the bottom, following.
        _ = await t.toggleAndSample(id, row: row)
        #expect(abs(t.originY - origin) <= 0.5, "collapsing scrolled the thread by \(t.originY - origin)pt")
        #expect(t.anchor.isPinnedToBottom, "back at the bottom resumes following")
    }

    /// Expanding the streaming turn's activity while following, then more
    /// thinking arriving: the expanded header stays where the reader opened it.
    @Test func expandingTheStreamingActivityKeepsItsHeaderStillAsTokensArrive() async throws {
        let t = Thread(height: 600)
        defer { t.window.close() }
        for _ in 0 ..< 3 { t.addToolExchange() }
        t.addToolExchange()
        let streaming = try #require(t.turns.last)
        streaming.content = ""
        streaming.appendThinking("\n\nNow compare the two modules.")
        t.apply(streaming: streaming)
        await t.settle()
        t.anchor.scrollToBottom()
        await t.settle()
        let (row, id) = try #require(t.activityRows.last)
        #expect(t.anchor.isPinnedToBottom)

        _ = await t.toggleAndSample(id, row: row)
        let header = t.tableView.rect(ofRow: row).minY - t.originY
        for i in 0 ..< 12 {
            streaming.appendThinking(" Step \(i): " + Thread.paragraph)
            t.apply(streaming: streaming)
            await t.settle(0.05)
            let offset = t.tableView.rect(ofRow: row).minY - t.originY
            #expect(abs(offset - header) <= 0.5, "token \(i): header moved \(offset - header)pt")
        }
        #expect(!t.anchor.isPinnedToBottom)
    }

    @Test func aNestedToolRowToggleResizesItsGroupInStep() async throws {
        let t = Thread(height: 700)
        defer { t.window.close() }
        t.addToolExchange()
        t.apply()
        await t.settle()
        let (row, groupId) = try #require(t.activityRows.first)
        _ = await t.toggleAndSample(groupId, row: row)
        let groupOpen = t.tableView.rect(ofRow: row).height

        let callId = try #require(t.turns.last?.toolCalls?.first?.id)
        let cell = try #require(t.tableView.view(atColumn: 0, row: row, makeIfNecessary: false))
        let tool = try #require(Self.firstSubview(of: NativeToolCallGroupView.self, in: cell))
        let open = await t.toggleAndSample(callId, row: row)
        let rowOpen = t.tableView.rect(ofRow: row).height
        #expect(rowOpen > groupOpen + 20)
        #expect(zip(open.heights, open.heights.dropFirst()).allSatisfy { $1 >= $0 - 0.5 })
        // The group's required height follows its row, so nothing inside is squeezed.
        t.layout()
        #expect(abs(tool.frame.height - tool.measuredHeight()) <= 0.5, "\(tool.frame.height) vs \(tool.measuredHeight())")
    }

    // MARK: - Hosted rows

    @Test func aHostedRowAppearsAtItsSettledHeight() async throws {
        let t = Thread(height: 700)
        defer { t.window.close() }
        t.addExchanges(1)
        t.apply()
        await t.settle()
        let turnId = try #require(t.turns.last?.id)
        let suggestions = [
            "Explain how the workflow decides which pasted value is the repository and which is noise",
            "Show me the run again with a real repository URL",
            "What else can this agent accept as input?",
        ]
        let block = ContentBlock.followUpSuggestions(turnId: turnId, suggestions: suggestions)
        t.apply(appending: [block])
        // The first layout after the insert, before any SwiftUI geometry report.
        t.layout()
        let row = t.tableView.numberOfRows - 1
        let first = t.tableView.rect(ofRow: row).height
        await t.settle(0.4)
        let settled = t.tableView.rect(ofRow: row).height
        #expect(settled > 60)
        #expect(abs(first - settled) <= 1, "appeared at \(first)pt, settled at \(settled)pt")
    }

    private static func firstSubview<V: NSView>(of type: V.Type, in view: NSView) -> V? {
        for sub in view.subviews {
            if let match = sub as? V { return match }
            if let match = firstSubview(of: type, in: sub) { return match }
        }
        return nil
    }
}
