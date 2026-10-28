import Foundation
import Testing

@testable import OsaurusCore

struct AgentGenerationSettingsTests {
    static let explicit = AgentGenerationSettings(
        topP: 0, topK: 0, minP: 0, repetitionPenalty: 1,
        frequencyPenalty: 0, presencePenalty: 0, seed: -7, stop: [],
        enableThinking: false, reasoningEffort: "low",
        templateKwargs: [
            "custom": .object([
                "enabled": .bool(false), "count": .number(0),
                "values": .array([.null, .string("value")]),
            ])
        ]
    )

    @Test("agent JSON keeps explicit zero and false without duplicating temperature or token limits")
    func agentJSONRoundTripAndLegacyInheritance() throws {
        let agent = Agent(
            name: "Generation fixture", temperature: 0, maxTokens: 1234,
            generationSettings: Self.explicit,
            autonomousExec: AutonomousExecConfig(enabled: false)
        )
        let data = try JSONEncoder().encode(agent)
        let decoded = try JSONDecoder().decode(Agent.self, from: data)
        #expect(decoded.generationSettings == Self.explicit)
        #expect(decoded.temperature == 0)
        #expect(decoded.maxTokens == 1234)

        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let settings = try #require(json["generationSettings"] as? [String: Any])
        #expect(settings["temperature"] == nil)
        #expect(settings["max_tokens"] == nil)
        #expect(settings["maxTokens"] == nil)
        #expect(settings["topP"] == nil)
        #expect(settings["top_p"] as? Double == 0)
        #expect(settings["enable_thinking"] as? Bool == false)

        json.removeValue(forKey: "generationSettings")
        let legacy = try JSONSerialization.data(withJSONObject: json)
        let inherited = try JSONDecoder().decode(Agent.self, from: legacy)
        #expect(inherited.generationSettings == nil)
        #expect(inherited.temperature == 0)
        #expect(inherited.maxTokens == 1234)
    }

    @Test("empty settings inherit while explicit empty collections remain configured")
    func emptyAndExplicitValues() throws {
        #expect(AgentGenerationSettings().isEmpty)
        #expect(!AgentGenerationSettings(topK: 0).isEmpty)
        #expect(!AgentGenerationSettings(enableThinking: false).isEmpty)
        #expect(!AgentGenerationSettings(stop: []).isEmpty)
        #expect(!AgentGenerationSettings(templateKwargs: [:]).isEmpty)
        try AgentGenerationSettings().validate()
        try Self.explicit.validate()
    }

    @Test("validation shares the request contracts without imposing provider-specific penalty bounds")
    func validatesExistingContracts() throws {
        let invalid = [
            AgentGenerationSettings(topP: -0.1),
            AgentGenerationSettings(topP: 1.1),
            AgentGenerationSettings(topP: .nan),
            AgentGenerationSettings(topK: -1),
            AgentGenerationSettings(minP: .infinity),
            AgentGenerationSettings(repetitionPenalty: 0),
            AgentGenerationSettings(frequencyPenalty: .nan),
            AgentGenerationSettings(presencePenalty: -.infinity),
            AgentGenerationSettings(reasoningEffort: "  "),
            AgentGenerationSettings(templateKwargs: ["messages": .array([])]),
        ]
        for settings in invalid {
            #expect(throws: (any Error).self) { try settings.validate() }
        }
        try AgentGenerationSettings(
            frequencyPenalty: -3, presencePenalty: 3, reasoningEffort: "model-specific-level"
        ).validate()
    }
}

@MainActor
@Suite(.serialized)
struct AgentGenerationSettingsPersistenceTests {
    @Test("save, refresh and duplicate preserve custom-agent defaults")
    func storeAndDuplicate() async throws {
        try await ChatHistoryTestStorage.run {
            let agent = Agent(
                name: "Generation fixture", temperature: 0, maxTokens: 1234,
                generationSettings: AgentGenerationSettingsTests.explicit,
                autonomousExec: AutonomousExecConfig(enabled: false)
            )
            AgentStore.save(agent)
            AgentManager.shared.refresh()
            #expect(AgentStore.load(id: agent.id)?.generationSettings == agent.generationSettings)
            #expect(AgentManager.shared.effectiveGenerationSettings(for: agent.id) == agent.generationSettings)
            #expect(AgentManager.shared.effectiveGenerationSettings(for: Agent.defaultId) == nil)
            #expect(AgentManager.shared.effectiveGenerationSettings(for: UUID()) == nil)
            let copy = AgentManager.duplicateRecord(from: agent, name: "Generation copy")
            #expect(copy.id != agent.id)
            #expect(copy.generationSettings == agent.generationSettings)
            #expect(copy.temperature == 0)
            #expect(copy.maxTokens == 1234)
        }
    }

    @Test("both backup identity-recovery paths preserve generation settings")
    func recoveryCopies() async throws {
        try await ChatHistoryTestStorage.run {
            let owner = Agent(
                name: "Owner", generationSettings: AgentGenerationSettingsTests.explicit,
                agentAddress: "fixture-address",
                autonomousExec: AutonomousExecConfig(enabled: false)
            )
            AgentStore.save(owner)
            // A cached load can precede the queued mkdir/write. This disk read
            // drains pending writes before the fixture writes adjacent backups.
            #expect(try AgentStore.loadPersisted(id: owner.id).id == owner.id)
            #expect(AgentStore.load(id: owner.id) != nil)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601

            // A UUID conflict creates a new record through recoveredConflictCopy.
            let conflictURL = OsaurusPaths.agents().appendingPathComponent("conflict.json.bak")
            try encoder.encode(owner).write(to: conflictURL)
            let copied = try AgentStore.restoreRecoverableBackup(at: conflictURL)
            #expect(copied.id != owner.id)
            #expect(copied.generationSettings == owner.generationSettings)

            // A distinct UUID with a conflicting address uses clearingRecoveredIdentity.
            let identityConflict = Agent(
                name: "Identity conflict", generationSettings: owner.generationSettings,
                agentAddress: owner.agentAddress,
                autonomousExec: AutonomousExecConfig(enabled: false)
            )
            let identityURL = OsaurusPaths.agents().appendingPathComponent("identity.json.bak")
            try encoder.encode(identityConflict).write(to: identityURL)
            let cleared = try AgentStore.restoreRecoverableBackup(at: identityURL)
            #expect(cleared.id == identityConflict.id)
            #expect(cleared.agentAddress == nil)
            #expect(cleared.generationSettings == owner.generationSettings)
        }
    }
}
