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

        #expect(concurrency.contains("same-model local subagent waves"))
        #expect(concurrency.contains("jobs targeting different local models remain serialized"))
        #expect(subagentSettings.contains("architecture-aware KV, SSM, and activation headroom"))
        #expect(subagentSettings.contains("split into smaller waves"))
    }

    @Test("turning custom-agent Spawn off does not erase its configured pools")
    func disabledSpawnKeepsConfiguredPolicyInSavePath() throws {
        let agents = try Self.source("Views/Agent/AgentsView.swift")

        #expect(agents.contains("spawnableAgentNames: spawnableAgentNames"))
        #expect(
            agents.contains(
                "spawnableModelNames: SubagentConfiguration.normalizedSpawnableModelNames("
            )
        )
        #expect(!agents.contains("spawnDelegationEnabled ? spawnableAgentNames : []"))
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

        #expect(editor.contains("ForEach(selected, id: \\.self)"))
        #expect(editor.contains("removableChip(label: name, unavailable: !available)"))
        #expect(editor.contains("setAgent(name, included: false)"))
        #expect(editor.contains("Configured agents marked unavailable can still be removed."))
        #expect(editor.contains(#"Text("Unavailable", bundle: .module)"#))
    }
}
