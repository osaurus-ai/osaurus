//
//  ChatThreadReliabilityTests.swift
//  osaurusTests
//
//  Pin the chat thread behaviors behind "Open Run sometimes can't be
//  clicked" and "the thread jumps while a reply streams": header links stay
//  clickable across streaming reconfigures, recycled markdown starts clean,
//  a reader who scrolls up is left alone, and rows growing above the
//  viewport don't move what the reader sees.

import AppKit
import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct ChatThreadReliabilityTests {

    // MARK: - Open Run

    private static let theme = CustomizableTheme(config: .lightDefault, fontScale: 1.0)

    private func workflowItem(runID: UUID) -> ToolCallItem {
        ToolCallItem(
            call: ToolCall(
                id: "call_run_" + UUID().uuidString,
                type: "function",
                function: ToolCallFunction(
                    name: RunWorkflowTool.toolName,
                    arguments: "{\"workflow\": \"Weekly digest\", \"input\": {\"topic\": \"release notes\"}}"
                )
            ),
            result: "{\"run_id\": \"\(runID.uuidString)\", \"status\": \"completed\"}"
        )
    }

    private func hostedRow() -> (NSWindow, NativeToolCallRowView) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 400), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        let row = NativeToolCallRowView(frame: NSRect(x: 0, y: 0, width: 640, height: 300))
        window.contentView?.addSubview(row)
        return (window, row)
    }

    private func openRunButton(in view: NSView) -> NSButton? {
        if let button = view as? NSButton, button.attributedTitle.string == L("Open Run") { return button }
        for subview in view.subviews {
            if let found = openRunButton(in: subview) { return found }
        }
        return nil
    }

    private func configure(_ row: NativeToolCallRowView, _ item: ToolCallItem, expanded: Bool) {
        row.configure(
            item: item, index: 0, totalCount: 1, isExpanded: expanded, width: 640, theme: Self.theme,
            onToggle: {}, onHeightChanged: {})
        row.layoutSubtreeIfNeeded()
    }

    /// The link must receive the click at its own center: nothing laid over
    /// it, and inside the row.
    private func expectClickable(_ button: NSButton, in row: NSView, _ note: String) {
        #expect(!button.isHidden, "\(note): Open Run is hidden")
        let center = NSPoint(x: button.bounds.midX, y: button.bounds.midY)
        let inSuperview = button.convert(center, to: row.superview)
        let hit = row.hitTest(inSuperview)
        #expect(hit === button || hit?.isDescendant(of: button) == true, "\(note): click lands on \(String(describing: hit))")
        #expect(row.bounds.contains(button.convert(button.bounds, to: row)), "\(note): Open Run sits outside the row")
    }

    @Test func openRunIsClickableCollapsedAndHiddenExpanded() throws {
        let (window, row) = hostedRow()
        defer { window.close() }
        let item = workflowItem(runID: UUID())

        configure(row, item, expanded: false)
        let button = try #require(openRunButton(in: row))
        expectClickable(button, in: row, "collapsed")

        configure(row, item, expanded: true)
        #expect(button.isHidden, "Open Run must not overlap the expanded arguments")

        configure(row, item, expanded: false)
        expectClickable(button, in: row, "collapsed again")
    }

    @Test func streamingReconfiguresKeepOpenRunStill() throws {
        let (window, row) = hostedRow()
        defer { window.close() }
        let item = workflowItem(runID: UUID())
        configure(row, item, expanded: false)
        let button = try #require(openRunButton(in: row))
        let frame = button.frame

        // Every streamed token reconfigures the row with the same item.
        for _ in 0 ..< 50 {
            configure(row, item, expanded: false)
            #expect(button.frame == frame)
        }
        expectClickable(button, in: row, "after streaming reconfigures")
    }

    // MARK: - Markdown reuse

    private func renderedStrings(_ view: NSView) -> [String] {
        if let textView = view as? NSTextView { return [textView.string] }
        return view.subviews.flatMap(renderedStrings)
    }

    @Test func streamedMarkdownMatchesOneShotRender() {
        let text =
            "# Plan\n\nFirst paragraph with **bold**.\n\n- one\n- two\n\n```swift\nlet x = 1\n```\n\n"
            + "| a | b |\n|---|---|\n| 1 | 2 |\n\nClosing paragraph."
        let streamed = NativeMarkdownView()
        var prefix = ""
        for character in text {
            prefix.append(character)
            streamed.configure(
                text: prefix, width: 600, theme: Self.theme, cacheKey: nil, isStreaming: true)
        }
        let oneShot = NativeMarkdownView()
        oneShot.configure(text: text, width: 600, theme: Self.theme, cacheKey: nil, isStreaming: true)
        #expect(renderedStrings(streamed) == renderedStrings(oneShot))
    }

    @Test func recycledMarkdownViewRendersOnlyTheNewMessage() {
        let view = NativeMarkdownView()
        let first = "Old reply that was streaming.\n\nSecond paragraph of the old reply.\n\nThird"
        var prefix = ""
        for character in first {
            prefix.append(character)
            view.configure(text: prefix, width: 600, theme: Self.theme, cacheKey: nil, isStreaming: true)
        }
        view.resetForReuse()

        let second = "Old reply that was streaming.\n\nA different message reusing the cell."
        view.configure(text: second, width: 600, theme: Self.theme, cacheKey: nil, isStreaming: true)
        let fresh = NativeMarkdownView()
        fresh.configure(text: second, width: 600, theme: Self.theme, cacheKey: nil, isStreaming: true)
        #expect(renderedStrings(view) == renderedStrings(fresh))
    }

    // MARK: - Scrolling

    @MainActor
    private final class Thread {
        let window: NSWindow
        let tableView: HoverTrackingTableView
        let scrollView: CenteredMessageScrollView
        let coordinator = MessageTableRepresentable.Coordinator()
        let memoizer = BlockMemoizer()
        var turns: [ChatTurn] = []

        init(viewportHeight: CGFloat) {
            tableView = MessageTableRepresentable.makeTableView()
            scrollView = MessageTableRepresentable.makeScrollView(documentView: tableView)
            scrollView.contentInsets = NSEdgeInsetsZero
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 700, height: viewportHeight), styleMask: [.titled],
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
            scrollView.onContentWidthChanged = { [weak coordinator] in coordinator?.tiledContentWidthDidChange($0) }
            coordinator.lastSwiftUIWidth = 700
        }

        func apply(streaming: ChatTurn? = nil) {
            let context = CellRenderingContext(
                width: coordinator.resolvedContentWidth(swiftUIWidth: 700),
                agentName: "Osaurus", agentAvatar: nil, agentCustomAvatarPath: nil, isStreaming: streaming != nil,
                lastAssistantTurnId: turns.last?.id, theme: ThemeManager.shared.currentTheme,
                expandedIds: coordinator.expandedIds, onToggleExpand: { _ in },
                onHeightMeasured: { [weak coordinator] height, id in
                    coordinator?.reportMeasuredHeight(height, forBlockId: id)
                })
            coordinator.applyBlocks(
                memoizer.blocks(from: turns, streamingTurnId: streaming?.id, agentName: "Osaurus"),
                groupHeaderMap: memoizer.groupHeaderMap, context: context, isStreaming: streaming != nil,
                lastAssistantTurnId: turns.last?.id, autoScrollEnabled: true)
        }

        /// Suspends rather than spinning the run loop: the test itself runs
        /// on the main queue, which a nested run loop can't drain, and the
        /// follow-the-stream work is queued there.
        func settle(_ seconds: TimeInterval = 0.2) async {
            window.contentView?.layoutSubtreeIfNeeded()
            tableView.layoutSubtreeIfNeeded()
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            window.contentView?.layoutSubtreeIfNeeded()
            tableView.layoutSubtreeIfNeeded()
        }

        var originY: CGFloat { scrollView.contentView.bounds.origin.y }

        func scroll(toY y: CGFloat) {
            scrollView.contentView.setBoundsOrigin(NSPoint(x: scrollView.contentView.bounds.origin.x, y: y))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        /// A scroll toward older content, through the scroll view's own event
        /// handling: `.pixel` is a trackpad, `.line` a mouse-wheel notch.
        func wheelUp(by amount: Int32, units: CGScrollEventUnit = .pixel) {
            guard
                let cgEvent = CGEvent(
                    scrollWheelEvent2Source: nil, units: units, wheelCount: 1, wheel1: amount, wheel2: 0,
                    wheel3: 0),
                let event = NSEvent(cgEvent: cgEvent)
            else { return }
            scrollView.scrollWheel(with: event)
        }

        static let paragraph =
            "The failed run received an order record, not a GitHub repository URL. I'll make the workflow "
            + "handle pasted mixed input gracefully and explain what it needs when nothing usable is present."
    }

    /// Six finished exchanges and a streaming reply, read from the bottom.
    private func streamingThread() async -> (Thread, ChatTurn) {
        let t = Thread(viewportHeight: 400)
        for i in 1 ... 6 {
            t.turns.append(ChatTurn(role: .user, content: "Question \(i)"))
            t.turns.append(ChatTurn(role: .assistant, content: "\(Thread.paragraph)\n\n\(Thread.paragraph)"))
        }
        t.turns.append(ChatTurn(role: .user, content: "Keep going"))
        let streaming = ChatTurn(role: .assistant, content: "Starting the answer. ")
        t.turns.append(streaming)
        t.apply(streaming: streaming)
        await t.settle()
        t.coordinator.scrollAnchor.scrollToBottom()
        await t.settle()
        return (t, streaming)
    }

    /// Token-sized deltas: the thread grows a line at a time, as it does live.
    private func stream(_ words: Int, into turn: ChatTurn, _ t: Thread) async {
        for n in 0 ..< words {
            turn.appendContent("word\(n) and more ")
            t.apply(streaming: turn)
            await t.settle(0.03)
        }
        await t.settle()
    }

    private func distanceFromBottom(_ t: Thread) -> CGFloat {
        t.tableView.frame.height - (t.originY + t.scrollView.contentView.bounds.height)
    }

    @Test func pinnedReaderFollowsTheStream() async {
        let (t, streaming) = await streamingThread()
        defer { t.window.close() }
        #expect(t.coordinator.scrollAnchor.isPinnedToBottom)
        let documentBefore = t.tableView.frame.height

        await stream(60, into: streaming, t)

        #expect(t.tableView.frame.height > documentBefore + 40, "the stream should have grown the thread")
        #expect(distanceFromBottom(t) <= 1, "the pinned reader fell \(distanceFromBottom(t))pt behind")
    }

    @Test func scrollingUpNearTheBottomStopsFollowingTheStream() async {
        let (t, streaming) = await streamingThread()
        defer { t.window.close() }
        #expect(t.coordinator.scrollAnchor.isPinnedToBottom)

        // Stay inside the 50pt band that otherwise still counts as "at bottom".
        let bottom = t.originY
        t.wheelUp(by: 8)
        if t.originY >= bottom - 0.5 {
            // Synthetic wheel events don't scroll in this environment; move the
            // clip view and report the upward scroll the way the event would.
            t.scroll(toY: bottom - 16)
            t.coordinator.userDidScrollUp()
        }
        await t.settle()
        let readingAt = t.originY
        #expect(readingAt < bottom - 0.5)
        #expect(
            distanceFromBottom(t) < t.coordinator.scrollAnchor.bottomThreshold,
            "scrolled past the band: \(distanceFromBottom(t))pt")
        #expect(!t.coordinator.scrollAnchor.isPinnedToBottom, "a reader who scrolled up must not stay pinned")
        let documentBefore = t.tableView.frame.height

        await stream(60, into: streaming, t)

        #expect(t.tableView.frame.height > documentBefore + 40, "the stream should have grown the thread")
        #expect(abs(t.originY - readingAt) <= 0.5, "streaming pulled the reader from \(readingAt) to \(t.originY)")

        t.coordinator.scrollAnchor.scrollToBottom()
        await t.settle()
        #expect(t.coordinator.scrollAnchor.isPinnedToBottom, "returning to the bottom resumes following")
        let documentAtBottom = t.tableView.frame.height
        await stream(30, into: streaming, t)
        #expect(t.tableView.frame.height > documentAtBottom)
        #expect(distanceFromBottom(t) <= 1, "following did not resume")
    }

    @Test func aWheelNotchStopsFollowingBeforeTheViewMoves() async {
        let (t, streaming) = await streamingThread()
        defer { t.window.close() }
        #expect(t.coordinator.scrollAnchor.isPinnedToBottom)

        // A notch animates its scroll, so the stream's next tick lands while
        // the view still sits at the bottom. The notch alone must unpin.
        t.wheelUp(by: 1, units: .line)
        #expect(!t.coordinator.scrollAnchor.isPinnedToBottom, "a wheel notch up must stop following")
        // Let the notch's own animation finish; how far it gets varies under load.
        var readingAt = t.originY
        for _ in 0 ..< 20 {
            await t.settle(0.1)
            if abs(t.originY - readingAt) <= 0.5 { break }
            readingAt = t.originY
        }

        await stream(60, into: streaming, t)
        #expect(abs(t.originY - readingAt) <= 0.5, "streaming pulled the reader from \(readingAt) to \(t.originY)")

        t.scroll(toY: t.tableView.frame.height - t.scrollView.contentView.bounds.height)
        await t.settle()
        #expect(t.coordinator.scrollAnchor.isPinnedToBottom, "scrolling back to the bottom resumes following")
        await stream(30, into: streaming, t)
        #expect(distanceFromBottom(t) <= 1, "following did not resume")
    }

    @Test func rowGrowingAboveTheViewportKeepsVisibleContentStill() async throws {
        let t = Thread(viewportHeight: 400)
        defer { t.window.close() }
        for i in 1 ... 12 {
            t.turns.append(ChatTurn(role: .user, content: "Question \(i)"))
            t.turns.append(ChatTurn(role: .assistant, content: "\(Thread.paragraph)\n\n\(Thread.paragraph)"))
        }
        t.apply()
        await t.settle()
        let documentHeight = t.tableView.frame.height
        #expect(documentHeight > 1200)
        t.scroll(toY: documentHeight / 2)
        t.coordinator.userDidScrollUp()
        await t.settle()
        #expect(!t.coordinator.scrollAnchor.isPinnedToBottom)

        let topRow = t.tableView.row(at: NSPoint(x: 0, y: t.originY))
        try #require(topRow >= 2)
        let offsetBefore = t.originY - t.tableView.rect(ofRow: topRow).origin.y
        // A row with a live cell re-measures itself when the table re-tiles
        // and would undo the injected height, so grow one that has none. The
        // anchor shift can still bring it on screen and replace the injected
        // height with the cell's real one; either way the row changed height.
        let rowAbove = try #require((0 ..< topRow - 1).last {
            t.tableView.view(atColumn: 0, row: $0, makeIfNecessary: false) == nil
        })
        let heightBefore = t.tableView.rect(ofRow: rowAbove).height
        t.coordinator.reportMeasuredHeight(heightBefore + 150, forBlockId: t.coordinator.blockIds[rowAbove])

        #expect(abs(t.tableView.rect(ofRow: rowAbove).height - heightBefore) > 0.5, "the row above never changed height")
        let offsetAfter = t.originY - t.tableView.rect(ofRow: topRow).origin.y
        #expect(abs(offsetAfter - offsetBefore) <= 0.5, "visible content moved by \(offsetBefore - offsetAfter)pt")
    }

    /// Open Run under the header: the thread's top and bottom padding are
    /// content insets, and a row scrolled into them is still drawn there.
    @Test func rowsScrolledIntoThePaddingStayClickable() async {
        let t = Thread(viewportHeight: 400)
        defer { t.window.close() }
        t.scrollView.contentInsets = NSEdgeInsets(top: 32, left: 0, bottom: 60, right: 0)
        for i in 1 ... 12 {
            t.turns.append(ChatTurn(role: .user, content: "Question \(i)"))
            t.turns.append(ChatTurn(role: .assistant, content: "\(Thread.paragraph)\n\n\(Thread.paragraph)"))
        }
        t.apply()
        await t.settle()
        t.scroll(toY: t.tableView.frame.height / 2)
        await t.settle()

        let frame = t.scrollView.frame
        for (band, yFromTop) in [("top", 16.0), ("bottom", frame.height - 30)] {
            let point = NSPoint(x: frame.midX, y: frame.maxY - yFromTop)
            let inTable = t.tableView.convert(point, from: t.scrollView.superview)
            #expect(t.tableView.row(at: inTable) >= 0, "no row drawn in the \(band) padding")
            let hit = t.window.contentView?.hitTest(point)
            #expect(hit?.isDescendant(of: t.tableView) == true, "a click in the \(band) padding lands on \(String(describing: hit))")
        }
    }
}
