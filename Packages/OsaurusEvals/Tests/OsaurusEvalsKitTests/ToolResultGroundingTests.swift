//
//  ToolResultGroundingTests.swift
//  OsaurusEvalsKitTests
//
//  Model-free coverage for transcript fixtures that prove final answers are
//  grounded in tool results rather than stale prompt text or call arguments.
//

import Foundation
import OsaurusCore
import Testing

@testable import OsaurusEvalsKit

@MainActor
struct ToolResultGroundingTests {
    private typealias Grounding = EvalCase.ToolResultGroundingExpectations
    private typealias Event = EvalCase.ToolResultGroundingExpectations.Event
    private typealias Assertion = EvalCase.ToolResultGroundingExpectations.Assertion

    private static func spawnBatchEnvelope(
        aggregateStatus: String = "succeeded"
    ) -> String {
        let succeeded = aggregateStatus == "succeeded"
        let childEnvelope: [String: Any]
        if succeeded {
            childEnvelope = [
                "ok": true,
                "result": [
                    "kind": "spawn_result",
                    "model": "test/worker",
                    "summary": "WORKER_RESULT_41",
                ],
            ]
        } else {
            childEnvelope = [
                "ok": false,
                "kind": "execution_error",
                "message": "worker failed",
            ]
        }
        let result: [String: Any] = [
            "kind": "spawn_batch_result",
            "max_parallel": 1,
            "succeeded": succeeded ? 1 : 0,
            "failed": succeeded ? 0 : 1,
            "aggregate_status": aggregateStatus,
            "execution": [
                "waves": [
                    [
                        "wave": 0,
                        "remote_jobs": 1,
                        "effective_local_slots": 1,
                        "local_subwaves": [1],
                        "limited_by": [],
                    ]
                ],
                "cache": ["available": false],
            ],
            "results": [
                [
                    "id": "worker",
                    "target_type": "agent",
                    "target": "A11CE001-0000-4000-8000-000000000001",
                    "ok": succeeded,
                    "envelope": childEnvelope,
                ]
            ],
        ]
        return ToolEnvelope.success(tool: "spawn_batch", result: result)
    }

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

    @Test func sequenceContinuationAndSingleFinalContractsPass() {
        let report = score(
            Grounding(
                events: [
                    Event(
                        kind: "toolCall",
                        callId: "batch-1",
                        tool: "spawn_batch",
                        arguments: "{\"jobs\":[]}"
                    ),
                    Event(
                        kind: "toolResult",
                        callId: "batch-1",
                        tool: "spawn_batch",
                        content: "BATCH_SETTLED_17"
                    ),
                    Event(
                        kind: "toolCall",
                        callId: "write-1",
                        tool: "file_write",
                        arguments: "{\"path\":\"summary.txt\"}"
                    ),
                    Event(
                        kind: "toolResult",
                        callId: "write-1",
                        tool: "file_write",
                        content: "WRITE_COMMIT_61"
                    ),
                    Event(
                        kind: "assistant",
                        content: "BATCH_SETTLED_17; WRITE_COMMIT_61"
                    ),
                ],
                assertions: [
                    Assertion(
                        callId: "batch-1",
                        answerMustContain: ["BATCH_SETTLED_17"]
                    ),
                    Assertion(
                        callId: "write-1",
                        answerMustContain: ["WRITE_COMMIT_61"],
                        callMustFollowResultOf: "batch-1"
                    ),
                ],
                expectedToolSequence: ["spawn_batch", "file_write"],
                requireSingleFinalAssistant: true,
                requireFinalAfterAllToolResults: true,
                requireFinalIsLastEvent: true
            )
        )

        #expect(report.outcome == .passed, "notes: \(report.notes)")
    }

    @Test func exactSequenceRejectsDuplicateContinuation() {
        let report = score(
            Grounding(
                events: [
                    Event(kind: "toolCall", callId: "batch-1", tool: "spawn_batch"),
                    Event(kind: "toolResult", callId: "batch-1", content: "settled"),
                    Event(kind: "toolCall", callId: "write-1", tool: "file_write"),
                    Event(kind: "toolResult", callId: "write-1", content: "written"),
                    Event(kind: "toolCall", callId: "write-2", tool: "file_write"),
                    Event(kind: "toolResult", callId: "write-2", content: "written again"),
                    Event(kind: "assistant", content: "done"),
                ],
                assertions: [],
                expectedToolSequence: ["spawn_batch", "file_write"],
                requireSingleFinalAssistant: true,
                requireFinalAfterAllToolResults: true,
                requireFinalIsLastEvent: true
            )
        )

        #expect(report.outcome == .failed)
        #expect(report.notes.contains { $0.contains("tool sequence") })
    }

