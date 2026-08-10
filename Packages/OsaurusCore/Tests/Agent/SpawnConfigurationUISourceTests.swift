// Copyright © 2026 osaurus.

import Foundation
import Testing

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
        #expect(settings.contains(#"SettingsSubsection(label: "Main Chat Spawn")"#))
        #expect(editor.contains(#"AgentSheetSectionLabel("Allowed agents")"#))
        #expect(editor.contains(#"AgentSheetSectionLabel("Allowed models")"#))
        #expect(editor.contains(#"title: "Max subagents per batch""#))
        #expect(editor.contains(#"title: "Max child tool calls (0 = default 8)""#))
        #expect(editor.contains(#"keyPath: \.maxToolCalls"#))
        #expect(editor.contains(#"Text("Agent tools only""#))
        #expect(editor.contains(#"Text("Agent tools + read-only files""#))
        #expect(editor.contains("cancellation-audited subset of their enabled tools"))
        #expect(editor.contains("host read-only file tools"))
        #expect(editor.contains("modelPickerCache.items.chatModelCandidates"))
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
            "Views/Settings/ConfigurationView.swift",
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
        let settings = try Self.source("Views/Settings/ConfigurationView.swift")
        let controller = try Self.source("Networking/ServerController.swift")
        let composer = try Self.source("Services/Chat/SystemPromptComposer.swift")

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
        #expect(
            composer.components(
                separatedBy: "for: ServerRuntimeSettingsStore.snapshot()"
            ).count - 1 == 2
        )
        #expect(!controller.contains("subagentConfigurationCancellable"))
    }

    @Test("runtime spawn boundaries inject the canonical Server concurrency")
    func runtimeSpawnBoundariesUseCanonicalServerLimit() throws {
        let snapshot = try Self.source("Services/Chat/AgentConfigSnapshot.swift")
        let textSpawn = try Self.source("Subagent/Kinds/TextSubagentKind.swift")
        let batchSpawn = try Self.source("Tools/SpawnBatchTool.swift")
        let visibility = try Self.source(
            "Subagent/SubagentCapabilityRegistry.swift"
        )

        #expect(snapshot.contains("for: ServerRuntimeSettingsStore.snapshot()"))
        #expect(snapshot.contains("sharedParallelLimit: sharedParallelLimit"))
        #expect(textSpawn.contains("for: ServerRuntimeSettingsStore.snapshot()"))
        #expect(textSpawn.contains("sharedParallelLimit: sharedParallelLimit"))
        #expect(batchSpawn.contains("maxParallelSpawns: maxParallelSpawns"))
        #expect(batchSpawn.contains("sharedParallelLimit: maxParallelSpawns"))
        #expect(
            batchSpawn.contains(
                "approved.maxParallelSpawns == current.maxParallelSpawns"
            )
        )

        // Keep the budget merger pure: every production boundary must name the
        // canonical source explicitly, while hand-built frozen-schema tests can
        // inject the persisted mirror without reading developer-machine state.
        #expect(!visibility.contains("ServerRuntimeSettingsStore.snapshot()"))
        #expect(visibility.contains("sharedParallelLimit: Int"))
    }

    @Test("model picker refresh, target status, and capacity contract stay in the shared editor")
    func sharedEditorOwnsRefreshStatusAndCapacityCopy() throws {
        let editor = try Self.source("Views/Agent/SpawnConfigurationEditor.swift")
        let concurrency = try Self.source(
            "Views/Settings/ServerSettings/ConcurrencySection.swift"
        )
        let subagentSettings = try Self.source(
            "Views/Settings/SubagentSettingsSection.swift"
        )

        #expect(editor.contains(".task(id: modelPickerPresented)"))
        #expect(editor.contains("refreshConnectedProviders()"))
        #expect(editor.contains("buildModelPickerItems()"))
        #expect(editor.contains("Refreshing local and connected cloud models"))
        #expect(editor.contains("No local or connected cloud models are available"))
        #expect(editor.contains(#"disabled: false"#))
        // The one remaining `addable.isEmpty` gate belongs to Add Agent. Add
        // Model stays reachable so opening it can refresh a cold cache.
        #expect(
            editor.components(separatedBy: #"disabled: addable.isEmpty"#).count - 1 == 1
        )
        #expect(editor.contains(#"L("Unavailable")"#))
        #expect(editor.contains(#"L("Checking…")"#))

        // The editor derives the displayed ceiling through the exact planner
        // used at run time instead of cloning min/clamp policy in SwiftUI.
        #expect(editor.contains("SubagentBatchAdmissionPlanner.plan("))
        #expect(editor.contains(#""Configured same-model local ceiling""#))
        #expect(editor.contains("Different local models run in serial model waves"))
        #expect(editor.contains("persist one configured limit"))
        #expect(editor.contains("This agent and Server Concurrent Sessions persist"))

        #expect(concurrency.contains("same-model local waves"))
        #expect(concurrency.contains("Shared with Main Chat Spawn"))
        #expect(concurrency.contains("SpawnBatchConcurrencyContract.bounds"))
        #expect(concurrency.contains("jobs targeting different local models remain serialized"))
        #expect(subagentSettings.contains("architecture-aware KV, SSM, and activation headroom"))
        #expect(subagentSettings.contains("split into smaller waves"))
    }

    @Test("turning custom-agent Spawn off does not erase its configured pools")
    func disabledSpawnKeepsConfiguredPolicyInSavePath() throws {
        let agents = try Self.source("Views/Agent/AgentsView.swift")

        #expect(agents.contains("spawnableAgentIDs: spawnableAgentIDs"))
        #expect(
            agents.contains(
                "spawnableModelNames: SubagentConfiguration.normalizedSpawnableModelNames("
            )
        )
        #expect(!agents.contains("spawnDelegationEnabled ? spawnableAgentIDs : []"))
        #expect(!agents.contains("Persist the allow-lists only while spawn is on"))
    }

    @Test("remote rows persist UUID-backed targets and migrate only live legacy matches")
    func remoteRowsUseStableSpawnIdentity() throws {
        let editor = try Self.source("Views/Agent/SpawnConfigurationEditor.swift")

        #expect(editor.contains("ConnectedSpawnModelTargetIndex.empty"))
        #expect(editor.contains("connectedSpawnModelTargetIndex()"))
        #expect(editor.contains("connectedSpawnTargetIndex.targetID("))
        #expect(editor.contains("connectedSpawnTargetIndex.target(forStoredId:"))
        #expect(editor.contains("selectionID(for: item)"))
        #expect(editor.contains("migrateLegacyRemoteSelections()"))
        #expect(editor.contains("migratedNotes.removeValue(forKey: legacy)"))
        #expect(editor.contains("ForEach(group.models, id: \\.self)"))
        #expect(!editor.contains("setModel(item.id, included: true)"))
        #expect(
            editor.components(separatedBy: "RemoteProviderManager.shared").count - 1 == 2
        )
        #expect(!editor.contains(".spawnTargetId("))
        #expect(!editor.contains(".connectedSpawnModelTarget(forStoredId:"))
    }

    @Test("stale configured agents remain visible and removable")
    func staleAgentRowsRemainRepairable() throws {
        let editor = try Self.source("Views/Agent/SpawnConfigurationEditor.swift")

        #expect(editor.contains("let selected = spawnableAgentIDs"))
        #expect(editor.contains("ForEach(selected, id: \\.self)"))
        #expect(editor.contains("let candidate = agentCandidates.first { $0.id == id }"))
        #expect(editor.contains("label: candidate?.name ?? id.uuidString"))
        #expect(editor.contains("unavailable: candidate == nil"))
        #expect(editor.contains("setAgent(id, included: false)"))
        #expect(editor.contains("Configured agents marked unavailable can still be removed."))
        #expect(editor.contains(#"Text("Unavailable", bundle: .module)"#))
    }
}
