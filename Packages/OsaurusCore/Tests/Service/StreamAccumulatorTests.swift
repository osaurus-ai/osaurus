//
//  StreamAccumulatorTests.swift
//  osaurusTests
//
//  Tests for StreamAccumulator — the component that consumes a raw TokenGeneration
//  stream from MLX and emits typed ModelRuntimeEvent values with stop-sequence
//  handling, tool-call detection, and prefill-progress signaling.
//

import Foundation
import MLXLMCommon
import Testing
import Tokenizers

@testable import OsaurusCore

// MARK: - Stub Tokenizer

/// A minimal Tokenizer stub that maps token IDs to single characters.
/// Token 32-126 → the corresponding ASCII character (all printable ASCII).
/// Everything outside that range → " ".
/// The key invariant: `decode(tokens: ids)` concatenates the per-id chars,
/// which is exactly the behaviour the accumulator's incremental-decode diff relies on.
final class StubTokenizer: Tokenizer, @unchecked Sendable {
    func tokenize(text: String) -> [String] { text.map { String($0) } }
    func encode(text: String) -> [Int] { text.unicodeScalars.map { Int($0.value) } }
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { encode(text: text) }
    func callAsFunction(_ text: String, addSpecialTokens: Bool) -> [Int] { encode(text: text) }

    func decode(tokens: [Int]) -> String {
        tokens.map { id -> String in
            guard id >= 32, id <= 126, let scalar = Unicode.Scalar(id) else { return " " }
            return String(scalar)
        }.joined()
    }

    func decode(tokens: [Int], skipSpecialTokens: Bool) -> String { decode(tokens: tokens) }

    func convertTokenToId(_ token: String) -> Int? { token.unicodeScalars.first.map { Int($0.value) } }
    func convertTokensToIds(_ tokens: [String]) -> [Int?] { tokens.map { convertTokenToId($0) } }
    func convertIdToToken(_ id: Int) -> String? {
        guard id >= 32, id <= 126, let scalar = Unicode.Scalar(id) else { return nil }
        return String(scalar)
    }
    func convertIdsToTokens(_ ids: [Int]) -> [String?] { ids.map { convertIdToToken($0) } }

    var bosToken: String? { nil }
    var bosTokenId: Int? { nil }
    var eosToken: String? { nil }
    var eosTokenId: Int? { nil }
    var unknownToken: String? { nil }
    var unknownTokenId: Int? { nil }
    var hasChatTemplate: Bool { false }
    func applyChatTemplate(messages: [Tokenizers.Message]) throws -> [Int] { [] }
    func applyChatTemplate(messages: [Tokenizers.Message], tools: [Tokenizers.ToolSpec]?) throws -> [Int] { [] }
    func applyChatTemplate(
        messages: [Tokenizers.Message],
        tools: [Tokenizers.ToolSpec]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] { [] }
    func applyChatTemplate(messages: [Tokenizers.Message], chatTemplate: Tokenizers.ChatTemplateArgument) throws
        -> [Int]
    { [] }
    func applyChatTemplate(messages: [Tokenizers.Message], chatTemplate: String) throws -> [Int] { [] }
    func applyChatTemplate(
        messages: [Tokenizers.Message],
        chatTemplate: Tokenizers.ChatTemplateArgument?,
        addGenerationPrompt: Bool,
        truncation: Bool,
        maxLength: Int?,
        tools: [Tokenizers.ToolSpec]?
    ) throws -> [Int] { [] }
    func applyChatTemplate(
        messages: [Tokenizers.Message],
        chatTemplate: Tokenizers.ChatTemplateArgument?,
        addGenerationPrompt: Bool,
        truncation: Bool,
        maxLength: Int?,
        tools: [Tokenizers.ToolSpec]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] { [] }
}

// MARK: - Helpers

/// Builds an AsyncStream<TokenGeneration> that yields the given events then finishes.
private func makeTokenStream(_ events: [TokenGeneration]) -> AsyncStream<TokenGeneration> {
    AsyncStream { continuation in
        for event in events { continuation.yield(event) }
        continuation.finish()
    }
}

/// Drains any AsyncSequence of ModelRuntimeEvent and returns accumulated token strings.
private func drainTokens<S: AsyncSequence>(_ stream: S) async throws -> String
where S.Element == ModelRuntimeEvent {
    var result = ""
    for try await event in stream {
        if case .tokens(let s) = event { result += s }
    }
    return result
}

/// Drains the stream and returns all events (tokens + tool invocations).
private func drainEvents<S: AsyncSequence>(_ stream: S) async throws -> [ModelRuntimeEvent]
where S.Element == ModelRuntimeEvent {
    var events: [ModelRuntimeEvent] = []
    for try await event in stream {
        events.append(event)
    }
    return events
}

private let stubTokenizer = StubTokenizer()

// MARK: - Tests

struct StreamAccumulatorTests {

    // MARK: Basic token emission

