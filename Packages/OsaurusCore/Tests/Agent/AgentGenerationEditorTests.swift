import Foundation
import Testing

@testable import OsaurusCore

struct AgentGenerationEditorTests {
    @Test("enabling custom JSON starts with the inherited no-override values")
    func customJSONStartsWithInheritedValues() throws {
        var draft = AgentGenerationDraft()
        draft.stop.setCustom(true, inheritedText: "[]")
        draft.templateKwargs.setCustom(true, inheritedText: "{}")
        #expect(draft.stop.text == "[]")
        #expect(draft.templateKwargs.text == "{}")
        let values = try draft.validated()
        #expect(values.settings?.stop == [])
        #expect(values.settings?.templateKwargs == [:])
        draft.stop.setCustom(false)
        draft.templateKwargs.setCustom(false)
        #expect(try draft.validated().settings == nil)
    }

    @Test("custom toggles preserve existing JSON edits and saved values")
    func customJSONPreservesEdits() throws {
        var draft = AgentGenerationDraft(settings: .init(stop: ["END"],
            templateKwargs: ["template": .object(["city": .null])]))
        let saved = try draft.validated().settings
        let original = draft
        draft.stop.setCustom(false)
        draft.templateKwargs.setCustom(false)
        draft.stop.setCustom(true, inheritedText: "[]")
        draft.templateKwargs.setCustom(true, inheritedText: "{}")
        #expect(draft == original)
        #expect(try draft.validated().settings == saved)
        draft.templateKwargs.text = "{invalid JSON"
        draft.templateKwargs.setCustom(false)
        draft.templateKwargs.setCustom(true, inheritedText: "{}")
        #expect(draft.templateKwargs.text == "{invalid JSON")
        #expect(throws: (any Error).self) { try draft.validated() }
    }

