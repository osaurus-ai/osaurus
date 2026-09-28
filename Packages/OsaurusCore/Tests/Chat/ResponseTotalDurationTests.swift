import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct ResponseTotalDurationTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    @Test
    func statsTextLeadsWithTotalDuration() {
        let text = NativeStatsView.statsText(ttft: 0.5, tokensPerSecond: 40, tokenCount: 12, totalDuration: 80)
        #expect(text.hasPrefix("Worked for 1m20s"))
        #expect(NativeStatsView.statsText(ttft: nil, tokensPerSecond: nil, tokenCount: nil, totalDuration: 4.2) == "Worked for 4.2s")
        #expect(!NativeStatsView.statsText(ttft: 0.5, tokensPerSecond: 40, tokenCount: 12).contains("Worked for"))
    }

    @Test
    func totalSpansEveryToolCallingStepOfTheResponse() throws {
        let turns = toolLoopTurns(steps: 3)
        let blocks = ContentBlock.generateBlocks(from: turns, streamingTurnId: nil, agentName: "Assistant")
        #expect(try totalDuration(in: blocks) == 80)
    }

    @Test
    func totalEndsAtLastVisibleOutputNotStreamTermination() throws {
        let user = ChatTurn(role: .user, content: "Hi", createdAt: start)
        let reply = ChatTurn(role: .assistant, content: "Hello", createdAt: start.addingTimeInterval(1))
        reply.generationTokensPerSecond = 40
        reply.lastOutputAt = start.addingTimeInterval(11)
        // Local cache-store tail after the last token must not count.
        reply.completedAt = start.addingTimeInterval(20)
        let blocks = ContentBlock.generateBlocks(from: [user, reply], streamingTurnId: nil, agentName: "Assistant")
        #expect(try totalDuration(in: blocks) == 10)
    }

    @Test
    func totalAloneStillShowsTheStatsRow() throws {
        let user = ChatTurn(role: .user, content: "Hi", createdAt: start)
        let reply = ChatTurn(role: .assistant, content: "Hello", createdAt: start)
        reply.lastOutputAt = start.addingTimeInterval(3)
        let blocks = ContentBlock.generateBlocks(from: [user, reply], streamingTurnId: nil, agentName: "Assistant")
        #expect(try totalDuration(in: blocks) == 3)
    }

    @Test
    func noTotalWithoutAnEndTimestamp() throws {
        let user = ChatTurn(role: .user, content: "Hi", createdAt: start)
        let reply = ChatTurn(role: .assistant, content: "Hello", createdAt: start)
        reply.generationTokensPerSecond = 40
        let blocks = ContentBlock.generateBlocks(from: [user, reply], streamingTurnId: nil, agentName: "Assistant")
        #expect(try totalDuration(in: blocks) == nil)
    }

    /// The memoizer's append path regenerates only a suffix of the transcript;
    /// the response's start must still come from its first assistant step.
    @Test
    func incrementalAppendKeepsTheResponseStart() throws {
        let all = toolLoopTurns(steps: 3)
        let memoizer = BlockMemoizer()
        // user, a1, tool, a2 — then tool, a3 appended.
        _ = memoizer.blocks(from: Array(all.prefix(4)), streamingTurnId: nil, agentName: "Assistant")
        let blocks = memoizer.blocks(from: all, streamingTurnId: nil, agentName: "Assistant")
        #expect(try totalDuration(in: blocks) == 80)
        let full = ContentBlock.generateBlocks(from: all, streamingTurnId: nil, agentName: "Assistant")
        #expect(blocks == full)
    }

    /// user → (assistant, tool)×(steps-1) → final assistant; the response
    /// starts 2s after the user message and its last output lands at +80s.
    private func toolLoopTurns(steps: Int) -> [ChatTurn] {
        var turns = [ChatTurn(role: .user, content: "Do the thing", createdAt: start.addingTimeInterval(-2))]
        for step in 0 ..< steps {
            let assistant = ChatTurn(
                role: .assistant,
                content: "Step \(step)",
                createdAt: start.addingTimeInterval(Double(step) * 20)
            )
            assistant.lastOutputAt = start.addingTimeInterval(Double(step) * 20 + 5)
            assistant.generationTokensPerSecond = 40
            turns.append(assistant)
            if step < steps - 1 {
                turns.append(ChatTurn(role: .tool, content: "ok", createdAt: start.addingTimeInterval(Double(step) * 20 + 6)))
            }
        }
        turns.last?.lastOutputAt = start.addingTimeInterval(80)
        return turns
    }

    private func totalDuration(in blocks: [ContentBlock]) throws -> TimeInterval? {
        let stats = blocks.compactMap { block -> TimeInterval?? in
            guard case let .generationStats(_, _, _, _, _, _, total) = block.kind else { return nil }
            return .some(total)
        }
        #expect(stats.count == 1)
        return try #require(stats.last)
    }
}
