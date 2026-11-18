//
//  SubagentErrorDescriptionTests.swift
//  osaurusTests
//
//  A subagent failure reads as its own message wherever it is shown, not
//  as "The operation couldn't be completed. (OsaurusCore.SubagentError
//  error 2.)".
//

import Foundation
import Testing

@testable import OsaurusCore

struct SubagentErrorDescriptionTests {
    @Test func everyCase_describesItselfWithItsMessage() {
        let cases: [SubagentError] = [
            .denied("a"), .userDenied("b"), .unavailable("c"), .invalidArgs(message: "d", field: "f"),
            .timedOut("e"), .iterationCap("g"), .toolRejected("h"), .overBudget("i"), .emptyExhausted("j"),
            .executionFailed(message: "k", retryable: false),
        ]
        #expect(cases.map(\.localizedDescription) == ["a", "b", "c", "d", "e", "g", "h", "i", "j", "k"])
    }

    @Test func workflowAttemptLog_quotesTheMessage() {
        let error: Error = SubagentError.unavailable("Qwen-Image-2.1 waited for local work to finish: Write the persona")
        #expect(error.localizedDescription.hasSuffix("finish: Write the persona"))
        #expect(!error.localizedDescription.contains("SubagentError"))
    }
}
