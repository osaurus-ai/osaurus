//
//  AgentStarterTemplateTests.swift
//  osaurusTests
//
//  Pins the create-agent starter catalog used by onboarding and the
//  in-app Agent editor.
//

import Testing

@testable import OsaurusCore

@Suite("Agent starter templates")
struct AgentStarterTemplateTests {
    @Test("Osaurus Guide starter has been retired")
    func osaurusGuideStarterIsRemoved() {
        let raw = AgentStarterTemplate.allCases.map(\.rawValue)
        #expect(!raw.contains("osaurusGuide"))
        #expect(AgentStarterTemplate(rawValue: "osaurusGuide") == nil)
    }

    @Test("Onboarding create-agent step defaults to the assistant archetype")
    @MainActor
    func onboardingCreateAgentDefaultsToAssistant() {
        let state = CreateAgentState()

        #expect(state.selectedTemplate == .assistant)
        #expect(state.selectedAvatar == AgentMascot.allCases.first?.id)
        #expect(state.name == AgentStarterTemplate.assistant.defaultName)
        #expect(state.canSave)
    }

    @Test("Switching archetype updates the name until the user edits it")
    @MainActor
    func archetypeFollowsNameUntilEdited() {
        let state = CreateAgentState()

        // Pre-edit: the name tracks the selected archetype.
        state.selectArchetype(.coder)
        #expect(state.name == AgentStarterTemplate.coder.defaultName)

        // Once the user types their own name, presets stop touching it.
        state.name = "Rexy"
        state.nameUserEdited = true
        state.selectArchetype(.writer)
        #expect(state.name == "Rexy")
        #expect(state.resolvedName == "Rexy")
    }

    @Test("Blank name resolves to the archetype default")
    @MainActor
    func blankNameResolvesToDefault() {
        let state = CreateAgentState()
        state.name = "   "

        #expect(state.resolvedName == AgentStarterTemplate.assistant.defaultName)
    }

    @Test("Onboarding archetypes lead with assistant and exclude blank")
    func onboardingArchetypesCurated() {
        let archetypes = AgentStarterTemplate.onboardingArchetypes

        #expect(archetypes.first == .assistant)
        #expect(!archetypes.contains(.blank))
        #expect(archetypes == [.assistant, .writer, .researcher, .coder, .productivity])
    }
}
