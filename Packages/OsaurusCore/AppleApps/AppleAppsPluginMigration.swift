//
//  AppleAppsPluginMigration.swift
//  osaurus
//
//  One-time launch migration from the superseded osaurus-tools Apple plugins
//  (`osaurus.calendar`, `.reminders`, `.contacts`, `.notes`, `.mail`,
//  `.messages`, `.maps`, `.music`) to the built-in `AppleApps/` tool families.
//
//  Agents that had the plugin tools ticked in `manualToolNames` get:
//    1. the legacy names REMOVED (never replaced — Apple tool names never
//       live in `manualToolNames`; the per-app toggle is the single switch
//       and the picker derives the rows from it), and
//    2. the owning app added to `settings.enabledAppleApps`
//  so the agent keeps working the day the plugin stops loading. A plugin's
//  legacy map is applied ONLY when that plugin's folder is actually
//  installed (`PluginManager.installedSupersededAppleAppPluginIds`) — names
//  like `play` / `send_message` / `create_note` are common in unrelated
//  plugins and MCP servers and must never be hijacked. Nothing is ever
//  turned on for an agent that did not already use the plugin tools, and
//  the Default agent is never touched (Apple tools are custom-agent only).
//
//  Pure mapping (`migrate(agent:installedPluginIds:)`) + a marker-guarded
//  launch sweep, same shape as `BrowserPluginMigration`. The marker is
//  written only after every changed agent persisted, and the sweep's file
//  I/O runs off the main actor.
//

import Foundation

/// Persisted marker for the built-in Apple apps feature.
public struct AppleAppsConfiguration: Codable, Sendable, Equatable {
    /// One-time marker: the plugin → native `manualToolNames` sweep has run.
    public var pluginToolNamesMigrated: Bool
    /// One-time marker: the "these plugins are now built in" launch notice
    /// has been shown (only ever set when a superseded plugin folder existed).
    public var supersededPluginNoticeShown: Bool

    public init(pluginToolNamesMigrated: Bool = false, supersededPluginNoticeShown: Bool = false) {
        self.pluginToolNamesMigrated = pluginToolNamesMigrated
        self.supersededPluginNoticeShown = supersededPluginNoticeShown
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pluginToolNamesMigrated = try c.decodeIfPresent(Bool.self, forKey: .pluginToolNamesMigrated) ?? false
        supersededPluginNoticeShown = try c.decodeIfPresent(Bool.self, forKey: .supersededPluginNoticeShown) ?? false
    }
}

@MainActor
public enum AppleAppsConfigurationStore {
    /// Test override for the persistence directory.
    public static var overrideDirectory: URL?
    private static var cached: AppleAppsConfiguration?

    public static func load() -> AppleAppsConfiguration {
        if let cached { return cached }
        let url = fileURL()
        if FileManager.default.fileExists(atPath: url.path),
            let data = try? Data(contentsOf: url),
            let config = try? JSONDecoder().decode(AppleAppsConfiguration.self, from: data)
        {
            cached = config
            return config
        }
        let config = AppleAppsConfiguration()
        cached = config
        return config
    }

    public static func save(_ config: AppleAppsConfiguration) {
        cached = config
        let url = fileURL()
        OsaurusPaths.ensureExistsSilent(url.deletingLastPathComponent())
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(config).write(to: url, options: [.atomic])
        } catch {
            print("[Osaurus] Failed to save AppleAppsConfiguration: \(error)")
        }
    }

    /// Test hook: drop the in-memory cache so the next read re-decodes.
    public static func resetCacheForTests() { cached = nil }

    private static func fileURL() -> URL {
        if let dir = overrideDirectory { return dir.appendingPathComponent("apple-apps.json") }
        return OsaurusPaths.appleAppsConfigFile()
    }
}

@MainActor
public enum AppleAppsPluginMigration {
    /// Result of mapping one agent. `changed == false` means nothing to save.
    public struct Outcome: Equatable, Sendable {
        public let agent: Agent
        public let changed: Bool
        public let enabledApps: Set<AppleApp>
        /// Legacy name → the native tool that now covers it (informational;
        /// the native name is NOT written into `manualToolNames`).
        public let renamedTools: [String: String]
    }

    /// Legacy name → (app, native) for exactly the plugins in
    /// `installedPluginIds`. `search_messages` shipped in both the Mail and
    /// Messages plugins: Messages wins when installed, Mail only when the
    /// Messages plugin is not.
    nonisolated static func legacyMap(
        installedPluginIds: Set<String>
    ) -> [String: (app: AppleApp, native: String)] {
        var map: [String: (app: AppleApp, native: String)] = [:]
        // Deterministic precedence: apply Mail first so Messages overwrites
        // the shared `search_messages` key when both are installed.
        let ordered = AppleApp.legacyPluginToolNamesByPlugin.keys.sorted { lhs, rhs in
            if lhs == "osaurus.messages" { return false }
            if rhs == "osaurus.messages" { return true }
            return lhs < rhs
        }
        for pluginId in ordered where installedPluginIds.contains(pluginId) {
            guard let app = AppleApp.app(forSupersededPlugin: pluginId),
                let names = AppleApp.legacyPluginToolNamesByPlugin[pluginId]
            else { continue }
            for (legacy, native) in names {
                map[legacy] = (app, native)
            }
        }
        return map
    }

