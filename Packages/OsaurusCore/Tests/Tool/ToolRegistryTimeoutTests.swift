//
//  ToolRegistryTimeoutTests.swift
//  osaurusTests
//
//  Coverage for the global per-tool wall-clock timeout added in §2.4 of
//  the inference-and-tool-calling gap audit. A misbehaving tool body
//  must surface a structured `kind: .timeout` envelope rather than
//  hanging the agent loop indefinitely.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct ToolRegistryTimeoutTests {

    /// Tool body that sleeps longer than the test timeout. Mirrors a
    /// hung subprocess / blocked network call in production. Returns a
    /// success envelope only if it somehow completes — that branch is
    /// the failure signal for the test.
    private struct SlowSleepTool: OsaurusTool {
        let name: String = "test_slow_sleep"
        let description: String = "Test fixture: sleeps 5 seconds, exceeding the test timeout."
        let parameters: JSONValue? = .object(["type": .string("object")])

        func execute(argumentsJSON: String) async throws -> String {
            try await Task.sleep(nanoseconds: 5_000_000_000)
            return ToolEnvelope.success(tool: name, text: "did not time out")
        }
    }

    /// Tool body that completes well within the test timeout. Used as a
    /// happy-path control to confirm the timeout race doesn't fire
    /// spuriously on fast tools.
    private struct FastEchoTool: OsaurusTool {
        let name: String = "test_fast_echo"
        let description: String = "Test fixture: returns immediately."
        let parameters: JSONValue? = .object(["type": .string("object")])

        func execute(argumentsJSON: String) async throws -> String {
            return ToolEnvelope.success(tool: name, text: "ok")
        }
    }

    @Test
    func slowToolReturnsTimeoutEnvelopeBeforeBudgetExpires() async throws {
        let tool = SlowSleepTool()
        let started = Date()
        let result = try await ToolRegistry.runToolBody(
            tool,
            argumentsJSON: "{}",
            timeoutSeconds: 0.5
        )
        let elapsed = Date().timeIntervalSince(started)

        // Race correctness: the envelope kind is the authoritative
        // signal that the timeout sleeper won — the body's success
        // payload is never `kind: timeout`, so this can't be a flake.
        #expect(ToolEnvelope.isError(result))
        let data = result.data(using: .utf8)!
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(parsed?["kind"] as? String == "timeout")
        #expect(parsed?["tool"] as? String == tool.name)
        #expect(parsed?["retryable"] as? Bool == true)
        // Wall-clock budget: body sleeps 5s, so anything under 4s
        // proves cancellation actually fired and we didn't accidentally
        // wait for the body to finish. Looser than the previous <1s
        // because xctest's parallel scheduler + Swift Concurrency
        // cooperative pool can add seconds of latency under load —
        // observed at ~3s under Xcode test runner vs ~0.2s on
        // `swift test`. The race is the same; only the wake-up
        // latency differs.
        #expect(elapsed < 4.0, "took \(elapsed)s — expected <4s if timeout race fired")
    }

    @Test
    func fastToolReturnsItsOwnResultBeforeTimeoutFires() async throws {
        let tool = FastEchoTool()
        let result = try await ToolRegistry.runToolBody(
            tool,
            argumentsJSON: "{}",
            timeoutSeconds: 5
        )
        // Happy path — must NOT come back as a timeout envelope.
        #expect(!ToolEnvelope.isError(result))
        // Optional sanity: pulled-out text should match the tool body.
        let payload = ToolEnvelope.successPayload(result)
        if let text = (payload as? [String: Any])?["text"] as? String {
            #expect(text == "ok")
        }
    }
}
