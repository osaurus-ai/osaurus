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
    @Test @MainActor
    func onboardingRejectsConcurrentSaveAndCancelledResult() async {
        let state = CreateAgentState()
        let originalName = state.name
        let task = Task { @MainActor in
            await state.resolveDescriptionAndSave { _, _ in
                let duplicate = await state.resolveDescriptionAndSave { _, _ in
                    Issue.record("A second save must not start generation")
                    return "Wrong duplicate"
                }
                #expect(!duplicate)
                withUnsafeCurrentTask { $0?.cancel() }
                return "Checks citations."
            }
        }
        let saved = await task.value
        #expect(!saved)
        #expect(state.createdAgentId == nil)
        #expect(state.name == originalName)
        #expect(state.description.isEmpty)
        #expect(!state.isSaving)
        #expect(state.descriptionError == nil)
    }

    @Test @MainActor
    func onboardingRejectsStaleGeneratedDescription() async {
        let state = CreateAgentState()
        let saved = await state.resolveDescriptionAndSave { _, _ in
            state.name = "Changed while generating"
            return "Checks citations."
        }
        #expect(!saved)
        #expect(state.createdAgentId == nil)
        #expect(state.description.isEmpty)
        #expect(!state.isSaving)
        #expect(state.descriptionError != nil)
    }

    @Test @MainActor
    func onboardingPreservesDraftOnInvalidGeneration() async {
        let state = CreateAgentState()
        let original = state.name
        let saved = await state.resolveDescriptionAndSave { _, _ in String(repeating: "界", count: 161) }
        #expect(!saved)
        #expect(state.name == original)
        #expect(state.description.isEmpty)
        #expect(state.createdAgentId == nil)
        #expect(state.descriptionError == AgentDescriptionPolicy.Violation.tooLong.message)
    }

    @Test("Osaurus Guide starter has been retired")
    func osaurusGuideStarterIsRemoved() {
        let raw = AgentStarterTemplate.allCases.map(\.rawValue)
        #expect(!raw.contains("osaurusGuide"))
        #expect(AgentStarterTemplate(rawValue: "osaurusGuide") == nil)
    }

    @Test("Onboarding create-agent step defaults to the everyday helper")
    @MainActor
    func onboardingCreateAgentDefaults() {
        let state = CreateAgentState()

        #expect(state.selectedSpecialty == .everyday)
        #expect(state.selectedTemplate == .assistant)
        #expect(state.selectedAvatar == AgentMascot.green.id)
        #expect(state.name == CreateAgentState.defaultName)
        #expect(state.canSave)
        state.description = "Handles independent everyday tasks when delegation is useful."
        #expect(state.canSave)
        state.description = "   "
        #expect(state.canSave)
        state.description = String(repeating: "a", count: 161)
        #expect(!state.canSave)
    }

    @Test("Reviewed default and starter descriptions satisfy the routing contract")
    func reviewedDescriptionsAreValid() {
        #expect(!Agent.default.requiresDescriptionRepair)
        for template in AgentStarterTemplate.allCases where template != .blank {
            #expect(AgentDescriptionPolicy.violation(in: template.routingDescription) == nil)
        }
    }

    @Test("Name is independent of the selected specialty")
    @MainActor
    func nameIsIndependentOfSpecialty() {
        let state = CreateAgentState()

        // Switching cards never rewrites the name chip (the Figma "Helper"
        // chip is decoupled from the specialty).
        state.selectedSpecialty = .coding
        #expect(state.name == CreateAgentState.defaultName)

        state.name = "Rexy"
        state.selectedSpecialty = .research
        #expect(state.name == "Rexy")
        #expect(state.resolvedName == "Rexy")
    }

    @Test("Blank name resolves to the default dino name")
    @MainActor
    func blankNameResolvesToDefault() {
        let state = CreateAgentState()
        state.name = "   "

        #expect(state.resolvedName == CreateAgentState.defaultName)
    }

    @Test("Specialty cards map onto distinct starter archetypes")
    func specialtyCardsMapToArchetypes() {
        #expect(OnboardingSpecialty.everyday.template == .assistant)
        #expect(OnboardingSpecialty.research.template == .researcher)
        #expect(OnboardingSpecialty.coding.template == .coder)

        let templates = OnboardingSpecialty.allCases.map(\.template)
        #expect(Set(templates).count == templates.count)
        #expect(!templates.contains(.blank))
    }

    @Test("Randomize always lands on a different mascot")
    @MainActor
    func randomizeAvatarChangesMascot() {
        let state = CreateAgentState()
        for _ in 0..<10 {
            let before = state.selectedAvatar
            state.randomizeAvatar()
            #expect(state.selectedAvatar != before)
            #expect(state.selectedAvatar != nil)
        }
    }
}
