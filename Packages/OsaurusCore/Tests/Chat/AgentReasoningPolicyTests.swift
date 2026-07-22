//
//  AgentReasoningPolicyTests.swift
//  osaurusTests
//

import Testing

@testable import OsaurusCore

@Suite("Agent reasoning policy")
struct AgentReasoningPolicyTests {
    private let toggleableDefaultOn = LocalReasoningCapability.Capability(
        supportsThinking: true,
        hasEnableThinkingKwarg: true,
        templateInjectsThinkTag: true,
        defaultThinkingOn: true
    )
    private let toggleableDefaultOff = LocalReasoningCapability.Capability(
        supportsThinking: true,
        hasEnableThinkingKwarg: true,
        templateInjectsThinkTag: false,
        defaultThinkingOn: false
    )

    @Test("unset ordinary chat preserves opposite bundle defaults")
    func ordinaryChatPreservesBundleDefault() {
        for capability in [toggleableDefaultOn, toggleableDefaultOff] {
            #expect(
                AgentReasoningPolicy.defaultEnableThinking(
                    isAgentOrToolRequest: false,
                    explicitEnableThinking: nil,
                    explicitReasoningEffort: nil,
                    modelOptions: [:],
                    usesReasoningEffortControl: false,
                    capability: capability
                ) == nil
            )
        }
    }

    @Test("unset agent/tool run selects direct rail for any toggleable template")
    func unsetAgentDefaultsThinkingOff() {
        for capability in [toggleableDefaultOn, toggleableDefaultOff] {
            #expect(
                AgentReasoningPolicy.defaultEnableThinking(
                    isAgentOrToolRequest: true,
                    explicitEnableThinking: nil,
                    explicitReasoningEffort: nil,
                    modelOptions: [:],
                    usesReasoningEffortControl: false,
                    capability: capability
                ) == false
            )
        }
    }

    @Test("explicit API and UI choices win in both directions")
    func explicitChoicesWin() {
        for enabled in [false, true] {
            #expect(
                AgentReasoningPolicy.defaultEnableThinking(
                    isAgentOrToolRequest: true,
                    explicitEnableThinking: enabled,
                    explicitReasoningEffort: nil,
                    modelOptions: [:],
                    usesReasoningEffortControl: false,
                    capability: toggleableDefaultOn
                ) == enabled
            )
            #expect(
                AgentReasoningPolicy.defaultEnableThinking(
                    isAgentOrToolRequest: true,
                    explicitEnableThinking: nil,
                    explicitReasoningEffort: nil,
                    modelOptions: ["disableThinking": .bool(!enabled)],
                    usesReasoningEffortControl: false,
                    capability: toggleableDefaultOn
                ) == enabled
            )
        }
    }

    @Test("explicit reasoning effort blocks the agent default")
    func reasoningEffortWins() {
        #expect(
            AgentReasoningPolicy.defaultEnableThinking(
                isAgentOrToolRequest: true,
                explicitEnableThinking: nil,
                explicitReasoningEffort: "high",
                modelOptions: [:],
                usesReasoningEffortControl: false,
                capability: toggleableDefaultOn
            ) == nil
        )
        #expect(
            AgentReasoningPolicy.defaultEnableThinking(
                isAgentOrToolRequest: true,
                explicitEnableThinking: nil,
                explicitReasoningEffort: nil,
                modelOptions: ["reasoningEffort": .string("max")],
                usesReasoningEffortControl: false,
                capability: toggleableDefaultOn
            ) == nil
        )
    }

    @Test("non-toggleable models receive no synthetic kwarg")
    func nonToggleableIsUntouched() {
        #expect(
            AgentReasoningPolicy.defaultEnableThinking(
                isAgentOrToolRequest: true,
                explicitEnableThinking: nil,
                explicitReasoningEffort: nil,
                modelOptions: [:],
                usesReasoningEffortControl: false,
                capability: .none
            ) == nil
        )
    }

    @Test("dedicated reasoning-effort profiles stay off the boolean rail")
    func reasoningEffortProfileIsUntouched() {
        #expect(
            AgentReasoningPolicy.defaultEnableThinking(
                isAgentOrToolRequest: true,
                explicitEnableThinking: nil,
                explicitReasoningEffort: nil,
                modelOptions: [:],
                usesReasoningEffortControl: true,
                capability: toggleableDefaultOn
            ) == nil
        )
    }

    @Test("presentation matches dispatch while preserving ordinary bundle default")
    func presentationMatchesDispatch() {
        #expect(
            AgentReasoningPolicy.effectiveEnableThinkingForPresentation(
                isAgentOrToolRequest: false,
                modelOptions: [:],
                capability: toggleableDefaultOn
            )
        )
        #expect(
            !AgentReasoningPolicy.effectiveEnableThinkingForPresentation(
                isAgentOrToolRequest: true,
                modelOptions: [:],
                capability: toggleableDefaultOn
            )
        )
        #expect(
            AgentReasoningPolicy.effectiveEnableThinkingForPresentation(
                isAgentOrToolRequest: true,
                modelOptions: ["disableThinking": .bool(false)],
                capability: toggleableDefaultOn
            )
        )
        #expect(
            !AgentReasoningPolicy.effectiveEnableThinkingForPresentation(
                isAgentOrToolRequest: true,
                modelOptions: ["disableThinking": .bool(true)],
                capability: toggleableDefaultOn
            )
        )
    }
}

@Suite("Agent reasoning dispatch")
struct AgentReasoningDispatchTests {
    private actor Capture {
        var parameters: GenerationParameters?
        func set(_ parameters: GenerationParameters) { self.parameters = parameters }
    }

