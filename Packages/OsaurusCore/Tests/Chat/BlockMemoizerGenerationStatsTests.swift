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

    private func statistics(in blocks: [ContentBlock]) throws -> (
        ttft: TimeInterval?, rate: Double?, count: Int?, unclosed: Bool, load: TimeInterval?
    ) {
        let stats = blocks.compactMap { block -> (TimeInterval?, Double?, Int?, Bool, TimeInterval?)? in
            guard case let .generationStats(ttft, rate, count, unclosed, load) = block.kind else { return nil }
            return (ttft, rate, count, unclosed, load)
        }
        return try #require(stats.first)
    }
}
