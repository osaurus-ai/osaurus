//
//  ConfigurationGapClosureTests.swift
//  OsaurusCoreTests
//
//  Functional coverage for the configuration-agent gap-closure surfaces:
//
//   * osaurus_list / osaurus_describe — new read scopes (skills, watchers,
//     knowledge, themes, commands, channels, search) return well-formed
//     payloads from live state.
//   * osaurus_status — the enriched snapshot carries the server / memory /
//     sandbox / channels / watchers / skills / knowledge rollups.
//   * osaurus_agent update `capabilities` — safe per-agent toggles,
//     knowledge grants, theme_id, with validation of unknown keys and
//     unknown grant/theme ids.
//   * osaurus_schedule update `agent_id` — schedules move between custom
//     agents; the Default agent stays refused.
//   * osaurus_watcher — create / update / enable / disable / delete plus
//     directory-path validation.
//
//  All mutations run against the OSAURUS_TEST_ROOT-scoped stores and are
//  cleaned up (delete created agents/schedules/watchers) so the suite
//  leaves no residue for sibling suites.
//

import Foundation
import Testing

@testable import OsaurusCore

// MARK: - Shared helpers

private func parseEnvelope(_ envelope: String) throws -> [String: Any] {
    let data = try #require(envelope.data(using: .utf8))
    let obj = try JSONSerialization.jsonObject(with: data)
    return try #require(obj as? [String: Any])
}

/// Run a configure tool as the Default agent and parse its envelope.
private func runAsDefaultAgent(
    _ tool: any OsaurusTool, _ argumentsJSON: String
) async throws -> [String: Any] {
    let envelope = try await ChatExecutionContext.$currentAgentId.withValue(Agent.defaultId) {
        try await tool.execute(argumentsJSON: argumentsJSON)
    }
    return try parseEnvelope(envelope)
}

// MARK: - Read scopes

@Suite(.serialized)
struct ConfigurationReadScopeFunctionalTests {

