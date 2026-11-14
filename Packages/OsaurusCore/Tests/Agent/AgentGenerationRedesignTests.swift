import Foundation
import Testing
@preconcurrency import MLXLMCommon
@testable import OsaurusCore

struct AgentGenerationRedesignTests {
    @Test("inherited previews preserve model, server and app precedence without writing overrides")
    func inheritedPrecedence() throws {
        let model = LocalGenerationDefaults.Defaults(
            maxTokens: 1024,
            temperature: 0.8,
            topP: 0.9,
            topK: 17,
            minP: 0.03,
            repetitionPenalty: 1.2,
            presencePenalty: 0.4,
            frequencyPenalty: 0.2
        )
        var server = VMLXServerGenerationDefaults()
        server.temperature = 0.3
        server.topP = 0.6
        let draft = AgentGenerationDraft()
        let preview = AgentGenerationInheritedValues.resolve(
            modelID: "fixture",
            isLocal: true,
            modelDefaults: model,
            runtime: server,
            appTopP: 0.7,
            modelOptions: [:],
            draft: draft
        )
        #expect(preview[.temperature] == .init(text: "0.3", source: "Server", customText: "0.3"))
        #expect(preview[.topP].text == "0.7")
        #expect(preview[.topP].source == "App")
        #expect(preview[.topK] == .init(text: "17", source: "Model", customText: "17"))
        #expect(preview[.maxTokens].text == "1024")
        #expect(preview[.presencePenalty].text == "0.4")
        #expect(try draft.validated().settings == nil)
        #expect(draft.overrideCount == 0)
    }

    @Test("runtime fallback and unknown remote defaults are not fabricated UI examples")
    func unknownAndRuntimeDefaults() {
        let preview = AgentGenerationInheritedValues.resolve(
            modelID: "fixture",
            isLocal: true,
            modelDefaults: .empty,
            runtime: .init(),
            appTopP: nil,
            modelOptions: [:],
            draft: .init()
        )
        #expect(preview[.topK].text == String(GenerateParameters().topK))
        #expect(preview[.topK].source == "Runtime")
        #expect(preview[.maxTokens].customText == nil)
        #expect(preview[.maxTokens].text != "Unlimited")
        #expect(preview[.repetitionPenalty].customText == nil)
        for id in [nil, "remote/provider"] as [String?] {
            let remote = AgentGenerationInheritedValues.resolve(
                modelID: id,
                isLocal: false,
                modelDefaults: .empty,
                runtime: .init(),
                appTopP: nil,
                modelOptions: [:],
                draft: .init()
            )
            #expect(remote[.topK].customText == nil)
            #expect(remote[.topK].source == "")
            #expect(remote[.stop].customText == "[]")
            #expect(remote[.templateKwargs].customText == "{}")
            let explicitApp = AgentGenerationInheritedValues.resolve(modelID: id, isLocal: false,
                modelDefaults: .empty, runtime: .init(), appTopP: 0.72, modelOptions: [:], draft: .init())
            #expect(explicitApp[.topP] == .init(text: "0.72", source: "App", customText: "0.72"))
            #expect(explicitApp[.temperature].customText == nil)
        }
    }

    @Test("thinking-mode bundle overlays use the same resolver as generation")
    func thinkingPreview() throws {
        let model = LocalGenerationDefaults.Defaults(
            temperature: 0.4,
            topK: 13,
            thinkingSamplingData: Data(#"{"temperature":0.9,"top_k":29}"#.utf8),
            defaultThinkingEnabled: false
        )
        var draft = AgentGenerationDraft()
        draft.templateKwargs = .init(#"{"enable_thinking":true}"#)
        let preview = AgentGenerationInheritedValues.resolve(
            modelID: "fixture",
            isLocal: true,
            modelDefaults: model,
            runtime: .init(),
            appTopP: nil,
            modelOptions: [:],
            draft: draft
        )
        #expect(preview[.temperature].text == "0.9")
        #expect(preview[.topK].text == "29")
        #expect(preview[.topK].source == "Model")
    }

    @Test("chip entry preserves exact strings, duplicates, removal and pending Save input")
    func chipsRoundTrip() throws {
        var draft = AgentGenerationDraft(settings: .init(stop: ["END", "END", " spaced ", "\n\\\""]))
        draft.pendingStopSequence = " pending \n"
        let values = try draft.validated()
        #expect(values.settings?.stop == ["END", "END", " spaced ", "\n\\\"", " pending \n"])
        try draft.commitStopSequence()
        #expect(draft.pendingStopSequence.isEmpty)
        #expect(try draft.validated().settings == values.settings)
        var chips = try draft.stopSequencesIncludingPending()
        chips.remove(at: 1)
        try draft.setStopSequences(chips)
        #expect(try draft.validated().settings?.stop == ["END", " spaced ", "\n\\\"", " pending \n"])
        draft.pendingStopSequence = "unsaved"
        draft.stop.setCustom(false)
        #expect(try draft.validated().settings == nil)
        draft.stop.setCustom(true, inheritedText: "[]")
        #expect(try draft.validated().settings?.stop?.last == "unsaved")
        #expect(draft.overrideCount == 1)
    }

    @Test("inline validation reuses existing save rules and does not report unrelated errors")
    func inlineValidation() throws {
        var draft = AgentGenerationDraft()
        draft.maxTokens = .init("")
        draft.topP = .init("0")
        #expect(draft.validationMessage(for: .maxTokens)?.contains("select Inherit") == true)
        #expect(draft.validationMessage(for: .topP) == nil)
        draft.templateKwargs = .init(#"{"messages":[]}"#)
        #expect(draft.validationMessage(for: .templateKwargs) != nil)
        draft.thinking = "off"
        draft.reasoningEffort = "low"
        #expect(draft.overrideCount == 5)
        draft.stop = .init("broken JSON")
        draft.pendingStopSequence = "keep"
        #expect(throws: (any Error).self) { try draft.commitStopSequence() }
        #expect(draft.pendingStopSequence == "keep")
        #expect(draft.stop.text == "broken JSON")
    }
}
