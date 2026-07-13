//
//  AgentStepIdempotencyFingerprintTests.swift
//  osaurusTests
//
//  Pins the body-fingerprint component of Router billing idempotency keys.
//  The agent loop's iteration counter is reused by budget-refunded
//  iterations (data-movement relief, empty-turn retries) whose request body
//  CHANGED — the fingerprint must diverge there so the key does too
//  (otherwise the Router rejects the step with 409 IDEMPOTENCY_CONFLICT),
//  while identical re-POSTs (retryWithoutCharge) must keep the same
//  fingerprint so billing dedupe still works.
//

import Foundation
import Testing

@testable import OsaurusCore

struct AgentStepIdempotencyFingerprintTests {

    private static func baseMessages() -> [ChatMessage] {
        [
            ChatMessage(role: "system", content: "You are an agent."),
            ChatMessage(role: "user", content: "refresh the github downloads"),
            ChatMessage(
                role: "assistant",
                content: "Importing now.",
                tool_calls: [
                    ToolCall(
                        id: "call_import_1",
                        type: "function",
                        function: ToolCallFunction(
                            name: "db_import",
                            arguments: #"{"table":"snapshots","path":"rows.json"}"#
                        )
                    )
                ],
                tool_call_id: nil
            ),
            ChatMessage(
                role: "tool",
                content: #"{"ok":true,"rows_imported":1262}"#,
                tool_calls: nil,
                tool_call_id: "call_import_1"
            ),
        ]
    }

    @Test func identicalMessages_produceIdenticalFingerprint() {
        let first = AgentToolLoop.stepIdempotencyFingerprint(messages: Self.baseMessages())
        let second = AgentToolLoop.stepIdempotencyFingerprint(messages: Self.baseMessages())
        #expect(first == second)
    }

    @Test func fingerprintIsShortLowercaseHex() {
        let fingerprint = AgentToolLoop.stepIdempotencyFingerprint(messages: Self.baseMessages())
        #expect(fingerprint.count == 16)
        #expect(fingerprint.allSatisfy { $0.isHexDigit && (!$0.isLetter || $0.isLowercase) })
    }

    /// The exact 409 trigger: a data-movement-refunded iteration reuses the
    /// attempt counter, but its body carries the relief notice merged into
    /// the trailing tool result. The fingerprint must diverge.
    @Test func noticeAppendedToToolResult_changesFingerprint() {
        let before = Self.baseMessages()
        let after = AgentLoopBudget.appendingTransientNotices(
            [AgentToolLoop.dataMovementReliefNotice(cap: 15)],
            to: before
        )
        #expect(
            AgentToolLoop.stepIdempotencyFingerprint(messages: before)
                != AgentToolLoop.stepIdempotencyFingerprint(messages: after)
        )
    }

    @Test func appendingToolResult_changesFingerprint() {
        var grown = Self.baseMessages()
        grown.append(
            ChatMessage(
                role: "tool",
                content: #"{"ok":true,"rows_imported":10}"#,
                tool_calls: nil,
                tool_call_id: "call_import_2"
            )
        )
        #expect(
            AgentToolLoop.stepIdempotencyFingerprint(messages: Self.baseMessages())
                != AgentToolLoop.stepIdempotencyFingerprint(messages: grown)
        )
    }

    @Test func toolCallArguments_participateInFingerprint() {
        var mutated = Self.baseMessages()
        mutated[2] = ChatMessage(
            role: "assistant",
            content: "Importing now.",
            tool_calls: [
                ToolCall(
                    id: "call_import_1",
                    type: "function",
                    function: ToolCallFunction(
                        name: "db_import",
                        arguments: #"{"table":"snapshots","path":"OTHER.json"}"#
                    )
                )
            ],
            tool_call_id: nil
        )
        #expect(
            AgentToolLoop.stepIdempotencyFingerprint(messages: Self.baseMessages())
                != AgentToolLoop.stepIdempotencyFingerprint(messages: mutated)
        )
    }

    /// Field boundaries are separator-delimited, so content can't bleed into
    /// the neighboring role/field and collide by concatenation.
    @Test func fieldBoundaries_doNotCollideByConcatenation() {
        let joined = [ChatMessage(role: "user", content: "ab")]
        let split = [ChatMessage(role: "usera", content: "b")]
        #expect(
            AgentToolLoop.stepIdempotencyFingerprint(messages: joined)
                != AgentToolLoop.stepIdempotencyFingerprint(messages: split)
        )
    }
}
