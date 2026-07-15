//
//  ToolResultGroundingTests.swift
//  OsaurusEvalsKitTests
//
//  Model-free coverage for transcript fixtures that prove final answers are
//  grounded in tool results rather than stale prompt text or call arguments.
//

import Foundation
import Testing

@testable import OsaurusEvalsKit

@MainActor
struct ToolResultGroundingTests {
    private typealias Grounding = EvalCase.ToolResultGroundingExpectations
    private typealias Event = EvalCase.ToolResultGroundingExpectations.Event
    private typealias Assertion = EvalCase.ToolResultGroundingExpectations.Assertion

    @Test func groundedTranscriptPasses() {
        let report = score(
            Grounding(
                events: [
                    Event(kind: "toolCall", callId: "call-1", tool: "file_read", arguments: "{\"path\":\"state.txt\"}"),
                    Event(kind: "toolResult", callId: "call-1", tool: "file_read", content: "state: ready-9\n"),
                    Event(kind: "assistant", content: "The current state is ready-9."),
                ],
                assertions: [
                    Assertion(
                        callId: "call-1",
                        answerMustContain: ["ready-9"],
                        resultMustContain: ["state: ready-9"],
                        argumentsMustNotContain: ["ready-9"]
                    )
                ]
            )
        )

        #expect(report.outcome == .passed, "notes: \(report.notes)")
    }

    @Test func staleFinalAnswerFails() {
        let report = score(
            Grounding(
                events: [
                    Event(kind: "toolCall", callId: "call-1", tool: "file_read", arguments: "{\"path\":\"state.txt\"}"),
                    Event(kind: "toolResult", callId: "call-1", tool: "file_read", content: "state: ready-9\n"),
                    Event(kind: "assistant", content: "The current state is stale-4."),
                ],
                assertions: [
                    Assertion(
                        callId: "call-1",
                        answerMustContain: ["ready-9"],
                        answerMustNotContain: ["stale-4"],
                        resultMustContain: ["state: ready-9"]
                    )
                ]
            )
        )

        #expect(report.outcome == .failed)
        #expect(report.notes.contains { $0.contains("missing required fragment") })
        #expect(report.notes.contains { $0.contains("forbidden fragment") })
    }

    @Test func answerFragmentCopiedFromArgumentsFails() {
        let report = score(
            Grounding(
                events: [
                    Event(
                        kind: "toolCall",
                        callId: "call-1",
                        tool: "file_read",
                        arguments: "{\"path\":\"state.txt\",\"expected\":\"ready-9\"}"
                    ),
                    Event(kind: "toolResult", callId: "call-1", tool: "file_read", content: "state: ready-9\n"),
                    Event(kind: "assistant", content: "The current state is ready-9."),
                ],
                assertions: [
                    Assertion(callId: "call-1", answerMustContain: ["ready-9"])
                ]
            )
        )

        #expect(report.outcome == .failed)
        #expect(report.notes.contains { $0.contains("already present in tool call") })
    }

    @Test func unmatchedToolResultFails() {
        let report = score(
            Grounding(
                events: [
                    Event(kind: "toolResult", callId: "call-1", tool: "file_read", content: "state: ready-9\n"),
                    Event(kind: "assistant", content: "The current state is ready-9."),
                ],
                assertions: [
                    Assertion(callId: "call-1", answerMustContain: ["ready-9"])
                ]
            )
        )

        #expect(report.outcome == .failed)
        #expect(report.notes.contains { $0.contains("no prior matching tool call") })
    }

    @Test func finalBeforeResultFails() {
        let report = score(
            Grounding(
                events: [
                    Event(kind: "assistant", content: "The current state is ready-9."),
                    Event(kind: "toolCall", callId: "call-1", tool: "file_read", arguments: "{\"path\":\"state.txt\"}"),
                    Event(kind: "toolResult", callId: "call-1", tool: "file_read", content: "state: ready-9\n"),
                ],
                assertions: [
                    Assertion(callId: "call-1", answerMustContain: ["ready-9"])
                ]
            )
        )

        #expect(report.outcome == .failed)
        #expect(report.notes.contains { $0.contains("before any tool result") })
    }