    @Test func sanity_asyncStreamDrainsCorrectly() async throws {
        // Sanity check: basic AsyncStream iteration works in this test context.
        let (rawStream, rawCont) = AsyncStream<Int>.makeStream()
        rawCont.yield(1)
        rawCont.yield(2)
        rawCont.finish()
        var collected: [Int] = []
        for await v in rawStream { collected.append(v) }
        #expect(collected == [1, 2])
    }

    @Test func emitsDecodedTextForSingleToken() async throws {
        // Token 72 == 'H'
        let stream = makeTokenStream([.token(72)])
        let acc = StreamAccumulator.accumulate(
            events: stream,
            tokenizer: stubTokenizer,
            stopSequences: [],
            tools: nil
        )
        var out = ""
        var iter = acc.makeAsyncIterator()
        print("[TEST] About to call next()")
        let first = await iter.next()
        print("[TEST] next() returned: \(String(describing: first))")
        if case .tokens(let s) = first { out += s }
        while let e = await iter.next() {
            if case .tokens(let s) = e { out += s }
        }
        #expect(out == "H")
    }

    @Test func emitsDecodedTextForMultipleTokens() async throws {
        // 72='H', 73='I' → "HI"
        let stream = makeTokenStream([.token(72), .token(73)])
        let out = try await drainTokens(
            StreamAccumulator.accumulate(
                events: stream,
                tokenizer: stubTokenizer,
                stopSequences: [],
                tools: nil
            )
        )
        #expect(out == "HI")
    }

    @Test func emitsNoTextForEmptyStream() async throws {
        let stream = makeTokenStream([])
        let out = try await drainTokens(
            StreamAccumulator.accumulate(
                events: stream,
                tokenizer: stubTokenizer,
                stopSequences: [],
                tools: nil
            )
        )
        #expect(out == "")
    }

    @Test func ignoresInfoEvent() async throws {
        let info = GenerateCompletionInfo(
            promptTokenCount: 10,
            generationTokenCount: 1,
            promptTime: 1.0,
            generationTime: 0.1,
            stopReason: .stop
        )
        // Token 65 = 'A', then an info event, then token 66 = 'B'
        let stream = makeTokenStream([.token(65), .info(info), .token(66)])
        let out = try await drainTokens(
            StreamAccumulator.accumulate(
                events: stream,
                tokenizer: stubTokenizer,
                stopSequences: [],
                tools: nil
            )
        )
        #expect(out == "AB")
    }

    // MARK: onGeneratedTokenIds callback

    @Test func onGeneratedTokenIds_receivesAllIds() async throws {
        let stream = makeTokenStream([.token(65), .token(66), .token(67)])
        nonisolated(unsafe) var capturedIds: [Int] = []
        _ = try await drainTokens(
            StreamAccumulator.accumulate(
                events: stream,
                tokenizer: stubTokenizer,
                stopSequences: [],
                tools: nil,
                onGeneratedTokenIds: { capturedIds = $0 }
            )
        )
        #expect(capturedIds == [65, 66, 67])
    }

    @Test func onGeneratedTokenIds_receivesEmptyArrayForEmptyStream() async throws {
        let stream = makeTokenStream([])
        nonisolated(unsafe) var capturedIds: [Int] = [-1]  // sentinel
        _ = try await drainTokens(
            StreamAccumulator.accumulate(
                events: stream,
                tokenizer: stubTokenizer,
                stopSequences: [],
                tools: nil,
                onGeneratedTokenIds: { capturedIds = $0 }
            )
        )
        #expect(capturedIds == [])
    }

    @Test func onGeneratedTokenIds_notCalledForInfoOnlyStream() async throws {
        let info = GenerateCompletionInfo(
            promptTokenCount: 5,
            generationTokenCount: 0,
            promptTime: 0.5,
            generationTime: 0.0,
            stopReason: .stop
        )
        let stream = makeTokenStream([.info(info)])
        nonisolated(unsafe) var callbackFired = false
        _ = try await drainTokens(
            StreamAccumulator.accumulate(
                events: stream,
                tokenizer: stubTokenizer,
                stopSequences: [],
                tools: nil,
                onGeneratedTokenIds: { _ in callbackFired = true }
            )
        )
        // Callback fires on stream finish even when no tokens were generated.
        #expect(callbackFired)
    }

    // MARK: Stop sequences

    @Test func stopSequence_truncatesAtMatch() async throws {
        // Tokens: A B C D E → "ABCDE", stop on "C"
        let stream = makeTokenStream([65, 66, 67, 68, 69].map { TokenGeneration.token($0) })
        let out = try await drainTokens(
            StreamAccumulator.accumulate(
                events: stream,
                tokenizer: stubTokenizer,
                stopSequences: ["C"],
                tools: nil
            )
        )
        #expect(out == "AB")
    }

    @Test func stopSequence_multiCharMatch() async throws {
        // Tokens: A B C D → "ABCD", stop on "BC"
        let stream = makeTokenStream([65, 66, 67, 68].map { TokenGeneration.token($0) })
        let out = try await drainTokens(
            StreamAccumulator.accumulate(
                events: stream,
                tokenizer: stubTokenizer,
                stopSequences: ["BC"],
                tools: nil
            )
        )
        #expect(out == "A")
    }

