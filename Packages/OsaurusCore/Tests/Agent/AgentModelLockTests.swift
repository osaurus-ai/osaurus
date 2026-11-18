//
//  AgentModelLockTests.swift
//  OsaurusCoreTests
//
//  `modelLocked` pins a custom agent's chats to its `defaultModel`. It must
//  survive the agent JSON round trip and Duplicate, travel through the
//  declarative document as `model_locked`, be turned on by templates whose
//  main model slot is `strictness: always`, and be honored only where
//  `AgentManager.lockedModel` says it applies.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct AgentModelLockTests {

    private func lockedAgent(model: String? = "anthropic/sonnet-5") -> Agent {
        var agent = AgentManager.newCustomAgentRecord(name: "Locked Bot")
        agent.defaultModel = model
        agent.modelLocked = true
        return agent
    }

    // MARK: - Persistence

    @Test
    func roundTripsThroughAgentJSON_andDefaultsToNil() throws {
        let data = try JSONEncoder().encode(lockedAgent())
        #expect(try JSONDecoder().decode(Agent.self, from: data).modelLocked == true)

        var json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        json?["modelLocked"] = nil
        let legacy = try JSONSerialization.data(withJSONObject: json ?? [:])
        #expect(try JSONDecoder().decode(Agent.self, from: legacy).modelLocked == nil)
    }

    @Test
    func duplicateCarriesTheLock() {
        let copy = AgentManager.duplicateRecord(from: lockedAgent(), name: "Locked Bot Copy")
        #expect(copy.modelLocked == true)
    }

    // MARK: - lockedModel gating

    @Test
    func lockedModel_returnsTrimmedModelOnlyWhenEveryConditionHolds() {
        #expect(AgentManager.lockedModel(of: lockedAgent(model: "  anthropic/sonnet-5 \n")) == "anthropic/sonnet-5")

        var off = lockedAgent()
        off.modelLocked = nil
        #expect(AgentManager.lockedModel(of: off) == nil)

        #expect(AgentManager.lockedModel(of: lockedAgent(model: nil)) == nil)
        #expect(AgentManager.lockedModel(of: lockedAgent(model: "   ")) == nil)

        var harness = lockedAgent()
        harness.runtime = .harness(UUID())
        #expect(AgentManager.lockedModel(of: harness) == nil)

        var builtInLoop = lockedAgent()
        builtInLoop.runtime = .builtIn
        #expect(AgentManager.lockedModel(of: builtInLoop) == "anthropic/sonnet-5")

        var orchestrator = Agent.default
        orchestrator.defaultModel = "anthropic/sonnet-5"
        orchestrator.modelLocked = true
        #expect(AgentManager.lockedModel(of: orchestrator) == nil)
    }

    @Test
    func updateModelLocked_togglesAndClearsToNil() async {
        var agent = AgentManager.newCustomAgentRecord(name: "Lock Toggle \(UUID().uuidString)")
        agent.defaultModel = "foundation"
        AgentManager.shared.add(agent)

        AgentManager.shared.updateModelLocked(for: agent.id, locked: true)
        #expect(AgentManager.shared.agent(for: agent.id)?.modelLocked == true)
        #expect(AgentManager.shared.lockedModel(for: agent.id) == "foundation")

        AgentManager.shared.updateModelLocked(for: agent.id, locked: false)
        #expect(AgentManager.shared.agent(for: agent.id)?.modelLocked == nil)
        #expect(AgentManager.shared.lockedModel(for: agent.id) == nil)

        AgentManager.shared.updateModelLocked(for: Agent.defaultId, locked: true)
        #expect(AgentManager.shared.agent(for: Agent.defaultId)?.modelLocked != true)
        _ = await AgentManager.shared.delete(id: agent.id)
    }

    // MARK: - Declarative document

    @Test
    func declarativeDocument_carriesModelLocked() throws {
        let yaml = """
            version: 1
            agents:
              - name: Locked Bot
                model: foundation
                model_locked: true
            """
        let document = try ConfigYAML.decode(yaml)
        #expect(document.agents?.first?.modelLocked == true)
        #expect(try ConfigYAML.encode(document).contains("model_locked: true"))

        let absent = try ConfigYAML.decode("version: 1\nagents:\n  - name: Plain\n")
        #expect(absent.agents?.first?.modelLocked == nil)
    }

    @Test
    func exporter_writesOnlyALock() {
        #expect(ConfigExporter.exportAgent(lockedAgent()).modelLocked == true)
        var unlocked = lockedAgent()
        unlocked.modelLocked = nil
        #expect(ConfigExporter.exportAgent(unlocked).modelLocked == nil)
    }

    // MARK: - Templates

    private func template(
        model: String? = "foundation", policy: TemplateRequirement.ModelPolicy?, locked: Bool? = nil
    ) -> AgentTemplate {
        var entry = AgentEntry(name: "T")
        if let model { entry.model = .value(model) }
        entry.modelLocked = locked
        var requirements = TemplateRequirements()
        if let model, let policy {
            requirements.models = [ModelRequirement(slot: ModelRequirement.agentSlot, preferred: model, strictness: policy)]
        }
        return AgentTemplate(name: "T", agent: entry, requirements: requirements)
    }

    @Test
    func alwaysMainModel_locksTheInstalledAgent() {
        #expect(template(policy: .always).resolvedEntry().modelLocked == true)
        #expect(template(policy: .preferred).resolvedEntry().modelLocked == nil)
        #expect(template(policy: nil).resolvedEntry().modelLocked == nil)
        #expect(template(model: nil, policy: .always).resolvedEntry().modelLocked == nil)
    }

    @Test
    func explicitOverrideOrEntryValue_winsOverStrictness() {
        var overrides = AgentEntry(name: "")
        overrides.modelLocked = false
        #expect(template(policy: .always).resolvedEntry(overrides: overrides).modelLocked == false)
        #expect(template(policy: .preferred, locked: true).resolvedEntry().modelLocked == true)
    }

    @Test
    func lockedEntry_derivesAnAlwaysRequirement() {
        var entry = AgentEntry(name: "T")
        entry.model = .value("foundation")
        entry.modelLocked = true
        let locked = AgentTemplate.agentRequirements(entry: entry, carried: TemplateRequirements())
        #expect(locked.models.first?.strictness == .always)

        entry.modelLocked = nil
        let unlocked = AgentTemplate.agentRequirements(entry: entry, carried: TemplateRequirements())
        #expect(unlocked.models.first?.strictness == .preferred)
    }
}
