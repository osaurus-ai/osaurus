//
//  ClaudeCodeStreamDecoderTests.swift
//  osaurusTests
//
//  Decoder coverage against the real `claude --output-format stream-json`
//  wire shapes (captured from CLI 2.1.212). Token-free — no subprocess.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Claude Code stream decoder")
struct ClaudeCodeStreamDecoderTests {

    private func decode(_ lines: [String]) -> [ClaudeCodeStreamEvent] {
        var decoder = ClaudeCodeStreamDecoder()
        var events: [ClaudeCodeStreamEvent] = []
        for line in lines {
            events.append(contentsOf: decoder.decode(line: Data(line.utf8)))
        }
        return events
    }

    @Test func textDeltasBecomeVisibleText() {
        let events = decode([
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"h"}}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"ello"}}}"#,
        ])
        #expect(events == [.text("h"), .text("ello")])
    }

    /// The `assistant` frame repeats the whole message the deltas already
    /// carried. Emitting both would double every answer in the chat.
    @Test func assembledAssistantMessageIsDropped() {
        let events = decode([
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"hello"}}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"hello"}]}}"#,
        ])
        #expect(events == [.text("hello")])
    }

    @Test func thinkingDeltasBecomeReasoningNotText() {
        let events = decode([
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"weighing it"}}}"#
        ])
        #expect(events == [.reasoning("weighing it")])
    }

    /// `signature_delta` carries a base64 thinking signature. Treating every
    /// `content_block_delta` as prose would dump that blob into the chat.
    @Test func signatureDeltaIsDropped() {
        let events = decode([
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"EuACCokBCBAYAipA"}}}"#
        ])
        #expect(events.isEmpty)
    }

    /// `input_json_delta` carries raw tool arguments, which the sanitized
    /// trace contract says never leave the CLI.
    @Test func toolArgumentDeltasAreDropped() {
        let events = decode([
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"path\":\"/etc"}}}"#
        ])
        #expect(events.isEmpty)
    }

    @Test func toolUseStartEmitsStartedTrace() {
        let events = decode([
            #"{"type":"stream_event","event":{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_01","name":"Read","input":{}}}}"#
        ])
        guard case .toolTrace(let trace)? = events.first else {
            Issue.record("expected a tool trace, got \(events)")
            return
        }
        #expect(trace.phase == "started")
        #expect(trace.name == "Read")
        #expect(trace.callId == "toolu_01")
        #expect(trace.isError == false)
        #expect(trace.endRun == false)
    }

    /// `tool_result` carries only `tool_use_id`, so the decoder has to
    /// remember the name from the matching `tool_use` start.
    @Test func toolResultResolvesNameFromEarlierStart() {
        let events = decode([
            #"{"type":"stream_event","event":{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_01","name":"Bash","input":{}}}}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","is_error":true,"tool_use_id":"toolu_01","content":"denied"}]}}"#,
        ])
        #expect(events.count == 2)
        guard case .toolTrace(let trace) = events[1] else {
            Issue.record("expected a tool trace, got \(events[1])")
            return
        }
        #expect(trace.phase == "completed")
        #expect(trace.name == "Bash")
        #expect(trace.callId == "toolu_01")
        #expect(trace.isError)
    }

    @Test func resultFrameEmitsStatsAndEndsTheRun() {
        let events = decode([
            #"{"type":"result","subtype":"success","is_error":false,"duration_ms":2000,"stop_reason":"end_turn","usage":{"output_tokens":40}}"#
        ])
        #expect(events.count == 2)

        guard case .toolTrace(let trace) = events[0] else {
            Issue.record("expected a terminal tool trace, got \(events[0])")
            return
        }
        #expect(trace.endRun)

        guard case .stats(let tokens, let tps, let stop) = events[1] else {
            Issue.record("expected stats, got \(events[1])")
            return
        }
        #expect(tokens == 40)
        // 40 tokens over 2000 ms.
        #expect(abs(tps - 20.0) < 0.001)
        #expect(stop == "end_turn")
    }

    /// The terminal `result` frame doesn't always repeat `stop_reason`, so the
    /// decoder keeps the one `message_delta` reported.
    @Test func stopReasonFallsBackToMessageDelta() {
        let events = decode([
            #"{"type":"stream_event","event":{"type":"message_delta","delta":{"stop_reason":"max_tokens"},"usage":{"output_tokens":9}}}"#,
            #"{"type":"result","subtype":"success","is_error":false,"duration_ms":1000,"usage":{"output_tokens":9}}"#,
        ])
        guard case .stats(_, _, let stop) = events.last else {
            Issue.record("expected stats, got \(String(describing: events.last))")
            return
        }
        #expect(stop == "max_tokens")
    }

    @Test func statsPreferAPIGenerationDuration() {
        let events = decode([
            #"{"type":"result","subtype":"success","is_error":false,"duration_ms":10000,"duration_api_ms":2000,"usage":{"output_tokens":40}}"#
        ])
        guard case .stats(let tokens, let tps, _)? = events.last else {
            Issue.record("expected stats, got \(String(describing: events.last))")
            return
        }
        #expect(tokens == 40)
        #expect(abs(tps - 20.0) < 0.001)
    }

    @Test func errorResultSurfacesFailure() {
        let events = decode([
            #"{"type":"result","subtype":"error_during_execution","is_error":true,"duration_ms":10,"result":"upstream exploded","usage":{"output_tokens":0}}"#
        ])
        #expect(events.contains { if case .failure("upstream exploded") = $0 { return true } else { return false } })
    }

    @Test func rateLimitEventIsSurfaced() {
        let events = decode([
            #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed_warning","resetsAt":1785355200,"utilization":0.82}}"#
        ])
        guard case .rateLimit(let status, let utilization, let resetsAt)? = events.first else {
            Issue.record("expected a rate limit event, got \(events)")
            return
        }
        #expect(status == "allowed_warning")
        #expect(abs(utilization - 0.82) < 0.001)
        #expect(resetsAt == Date(timeIntervalSince1970: 1_785_355_200))
    }

    @Test func initFrameCapturesSessionId() {
        var decoder = ClaudeCodeStreamDecoder()
        _ = decoder.decode(
            line: Data(#"{"type":"system","subtype":"init","session_id":"abc-123","tools":[]}"#.utf8)
        )
        #expect(decoder.sessionId == "abc-123")
    }

    /// A frame from a newer CLI must not fail the user's turn.
    @Test func unknownAndMalformedLinesAreIgnored() {
        let events = decode([
            "",
            "not json at all",
            #"{"type":"some_future_frame","payload":{"a":1}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"ok"}}}"#,
        ])
        #expect(events == [.text("ok")])
    }

    /// The wire is NDJSON, so a JSON string containing a literal `\n` escape
    /// must not be mistaken for a frame boundary.
    @Test func escapedNewlinesInsideTextSurvive() {
        let events = decode([
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"line1\nline2"}}}"#
        ])
        #expect(events == [.text("line1\nline2")])
    }
}