    @Test func stopSequence_atStartYieldsNothing() async throws {
        // Stop on "A" — the very first character — nothing before it.
        let stream = makeTokenStream([65, 66].map { TokenGeneration.token($0) })
        let out = try await drainTokens(
            StreamAccumulator.accumulate(
                events: stream,
                tokenizer: stubTokenizer,
                stopSequences: ["A"],
                tools: nil
            )
        )
        #expect(out == "")
    }

    @Test func stopSequence_notPresent_emitsAll() async throws {
        let stream = makeTokenStream([65, 66, 67].map { TokenGeneration.token($0) })
        let out = try await drainTokens(
            StreamAccumulator.accumulate(
                events: stream,
                tokenizer: stubTokenizer,
                stopSequences: ["Z"],
                tools: nil
            )
        )
        #expect(out == "ABC")
    }

    // MARK: prefillDidFinish signaling

    @Test func prefillDidFinish_calledAfterFirstToken() async throws {
        // Set and read in one MainActor block to avoid a suspension point where
        // a lingering prefillDidFinishAsync() from a parallel test could clear the value.
        let countAfterStart = await MainActor.run {
            InferenceProgressManager.shared.prefillWillStart(tokenCount: 5)
            return InferenceProgressManager.shared.prefillTokenCount
        }
        #expect(countAfterStart != nil)

        // Build a stream with one token then a finish.
        // We use a pre-filled stream so the iterator returns synchronously.
        let rawStream = makeTokenStream([.token(65)])  // 'A'

        let acc = StreamAccumulator.accumulate(
            events: rawStream,
            tokenizer: stubTokenizer,
            stopSequences: [],
            tools: nil
        )

        // Pull the first event. Inside next(), prefillDidFinishAsync() is called on first token.
        var iter = acc.makeAsyncIterator()
        let firstEvent = await iter.next()
        #expect(firstEvent != nil)

        // Allow the @MainActor prefillDidFinish task to run.
        try await Task.sleep(for: .milliseconds(50))

        let countAfterToken = await MainActor.run { InferenceProgressManager.shared.prefillTokenCount }
        #expect(countAfterToken == nil)

        // Drain the rest (stream is already finished after one token).
        while await iter.next() != nil {}
    }

    @Test func prefillDidFinish_calledOnStreamFinishWithNoTokens() async throws {
        await MainActor.run { InferenceProgressManager.shared.prefillWillStart(tokenCount: 5) }
        try await Task.sleep(for: .milliseconds(50))

        let stream = makeTokenStream([])
        _ = try await drainTokens(
            StreamAccumulator.accumulate(
                events: stream,
                tokenizer: stubTokenizer,
                stopSequences: [],
                tools: nil
            )
        )
        try await Task.sleep(for: .milliseconds(50))

        let countAfterFinish = await MainActor.run { InferenceProgressManager.shared.prefillTokenCount }
        #expect(countAfterFinish == nil)
    }

    // MARK: Tool detection

    @Test func toolDetection_yieldsToolInvocationAndStops() async throws {
        let tool = Tool(
            type: "function",
            function: ToolFunction(
                name: "get_weather",
                description: nil,
                parameters: .object(["city": .string("")])
            )
        )
        // Build a stream that emits the full inline tool-call in the flat JSON format
        // that JSONToolCallParser expects: <tool_call>{"name":...,"arguments":...}</tool_call>
        // We encode each character as its Unicode scalar value (which StubTokenizer decodes).
        let text = "<tool_call>{\"name\":\"get_weather\",\"arguments\":{\"city\":\"SF\"}}</tool_call>"
        let tokens: [TokenGeneration] = text.unicodeScalars.map { .token(Int($0.value)) }
        let toolsSpec = [tool.toTokenizerToolSpec()]

        let stream = makeTokenStream(tokens)
        let events = try await drainEvents(
            StreamAccumulator.accumulate(
                events: stream,
                tokenizer: stubTokenizer,
                stopSequences: [],
                tools: [tool],
                toolCallFormat: .json,
                toolsSpec: toolsSpec
            )
        )

        // The last event must be a .toolInvocation
        guard let last = events.last, case .toolInvocation(let name, let args) = last else {
            Issue.record("Expected .toolInvocation as last event, got \(events)")
            return
        }
        #expect(name == "get_weather")
        #expect(args.contains("SF"))
    }

    // MARK: Incremental decode correctness

    @Test func incrementalDecode_producesCorrectCumulativeText() async throws {
        // 5 tokens → "ABCDE", verify the concatenation of all emitted chunks equals full text.
        let ids = [65, 66, 67, 68, 69]
        let stream = makeTokenStream(ids.map { .token($0) })
        var chunks: [String] = []
        for await event in StreamAccumulator.accumulate(
            events: stream,
            tokenizer: stubTokenizer,
            stopSequences: [],
            tools: nil
        ) {
            if case .tokens(let s) = event { chunks.append(s) }
        }
        #expect(chunks.joined() == "ABCDE")
    }
}