    @Test
    func list_skillsScope_returnsRowsWithOriginFlags() async throws {
        let dict = try await runAsDefaultAgent(OsaurusListTool(), #"{"scope": "skills"}"#)
        #expect(dict["ok"] as? Bool == true)
        let result = try #require(dict["result"] as? [String: Any])
        #expect(result["scope"] as? String == "skills")
        let items = try #require(result["items"] as? [[String: Any]])
        // Built-in skills ship with the app, so the scope is never empty.
        #expect(!items.isEmpty)
        for item in items {
            #expect(item["id"] as? String != nil)
            #expect(item["name"] as? String != nil)
            #expect(item["built_in"] as? Bool != nil)
            #expect(item["from_plugin"] as? Bool != nil)
        }
    }

    @Test
    func list_commandsScope_includesBuiltIns() async throws {
        let dict = try await runAsDefaultAgent(OsaurusListTool(), #"{"scope": "commands"}"#)
        #expect(dict["ok"] as? Bool == true)
        let result = try #require(dict["result"] as? [String: Any])
        let items = try #require(result["items"] as? [[String: Any]])
        #expect(items.contains { ($0["built_in"] as? Bool) == true })
    }

    @Test
    func list_themesScope_marksTheActiveTheme() async throws {
        let dict = try await runAsDefaultAgent(OsaurusListTool(), #"{"scope": "themes"}"#)
        #expect(dict["ok"] as? Bool == true)
        let result = try #require(dict["result"] as? [String: Any])
        let items = try #require(result["items"] as? [[String: Any]])
        // Built-in presets are installed on first list.
        #expect(!items.isEmpty)
        for item in items {
            #expect(item["active"] as? Bool != nil)
            #expect(item["built_in"] as? Bool != nil)
        }
    }

    @Test
    func list_knowledgeWatchersChannels_returnWellFormedPayloads() async throws {
        for scope in ["knowledge", "watchers", "channels"] {
            let dict = try await runAsDefaultAgent(
                OsaurusListTool(), "{\"scope\": \"\(scope)\"}"
            )
            #expect(dict["ok"] as? Bool == true, "scope \(scope) should list")
            let result = try #require(dict["result"] as? [String: Any])
            #expect(result["scope"] as? String == scope)
            #expect(result["items"] as? [[String: Any]] != nil, "scope \(scope) items missing")
        }
    }

    @Test
    func list_searchScope_mirrorsProviderRanking() async throws {
        let dict = try await runAsDefaultAgent(OsaurusListTool(), #"{"scope": "search"}"#)
        #expect(dict["ok"] as? Bool == true)
        let result = try #require(dict["result"] as? [String: Any])
        let items = try #require(result["items"] as? [[String: Any]])
        for item in items {
            #expect(item["id"] as? String != nil)
            #expect(item["rank"] as? Int != nil)
            #expect(item["enabled"] as? Bool != nil)
        }
    }

    @Test
    func describe_skillByName_matchesCaseInsensitively() async throws {
        // Pick a real skill from the list, then describe it by lowercased name.
        let listDict = try await runAsDefaultAgent(OsaurusListTool(), #"{"scope": "skills"}"#)
        let listResult = try #require(listDict["result"] as? [String: Any])
        let items = try #require(listResult["items"] as? [[String: Any]])
        let first = try #require(items.first)
        let skillName = try #require(first["name"] as? String)

        let dict = try await runAsDefaultAgent(
            OsaurusDescribeTool(),
            "{\"scope\": \"skills\", \"id\": \"\(skillName.lowercased())\"}"
        )
        #expect(dict["ok"] as? Bool == true)
        let result = try #require(dict["result"] as? [String: Any])
        #expect((result["name"] as? String)?.caseInsensitiveCompare(skillName) == .orderedSame)
        #expect(result["keywords"] as? [String] != nil)
    }

    @Test
    func describe_unknownIdInNewScopes_failsCleanly() async throws {
        for scope in ["skills", "watchers", "knowledge", "themes", "commands", "channels", "search"] {
            let dict = try await runAsDefaultAgent(
                OsaurusDescribeTool(),
                "{\"scope\": \"\(scope)\", \"id\": \"definitely-not-a-real-id\"}"
            )
            #expect(dict["ok"] as? Bool == false, "scope \(scope) should not find the id")
            #expect(dict["kind"] as? String == "invalid_args")
        }
    }

    @Test
    func describe_agent_includesCapabilities() async throws {
        let agent = await MainActor.run {
            AgentManager.shared.create(
                name: "GapClosure Describe Probe",
                description: "",
                systemPrompt: "",
                defaultModel: nil,
                temperature: nil,
                maxTokens: nil
            )
        }
        defer { Task { _ = await AgentManager.shared.delete(id: agent.id) } }

        let dict = try await runAsDefaultAgent(
            OsaurusDescribeTool(),
            "{\"scope\": \"agents\", \"id\": \"\(agent.id.uuidString)\"}"
        )
        #expect(dict["ok"] as? Bool == true)
        let result = try #require(dict["result"] as? [String: Any])
        let capabilities = try #require(result["capabilities"] as? [String: Any])
        #expect(capabilities["tools_enabled"] as? Bool == true)
        #expect(capabilities["browser_use_enabled"] as? Bool == false)
        #expect(capabilities["knowledge_collection_ids"] as? [String] != nil)

        _ = await AgentManager.shared.delete(id: agent.id)
    }

    @Test
    func status_carriesTheEnrichedRollups() async throws {
        let dict = try await runAsDefaultAgent(OsaurusStatusTool(), "{}")
        #expect(dict["ok"] as? Bool == true)
        let result = try #require(dict["result"] as? [String: Any])

        let server = try #require(result["server"] as? [String: Any])
        #expect(server["running"] as? Bool != nil)
        #expect(server["port"] as? Int != nil)

        let memory = try #require(result["memory"] as? [String: Any])
        #expect(memory["enabled"] as? Bool != nil)

        let sandbox = try #require(result["sandbox"] as? [String: Any])
        #expect(sandbox["provisioned"] as? Bool != nil)
        #expect(sandbox["state"] as? String != nil)

        let channels = try #require(result["channels"] as? [String: Any])
        #expect(channels["configured"] as? Int != nil)

        let watchers = try #require(result["watchers"] as? [String: Any])
        #expect(watchers["total"] as? Int != nil)

        let skills = try #require(result["skills"] as? [String: Any])
        #expect(skills["installed"] as? Int != nil)

        let knowledge = try #require(result["knowledge"] as? [String: Any])
        #expect(knowledge["collections"] as? Int != nil)
    }
}

// MARK: - osaurus_agent capabilities

@Suite(.serialized)
struct AgentCapabilitiesPatchTests {

    private func makeAgent(_ name: String) async -> Agent {
        await MainActor.run {
            AgentManager.shared.create(
                name: name,
                description: "",
                systemPrompt: "",
                defaultModel: nil,
                temperature: nil,
                maxTokens: nil
            )
        }
    }

    @Test
    func update_capabilitiesPatchesSafeTogglesAndPersists() async throws {
        let agent = await makeAgent("GapClosure Capabilities Probe")
        defer { Task { _ = await AgentManager.shared.delete(id: agent.id) } }

        let dict = try await runAsDefaultAgent(
            OsaurusAgentTool(),
            """
            {"action": "update", "id": "\(agent.id.uuidString)", "capabilities": {
                "browser_use_enabled": true,
                "web_search_enabled": false,
                "speak_enabled": true,
                "memory_enabled": false,
                "knowledge_collection_ids": []
            }}
            """
        )
        #expect(dict["ok"] as? Bool == true)

        let saved = try #require(await MainActor.run { AgentManager.shared.agent(for: agent.id) }
        )
        #expect(saved.settings.browserUseEnabled == true)
        #expect(saved.settings.webSearchEnabled == false)
        #expect(saved.settings.speakEnabled == true)
        #expect(saved.memoryEnabled == false)
        #expect(saved.settings.knowledgeCollectionIds.isEmpty)

        _ = await AgentManager.shared.delete(id: agent.id)
    }

    @Test
    func update_knowledgeEnabledWithoutGrants_notesHiddenTools() async throws {
        let agent = await makeAgent("GapClosure Knowledge Note Probe")
        defer { Task { _ = await AgentManager.shared.delete(id: agent.id) } }

        let dict = try await runAsDefaultAgent(
            OsaurusAgentTool(),
            """
            {"action": "update", "id": "\(agent.id.uuidString)", "capabilities": {
                "knowledge_enabled": true
            }}
            """
        )
        #expect(dict["ok"] as? Bool == true)
        let result = try #require(dict["result"] as? [String: Any])
        let note = try #require(result["note"] as? String)
        #expect(note.contains("knowledge_collection_ids"))

        _ = await AgentManager.shared.delete(id: agent.id)
    }

    @Test
    func update_rejectsUnknownCapabilityNamingTheUIOnlyBoundary() async throws {
        let agent = await makeAgent("GapClosure Unknown Cap Probe")
        defer { Task { _ = await AgentManager.shared.delete(id: agent.id) } }

        let dict = try await runAsDefaultAgent(
            OsaurusAgentTool(),
            """
            {"action": "update", "id": "\(agent.id.uuidString)", "capabilities": {
                "spawn_delegation_enabled": true
            }}
            """
        )
        #expect(dict["ok"] as? Bool == false)
        #expect(dict["kind"] as? String == "invalid_args")
        let message = try #require(dict["message"] as? String)
        #expect(message.contains("spawn_delegation_enabled"))
        #expect(message.contains("Settings"))

        _ = await AgentManager.shared.delete(id: agent.id)
    }

    @Test
    func update_rejectsUnknownKnowledgeCollectionIds() async throws {
        let agent = await makeAgent("GapClosure Grant Probe")
        defer { Task { _ = await AgentManager.shared.delete(id: agent.id) } }

        let phantom = UUID().uuidString
        let dict = try await runAsDefaultAgent(
            OsaurusAgentTool(),
            """
            {"action": "update", "id": "\(agent.id.uuidString)", "capabilities": {
                "knowledge_collection_ids": ["\(phantom)"]
            }}
            """
        )
        #expect(dict["ok"] as? Bool == false)
        let message = try #require(dict["message"] as? String)
        #expect(message.contains(phantom))

        _ = await AgentManager.shared.delete(id: agent.id)
    }

    @Test
    func update_rejectsUnknownThemeIdAndAcceptsRealOne() async throws {
        let agent = await makeAgent("GapClosure Theme Probe")
        defer { Task { _ = await AgentManager.shared.delete(id: agent.id) } }

        // Unknown theme → refused.
        let bad = try await runAsDefaultAgent(
            OsaurusAgentTool(),
            """
            {"action": "update", "id": "\(agent.id.uuidString)", "capabilities": {
                "theme_id": "\(UUID().uuidString)"
            }}
            """
        )
        #expect(bad["ok"] as? Bool == false)
        #expect(bad["field"] as? String == "theme_id")

        // A real installed theme → applied; null → cleared.
        let themeId = await MainActor.run {
            ThemeConfigurationStore.listThemes().first?.metadata.id
        }
        let realThemeId = try #require(themeId)
        let good = try await runAsDefaultAgent(
            OsaurusAgentTool(),
            """
            {"action": "update", "id": "\(agent.id.uuidString)", "capabilities": {
                "theme_id": "\(realThemeId.uuidString)"
            }}
            """
        )
        #expect(good["ok"] as? Bool == true)
        var saved = try #require(await MainActor.run { AgentManager.shared.agent(for: agent.id) }
        )
        #expect(saved.themeId == realThemeId)

        let cleared = try await runAsDefaultAgent(
            OsaurusAgentTool(),
            """
            {"action": "update", "id": "\(agent.id.uuidString)", "capabilities": {
                "theme_id": null
            }}
            """
        )
        #expect(cleared["ok"] as? Bool == true)
        saved = try #require(await MainActor.run { AgentManager.shared.agent(for: agent.id) }
        )
        #expect(saved.themeId == nil)

        _ = await AgentManager.shared.delete(id: agent.id)
    }
}

// MARK: - osaurus_schedule agent_id reassignment

@Suite(.serialized)
struct ScheduleReassignmentTests {

    @Test
    func update_movesScheduleToAnotherCustomAgent() async throws {
        let (agentA, agentB) = await MainActor.run {
            (
                AgentManager.shared.create(
                    name: "GapClosure Sched A", description: "", systemPrompt: "",
                    defaultModel: nil, temperature: nil, maxTokens: nil
                ),
                AgentManager.shared.create(
                    name: "GapClosure Sched B", description: "", systemPrompt: "",
                    defaultModel: nil, temperature: nil, maxTokens: nil
                )
            )
        }
        defer {
            Task {
                _ = await AgentManager.shared.delete(id: agentA.id)
                _ = await AgentManager.shared.delete(id: agentB.id)
            }
        }

        let created = try await runAsDefaultAgent(
            OsaurusScheduleTool(),
            """
            {"action": "create", "name": "GapClosure Move Probe",
             "instructions": "do the thing", "agent_id": "\(agentA.id.uuidString)",
             "frequency": "daily", "frequency_time_of_day": "09:00", "enabled": false}
            """
        )
        #expect(created["ok"] as? Bool == true)
        let createdResult = try #require(created["result"] as? [String: Any])
        let scheduleIdStr = try #require(createdResult["schedule_id"] as? String)
        let scheduleId = try #require(UUID(uuidString: scheduleIdStr))
        defer {
            Task { _ = await MainActor.run { ScheduleManager.shared.delete(id: scheduleId) } }
        }

        // Move it to agent B.
        let moved = try await runAsDefaultAgent(
            OsaurusScheduleTool(),
            """
            {"action": "update", "id": "\(scheduleIdStr)", "agent_id": "\(agentB.id.uuidString)"}
            """
        )
        #expect(moved["ok"] as? Bool == true)
        // ScheduleManager's async init load can land after the tool's
        // in-memory update and clobber it with a stale disk snapshot.
        // Re-reading through the serial IO queue (ordered after the
        // update's save) makes the assertion deterministic.
        await ScheduleManager.shared.refreshFromDisk()
        let schedule = try #require(await MainActor.run { ScheduleManager.shared.schedule(for: scheduleId) }
        )
        #expect(schedule.agentId == agentB.id)

        // The Default agent stays refused on update, same as create.
        let refused = try await runAsDefaultAgent(
            OsaurusScheduleTool(),
            """
            {"action": "update", "id": "\(scheduleIdStr)", "agent_id": "\(Agent.defaultId.uuidString)"}
            """
        )
        #expect(refused["ok"] as? Bool == false)
        #expect(refused["field"] as? String == "agent_id")

        // Unknown agents are refused before anything persists.
        let unknown = try await runAsDefaultAgent(
            OsaurusScheduleTool(),
            """
            {"action": "update", "id": "\(scheduleIdStr)", "agent_id": "\(UUID().uuidString)"}
            """
        )
        #expect(unknown["ok"] as? Bool == false)

        _ = await MainActor.run { ScheduleManager.shared.delete(id: scheduleId) }
        _ = await AgentManager.shared.delete(id: agentA.id)
        _ = await AgentManager.shared.delete(id: agentB.id)
    }
}

// MARK: - osaurus_watcher

@Suite(.serialized)
struct WatcherConfigurationDomainTests {

