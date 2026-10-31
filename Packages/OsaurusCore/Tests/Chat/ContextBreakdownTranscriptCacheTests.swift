//
//  ContextBreakdownTranscriptCacheTests.swift
//  osaurusTests
//
//  `ChatSession.estimatedContextBreakdown` is evaluated inside the chat view
//  body. Re-walking every turn per render hung the main thread on long
//  conversations (APPLE-MACOS-2NW), so the transcript token totals are
//  memoized. These tests pin that the memo never goes stale: reassigning
//  `turns` AND mutating a turn in place must both refresh the estimate.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct ChatTurnTokenEstimateRevisionTests {

    @Test func tokenRelevantMutationsBumpRevision() {
        let turn = ChatTurn(role: .assistant, content: "Hello")

        var before = ChatTurn.tokenEstimateRevision
        turn.appendContent(" world")
        #expect(ChatTurn.tokenEstimateRevision != before)

        before = ChatTurn.tokenEstimateRevision
        turn.content = "Replaced"
        #expect(ChatTurn.tokenEstimateRevision != before)

        before = ChatTurn.tokenEstimateRevision
        turn.appendThinking("reasoning")
        #expect(ChatTurn.tokenEstimateRevision != before)

        before = ChatTurn.tokenEstimateRevision
        turn.thinking = "other reasoning"
        #expect(ChatTurn.tokenEstimateRevision != before)

        before = ChatTurn.tokenEstimateRevision
        turn.toolResults["call-1"] = "result"
        #expect(ChatTurn.tokenEstimateRevision != before)

        before = ChatTurn.tokenEstimateRevision
        turn.toolCalls = nil
        #expect(ChatTurn.tokenEstimateRevision != before)

        before = ChatTurn.tokenEstimateRevision
        turn.toolCallId = "call-1"
        #expect(ChatTurn.tokenEstimateRevision != before)
    }
}

@Suite(.serialized)
@MainActor
struct ContextBreakdownTranscriptCacheTests {

    private func messageTokens(_ session: ChatSession, _ id: String) -> Int {
        session.estimatedContextBreakdown.messages.first { $0.id == id }?.tokens ?? 0
    }

    @Test func matchingResultRefreshesTheCachedConversationEstimate() async throws {
        try await ChatHistoryTestStorage.run {
            let session = ChatSession()
            let assistant = ChatTurn(role: .assistant, content: "")
            assistant.toolResults["call-1"] = String(repeating: "r", count: 4000)
            let result = ChatTurn(role: .tool, content: assistant.toolResults["call-1"]!)
            session.turns = [assistant, result]
            let unmatched = messageTokens(session, "conversation")

            result.toolCallId = "call-1"
            #expect(messageTokens(session, "conversation") == unmatched - 1000)

            result.toolCallId = nil
            #expect(messageTokens(session, "conversation") == unmatched)
        }
    }

    @Test func inPlaceTurnEditsRefreshEstimate() async throws {
        try await ChatHistoryTestStorage.run {
            let session = ChatSession()
            let assistant = ChatTurn(role: .assistant, content: String(repeating: "a", count: 400))
            session.turns = [
                ChatTurn(role: .user, content: String(repeating: "u", count: 400)),
                assistant,
            ]

            let output1 = messageTokens(session, "output")
            #expect(output1 > 0)
            // Cache hit returns the same value.
            #expect(messageTokens(session, "output") == output1)

            // In-place append (no `turns` reassignment) must be reflected.
            assistant.appendContent(String(repeating: "b", count: 4000))
            let output2 = messageTokens(session, "output")
            #expect(output2 > output1)

            // Tool results count toward conversation tokens.
            let conversation1 = messageTokens(session, "conversation")
            assistant.toolResults["call-1"] = String(repeating: "r", count: 4000)
            #expect(messageTokens(session, "conversation") > conversation1)

            // Appending a turn (reassigns `turns`) must be reflected.
            let conversation2 = messageTokens(session, "conversation")
            session.turns.append(ChatTurn(role: .user, content: String(repeating: "q", count: 4000)))
            #expect(messageTokens(session, "conversation") > conversation2)

            // Clearing the transcript drops the totals.
            session.turns = []
            #expect(messageTokens(session, "output") == 0)
        }
    }
}

