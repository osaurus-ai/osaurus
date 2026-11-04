//
//  OptionalToolCapabilitiesDeclarativeTests.swift
//  osaurusTests
//
//  The Orchestrator turns per-agent optional tools on through
//  `agents[].capabilities.*_enabled`: Calculator and Redaction Tools are off
//  on a new agent, Task Checklist / Clarify / Artifacts are on. Pins the
//  manifest keys, create-with-flags in one apply, plan diff rows, export
//  round-trip, and the inspect payload.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct OptionalToolCapabilitiesDeclarativeTests {

    private static let keys = [
        "calculator_enabled", "redaction_tools_enabled", "task_checklist_enabled",
        "clarify_enabled", "artifacts_enabled",
    ]

    private func withStorage(_ body: @MainActor @Sendable () async throws -> Void) async throws {
        try await SandboxTestLock.runWithStoragePaths {
            await SubagentStoreTestLock.shared.acquire()
            defer { SubagentStoreTestLock.shared.release() }
            try await body()
        }
    }

    @Test func manifestAdvertisesEveryKey() {
        let known = ConfigManifest.knownKeys["agents[].capabilities"] ?? []
        for key in Self.keys { #expect(known.contains(key), "missing \(key)") }
        #expect(ConfigManifest.renderedSchemaSections(only: [.agents]).contains("calculator_enabled"))
    }

    @Test func newAgentDefaultsAreLean() {
        let settings = AgentSettings(dbEnabled: false, schedule: AgentScheduleSettings.defaults(for: .reactive))
        #expect(!settings.calculatorEnabled)
        #expect(!settings.redactionToolsEnabled)
        #expect(settings.taskChecklistEnabled)
        #expect(settings.clarifyEnabled)
        #expect(settings.artifactsEnabled)
    }

    @Test func storedAgentsWithoutTheKeysDecodeToDefaults() throws {
        let encoded = try JSONEncoder().encode(AgentSettings(dbEnabled: false, schedule: AgentScheduleSettings.defaults(for: .reactive)))
        var object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for key in ["calculatorEnabled", "redactionToolsEnabled", "taskChecklistEnabled", "clarifyEnabled", "artifactsEnabled"] {
            object.removeValue(forKey: key)
        }
        let legacy = try JSONDecoder().decode(
            AgentSettings.self, from: try JSONSerialization.data(withJSONObject: object))
        #expect(!legacy.calculatorEnabled)
        #expect(!legacy.redactionToolsEnabled)
        #expect(legacy.taskChecklistEnabled && legacy.clarifyEnabled && legacy.artifactsEnabled)
    }

    @Test func createWithCalculatorInOneApplyThenExportRoundTrips() async throws {
        try await withStorage {
            let name = "Finance Probe \(UUID().uuidString.prefix(6))"
            let document = try ConfigYAML.decode(
                """
                agents:
                  - name: \(name)
                    description: Reconciles monthly card statements and totals spending.
                    capabilities:
                      calculator_enabled: true
                      clarify_enabled: false
                """)

            let plan = try ConfigPlanner.plan(document: document, prune: false)
            let create = plan.actions.first { $0.section == "agents" && $0.target == name }
            #expect(create?.kind == .create)

            let results = await ConfigApplier.apply(document: document, prune: false)
            #expect(results.allSatisfy { $0.status != .failed }, "\(results)")
            let created = try #require(AgentManager.shared.agents.first { $0.name == name })

            #expect(created.settings.calculatorEnabled)
            #expect(!created.settings.clarifyEnabled)
            #expect(!created.settings.redactionToolsEnabled)
            let caps = AgentManager.shared.effectiveCapabilities(for: created.id)
            #expect(caps.calculatorEnabled && !caps.clarifyEnabled && caps.taskChecklistEnabled)

            let exported = ConfigExporter.export(sections: [.agents])
            let entry = exported.agents?.first { $0.name == name }
            #expect(entry?.capabilities?.calculatorEnabled == true)
            #expect(entry?.capabilities?.clarifyEnabled == false)
            let replan = try ConfigPlanner.plan(document: exported, prune: false)
            #expect(!replan.actions.contains { $0.section == "agents" && $0.target == name }, "\(replan.actions)")

            let payload = AgentCapabilitiesPayload.payload(for: created)
            #expect(payload["calculator_enabled"] as? Bool == true)
            #expect(payload["redaction_tools_enabled"] as? Bool == false)
            _ = await AgentManager.shared.delete(id: created.id)
        }
    }

    @Test func togglingAnExistingAgentPlansAChangeRow() async throws {
        try await withStorage {
            let agent = AgentManager.shared.create(
                name: "Redaction Probe \(UUID().uuidString.prefix(6))",
                description: "Scrubs personal data from shared files.", systemPrompt: "")

            var entry = AgentEntry(name: agent.name)
            var caps = AgentCapabilitiesEntry()
            caps.redactionToolsEnabled = true
            entry.capabilities = caps
            var document = OsaurusConfigDocument()
            document.agents = [entry]

            let plan = try ConfigPlanner.plan(document: document, prune: false)
            let action = plan.actions.first { $0.section == "agents" && $0.target == agent.name }
            #expect(action?.changes.contains { $0.contains("redaction_tools_enabled") } == true)

            _ = await ConfigApplier.apply(document: document, prune: false)
            #expect(AgentManager.shared.agents.first { $0.id == agent.id }?.settings.redactionToolsEnabled == true)
            _ = await AgentManager.shared.delete(id: agent.id)
        }
    }
}
