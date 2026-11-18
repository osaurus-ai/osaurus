//
//  AgentDraftCreateBlockerTests.swift
//  OsaurusCoreTests
//
//  The Configurator learns why Create Agent is off: `agent_draft` reports
//  `can_create` and, when a name is missing or taken, `create_blocked`.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct AgentDraftCreateBlockerTests {
    private func freshDraft() -> AgentDraft {
        ConfigurationDomainBootstrap.registerBuiltIns()
        return AgentDraftStore.shared.create(sessionID: UUID().uuidString)
    }

    @Test
    func aDraftWithoutANameCannotBeCreated() {
        let draft = freshDraft()
        defer { AgentDraftStore.shared.delete(draft.id) }
        let summary = AgentDraftTool.summary(draft)
        #expect(summary["can_create"] as? Bool == false)
        #expect(summary["create_blocked"] is String)
    }

    @Test
    func aTakenNameIsReportedWithWhoSetIt() async throws {
        let name = "Create blocker \(UUID().uuidString.prefix(8))"
        let existing = Agent(name: name)
        AgentManager.shared.add(existing)
        let draft = freshDraft()
        do {
            try checkTakenName(name, draft: draft)
        } catch {
            AgentDraftStore.shared.delete(draft.id)
            _ = await AgentManager.shared.delete(id: existing.id)
            throw error
        }
        AgentDraftStore.shared.delete(draft.id)
        _ = await AgentManager.shared.delete(id: existing.id)
    }

    private func checkTakenName(_ name: String, draft: AgentDraft) throws {
        let store = AgentDraftStore.shared

        _ = try store.applyConfiguratorPatch(
            draft.id, entry: try JSONDecoder().decode(AgentEntry.self, from: Data(#"{"name": " \#(name.lowercased()) "}"#.utf8)))
        let chosen = AgentDraftTool.summary(try #require(store.draft(id: draft.id)))
        #expect(chosen["can_create"] as? Bool == false)
        let chosenReason = try #require(chosen["create_blocked"] as? String)
        #expect(chosenReason.contains("Patch a different name"))

        store.applyUserEdit(draft.id, .name) { $0.name = name }
        let typed = AgentDraftTool.summary(try #require(store.draft(id: draft.id)))
        let typedReason = try #require(typed["create_blocked"] as? String)
        #expect(typedReason.contains("override_user_edits"))

        store.applyUserEdit(draft.id, .name) { $0.name = name + " Two" }
        let free = AgentDraftTool.summary(try #require(store.draft(id: draft.id)))
        #expect(free["can_create"] as? Bool == true)
        #expect(free["create_blocked"] == nil)
    }
}
