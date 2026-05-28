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
    @Test("Osaurus Guide starter is available and scoped to onboarding help")
    func osaurusGuideStarterIsAvailable() {
        #expect(AgentStarterTemplate.allCases.contains(.osaurusGuide))
        #expect(AgentStarterTemplate.osaurusGuide.label == "Guide")
        #expect(AgentStarterTemplate.osaurusGuide.defaultName == "Osaurus Guide")

        let prompt = AgentStarterTemplate.osaurusGuide.systemPrompt.lowercased()
        #expect(prompt.contains("agent"))
        #expect(prompt.contains("skills"))
        #expect(prompt.contains("plugins"))
        #expect(prompt.contains("feature request"))
        #expect(prompt.contains("do not pretend"))
        #expect(prompt.contains("github"))
    }

    @Test("Onboarding create-agent step defaults to Osaurus Guide")
    @MainActor
    func onboardingCreateAgentDefaultsToGuide() {
        let state = CreateAgentState()

        #expect(state.selectedTemplate == .osaurusGuide)
        #expect(state.name == "Osaurus Guide")
        #expect(state.systemPrompt == AgentStarterTemplate.osaurusGuide.systemPrompt)
    }
}
