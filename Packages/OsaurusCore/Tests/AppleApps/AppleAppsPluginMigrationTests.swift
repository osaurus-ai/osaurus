//
//  AppleAppsPluginMigrationTests.swift
//  OsaurusCoreTests — AppleApps
//
//  One-time migration from the superseded osaurus-tools Apple plugins:
//  legacy `manualToolNames` are renamed to the native tools, the owning app
//  is enabled, the Default agent is never touched, and the launch sweep is
//  guarded by the `apple-apps.json` marker so it runs exactly once.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct AppleAppsPluginMigrationTests {

    private func customAgent(manualToolNames: [String]?) -> Agent {
        Agent(
            name: "Migration Probe \(UUID().uuidString.prefix(6))",
            agentAddress: "test-apple-migration-\(UUID().uuidString)",
            toolSelectionMode: manualToolNames == nil ? .auto : .manual,
            manualToolNames: manualToolNames
        )
    }

    @Test("legacy plugin names are renamed, the family is pulled in, and the app is enabled")
    func mapsLegacyNames() {
        let agent = customAgent(manualToolNames: ["get_events", "create_event", "web_search", "find_contact_by_name"])
        let outcome = AppleAppsPluginMigration.migrate(agent: agent)
        #expect(outcome.changed)
        #expect(outcome.enabledApps == [.calendar, .contacts])
        #expect(outcome.renamedTools["get_events"] == "calendar_events")
        #expect(outcome.renamedTools["create_event"] == "calendar_create_event")
        #expect(outcome.renamedTools["find_contact_by_name"] == "contacts_search")
        let names = Set(outcome.agent.manualToolNames ?? [])
        #expect(names.contains("web_search"), "non-Apple picks survive")
        #expect(!names.contains("get_events"), "legacy name removed")
        #expect(AppleApp.calendar.toolNames.isSubset(of: names), "whole calendar family pulled in")
        #expect(AppleApp.contacts.toolNames.isSubset(of: names))
        #expect(names.isDisjoint(with: AppleApp.mail.toolNames), "unrelated apps stay off")
        #expect(outcome.agent.settings.enabledAppleApps == [.calendar, .contacts])
        #expect((outcome.agent.manualToolNames ?? []).count == names.count, "no duplicates")
    }

    @Test("agents without legacy names, auto-mode agents, and the Default agent are untouched")
    func noOps() {
        let plain = customAgent(manualToolNames: ["web_search", "calendar_events"])
        let o1 = AppleAppsPluginMigration.migrate(agent: plain)
        #expect(!o1.changed)
        #expect(o1.agent == plain)

        let auto = customAgent(manualToolNames: nil)
        #expect(!AppleAppsPluginMigration.migrate(agent: auto).changed)

        let def = Agent(
            id: Agent.defaultId, name: "Default", agentAddress: "default-probe",
            toolSelectionMode: .manual, manualToolNames: ["get_events"]
        )
        let o3 = AppleAppsPluginMigration.migrate(agent: def)
        #expect(!o3.changed)
        #expect(o3.agent.settings.enabledAppleApps.isEmpty)
    }

    @Test("migration is idempotent")
    func idempotent() {
        let agent = customAgent(manualToolNames: ["list_messages", "read_message", "send_message"])
        let first = AppleAppsPluginMigration.migrate(agent: agent)
        #expect(first.enabledApps == [.mail, .messages])
        let second = AppleAppsPluginMigration.migrate(agent: first.agent)
        #expect(!second.changed)
        #expect(second.agent == first.agent)
    }

    @Test("the launch sweep runs once, persists changed agents only, and writes the marker")
    func sweepRunsOnce() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("apple-apps-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer {
            AppleAppsConfigurationStore.overrideDirectory = nil
            AppleAppsConfigurationStore.resetCacheForTests()
            try? FileManager.default.removeItem(at: dir)
        }
        AppleAppsConfigurationStore.overrideDirectory = dir
        AppleAppsConfigurationStore.resetCacheForTests()
        #expect(!AppleAppsConfigurationStore.load().pluginToolNamesMigrated)

        let legacy = customAgent(manualToolNames: ["get_reminders"])
        let untouched = customAgent(manualToolNames: ["web_search"])
        var persisted: [Agent] = []
        let count = AppleAppsPluginMigration.migrateIfNeeded(agents: [legacy, untouched]) { persisted.append($0) }
        #expect(count == 1)
        #expect(persisted.count == 1)
        #expect(persisted.first?.id == legacy.id)
        #expect(persisted.first?.settings.enabledAppleApps == [.reminders])
        #expect(AppleAppsConfigurationStore.load().pluginToolNamesMigrated)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("apple-apps.json").path))

        // Second launch: marker set → nothing runs even with legacy agents present.
        AppleAppsConfigurationStore.resetCacheForTests()
        let again = AppleAppsPluginMigration.migrateIfNeeded(agents: [legacy]) { _ in Issue.record("must not persist on a second run") }
        #expect(again == 0)
    }

    @Test("PluginManager supersedes the Apple plugins and deep-links them to the Agents tab")
    func supersededPlugins() {
        for app in AppleApp.allCases {
            guard let id = app.supersededPluginId else { continue }
            #expect(PluginManager.supersededPluginIds.contains(id), "\(id) is not superseded")
            #expect(PluginManager.nativeSettingsTab(forSupersededPlugin: id) == .agents, "\(id) should point at Agents → Abilities")
        }
        #expect(PluginManager.supersededAppleAppPluginIds.isSubset(of: PluginManager.supersededPluginIds))
    }
}
