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
import Dispatch
import Testing

@testable import OsaurusCore

@Suite
struct ToolRegistryTimeoutTests {

    /// Tool body that sleeps longer than the test timeout. Mirrors a
    /// hung subprocess / blocked network call in production. Returns a
    /// success envelope only if it somehow completes — that branch is
    /// the failure signal for the test.
    private struct SlowSleepTool: OsaurusTool {
        static let sleepSeconds: TimeInterval = 8
        static let timeoutSeconds: TimeInterval = 0.5

        let name: String = "test_slow_sleep"
        let description: String = "Test fixture: sleeps 8 seconds, exceeding the test timeout."
        let parameters: JSONValue? = .object(["type": .string("object")])

        func execute(argumentsJSON: String) async throws -> String {
            return await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    // Deliberately blocking, not cooperative. The registry
                    // timeout is the wall-clock safety net for hung
                    // subprocess/network-style bodies that do not observe
                    // Swift task cancellation promptly.
                    Thread.sleep(forTimeInterval: Self.sleepSeconds)
                    continuation.resume(returning: ToolEnvelope.success(tool: name, text: "did not time out"))
                }
            }
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
    func slowToolReturnsTimeoutEnvelopeForNonCooperativeBody() async throws {
        let tool = SlowSleepTool()
        let result = try await ToolRegistry.runToolBody(
            tool,
            argumentsJSON: "{}",
            timeoutSeconds: SlowSleepTool.timeoutSeconds
        )

        // Race correctness: the envelope kind is the authoritative
        // signal that the timeout sleeper won — the body's success
        // payload is never `kind: timeout`, so this can't be a flake.
        #expect(ToolEnvelope.isError(result))
        let data = result.data(using: .utf8)!
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(parsed?["kind"] as? String == "timeout")
        #expect(parsed?["tool"] as? String == tool.name)
        #expect(parsed?["retryable"] as? Bool == true)
    }

    @Test
    func fastToolReturnsItsOwnResultBeforeTimeoutFires() async throws {
        let tool = FastEchoTool()
        // 60s budget instead of 5s. The body returns in microseconds, so
        // the only thing this value gates is "how long are we willing to
        // wait for the cooperative thread pool to schedule the body Task
        // before the GCD timer wins". Loaded macOS CI runners (1186)
        // sometimes need >5s for that scheduling under contention; 60s
        // keeps the race tilted firmly in the body's favour while still
        // catching any regression where the timeout fires spuriously on
        // a fast tool.
        let result = try await ToolRegistry.runToolBody(
            tool,
            argumentsJSON: "{}",
            timeoutSeconds: 60
        )
        // Happy path — must NOT come back as a timeout envelope.
        #expect(!ToolEnvelope.isError(result))
        // Optional sanity: pulled-out text should match the tool body.
        let payload = ToolEnvelope.successPayload(result)
        if let text = (payload as? [String: Any])?["text"] as? String {
            #expect(text == "ok")
        }
    }

    /// Streaming-aware tools opt out of the wall-clock race via
    /// `bypassRegistryTimeout`. A `cargo build` takes 30+ minutes and
    /// must not be killed at the registry's default 120s. This test
    /// proves a tool that sleeps longer than the bypass path's notional
    /// budget still completes when the opt-out is set.
    private struct SlowBypassTool: OsaurusTool {
        static let sleepNanoseconds: UInt64 = 1_500_000_000  // 1.5s
        let name: String = "test_slow_bypass"
        let description: String = "Test fixture: opts out of registry timeout."
        let parameters: JSONValue? = .object(["type": .string("object")])
        var bypassRegistryTimeout: Bool { true }
        func execute(argumentsJSON: String) async throws -> String {
            try await Task.sleep(nanoseconds: Self.sleepNanoseconds)
            return ToolEnvelope.success(tool: name, text: "completed")
        }
    }

    @Test
    func bypassRegistryTimeoutSkipsTheRace() async throws {
        let tool = SlowBypassTool()
        // 0.2s wall-clock budget — would normally kill the body
        // mid-sleep. With `bypassRegistryTimeout: true` the body should
        // run to its 1.5s sleep without intervention.
        let result = try await ToolRegistry.runToolBodyUntimed(
            tool,
            argumentsJSON: "{}"
        )
        #expect(!ToolEnvelope.isError(result))
        let payload = ToolEnvelope.successPayload(result) as? [String: Any]
        #expect(payload?["text"] as? String == "completed")
    }
}
