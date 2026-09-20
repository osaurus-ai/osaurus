//
//  AppleAppsComposerGatingTests.swift
//  OsaurusCoreTests — AppleApps
//
//  `SystemPromptComposer.resolveTools` contract for the built-in Apple app
//  tools:
//   * OFF by default: with `enabledAppleApps` empty no Apple tool reaches
//     the schema (auto and manual mode).
//   * Per-app: enabling Calendar exposes exactly the calendar_* family.
//   * Manual-pick carve-out: a ticked manual name survives the strip on a
//     custom agent (same rule as the Web Search gate).
//   * The Default agent NEVER carries an Apple tool — not via the snapshot
//     flag, not via a manual pick, not via `additionalToolNames`.
//   * The Apple guidance block renders only when an Apple tool resolved.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct AppleAppsComposerGatingTests {

    private func makeSnapshot(
        agentId: UUID = UUID(),
        toolMode: ToolSelectionMode = .auto,
        manualToolNames: [String]? = nil,
        enabledAppleApps: Set<AppleApp> = []
    ) -> AgentConfigSnapshot {
        AgentConfigSnapshot(
            agentId: agentId,
            toolsDisabled: false,
            memoryDisabled: true,
            autonomousConfig: nil,
            toolMode: toolMode,
            model: nil,
            manualToolNames: manualToolNames,
            systemPrompt: "",
            dbEnabled: false,
            enabledAppleApps: enabledAppleApps
        )
    }

    private func names(_ snapshot: AgentConfigSnapshot, additional: Set<String> = []) -> Set<String> {
        Set(
            SystemPromptComposer.resolveTools(
                snapshot: snapshot, executionMode: .none, additionalToolNames: additional
            ).map(\.function.name))
    }

    @Test("no Apple tool is exposed when no app is enabled (auto and manual)")
    func offByDefault() {
        #expect(names(makeSnapshot()).isDisjoint(with: AppleApp.allToolNames))
        #expect(names(makeSnapshot(toolMode: .manual, manualToolNames: ["web_search"])).isDisjoint(with: AppleApp.allToolNames))
    }

    @Test("enabling one app exposes exactly that app's tools")
    func perAppGate() {
        let resolved = names(makeSnapshot(enabledAppleApps: [.calendar]))
        #expect(AppleApp.calendar.toolNames.isSubset(of: resolved), "missing: \(AppleApp.calendar.toolNames.subtracting(resolved).sorted())")
        #expect(resolved.isDisjoint(with: AppleApp.disabledToolNames(enabled: [.calendar])))

        let two = names(makeSnapshot(enabledAppleApps: [.reminders, .music]))
        #expect(AppleApp.reminders.toolNames.union(AppleApp.music.toolNames).isSubset(of: two))
        #expect(!two.contains("calendar_events"))
    }

    @Test("a ticked manual name survives the strip on a custom agent")
    func manualPickCarveOut() {
        let resolved = names(makeSnapshot(toolMode: .manual, manualToolNames: ["notes_read"]))
        #expect(resolved.contains("notes_read"))
        #expect(!resolved.contains("notes_create"), "only the ticked name is kept, not the whole family")
    }

    @Test("a session capabilities_load keeps an Apple tool on a custom agent")
    func additionalNamesCarveOut() {
        let resolved = names(makeSnapshot(), additional: ["mail_list"])
        #expect(resolved.contains("mail_list"))
        #expect(!resolved.contains("mail_compose"))
    }

    @Test("the Default agent never carries an Apple tool, even with every bypass tried")
    func defaultAgentNeverCarries() async {
        ConfigurationDomainBootstrap.registerBuiltIns()
        let lease = await acquireSubagentStoreSandbox("apple-apps-default-agent")
        defer { lease.release() }

        let all = Set(AppleApp.allCases)
        let flagged = names(makeSnapshot(agentId: Agent.defaultId, enabledAppleApps: all))
        #expect(flagged.isDisjoint(with: AppleApp.allToolNames), "leaked via flag: \(flagged.intersection(AppleApp.allToolNames).sorted())")

        let manual = names(
            makeSnapshot(agentId: Agent.defaultId, toolMode: .manual, manualToolNames: ["calendar_events", "messages_send"], enabledAppleApps: all))
        #expect(manual.isDisjoint(with: AppleApp.allToolNames), "leaked via manual pick")

        let loaded = names(makeSnapshot(agentId: Agent.defaultId), additional: ["reminders_create"])
        #expect(loaded.isDisjoint(with: AppleApp.allToolNames), "leaked via additionalToolNames")

        // The Orchestrator still keeps its configure surface so it can flip
        // `capabilities.apple_apps` on custom agents.
        #expect(flagged.contains("osaurus_config"))
    }

    @Test("the Apple guidance block renders only when an Apple tool resolved")
    func guidanceBlock() {
        let guidance = SystemPromptTemplates.appleAppsGuidance(apps: [.calendar, .mail])
        #expect(guidance.contains("Calendar"))
        #expect(guidance.contains("Mail"))
        #expect(guidance.contains("get_current_time"))
        #expect(SystemPromptTemplates.appleAppsGuidance(apps: []).isEmpty)
    }

    @Test("AgentConfigSnapshot.capture carries the agent's enabled apps; the Default agent is hard-empty")
    func snapshotCapture() async {
        await SandboxTestLock.runWithStoragePaths {
            await SubagentStoreTestLock.shared.acquire()
            defer { SubagentStoreTestLock.shared.release() }
            let manager = AgentManager.shared
            var agent = Agent(
                name: "Apple Snapshot Probe \(UUID().uuidString.prefix(6))",
                agentAddress: "test-apple-snapshot-\(UUID().uuidString)"
            )
            agent.settings.enabledAppleApps = [.contacts, .weather]
            manager.add(agent)

            let caps = manager.effectiveCapabilities(for: agent.id)
            #expect(caps.enabledAppleApps == [.contacts, .weather])
            #expect(manager.effectiveCapabilities(for: Agent.defaultId).enabledAppleApps.isEmpty)
            _ = await manager.delete(id: agent.id)
        }
    }

    @Test("the Tools picker write path replaces a custom agent's apps and refuses the Default agent")
    func pickerWritePath() async {
        await SandboxTestLock.runWithStoragePaths {
            await SubagentStoreTestLock.shared.acquire()
            defer { SubagentStoreTestLock.shared.release() }
            let manager = AgentManager.shared
            var agent = Agent(
                name: "Apple Picker Probe \(UUID().uuidString.prefix(6))",
                agentAddress: "test-apple-picker-\(UUID().uuidString)"
            )
            agent.manualToolNames = ["some_plugin_tool"]
            manager.add(agent)

            manager.updateEnabledAppleApps([.calendar, .mail], for: agent.id)
            #expect(manager.agent(for: agent.id)?.settings.enabledAppleApps == [.calendar, .mail])
            // Apple names never enter the manual allowlist; the two sets stay apart.
            #expect(manager.agent(for: agent.id)?.manualToolNames == ["some_plugin_tool"])

            manager.updateEnabledAppleApps([.mail], for: agent.id)
            #expect(manager.agent(for: agent.id)?.settings.enabledAppleApps == [.mail])

            manager.updateEnabledAppleApps([.calendar], for: Agent.defaultId)
            #expect(manager.effectiveCapabilities(for: Agent.defaultId).enabledAppleApps.isEmpty)
            _ = await manager.delete(id: agent.id)
        }
    }
}
