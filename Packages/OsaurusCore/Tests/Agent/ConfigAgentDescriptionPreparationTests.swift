import Foundation
import Testing
@testable import OsaurusCore

@MainActor
@Suite(.serialized)
struct ConfigAgentDescriptionPreparationTests {
    @Test func templatePromptMatchesGenerationAndPersistence() async throws {
        try await SandboxTestLock.runWithStoragePaths {
            await SubagentStoreTestLock.shared.acquire()
            defer { SubagentStoreTestLock.shared.release() }
            var entry = AgentEntry(name: "Template purpose \(UUID())")
            entry.template = "researcher"
            entry.systemPrompt = "  \n "
            var document = OsaurusConfigDocument()
            document.agents = [entry]
            let expectedPrompt = AgentStarterTemplate.researcher.systemPrompt
            let prepared = try await ConfigAgentDescriptionPreparation.prepare(document) { _, prompt in
                #expect(prompt == expectedPrompt)
                return "Researches questions and verifies evidence."
            }
            #expect(prepared.agents?.first?.systemPrompt == expectedPrompt)
            _ = try ConfigPlanner.plan(document: prepared, prune: false)
            let results = await ConfigApplier.apply(document: prepared, prune: false)
            #expect(results.allSatisfy { $0.status != .failed })
            let saved = try #require(AgentManager.shared.agents.first { $0.name == entry.name })
            #expect(saved.systemPrompt == expectedPrompt)
            #expect(saved.description == "Researches questions and verifies evidence.")
            _ = await AgentManager.shared.delete(id: saved.id)
        }
    }

    @Test func newerManualRepairSurvivesPreparedApply() async throws {
        try await SandboxTestLock.runWithStoragePaths {
            await SubagentStoreTestLock.shared.acquire()
            defer { SubagentStoreTestLock.shared.release() }
            var agent = Agent(name: "Repair race \(UUID())", description: "", systemPrompt: "Check citations.")
            AgentManager.shared.add(agent)
            var entry = AgentEntry(name: agent.name)
            entry.description = ""
            var document = OsaurusConfigDocument()
            document.agents = [entry]
            let prepared = try await ConfigAgentDescriptionPreparation.prepare(document) { _, _ in "Checks citations." }
            agent.description = "Reviews technical writing and verifies its sources."
            AgentManager.shared.update(agent)
            let results = await ConfigApplier.apply(document: prepared, prune: false)
            #expect(results.contains { $0.status == .failed && ($0.message?.contains("changed") ?? false) })
            #expect(AgentManager.shared.agent(for: agent.id)?.description == agent.description)
            _ = await AgentManager.shared.delete(id: agent.id)
        }
    }

    @Test func preparedCreationCannotOverwriteNewlyOccupiedName() async throws {
        try await SandboxTestLock.runWithStoragePaths {
            await SubagentStoreTestLock.shared.acquire()
            defer { SubagentStoreTestLock.shared.release() }
            var entry = AgentEntry(name: "Creation race \(UUID())")
            entry.systemPrompt = "Check citations."
            var document = OsaurusConfigDocument()
            document.agents = [entry]
            let prepared = try await ConfigAgentDescriptionPreparation.prepare(document) { _, _ in "Checks citations." }
            let newer = Agent(name: entry.name, description: "Reviews source code.", systemPrompt: "Review code.")
            AgentManager.shared.add(newer)
            let results = await ConfigApplier.apply(document: prepared, prune: false)
            #expect(results.contains { $0.status == .failed })
            #expect(AgentManager.shared.agent(for: newer.id)?.description == newer.description)
            #expect(AgentManager.shared.agent(for: newer.id)?.systemPrompt == newer.systemPrompt)
            _ = await AgentManager.shared.delete(id: newer.id)
        }
    }

    @Test func generatedDescriptionIsVisibleInPlanWithoutCreatingAgent() async throws {
        let name = "Description proof \(UUID())"
        var entry = AgentEntry(name: name)
        entry.systemPrompt = "Verify sources and citations."
        var document = OsaurusConfigDocument()
        document.agents = [entry]
        let prepared = try await ConfigAgentDescriptionPreparation.prepare(document) { description, prompt in
            #expect(description.isEmpty)
            #expect(prompt == "Verify sources and citations.")
            return "Checks citations when independent source verification is needed."
        }
        #expect(document.agents?.first?.description == nil)
        #expect(prepared.agents?.first?.description == "Checks citations when independent source verification is needed.")
        let plan = try ConfigPlanner.plan(document: prepared, prune: false)
        #expect(plan.summaryText().contains("Checks citations when independent source verification is needed."))
        #expect(!AgentManager.shared.agents.contains { $0.name == name })
    }

    @Test func noPromptDoesNotCallModelAndRemainsInvalid() async throws {
        var document = OsaurusConfigDocument()
        document.agents = [AgentEntry(name: "No prompt \(UUID())")]
        let prepared = try await ConfigAgentDescriptionPreparation.prepare(document) { _, _ in
            Issue.record("No prompt must not generate a generic description")
            return "Generic"
        }
        #expect(throws: ConfigPlanIssues.self) { try ConfigPlanner.plan(document: prepared, prune: false) }
    }

    @Test func suppliedDescriptionIsPreservedWithoutModelCall() async throws {
        var entry = AgentEntry(name: "Manual purpose \(UUID())")
        entry.description = "Reviews Swift changes."
        entry.systemPrompt = "Review source code."
        var document = OsaurusConfigDocument()
        document.agents = [entry]
        let prepared = try await ConfigAgentDescriptionPreparation.prepare(document) { _, _ in
            Issue.record("Explicit description must be preserved")
            return "Replacement"
        }
        #expect(prepared == document)
    }
}
