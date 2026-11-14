//
//  ContentBlockEngineTailTests.swift
//  OsaurusCoreTests
//
//  The chat's `streamingTurnId` goes nil the moment the engine reports output
//  complete (so the cursor stops at the last letter), but for local MLX the
//  stream stays open for vmlx's post-generation cache-store tail — and a
//  tool-call step's parsed invocation only arrives at that stream's end.
//  `generateBlocks(activeTurnId:)` keeps the progress affordances (pending
//  tool chip, typing indicator) alive for that window and labels it
//  `.finishing`, instead of rendering a header-only assistant row under a
//  live Stop button.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct ContentBlockEngineTailTests {

    private func typingPhases(in blocks: [ContentBlock]) -> [TypingIndicatorPhase] {
        blocks.compactMap { block in
            guard case let .typingIndicator(phase) = block.kind else { return nil }
            return phase
        }
    }

    private func contains(_ blocks: [ContentBlock], where match: (ContentBlockKind) -> Bool) -> Bool {
        blocks.contains { match($0.kind) }
    }

    // MARK: - Pending tool chip

    @Test
    func pendingToolChipSurvivesOutputCompleteWhileRunIsOpen() {
        let assistant = ChatTurn(role: .assistant, content: "")
        assistant.pendingToolName = "web_search"

        let blocks = ContentBlock.generateBlocks(
            from: [assistant],
            streamingTurnId: nil,
            activeTurnId: assistant.id,
            agentName: "Assistant"
        )

        #expect(
            contains(blocks) {
                if case let .pendingToolCall(name, _, _) = $0 { return name == "web_search" }
                return false
            },
            "the parsed call only lands at stream end; the chip must cover the engine tail"
        )
        // The chip already signals progress — no second progress row on top.
        #expect(typingPhases(in: blocks).isEmpty)
        // Not a finished turn: no footer, no empty-turn notice.
        #expect(!contains(blocks) { if case .assistantActions = $0 { return true }; return false })
        #expect(!contains(blocks) { if case .paragraph = $0 { return true }; return false })
    }

    @Test
    func pendingToolStepWithPreambleHidesStatsAndFooterDuringTail() {
        // Live: "I'll check the configuration…" + a pending call. The rolling
        // tok/s is stamped mid-stream, so without the intermediate-step guard
        // the stats row and copy/regenerate footer flashed under the chip.
        let assistant = ChatTurn(role: .assistant, content: "I'll check the configuration.")
        assistant.pendingToolName = "osaurus_config"
        assistant.generationTokensPerSecond = 38.1

        let blocks = ContentBlock.generateBlocks(
            from: [assistant],
            streamingTurnId: nil,
            activeTurnId: assistant.id,
            agentName: "Assistant"
        )

        #expect(contains(blocks) { if case .pendingToolCall = $0 { return true }; return false })
        #expect(!contains(blocks) { if case .generationStats = $0 { return true }; return false })
        #expect(!contains(blocks) { if case .assistantActions = $0 { return true }; return false })
        #expect(typingPhases(in: blocks).isEmpty)
    }

    @Test
    func pendingToolChipStillRequiresAnOpenRun() {
        let assistant = ChatTurn(role: .assistant, content: "")
        assistant.pendingToolName = "web_search"

        let blocks = ContentBlock.generateBlocks(
            from: [assistant],
            streamingTurnId: nil,
            activeTurnId: nil,
            agentName: "Assistant"
        )

        #expect(!contains(blocks) { if case .pendingToolCall = $0 { return true }; return false })
    }

    // MARK: - Typing indicator phases

    @Test
    func emptyTurnShowsGeneratingWhileStreaming() {
        let assistant = ChatTurn(role: .assistant, content: "")

        let blocks = ContentBlock.generateBlocks(
            from: [assistant],
            streamingTurnId: assistant.id,
            activeTurnId: assistant.id,
            agentName: "Assistant"
        )

        #expect(typingPhases(in: blocks) == [.generating])
    }

    @Test
    func emptyTurnShowsFinishingOnceOutputCompleteWithRunOpen() {
        let assistant = ChatTurn(role: .assistant, content: "")

        let blocks = ContentBlock.generateBlocks(
            from: [assistant],
            streamingTurnId: nil,
            activeTurnId: assistant.id,
            agentName: "Assistant"
        )

        #expect(typingPhases(in: blocks) == [.finishing])
        // Same block id across the phase flip so the cell is reconfigured, not replaced.
        let id = blocks.first { if case .typingIndicator = $0.kind { return true }; return false }?.id
        #expect(id == "typing-\(assistant.id.uuidString)")
    }

    @Test
    func phaseFlipChangesBlockEquality() {
        let turnId = UUID()
        let generating = ContentBlock.typingIndicator(turnId: turnId, phase: .generating, position: .middle)
        let finishing = ContentBlock.typingIndicator(turnId: turnId, phase: .finishing, position: .middle)
        #expect(generating.id == finishing.id)
        #expect(generating != finishing)
    }

    @Test
    func textTurnGetsFinishingRowAfterContentDuringTail() {
        let assistant = ChatTurn(role: .assistant, content: "Here is the spec.")

        let blocks = ContentBlock.generateBlocks(
            from: [assistant],
            streamingTurnId: nil,
            activeTurnId: assistant.id,
            agentName: "Assistant"
        )

        let paragraphIndex = blocks.firstIndex { if case .paragraph = $0.kind { return true }; return false }
        let typingIndex = blocks.firstIndex { if case .typingIndicator = $0.kind { return true }; return false }
        #expect(typingPhases(in: blocks) == [.finishing])
        #expect(paragraphIndex != nil && typingIndex != nil)
        if let paragraphIndex, let typingIndex {
            #expect(paragraphIndex < typingIndex, "the status row follows the painted answer")
        }
        // Stats land only when the stream closes (ttft is stamped after the loop).
        #expect(!contains(blocks) { if case .generationStats = $0 { return true }; return false })
        // The paragraph itself is no longer streaming: the cursor stopped at the last letter.
        #expect(
            contains(blocks) {
                if case let .paragraph(_, _, isStreaming, _) = $0 { return !isStreaming }
                return false
            }
        )
    }

    @Test
    func textTurnWhileStreamingHasNoFinishingRow() {
        let assistant = ChatTurn(role: .assistant, content: "Here is the spec.")

        let blocks = ContentBlock.generateBlocks(
            from: [assistant],
            streamingTurnId: assistant.id,
            activeTurnId: assistant.id,
            agentName: "Assistant"
        )

        #expect(typingPhases(in: blocks).isEmpty)
    }

    @Test
    func finishedTurnHasNoIndicator() {
        let assistant = ChatTurn(role: .assistant, content: "Here is the spec.")

        let blocks = ContentBlock.generateBlocks(
            from: [assistant],
            streamingTurnId: nil,
            activeTurnId: nil,
            agentName: "Assistant"
        )

        #expect(typingPhases(in: blocks).isEmpty)
        #expect(contains(blocks) { if case .assistantActions = $0 { return true }; return false })
    }

    // MARK: - Progress already signalled elsewhere

    @Test
    func committedToolCallsSuppressFinishingRow() {
        let assistant = ChatTurn(role: .assistant, content: "")
        let call = ToolCall(
            id: "call_1",
            type: "function",
            function: ToolCallFunction(name: "web_search", arguments: "{}")
        )
        assistant.toolCalls = [call]

        let blocks = ContentBlock.generateBlocks(
            from: [assistant],
            streamingTurnId: nil,
            activeTurnId: assistant.id,
            agentName: "Assistant"
        )

        #expect(typingPhases(in: blocks).isEmpty)
        #expect(contains(blocks) { if case .toolCallGroup = $0 { return true }; return false })
    }

    @Test
    func remoteToolActivitySuppressesFinishingRow() {
        let assistant = ChatTurn(role: .assistant, content: "")
        assistant.noteRemoteToolStarted(callId: "r1", name: "web_search")

        let blocks = ContentBlock.generateBlocks(
            from: [assistant],
            streamingTurnId: nil,
            activeTurnId: assistant.id,
            agentName: "Assistant"
        )

        #expect(typingPhases(in: blocks).isEmpty)
    }

    // MARK: - Empty-turn notices wait for the run to close

    @Test
    func noVisibleTextNoticeWaitsForRunToClose() {
        let assistant = ChatTurn(role: .assistant, content: "")
        assistant.generationTokenCount = 12

        let openRun = ContentBlock.generateBlocks(
            from: [assistant],
            streamingTurnId: nil,
            activeTurnId: assistant.id,
            agentName: "Assistant"
        )
        #expect(!contains(openRun) { if case .paragraph = $0 { return true }; return false })
        #expect(typingPhases(in: openRun) == [.finishing])

        let closedRun = ContentBlock.generateBlocks(
            from: [assistant],
            streamingTurnId: nil,
            activeTurnId: nil,
            agentName: "Assistant"
        )
        let texts = closedRun.compactMap { block -> String? in
            guard case let .paragraph(_, text, _, _) = block.kind else { return nil }
            return text
        }
        #expect(texts == ["No visible text was produced."])
    }

    // MARK: - Only the last turn is active

    @Test
    func earlierTurnsAreNeverActive() {
        let earlier = ChatTurn(role: .assistant, content: "")
        earlier.pendingToolName = "stale"
        let user = ChatTurn(role: .user, content: "next")
        let current = ChatTurn(role: .assistant, content: "")

        let blocks = ContentBlock.generateBlocks(
            from: [earlier, user, current],
            streamingTurnId: nil,
            activeTurnId: current.id,
            agentName: "Assistant"
        )

        #expect(!contains(blocks) { if case .pendingToolCall = $0 { return true }; return false })
        let indicators = blocks.filter { if case .typingIndicator = $0.kind { return true }; return false }
        #expect(indicators.map(\.turnId) == [current.id])
    }
}

