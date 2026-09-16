// Copyright © 2026 osaurus.

import Foundation
import Testing

/// Source-level pins for the shared Spawn editor (Settings → Orchestrator
/// and the custom-agent sheet). These guard the simplified delegation
/// surface: one `spawn_agent` tool, agents (local + shared) as the only
/// targets, Always Allow as the local default, and stale pool entries
/// pruned instead of rendered as "Unavailable".
@Suite("Spawn configuration UI source")
struct SpawnConfigurationUISourceTests {
    private static func packageRoot() -> URL {
        let here = URL(fileURLWithPath: #filePath)
        var cursor = here.deletingLastPathComponent()  // Agent/
        cursor.deleteLastPathComponent()  // Tests/
        return cursor.deletingLastPathComponent()  // OsaurusCore/
    }

    private static func source(_ relativePath: String) throws -> String {
        let url = packageRoot().appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("custom agents and main chat reuse one Spawn editor")
    func sharedEditorIsUsedByBothSurfaces() throws {
        let agents = try Self.source("Views/Agent/AgentsView.swift")
        let settings = try Self.source("Views/Settings/SubagentSettingsSection.swift")
        let editor = try Self.source("Views/Agent/SpawnConfigurationEditor.swift")

        #expect(agents.components(separatedBy: "SpawnConfigurationEditor(").count - 1 == 1)
        #expect(settings.components(separatedBy: "SpawnConfigurationEditor(").count - 1 == 1)
        #expect(settings.contains(#"label: "Allowed subagents""#))
        // Labels converge on "subagent" / "delegate"; "Spawn" survives only
        // in tool ids.
        #expect(!settings.contains(#"label: "Main Chat Spawn""#))
        #expect(editor.contains(#"Text("Allowed subagents", bundle: .module)"#))
        #expect(editor.contains(#"AgentSheetSectionLabel("Allowed agents")"#))
        #expect(editor.contains(#"AgentSheetSectionLabel("Allowed shared agents")"#))
        #expect(editor.contains(#"AgentSheetSectionLabel("Limits")"#))
        #expect(editor.contains(#"title: "Max output tokens per subagent""#))
        #expect(editor.contains(#"title: "Max turns per subagent""#))
        #expect(editor.contains(#"title: "Time limit per subagent (seconds)""#))
        #expect(editor.contains(#"title: "Max local subagents at once""#))
        #expect(editor.contains(#"title: "Max remote subagents at once""#))
        #expect(editor.contains(#"keyPath: \.maxRemoteParallelSpawns"#))

        // Bare-model workers and their tool-access switch are gone: the
        // worker IS the agent, with its own tools and Working Folder.
        #expect(!editor.contains(#"AgentSheetSectionLabel("Allowed models")"#))
        #expect(!editor.contains("maxToolCalls"))
        #expect(!editor.contains("Let model subagents read files"))
        #expect(!editor.contains("SpawnToolAccess"))
        #expect(editor.contains("Agents with their own Working Folder read and write files there."))
        #expect(editor.contains("inherit the Orchestrator's Working Folder for the run"))
    }

    @Test("starter agents and Always Allow are the out-of-the-box path")
    func starterAgentsAndDefaultPermission() throws {
        let editor = try Self.source("Views/Agent/SpawnConfigurationEditor.swift")

        #expect(editor.contains(#"Text("Create starter agents", bundle: .module)"#))
        #expect(editor.contains("agentManager.createStarterAgents()"))
        #expect(editor.contains("Always Allow is the default"))
        #expect(editor.contains(#""Permission for shared (workspace) agents""#))
        #expect(editor.contains("SubagentPermissionDefaults.workspaceSpawnKindId"))
    }

    @Test("open custom-agent editor refreshes shared handoff and concurrency state")
    func customAgentEditorObservesGlobalSubagentChanges() throws {
        let agents = try Self.source("Views/Agent/AgentsView.swift")

        #expect(
            agents.contains(
                "NotificationCenter.default.publisher(for: .subagentConfigurationChanged)"
            )
        )
        #expect(agents.contains("let latest = SubagentConfigurationStore.snapshot()"))
        #expect(
            agents.contains(
                "if latest != globalSubagentConfig { globalSubagentConfig = latest }"
            )
        )
        #expect(agents.contains("budgets: sharedSpawnBudgetsBinding"))
        #expect(
            agents.contains(
                "SpawnBatchConcurrencyContract.applyingSharedLimit("
            )
        )
        #expect(agents.contains("ServerController.applyAgentSpawnBatchLimit(requested)"))
    }

    @Test("shared global editors use revision-safe three-way store saves")
    func globalEditorsDoNotReplaceStaleSharedSnapshots() throws {
        let paths = [
            "Views/Settings/OrchestratorSettingsView.swift",
            "Views/Model/AppleScriptModelsView.swift",
            "Views/ImageGeneration/ImageGenerationView.swift",
        ]

        for path in paths {
            let source = try Self.source(path)
            #expect(source.contains("Baseline"))
            #expect(source.contains("SubagentConfigurationStore.saveEditorSnapshot("))
            #expect(source.contains("loadedBaseline:"))
            #expect(source.contains("SubagentConfiguration.mergingEditorSnapshot("))
            #expect(!source.contains("SubagentConfigurationStore.save(newValue)"))
        }
    }

    @Test("Main Chat batch edits use an origin-aware Server update path")
    func mainChatBatchEditsUpdateServerWithoutNotificationEchoes() throws {
        let settings = try Self.source("Views/Settings/OrchestratorSettingsView.swift")
        let controller = try Self.source("Networking/ServerController.swift")

        #expect(settings.contains("server.applyMainChatBatchLimit(from: saved)"))
        #expect(settings.contains("let batchLimitWasExplicitlyEdited ="))
        #expect(settings.contains("if batchLimitWasExplicitlyEdited"))
        #expect(controller.contains("func applyMainChatBatchLimit("))
        #expect(controller.contains("synchronizeSpawnBatchLimit(from: latest)"))
        #expect(controller.contains("static func applyAgentSpawnBatchLimit("))
        #expect(controller.contains("func applySpawnBatchLimit("))
        #expect(
            controller.contains(
                "runtimeSettings.concurrency.maxConcurrentSequences != requested"
            )
        )
        #expect(!controller.contains("subagentConfigurationCancellable"))
    }

    @Test("runtime spawn boundaries inject the canonical Server concurrency")
    func runtimeSpawnBoundariesUseCanonicalServerLimit() throws {
        let snapshot = try Self.source("Services/Chat/AgentConfigSnapshot.swift")
        let textSpawn = try Self.source("Subagent/Kinds/TextSubagentKind.swift")
        let fanOut = try Self.source("Subagent/SpawnFanOutPolicy.swift")
        let visibility = try Self.source(
            "Subagent/SubagentCapabilityRegistry.swift"
        )

        #expect(snapshot.contains("for: ServerRuntimeSettingsStore.snapshot()"))
        #expect(snapshot.contains("sharedParallelLimit: sharedParallelLimit"))
        #expect(textSpawn.contains("for: ServerRuntimeSettingsStore.snapshot()"))
        #expect(textSpawn.contains("sharedParallelLimit: sharedParallelLimit"))
        // The wave policy (several spawn_agent calls in one message) reads
        // the same canonical source.
        #expect(fanOut.contains("for: ServerRuntimeSettingsStore.snapshot()"))
        #expect(fanOut.contains("sharedParallelLimit: SpawnBatchConcurrencyContract.configuredLimit("))

        // Keep the budget merger pure: every production boundary must name the
        // canonical source explicitly, while hand-built frozen-schema tests can
        // inject the persisted mirror without reading developer-machine state.
        #expect(!visibility.contains("ServerRuntimeSettingsStore.snapshot()"))
        #expect(visibility.contains("sharedParallelLimit: Int"))
    }

    @Test("capacity contract and shared-agent roster refresh stay in the shared editor")
    func sharedEditorOwnsRefreshStatusAndCapacityCopy() throws {
        let editor = try Self.source("Views/Agent/SpawnConfigurationEditor.swift")
        let concurrency = try Self.source(
            "Views/Settings/ServerSettings/ConcurrencySection.swift"
        )

        #expect(editor.contains(".task(id: workspaceAgentPickerPresented)"))
        // The `addable.isEmpty` gates belong to Add Agent and Add Shared
        // Agent; there is no model picker any more.
        #expect(
            editor.components(separatedBy: #"disabled: addable.isEmpty"#).count - 1 == 2
        )
        #expect(editor.contains(#"title: "Add agent""#))
        #expect(editor.contains(#"title: "Add shared agent""#))

        // The editor derives the displayed ceiling through the exact planner
        // used at run time instead of cloning min/clamp policy in SwiftUI.
        #expect(editor.contains("SubagentBatchAdmissionPlanner.plan("))
        #expect(editor.contains(#""Configured same-model local ceiling""#))
        #expect(editor.contains("share one configured local limit"))
        #expect(editor.contains("Remote subagents use the separate remote limit"))
        #expect(editor.contains("This agent and Server Concurrent Sessions share"))

        #expect(concurrency.contains("same-model local waves"))
        #expect(concurrency.contains("Shared with the Orchestrator's and every agent's Max local subagents at once"))
        #expect(concurrency.contains("SpawnBatchConcurrencyContract.bounds"))
        #expect(concurrency.contains("jobs targeting different local models remain serialized"))
    }

    @Test("turning custom-agent Spawn off does not erase its configured pool")
    func disabledSpawnKeepsConfiguredPolicyInSavePath() throws {
        let agents = try Self.source("Views/Agent/AgentsView.swift")

        #expect(agents.contains("spawnableAgentIDs: spawnableAgentIDs"))
        #expect(!agents.contains("spawnableModelNames"))
        #expect(!agents.contains("spawnDelegationEnabled ? spawnableAgentIDs : []"))
        #expect(!agents.contains("Persist the allow-lists only while spawn is on"))
    }

    @Test("stale pool entries are pruned, not rendered as Unavailable")
    func staleAgentRowsArePruned() throws {
        let editor = try Self.source("Views/Agent/SpawnConfigurationEditor.swift")

        // Local agents: only ids with a live agent render.
        #expect(
            editor.contains(
                "let selected = spawnableAgentIDs.filter { id in agentCandidates.contains { $0.id == id } }"
            )
        )
        // Shared agents: once the roster is loaded, an unlisted ref is stale
        // and never renders as a bare address.
        #expect(editor.contains("!roster.hasWorkspaces || candidates.contains { $0.ref == ref }"))
        #expect(!editor.contains("Configured agents marked unavailable can still be removed."))
        // The remote-target index survives only for the Advanced
        // model-override picker; the per-model pool is gone.
        #expect(!editor.contains("migrateLegacyRemoteSelections()"))
        #expect(!editor.contains("setModel("))
    }
}
