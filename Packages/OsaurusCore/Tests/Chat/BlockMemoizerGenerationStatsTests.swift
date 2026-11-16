import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct BlockMemoizerGenerationStatsTests {
    @Test
    func finalStatisticsReplaceRollingEstimateWithoutAnotherContentDelta() throws {
        let turn = ChatTurn(role: .assistant, content: "A completed answer.")
        let memoizer = BlockMemoizer()
        turn.generationTokensPerSecond = 54.1
        let before = memoizer.blocks(from: [turn], streamingTurnId: nil, agentName: "Assistant")
        #expect(try statistics(in: before).rate == 54.1)

        turn.generationTokensPerSecond = 35.7
        turn.generationTokenCount = 28
        turn.timeToFirstToken = 0.3
        turn.modelLoadSeconds = 4.2
        turn.unclosedReasoning = true
        let after = memoizer.blocks(from: [turn], streamingTurnId: nil, agentName: "Assistant")
        let stats = try statistics(in: after)
        #expect(stats.rate == 35.7)
        #expect(stats.count == 28)
        #expect(stats.ttft == 0.3)
        #expect(stats.load == 4.2)
        #expect(stats.unclosed)
        // Identical calls still return identical blocks after the refresh.
        #expect(memoizer.blocks(from: [turn], streamingTurnId: nil, agentName: "Assistant") == after)
    }

    @Test
    func lateStatisticsCreateFooterAndClearDoesNotRetainThem() throws {
        let turn = ChatTurn(role: .assistant, content: "A completed answer.")
        let memoizer = BlockMemoizer()
        let before = memoizer.blocks(from: [turn], streamingTurnId: nil, agentName: "Assistant")
        #expect(
            !before.contains {
                if case .generationStats = $0.kind { return true }; return false
            }
        )

        turn.generationTokensPerSecond = 42
        let after = memoizer.blocks(from: [turn], streamingTurnId: nil, agentName: "Assistant")
        #expect(try statistics(in: after).rate == 42)

        memoizer.clear()
        turn.generationTokensPerSecond = nil
        #expect(memoizer.blocks(from: [turn], streamingTurnId: nil, agentName: "Assistant") == before)
    }

    @Test
    func imageProgressReplacementsRefreshAtEveryStep() {
        let turn = ChatTurn(role: .assistant, content: "")
        let memoizer = BlockMemoizer()
        for step in 1 ... 16 {
            let status = "Generating image… \(step)/16"
            turn.content = status
            let blocks = memoizer.blocks(
                from: [turn], streamingTurnId: turn.id, activeTurnId: turn.id,
                agentName: "Assistant"
            )
            #expect(blocks.contains {
                if case let .paragraph(_, text, _, _) = $0.kind { return text == status }
                return false
            })
            #expect(memoizer.blocks(
                from: [turn], streamingTurnId: turn.id, activeTurnId: turn.id,
                agentName: "Assistant"
            ) == blocks)
        }
    }

    @Test
    func sameLengthReplacementAndAppendRefreshWithoutChangingTurnIdentity() {
        let turn = ChatTurn(role: .assistant, content: "blue")
        let memoizer = BlockMemoizer()
        _ = memoizer.blocks(from: [turn], streamingTurnId: turn.id, agentName: "Assistant")
        turn.content = "gold"
        turn.appendContent("!")
        for expected in ["gold!", "green"] {
            turn.content = expected
            let blocks = memoizer.blocks(from: [turn], streamingTurnId: turn.id, agentName: "Assistant")
            #expect(blocks.contains {
                if case let .paragraph(_, text, _, _) = $0.kind { return text == expected }
                return false
            })
        }
    }

    private func statistics(in blocks: [ContentBlock]) throws -> (
        ttft: TimeInterval?, rate: Double?, count: Int?, unclosed: Bool, load: TimeInterval?
    ) {
        let stats = blocks.compactMap { block -> (TimeInterval?, Double?, Int?, Bool, TimeInterval?)? in
            guard case let .generationStats(ttft, rate, count, unclosed, load, _, _) = block.kind else { return nil }
            return (ttft, rate, count, unclosed, load)
        }
        return try #require(stats.first)
    }
}