// MARK: - BlockMemoizer threading

@MainActor
struct BlockMemoizerEngineTailTests {

    @Test
    func activeTurnIdChangeInvalidatesFastPath() {
        let memoizer = BlockMemoizer()
        let assistant = ChatTurn(role: .assistant, content: "")
        assistant.pendingToolName = "web_search"

        // Streaming: chip rendered via `isStreaming`.
        let streaming = memoizer.blocks(
            from: [assistant],
            streamingTurnId: assistant.id,
            activeTurnId: assistant.id,
            agentName: "Assistant"
        )
        #expect(streaming.contains { if case .pendingToolCall = $0.kind { return true }; return false })

        // Output complete, run open: same turn, same content — only the ids
        // changed. The memoizer must not serve the cached array blindly.
        let tail = memoizer.blocks(
            from: [assistant],
            streamingTurnId: nil,
            activeTurnId: assistant.id,
            agentName: "Assistant"
        )
        #expect(tail.contains { if case .pendingToolCall = $0.kind { return true }; return false })

        // Run closed: chip gone.
        let closed = memoizer.blocks(
            from: [assistant],
            streamingTurnId: nil,
            activeTurnId: nil,
            agentName: "Assistant"
        )
        #expect(!closed.contains { if case .pendingToolCall = $0.kind { return true }; return false })
    }

    @Test
    func pendingArgTicksDuringTailRefreshTheChip() {
        let memoizer = BlockMemoizer()
        let assistant = ChatTurn(role: .assistant, content: "")
        assistant.pendingToolName = "file_write"

        _ = memoizer.blocks(
            from: [assistant],
            streamingTurnId: nil,
            activeTurnId: assistant.id,
            agentName: "Assistant"
        )
        assistant.appendToolArgFragment(#"{"path":"a.txt","content":"hello"#)

        let refreshed = memoizer.blocks(
            from: [assistant],
            streamingTurnId: nil,
            activeTurnId: assistant.id,
            agentName: "Assistant"
        )
        let argSize = refreshed.compactMap { block -> Int? in
            guard case let .pendingToolCall(_, _, size) = block.kind else { return nil }
            return size
        }.first
        #expect(argSize == assistant.pendingToolArgSize)
        #expect((argSize ?? 0) > 0)
    }
}
