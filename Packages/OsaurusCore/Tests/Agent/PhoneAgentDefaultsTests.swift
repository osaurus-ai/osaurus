//
//  PhoneAgentDefaultsTests.swift
//  OsaurusCoreTests
//
//  An agent created from the paired phone starts with every capability off:
//  the phone can't reach the agent's settings, so anything on by default
//  would stay on until the user got to the Mac.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Phone-created agent defaults")
@MainActor
struct PhoneAgentDefaultsTests {
    @Test func phoneAgentStartsWithEverythingOff() {
        let agent = AgentManager.phoneAgentRecord(
            name: "From Phone",
            description: "Made on the phone.",
            systemPrompt: "Help.",
            defaultModel: "some-model"
        )
        #expect(!agent.isBuiltIn)
        #expect(agent.defaultModel == "some-model")
        #expect(!agent.toolsEnabled)
        #expect(!agent.memoryEnabled)
        #expect(!agent.settings.webSearchEnabled)
        #expect(!agent.settings.screenContextEnabled)
        #expect(!agent.settings.dbEnabled)
        #expect(!agent.settings.searchMemoryEnabled)
        #expect(!agent.settings.selfSchedulingEnabled)
        #expect(!agent.settings.computerUseEnabled)
        #expect(!agent.settings.browserUseEnabled)
        #expect(agent.settings.enabledAppleApps.isEmpty)
        // An explicit opt-out, which stays off where the sandbox runs.
        #expect(agent.autonomousExec?.enabled == false)
        #expect(AgentManager.resolvedAutonomousExec(for: agent, availability: .available)?.enabled != true)
    }

    @Test func macCreatedAgentKeepsTheUsualDefaults() {
        let agent = AgentManager.newCustomAgentRecord(name: "On the Mac", description: "Made on the Mac.")
        #expect(agent.toolsEnabled)
        #expect(agent.memoryEnabled)
        #expect(agent.settings.webSearchEnabled)
    }
}
