import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct ChatTurnFinishReasonTests {
    @Test @MainActor
    func terminalStopReasonRoundTripsThroughChatTurnData() throws {
        let turn = ChatTurn(role: .assistant, content: "")
        turn.thinking = "unfinished reasoning"
        turn.generationTokenCount = 2_048
        turn.terminalStopReason = "length"

        let data = ChatTurnData(from: turn)
        let encoded = try JSONEncoder().encode(data)
        let decoded = try JSONDecoder().decode(ChatTurnData.self, from: encoded)
        let restored = ChatTurn(from: decoded)

        #expect(restored.terminalStopReason == "length")
        #expect(restored.generationTokenCount == 2_048)
        #expect(restored.thinking == "unfinished reasoning")
    }

    @Test
    func legacyTurnWithoutTerminalStopReasonStillDecodes() throws {
        let legacy = """
            {
              "id": "\(UUID().uuidString)",
              "role": "assistant",
              "content": "done",
              "attachments": [],
              "toolResults": {},
              "thinking": ""
            }
            """

        let decoded = try JSONDecoder().decode(ChatTurnData.self, from: Data(legacy.utf8))

        #expect(decoded.terminalStopReason == nil)
        #expect(decoded.content == "done")
    }
}
