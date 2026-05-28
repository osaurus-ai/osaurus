//
//  InboundStreamWrapperTests.swift
//  osaurus / PrivacyFilter Tests
//
//  Locks in `PrivacyFilterPipeline.wrapInboundStream` behavior across
//  the three delta kinds the provider stream interleaves:
//
//    • plain content chunks (no sentinel)
//    • reasoning deltas prefixed by `\u{FFFE}reasoning:<payload>`
//    • bookkeeping sentinels (`\u{FFFE}done:`, `\u{FFFE}stats:`)
//
//  The previous single-buffer implementation concatenated everything
//  before scanning for `[CATEGORY_N]` tokens, which (a) failed to
//  substitute placeholders that landed in reasoning text and (b)
//  corrupted the sentinel framing the chat view depends on to route
//  reasoning to the Thinking pill. The current implementation keeps a
//  per-rail buffer and is sentinel-aware.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Inbound stream wrapper (sentinel-aware)")
struct InboundStreamWrapperTests {

    private static let reasoningPrefix = "\u{FFFE}reasoning:"

    // MARK: - Helpers

    /// Drive `wrapInboundStream` with a fixed list of upstream chunks
    /// and return everything it emits, in order.
    private func collect(
        chunks: [String],
        map: RedactionMap
    ) async throws -> [String] {
        let upstream = AsyncThrowingStream<String, Error> { continuation in
            for chunk in chunks {
                continuation.yield(chunk)
            }
            continuation.finish()
        }
        let wrapped = PrivacyFilterPipeline.wrapInboundStream(upstream, map: map)
        var out: [String] = []
        for try await emitted in wrapped {
            out.append(emitted)
        }
        return out
    }

    // MARK: - Tests

    @Test func contentRail_substitutesPlaceholderInOneChunk() async throws {
        let map = RedactionMap(conversationID: UUID())
        _ = await map.intern("949-238-0232", as: .phone)
        let collected = try await collect(
            chunks: ["thanks for sharing [PHONE_1]."],
            map: map
        )
        #expect(collected.joined() == "thanks for sharing 949-238-0232.")
    }

    @Test func contentRail_substitutesAcrossSplitChunks() async throws {
        let map = RedactionMap(conversationID: UUID())
        _ = await map.intern("949-238-0232", as: .phone)
        let collected = try await collect(
            chunks: ["sharing [", "PHONE_", "1]!"],
            map: map
        )
        #expect(collected.joined() == "sharing 949-238-0232!")
    }

    @Test func reasoningRail_keepsSentinelPrefixAndUnscrubsPayload() async throws {
        // The exact bug from the field: a placeholder split across two
        // reasoning deltas previously ended up as
        //   `\u{FFFE}reasoning:[\u{FFFE}reasoning:PHONE\u{FFFE}reasoning:_1]`
        // because the single-buffer unscrubber concatenated the
        // sentinel-prefixed chunks. With per-rail buffers, both
        // fragments belong to the reasoning rail and the placeholder
        // resolves cleanly.
        let map = RedactionMap(conversationID: UUID())
        _ = await map.intern("949-238-0232", as: .phone)
        let collected = try await collect(
            chunks: [
                Self.reasoningPrefix + "user shared [",
                Self.reasoningPrefix + "PHONE_1].",
            ],
            map: map
        )
        // Each emitted reasoning delta should keep the sentinel prefix
        // so the chat view's `StreamingReasoningHint.decode` still
        // routes it to the Thinking pill.
        for delta in collected {
            #expect(delta.hasPrefix(Self.reasoningPrefix))
        }
        // Concatenating payloads should yield the original reasoning
        // text with the phone number restored.
        let payloads = collected.map {
            $0.replacingOccurrences(of: Self.reasoningPrefix, with: "")
        }
        #expect(payloads.joined() == "user shared 949-238-0232.")
    }

    @Test func interleavedReasoningAndContent_useSeparateBuffers() async throws {
        // Content rail mid-token, a reasoning delta cuts in, then
        // content resumes. The reasoning chunk must NOT poison the
        // content buffer.
        let map = RedactionMap(conversationID: UUID())
        _ = await map.intern("949-238-0232", as: .phone)
        let collected = try await collect(
            chunks: [
                "Hi [PHO",
                Self.reasoningPrefix + "thinking…",
                "NE_1]!",
            ],
            map: map
        )
        // Reasoning delta is emitted standalone with its prefix.
        #expect(collected.contains(Self.reasoningPrefix + "thinking…"))
        // Content (stripped of any reasoning deltas) is correctly
        // unscrubbed.
        let contentOnly =
            collected
            .filter { !$0.hasPrefix(Self.reasoningPrefix) }
            .joined()
        #expect(contentOnly == "Hi 949-238-0232!")
    }