    @Test("blank custom JSON validation names the visible Inherit choice")
    func blankJSONValidationUsesCustomLabel() throws {
        for field in ["Template parameters", "Stop sequences"] {
            var value = AgentGenerationFieldDraft()
            value.isCustom = true
            value.text = " \n "
            do {
                _ = try value.value(named: field)
                Issue.record("Blank custom JSON must not save")
            } catch {
                #expect(error.localizedDescription ==
                    "Enter a value for \(field), or select Inherit to use defaults.")
            }
        }
    }

    @Test("inherit and explicit zero/false survive the agent editor")
    func draftRoundTrip() throws {
        let settings = AgentGenerationSettings(topP: 0, topK: 0, minP: 0,
            repetitionPenalty: 1, presencePenalty: 0, seed: 0, stop: [],
            enableThinking: false, reasoningEffort: "xhigh",
            templateKwargs: ["template": .object(["city": .null])])
        let draft = AgentGenerationDraft(temperature: 0, maxTokens: 128, settings: settings)
        let values = try draft.validated()
        #expect(values.temperature == 0)
        #expect(values.maxTokens == 128)
        #expect(values.settings == settings)
        let inherited = try AgentGenerationDraft().validated()
        #expect(inherited.temperature == nil)
        #expect(inherited.maxTokens == nil)
        #expect(inherited.settings == nil)
    }

    @Test("invalid custom text never becomes an inherited setting")
    func invalidCustomValuesReject() throws {
        for input in ["", "NaN", "infinity", "not a number"] {
            var draft = AgentGenerationDraft()
            draft.topP.isCustom = true
            draft.topP.text = input
            #expect(throws: (any Error).self) { try draft.validated() }
        }
        var draft = AgentGenerationDraft()
        draft.topK = .init("1.2")
        #expect(throws: (any Error).self) { try draft.validated() }
        draft.topK.isCustom = false
        #expect(try draft.validated().settings == nil)
        draft.templateKwargs = .init("{\"messages\":[]}")
        #expect(throws: (any Error).self) { try draft.validated() }
    }

    @Test("only the detected model's exact effort ids are accepted")
    func exactCapabilities() throws {
        let choices = AgentGenerationReasoningChoices(
            efforts: .init(levels: ["low", "medium", "xhigh"].map { .init(id: $0) }, defaultLevelId: "xhigh"),
            supportsThinking: false)
        try choices.validate(settings: .init(reasoningEffort: "xhigh"))
        #expect(throws: (any Error).self) { try choices.validate(settings: .init(reasoningEffort: "high")) }
        #expect(throws: (any Error).self) { try choices.validate(settings: .init(enableThinking: false)) }
        let noControls = AgentGenerationReasoningChoices(efforts: nil, supportsThinking: false)
        try noControls.validate(settings: .init())
        #expect(throws: (any Error).self) { try noControls.validate(settings: .init(reasoningEffort: "low")) }
        try AgentGenerationReasoningChoices(efforts: nil, supportsThinking: true)
            .validate(settings: .init(enableThinking: false))
    }

    @Test("agent defaults reach rebuilt Responses and compatibility requests; explicit turn values win")
    func requestPrecedence() throws {
        var controls = ChatTurnGenerationControls.capture(
            activeModelOptions: ["reasoningEffort": .string("medium"), "disableThinking": .bool(false)])
        controls.topP = 0.95
        controls.agentSettings = .init(topP: 0.8, topK: 42, minP: 0.02,
            repetitionPenalty: 1.1, frequencyPenalty: 0.3, presencePenalty: 0.4,
            seed: 17, stop: ["END"], enableThinking: true, reasoningEffort: "low",
            templateKwargs: ["template": .string("agent")])
        controls.overrides = .init(topP: 0, topK: 0, reasoningEffort: "xhigh", enableThinking: false,
            templateKwargs: ["template": .string("turn")])
        for _ in 0..<3 {
            var request = ResponsesInferenceRequest(model: "fixture", input: [])
            controls.apply(to: &request)
            #expect(request.generation.topP == 0)
            #expect(request.generation.topK == 0)
            #expect(request.generation.minP == 0.02)
            #expect(request.generation.repetitionPenalty == 1.1)
            #expect(request.generation.frequencyPenalty == 0.3)
            #expect(request.generation.presencePenalty == 0.4)
            #expect(request.generation.seed == 17)
            #expect(request.generation.stop == ["END"])
            #expect(request.generation.enableThinking == false)
            #expect(request.generation.reasoningEffort == "xhigh")
            #expect(request.generation.templateKwargs == ["template": .string("turn")])
            var compatibility = ResponsesInferenceRequest(model: "fixture", input: []).chatCompletionsCompatibilityRequest()
            controls.apply(to: &compatibility)
            let restored = ResponsesInferenceRequest(chatCompletion: compatibility)
            #expect(restored.generation.minP == request.generation.minP)
            #expect(restored.generation.repetitionPenalty == request.generation.repetitionPenalty)
            #expect(restored.generation.frequencyPenalty == request.generation.frequencyPenalty)
            #expect(restored.generation.presencePenalty == request.generation.presencePenalty)
            #expect(restored.generation.seed == request.generation.seed)
            #expect(restored.generation.reasoningEffort == request.generation.reasoningEffort)
            #expect(restored.generation.enableThinking == request.generation.enableThinking)
            #expect(restored.generation.templateKwargs == request.generation.templateKwargs)
        }
    }

    @Test("template detection follows the canonical effort control instead of adding a duplicate Thinking switch")
    func effortAndThinkingAreNotDuplicated() throws {
        let local = LocalReasoningCapability.analyze(
            template: "{% if enable_thinking is false %}{{ '<think></think>' }}{% endif %}")
        #expect(local.isToggleableThinking)
        let efforts = ModelReasoningCapabilities(
            levels: ["none", "low", "medium", "xhigh"].map { .init(id: $0) }, defaultLevelId: "xhigh")
        let effortChoices = AgentGenerationReasoningChoices.resolved(modelID: "effort-fixture",
            localCapability: local, efforts: efforts, options: [efforts.reasoningOptionDefinition])
        #expect(effortChoices.efforts?.levels.map(\.id) == ["none", "low", "medium", "xhigh"])
        #expect(!effortChoices.showsThinkingControl)
        #expect(effortChoices.supportsThinking)
        try effortChoices.validate(settings: .init(enableThinking: false))
        let toggleChoices = AgentGenerationReasoningChoices.resolved(modelID: "Qwen3-toggle-fixture",
            localCapability: local, efforts: nil, options: QwenThinkingProfile.options)
        #expect(toggleChoices.supportsThinking)
        #expect(toggleChoices.showsThinkingControl)
        #expect(toggleChoices.efforts == nil)
    }

    @Test("captured raw agent cap cannot overwrite a tighter delegated request cap")
    func capRemainsTightened() {
        var controls = ChatTurnGenerationControls.capture(activeModelOptions: [:])
        controls.agentDefaultsCaptured = true
        controls.maxOutputTokens = 4096
        controls.agentSettings = .init(topK: 0)
        var request = ResponsesInferenceRequest(model: "fixture", input: [],
            generation: .init(maxOutputTokens: 128))
        controls.apply(to: &request)
        #expect(request.generation.maxOutputTokens == 128)
    }

    @Test("old turn records decode and new saved snapshots preserve exact agent settings")
    func snapshotCompatibility() throws {
        var controls = ChatTurnGenerationControls.capture(activeModelOptions: [:])
        controls.agentSettings = .init(topP: 0, topK: 0, enableThinking: false)
        controls.maxOutputTokens = 128
        controls.agentDefaultsCaptured = true
        let encoded = try JSONEncoder().encode(controls)
        #expect(try JSONDecoder().decode(ChatTurnGenerationControls.self, from: encoded) == controls)
        var old = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for key in ["agentSettings", "maxOutputTokens", "agentDefaultsCaptured"] { old.removeValue(forKey: key) }
        let decoded = try JSONDecoder().decode(ChatTurnGenerationControls.self,
            from: JSONSerialization.data(withJSONObject: old))
        #expect(decoded.agentSettings == nil)
        #expect(decoded.agentDefaultsCaptured == nil)
        #expect(decoded.maxOutputTokens == nil)
    }
}
