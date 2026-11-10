//
//  AgentDraftTests.swift
//  OsaurusCoreTests
//
//  The New Agent draft: the store's Configurator patches (same mapping as
//  `osaurus_config`, all-or-nothing, hand edits kept), panel edits and the
//  notes they leave for the Configurator, and the `agent_draft` tool's
//  gate, patch, and tools lookup. Nothing here may add an agent.
//

import Foundation
import Testing

@testable import OsaurusCore

private func entry(_ json: String) throws -> AgentEntry {
    try JSONDecoder().decode(AgentEntry.self, from: Data(json.utf8))
}

private func result(_ envelope: String) -> [String: Any]? {
    guard let object = (try? JSONSerialization.jsonObject(with: Data(envelope.utf8))) as? [String: Any] else {
        return nil
    }
    return object
}

@Suite(.serialized)
@MainActor
struct AgentDraftStoreTests {

    private func freshDraft() -> AgentDraft {
        ConfigurationDomainBootstrap.registerBuiltIns()
        return AgentDraftStore.shared.create(sessionID: UUID().uuidString)
    }

    @Test
    func newDraft_isEmptyAutoModeAndNotAnAgent() {
        let before = AgentManager.shared.agents.count
        let draft = freshDraft()
        defer { AgentDraftStore.shared.delete(draft.id) }
        #expect(draft.isEmpty)
        #expect(!draft.isCreated)
        #expect(draft.agent.toolSelectionMode == .auto)
        #expect(AgentManager.shared.agents.count == before)
        #expect(AgentManager.shared.agent(for: draft.agent.id) == nil)
    }

    @Test
    func unfinishedDrafts_skipEmptyAndCreatedNewestFirst() throws {
        let empty = freshDraft()
        let older = freshDraft()
        let newer = freshDraft()
        let created = freshDraft()
        defer { for d in [empty, older, newer, created] { AgentDraftStore.shared.delete(d.id) } }
        AgentDraftStore.shared.applyUserEdit(older.id, .name) { $0.name = "Older" }
        AgentDraftStore.shared.applyUserEdit(newer.id, .name) { $0.name = "Newer" }
        AgentDraftStore.shared.applyUserEdit(created.id, .name) { $0.name = "Made" }
        AgentDraftStore.shared.markCreated(created.id, agentId: UUID())

        let ours: Set<UUID> = [empty.id, older.id, newer.id, created.id]
        let unfinished = AgentDraftStore.shared.unfinishedDrafts.filter { ours.contains($0.id) }
        #expect(unfinished.map(\.agent.name) == ["Newer", "Older"])
    }