    @Test func continuationBeforeNamedResultFails() {
        let report = score(
            Grounding(
                events: [
                    Event(kind: "toolCall", callId: "batch-1", tool: "spawn_batch"),
                    Event(kind: "toolCall", callId: "write-1", tool: "file_write"),
                    Event(kind: "toolResult", callId: "batch-1", content: "settled"),
                    Event(kind: "toolResult", callId: "write-1", content: "written"),
                    Event(kind: "assistant", content: "done"),
                ],
                assertions: [
                    Assertion(
                        callId: "write-1",
                        callMustFollowResultOf: "batch-1"
                    )
                ]
            )
        )

        #expect(report.outcome == .failed)
        #expect(report.notes.contains { $0.contains("did not follow result") })
    }

    @Test func duplicateFinalAndPostFinalActivityFail() {
        let report = score(
            Grounding(
                events: [
                    Event(kind: "toolCall", callId: "batch-1", tool: "spawn_batch"),
                    Event(kind: "toolResult", callId: "batch-1", content: "settled"),
                    Event(kind: "assistant", content: "first final"),
                    Event(kind: "assistant", content: "second final"),
                    Event(kind: "toolCall", callId: "reopened", tool: "todo"),
                    Event(kind: "toolResult", callId: "reopened", content: "reopened"),
                ],
                assertions: [],
                requireSingleFinalAssistant: true,
                requireFinalAfterAllToolResults: true,
                requireFinalIsLastEvent: true
            )
        )

        #expect(report.outcome == .failed)
        #expect(report.notes.contains { $0.contains("assistant final count") })
        #expect(report.notes.contains { $0.contains("before tool result") })
        #expect(report.notes.contains { $0.contains("was not the last event") })
    }

    @Test func structuredSpawnBatchContractPassesAndCatchesAggregateDrift() {
        let assertion = EvalCase.AgentLoopExpectations.SpawnBatchAssertion(
            exactCallCount: 1,
            expectedJobIds: ["worker"],
            expectedSucceeded: 1,
            expectedFailed: 0,
            expectedMaxParallel: 1,
            requireEveryRowSettled: true,
            requireReportedCountsMatchRows: true,
            expectedAggregateStatus: "succeeded",
            requireEveryExecutionWaveWellFormed: true,
            expectedCacheAvailable: false,
            expectedRows: [
                .init(
                    id: "worker",
                    targetType: "agent",
                    target: "A11CE001-0000-4000-8000-000000000001",
                    ok: true,
                    model: "test/worker",
                    summaryContains: ["WORKER_RESULT_41"]
                )
            ]
        )
        let events = [
            Event(kind: "toolCall", callId: "batch-1", tool: "spawn_batch"),
            Event(
                kind: "toolResult",
                callId: "batch-1",
                tool: "spawn_batch",
                content: Self.spawnBatchEnvelope()
            ),
            Event(kind: "assistant", content: "WORKER_RESULT_41"),
        ]
        let passing = score(
            Grounding(
                events: events,
                assertions: [],
                expectedToolSequence: ["spawn_batch"],
                requireSingleFinalAssistant: true,
                requireFinalAfterAllToolResults: true,
                requireFinalIsLastEvent: true,
                spawnBatch: assertion
            )
        )
        #expect(passing.outcome == .passed, "notes: \(passing.notes)")
        #expect(passing.notes.contains { $0.contains("aggregateStatus") })

        let drift = score(
            Grounding(
                events: [
                    events[0],
                    Event(
                        kind: "toolResult",
                        callId: "batch-1",
                        tool: "spawn_batch",
                        content: Self.spawnBatchEnvelope(
                            aggregateStatus: "all_failed"
                        )
                    ),
                    events[2],
                ],
                assertions: [],
                spawnBatch: assertion
            )
        )
        #expect(drift.outcome == .failed)
        #expect(drift.notes.contains { $0.contains("aggregate_status") })
    }

    @Test func suiteDecodesAndPasses() throws {
        let suiteDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // OsaurusEvalsKitTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // OsaurusEvals
            .appendingPathComponent("Suites/ToolResultGrounding", isDirectory: true)

        let suite = try EvalSuite.load(from: suiteDir)
        #expect(suite.decodeFailures.isEmpty, "decode failures: \(suite.decodeFailures)")
        let requiredSpawnBatchCases: Set<String> = [
            "tool_result_grounding.spawn-batch-partial-failure-parent-continuation",
            "tool_result_grounding.spawn-batch-second-tool-then-final",
            "tool_result_grounding.spawn-batch-pending-todo-finalizes-once",
            "tool_result_grounding.spawn-batch-all-cancelled-finalizes-once",
        ]
        #expect(
            requiredSpawnBatchCases.isSubset(of: Set(suite.cases.map(\.id))),
            "missing required spawn_batch transcript fixture"
        )
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
