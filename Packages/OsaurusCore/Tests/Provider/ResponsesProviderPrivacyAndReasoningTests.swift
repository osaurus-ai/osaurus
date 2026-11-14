import Foundation
import Testing
import os

@testable import OsaurusCore

@Suite("Native provider privacy and reasoning continuity", .serialized, .timeLimit(.minutes(2)))
struct ResponsesProviderPrivacyAndReasoningTests {
    private final class Capture: Sendable {
        let values = OSAllocatedUnfairLock(initialState: [ResponsesGenerationEvent]())
        func add(_ event: ResponsesGenerationEvent) { values.withLock { $0.append(event) } }
    }
    private func encoded(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: .sortedKeys), as: UTF8.self)
    }
    private func stream(_ values: [ResponsesGenerationEvent]) -> AsyncThrowingStream<ResponsesGenerationEvent, Error> {
        AsyncThrowingStream { c in values.forEach { c.yield($0) }; c.finish() }
    }
    private func raw(_ delta: String, type: String = "response.output_text.delta", sequence: Int) -> ResponsesGenerationEvent {
        .providerEvent(.object(["type": .string(type), "delta": .string(delta),
            "output_index": .number(0), "content_index": .number(0), "sequence_number": .number(Double(sequence))]))
    }
    private func done(type: String = "response.output_text.done", text: String) -> ResponsesGenerationEvent {
        .providerEvent(.object(["type": .string(type), "text": .string(text), "output_index": .number(0), "content_index": .number(0)]))
    }

    @Test func splitPlaceholderRestorationKeepsOriginalNativeFramesAndPortableTextConsistent() async throws {
        let map = RedactionMap(conversationID: UUID())
        let placeholder = await map.intern("Eric", as: .person)
        let token = placeholder.token
        let cut = token.index(token.startIndex, offsetBy: 4)
        let first = String(token[..<cut]), second = String(token[cut...])
        let source = stream([raw(first, sequence: 1), .outputTextDelta(first),
            raw(second, sequence: 2), .outputTextDelta(second), done(text: token)])
        var events: [ResponsesGenerationEvent] = []
        for try await event in RemoteResponsesPrivacyStream.wrap(source, map: map) { events.append(event) }
        let native = events.compactMap { event -> [String: JSONValue]? in
            if case .providerEvent(.object(let value)) = event { return value }; return nil
        }
        #expect(native.compactMap { if case .number(let value) = $0["sequence_number"] { return Int(value) }; return nil } == [1, 2])
        let rawText = native.compactMap { if case .string(let value) = $0["delta"] { return value }; return nil }.joined()
        let portable = events.compactMap { if case .outputTextDelta(let text) = $0 { return text }; return nil }.joined()
        #expect(rawText == "Eric" && portable == "Eric")
        #expect(native.last?["text"] == .string("Eric"))
    }

    @Test func literalUnclosedTailIsFlushedOnItsOriginalFrame() async throws {
        let map = RedactionMap(conversationID: UUID())
        _ = await map.intern("Eric", as: .person)
        let source = stream([raw("literal [", sequence: 1), .outputTextDelta("literal ["), done(text: "literal [")])
        var rawText = "", portable = ""
        for try await event in RemoteResponsesPrivacyStream.wrap(source, map: map) {
            if case .providerEvent(.object(let value)) = event, case .string(let delta) = value["delta"] { rawText += delta }
            if case .outputTextDelta(let delta) = event { portable += delta }
        }
        #expect(rawText == "literal [" && portable == "literal [")
    }

    @Test func argumentDeltaOriginalsAreJSONEscapedAndNeverRewriteProviderIdentity() async throws {
        let original = "Eric \"quoted\"\\path\nnext"
        let map = RedactionMap(conversationID: UUID())
        let placeholder = await map.intern(original, as: .person)
        let pieces = ["{\"name\":\"[PERS", String(placeholder.token.dropFirst(5)) + "\"}"]
        let source = stream([raw(pieces[0], type: "response.function_call_arguments.delta", sequence: 1), .functionArgumentsPreview(pieces[0]),
            raw(pieces[1], type: "response.function_call_arguments.delta", sequence: 2), .functionArgumentsPreview(pieces[1]),
            done(type: "response.function_call_arguments.done", text: "")])
        var rawArguments = "", portable = ""
        for try await event in RemoteResponsesPrivacyStream.wrap(source, map: map) {
            if case .providerEvent(.object(let value)) = event, case .string(let delta) = value["delta"] { rawArguments += delta }
            if case .functionArgumentsPreview(let delta) = event { portable += delta }
        }
        let decoded = try JSONSerialization.jsonObject(with: Data(rawArguments.utf8)) as? [String: String]
        #expect(decoded?["name"] == original)
        #expect(rawArguments == portable)
    }

    @Test func pendingInterleavedFramesAreBoundedAndFailWithoutReplayOrTrimming() async throws {
        let map = RedactionMap(conversationID: UUID())
        _ = await map.intern("Eric", as: .person)
        let source = stream([raw("[PERS", sequence: 1), .outputTextDelta("[PERS"),
            .providerEvent(.object(["type": .string("response.future_event"), "payload": .string(String(repeating: "x", count: 2048))]))])
        var count = 0
        do {
            for try await _ in RemoteResponsesPrivacyStream.wrap(source, map: map, pendingByteLimit: 512) { count += 1 }
            Issue.record("Expected bounded restoration error")
        } catch {
            #expect(error is RemoteResponsesPrivacyStream.PendingFrameLimitError)
            #expect(count == 0)
        }
    }

    private enum UpstreamFailure: Error { case transport }

    @Test(arguments: [false, true])
    func upstreamErrorOrCancellationFlushesReceivedFramesWithoutCompletion(_ cancelled: Bool) async throws {
        let map = RedactionMap(conversationID: UUID())
        _ = await map.intern("Eric", as: .person)
        let source = AsyncThrowingStream<ResponsesGenerationEvent, Error> { c in
            c.yield(raw("literal [", sequence: 17))
            c.yield(.outputTextDelta("literal ["))
            c.finish(throwing: cancelled ? CancellationError() : UpstreamFailure.transport)
        }
        var events: [ResponsesGenerationEvent] = []
        do {
            for try await event in RemoteResponsesPrivacyStream.wrap(source, map: map) { events.append(event) }
            Issue.record("Expected original upstream terminal error")
        } catch {
            if cancelled { #expect(error is CancellationError) }
            else { #expect(error is UpstreamFailure) }
        }
        #expect(events.count == 2, "No completion or transport-success event is invented")
        if case .providerEvent(.object(let frame)) = events.first {
            #expect(frame["sequence_number"] == .number(17))
            #expect(frame["delta"] == .string("literal ["))
        } else { Issue.record("Expected original native frame first") }
        if case .outputTextDelta(let text) = events.last { #expect(text == "literal [") }
        else { Issue.record("Expected matching portable frame") }
    }

    @Test func consumerCancellationTerminatesUpstreamInsteadOfReplaying() async throws {
        let map = RedactionMap(conversationID: UUID())
        let termination = AsyncStream<Void>.makeStream()
        let source = AsyncThrowingStream<ResponsesGenerationEvent, Error> { c in
            c.onTermination = { _ in termination.continuation.yield(()); termination.continuation.finish() }
        }
        let wrapped = RemoteResponsesPrivacyStream.wrap(source, map: map)
        let consumer = Task { for try await _ in wrapped {} }
        consumer.cancel()
        var iterator = termination.stream.makeAsyncIterator()
        _ = await iterator.next()
        _ = await consumer.result
    }

    @Test func refusalPlaceholdersUseTheirOwnPortableRailAndPreserveRawFrames() async throws {
        let map = RedactionMap(conversationID: UUID())
        let token = await map.intern("Eric", as: .person).token
        let cut = token.index(token.startIndex, offsetBy: 4)
        let first = String(token[..<cut]), second = String(token[cut...])
        let source = stream([
            raw("Prior text. ", sequence: 1), .outputTextDelta("Prior text. "),
            raw(first, type: "response.refusal.delta", sequence: 2), .outputTextDelta(first),
            raw(second, type: "response.refusal.delta", sequence: 3), .outputTextDelta(second),
            .providerEvent(.object(["type": .string("response.refusal.done"), "refusal": .string(token),
                "output_index": .number(0), "content_index": .number(0)])),
        ])
        var native = "", portable = "", sequences: [Int] = []
        for try await event in RemoteResponsesPrivacyStream.wrap(source, map: map) {
            if case .providerEvent(.object(let frame)) = event {
                if case .string(let delta) = frame["delta"] { native += delta }
                if case .number(let value) = frame["sequence_number"] { sequences.append(Int(value)) }
                if case .string(let refusal) = frame["refusal"] { #expect(refusal == "Eric") }
            }
            if case .outputTextDelta(let text) = event { portable += text }
        }
        #expect(native == "Prior text. Eric" && portable == native)
        #expect(sequences == [1, 2, 3])
    }

    @Test func realAnthropicThinkingAndSignatureSurviveTypedResultAndHistory() async throws {
        let capture = Capture()
        let native = RemoteAnthropicNativeStream { capture.add($0) }
        for value in [
            try encoded(["type": "message_start", "message": ["id": "msg_actual", "usage": ["input_tokens": 20, "cache_read_input_tokens": 10]]]),
            try encoded(["type": "content_block_start", "index": 0, "content_block": ["type": "thinking", "thinking": "", "future": "retained"]]),
            try encoded(["type": "content_block_delta", "index": 0, "delta": ["type": "thinking_delta", "thinking": "Actual thinking."]]),
            try encoded(["type": "content_block_delta", "index": 0, "delta": ["type": "signature_delta", "signature": "opaque-signature"]]),
            try encoded(["type": "content_block_stop", "index": 0]),
            try encoded(["type": "content_block_start", "index": 1, "content_block": ["type": "redacted_thinking", "data": "opaque-redacted"]]),
            try encoded(["type": "content_block_stop", "index": 1]),
            try encoded(["type": "message_delta", "delta": ["stop_reason": "end_turn"], "usage": ["output_tokens": 7]]),
            try encoded(["type": "message_stop"]),
        ] { _ = try native.consume(value) }
        let result = try await ResponsesGenerationResult.collect(stream(capture.values.withLock { $0 }))
        #expect(result.completion.responseID == "msg_actual")
        #expect(result.inputTokenCount == 30 && result.completion.tokenCount == 7)
        #expect(result.completion.tokensPerSecond == nil)
        #expect(result.reasoning == "Actual thinking.")
        #expect(result.providerOutputItems.isEmpty, "Anthropic blocks are never OpenAI Items")
        #expect(result.anthropicThinkingBlocks.count == 2)
        let history = try result.completedAssistantInput()
        #expect(history.anthropic_thinking_blocks == result.anthropicThinkingBlocks)
        if case .object(let block) = result.anthropicThinkingBlocks[0] {
            #expect(block["signature"] == .string("opaque-signature"))
            #expect(block["future"] == .string("retained"))
        }
    }

    @Test @MainActor func signedBlocksSurviveBothSessionPersistenceRepresentations() throws {
        let block: JSONValue = .object(["type": .string("thinking"), "thinking": .string("actual"), "signature": .string("opaque")])
        let turn = ChatTurn(role: .assistant, content: "Answer")
        turn.anthropicThinkingBlocks = [block]
        let data = try JSONEncoder().encode(ChatTurnData(from: turn))
        let reloaded = ChatTurn(from: try JSONDecoder().decode(ChatTurnData.self, from: data))
        #expect(reloaded.anthropicThinkingBlocks == [block])
        let lightweight = try JSONDecoder().decode(ChatTurn.Persisted.self, from: JSONEncoder().encode(turn.toPersisted()))
        #expect(ChatTurn.fromPersisted(lightweight).anthropicThinkingBlocks == [block])
    }
}
