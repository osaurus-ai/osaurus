import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct ChatModelControlsTests {
    private let model = "fixture-org/fixture-model"
    private var key: String { ChatModelControls.key(for: model) }

    private func savedAgent() -> Agent {
        let agent = Agent(name: "Conversation controls", temperature: 0.23, maxTokens: 321,
            generationSettings: .init(topP: 0.81, topK: 17, minP: 0.04,
                repetitionPenalty: 1.1, frequencyPenalty: 0.2, presencePenalty: 0.3,
                seed: 42, stop: ["END"], reasoningEffort: "low",
                templateKwargs: ["extraction_schema": .string("kept")], speculativeDecoding: false),
            autonomousExec: .init(enabled: false))
        AgentStore.save(agent)
        AgentManager.shared.refresh()
        return agent
    }

    private func session(for agent: Agent) -> ChatSession {
        let session = ChatSession()
        session.agentId = agent.id
        session.selectedModel = model
        return session
    }

    @Test("chat On/None overrides saved Off/Light without changing another chat or defaults")
    func twoChatsAndSavedDefaults() async throws {
        try await ChatHistoryTestStorage.run {
            let agent = savedAgent()
            let before = try JSONEncoder.osaurusCanonical(prettyPrinted: false).encode(AgentStore.load(id: agent.id))
            let first = session(for: agent)
            let second = session(for: agent)
            let server = ServerController.runtimeSettingsForConfigureTool().settings
            let options = ModelOptionsStore.shared.storedExplicitOptions(for: model)
            first.updateModelControls([key: .init(reasoningEffort: "none", speculativeDecoding: true)])

            let controls = first.captureGenerationControls()
            #expect(controls.agentSettings?.speculativeDecoding == true)
            #expect(controls.reasoningEffort == "none")
            #expect(second.captureGenerationControls().agentSettings?.speculativeDecoding == false)
            #expect(second.captureGenerationControls().reasoningEffort == "low")
            #expect(try JSONEncoder.osaurusCanonical(prettyPrinted: false).encode(AgentStore.load(id: agent.id)) == before)
            #expect(ServerController.runtimeSettingsForConfigureTool().settings == server)
            #expect(ModelOptionsStore.shared.storedExplicitOptions(for: model) == options)

            var request = ResponsesInferenceRequest(model: model, input: [])
            controls.apply(to: &request)
            #expect(request.context.speculativeDecoding == true)
            #expect(request.generation.reasoningEffort == "none")
            #expect(request.generation.temperature == 0.23)
            #expect(request.generation.topP == 0.81)
            #expect(request.generation.topK == 17)
            #expect(request.generation.minP == 0.04)
            #expect(request.generation.repetitionPenalty == 1.1)
            #expect(request.generation.frequencyPenalty == 0.2)
            #expect(request.generation.presencePenalty == 0.3)
            #expect(request.generation.seed == 42)
            #expect(request.generation.stop == ["END"])
            #expect(request.generation.templateKwargs == ["extraction_schema": .string("kept")])
            #expect(controls.maxOutputTokens == 321)
        }
    }

    @Test("reset inherits current saved values; full model IDs do not collide")
    func resetAndModelSwitch() async throws {
        try await ChatHistoryTestStorage.run {
            let agent = savedAgent()
            let chat = session(for: agent)
            chat.updateModelControls([key: .init(enableThinking: false, speculativeDecoding: true),
                "another-org/fixture-model": .init(reasoningEffort: "high", speculativeDecoding: false)])
            chat.selectedModel = "FIXTURE-ORG/FIXTURE-MODEL"
            #expect(chat.captureGenerationControls().agentSettings?.enableThinking == false)
            #expect(chat.captureGenerationControls().agentSettings?.speculativeDecoding == true)
            chat.selectedModel = "another-org/fixture-model"
            #expect(chat.captureGenerationControls().reasoningEffort == "high")
            #expect(chat.captureGenerationControls().agentSettings?.speculativeDecoding == false)
            chat.selectedModel = model
            chat.updateModelControls([key: .init(speculativeDecoding: true)])
            #expect(chat.captureGenerationControls().reasoningEffort == "low")
            #expect(chat.captureGenerationControls().agentSettings?.speculativeDecoding == true)
            chat.updateModelControls([:])
            #expect(chat.captureGenerationControls().agentSettings == agent.generationSettings)
        }
    }

    @Test("reasoning kind replaces aliases and preserves unrelated template and sampling fields")
    func reasoningAliases() {
        let saved = AgentGenerationSettings(topK: 9, enableThinking: true, reasoningEffort: "high",
            templateKwargs: ["enable_thinking": .bool(true), "thinking": .bool(true),
                "reasoning_effort": .string("high"), "custom": .string("kept")])
        let thinking = ChatModelControls(enableThinking: false).applying(to: saved)
        #expect(thinking?.enableThinking == false)
        #expect(thinking?.reasoningEffort == nil)
        #expect(thinking?.templateKwargs == ["custom": .string("kept")])
        #expect(thinking?.topK == 9)
        let effort = ChatModelControls(reasoningEffort: "none").applying(to: saved)
        #expect(effort?.enableThinking == nil && effort?.reasoningEffort == "none")
        #expect(effort?.templateKwargs == ["custom": .string("kept")])
        #expect(saved.enableThinking == true && saved.reasoningEffort == "high")
        #expect(ChatModelControls(speculativeDecoding: false).applying(to: saved)?.templateKwargs == saved.templateKwargs)
        #expect(ChatModelControls().applying(to: nil) == nil)
    }

    @Test("queued turn and all reconstructed requests keep captured choices after UI edits")
    func queuedCapture() async throws {
        try await ChatHistoryTestStorage.run {
            let agent = savedAgent()
            let chat = session(for: agent)
            chat.updateModelControls([key: .init(reasoningEffort: "none", speculativeDecoding: true)])
            chat.enqueueSend("Use the queued choices", attachments: [])
            let held = try #require(chat.queuedSend?.generationControls)
            chat.updateModelControls([key: .init(enableThinking: true, speculativeDecoding: false)])
            #expect(!chat.captureGenerationControls().matchesForSteering(held))
            let restored = try JSONDecoder().decode(ChatTurnGenerationControls.self, from: JSONEncoder().encode(held))
            for _ in 0..<3 {
                var request = ResponsesInferenceRequest(model: model, input: [])
                restored.apply(to: &request)
                #expect(request.context.speculativeDecoding == true)
                #expect(request.generation.reasoningEffort == "none")
                #expect(request.generation.topK == 17)
            }
            #expect(AgentStore.load(id: agent.id)?.generationSettings == agent.generationSettings)
        }
    }

    @Test("per-submission controls override chat reasoning without changing subsequent defaults")
    func oneSubmissionPrecedence() async throws {
        try await ChatHistoryTestStorage.run {
            let agent = savedAgent()
            let chat = session(for: agent)
            chat.updateModelControls([key: .init(reasoningEffort: "none", speculativeDecoding: true)])
            let controls = chat.captureGenerationControls(overrides: .init(topP: 0.4, reasoningEffort: "medium"))
            var request = ResponsesInferenceRequest(model: model, input: [])
            controls.apply(to: &request)
            #expect(request.generation.reasoningEffort == "medium")
            #expect(request.generation.topP == 0.4)
            #expect(request.context.speculativeDecoding == true)
            #expect(chat.captureGenerationControls().reasoningEffort == "none")
            #expect(AgentStore.load(id: agent.id)?.generationSettings?.reasoningEffort == "low")
        }
    }

    @Test("conversation controls survive JSON and SQLite reopen; legacy sessions inherit")
    func persistence() async throws {
        try await ChatHistoryTestStorage.run {
            let values: [String: ChatModelControls] = [key: .init(enableThinking: false, speculativeDecoding: false),
                "second/model": .init(reasoningEffort: "none", speculativeDecoding: true)]
            let data = ChatSessionData(selectedModel: model,
                turns: [ChatTurnData(id: UUID(), role: .user, content: "preserved history")], modelControls: values)
            let roundTrip = try JSONDecoder().decode(ChatSessionData.self, from: JSONEncoder().encode(data))
            #expect(roundTrip.modelControls == values)
            let db = ChatHistoryDatabase()
            try db.open()
            try db.saveSession(data)
            db.close()
            try db.open()
            defer { db.close() }
            let loaded = try #require(db.loadSession(id: data.id))
            #expect(loaded.modelControls == values)
            #expect(loaded.turns.first?.content == "preserved history")
            let chat = ChatSession()
            chat.load(from: loaded)
            #expect(chat.modelControls == values)
            chat.reset()
            #expect(chat.modelControls.isEmpty)
            let legacy = ChatSessionData(turns: [])
            let legacyBytes = try JSONEncoder().encode(legacy)
            #expect(try JSONDecoder().decode(ChatSessionData.self, from: legacyBytes).modelControls == nil)
            chat.load(from: legacy)
            #expect(chat.modelControls.isEmpty)
        }
    }

    @Test("actual ChatSession.send forwards the conversation choice with saved sampling")
    func sendForwardsControls() async throws {
        try await ChatHistoryTestStorage.run {
            let agent = savedAgent()
            let chat = session(for: agent)
            let engine = ConversationControlsCaptureEngine()
            chat.chatEngineFactory = { _ in engine }
            chat.updateModelControls([key: .init(reasoningEffort: "none", speculativeDecoding: true)])
            chat.send("Use this conversation's choices.")
            let deadline = ContinuousClock.now + .seconds(10)
            while await engine.request == nil, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            let request = try #require(await engine.request)
            #expect(request.inferenceContext.speculativeDecoding == true)
            #expect(request.reasoning_effort == "none")
            #expect(request.temperature == 0.23 && request.max_tokens == 321)
            #expect(request.top_p == 0.81 && request.top_k == 17)
            while chat.isStreaming, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(!chat.isStreaming)
            #expect(AgentStore.load(id: agent.id)?.generationSettings == agent.generationSettings)
        }
    }
}

private actor ConversationControlsCaptureEngine: ChatEngineProtocol {
    private(set) var request: ChatCompletionRequest?
    func streamChat(request: ChatCompletionRequest) async throws -> AsyncThrowingStream<String, Error> {
        self.request = request
        return AsyncThrowingStream { continuation in
            continuation.yield("ok")
            continuation.finish()
        }
    }
    func completeChat(request _: ChatCompletionRequest) async throws -> ChatCompletionResponse {
        throw NSError(domain: "ChatModelControlsTests", code: 1)
    }
}
