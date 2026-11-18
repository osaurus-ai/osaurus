//
//  AgentToolApprovalsDeclarativeTests.swift
//  osaurusTests
//
//  `agents[].tool_approvals` and `agents[].tools.policies`: manifest keys,
//  stored-settings decoding, plan rows and HIGH RISK lines, apply, export
//  round-trip, drafts that refuse them, and templates that never carry them.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct AgentToolApprovalsDeclarativeTests {

    private func withStorage(_ body: @MainActor @Sendable () async throws -> Void) async throws {
        try await SandboxTestLock.runWithStoragePaths {
            await SubagentStoreTestLock.shared.acquire()
            defer { SubagentStoreTestLock.shared.release() }
            try await body()
        }
    }

    private func probeAgent() -> Agent {
        AgentManager.shared.create(
            name: "Approvals Probe \(UUID().uuidString.prefix(6))",
            description: "Files weekly expense reports.", systemPrompt: "")
    }

    // MARK: Model

    @Test func manifestAdvertisesTheKeys() {
        #expect(ConfigManifest.knownKeys["agents[]"]?.contains("tool_approvals") == true)
        #expect(ConfigManifest.knownKeys["agents[].tools"]?.contains("policies") == true)
        #expect(ConfigManifest.renderedSchemaSections(only: [.agents]).contains("never_ask"))
    }

    @Test func legacySettingsDecodeToTheGlobalBehaviour() throws {
        let encoded = try JSONEncoder().encode(
            AgentSettings(dbEnabled: false, schedule: AgentScheduleSettings.defaults(for: .reactive)))
        let object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["toolApprovalMode"] == nil)
        #expect(object["toolPolicies"] == nil)
        let decoded = try JSONDecoder().decode(AgentSettings.self, from: encoded)
        #expect(decoded.toolApprovalMode == .useGlobal)
        #expect(decoded.toolPolicies.isEmpty)
    }

    @Test func settingsRoundTripAndDropUnknownValues() throws {
        var settings = AgentSettings(dbEnabled: false, schedule: AgentScheduleSettings.defaults(for: .reactive))
        settings.toolApprovalMode = .neverAsk
        settings.toolPolicies = ["file_write": .auto, "shell_run": .deny]
        let decoded = try JSONDecoder().decode(AgentSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.toolApprovalMode == .neverAsk)
        #expect(decoded.toolPolicies == ["file_write": .auto, "shell_run": .deny])

        var object = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        object["toolApprovalMode"] = "sometimes"
        object["toolPolicies"] = ["file_write": "maybe", "shell_run": "ask"]
        let lenient = try JSONDecoder().decode(
            AgentSettings.self, from: try JSONSerialization.data(withJSONObject: object))
        #expect(lenient.toolApprovalMode == .useGlobal)
        #expect(lenient.toolPolicies == ["shell_run": .ask])
    }

    // MARK: Plan and apply

    @Test func neverAskIsHighRiskAndApplies() async throws {
        try await withStorage {
            let agent = probeAgent()
            let document = try ConfigYAML.decode(
                """
                agents:
                  - name: \(agent.name)
                    tool_approvals: never_ask
                """)
            let plan = try ConfigPlanner.plan(document: document, prune: false)
            let action = try #require(plan.actions.first { $0.section == "agents" && $0.target == agent.name })
            #expect(action.changes.contains("tool_approvals: use_global -> never_ask"))
            #expect(action.risks.contains(ConfigRisk.neverAsk(agent.name)))

            _ = await ConfigApplier.apply(document: document, prune: false)
            #expect(AgentManager.shared.agent(for: agent.id)?.settings.toolApprovalMode == .neverAsk)

            let back = try ConfigYAML.decode(
                """
                agents:
                  - name: \(agent.name)
                    tool_approvals: ask
                """)
            let backPlan = try ConfigPlanner.plan(document: back, prune: false)
            let backAction = try #require(backPlan.actions.first { $0.target == agent.name })
            #expect(backAction.risks.isEmpty)
            _ = await ConfigApplier.apply(document: back, prune: false)
            #expect(AgentManager.shared.agent(for: agent.id)?.settings.toolApprovalMode == .ask)
            _ = await AgentManager.shared.delete(id: agent.id)
        }
    }

    @Test func invalidValuesAreRejected() async throws {
        try await withStorage {
            #expect(throws: (any Error).self) {
                _ = try ConfigYAML.decode(
                    """
                    agents:
                      - name: Anyone
                        tool_approvals: sometimes
                    """)
            }
            #expect(throws: (any Error).self) {
                _ = try ConfigYAML.decode(
                    """
                    agents:
                      - name: Anyone
                        tools:
                          policies:
                            file_write: maybe
                    """)
            }
            let agent = probeAgent()
            var entry = AgentEntry(name: agent.name)
            var tools = AgentToolsEntry()
            tools.policies = ["file_write": "maybe"]
            entry.tools = tools
            var document = OsaurusConfigDocument()
            document.agents = [entry]
            #expect(throws: ConfigPlanIssues.self) {
                _ = try ConfigPlanner.plan(document: document, prune: false)
            }
            _ = await AgentManager.shared.delete(id: agent.id)
        }
    }

    @Test func agentAutoPolicyIsHighRiskAndDefaultClearsIt() async throws {
        try await withStorage {
            let agent = probeAgent()
            let document = try ConfigYAML.decode(
                """
                agents:
                  - name: \(agent.name)
                    tools:
                      policies:
                        approvals_probe_tool: auto
                        approvals_probe_other: deny
                """)
            let plan = try ConfigPlanner.plan(document: document, prune: false)
            let action = try #require(plan.actions.first { $0.target == agent.name })
            #expect(action.changes.contains("tools.policies[approvals_probe_tool]: default -> auto"))
            #expect(action.changes.contains("tools.policies[approvals_probe_other]: default -> deny"))
            #expect(action.risks == [ConfigRisk.agentAutoPolicy(agent.name, "approvals_probe_tool")])

            _ = await ConfigApplier.apply(document: document, prune: false)
            #expect(
                AgentManager.shared.agent(for: agent.id)?.settings.toolPolicies
                    == ["approvals_probe_tool": .auto, "approvals_probe_other": .deny])

            let clear = try ConfigYAML.decode(
                """
                agents:
                  - name: \(agent.name)
                    tools:
                      policies:
                        approvals_probe_tool: default
                """)
            _ = await ConfigApplier.apply(document: clear, prune: false)
            #expect(
                AgentManager.shared.agent(for: agent.id)?.settings.toolPolicies
                    == ["approvals_probe_other": .deny])
            _ = await AgentManager.shared.delete(id: agent.id)
        }
    }

    @Test func exportRoundTripsWithoutChanges() async throws {
        try await withStorage {
            var agent = probeAgent()
            agent.settings.toolApprovalMode = .neverAsk
            agent.settings.toolPolicies = ["approvals_probe_tool": .ask]
            AgentManager.shared.update(agent)

            let exported = ConfigExporter.export(sections: [.agents])
            let entry = try #require(exported.agents?.first { $0.name == agent.name })
            #expect(entry.toolApprovals == .neverAsk)
            #expect(entry.tools?.policies == ["approvals_probe_tool": "ask"])
            let replan = try ConfigPlanner.plan(document: exported, prune: false)
            #expect(!replan.actions.contains { $0.target == agent.name }, "\(replan.actions)")
            _ = await AgentManager.shared.delete(id: agent.id)
        }
    }

    @Test func draftsNeverTakeTheKeys() throws {
        var draft = AgentManager.newCustomAgentRecord(name: "Draft Probe")
        var entry = AgentEntry(name: "")
        entry.toolApprovals = .neverAsk
        var tools = AgentToolsEntry()
        tools.policies = ["approvals_probe_tool": "auto"]
        entry.tools = tools
        let outcome = try ConfigApplier.patchDraft(&draft, with: entry)
        #expect(draft.settings.toolApprovalMode == .useGlobal)
        #expect(draft.settings.toolPolicies.isEmpty)
        #expect(outcome.notes.contains { $0.contains("tool_approvals") })
    }

    // MARK: Templates

    @Test func templatesDropTheKeysOnExportAndInstall() async throws {
        try await withStorage {
            var agent = probeAgent()
            agent.settings.toolApprovalMode = .neverAsk
            agent.settings.toolPolicies = ["approvals_probe_tool": .auto]
            AgentManager.shared.update(agent)
            let stored = try #require(AgentManager.shared.agent(for: agent.id))

            let template = Template.make(from: stored)
            #expect(template.agent.toolApprovals == nil)
            #expect(template.agent.tools?.policies == nil)

            var handEdited = template
            var edited = handEdited.agent
            edited.toolApprovals = .neverAsk
            var tools = edited.tools ?? AgentToolsEntry()
            tools.policies = ["approvals_probe_tool": "auto"]
            edited.tools = tools
            handEdited.agent = edited
            let installed = try #require(handEdited.document().agents?.first)
            #expect(installed.toolApprovals == nil)
            #expect(installed.tools?.policies == nil)

            var overrides = AgentEntry(name: "Renamed")
            overrides.tools = tools
            let overridden = try #require(handEdited.document(overrides: overrides).agents?.first)
            #expect(overridden.tools?.policies == nil)
            _ = await AgentManager.shared.delete(id: agent.id)
        }
    }
}