    private func makeTempWatchDirectory() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("osaurus-watcher-tool-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test
    func createUpdateToggleDelete_roundTrips() async throws {
        let dir = try makeTempWatchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Watchers must target a custom agent (the runtime refuses nil /
        // built-in agentIds at dispatch), so seed one for the round trip.
        let agent = await MainActor.run {
            AgentManager.shared.create(
                name: "GapClosure Watch Agent", description: "", systemPrompt: "",
                defaultModel: nil, temperature: nil, maxTokens: nil
            )
        }
        defer { Task { _ = await AgentManager.shared.delete(id: agent.id) } }

        // Create disabled so the FSEvents stream never starts for this probe.
        let created = try await runAsDefaultAgent(
            OsaurusWatcherTool(),
            """
            {"action": "create", "name": "GapClosure Watch Probe",
             "instructions": "organize new files", "path": "\(dir.path)",
             "agent_id": "\(agent.id.uuidString)",
             "enabled": false, "responsiveness": "patient", "recursive": true}
            """
        )
        #expect(created["ok"] as? Bool == true)
        let createdResult = try #require(created["result"] as? [String: Any])
        let watcherIdStr = try #require(createdResult["watcher_id"] as? String)
        let watcherId = try #require(UUID(uuidString: watcherIdStr))
        defer {
            Task { _ = await MainActor.run { WatcherManager.shared.delete(id: watcherId) } }
        }

        var watcher = try #require(await MainActor.run { WatcherManager.shared.watchers.first { $0.id == watcherId } }
        )
        #expect(watcher.watchPath == dir.path)
        #expect(watcher.isEnabled == false)
        #expect(watcher.recursive == true)
        #expect(watcher.responsiveness == .patient)
        #expect(watcher.agentId == agent.id)

        // Patch instructions + responsiveness.
        let updated = try await runAsDefaultAgent(
            OsaurusWatcherTool(),
            """
            {"action": "update", "id": "\(watcherIdStr)",
             "instructions": "rename screenshots", "responsiveness": "fast"}
            """
        )
        #expect(updated["ok"] as? Bool == true)
        watcher = try #require(await MainActor.run { WatcherManager.shared.watchers.first { $0.id == watcherId } }
        )
        #expect(watcher.instructions == "rename screenshots")
        #expect(watcher.responsiveness == .fast)

        // Enable, then disable via the first-class actions.
        let enabled = try await runAsDefaultAgent(
            OsaurusWatcherTool(), #"{"action": "enable", "id": "\#(watcherIdStr)"}"#
        )
        #expect(enabled["ok"] as? Bool == true)
        watcher = try #require(await MainActor.run { WatcherManager.shared.watchers.first { $0.id == watcherId } }
        )
        #expect(watcher.isEnabled == true)