    /// Pure mapping: drop legacy plugin tool names from `manualToolNames`
    /// and enable the owning apps — for installed plugins only. Idempotent
    /// (a second pass finds no legacy names). Any Apple native name that
    /// somehow sits in `manualToolNames` is stripped as well (picker
    /// invariant). The Default agent is returned unchanged.
    nonisolated public static func migrate(agent: Agent, installedPluginIds: Set<String>) -> Outcome {
        guard agent.id != Agent.defaultId, let names = agent.manualToolNames, !names.isEmpty,
            !installedPluginIds.isEmpty
        else {
            return Outcome(agent: agent, changed: false, enabledApps: [], renamedTools: [:])
        }
        let mapping = legacyMap(installedPluginIds: installedPluginIds)
        var renamed: [String: String] = [:]
        var apps: Set<AppleApp> = []
        var next: [String] = []
        var seen: Set<String> = []
        for name in names {
            if let hit = mapping[name] {
                renamed[name] = hit.native
                apps.insert(hit.app)
            } else if AppleApp.allToolNames.contains(name) {
                // Native names never live in the manual pick list.
                continue
            } else if seen.insert(name).inserted {
                next.append(name)
            }
        }
        guard !renamed.isEmpty else {
            return Outcome(agent: agent, changed: false, enabledApps: [], renamedTools: [:])
        }
        var updated = agent
        updated.manualToolNames = next
        updated.settings.enabledAppleApps.formUnion(apps)
        return Outcome(agent: updated, changed: true, enabledApps: apps, renamedTools: renamed)
    }

    /// Launch sweep. Runs once (marker in `apple-apps.json`); `agents` /
    /// `installedPluginIds` / `persist` are test seams, production uses
    /// `AgentManager.shared` and the on-disk `Tools/` folder. The marker is
    /// written only when every changed agent was persisted; if `persist`
    /// throws, the sweep retries on the next launch.
    @discardableResult
    public static func migrateIfNeeded(
        agents: [Agent]? = nil,
        installedPluginIds: Set<String>? = nil,
        persist: ((Agent) throws -> Void)? = nil
    ) -> Int {
        var config = AppleAppsConfigurationStore.load()
        guard !config.pluginToolNamesMigrated else { return 0 }

        let installed = installedPluginIds ?? PluginManager.installedSupersededAppleAppPluginIds()
        let source = agents ?? AgentManager.shared.agents
        let save = persist ?? { AgentManager.shared.update($0) }
        var migrated = 0
        var allPersisted = true
        for agent in source {
            let outcome = migrate(agent: agent, installedPluginIds: installed)
            guard outcome.changed else { continue }
            do {
                try save(outcome.agent)
            } catch {
                allPersisted = false
                print("[Osaurus] Apple apps: failed to persist migrated agent \"\(agent.name)\": \(error)")
                continue
            }
            migrated += 1
            print(
                "[Osaurus] Apple apps: removed \(outcome.renamedTools.count) legacy plugin tool name(s) on \"\(agent.name)\" → enabled \(AppleApp.sorted(outcome.enabledApps).map(\.rawValue).joined(separator: ", "))"
            )
        }

        guard allPersisted else { return migrated }
        config.pluginToolNamesMigrated = true
        AppleAppsConfigurationStore.save(config)
        return migrated
    }

    /// Entry point for `AppDelegate`: the `Tools/` scan runs off the main
    /// actor, then the sweep and the one-time notice run on it.
    public static func migrateIfNeededAtLaunch() async {
        let installed = await Task.detached(priority: .utility) {
            PluginManager.installedSupersededAppleAppPluginIds()
        }.value
        migrateIfNeeded(installedPluginIds: installed)
        showSupersededNoticeIfNeeded(installedPluginIds: installed)
    }

    /// One-time launch notice when a superseded Apple plugin folder still
    /// exists: the user had e.g. `osaurus.mail` and would otherwise get no
    /// hint that Mail is now a per-agent built-in. Returns the notice text
    /// when shown (test seam), nil otherwise.
    @discardableResult
    public static func showSupersededNoticeIfNeeded(
        installedPluginIds: Set<String>,
        present: ((String, String) -> Void)? = nil
    ) -> String? {
        var config = AppleAppsConfigurationStore.load()
        guard !config.supersededPluginNoticeShown else { return nil }
        let apps = AppleApp.sorted(Set(installedPluginIds.compactMap(AppleApp.app(forSupersededPlugin:))))
        guard !apps.isEmpty else { return nil }
        let title = L("Apple apps are now built into Osaurus")
        let list = apps.map(\.displayName).joined(separator: ", ")
        let message = String(
            format: L("%@ no longer need a plugin. Turn each app on per agent under Agents → Abilities → Tools → Apple Apps."),
            list
        )
        if let present {
            present(title, message)
        } else {
            ToastManager.shared.action(
                title, message: message,
                action: .openSettings(tab: ManagementTab.agents.rawValue),
                buttonTitle: L("Open Agents"),
                timeout: 20
            )
        }
        config.supersededPluginNoticeShown = true
        AppleAppsConfigurationStore.save(config)
        return message
    }
}
