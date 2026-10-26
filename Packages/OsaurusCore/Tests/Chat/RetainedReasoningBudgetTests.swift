import Foundation
import Testing

@testable import OsaurusCore

struct RetainedReasoningBudgetTests {
    @Test(arguments: [nil, ""] as [String?])
    func absentReasoningPreservesExistingVisibleAndToolEstimates(_ reasoning: String?) {
        let call = ToolCall(id: "call_1", type: "function",
            function: .init(name: "file_read", arguments: #"{"path":"a.txt"}"#))
        let plain = ChatMessage(role: "assistant", content: "done", tool_calls: [call], tool_call_id: nil)
        let value = ChatMessage(role: "assistant", content: "done", tool_calls: [call], tool_call_id: nil,
            reasoning_content: reasoning)
        #expect(ContextBudgetManager.estimateTokens(forMessage: value) == ContextBudgetManager.estimateTokens(forMessage: plain))
    }

    @Test func longReasoningAndShortAnswerRoundTripWithMixedToolHistory() throws {
        let reasoning = String(repeating: "r", count: 8_000)
        let call = ToolCall(id: "call_1", type: "function",
            function: .init(name: "file_read", arguments: #"{"path":"a.txt"}"#))
        let assistant = ChatMessage(role: "assistant", content: "done", tool_calls: [call], tool_call_id: nil,
            reasoning_content: reasoning)
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(assistant))
        #expect(decoded.reasoning_content == reasoning)
        #expect(decoded.tool_calls?.first?.function.arguments == call.function.arguments)
        let visibleAndCall = ContextBudgetManager.estimateTokens(forMessage:
            ChatMessage(role: "assistant", content: "done", tool_calls: [call], tool_call_id: nil))
        #expect(ContextBudgetManager.estimateTokens(forMessage: decoded) == visibleAndCall + 2_000)
        let history = [ChatMessage(role: "user", content: "read"), decoded,
            ChatMessage(role: "tool", content: "text", tool_calls: nil, tool_call_id: "call_1")]
        #expect(ContextBudgetManager.estimateTokens(for: history) == visibleAndCall + 2_000 + 10)
    }

    @Test func thinkingOffDoesNotDiscardActuallyForwardedPriorReasoning() throws {
        let reasoning = String(repeating: "r", count: 8_000)
        var request = ResponsesInferenceRequest(model: "reasoning-budget", input: [
            ChatMessage(role: "assistant", content: "done", tool_calls: nil, tool_call_id: nil,
                reasoning_content: reasoning)])
        request.generation.enableThinking = false
        let mapped = try ModelRuntime.mapOpenAIChatToMLX(request.input)
        try #require(mapped.count == 1)
        #expect(mapped[0].reasoningContent == reasoning)
        #expect(ContextBudgetManager.estimateTokens(for: request.input) == 2_005)
        #expect(request.generation.enableThinking == false)
    }

    @Test func nativeReasoningMirrorsAndEncryptedStateDoNotDoubleCountKnownText() {
        let reasoning = String(repeating: "r", count: 8_000)
        let opaque = String(repeating: "e", count: 16_000)
        let native: JSONValue = .object(["type": .string("reasoning"), "id": .string("rs_actual"),
            "summary": .array([.object(["type": .string("summary_text"), "text": .string(reasoning)])]),
            "encrypted_content": .string(opaque)])
        let message = ChatMessage(role: "assistant", content: "done", tool_calls: nil, tool_call_id: nil,
            reasoning_content: reasoning, reasoning_item_id: "rs_actual", reasoning_encrypted: opaque,
            responses_output_items: [native])
        let request = ResponsesInferenceRequest(model: "reasoning-budget", input: [message])
        let roundTrip = ResponsesInferenceRequest(chatCompletion: request.chatCompletionsCompatibilityRequest())
        #expect(roundTrip.input[0].responses_output_items == [native])
        #expect(roundTrip.input[0].reasoning_content == reasoning)
        #expect(roundTrip.input[0].reasoning_encrypted == opaque)
        #expect(ContextBudgetManager.estimateTokens(for: roundTrip.input) == 2_005)
        let opaqueOnly = ChatMessage(role: "assistant", content: "done", tool_calls: nil, tool_call_id: nil,
            reasoning_item_id: "rs_actual", reasoning_encrypted: opaque, responses_output_items: [native])
        #expect(ContextBudgetManager.estimateTokens(forMessage: opaqueOnly) == 5)
    }

    @Test func retainedReasoningAloneCanCrossTheExistingHistoryCompactionThreshold() {
        let manager = AgentLoopBudget.makeBudgetManager(contextWindow: 24_000,
            systemPromptChars: 1_414, toolTokens: 5_001, maxResponseTokens: nil)
        #expect(manager.historyBudget == 10_950)
        var history = [ChatMessage(role: "user", content: "task")]
        for index in 0 ..< 5 {
            let id = "call_\(index)"
            history.append(ChatMessage(role: "assistant", content: "done", tool_calls: [
                ToolCall(id: id, type: "function", function: .init(name: "file_read", arguments: "{}"))],
                tool_call_id: nil, reasoning_content: index == 0 ? String(repeating: "r", count: 48_000) : nil))
            history.append(ChatMessage(role: "tool", content: "text", tool_calls: nil, tool_call_id: id))
        }
        let control = history.map { message in
            ChatMessage(role: message.role, content: message.content,
                tool_calls: message.tool_calls, tool_call_id: message.tool_call_id)
        }
        #expect(manager.fitsInBudget(control))
        #expect(!manager.fitsInBudget(history))
        let controlWatermark = CompactionWatermark()
        _ = manager.trimMessagesReportingOverflow(control, watermark: controlWatermark)
        #expect(!controlWatermark.hasCompacted)
        let watermark = CompactionWatermark()
        let result = manager.trimMessagesReportingOverflow(history, watermark: watermark)
        #expect(watermark.hasCompacted)
        #expect(!result.overBudget)
        #expect(result.messages.first?.content == "task")
        #expect(result.messages.contains { $0.tool_call_id == "call_4" })
        #expect(history[1].reasoning_content?.count == 48_000, "Compaction must not mutate the retained source history")
    }
}
