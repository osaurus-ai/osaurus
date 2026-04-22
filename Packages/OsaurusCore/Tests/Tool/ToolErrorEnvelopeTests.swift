//
//  ToolErrorEnvelopeTests.swift
//  osaurusTests
//
//  Tests the legacy ToolErrorEnvelope shim that now delegates to the new
//  ToolEnvelope wire format. The shim's API stays the same so existing
//  call sites compile; this suite verifies the JSON output matches the
//  new contract (`ok:false`, `kind`, `message`, `tool`, `retryable`).
//

import Foundation
import Testing

@testable import OsaurusCore

struct ToolErrorEnvelopeTests {

    @Test func envelopeRoundTripsThroughJSON() throws {
        let envelope = ToolErrorEnvelope(
            kind: .timeout,
            reason: "Tool did not complete within 30 seconds.",
            toolName: "my_tool"
        )
        let json = envelope.toJSONString()
        let data = json.data(using: .utf8)!
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        #expect(parsed?["ok"] as? Bool == false)
        #expect(parsed?["kind"] as? String == "timeout")
        #expect(parsed?["message"] as? String == "Tool did not complete within 30 seconds.")
        #expect(parsed?["tool"] as? String == "my_tool")
        #expect(parsed?["retryable"] as? Bool == true)
    }

    @Test func defaultRetryableMatchesKind() {
        let rejected = ToolErrorEnvelope(kind: .rejected, reason: "denied")
        #expect(rejected.retryable == false)

        let exec = ToolErrorEnvelope(kind: .executionError, reason: "boom")
        #expect(exec.retryable == true)

        let notFound = ToolErrorEnvelope(kind: .toolNotFound, reason: "no such tool")
        #expect(notFound.retryable == false)
    }

    @Test func explicitRetryableOverridesDefault() {
        let env = ToolErrorEnvelope(kind: .rejected, reason: "permission ask", retryable: true)
        #expect(env.retryable == true)
    }

    @Test func isErrorResultDetectsLegacyPrefixes() {
        #expect(ToolErrorEnvelope.isErrorResult("[REJECTED] permission denied") == true)
        #expect(ToolErrorEnvelope.isErrorResult("[TIMEOUT] timed out") == true)
        #expect(ToolErrorEnvelope.isErrorResult("ok") == false)
    }

    @Test func isErrorResultDetectsNewEnvelope() {
        let env = ToolErrorEnvelope(kind: .executionError, reason: "boom").toJSONString()
        #expect(ToolErrorEnvelope.isErrorResult(env) == true)
    }

    @Test func isErrorResultDoesNotMisidentifyOrdinaryJSON() {
        #expect(ToolErrorEnvelope.isErrorResult("{\"value\": 42}") == false)
    }

    @Test func isErrorResultDoesNotMisidentifySuccessEnvelope() {
        let success = ToolEnvelope.success(tool: "my_tool", text: "all done")
        #expect(ToolErrorEnvelope.isErrorResult(success) == false)
    }

    @Test func envelopeNeverIncludesSuggestedTools() throws {
        // Suggestions in error envelopes were causing the model to invent
        // neighbouring tool names (it treats the suggestion as proof a
        // tool exists). The envelope must carry only kind/message/retryable/
        // (tool) — no "you might mean..." list.
        let env = ToolErrorEnvelope(
            kind: .toolNotFound,
            reason: "Tool 'mystery' is not available in this session.",
            toolName: "mystery"
        )
        let json = env.toJSONString()
        let data = json.data(using: .utf8)!
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        #expect(parsed?["kind"] as? String == "tool_not_found")
        #expect(parsed?["retryable"] as? Bool == false)
        #expect(parsed?["suggested_tools"] == nil)
        let reason = parsed?["message"] as? String ?? ""
        #expect(!reason.contains("capabilities_load"))
        #expect(!reason.contains("Try:"))
    }
}
