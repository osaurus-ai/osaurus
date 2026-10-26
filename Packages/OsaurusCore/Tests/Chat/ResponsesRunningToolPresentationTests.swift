import AppKit
@preconcurrency import Combine
import Foundation
import Testing

@testable import OsaurusCore

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct ResponsesRunningToolPresentationTests {
    private func call(_ id: String = "fixture-call", name: String = "shell_run", command: String = "printf old") -> ToolCall {
        ToolCall(id: id, type: "function", function: .init(name: name, arguments: "{\"command\":\"\(command)\"}"))
    }
    private func rows(_ blocks: [ContentBlock]) -> [ToolCallItem] {
        blocks.flatMap { block -> [ToolCallItem] in
            switch block.kind {
            case .toolCallGroup(let calls): return calls
            case .activityGroup(let children): return rows(children)
            default: return []
            }
        }
    }
    private func owner() -> ChatTurn {
        let turn = ChatTurn(role: .assistant, content: "")
        turn.appendThinking("Real completed reasoning before the call.")
        turn.finalizeThinkingDuration()
        turn.completedAt = Date(timeIntervalSince1970: 100)
        return turn
    }
    private func blocks(_ memoizer: BlockMemoizer, _ turns: [ChatTurn]) -> [ContentBlock] {
        memoizer.blocks(from: turns, streamingTurnId: nil, activeTurnId: turns.last?.id, agentName: "Assistant")
    }
    private func descendants<T: NSView>(_ root: NSView, as type: T.Type) -> [T] {
        ((root as? T).map { [$0] } ?? []) + root.subviews.flatMap { descendants($0, as: type) }
    }
    private func wait(_ condition: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(domain: "ResponsesRunningToolPresentationTests.timeout", code: 1)
    }

    @Test func completedToolCallAppearsBeforeAnyResultOrFurtherText() throws {
        let turn = owner()
        let memoizer = BlockMemoizer()
        let before = blocks(memoizer, [turn])
        #expect(rows(before).isEmpty)
        // Canonical completion already cleared the preview and painted the
        // finishing state. Dispatch attaches the call before awaiting execution.
        let actual = call()
        turn.toolCalls = [actual]
        turn.markToolCallStarted(actual.id)
        let after = blocks(memoizer, [turn])
        let running = try #require(rows(after).first)
        #expect(running.call.id == actual.id && running.result == nil)
        #expect(turn.contentIsBlank && turn.pendingToolName == nil)
        let result = ToolEnvelope.success(tool: "shell_run", text: "Actual finished result")
        turn.setToolResult(result, for: actual.id)
        #expect(try #require(rows(blocks(memoizer, [turn])).first).result == result)
    }

    @Test func unchangedCountIdentityNameAndArgumentsReplaceTheCachedRow() throws {
        let turn = owner()
        let memoizer = BlockMemoizer()
        turn.toolCalls = [call()]
        let before = blocks(memoizer, [turn])
        turn.toolCalls = [call("replacement", name: "sandbox_exec", command: "printf new")]
        let replacement = blocks(memoizer, [turn])
        let replaced = try #require(rows(replacement).first)
        #expect(replaced.call.id == "replacement" && replaced.call.function.name == "sandbox_exec")
        #expect(replacement != before)
        turn.toolCalls = [call("replacement", name: "sandbox_exec", command: "printf now")]
        let corrected = blocks(memoizer, [turn])
        #expect(try #require(rows(corrected).first).call.function.arguments.contains("printf now"))
        #expect(corrected != replacement, "Diffable rows must observe same-ID argument changes too")
    }

    @Test func earlierOwningTurnChangesCannotHideBehindTheUnchangedTail() throws {
        let first = owner()
        let tail = ChatTurn(role: .assistant, content: "Later unchanged buffer")
        let memoizer = BlockMemoizer()
        _ = blocks(memoizer, [first, tail])
        first.toolCalls = [call("earlier-owner")]
        #expect(try #require(rows(blocks(memoizer, [first, tail])).first).call.id == "earlier-owner")
        first.toolCalls = [call("corrected-owner")]
        let appended = ChatTurn(role: .assistant, content: "Next buffer")
        #expect(rows(blocks(memoizer, [first, tail, appended])).map(\.call.id) == ["corrected-owner"])
    }

    private actor Terminations {
        var count = 0
        func record() { count += 1 }
    }

    @Test func sameIDArgumentCorrectionRefreshesAfterCollapsedUpdate() async throws {
        let row = NativeToolCallRowView(frame: .zero)
        func configure(_ command: String, expanded: Bool) {
            row.configure(item: ToolCallItem(call: call(command: command), result: nil),
                index: 0, totalCount: 1, isExpanded: expanded, width: 640, theme: LightTheme(),
                onToggle: {}, onHeightChanged: {})
        }
        func text() -> String {
            descendants(row, as: NSTextView.self).map(\.string).joined(separator: "\n")
        }
        configure("printf old", expanded: true)
        try await wait { text().contains("printf old") }
        configure("printf new", expanded: false)
        configure("printf new", expanded: true)
        try await wait { text().contains("printf new") && !text().contains("printf old") }
    }
    private final class Stream: @unchecked Sendable {
        let output = PassthroughSubject<Data, Never>()
        let status = CurrentValueSubject<LiveExecRegistry.LiveExecStatus, Never>(.running)
    }

    @Test func publishedRunningRowMountsLiveOutputAndTheRealTerminateControl() async throws {
        let turn = owner()
        let memoizer = BlockMemoizer()
        _ = blocks(memoizer, [turn])
        let id = "responses-running-ui-" + UUID().uuidString
        let actualCall = call(id)
        turn.toolCalls = [actualCall]
        turn.markToolCallStarted(id)
        let item = try #require(rows(blocks(memoizer, [turn])).first)
        #expect(item.result == nil, "The row must exist while dispatch is still awaiting a result")
        let row = NativeToolCallRowView(frame: .zero)
        func configure(_ item: ToolCallItem) {
            row.configure(item: item, index: 0, totalCount: 1, isExpanded: true, width: 640,
                theme: LightTheme(), onToggle: {}, onHeightChanged: {})
        }
        configure(item)
        let stream = Stream()
        let terminations = Terminations()
        let entry = LiveExecRegistry.Entry(toolCallId: id, pid: "fixture", command: "printf old",
            startedAt: Date(), outputPublisher: stream.output.eraseToAnyPublisher(),
            statusPublisher: stream.status.eraseToAnyPublisher(), currentStatus: { stream.status.value },
            seed: { Data("seed output\n".utf8) }, terminate: { _ in
                await terminations.record()
                stream.status.send(.killed(reason: "user"))
            })
        defer { Task { await LiveExecRegistry.shared.unregister(toolCallId: id) } }
        // Registration happens after the row exists, as in real dispatch.
        await LiveExecRegistry.shared.register(entry)
        try await wait { descendants(row, as: TerminalDisplayView.self).first != nil }
        let terminal = try #require(descendants(row, as: TerminalDisplayView.self).first)
        defer { terminal.unbind() }
        #expect(!terminal._test_terminateHidden)
        try await wait { terminal._test_textStorageString.contains("seed output") }
        stream.output.send(Data("live output\n".utf8))
        try await wait { terminal._test_textStorageString.contains("live output") }
        let terminate = try #require(descendants(row, as: NSButton.self).first { $0.accessibilityLabel() == "Terminate" })
        terminate.performClick(nil)
        try await wait { await terminations.count == 1 }
        try await wait { terminal._test_terminateHidden }
        let result = ToolEnvelope.success(tool: "shell_run", result: [
            "stdout": "seed output\nlive output\n", "stderr": "", "exit_code": 143, "killed_by": "user",
        ])
        turn.setToolResult(result, for: id)
        configure(try #require(rows(blocks(memoizer, [turn])).first))
        let completed = try #require(descendants(row, as: TerminalDisplayView.self).first)
        #expect(completed._test_terminateHidden)
        #expect(completed._test_textStorageString.contains("live output"))
        #expect(completed._test_statusLabelString.contains("terminated"))
    }
}
