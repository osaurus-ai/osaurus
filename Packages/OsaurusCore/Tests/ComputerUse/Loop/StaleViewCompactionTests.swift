//
//  StaleViewCompactionTests.swift
//  OsaurusCoreTests — Computer Use
//
//  Every step appends a full screen listing and the history re-sends all of
//  them (a traced 30-step run grew from 3.5K to 68K prompt tokens). Old
//  listings are collapsed in batches: the latest two stay whole, the goal and
//  every action result line survive, and between batches the history is
//  append-only so provider prompt caching still hits.
//

import Foundation
import XCTest

@testable import OsaurusCore

final class StaleViewCompactionTests: XCTestCase {

    private func listing(_ n: Int) -> String {
        "App: Finder — window \"PII-Test\" [tier: ax]\n  [1] row \"file-\(n).pdf\"\n  [2] button \"New Folder\""
    }

    private func history(views: Int) -> [ChatMessage] {
        var messages = [
            ChatMessage(role: "system", content: "system prompt"),
            ChatMessage(role: "user", content: "Goal: organize PII-Test\n\nCurrent view:\n" + listing(0)),
        ]
        for n in 1 ..< views {
            messages.append(ChatMessage(role: "assistant", content: nil, tool_calls: [], tool_call_id: nil))
            let body =
                n == 1
                ? "Opened Finder.\n" + listing(n)
                : "Action succeeded. The view changed.\n\nCurrent view:\n" + listing(n)
            messages.append(ChatMessage(role: "tool", content: body, tool_calls: nil, tool_call_id: "call_\(n)"))
        }
        return messages
    }

    private func listingCount(_ messages: [ChatMessage]) -> Int {
        messages.filter { ComputerUseLoop.viewListingStart(in: $0.content) != nil }.count
    }

    func testBelowBatchThresholdLeavesHistoryUntouched() {
        var messages = history(views: ComputerUseLoop.keptRecentViews + ComputerUseLoop.viewCompactionBatch - 1)
        let before = messages.map(\.content)
        XCTAssertEqual(ComputerUseLoop.compactStaleViews(&messages), 0)
        XCTAssertEqual(messages.map(\.content), before, "no rewrite before a full batch keeps the prefix cacheable")
    }

    func testFullBatchCollapsesAllButLatestTwo() throws {
        let total = ComputerUseLoop.keptRecentViews + ComputerUseLoop.viewCompactionBatch
        var messages = history(views: total)
        XCTAssertEqual(ComputerUseLoop.compactStaleViews(&messages), total - ComputerUseLoop.keptRecentViews)
        XCTAssertEqual(listingCount(messages), ComputerUseLoop.keptRecentViews)

        let goal = try XCTUnwrap(messages[1].content)
        XCTAssertTrue(goal.hasPrefix("Goal: organize PII-Test"), "the goal must survive compaction")
        XCTAssertTrue(goal.contains(ComputerUseLoop.compactedViewMarker))
        XCTAssertFalse(goal.contains("file-0.pdf"))

        let opened = try XCTUnwrap(messages[3].content)
        XCTAssertTrue(opened.hasPrefix("Opened Finder."), "open results keep their outcome line")
        XCTAssertFalse(opened.contains("[tier: "))
        XCTAssertEqual(messages[3].tool_call_id, "call_1", "tool call pairing must be preserved")

        XCTAssertTrue(messages.last?.content?.contains("file-\(total - 1).pdf") == true)
    }

    func testHistoryStaysAppendOnlyBetweenBatches() {
        var messages = history(views: ComputerUseLoop.keptRecentViews + ComputerUseLoop.viewCompactionBatch)
        ComputerUseLoop.compactStaleViews(&messages)
        let afterBatch = messages.map(\.content)
        messages.append(
            ChatMessage(
                role: "tool", content: "Action succeeded.\n\nCurrent view:\n" + listing(99),
                tool_calls: nil, tool_call_id: "call_99"))
        XCTAssertEqual(ComputerUseLoop.compactStaleViews(&messages), 0)
        XCTAssertEqual(Array(messages.map(\.content).prefix(afterBatch.count)), afterBatch)
    }
}