    @Test func otherSentinels_passThroughUntouched() async throws {
        // Stats and done sentinels carry telemetry, not user text, so
        // the unscrubber must leave them exactly as received.
        let map = RedactionMap(conversationID: UUID())
        _ = await map.intern("949-238-0232", as: .phone)
        let stats = "\u{FFFE}stats:42;123.4"
        let done = "\u{FFFE}done:"
        let collected = try await collect(
            chunks: ["hello [PHONE_1]", stats, done],
            map: map
        )
        #expect(collected.contains(stats))
        #expect(collected.contains(done))
        let contentOnly =
            collected
            .filter { !$0.hasPrefix("\u{FFFE}") }
            .joined()
        #expect(contentOnly == "hello 949-238-0232")
    }

    @Test func nilMap_isPassThrough() async throws {
        let chunks = [
            "hi ",
            Self.reasoningPrefix + "thinking",
            "world",
            "\u{FFFE}done:",
        ]
        let upstream = AsyncThrowingStream<String, Error> { cont in
            for c in chunks { cont.yield(c) }
            cont.finish()
        }
        let wrapped = PrivacyFilterPipeline.wrapInboundStream(upstream, map: nil)
        var collected: [String] = []
        for try await c in wrapped { collected.append(c) }
        #expect(collected == chunks)
    }

    /// Covers C1: when a provider throws `ServiceToolInvocation`
    /// mid-stream, the wrapper must rewrite every `[CATEGORY_N]`
    /// placeholder back to the user's original BEFORE the local
    /// tool executor sees the args. Before C1 the local tool ran
    /// with `{"phone":"[PHONE_1]"}` and silently broke.
    @Test func toolInvocationError_unscrubsJSONArgs() async throws {
        let map = RedactionMap(conversationID: UUID())
        _ = await map.intern("949-238-0232", as: .phone)

        let upstream = AsyncThrowingStream<String, Error> { cont in
            cont.yield("partial content ")
            cont.finish(
                throwing: ServiceToolInvocation(
                    toolName: "send_sms",
                    jsonArguments: "{\"phone\":\"[PHONE_1]\"}",
                    toolCallId: "call_abc"
                )
            )
        }

        let wrapped = PrivacyFilterPipeline.wrapInboundStream(upstream, map: map)
        var collected: [String] = []
        var caught: Error?
        do {
            for try await chunk in wrapped {
                collected.append(chunk)
            }
        } catch {
            caught = error
        }

        guard let single = caught as? ServiceToolInvocation else {
            #expect(Bool(false), "Expected ServiceToolInvocation, got \(String(describing: caught))")
            return
        }
        #expect(single.toolName == "send_sms")
        #expect(single.toolCallId == "call_abc")
        #expect(single.jsonArguments.contains("949-238-0232"))
        #expect(!single.jsonArguments.contains("[PHONE_1]"))
    }

    /// Same idea as above but for the batched
    /// `ServiceToolInvocations` shape (multi-tool turn).
    @Test func batchedToolInvocationsError_unscrubsEveryArg() async throws {
        let map = RedactionMap(conversationID: UUID())
        _ = await map.intern("949-238-0232", as: .phone)
        _ = await map.intern("alice@example.com", as: .email)

        let batch = ServiceToolInvocations(invocations: [
            ServiceToolInvocation(
                toolName: "send_sms",
                jsonArguments: "{\"phone\":\"[PHONE_1]\"}",
                toolCallId: "call_a"
            ),
            ServiceToolInvocation(
                toolName: "send_email",
                jsonArguments: "{\"to\":\"[EMAIL_1]\"}",
                toolCallId: "call_b"
            ),
        ])

        let upstream = AsyncThrowingStream<String, Error> { cont in
            cont.finish(throwing: batch)
        }
        let wrapped = PrivacyFilterPipeline.wrapInboundStream(upstream, map: map)
        var caught: Error?
        do {
            for try await _ in wrapped {}
        } catch {
            caught = error
        }
        guard let group = caught as? ServiceToolInvocations else {
            #expect(Bool(false), "Expected ServiceToolInvocations")
            return
        }
        #expect(group.invocations.count == 2)
        for inv in group.invocations {
            #expect(!inv.jsonArguments.contains("[PHONE_"))
            #expect(!inv.jsonArguments.contains("[EMAIL_"))
        }
        #expect(group.invocations[0].jsonArguments.contains("949-238-0232"))
        #expect(group.invocations[1].jsonArguments.contains("alice@example.com"))
    }
}
