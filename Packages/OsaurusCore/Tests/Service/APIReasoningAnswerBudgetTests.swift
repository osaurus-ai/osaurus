//
//  APIReasoningAnswerBudgetTests.swift
//  osaurus
//
//  The Anarlog class of failure: an OpenAI-compatible client sends a finite
//  max_tokens and reads only `content`; a think block that spends the whole
//  cap returns an empty answer because `reasoning_content` is invisible to
//  the client. `apiReasoningAnswerBudget` reserves answer room by arming
//  vmlx's per-request reasoning ceiling for `.httpAPI` requests.
//

import Foundation
import Testing

@testable import OsaurusCore

struct APIReasoningAnswerBudgetTests {

    @Test("only the HTTP API surface arms the reserve")
    func onlyHTTPAPIArms() {
        #expect(
            MLXBatchAdapter.apiReasoningAnswerBudget(requestSource: .chatUI, maxTokens: 4096)
                == nil)
        #expect(
            MLXBatchAdapter.apiReasoningAnswerBudget(requestSource: .plugin, maxTokens: 4096)
                == nil)
        #expect(
            MLXBatchAdapter.apiReasoningAnswerBudget(requestSource: .httpAPI, maxTokens: 4096)
                != nil)
    }

    @Test("degenerate caps stay untouched")
    func tinyCapsAreInert() {
        #expect(
            MLXBatchAdapter.apiReasoningAnswerBudget(requestSource: .httpAPI, maxTokens: 128)
                == nil)
        // 129..<224 would leave under 64 tokens of ceiling — inert too.
        #expect(
            MLXBatchAdapter.apiReasoningAnswerBudget(requestSource: .httpAPI, maxTokens: 200)
                == nil)
        #expect(
            MLXBatchAdapter.apiReasoningAnswerBudget(requestSource: .httpAPI, maxTokens: 0)
                == nil)
    }

    @Test("the reserve scales: floor 160, a third in the middle, ceiling 2048")
    func reserveSizing() {
        // 300 tokens: third = 100 → floored to 160 → budget 140.
        #expect(
            MLXBatchAdapter.apiReasoningAnswerBudget(requestSource: .httpAPI, maxTokens: 300)
                == 140)
        // 512: third = 170 → budget 342. The reported summarizer shape — a
        // client cap this size previously produced content == "" whenever
        // thinking ran long.
        #expect(
            MLXBatchAdapter.apiReasoningAnswerBudget(requestSource: .httpAPI, maxTokens: 512)
                == 342)
        // 4096: third = 1365 → budget 2731.
        #expect(
            MLXBatchAdapter.apiReasoningAnswerBudget(requestSource: .httpAPI, maxTokens: 4096)
                == 2731)
        // 20000: reserve capped at 2048 → budget 17952 — deep reasoning
        // keeps almost everything, only the runaway-past-the-cap tail is cut.
        #expect(
            MLXBatchAdapter.apiReasoningAnswerBudget(requestSource: .httpAPI, maxTokens: 20000)
                == 17952)
    }

    @Test("every armed budget leaves real answer room")
    func budgetAlwaysLeavesAnswerRoom() {
        for cap in [224, 300, 512, 1024, 8192, 65536] {
            guard
                let budget = MLXBatchAdapter.apiReasoningAnswerBudget(
                    requestSource: .httpAPI, maxTokens: cap)
            else {
                Issue.record("cap \(cap) unexpectedly inert")
                continue
            }
            #expect(budget > 0)
            #expect(cap - budget >= 128, "cap \(cap): reserve \(cap - budget) too small")
        }
    }
}
