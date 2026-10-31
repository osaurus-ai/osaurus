import Testing

@testable import OsaurusCore

struct AgentReasoningModelSwitchPresentationTests {
    private let efforts = ModelReasoningCapabilities(
        levels: ["low", "xhigh"].map { .init(id: $0) }, defaultLevelId: "xhigh")

    @Test("saved controls use the same compatibility predicate before display and dispatch")
    func rawSavedControlsAreValidated() throws {
        let toggle = AgentGenerationReasoningChoices(efforts: nil, supportsThinking: true)
        let effort = AgentGenerationReasoningChoices(efforts: efforts, supportsThinking: false)
        let savedLow = AgentGenerationSettings(reasoningEffort: "low")
        let savedOff = AgentGenerationSettings(enableThinking: false)
        #expect(toggle.reasoningIssue(settings: savedLow) == .effort("low"))
        #expect(throws: (any Error).self) { try toggle.validate(settings: savedLow) }
        #expect(effort.reasoningIssue(settings: savedOff) == .thinking)
        #expect(throws: (any Error).self) { try effort.validate(settings: savedOff) }
        #expect(effort.reasoningIssue(settings: savedLow) == nil)
        try effort.validate(settings: savedLow)
        #expect(toggle.reasoningIssue(settings: savedOff) == nil)
        try toggle.validate(settings: savedOff)
        for choices in [toggle, effort] {
            #expect(choices.reasoningIssue(settings: .init()) == nil)
            try choices.validate(settings: .init())
        }
        // Inspecting another model must not rewrite the saved defaults or an old turn.
        #expect(savedLow.reasoningEffort == "low")
        #expect(savedOff.enableThinking == false)
    }

    @Test("an incompatible saved effort does not select Off or Default in the actual picker projection")
    func invalidThinkingSelection() throws {
        for supportsDefault in [false, true] {
            let thinking = ModelPickerThinkingControl(isEnabled: false, isExplicit: true,
                onSetEnabled: { _ in }, supportsUnspecifiedDefault: supportsDefault, selectionIsValid: false)
            let control = ModelPickerOptionsControl(capabilities: nil, thinking: thinking,
                options: [], values: [:], defaults: [:], onChange: { _, _ in },
                reasoningValidationMessage: "Choose a supported reasoning setting.")
            let snapshot = try #require(ChatPickerOptionsSnapshot.make(modelID: "toggle", control: control))
            let section = try #require(snapshot.sections.first)
            #expect(thinking.selectedMode == nil)
            #expect(section.rows.allSatisfy { !$0.selected })
            #expect(section.rows.contains { $0.action == .thinking(false) })
            #expect(section.rows.contains { $0.action == .thinking(true) })
            #expect(section.footnote == control.reasoningValidationMessage)
            #expect(supportsDefault ? section.rows.contains { $0.action == .thinking(nil) } : section.reset != nil)
        }
    }

    @Test("valid and inherited thinking selections retain their existing meanings")
    func validThinkingSelection() {
        #expect(ModelPickerThinkingControl(isEnabled: false, isExplicit: true,
            onSetEnabled: { _ in }).selectedMode == "off")
        #expect(ModelPickerThinkingControl(isEnabled: true, isExplicit: false,
            onSetEnabled: { _ in }).selectedMode == "on")
        #expect(ModelPickerThinkingControl(isEnabled: true, isExplicit: false,
            onSetEnabled: { _ in }, supportsUnspecifiedDefault: true).selectedMode == "default")
    }

    @Test("incompatible thinking does not highlight a default effort or change speculation")
    func invalidEffortSelectionPreservesMTP() throws {
        let effort = ModelOptionDefinition(id: "reasoningEffort", label: "Reasoning Effort",
            kind: .segmented([.init(id: "low", label: "Low"), .init(id: "xhigh", label: "Extra High")]))
        let mtp = ModelOptionDefinition(id: "nativeMTP", label: "MTP",
            kind: .segmented([.init(id: "auto", label: "On"), .init(id: "off", label: "Off")]))
        let control = ModelPickerOptionsControl(capabilities: efforts, options: [effort, mtp],
            values: ["nativeMTP": .string("auto")], defaults: ["reasoningEffort": .string("xhigh")],
            onChange: { _, _ in }, reasoningValidationMessage: "Choose a supported reasoning setting.")
        let snapshot = try #require(ChatPickerOptionsSnapshot.make(modelID: "effort", control: control))
        let reasoning = try #require(snapshot.sections.first { $0.id == "reasoningEffort" })
        #expect(reasoning.rows.allSatisfy { !$0.selected })
        #expect(reasoning.reset?.action == .reset(optionID: "reasoningEffort"))
        let speculation = try #require(snapshot.sections.first { $0.id == "nativeMTP" })
        #expect(speculation.rows.first { $0.selected }?.action == .segment(optionID: "nativeMTP", segmentID: "auto"))
        #expect(control.defaults["reasoningEffort"] == .string("xhigh"))
    }

    @Test("a model without reasoning controls still offers an explicit reset of incompatible saved reasoning")
    func unsupportedModelHasReset() throws {
        let control = ModelPickerOptionsControl(capabilities: nil, options: [], values: [:], defaults: [:],
            onChange: { _, _ in }, reasoningValidationMessage: "Choose a supported reasoning setting.")
        #expect(!control.isEmpty)
        let snapshot = try #require(ChatPickerOptionsSnapshot.make(modelID: "no-reasoning", control: control))
        #expect(snapshot.sections.first?.reset?.action == .reset(optionID: "reasoningEffort"))
        #expect(control.canResetOption("reasoningEffort"))
        #expect(!control.canResetOption("nativeMTP"))
        #expect(!control.canResetOption("unknown"))
        let inherited = ModelPickerOptionsControl(capabilities: nil, options: [], values: [:], defaults: [:],
            onChange: { _, _ in })
        #expect(inherited.isEmpty)
        #expect(ChatPickerOptionsSnapshot.make(modelID: "no-reasoning", control: inherited) == nil)
    }
}
