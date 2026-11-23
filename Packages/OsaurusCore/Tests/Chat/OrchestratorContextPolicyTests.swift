//
//  OrchestratorContextPolicyTests.swift
//  OsaurusCoreTests
//
//  The Orchestrator's bounded context: system prompt, at most three earlier
//  exchanges, and the current exchange, under min(8k, 25% of the window).
//  Older exchanges are dropped, never summarized.
//

import Foundation
import Testing

@testable import OsaurusCore

struct OrchestratorContextPolicyTests {

    private static let filler = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 12)

    /// One exchange: the user asks, the assistant hands off, the tool
    /// answers, the assistant presents.
    private static func exchange(_ n: Int) -> [ChatMessage] {
        let callId = "call_\(n)"
        return [
            ChatMessage(role: "user", content: "Request \(n). \(filler)"),
            ChatMessage(
                role: "assistant", content: nil,
                tool_calls: [
                    ToolCall(
                        id: callId, type: "function",
                        function: ToolCallFunction(name: "configurator_handoff", arguments: #"{"brief":"x"}"#))
                ],
                tool_call_id: nil),
            ChatMessage(role: "tool", content: "Result \(n). \(filler)", tool_calls: nil, tool_call_id: callId),
            ChatMessage(role: "assistant", content: "Answer \(n). \(filler)"),
        ]
    }

    private static func conversation(turns: Int) -> [ChatMessage] {
        [ChatMessage(role: "system", content: "You are the Orchestrator.")]
            + (1...turns).flatMap(exchange)
    }

    @Test
    func ceilingIsTheSmallerOfEightKAndAQuarterOfTheWindow() {
        #expect(OrchestratorContextPolicy.ceiling(contextWindow: 8192) == 2048)
        #expect(OrchestratorContextPolicy.ceiling(contextWindow: 32_000) == 8000)
        #expect(OrchestratorContextPolicy.ceiling(contextWindow: 200_000) == 8000)
        #expect(OrchestratorContextPolicy.ceiling(contextWindow: 0) == 0)
    }

    /// Forty turns in, the prompt is still the system message, three earlier
    /// exchanges, and the current one, and it fits the ceiling.
    @Test(arguments: [32_768, 131_072])
    func fortyTurnsStayUnderBudget(contextWindow: Int) {
        let messages = Self.conversation(turns: 40)
        let kept = OrchestratorContextPolicy.apply(messages, contextWindow: contextWindow)
        let ceiling = OrchestratorContextPolicy.ceiling(contextWindow: contextWindow)
        #expect(ContextBudgetManager.estimateTokens(for: kept) <= ceiling)
        #expect(ContextBudgetManager.estimateTokens(for: messages) > ceiling)
        #expect(kept.first?.role == "system")
        let users = kept.filter { $0.role == "user" }.compactMap(\.content)
        #expect(users.count == OrchestratorContextPolicy.keptExchanges + 1)
        #expect(users.last?.hasPrefix("Request 40.") == true)
        #expect(users.first?.hasPrefix("Request 37.") == true)
        #expect(!kept.contains { ($0.content ?? "").contains("summary") })
    }

    /// A small window drops earlier exchanges oldest-first, but never the
    /// current one.
    @Test
    func tightWindowDropsOldestFirstAndKeepsTheCurrentExchange() {
        let messages = Self.conversation(turns: 10)
        let kept = OrchestratorContextPolicy.apply(messages, contextWindow: 2_400)
        let users = kept.filter { $0.role == "user" }.compactMap(\.content)
        #expect(users.last?.hasPrefix("Request 10.") == true)
        #expect(users.count < OrchestratorContextPolicy.keptExchanges + 1)
        let tiny = OrchestratorContextPolicy.apply(messages, contextWindow: 16)
        #expect(tiny.filter { $0.role == "user" }.count == 1)
        #expect(tiny.last?.content?.hasPrefix("Answer 10.") == true)
    }

    /// Exchanges are cut on user messages, so a tool result never loses
    /// the assistant call it answers.
    @Test
    func everyKeptToolResultKeepsItsCall() {
        let kept = OrchestratorContextPolicy.apply(Self.conversation(turns: 12), contextWindow: 32_768)
        let callIds = Set(kept.flatMap { $0.tool_calls ?? [] }.map(\.id))
        for message in kept where message.role == "tool" {
            #expect(message.tool_call_id.map(callIds.contains) == true)
        }
    }

    @Test
    func shortConversationIsUntouched() {
        let messages = Self.conversation(turns: 2)
        let kept = OrchestratorContextPolicy.apply(messages, contextWindow: 131_072)
        #expect(kept.count == messages.count)
        let noUser = [ChatMessage(role: "system", content: "s")]
        #expect(OrchestratorContextPolicy.apply(noUser, contextWindow: 10).count == 1)
    }
}
