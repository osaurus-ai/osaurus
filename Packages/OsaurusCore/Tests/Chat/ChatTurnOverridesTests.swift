import Foundation
import Testing
@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct ChatTurnOverridesTests {
    @Test func omittedAndZeroAreDistinctAndTemplateNullSurvives() throws {
        let empty = ChatTurnOverrides()
        try empty.validate()
        #expect(empty.isEmpty)
        let controls = ChatTurnOverrides(temperature: 0, topP: 0, topK: 0,
            enableThinking: false, templateKwargs: ["template": .object(["field": .null])])
        try controls.validate()
        #expect(!controls.isEmpty)
        let restored = try JSONDecoder().decode(ChatTurnOverrides.self, from: JSONEncoder().encode(controls))
        #expect(restored == controls)
        var request = ResponsesInferenceRequest(model: "test", input: [])
        controls.apply(to: &request)
        #expect(request.generation.temperature == 0)
        #expect(request.generation.topP == 0)
        #expect(request.generation.topK == 0)
        #expect(request.generation.enableThinking == false)
        #expect(request.generation.templateKwargs == controls.templateKwargs)
    }

    @Test func invalidControlsRejectBeforeDispatch() throws {
        for controls in [ChatTurnOverrides(temperature: -.infinity), .init(temperature: .nan),
            .init(topP: 1.1), .init(topK: -1), .init(reasoningEffort: "   "),
            .init(templateKwargs: ["messages": .array([])]),
            .init(templateKwargs: ["tools": .array([])]),
            .init(templateKwargs: ["add_generation_prompt": .bool(false)])] {
            #expect(throws: (any Error).self) { try controls.validate() }
        }
        try ChatTurnOverrides(templateKwargs: ["model_hint": .string("explicit"), "optional_value": .null]).validate()
    }

    @Test func rebuiltToolStepsAndCompatibilityUseFrozenControls() throws {
        var inherited = ResponsesInferenceRequest(model: "test", input: [])
        ChatTurnGenerationControls.capture(activeModelOptions: [:]).apply(to: &inherited)
        #expect(inherited.context.modelOptions == [:])
        #expect(inherited.generation.enableThinking == nil)
        var frozen = ChatTurnGenerationControls.capture(activeModelOptions: ["disableThinking": .bool(false)])
        frozen.overrides = .init(topK: 0, reasoningEffort: "high", enableThinking: false,
            templateKwargs: ["template": .object(["city": .null])])
        for _ in 0..<3 {
            var request = ResponsesInferenceRequest(model: "test", input: [])
            frozen.apply(to: &request)
            #expect(request.generation.temperature == nil)
            #expect(request.generation.topP == nil)
            #expect(request.generation.topK == 0)
            #expect(request.generation.reasoningEffort == "high")
            #expect(request.generation.enableThinking == false)
            let legacy = request.chatCompletionsCompatibilityRequest()
            let rebuilt = ResponsesInferenceRequest(chatCompletion: legacy)
            #expect(rebuilt.generation.templateKwargs == request.generation.templateKwargs)
            #expect(rebuilt.generation.topK == 0)
        }
    }

    @Test func queuedCustomControlsAreLatchedAndCannotSteerDifferentRun() async throws {
        try await ChatHistoryTestStorage.run {
            let session = ChatSession()
            session.nextTurnOverrides = .init(temperature: 0, topK: 0, templateKwargs: ["template": .object(["a": .null])])
            session.enqueueSend("queued", attachments: [])
            let captured = try #require(session.queuedSend?.generationControls)
            #expect(session.nextTurnOverrides.isEmpty)
            session.nextTurnOverrides = .init(temperature: 1.5)
            #expect(session.queuedSend?.generationControls == captured)
            #expect(!session.injectQueuedSteerIfEligible())
            #expect(session.queuedSend?.text == "queued")
            #expect(session.turns.isEmpty)
        }
    }

    @Test func nativeSendRegenerateAndFollowingTurnHaveIndependentRequests() async throws {
        try await ChatHistoryTestStorage.run {
            let engine = TurnParameterRecordingEngine()
            let session = ChatSession()
            session.forceChatEngineRouteForTests = true
            session.chatEngineFactory = { _ in engine }
            let savedAgentTemperature = AgentManager.shared.effectiveTemperature(for: Agent.defaultId)
            session.nextTurnOverrides = .init(temperature: 0, topP: 0.8, topK: 0,
                templateKwargs: ["template": .object(["city": .null])])
            session.send("Hello")
            try await waitForCompletion(session)
            let original = try #require(await engine.requests.first)
            #expect(original.generation.temperature == 0)
            #expect(original.generation.topP == 0.8)
            #expect(original.generation.topK == 0)
            #expect(session.nextTurnOverrides.isEmpty)
            #expect(AgentManager.shared.effectiveTemperature(for: Agent.defaultId) == savedAgentTemperature)
            let assistant = try #require(session.turns.last(where: { $0.role == .assistant }))
            session.activeModelOptions = ["disableThinking": .bool(true)]
            session.nextTurnOverrides = .init(temperature: 1.5, topK: 9)
            session.regenerate(turnId: assistant.id)
            try await waitForCompletion(session)
            let retry = try #require(await engine.requests.last)
            #expect(retry.generation.temperature == original.generation.temperature)
            #expect(retry.generation.topP == original.generation.topP)
            #expect(retry.generation.topK == original.generation.topK)
            #expect(retry.generation.templateKwargs == original.generation.templateKwargs)
            #expect(retry.generation.enableThinking == original.generation.enableThinking)
            #expect(session.nextTurnOverrides.temperature == 1.5)
            #expect(session.nextTurnOverrides.topK == 9)
            session.nextTurnOverrides = ChatTurnOverrides()
            session.send("Another hello")
            try await waitForCompletion(session)
            let next = try #require(await engine.requests.last)
            #expect(next.generation.temperature == savedAgentTemperature)
            #expect(next.generation.topK == nil)
            #expect(next.generation.templateKwargs == nil)
        }
    }

    @Test func queuedRequestUsesItsOwnControlsAndKeepsLaterComposerDraft() async throws {
        try await ChatHistoryTestStorage.run {
            let engine = TurnParameterRecordingEngine(holdFirst: true)
            let session = ChatSession()
            session.forceChatEngineRouteForTests = true
            session.chatEngineFactory = { _ in engine }
            session.send("First hello")
            let deadline = ContinuousClock.now + .seconds(5)
            while await engine.requests.isEmpty {
                if ContinuousClock.now >= deadline { throw NSError(domain: "ChatTurnOverridesTests", code: 2) }
                try await Task.sleep(for: .milliseconds(10))
            }
            session.nextTurnOverrides = .init(temperature: 0, topK: 0,
                templateKwargs: ["template": .object(["queued": .null])])
            session.enqueueSend("Queued hello", attachments: [])
            session.nextTurnOverrides = .init(temperature: 1.2, topK: 5)
            await engine.releaseFirst()
            // Queue removal precedes asynchronous request construction. Wait
            // for the actual second dispatch and terminal run ownership, not
            // the brief UI-idle interval between those two stages.
            while await engine.requests.count < 2 || !session.isAvailableForDispatchReattachment
                || session.queuedSend != nil {
                if ContinuousClock.now >= deadline { throw NSError(domain: "ChatTurnOverridesTests", code: 3) }
                try await Task.sleep(for: .milliseconds(10))
            }
            let requests = await engine.requests
            #expect(requests.count == 2)
            #expect(requests.last?.generation.temperature == 0)
            #expect(requests.last?.generation.topK == 0)
            #expect(requests.last?.generation.templateKwargs == ["template": .object(["queued": .null])])
            #expect(session.nextTurnOverrides.temperature == 1.2)
            #expect(session.nextTurnOverrides.topK == 5)
        }
    }

    @Test func sqliteRoundTripAndIncrementalUpdateRetainControlsWithoutChangingOldTurns() throws {
        let db = ChatHistoryDatabase()
        try db.openInMemory()
        defer { db.close() }
        let id = UUID()
        var data = ChatTurnData(role: .user, content: "extract")
        var controls = ChatTurnGenerationControls.capture(activeModelOptions: ["reasoningEffort": .string("high")])
        controls.overrides = .init(temperature: 0, topK: 0, templateKwargs: ["template": .object(["a": .null])])
        controls.hasResolvedReasoning = true
        data.generationControls = controls
        var session = ChatSessionData(id: id, turns: [data, .init(role: .assistant, content: "old")])
        try db.saveSession(session)
        var restored = try #require(db.loadSession(id: id))
        #expect(restored.turns[0].generationControls == controls)
        #expect(restored.turns[1].generationControls == nil)
        controls.overrides.templateKwargs = ["template": .object(["b": .null])]
        session.turns[0].generationControls = controls
        try db.saveSession(session)
        restored = try #require(db.loadSession(id: id))
        #expect(restored.turns[0].generationControls == controls)
        let legacyBytes = try JSONEncoder().encode(ChatTurnData(role: .user, content: "legacy"))
        #expect(try JSONDecoder().decode(ChatTurnData.self, from: legacyBytes).generationControls == nil)
        let turn = ChatTurn(role: .user, content: "saved controls")
        turn.generationControls = controls
        #expect(ChatTurn.fromPersisted(turn.toPersisted()).generationControls == controls)
    }

    @Test func workflowRequestKeepsTypedControlsWithoutUsingStringSubstitutionParameters() {
        let controls = ChatTurnOverrides(temperature: 0, topK: 0, templateKwargs: ["template": .object(["a": .null])])
        let request = DispatchRequest(prompt: "extract", parameters: ["temperature": "ordinary prompt variable"], generationOverrides: controls)
        #expect(request.generationOverrides == controls)
        #expect(request.parameters["temperature"] == "ordinary prompt variable")
        #expect(DispatchRequest(prompt: "inherit").generationOverrides == nil)
    }

    @Test func workspaceOverridesRejectBeforePrepareAndDirectExecutionReportsFailure() async throws {
        try await ChatHistoryTestStorage.run {
            let controls = ChatTurnOverrides(temperature: 0, topK: 0)
            try ChatTurnOverrides().validate(forWorkspaceAgent: true)
            try controls.validate(forWorkspaceAgent: false)
            #expect(throws: (any Error).self) { try controls.validate(forWorkspaceAgent: true) }
            let ref = WorkspaceAgentRef(workspaceId: "controls-fixture", agentAddress: "0x1111111111111111111111111111111111111111")
            let client = WorkspaceAgentRunClient.shared
            let saved = client.routerEnabled
            var prepareChecks = 0
            client.routerEnabled = { prepareChecks += 1; return false }
            defer { client.routerEnabled = saved }
            let request = DispatchRequest(prompt: "extract", target: .workspace(ref), generationOverrides: controls)
            #expect(await BackgroundTaskManager.shared.dispatchChat(request) == nil)
            #expect(prepareChecks == 0)
            let prepared = WorkspaceAgentRunClient.Prepared(ref: ref, providerId: UUID(),
                displayName: "Fixture", effectiveModel: nil, workspaceName: nil)
            let context = ExecutionContext(workspace: prepared, source: .chat)
            let engine = TurnParameterRecordingEngine()
            context.chatSession.chatEngineFactory = { _ in engine }
            let failure = await context.start(prompt: "extract", generationOverrides: controls)
            #expect(failure != nil)
            #expect(context.chatSession.lastStreamError == failure)
            #expect(context.chatSession.turns.isEmpty)
            #expect(!context.isExecuting)
            #expect(await engine.requests.isEmpty)
        }
    }

    @Test func abortedSendRestoresItsControlsWithoutReplacingANewerDraft() async throws {
        try await ChatHistoryTestStorage.run {
            let session = ChatSession()
            var controls = ChatTurnGenerationControls.capture(activeModelOptions: [:])
            controls.overrides = .init(temperature: 0, topK: 0,
                templateKwargs: ["template": .object(["field": .null])])
            session.restoreAbortedSendDraft(text: "original", attachments: [], controls: controls)
            #expect(session.input == "original")
            #expect(session.nextTurnOverrides == controls.overrides)
            session.input = ""
            session.nextTurnOverrides = .init(temperature: 1.2)
            session.restoreAbortedSendDraft(text: "original", attachments: [], controls: controls)
            #expect(session.input == "original")
            #expect(session.nextTurnOverrides.temperature == 1.2)
            session.input = "newer text"
            session.restoreAbortedSendDraft(text: "old text", attachments: [], controls: controls)
            #expect(session.input == "newer text")
        }
    }

    @Test func phoneHeldCapturedControlsDoNotConsumeALaterComposerDraft() async throws {
        try await ChatHistoryTestStorage.run {
            let session = ChatSession()
            let id = UUID()
            session.sessionId = id
            RemoteSessionContinuation.beginPhoneRun(id)
            defer { session.queuedSend = nil; RemoteSessionContinuation.endPhoneRun(id) }
            var captured = ChatTurnGenerationControls.capture(activeModelOptions: [:])
            captured.overrides = .init(temperature: 0, topK: 0)
            session.nextTurnOverrides = .init(temperature: 1.2, topK: 5)
            session.send("held", generationControls: captured)
            #expect(session.queuedSend?.generationControls == captured)
            #expect(session.nextTurnOverrides.temperature == 1.2)
            #expect(session.nextTurnOverrides.topK == 5)
            #expect(session.turns.isEmpty)
        }
    }

    @Test func invalidSavedRegenerationRestoresTheOriginalTranscript() async throws {
        try await ChatHistoryTestStorage.run {
            let session = ChatSession()
            let engine = TurnParameterRecordingEngine()
            session.forceChatEngineRouteForTests = true
            session.chatEngineFactory = { _ in engine }
            let user = ChatTurn(role: .user, content: "original")
            var invalid = ChatTurnGenerationControls.capture(activeModelOptions: [:])
            invalid.overrides = .init(topK: -1)
            user.generationControls = invalid
            let answer = ChatTurn(role: .assistant, content: "keep answer")
            session.turns = [user, answer]
            session.regenerate(turnId: answer.id)
            #expect(session.turns.map(\.id) == [user.id, answer.id])
            #expect(session.turns.map(\.content) == ["original", "keep answer"])
            #expect(session.turnParametersError != nil)
            #expect(!session.isSendActiveForComposer)
            #expect(await engine.requests.isEmpty)
        }
    }

    @Test func customAgentDefaultsAndCapsAreFrozenForQueuedWork() async throws {
        try await ChatHistoryTestStorage.run {
            var agent = Agent(name: "Generation queue fixture", temperature: 0, maxTokens: 128,
                generationSettings: .init(topP: 0.8, topK: 0, seed: 17, enableThinking: false),
                autonomousExec: AutonomousExecConfig(enabled: false), toolsEnabled: false, memoryEnabled: false)
            AgentStore.save(agent)
            AgentManager.shared.refresh()
            let session = ChatSession()
            session.agentId = agent.id
            session.enqueueSend("queued", attachments: [])
            let frozen = try #require(session.queuedSend?.generationControls)
            #expect(frozen.temperature == 0)
            #expect(frozen.maxOutputTokens == 128)
            #expect(frozen.agentDefaultsCaptured == true)
            #expect(frozen.agentSettings == agent.generationSettings)
            agent.temperature = 1.5
            agent.maxTokens = 2048
            agent.generationSettings = .init(topP: 0.9, topK: 10, seed: 23, enableThinking: true)
            AgentManager.shared.update(agent)
            #expect(session.queuedSend?.generationControls == frozen)
            let next = session.captureGenerationControls()
            #expect(next.temperature == 1.5)
            #expect(next.maxOutputTokens == 2048)
            #expect(next.agentSettings == agent.generationSettings)
        }
    }

    @Test func customAgentDefaultsReachTheRealChatDispatchAndSurviveRegeneration() async throws {
        try await ChatHistoryTestStorage.run {
            var agent = Agent(name: "Generation dispatch fixture", temperature: 0, maxTokens: 128,
                generationSettings: .init(topP: 0.8, topK: 0, minP: 0.02, repetitionPenalty: 1.1,
                    presencePenalty: 0.3, seed: 17, templateKwargs: ["format": .string("fixture")]),
                autonomousExec: AutonomousExecConfig(enabled: false), toolsEnabled: false, memoryEnabled: false)
            AgentStore.save(agent)
            AgentManager.shared.refresh()
            let engine = TurnParameterRecordingEngine()
            let session = ChatSession()
            session.agentId = agent.id
            session.forceChatEngineRouteForTests = true
            session.chatEngineFactory = { _ in engine }
            session.send("Hello")
            try await waitForCompletion(session)
            let request = try #require(await engine.requests.first)
            #expect(request.generation.temperature == 0)
            #expect(request.generation.maxOutputTokens == 128)
            #expect(request.generation.topP == 0.8)
            #expect(request.generation.topK == 0)
            #expect(request.generation.minP == 0.02)
            #expect(request.generation.repetitionPenalty == 1.1)
            #expect(request.generation.presencePenalty == 0.3)
            #expect(request.generation.seed == 17)
            #expect(request.generation.templateKwargs == agent.generationSettings?.templateKwargs)
            let assistant = try #require(session.turns.last(where: { $0.role == .assistant }))
            agent.temperature = 1.5
            agent.maxTokens = 1024
            agent.generationSettings = nil
            AgentManager.shared.update(agent)
            session.regenerate(turnId: assistant.id)
            try await waitForCompletion(session)
            let retry = try #require(await engine.requests.last)
            #expect(retry.generation.temperature == request.generation.temperature)
            #expect(retry.generation.maxOutputTokens == request.generation.maxOutputTokens)
            #expect(retry.generation.topK == request.generation.topK)
            #expect(retry.generation.seed == request.generation.seed)
            #expect(retry.generation.templateKwargs == request.generation.templateKwargs)
        }
    }

    private func waitForCompletion(_ session: ChatSession) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while session.isSendActiveForComposer || session.turns.last?.role == .user {
            if ContinuousClock.now >= deadline { throw NSError(domain: "ChatTurnOverridesTests", code: 1) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private actor TurnParameterRecordingEngine: ChatEngineProtocol {
    var requests: [ResponsesInferenceRequest] = []
    let holdFirst: Bool
    private var held: AsyncThrowingStream<ResponsesGenerationEvent, Error>.Continuation?
    init(holdFirst: Bool = false) { self.holdFirst = holdFirst }
    func streamResponses(request: ResponsesInferenceRequest) async throws -> AsyncThrowingStream<ResponsesGenerationEvent, Error> {
        requests.append(request)
        let stream = AsyncThrowingStream<ResponsesGenerationEvent, Error>.makeStream()
        if holdFirst && requests.count == 1 { held = stream.continuation }
        else { Self.finish(stream.continuation) }
        return stream.stream
    }
    func releaseFirst() {
        if let held { Self.finish(held) }
        held = nil
    }
    private nonisolated static func finish(_ continuation: AsyncThrowingStream<ResponsesGenerationEvent, Error>.Continuation) {
        continuation.yield(.outputTextDelta("Hello."))
        continuation.yield(.responseCompleted(.init(responseID: UUID().uuidString, status: .completed,
            functionCalls: [], tokenCount: 2, tokensPerSecond: 10, unclosedReasoning: false,
            stopReason: "stop", promptTokensPerSecond: nil, mtp: nil)))
        continuation.yield(.drained)
        continuation.finish()
    }
    func streamChat(request: ChatCompletionRequest) async throws -> AsyncThrowingStream<String, Error> {
        throw NSError(domain: "ChatTurnOverridesTests.unexpectedLegacy", code: 1)
    }
    func completeChat(request: ChatCompletionRequest) async throws -> ChatCompletionResponse {
        throw NSError(domain: "ChatTurnOverridesTests.unexpectedLegacy", code: 2)
    }
}