    private struct CaptureService: ModelService {
        let capture: Capture
        let id: String
        func isAvailable() -> Bool { true }
        func handles(requestedModel: String?) -> Bool { requestedModel == id }
        func generateOneShot(
            messages: [ChatMessage],
            parameters: GenerationParameters,
            requestedModel: String?
        ) async throws -> String {
            await capture.set(parameters)
            return "ok"
        }
        func streamDeltas(
            messages: [ChatMessage],
            parameters: GenerationParameters,
            requestedModel: String?,
            stopSequences: [String]
        ) async throws -> AsyncThrowingStream<String, Error> {
            await capture.set(parameters)
            return AsyncThrowingStream { continuation in
                continuation.yield("ok")
                continuation.finish()
            }
        }
    }

    private var toggleableDefaultOn: LocalReasoningCapability.Capability {
        LocalReasoningCapability.Capability(
            supportsThinking: true,
            hasEnableThinkingKwarg: true,
            templateInjectsThinkTag: true,
            defaultThinkingOn: true
        )
    }

    private func request(
        model: String = "ornith-fixture",
        tools: [Tool]? = nil,
        toolChoice: ToolChoiceOption? = nil
    ) -> ChatCompletionRequest {
        ChatCompletionRequest(
            model: model,
            messages: [ChatMessage(role: "user", content: "hi")],
            temperature: nil,
            max_tokens: 32,
            stream: false,
            top_p: nil,
            frequency_penalty: nil,
            presence_penalty: nil,
            stop: nil,
            n: nil,
            tools: tools,
            tool_choice: toolChoice,
            session_id: nil
        )
    }

    private var fixtureTool: Tool {
        Tool(
            type: "function",
            function: ToolFunction(
                name: "fixture",
                description: "fixture",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([:]),
                ])
            )
        )
    }

    @Test("shared dispatch distinguishes agent, enabled tools, and tool_choice none")
    func dispatchPolicy() async throws {
        let capture = Capture()
        let capability = toggleableDefaultOn
        let engine = ChatEngine(
            services: [CaptureService(capture: capture, id: "ornith-fixture")],
            installedModelsProvider: { [] },
            reasoningCapabilityProvider: { _ in capability }
        )

        var ordinary = request()
        _ = try await engine.completeChat(request: ordinary)
        #expect(await capture.parameters?.modelOptions["disableThinking"] == nil)

        ordinary = request(tools: [fixtureTool], toolChoice: ToolChoiceOption.none)
        _ = try await engine.completeChat(request: ordinary)
        #expect(await capture.parameters?.modelOptions["disableThinking"] == nil)

        var agentFinalizer = request()
        agentFinalizer.isAgentRequest = true
        _ = try await engine.completeChat(request: agentFinalizer)
        #expect(await capture.parameters?.modelOptions["disableThinking"]?.boolValue == true)

        let enabledTools = request(tools: [fixtureTool], toolChoice: .auto)
        _ = try await engine.completeChat(request: enabledTools)
        #expect(await capture.parameters?.modelOptions["disableThinking"]?.boolValue == true)

        var explicitOn = agentFinalizer
        explicitOn.enable_thinking = true
        _ = try await engine.completeChat(request: explicitOn)
        #expect(await capture.parameters?.modelOptions["disableThinking"]?.boolValue == false)

        var explicitModelOptionOn = agentFinalizer
        explicitModelOptionOn.modelOptions = ["disableThinking": .bool(false)]
        _ = try await engine.completeChat(request: explicitModelOptionOn)
        #expect(await capture.parameters?.modelOptions["disableThinking"]?.boolValue == false)

        var remoteAgent = agentFinalizer
        remoteAgent.runAsRemoteAgent = true
        _ = try await engine.completeChat(request: remoteAgent)
        #expect(await capture.parameters?.modelOptions["disableThinking"] == nil)
    }

    @Test("DSV4 agent default stays on its dedicated effort rail")
    func dsv4DispatchDoesNotSynthesizeBooleanThinking() async throws {
        let model = "dealign.ai/DeepSeek-V4-Flash-JANG-CRACK"
        let capture = Capture()
        let capability = toggleableDefaultOn
        let engine = ChatEngine(
            services: [CaptureService(capture: capture, id: model)],
            installedModelsProvider: { [] },
            reasoningCapabilityProvider: { _ in capability }
        )

        var agent = request(model: model)
        agent.isAgentRequest = true
        _ = try await engine.completeChat(request: agent)
        #expect(await capture.parameters?.modelOptions["disableThinking"] == nil)
        #expect(await capture.parameters?.modelOptions["reasoningEffort"] == nil)
    }

    @Test("chat UI agents load persisted model choice without leaking it to ordinary or remote requests")
    func chatUIAgentLoadsPersistedChoiceOnly() async throws {
        let capture = Capture()
        let capability = toggleableDefaultOn
        let engine = ChatEngine(
            services: [CaptureService(capture: capture, id: "ornith-fixture")],
            installedModelsProvider: { [] },
            reasoningCapabilityProvider: { _ in capability },
            agentModelOptionsProvider: { _ in ["disableThinking": .bool(false)] },
            source: .chatUI
        )

        _ = try await engine.completeChat(request: request())
        #expect(await capture.parameters?.modelOptions["disableThinking"] == nil)

        var localAgent = request()
        localAgent.isAgentRequest = true
        _ = try await engine.completeChat(request: localAgent)
        #expect(await capture.parameters?.modelOptions["disableThinking"]?.boolValue == false)

        var remoteAgent = localAgent
        remoteAgent.runAsRemoteAgent = true
        _ = try await engine.completeChat(request: remoteAgent)
        #expect(await capture.parameters?.modelOptions["disableThinking"] == nil)
    }
}