@MainActor
struct ToolResultBudgetTests {
    private let payload = String(repeating: "r", count: 4000)

    private func assistant(_ results: [String: String]) -> ChatTurn {
        let turn = ChatTurn(role: .assistant, content: "")
        turn.toolCalls = results.keys.sorted().map {
            ToolCall(id: $0, type: "function", function: .init(name: "read", arguments: "{}"))
        }
        turn.toolResults = results
        return turn
    }

    private func result(_ id: String?, _ content: String) -> ChatTurn {
        let turn = ChatTurn(role: .tool, content: content)
        turn.toolCallId = id
        return turn
    }

    @Test func explicitResultCountsOnceAlongsideItsDisplayMirror() {
        let turn = assistant(["a": payload])
        let explicit = result("a", payload)
        let estimate = ContextBudgetManager.estimateTokens(for: [turn, explicit])
        turn.toolResults = [:]
        #expect(estimate == ContextBudgetManager.estimateTokens(for: [turn, explicit]))
    }

    @Test func legacyResultWithoutAnExplicitTurnStillCounts() {
        let turn = assistant(["a": payload])
        let estimate = ContextBudgetManager.estimateTokens(for: [turn])
        turn.toolResults = [:]
        #expect(estimate == ContextBudgetManager.estimateTokens(for: [turn]) + 1000)
    }

    @Test func parallelResultsDeduplicateOnlyTheirOwnCallIDs() {
        let turn = assistant(["a": payload, "b": payload])
        let explicit = result("a", payload)
        let estimate = ContextBudgetManager.estimateTokens(for: [turn, explicit])
        turn.toolResults = [:]
        #expect(estimate == ContextBudgetManager.estimateTokens(for: [turn, explicit]) + 1000)
    }

    @Test func unrelatedResultCannotHideAnEqualDisplayPayload() {
        let turn = assistant(["a": payload])
        let explicit = result("b", payload)
        let estimate = ContextBudgetManager.estimateTokens(for: [turn, explicit])
        turn.toolResults = [:]
        #expect(estimate == ContextBudgetManager.estimateTokens(for: [turn, explicit]) + 1000)
    }

    @Test func reusedCallIDInAnotherBatchCannotHideALegacyResult() {
        let earlier = assistant(["a": payload])
        let later = assistant(["a": payload])
        let explicit = result("a", payload)
        #expect(ContextBudgetManager.estimateTokens(for: [earlier, later, explicit])
            == ContextBudgetManager.estimateTokens(for: [earlier])
                + ContextBudgetManager.estimateTokens(for: [later, explicit]))
    }

    @Test func missingOrEmptyResultIDCannotHideALegacyResult() {
        for id: String? in [nil, ""] {
            let turn = assistant(["": payload])
            let explicit = result(id, payload)
            let estimate = ContextBudgetManager.estimateTokens(for: [turn, explicit])
            turn.toolResults = [:]
            #expect(estimate == ContextBudgetManager.estimateTokens(for: [turn, explicit]) + 1000)
        }
    }

    @Test func interveningUserTurnEndsTheResultBatch() {
        let turn = assistant(["a": payload])
        let explicit = result("a", payload)
        let user = ChatTurn(role: .user, content: "next")
        #expect(ContextBudgetManager.estimateTokens(for: [turn, user, explicit])
            == ContextBudgetManager.estimateTokens(for: [turn])
                + ContextBudgetManager.estimateTokens(for: [user, explicit]))
    }

    @Test func displayMirrorCannotMakeASmallBatchEligibleForCompaction() {
        let text = String(repeating: "r", count: 12000)
        let turns = [ChatTurn(role: .user, content: "read"), assistant(["a": text]), result("a", text)]
        #expect(ContextCompactionService.compactionCutIndex(
            turns: turns, existingSummary: nil, afterToolBatch: true) == nil)
    }
}
