import Foundation
import Testing

@testable import OsaurusCore

struct AgentReasoningDefaultsGuardTests {
    private actor Capture {
        var choiceModels: [String] = []
        var parameters: [GenerationParameters] = []
        var remoteLookups = 0

        func resolved(_ model: String) { choiceModels.append(model) }
        func executed(_ value: GenerationParameters) { parameters.append(value) }
        func fetchedRemoteServices() { remoteLookups += 1 }
    }

    private struct Service: ModelService {
        let id: String
        let capture: Capture
        var acceptsDefault = false

        func isAvailable() -> Bool { true }
        func handles(requestedModel: String?) -> Bool {
            requestedModel == id || (acceptsDefault && requestedModel == "default")
        }
        func generateOneShot(messages: [ChatMessage], parameters: GenerationParameters,
            requestedModel: String?) async throws -> String
        {
            await capture.executed(parameters)
            return "ok"
        }
        func streamDeltas(messages: [ChatMessage], parameters: GenerationParameters,
            requestedModel: String?, stopSequences: [String]) async throws -> AsyncThrowingStream<String, Error>
        {
            await capture.executed(parameters)
            return AsyncThrowingStream { producer in
                producer.yield("ok")
                producer.finish()
            }
        }
    }

    private static let efforts = ModelReasoningCapabilities(
        levels: ["low", "medium", "xhigh"].map { .init(id: $0) }, defaultLevelId: "xhigh")

    private func makeEngine(capture: Capture, services: [ModelService], remote: [ModelService] = [],
        supportsThinking: Bool = false) -> ChatEngine
    {
        ChatEngine(
            services: services,
            installedModelsProvider: { [] },
            remoteServicesProvider: {
                await capture.fetchedRemoteServices()
                return remote
            },
            reasoningCapabilityProvider: { _ in .none },
            agentModelOptionsProvider: { _ in [:] },
            agentReasoningChoicesProvider: { model, _ in
                await capture.resolved(model)
                return AgentGenerationReasoningChoices(modelID: model,
                    efforts: Self.efforts, supportsThinking: supportsThinking)
            }
        )
    }

    private func request(model: String = "saved-agent-fixture", settings: AgentGenerationSettings,
        overrides: ChatTurnOverrides = .init()) -> ResponsesInferenceRequest
    {
        var controls = ChatTurnGenerationControls.capture(activeModelOptions: [:])
        controls.agentSettings = settings
        controls.overrides = overrides
        var request = ResponsesInferenceRequest(model: model,
            input: [ChatMessage(role: "user", content: "Answer.")])
        controls.apply(to: &request)
        return request
    }

    @Test("only unshadowed saved-agent reasoning fields carry host provenance")
    func provenanceAndCompatibility() throws {
        let settings = AgentGenerationSettings(topK: 0, enableThinking: false, reasoningEffort: "high")
        let original = request(settings: settings)
        #expect(original.context.agentReasoningDefaults?.settings == AgentGenerationSettings(enableThinking: false, reasoningEffort: "high"))
        let effortOverride = request(settings: settings, overrides: .init(reasoningEffort: "xhigh"))
        #expect(effortOverride.context.agentReasoningDefaults?.settings == AgentGenerationSettings(enableThinking: false))
        let thinkingOverride = request(settings: settings, overrides: .init(enableThinking: true))
        #expect(thinkingOverride.context.agentReasoningDefaults?.settings == AgentGenerationSettings(reasoningEffort: "high"))
        let both = request(settings: settings, overrides: .init(reasoningEffort: "xhigh", enableThinking: true))
        #expect(both.context.agentReasoningDefaults == nil)
        #expect(request(settings: .init(topK: 0)).context.agentReasoningDefaults == nil)
        let restored = ResponsesInferenceRequest(chatCompletion: original.chatCompletionsCompatibilityRequest())
        #expect(restored.context.agentReasoningDefaults == original.context.agentReasoningDefaults)
        // Host-only context is absent from the public request encoding.
        let wire = String(decoding: try JSONEncoder().encode(original.chatCompletionsCompatibilityRequest()), as: UTF8.self)
        #expect(!wire.contains("agentReasoningDefaults"))
    }

    @Test("a stale saved effort is rejected rather than snapped after a model switch")
    func rejectsUnsupportedSavedEffortBeforeService() async throws {
        let capture = Capture()
        let service = Service(id: "saved-agent-fixture", capture: capture)
        let engine = makeEngine(capture: capture, services: [service])
        let stale = request(settings: .init(reasoningEffort: "high"))
        do {
            _ = try await engine.completeChat(request: stale.chatCompletionsCompatibilityRequest())
            Issue.record("Unsupported saved effort must not reach inference")
        } catch {
            #expect(error.localizedDescription.contains("does not advertise reasoning effort 'high'"))
        }
        #expect(await capture.choiceModels == ["saved-agent-fixture"])
        #expect(await capture.parameters.isEmpty)
        #expect(await capture.remoteLookups == 0)
    }

