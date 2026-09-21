//
//  AppleAppsPluginMigrationTests.swift
//  OsaurusCoreTests — AppleApps
//
//  One-time migration from the superseded osaurus-tools Apple plugins:
//  legacy `manualToolNames` are removed (never rewritten into native names),
//  the owning app is enabled, only INSTALLED plugins' names are touched so
//  generic names from other plugins survive, the Default agent is never
//  touched, and the launch sweep is guarded by the `apple-apps.json` marker
//  so it runs exactly once (and only after every changed agent persisted).
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct AppleAppsPluginMigrationTests {

    private static let allApplePlugins: Set<String> = PluginManager.supersededAppleAppPluginIds

    @MainActor private final class NoticeCapture {
        var title = ""
        var message = ""
    }

    private func customAgent(manualToolNames: [String]?) -> Agent {
        Agent(
            name: "Migration Probe \(UUID().uuidString.prefix(6))",
            agentAddress: "test-apple-migration-\(UUID().uuidString)",
            toolSelectionMode: manualToolNames == nil ? .auto : .manual,
            manualToolNames: manualToolNames
        )
    }

    /// Run `body` with `apple-apps.json` redirected to a temp dir, under the
    /// process-wide storage lock (other suites rewrite `OsaurusPaths`).
    private func withIsolatedStore(_ body: @MainActor @Sendable (URL) async throws -> Void) async throws {
        try await SandboxTestLock.runWithStoragePaths {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
                "apple-apps-migration-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer {
                AppleAppsConfigurationStore.overrideDirectory = nil
                AppleAppsConfigurationStore.resetCacheForTests()
                try? FileManager.default.removeItem(at: dir)
            }
            AppleAppsConfigurationStore.overrideDirectory = dir
            AppleAppsConfigurationStore.resetCacheForTests()
            try await body(dir)
        }
    }

    @Test("legacy names are removed (not rewritten), native names never enter manualToolNames, and the app is enabled")
    func removesLegacyNames() {
        let agent = customAgent(manualToolNames: ["get_events", "create_event", "web_search", "find_contact_by_name"])
        let outcome = AppleAppsPluginMigration.migrate(agent: agent, installedPluginIds: Self.allApplePlugins)
        #expect(outcome.changed)
        #expect(outcome.enabledApps == [.calendar, .contacts])
        #expect(outcome.renamedTools["get_events"] == "calendar_events")
        #expect(outcome.renamedTools["create_event"] == "calendar_create_event")
        #expect(outcome.renamedTools["find_contact_by_name"] == "contacts_search")
        let names = Set(outcome.agent.manualToolNames ?? [])
        #expect(names == ["web_search"], "only non-Apple picks survive: \(names.sorted())")
        #expect(names.isDisjoint(with: AppleApp.allToolNames), "picker invariant: no Apple names in manualToolNames")
        #expect(outcome.agent.settings.enabledAppleApps == [.calendar, .contacts])
    }

    @Test("generic names from other plugins are untouched when the Apple plugin was never installed")
    func skipsUninstalledPlugins() {
        // Spotify `play`, Slack `send_message`, some notes MCP `create_note`.
        let agent = customAgent(manualToolNames: ["play", "send_message", "create_note", "web_search"])
        let none = AppleAppsPluginMigration.migrate(agent: agent, installedPluginIds: [])
        #expect(!none.changed)
        #expect(none.agent == agent)

        // Only the music plugin installed → only `play` is claimed.
        let musicOnly = AppleAppsPluginMigration.migrate(agent: agent, installedPluginIds: ["osaurus.music"])
        #expect(musicOnly.changed)
        #expect(musicOnly.enabledApps == [.music])
        #expect(Set(musicOnly.agent.manualToolNames ?? []) == ["send_message", "create_note", "web_search"])
        #expect(musicOnly.agent.settings.enabledAppleApps == [.music])
    }

    @Test("search_messages prefers the Messages plugin and falls back to Mail only when Messages is absent")
    func searchMessagesPreference() {
        let agent = customAgent(manualToolNames: ["search_messages"])
        let both = AppleAppsPluginMigration.migrate(agent: agent, installedPluginIds: ["osaurus.mail", "osaurus.messages"])
        #expect(both.enabledApps == [.messages])
        #expect(both.renamedTools["search_messages"] == "messages_search")

        let messagesOnly = AppleAppsPluginMigration.migrate(agent: agent, installedPluginIds: ["osaurus.messages"])
        #expect(messagesOnly.enabledApps == [.messages])

        let mailOnly = AppleAppsPluginMigration.migrate(agent: agent, installedPluginIds: ["osaurus.mail"])
        #expect(mailOnly.enabledApps == [.mail])
        #expect(mailOnly.renamedTools["search_messages"] == "mail_search")
    }

    @Test("agents without legacy names, auto-mode agents, and the Default agent are untouched")
    func noOps() {
        let plain = customAgent(manualToolNames: ["web_search"])
        let o1 = AppleAppsPluginMigration.migrate(agent: plain, installedPluginIds: Self.allApplePlugins)
        #expect(!o1.changed)
        #expect(o1.agent == plain)

        let auto = customAgent(manualToolNames: nil)
        #expect(!AppleAppsPluginMigration.migrate(agent: auto, installedPluginIds: Self.allApplePlugins).changed)

        let def = Agent(
            id: Agent.defaultId, name: "Default", agentAddress: "default-probe",
            toolSelectionMode: .manual, manualToolNames: ["get_events"]
        )
        let o3 = AppleAppsPluginMigration.migrate(agent: def, installedPluginIds: Self.allApplePlugins)
        #expect(!o3.changed)
        #expect(o3.agent.settings.enabledAppleApps.isEmpty)
    }

    @Test("migration is idempotent")
    func idempotent() {
        let agent = customAgent(manualToolNames: ["list_messages", "read_message", "send_message"])
        let first = AppleAppsPluginMigration.migrate(agent: agent, installedPluginIds: Self.allApplePlugins)
        #expect(first.enabledApps == [.mail, .messages])
        let second = AppleAppsPluginMigration.migrate(agent: first.agent, installedPluginIds: Self.allApplePlugins)
        #expect(!second.changed)
        #expect(second.agent == first.agent)
    }

    @Test("the launch sweep runs once, persists changed agents only, and writes the marker")
    func sweepRunsOnce() async throws {
        try await withIsolatedStore { dir in
            #expect(!AppleAppsConfigurationStore.load().pluginToolNamesMigrated)

            let legacy = customAgent(manualToolNames: ["get_reminders"])
            let untouched = customAgent(manualToolNames: ["web_search"])
            var persisted: [Agent] = []
            let count = AppleAppsPluginMigration.migrateIfNeeded(
                agents: [legacy, untouched], installedPluginIds: ["osaurus.reminders"]
            ) { persisted.append($0) }
            #expect(count == 1)
            #expect(persisted.count == 1)
            #expect(persisted.first?.id == legacy.id)
            #expect(persisted.first?.settings.enabledAppleApps == [.reminders])
            #expect(AppleAppsConfigurationStore.load().pluginToolNamesMigrated)
            #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("apple-apps.json").path))

            // Second launch: marker set → nothing runs even with legacy agents present.
            AppleAppsConfigurationStore.resetCacheForTests()
            let again = AppleAppsPluginMigration.migrateIfNeeded(
                agents: [legacy], installedPluginIds: ["osaurus.reminders"]
            ) { _ in Issue.record("must not persist on a second run") }
            #expect(again == 0)
        }
    }

    @Test("the marker is not written when persisting a changed agent fails, so the sweep retries next launch")
    func markerWaitsForPersistence() async throws {
        struct PersistFailed: Error {}
        try await withIsolatedStore { _ in
            let legacy = customAgent(manualToolNames: ["get_reminders"])
            let count = AppleAppsPluginMigration.migrateIfNeeded(
                agents: [legacy], installedPluginIds: ["osaurus.reminders"]
            ) { _ in throw PersistFailed() }
            #expect(count == 0)
            #expect(!AppleAppsConfigurationStore.load().pluginToolNamesMigrated)

            // A later successful run completes and sets the marker.
            let retry = AppleAppsPluginMigration.migrateIfNeeded(
                agents: [legacy], installedPluginIds: ["osaurus.reminders"]
            ) { _ in }
            #expect(retry == 1)
            #expect(AppleAppsConfigurationStore.load().pluginToolNamesMigrated)
        }
    }

    @Test("with no Apple plugin installed the sweep changes nothing but still sets the marker")
    func noPluginsInstalled() async throws {
        try await withIsolatedStore { _ in
            let spotifyish = customAgent(manualToolNames: ["play", "pause"])
            let count = AppleAppsPluginMigration.migrateIfNeeded(agents: [spotifyish], installedPluginIds: []) { _ in
                Issue.record("nothing should be persisted")
            }
            #expect(count == 0)
            #expect(AppleAppsConfigurationStore.load().pluginToolNamesMigrated)
        }
    }

    @Test("installedSupersededAppleAppPluginIds sees only Apple plugin folders with a version dir or current link")
    func installedScan() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tools-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("osaurus.music/1.2.0"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("osaurus.mail"), withIntermediateDirectories: true)  // empty leftover
        try fm.createDirectory(at: root.appendingPathComponent("osaurus.notes"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(
            at: root.appendingPathComponent("osaurus.notes/current"),
            withDestinationURL: root.appendingPathComponent("osaurus.notes/0.1.0"))
        try fm.createDirectory(at: root.appendingPathComponent("com.example.spotify/1.0.0"), withIntermediateDirectories: true)

        let installed = PluginManager.installedSupersededAppleAppPluginIds(toolsRoot: root)
        #expect(installed == ["osaurus.music", "osaurus.notes"])

        let missing = root.appendingPathComponent("does-not-exist", isDirectory: true)
        #expect(PluginManager.installedSupersededAppleAppPluginIds(toolsRoot: missing).isEmpty)
    }

    @Test("the superseded-plugin notice shows once, names the installed apps, and is skipped when none are installed")
    func supersededNotice() async throws {
        try await withIsolatedStore { _ in
            #expect(AppleAppsPluginMigration.showSupersededNoticeIfNeeded(installedPluginIds: []) { _, _ in
                Issue.record("no notice without an installed plugin")
            } == nil)
            #expect(!AppleAppsConfigurationStore.load().supersededPluginNoticeShown)

            let shown = NoticeCapture()
            let capture: @MainActor (String, String) -> Void = { title, body in
                shown.title = title
                shown.message = body
            }
            let message = AppleAppsPluginMigration.showSupersededNoticeIfNeeded(
                installedPluginIds: ["osaurus.mail", "osaurus.music", "com.example.other"],
                present: capture
            )
            #expect(message != nil)
            #expect(!shown.title.isEmpty)
            #expect(shown.message.contains("Mail"))
            #expect(shown.message.contains("Music"))
            #expect(shown.message.contains("Abilities"))
            #expect(AppleAppsConfigurationStore.load().supersededPluginNoticeShown)

            let again = AppleAppsPluginMigration.showSupersededNoticeIfNeeded(installedPluginIds: ["osaurus.mail"]) { _, _ in
                Issue.record("notice must show once")
            }
            #expect(again == nil)
        }
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
