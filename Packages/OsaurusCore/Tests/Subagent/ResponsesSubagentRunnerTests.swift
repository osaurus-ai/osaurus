import Foundation
import Testing

@testable import OsaurusCore

@Suite("Responses spawned-run continuity", .timeLimit(.minutes(1)))
struct ResponsesSubagentRunnerTests {
    private actor Script {
        var requests: [ResponsesInferenceRequest] = []
        var executions: [String] = []
        var firstTail: AsyncThrowingStream<ResponsesGenerationEvent, Error>.Continuation?
        let incomplete: Bool

        init(incomplete: Bool = false) { self.incomplete = incomplete }

        static let items: [JSONValue] = [
            .object([
                "type": .string("reasoning"), "id": .string("rs_fixture"),
                "encrypted_content": .string("opaque"), "summary": .array([]),
            ]),
            .object([
                "type": .string("message"), "id": .string("msg_fixture"),
                "phase": .string("commentary"), "status": .string("completed"), "role": .string("assistant"),
                "content": .array([
                    .object([
                        "type": .string("output_text"), "text": .string("Checking."),
                        "annotations": .array([]),
                    ])
                ]), "future": .bool(true),
            ]),
            .object([
                "type": .string("function_call"), "id": .string("fc_fixture"),
                "call_id": .string("call_fixture"), "name": .string("lookup"),
                "arguments": .string(#"{"key":"a"}"#), "status": .string("completed"), "future": .bool(true),
            ]),
        ]

        func stream(_ request: ResponsesInferenceRequest) -> AsyncThrowingStream<ResponsesGenerationEvent, Error> {
            requests.append(request)
            let (stream, producer) = AsyncThrowingStream<ResponsesGenerationEvent, Error>.makeStream()
            if requests.count == 1 {
                let call = ResponsesFunctionCall(
                    id: "fc_fixture",
                    callID: "call_fixture",
                    name: "lookup",
                    arguments: #"{"key":"a"}"#
                )
                producer.yield(.reasoningDelta("Plan."))
                producer.yield(.outputTextDelta("Checking."))
                for item in Self.items { producer.yield(.providerOutputItem(item)) }
                producer.yield(.reasoningItem(.init(id: "rs_fixture", encryptedContent: "opaque")))
                producer.yield(.functionCallAdded(call))
                producer.yield(
                    .responseCompleted(
                        .init(
                            responseID: "resp_first",
                            status: incomplete ? .incomplete : .completed,
                            functionCalls: [call],
                            tokenCount: 12,
                            tokensPerSecond: 31.125,
                            unclosedReasoning: false,
                            stopReason: incomplete ? "length" : "tool_calls",
                            promptTokensPerSecond: 512,
                            mtp: nil,
                            inputTokenCount: 100
                        )
                    )
                )
                if incomplete {
                    producer.yield(.drained)
                    producer.finish()
                } else {
                    // Tool execution must start at response completion. Waiting
                    // for this tail first would deadlock until the run deadline.
                    firstTail = producer
                }
            } else {
                producer.yield(.outputTextDelta("42"))
                producer.yield(
                    .responseCompleted(
                        .init(
                            responseID: "resp_second",
                            status: .completed,
                            functionCalls: [],
                            tokenCount: 2,
                            tokensPerSecond: 40,
                            unclosedReasoning: false,
                            stopReason: "stop",
                            promptTokensPerSecond: 1024,
                            mtp: nil,
                            inputTokenCount: 180
                        )
                    )
                )
                producer.yield(.drained)
                producer.finish()
            }
            return stream
        }

        func execute(_ call: ServiceToolInvocation) -> String {
            executions.append(call.toolCallId ?? "missing")
            firstTail?.yield(.drained)
            firstTail?.finish()
            firstTail = nil
            return #"{"value":42}"#
        }
    }

    @Test func toolRunsBeforeDrainAndFollowupRetainsNativeItemsReasoningAndIDs() async throws {
        let script = Script()
        let toolset = AgentSubagentToolset(
            specs: [
                Tool(
                    type: "function",
                    function: ToolFunction(name: "lookup", description: nil, parameters: nil)
                )
            ],
            execute: { call in await script.execute(call) }
        )
        let result = try await AgentSubagentRunner.run(
            modelName: "responses-spawn-fixture",
            seedMessages: [ChatMessage(role: "user", content: "Look up the answer.")],
            maxTokens: 64,
            admissionPositionLimit: 8192,
            maxIterations: 3,
            deadline: Date().addingTimeInterval(5),
            sessionId: "responses-spawn-continuity",
            enableThinking: true,
            toolset: toolset,
            responsesStreamProvider: { request in await script.stream(request) }
        )
        #expect(result.exit == .finalResponse)
        #expect(result.digest == "42")
        #expect(result.usage.promptTokens == 180)
        #expect(result.usage.completionTokens == 14)
        #expect(await script.executions == ["call_fixture"])
        let requests = await script.requests
        #expect(requests.count == 2)
        for request in requests {
            #expect(request.context.admissionPositionLimit == 8192)
            #expect(request.context.backgroundModelLoad)
            #expect(request.context.preserveExistingResidencyOwner)
            #expect(request.context.samplingParametersAreImplicit)
            #expect(request.generation.temperature == nil)
            #expect(request.generation.enableThinking == true)
        }
        let followup = try #require(requests.last)
        let assistant = try #require(followup.input.first { $0.role == "assistant" })
        #expect(assistant.content == "Checking.")
        #expect(assistant.reasoning_content == "Plan.")
        #expect(assistant.reasoning_item_id == "rs_fixture")
        #expect(assistant.reasoning_encrypted == "opaque")
        #expect(assistant.responses_output_items == Script.items)
        #expect(assistant.tool_calls?.first?.id == "call_fixture")
        let tool = try #require(followup.input.first { $0.role == "tool" })
        #expect(tool.tool_call_id == "call_fixture")
        #expect(tool.content == #"{"value":42}"#)
    }

    @Test func lengthBoundaryCannotExecutePreviewedCallOrBecomeFinalDigest() async throws {
        let script = Script(incomplete: true)
        let toolset = AgentSubagentToolset(
            specs: [
                Tool(
                    type: "function",
                    function: ToolFunction(name: "lookup", description: nil, parameters: nil)
                )
            ],
            execute: { call in await script.execute(call) }
        )
        let result = try await AgentSubagentRunner.run(
            modelName: "responses-spawn-fixture",
            seedMessages: [ChatMessage(role: "user", content: "Look up the answer.")],
            maxTokens: 64,
            maxIterations: 3,
            deadline: Date().addingTimeInterval(5),
            sessionId: "responses-spawn-incomplete",
            toolset: toolset,
            responsesStreamProvider: { request in await script.stream(request) }
        )
        #expect(result.exit == .lengthExhausted)
        #expect(result.digest == nil)
        #expect(await script.executions.isEmpty)
        #expect(await script.requests.count == 1)
    }

    @Test func targetGenerationDefaultsAndTighterOutputCapSurviveEveryToolIteration() async throws {
        let settings = AgentGenerationSettings(
            topP: 0, topK: 0, minP: 0.05, repetitionPenalty: 1.1,
            frequencyPenalty: 0, presencePenalty: -0.25, seed: -7,
            stop: ["END"], enableThinking: false, reasoningEffort: "low",
            templateKwargs: ["custom": .object(["enabled": .bool(false), "value": .null])],
            speculativeDecoding: false
        )
        // A smaller target cap tightens the launcher; a larger or absent
        // target cap cannot raise it. Inspect the real rebuilt requests.
        let targetCaps: [Int?] = [32, 128, nil]
        for targetCap in targetCaps {
            let script = Script()
            let toolset = AgentSubagentToolset(
                specs: [
                    Tool(type: "function", function: ToolFunction(name: "lookup", description: nil, parameters: nil))
                ],
                execute: { call in await script.execute(call) }
            )
            let result = try await AgentSubagentRunner.run(
                modelName: "responses-spawn-fixture",
                seedMessages: [ChatMessage(role: "user", content: "Look up the answer.")],
                maxTokens: 64,
                admissionPositionLimit: 8192,
                maxIterations: 3,
                deadline: Date().addingTimeInterval(5),
                sessionId: "responses-spawn-agent-defaults",
                temperature: 0,
                agentMaxTokens: targetCap,
                generationSettings: settings,
                enableThinking: true,
                reasoningEffort: "high",
                toolset: toolset,
                responsesStreamProvider: { request in await script.stream(request) }
            )
            #expect(result.exit == .finalResponse)
            #expect(result.digest == "42")
            #expect(await script.executions == ["call_fixture"])
            let requests = await script.requests
            #expect(requests.count == 2)
            for request in requests {
                #expect(request.generation.maxOutputTokens == min(targetCap ?? 64, 64))
                #expect(request.generation.temperature == 0)
                #expect(request.generation.topP == settings.topP)
                #expect(request.generation.topK == 0)
                #expect(request.generation.minP == settings.minP)
                #expect(request.generation.repetitionPenalty == settings.repetitionPenalty)
                #expect(request.generation.frequencyPenalty == 0)
                #expect(request.generation.presencePenalty == settings.presencePenalty)
                #expect(request.generation.seed == -7)
                #expect(request.generation.stop == ["END"])
                #expect(request.generation.enableThinking == false)
                #expect(request.generation.reasoningEffort == "low")
                #expect(request.context.speculativeDecoding == false)
                #expect(request.generation.templateKwargs == settings.templateKwargs)
                #expect(request.context.agentReasoningDefaults?.settings == AgentGenerationSettings(enableThinking: false, reasoningEffort: "low"))
                let legacy = request.chatCompletionsCompatibilityRequest()
                #expect(legacy.max_tokens == request.generation.maxOutputTokens)
                #expect(legacy.top_p == 0)
                #expect(legacy.top_k == 0)
                #expect(legacy.min_p == settings.minP)
                #expect(legacy.repetition_penalty == settings.repetitionPenalty)
                #expect(legacy.frequency_penalty == 0)
                #expect(legacy.presence_penalty == settings.presencePenalty)
                #expect(legacy.seed == -7)
                #expect(legacy.stop == settings.stop)
                #expect(legacy.enable_thinking == false)
                #expect(legacy.reasoning_effort == "low")
                #expect(legacy.chat_template_kwargs == settings.templateKwargs)
            }
        }
    }

    @Test func reasoningOnlyLengthStopRemainsIncompleteWithTargetDefaults() async throws {
        let result = try await AgentSubagentRunner.run(
            modelName: "responses-spawn-fixture",
            seedMessages: [ChatMessage(role: "user", content: "Answer.")],
            maxTokens: 64,
            maxIterations: 3,
            deadline: Date().addingTimeInterval(5),
            sessionId: "responses-spawn-reasoning-length",
            agentMaxTokens: 16,
            generationSettings: AgentGenerationSettings(enableThinking: true),
            enableThinking: false,
            responsesStreamProvider: { request in
                #expect(request.generation.maxOutputTokens == 16)
                #expect(request.generation.enableThinking == true)
                return AsyncThrowingStream { producer in
                    producer.yield(.reasoningDelta("Still considering the problem."))
                    producer.yield(.responseCompleted(.init(
                        responseID: "resp_reasoning_length", status: .incomplete,
                        functionCalls: [], tokenCount: 16, tokensPerSecond: 40,
                        unclosedReasoning: true, stopReason: "length",
                        promptTokensPerSecond: nil, mtp: nil
                    )))
                    producer.yield(.drained)
                    producer.finish()
                }
            }
        )
        #expect(result.exit == .lengthExhausted)
        #expect(result.digest == nil)
        #expect(result.iterations == 1)
        #expect(result.usage.completionTokens == 16)
    }

    @Test func providerCancellationIsNotAttributedToUserParentOrDeadline() async throws {
        let result = try await AgentSubagentRunner.run(
            modelName: "responses-spawn-fixture",
            seedMessages: [ChatMessage(role: "user", content: "Answer.")],
            maxTokens: 64,
            maxIterations: 1,
            deadline: Date().addingTimeInterval(5),
            sessionId: "responses-spawn-cancelled",
            responsesStreamProvider: { _ in
                AsyncThrowingStream { c in
                    c.yield(
                        .responseCompleted(
                            .init(
                                responseID: "resp_cancelled",
                                status: .cancelled,
                                functionCalls: [],
                                tokenCount: 0,
                                tokensPerSecond: nil,
                                unclosedReasoning: false,
                                stopReason: "cancelled",
                                promptTokensPerSecond: nil,
                                mtp: nil
                            )
                        )
                    )
                    c.yield(.drained)
                    c.finish()
                }
            }
        )
        #expect(result.exit == .cancelled)
        #expect(result.cancelCause == .upstream)
        #expect(result.digest == nil)
        let error = TextSubagentKind.cancelError(cause: result.cancelCause, label: "fixture", maxElapsedSeconds: 5)
        if case .executionFailed(let message, let retryable) = error {
            #expect(message.contains("model or provider"))
            #expect(!message.contains("parent"))
            #expect(!message.contains("time budget"))
            #expect(!retryable)
        } else {
            Issue.record("Expected upstream cancellation error")
        }
    }
}