    @Test
    func patch_mapsLikeConfigApplyAndKeepsTheAvatar() throws {
        let draft = freshDraft()
        defer { AgentDraftStore.shared.delete(draft.id) }
        let patch = try entry(
            #"{"name": "Trip Planner", "description": "Plans trips.", "avatar": "green", "model": null,"#
                + #" "system_prompt": "You plan trips.", "capabilities": {"web_search_enabled": true}}"#)
        let outcome = try AgentDraftStore.shared.applyConfiguratorPatch(
            draft.id, entry: patch, reasons: ["web_search_enabled": "Looks up flights."])
        #expect(Set(outcome.changed) == [.name, .description, .avatar, .model, .instructions, .tools])

        let patched = try #require(AgentDraftStore.shared.draft(id: draft.id))
        var expected = draft.agent
        _ = try ConfigApplier.patchDraft(&expected, with: patch)
        #expect(patched.agent.name == expected.name)
        #expect(patched.agent.systemPrompt == expected.systemPrompt)
        #expect(patched.agent.avatar == "green")
        #expect(AgentDraftTool.enabledCapabilities(patched.agent).contains("web_search_enabled"))
        #expect(patched.reasons["web_search_enabled"] == "Looks up flights.")
        #expect(ConfigExporter.exportAgent(patched.agent).avatar == "green")
        #expect(AgentManager.shared.agent(for: draft.agent.id) == nil, "a patch must never save an agent")
    }

    @Test
    func patch_isAllOrNothing() throws {
        let draft = freshDraft()
        defer { AgentDraftStore.shared.delete(draft.id) }
        #expect(throws: AgentDraftStore.PatchError.self) {
            try AgentDraftStore.shared.applyConfiguratorPatch(
                draft.id, entry: try entry(#"{"name": "Bad", "avatar": "not-a-mascot"}"#))
        }
        #expect(AgentDraftStore.shared.draft(id: draft.id)?.agent.name == "")
        #expect(throws: AgentDraftStore.PatchError.self) {
            try AgentDraftStore.shared.applyConfiguratorPatch(
                draft.id,
                entry: try entry(#"{"name": "Bad", "tools": {"mode": "manual", "enabled": ["no_such_tool_xyz"]}}"#))
        }
        let after = try #require(AgentDraftStore.shared.draft(id: draft.id))
        #expect(after.agent.name == "")
        #expect(after.agent.toolSelectionMode == .auto)
    }

    @Test
    func handEdits_winUntilOverriddenAndReachTheNextTurn() throws {
        let draft = freshDraft()
        defer { AgentDraftStore.shared.delete(draft.id) }
        let store = AgentDraftStore.shared
        store.applyUserEdit(draft.id, .name) { $0.name = "Mine" }
        #expect(store.draft(id: draft.id)?.userEdited == [.name])

        let kept = try store.applyConfiguratorPatch(
            draft.id, entry: try entry(#"{"name": "Theirs", "description": "Does things."}"#))
        #expect(kept.keptUserEdits == [.name])
        #expect(kept.changed == [.description])
        #expect(store.draft(id: draft.id)?.agent.name == "Mine")

        let context = try #require(store.takeTurnContext(sessionID: draft.sessionID))
        #expect(context.contains("\"Mine\""))
        #expect(store.takeTurnContext(sessionID: draft.sessionID) == nil, "notes are delivered once")

        _ = try store.applyConfiguratorPatch(
            draft.id, entry: try entry(#"{"name": "Theirs"}"#), overrideUserEdits: true)
        #expect(store.draft(id: draft.id)?.agent.name == "Theirs")
        #expect(store.draft(id: draft.id)?.userEdited.isEmpty == true)
    }

    @Test
    func panelSettings_leaveNoNoteAndCreatedDraftsAreFrozen() throws {
        let draft = freshDraft()
        defer { AgentDraftStore.shared.delete(draft.id) }
        let store = AgentDraftStore.shared
        store.applyPanelSetting(draft.id) { $0.settings.showResponseMetrics = true }
        #expect(store.draft(id: draft.id)?.agent.settings.showResponseMetrics == true)
        #expect(store.takeTurnContext(sessionID: draft.sessionID) == nil)

        store.markCreated(draft.id, agentId: draft.agent.id)
        #expect(throws: AgentDraftStore.PatchError.self) {
            try store.applyConfiguratorPatch(draft.id, entry: try entry(#"{"name": "Later"}"#))
        }
        store.applyUserEdit(draft.id, .name) { $0.name = "Later" }
        #expect(store.draft(id: draft.id)?.agent.name == "")
    }

    @Test
    func drafts_surviveAReload() throws {
        let draft = freshDraft()
        defer { AgentDraftStore.shared.delete(draft.id) }
        _ = try AgentDraftStore.shared.applyConfiguratorPatch(
            draft.id, entry: try entry(#"{"name": "Persisted", "avatar": "orange"}"#))
        AgentDraftStore.shared.reload()
        let loaded = try #require(AgentDraftStore.shared.draft(forSession: draft.sessionID))
        #expect(loaded.agent.name == "Persisted")
        #expect(loaded.agent.avatar == "orange")
        #expect(loaded.touched.contains(.avatar))
    }
}

@Suite(.serialized)
@MainActor
struct AgentDraftToolTests {

    private func run(_ args: String, agentId: UUID = Agent.configuratorId, session: String?) async throws -> [String: Any] {
        let raw = try await ChatExecutionContext.$currentAgentId.withValue(agentId) {
            try await ChatExecutionContext.$currentSessionId.withValue(session) {
                try await AgentDraftTool().execute(argumentsJSON: args)
            }
        }
        return try #require(result(raw), "not JSON: \(raw)")
    }

    @Test
    func onlyTheConfiguratorInADraftChatCanUseIt() async throws {
        ConfigurationDomainBootstrap.registerBuiltIns()
        let draft = AgentDraftStore.shared.create(sessionID: UUID().uuidString)
        defer { AgentDraftStore.shared.delete(draft.id) }
        let other = try await run(#"{"action": "get"}"#, agentId: Agent.defaultId, session: draft.sessionID)
        #expect(other["ok"] as? Bool == false)
        let noDraft = try await run(#"{"action": "get"}"#, session: UUID().uuidString)
        #expect(noDraft["ok"] as? Bool == false)
        let ok = try await run(#"{"action": "get"}"#, session: draft.sessionID)
        #expect(ok["ok"] as? Bool == true)
    }

    @Test
    func patch_returnsTheDraftAndRejectsUnknownKeys() async throws {
        ConfigurationDomainBootstrap.registerBuiltIns()
        let draft = AgentDraftStore.shared.create(sessionID: UUID().uuidString)
        defer { AgentDraftStore.shared.delete(draft.id) }
        let bad = try await run(#"{"action": "patch", "agent": {"persona": "x"}}"#, session: draft.sessionID)
        #expect(bad["ok"] as? Bool == false)

        let good = try await run(
            #"{"action": "patch", "agent": {"name": "Scout", "avatar": "blue"}, "why": "Fits a lookout."}"#,
            session: draft.sessionID)
        #expect(good["ok"] as? Bool == true)
        let body = try #require(good["result"] as? [String: Any])
        #expect(Set(body["changed"] as? [String] ?? []) == ["name", "avatar"])
        let summary = try #require(body["draft"] as? [String: Any])
        #expect(summary["name"] as? String == "Scout")
        #expect(summary["created"] as? Bool == false)
        #expect(AgentDraftStore.shared.draft(id: draft.id)?.reasons["avatar"] == "Fits a lookout.")
        #expect(AgentManager.shared.agent(for: draft.agent.id) == nil)
    }

    @Test
    func toolsLookup_returnsExactAssignableNames() async throws {
        ConfigurationDomainBootstrap.registerBuiltIns()
        let draft = AgentDraftStore.shared.create(sessionID: UUID().uuidString)
        defer { AgentDraftStore.shared.delete(draft.id) }
        let response = try await run(#"{"action": "tools", "query": "web search"}"#, session: draft.sessionID)
        let body = try #require(response["result"] as? [String: Any])
        let capabilities = try #require(body["capabilities"] as? [[String: Any]])
        #expect(capabilities.contains { $0["key"] as? String == "web_search_enabled" })
        let assignable = Set(ToolRegistry.shared.listDynamicTools().map(\.name))
        for row in body["tools"] as? [[String: Any]] ?? [] {
            let name = try #require(row["name"] as? String)
            #expect(assignable.contains(name), "\(name) is not an assignable tool")
        }
    }
}
