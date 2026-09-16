import Foundation
import MLXLMCommon
import Testing

@testable import OsaurusCore

@Suite("Prepared local input accounting")
struct LocalInputTokenUsageTests {
    @Test func inputHintIsMetadataAndNotTerminalStats() {
        for count in [0, 1, 257, Int.max] {
            let hint = StreamingInputTokenHint.encode(count)
            #expect(StreamingInputTokenHint.decode(hint) == count)
            #expect(StreamingToolHint.isSentinel(hint))
            #expect(StreamingStatsHint.decode(hint) == nil)
        }
        for text in ["input_tokens:12", "\u{FFFE}input_tokens:-1", "\u{FFFE}input_tokens:",
                     "\u{FFFE}input_tokens:12x", "\u{FFFE}input_tokens:999999999999999999999"] {
            #expect(StreamingInputTokenHint.decode(text) == nil)
        }
    }

    @Test(arguments: [0, 257])
    func preparedCountPrecedesImmediateToolDispatch(_ count: Int) async throws {
        let source = AsyncStream<Generation> { continuation in
            continuation.yield(.toolCall(MLXLMCommon.ToolCall(function: .init(
                name: "lookup_zone", arguments: ["zone": .string("east")]))))
            continuation.finish()
        }
        let events = GenerationEventMapper.map(events: source, promptTokenCount: count)
        let stream = ModelRuntime.bridgeToolEventStream(events)
        var inputCount: Int?
        var terminalCount: Int?
        do {
            for try await delta in stream {
                inputCount = StreamingInputTokenHint.decode(delta) ?? inputCount
                terminalCount = StreamingStatsHint.decode(delta)?.tokenCount ?? terminalCount
            }
            Issue.record("Expected immediate tool dispatch")
        } catch let call as ServiceToolInvocation {
            #expect(call.toolName == "lookup_zone")
        }
        #expect(inputCount == count)
        #expect(terminalCount == nil)
    }

    @Test(arguments: [12, 257])
    func terminalCountConfirmsOrCorrectsPreparedCount(_ prepared: Int) async throws {
        let source = AsyncStream<Generation> { continuation in
            continuation.yield(.chunk("answer"))
            continuation.yield(.info(GenerateCompletionInfo(
                promptTokenCount: 257, generationTokenCount: 8, promptTime: 0.1, generationTime: 0.2)))
            continuation.finish()
        }
        var counts: [Int] = []
        var output: [String] = []
        var completions = 0
        for try await event in GenerationEventMapper.map(events: source, promptTokenCount: prepared) {
            switch event {
            case .inputTokenCount(let count): counts.append(count)
            case .tokens(let text): output.append(text)
            case .completionInfo: completions += 1
            default: break
            }
        }
        #expect(counts == (prepared == 257 ? [257] : [12, 257]))
        #expect(output == ["answer"])
        #expect(completions == 1)
    }

    private actor CancellationProbe {
        var receivedInput = false
        var upstreamCancelled = false
        func receiveInput() { receivedInput = true }
        func cancelUpstream() { upstreamCancelled = true }
    }

    private struct OpenStreamService: ModelService {
        let stream: AsyncThrowingStream<String, Error>
        var id: String { "input-usage-cancel" }
        func isAvailable() -> Bool { true }
        func handles(requestedModel: String?) -> Bool { requestedModel == id }
        func generateOneShot(
            messages: [ChatMessage], parameters: GenerationParameters, requestedModel: String?
        ) async throws -> String { "unused" }
        func streamDeltas(
            messages: [ChatMessage], parameters: GenerationParameters,
            requestedModel: String?, stopSequences: [String]
        ) async throws -> AsyncThrowingStream<String, Error> { stream }
    }

    @Test func inputHintDoesNotDisarmRealChatStreamCancellation() async throws {
        let probe = CancellationProbe()
        let (upstream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        continuation.onTermination = { termination in
            if case .cancelled = termination { Task { await probe.cancelUpstream() } }
        }
        defer { continuation.finish() }
        let engine = ChatEngine(services: [OpenStreamService(stream: upstream)], installedModelsProvider: { [] })
        let request = try JSONDecoder().decode(ChatCompletionRequest.self, from: Data(
            #"{"model":"input-usage-cancel","messages":[{"role":"user","content":"hello"}],"stream":true}"#.utf8))
        let stream = try await engine.streamChat(request: request)
        let consumer = Task {
            do {
                for try await delta in stream {
                    if StreamingInputTokenHint.decode(delta) != nil { await probe.receiveInput() }
                }
            } catch {}
        }
        defer { consumer.cancel() }
        continuation.yield(StreamingInputTokenHint.encode(257))
        for _ in 0 ..< 100 where !(await probe.receivedInput) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await probe.receivedInput)
        consumer.cancel()
        await consumer.value
        for _ in 0 ..< 100 where !(await probe.upstreamCancelled) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await probe.upstreamCancelled)
    }
}
