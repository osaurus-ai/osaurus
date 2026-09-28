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
        #expect(try totalDuration(in: blocks) == 81)
    }

    /// Enter → run end: the pre-send warm-up before the assistant turn exists
    /// and the local cache-store tail after the last token both count.
    @Test
    func totalRunsFromKeypressToRunEnd() throws {
        let user = ChatTurn(role: .user, content: "Hi", createdAt: start)
        let reply = ChatTurn(role: .assistant, content: "Hello", createdAt: start.addingTimeInterval(9))
        reply.requestedAt = start  // model load happened before the turn was created
        reply.generationTokensPerSecond = 40
        reply.lastOutputAt = start.addingTimeInterval(11)
        reply.completedAt = start.addingTimeInterval(20)
        let blocks = ContentBlock.generateBlocks(from: [user, reply], streamingTurnId: nil, agentName: "Assistant")
        #expect(try totalDuration(in: blocks) == 20)
    }

    /// While the run is open (engine tail after the output completed) the
    /// chip is withheld so it lands once with the final number.
    @Test
    func totalWithheldWhileTheRunIsOpen() throws {
        let user = ChatTurn(role: .user, content: "Hi", createdAt: start)
        let reply = ChatTurn(role: .assistant, content: "Hello", createdAt: start)
        reply.generationTokensPerSecond = 40
        reply.lastOutputAt = start.addingTimeInterval(5)
        reply.completedAt = start.addingTimeInterval(5)
        let open = ContentBlock.generateBlocks(
            from: [user, reply], streamingTurnId: nil, activeTurnId: reply.id, agentName: "Assistant")
        #expect(try totalDuration(in: open) == nil)
        let closed = ContentBlock.generateBlocks(from: [user, reply], streamingTurnId: nil, agentName: "Assistant")
        #expect(try totalDuration(in: closed) == 5)
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

    @Test
    func requestedAtSurvivesTheTurnDataRoundTrip() throws {
        let turn = ChatTurn(role: .assistant, content: "Done")
        turn.requestedAt = start
        let data = try JSONDecoder().decode(ChatTurnData.self, from: JSONEncoder().encode(ChatTurnData(from: turn)))
        #expect(data.requestedAt == start)
        #expect(ChatTurn(from: data).requestedAt == start)
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
        #expect(try totalDuration(in: blocks) == 81)
        let full = ContentBlock.generateBlocks(from: all, streamingTurnId: nil, agentName: "Assistant")
        #expect(blocks == full)
    }

    /// user → (assistant, tool)×(steps-1) → final assistant.
    /// Enter at -1s, first assistant step created at 0s, last output at +80s.
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
            if step == 0 { assistant.requestedAt = start.addingTimeInterval(-1) }
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