    @Test("unsupported saved Thinking is rejected before inference")
    func rejectsUnsupportedThinking() async throws {
        let capture = Capture()
        let service = Service(id: "saved-agent-fixture", capture: capture)
        let engine = makeEngine(capture: capture, services: [service])
        do {
            _ = try await engine.streamResponses(request: request(settings: .init(enableThinking: false)))
            Issue.record("Unsupported saved Thinking must not reach inference")
        } catch {
            #expect(error.localizedDescription.contains("does not advertise a Thinking switch"))
        }
        #expect(await capture.parameters.isEmpty)
    }

    @Test("accepted defaults remain exact and explicit turn overrides replace stale values")
    func acceptedAndShadowedDefaults() async throws {
        let capture = Capture()
        let service = Service(id: "saved-agent-fixture", capture: capture)
        let engine = makeEngine(capture: capture, services: [service], supportsThinking: true)
        let accepted = request(settings: .init(enableThinking: false, reasoningEffort: "xhigh"))
        _ = try await engine.completeChat(request: accepted.chatCompletionsCompatibilityRequest())
        var parameters = await capture.parameters
        #expect(parameters.last?.modelOptions["reasoningEffort"]?.stringValue == "xhigh")
        #expect(parameters.last?.modelOptions["disableThinking"]?.boolValue == true)
        let shadowed = request(settings: .init(reasoningEffort: "high"), overrides: .init(reasoningEffort: "medium"))
        _ = try await engine.completeChat(request: shadowed.chatCompletionsCompatibilityRequest())
        parameters = await capture.parameters
        #expect(parameters.last?.modelOptions["reasoningEffort"]?.stringValue == "medium")
        #expect(await capture.choiceModels == ["saved-agent-fixture"])
    }

    @Test("requests without saved-agent provenance retain legacy input behavior")
    func unmarkedRequestsDoNotResolveOrValidateAgentChoices() async throws {
        let capture = Capture()
        let service = Service(id: "saved-agent-fixture", capture: capture)
        let engine = makeEngine(capture: capture, services: [service])
        var unmarked = ResponsesInferenceRequest(model: service.id,
            input: [ChatMessage(role: "user", content: "Answer.")])
        unmarked.generation.reasoningEffort = "high"
        _ = try await engine.completeChat(request: unmarked.chatCompletionsCompatibilityRequest())
        #expect(await capture.choiceModels.isEmpty)
        #expect(await capture.parameters.last?.modelOptions["reasoningEffort"]?.stringValue == "high")
    }

    @Test("validation uses the router's effective identity and preserves local-first remote lookup ownership")
    func authoritativeRouteIdentity() async throws {
        let localCapture = Capture()
        let local = Service(id: "default-service", capture: localCapture, acceptsDefault: true)
        let localEngine = makeEngine(capture: localCapture, services: [local])
        _ = try await localEngine.completeChat(request: request(model: "default", settings: .init(reasoningEffort: "xhigh"))
            .chatCompletionsCompatibilityRequest())
        #expect(await localCapture.choiceModels == ["foundation"])
        #expect(await localCapture.remoteLookups == 0)
        #expect(await localCapture.parameters.count == 1)

        let remoteCapture = Capture()
        let remote = Service(id: "provider/saved-agent-fixture", capture: remoteCapture)
        let remoteEngine = makeEngine(capture: remoteCapture, services: [], remote: [remote])
        _ = try await remoteEngine.completeChat(request: request(model: remote.id, settings: .init(reasoningEffort: "medium"))
            .chatCompletionsCompatibilityRequest())
        #expect(await remoteCapture.choiceModels == [remote.id])
        #expect(await remoteCapture.remoteLookups == 1)
        #expect(await remoteCapture.parameters.count == 1)
    }

    @Test("a remote agent's log label is not an authoritative model contract")
    func remoteAgentHostOwnsItsContract() async throws {
        let capture = Capture()
        let service = Service(id: "saved-agent-fixture", capture: capture)
        let engine = makeEngine(capture: capture, services: [service])
        var remoteAgent = request(settings: .init(reasoningEffort: "xhigh"))
        remoteAgent.context.runAsRemoteAgent = true
        remoteAgent.context.remoteAgentLogModel = "host-reported-label"
        do {
            _ = try await engine.completeChat(request: remoteAgent.chatCompletionsCompatibilityRequest())
            Issue.record("The host's effective model cannot be guessed from a label")
        } catch {
            #expect(error.localizedDescription.contains("remote agent's host"))
        }
        #expect(await capture.choiceModels.isEmpty)
        #expect(await capture.parameters.isEmpty)
    }
}
