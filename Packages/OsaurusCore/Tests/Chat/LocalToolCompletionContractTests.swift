import Foundation
import Testing

@testable import OsaurusCore

@Suite("Local API tool completion accounting")
struct LocalToolCompletionContractTests {
    actor Capture {
        var complete: Bool?
        var cancelled = false
        func set(_ value: Bool) { complete = value }
        func markCancelled() { cancelled = true }
    }

    struct Service: ToolCapableService {
        let capture: Capture
        var callCount = 2
        var id: String { "tool-contract-fixture" }
        func isAvailable() -> Bool { true }
        func handles(requestedModel: String?) -> Bool { requestedModel == id }
        func generateOneShot(
            messages: [ChatMessage],
            parameters: GenerationParameters,
            requestedModel: String?
        ) async throws -> String { "unused" }
        func streamDeltas(
            messages: [ChatMessage],
            parameters: GenerationParameters,
            requestedModel: String?,
            stopSequences: [String]
        ) async throws
            -> AsyncThrowingStream<String, Error>
        { AsyncThrowingStream { $0.finish() } }
        func respondWithTools(
            messages: [ChatMessage],
            parameters: GenerationParameters,
            stopSequences: [String],
            tools: [Tool],
            toolChoice: ToolChoiceOption?,
            requestedModel: String?
        ) async throws -> String { "unused" }
        func streamWithTools(
            messages: [ChatMessage],
            parameters: GenerationParameters,
            stopSequences: [String],
            tools: [Tool],
            toolChoice: ToolChoiceOption?,
            requestedModel: String?
        ) async throws -> AsyncThrowingStream<String, Error> {
            await capture.set(parameters.collectCompleteToolResponse)
            let events = AsyncThrowingStream<ModelRuntimeEvent, Error> { c in
                c.yield(.reasoning("Need both readings."))
                c.yield(.tokens("Checking both zones."))
                c.yield(.toolCallProgress("<tool_call>lookup_zone"))
                if callCount > 0 {
                    c.yield(.toolInvocation(name: "lookup_zone", argsJSON: #"{"zone":"east"}"#))
                }
                if callCount > 1 {
                    c.yield(.toolInvocation(name: "lookup_zone", argsJSON: #"{"zone":"west"}"#))
                }
                c.yield(
                    .completionInfo(
                        tokenCount: 59,
                        tokensPerSecond: 17.5,
                        unclosedReasoning: false,
                        stopReason: callCount == 0 ? "stop" : "tool_calls",
                        promptTokensPerSecond: 100,
                        mtp: nil
                    )
                )
                c.finish()
            }
            return ModelRuntime.bridgeToolEventStream(
                events,
                collectCompleteResponse: parameters.collectCompleteToolResponse
            )
        }
    }

    func request(stream: Bool = false, agent: Bool = false) -> ChatCompletionRequest {
        var r = ChatCompletionRequest(
            model: "tool-contract-fixture",
            messages: [ChatMessage(role: "user", content: "Read both zones.")],
            temperature: nil,
            max_tokens: 128,
            stream: stream,
            top_p: nil,
            frequency_penalty: nil,
            presence_penalty: nil,
            stop: nil,
            n: nil,
            tools: [
                Tool(type: "function", function: ToolFunction(name: "lookup_zone", description: nil, parameters: nil))
            ],
            tool_choice: nil
        )
        r.isAgentRequest = agent
        return r
    }

    @Test func nonstreamKeepsAllCallsReasoningContentAndRuntimeUsage() async throws {
        let capture = Capture()
        let engine = ChatEngine(services: [Service(capture: capture)], installedModelsProvider: { [] })
        let response = try await engine.completeChat(request: request())
        #expect(await capture.complete == true)
        let choice = try #require(response.choices.first)
        #expect(choice.finish_reason == "tool_calls")
        #expect(choice.message.content == "Checking both zones.")
        #expect(choice.message.reasoning_content == "Need both readings.")
        #expect(choice.message.tool_calls?.map(\.function.arguments) == [#"{"zone":"east"}"#, #"{"zone":"west"}"#])
        #expect(response.usage.completion_tokens == 59)
        #expect(response.usage.total_tokens == response.usage.prompt_tokens + 59)
        #expect(response.usage.tokens_per_second == 17.5)
    }

    @Test func streamingExposesStatsBeforeTheCompleteCallBatch() async throws {
        let capture = Capture()
        let engine = ChatEngine(services: [Service(capture: capture)], installedModelsProvider: { [] })
        let stream = try await engine.streamChat(request: request(stream: true))
        var count: Int?
        var rate: Double?
        var callCount = 0
        do {
            for try await delta in stream {
                if let stats = StreamingStatsHint.decode(delta) {
                    count = stats.tokenCount
                    rate = stats.tokensPerSecond
                }
            }
            Issue.record("Expected complete tool batch")
        } catch let calls as ServiceToolInvocations {
            callCount = calls.invocations.count
        }
        #expect(await capture.complete == true)
        #expect(callCount == 2)
        #expect(count == 59)
        #expect(rate == 17.5)
    }

    @Test func agentRequestsKeepImmediateDispatch() async throws {
        let capture = Capture()
        let engine = ChatEngine(services: [Service(capture: capture)], installedModelsProvider: { [] })
        let response = try await engine.completeChat(request: request(agent: true))
        #expect(await capture.complete == false)
        #expect(response.choices.first?.message.tool_calls?.count == 1)
        #expect(response.choices.first?.message.content == nil)
        #expect(response.choices.first?.message.reasoning_content == nil)
    }

    @Test func chatUISourceKeepsImmediateDispatchWithoutAgentMarker() async throws {
        let capture = Capture()
        let engine = ChatEngine(services: [Service(capture: capture)], installedModelsProvider: { [] }, source: .chatUI)
        let response = try await engine.completeChat(request: request())
        #expect(await capture.complete == false)
        #expect(response.choices.first?.message.tool_calls?.count == 1)
        #expect(response.choices.first?.message.content == nil)
    }

    @Test func toolEnabledPlainAnswerKeepsAuthoritativeReasoningUsage() async throws {
        let capture = Capture()
        let engine = ChatEngine(services: [Service(capture: capture, callCount: 0)], installedModelsProvider: { [] })
        let response = try await engine.completeChat(request: request())
        #expect(response.choices.first?.finish_reason == "stop")
        #expect(response.choices.first?.message.content == "Checking both zones.")
        #expect(response.choices.first?.message.reasoning_content == "Need both readings.")
        #expect(response.usage.completion_tokens == 59)
        #expect(response.usage.tokens_per_second == 17.5)
    }

    @Test func completeResponseCancellationCancelsUpstream() async throws {
        let capture = Capture()
        let (upstream, continuation) = AsyncThrowingStream<ModelRuntimeEvent, Error>.makeStream()
        continuation.onTermination = { termination in
            if case .cancelled = termination {
                Task { await capture.markCancelled() }
            }
        }
        let stream = ModelRuntime.bridgeToolEventStream(upstream, collectCompleteResponse: true)
        let consumer = Task {
            do { for try await _ in stream {} } catch {}
        }
        continuation.yield(.toolInvocation(name: "lookup_zone", argsJSON: #"{"zone":"east"}"#))
        consumer.cancel()
        await consumer.value
        for _ in 0 ..< 100 where !(await capture.cancelled) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await capture.cancelled)
        continuation.finish()
    }

    @Test func failedTailDoesNotPublishPartialAPICompletion() async throws {
        struct Failed: Error {}
        let upstream = AsyncThrowingStream<ModelRuntimeEvent, Error> { c in
            c.yield(.toolInvocation(name: "lookup_zone", argsJSON: #"{"zone":"east"}"#))
            c.finish(throwing: Failed())
        }
        do {
            for try await _ in ModelRuntime.bridgeToolEventStream(upstream, collectCompleteResponse: true) {}
            Issue.record("Expected upstream error")
        } catch is Failed {
            // A closed first envelope does not make a failed full completion successful.
        }
    }
}
