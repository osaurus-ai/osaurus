//
//  AgentStarterTemplateTests.swift
//  osaurusTests
//
//  Pins the create-agent starter catalog used by the in-app Agent editor.
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

    @Test("Reviewed default and starter descriptions are one-line routing text")
    func reviewedDescriptionsAreValid() {
        #expect(!Agent.default.routingDescription.isEmpty)
        for template in AgentStarterTemplate.allCases where template != .blank {
            let text = template.routingDescription
            #expect(!text.isEmpty)
            #expect(AgentDescriptionPolicy.normalized(text) == text)
            #expect(text.count <= AgentDescriptionPolicy.generatedMaximumCharacters)
        }
    }
}
