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

    @Test("Onboarding create-agent step defaults to a blank starter")
    @MainActor
    func onboardingCreateAgentDefaultsToBlank() {
        let state = CreateAgentState()

        #expect(state.selectedTemplate == .blank)
        #expect(state.name == "")
        #expect(state.systemPrompt == AgentStarterTemplate.blank.systemPrompt)
    }
}
