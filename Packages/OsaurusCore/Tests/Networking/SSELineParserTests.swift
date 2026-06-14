//
//  SSELineParserTests.swift
//  osaurusTests
//
//  Regression tests for the SSE line splitter and field parser used by
//  RemoteProviderService. The previous implementation split on Swift's
//  Character.isNewline (which matches U+2028/U+2029/NEL/VT/FF in addition
//  to LF/CR), and only stripped "data: " with a literal space. Both bugs
//  caused streamed tool-call JSON from providers like Venice to be cut in
//  half and silently discarded as parse failures. These tests lock in the
//  spec-correct behaviour.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct SSELineParserTests {

    // MARK: - SSELineParser

    @Test func splitter_splitsOnLF() {
        var parser = RemoteProviderService.SSELineParser()
        parser.append(Data("data: a\ndata: b\n\n".utf8))
        let lines = drain(&parser)
        #expect(lines == ["data: a", "data: b", ""])
    }

    @Test func splitter_splitsOnLoneCR() {
        var parser = RemoteProviderService.SSELineParser()
        parser.append(Data("data: a\rdata: b\r\r".utf8))
        let lines = drain(&parser)
        #expect(lines == ["data: a", "data: b", ""])
    }

    @Test func splitter_treatsCRLFAsSingleTerminator() {
        // The previous implementation saw `\r` then `\n` as two separate
        // newlines and would dispatch a (premature) blank-line event after
        // every CRLF. That broke any provider sending CRLF-terminated multi-
        // line `data:` events.
        var parser = RemoteProviderService.SSELineParser()
        parser.append(Data("data: a\r\ndata: b\r\n\r\n".utf8))
        let lines = drain(&parser)
        #expect(lines == ["data: a", "data: b", ""])
    }

    @Test func splitter_handlesCRLFSplitAcrossChunks() {
        // CR arrives in one chunk, LF arrives in the next. Must still be
        // collapsed into a single terminator.
        var parser = RemoteProviderService.SSELineParser()
        parser.append(Data("data: a\r".utf8))
        parser.append(Data("\ndata: b\n".utf8))
        let lines = drain(&parser)
        #expect(lines == ["data: a", "data: b"])
    }

    @Test func splitter_doesNotSplitOnUnicodeLineSeparators() {
        // U+2028 (LS), U+2029 (PS), U+0085 (NEL), U+000B (VT), U+000C (FF)
        // can all appear unescaped in JSON string values. Character.isNewline
        // matches them — the byte-level splitter must not.
        let payload = "data: {\"text\":\"a\u{2028}b\u{2029}c\u{0085}d\u{000B}e\u{000C}f\"}\n\n"
        var parser = RemoteProviderService.SSELineParser()
        parser.append(Data(payload.utf8))
        let lines = drain(&parser).map { String(decoding: Data($0.utf8), as: UTF8.self) }
        #expect(lines.count == 2)
        #expect(lines[1] == "")
        let firstLine = lines[0]
        #expect(firstLine.hasPrefix("data: "))
        #expect(firstLine.contains("\u{2028}"))
        #expect(firstLine.contains("\u{2029}"))
        #expect(firstLine.contains("\u{0085}"))
        #expect(firstLine.contains("\u{000B}"))
        #expect(firstLine.contains("\u{000C}"))
    }

    @Test func splitter_buffersIncompleteLine() {
        var parser = RemoteProviderService.SSELineParser()
        parser.append(Data("data: hel".utf8))
        #expect(parser.nextLine() == nil)
        parser.append(Data("lo\n".utf8))
        let line = parser.nextLine()
        #expect(line.map { String(decoding: $0, as: UTF8.self) } == "data: hello")
    }

    @Test func splitter_flushPendingEmitsTrailingUnterminated() {
        var parser = RemoteProviderService.SSELineParser()
        parser.append(Data("data: hello".utf8))
        #expect(parser.nextLine() == nil)
        parser.flushPending()
        let line = parser.nextLine()
        #expect(line.map { String(decoding: $0, as: UTF8.self) } == "data: hello")
        #expect(parser.nextLine() == nil)
    }

    @Test func splitter_consecutiveBlankLinesEmitSeparateEmptyLines() {
        var parser = RemoteProviderService.SSELineParser()
        parser.append(Data("a\n\n\n".utf8))
        let lines = drain(&parser)
        #expect(lines == ["a", "", ""])
    }

    // MARK: - processSSELine (field parser)

    @Test func fieldParser_handlesDataWithSpace() {
        var event = ""
        RemoteProviderService.processSSELine(Data("data: hello".utf8), into: &event)
        #expect(event == "hello")
    }

    @Test func fieldParser_handlesDataWithoutSpace() {
        // Per W3C SSE spec the space after `:` is optional. The previous
        // implementation only matched "data: " with a space — bare
        // `data:value` lines fell into the generic continuation branch and
        // corrupted the buffer.
        var event = ""
        RemoteProviderService.processSSELine(Data("data:hello".utf8), into: &event)
        #expect(event == "hello")
    }

    @Test func fieldParser_joinsMultipleDataLinesWithNewline() {
        var event = ""
        RemoteProviderService.processSSELine(Data("data: line one".utf8), into: &event)
        RemoteProviderService.processSSELine(Data("data: line two".utf8), into: &event)
        #expect(event == "line one\nline two")
    }

    @Test func fieldParser_ignoresOtherFields() {
        var event = ""
        RemoteProviderService.processSSELine(Data("event: ping".utf8), into: &event)
        RemoteProviderService.processSSELine(Data("id: abc-123".utf8), into: &event)
        RemoteProviderService.processSSELine(Data("retry: 5000".utf8), into: &event)
        #expect(event == "")
    }

    @Test func fieldParser_ignoresCommentLines() {
        var event = ""
        RemoteProviderService.processSSELine(Data(": this is a heartbeat".utf8), into: &event)
        #expect(event == "")
    }

    @Test func fieldParser_ignoresUnknownFields() {
        var event = ""
        RemoteProviderService.processSSELine(Data("foo: bar".utf8), into: &event)
        #expect(event == "")
    }

    @Test func fieldParser_emptyLineIsNoOp() {
        var event = "existing"
        RemoteProviderService.processSSELine(Data(), into: &event)
        #expect(event == "existing")
    }

    // MARK: - End-to-end SSE → event reconstruction

    @Test func endToEnd_openAIChunkWithUnicodeSeparatorInJSONString() {
        // The exact regression: a Venice/Llama-style tool-call argument
        // contains a U+2028 line separator inside a string value. The
        // splitter must not slice the JSON in half.
        let payload = """
            data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\\"q\\":\\"a\u{2028}b\\"}"}}]}}]}\n\n
            """
        var parser = RemoteProviderService.SSELineParser()
        parser.append(Data(payload.utf8))
        var event = ""
        var dispatched: [String] = []
        while let line = parser.nextLine() {
            if line.isEmpty {
                if !event.isEmpty {
                    dispatched.append(event)
                    event = ""
                }
            } else {
                RemoteProviderService.processSSELine(line, into: &event)
            }
        }
        #expect(dispatched.count == 1)
        guard let json = dispatched.first?.data(using: .utf8) else {
            #expect(Bool(false), "expected dispatched event payload")
            return
        }
        // The reassembled payload must be parseable JSON — confirming the
        // U+2028 inside the inner string value did not get treated as a
        // line break in the SSE framing.
        let parsed = try? JSONSerialization.jsonObject(with: json)
        #expect(parsed != nil, "JSON should still be parseable after reassembly")
    }

    @Test func endToEnd_crlfMultilineDataEvent() {
        // Multi-line `data:` event with CRLF terminators (rare but spec-legal).
        // Old behaviour: each CRLF dispatched a partial event; the JSON was
        // sliced into 3 separate broken events.
        let payload = "data: {\r\ndata:   \"x\":1\r\ndata: }\r\n\r\n"
        var parser = RemoteProviderService.SSELineParser()
        parser.append(Data(payload.utf8))
        var event = ""
        var dispatched: [String] = []
        while let line = parser.nextLine() {
            if line.isEmpty {
                if !event.isEmpty {
                    dispatched.append(event)
                    event = ""
                }
            } else {
                RemoteProviderService.processSSELine(line, into: &event)
            }
        }
        #expect(dispatched.count == 1)
        let reassembled = dispatched.first ?? ""
        // SSE spec joins multiple data: lines with `\n`; parsed JSON must round-trip.
        guard let data = reassembled.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            #expect(Bool(false), "expected reassembled JSON object, got: \(reassembled)")
            return
        }
        #expect(obj["x"] as? Int == 1)
    }

    // MARK: - Stream error envelope detection

    @Test func errorEnvelope_decodesOpenAIError() {
        let payload = """
            {"error":{"message":"Rate limited","type":"rate_limit_error","param":null,"code":"rate_limited"}}
            """
        let result = RemoteProviderService.tryDecodeStreamError(
            Data(payload.utf8),
            providerType: .openaiLegacy
        )
        #expect(result == "Rate limited")
    }

    @Test func errorEnvelope_decodesAnthropicStreamError() {
        let payload = """
            {"type":"error","error":{"type":"overloaded_error","message":"Anthropic is busy"}}
            """
        let result = RemoteProviderService.tryDecodeStreamError(
            Data(payload.utf8),
            providerType: .anthropic
        )
        #expect(result == "Anthropic is busy")
    }

    @Test func anthropicRefusalStopReasonSurfacesAsStreamError() {
        // Anthropic's real-time safeguard blocks a turn with
        // `stop_reason: "refusal"` and ZERO content blocks. The handler
        // must surface the `stop_details.explanation` as a stream error —
        // not let the turn end as a silent empty completion.
        let payload = """
            {"type":"message_delta","delta":{"stop_reason":"refusal","stop_sequence":null,"stop_details":{"type":"refusal","category":"cyber","explanation":"Blocked under the usage policy."}},"usage":{"output_tokens":4}}
            """
        var state = RemoteProviderService.StreamingState(stopSequences: [], trackContent: false)
        let outcome = RemoteProviderService.handleStreamEvent(
            jsonData: Data(payload.utf8),
            providerType: .anthropic,
            state: &state,
            yield: { _ in }
        )
        guard case .finishWithError(let error) = outcome else {
            Issue.record("expected finishWithError, got \(outcome)")
            return
        }
        let message = String(describing: error)
        #expect(message.contains("refusal"))
        #expect(message.contains("Blocked under the usage policy."))
    }

    @Test func anthropicNormalStopReasonDoesNotError() {
        let payload = """
            {"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":12}}
            """
        var state = RemoteProviderService.StreamingState(stopSequences: [], trackContent: false)
        let outcome = RemoteProviderService.handleStreamEvent(
            jsonData: Data(payload.utf8),
            providerType: .anthropic,
            state: &state,
            yield: { _ in }
        )
        guard case .continue = outcome else {
            Issue.record("expected .continue, got \(outcome)")
            return
        }
        #expect(state.lastFinishReason == "end_turn")
    }

    @Test func errorEnvelope_decodesGeminiError() {
        let payload = """
            {"error":{"code":429,"message":"Quota exceeded","status":"RESOURCE_EXHAUSTED"}}
            """
        let result = RemoteProviderService.tryDecodeStreamError(
            Data(payload.utf8),
            providerType: .gemini
        )
        #expect(result == "Quota exceeded")
    }

    @Test func errorEnvelope_returnsNilForNonError() {
        // A normal chat-completion chunk must not be misclassified as an error.
        let payload = """
            {"id":"abc","choices":[{"delta":{"content":"hi"},"index":0,"finish_reason":null}]}
            """
        let result = RemoteProviderService.tryDecodeStreamError(
            Data(payload.utf8),
            providerType: .openaiLegacy
        )
        #expect(result == nil)
    }

    // MARK: - Helpers

    private func drain(_ parser: inout RemoteProviderService.SSELineParser) -> [String] {
        var out: [String] = []
        while let line = parser.nextLine() {
            out.append(String(decoding: line, as: UTF8.self))
        }
        return out
    }
}