        let disabled = try await runAsDefaultAgent(
            OsaurusWatcherTool(), #"{"action": "disable", "id": "\#(watcherIdStr)"}"#
        )
        #expect(disabled["ok"] as? Bool == true)
        watcher = try #require(await MainActor.run { WatcherManager.shared.watchers.first { $0.id == watcherId } }
        )
        #expect(watcher.isEnabled == false)

        // Delete removes it from live state.
        let deleted = try await runAsDefaultAgent(
            OsaurusWatcherTool(), #"{"action": "delete", "id": "\#(watcherIdStr)"}"#
        )
        #expect(deleted["ok"] as? Bool == true)
        let stillThere = await MainActor.run {
            WatcherManager.shared.watchers.contains { $0.id == watcherId }
        }
        #expect(stillThere == false)
    }

    @Test
    func create_rejectsMissingDirectory() async throws {
        let dict = try await runAsDefaultAgent(
            OsaurusWatcherTool(),
            """
            {"action": "create", "name": "Bad Path Probe",
             "instructions": "x", "path": "/definitely/not/a/real/dir/\(UUID().uuidString)"}
            """
        )
        #expect(dict["ok"] as? Bool == false)
        #expect(dict["field"] as? String == "path")
    }

    @Test
    func create_listsAllMissingRequiredFieldsAtOnce() async throws {
        let dict = try await runAsDefaultAgent(
            OsaurusWatcherTool(), #"{"action": "create"}"#
        )
        #expect(dict["ok"] as? Bool == false)
        let message = try #require(dict["message"] as? String)
        #expect(message.contains("name"))
        #expect(message.contains("instructions"))
        #expect(message.contains("path"))
        #expect(message.contains("agent_id"))
    }

    @Test
    func create_rejectsTheDefaultAgent() async throws {
        let dir = try makeTempWatchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        // The runtime skips watchers with nil/built-in agentIds, so the tool
        // must refuse the Default agent's id up front instead of creating a
        // watcher that would never fire.
        let dict = try await runAsDefaultAgent(
            OsaurusWatcherTool(),
            """
            {"action": "create", "name": "Default Agent Probe",
             "instructions": "x", "path": "\(dir.path)",
             "agent_id": "\(Agent.defaultId.uuidString)", "enabled": false}
            """
        )
        #expect(dict["ok"] as? Bool == false)
        #expect(dict["field"] as? String == "agent_id")
        let message = try #require(dict["message"] as? String)
        #expect(message.contains("custom"))
    }

    @Test
    func create_rejectsUnknownAgent() async throws {
        let dir = try makeTempWatchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let dict = try await runAsDefaultAgent(
            OsaurusWatcherTool(),
            """
            {"action": "create", "name": "Unknown Agent Probe",
             "instructions": "x", "path": "\(dir.path)", "agent_id": "\(UUID().uuidString)",
             "enabled": false}
            """
        )
        #expect(dict["ok"] as? Bool == false)
        #expect(dict["field"] as? String == "agent_id")
    }
}