    @Test func assertedResultAfterFinalFails() {
        let report = score(
            Grounding(
                events: [
                    Event(kind: "toolCall", callId: "older", tool: "file_read", arguments: "{\"path\":\"old.txt\"}"),
                    Event(kind: "toolResult", callId: "older", tool: "file_read", content: "state: old-1\n"),
                    Event(kind: "assistant", content: "The current state is ready-9."),
                    Event(kind: "toolCall", callId: "call-1", tool: "file_read", arguments: "{\"path\":\"state.txt\"}"),
                    Event(kind: "toolResult", callId: "call-1", tool: "file_read", content: "state: ready-9\n"),
                ],
                assertions: [
                    Assertion(callId: "call-1", answerMustContain: ["ready-9"])
                ]
            )
        )

        #expect(report.outcome == .failed)
        #expect(report.notes.contains { $0.contains("appears after the final answer") })
    }

    @Test func resultBeforeCallFails() {
        let report = score(
            Grounding(
                events: [
                    Event(kind: "toolResult", callId: "call-1", tool: "file_read", content: "state: ready-9\n"),
                    Event(kind: "toolCall", callId: "call-1", tool: "file_read", arguments: "{\"path\":\"state.txt\"}"),
                    Event(kind: "assistant", content: "The current state is ready-9."),
                ],
                assertions: [
                    Assertion(callId: "call-1", answerMustContain: ["ready-9"])
                ]
            )
        )

        #expect(report.outcome == .failed)
        #expect(report.notes.contains { $0.contains("appears before its matching tool call") })
    }

    @Test func malformedEventErrors() {
        let report = score(
            Grounding(
                events: [
                    Event(kind: "toolCall", callId: nil, tool: "file_read"),
                    Event(kind: "assistant", content: "No result."),
                ],
                assertions: []
            )
        )

        #expect(report.outcome == .errored)
        #expect(report.notes.contains { $0.contains("toolCall needs") })
    }

    @Test func duplicateCallIdErrors() {
        let report = score(
            Grounding(
                events: [
                    Event(kind: "toolCall", callId: "call-1", tool: "file_read"),
                    Event(kind: "toolCall", callId: "call-1", tool: "file_read"),
                    Event(kind: "assistant", content: "No result."),
                ],
                assertions: []
            )
        )

        #expect(report.outcome == .errored)
        #expect(report.notes.contains { $0.contains("duplicates toolCall id") })
    }

    @Test func suiteDecodesAndPasses() throws {
        let suiteDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // OsaurusEvalsKitTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // OsaurusEvals
            .appendingPathComponent("Suites/ToolResultGrounding", isDirectory: true)

        let suite = try EvalSuite.load(from: suiteDir)
        #expect(suite.decodeFailures.isEmpty, "decode failures: \(suite.decodeFailures)")
        // Floor, not exact: new cases must not break this smoke.
        #expect(suite.cases.count >= 2, "ToolResultGrounding suite shrank; got \(suite.cases.count)")
        for testCase in suite.cases {
            #expect(testCase.domain == "tool_result_grounding")
            let report = EvalRunner.runToolResultGroundingCase(testCase, modelId: "fixture")
            #expect(report.outcome == .passed, "\(testCase.id) notes: \(report.notes)")
        }
    }

    private func score(_ expectation: Grounding) -> EvalCaseReport {
        let testCase = EvalCase(
            id: "tool_result_grounding.test",
            domain: "tool_result_grounding",
            query: "q",
            fixtures: .init(),
            expect: .init(toolResultGrounding: expectation)
        )
        return EvalRunner.runToolResultGroundingCase(testCase, modelId: "fixture")
    }
}
