//
//  AppleAppsPluginMigration.swift
//  osaurus
//
//  One-time launch migration from the superseded osaurus-tools Apple plugins
//  (`osaurus.calendar`, `.reminders`, `.contacts`, `.notes`, `.mail`,
//  `.messages`, `.maps`, `.music`) to the built-in `AppleApps/` tool families.
//
//  Agents that had the plugin tools ticked in `manualToolNames` get:
//    1. the legacy names replaced by the native names
//       (`AppleApp.legacyPluginToolNames`), and
//    2. the owning app added to `settings.enabledAppleApps`
//  so the agent keeps working the day the plugin stops loading. Nothing is
//  ever turned on for an agent that did not already use the plugin tools,
//  and the Default agent is never touched (Apple tools are custom-agent only).
//
//  Pure mapping (`migrate(agent:)`) + a marker-guarded launch sweep, same shape
//  as `BrowserPluginMigration`.
//

import Foundation

/// Persisted marker for the built-in Apple apps feature.
public struct AppleAppsConfiguration: Codable, Sendable, Equatable {
    /// One-time marker: the plugin → native `manualToolNames` sweep has run.
    public var pluginToolNamesMigrated: Bool

    public init(pluginToolNamesMigrated: Bool = false) {
        self.pluginToolNamesMigrated = pluginToolNamesMigrated
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pluginToolNamesMigrated = try c.decodeIfPresent(Bool.self, forKey: .pluginToolNamesMigrated) ?? false
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
        public let renamedTools: [String: String]
    }

    /// Pure mapping: replace legacy plugin tool names in `manualToolNames`
    /// with their native equivalents and enable the owning apps. Idempotent
    /// (native names are left alone; apps already enabled stay enabled).
    /// The Default agent is returned unchanged.
    public static func migrate(agent: Agent) -> Outcome {
        guard agent.id != Agent.defaultId, let names = agent.manualToolNames, !names.isEmpty else {
            return Outcome(agent: agent, changed: false, enabledApps: [], renamedTools: [:])
        }
        var renamed: [String: String] = [:]
        var apps: Set<AppleApp> = []
        var next: [String] = []
        var seen: Set<String> = []
        for name in names {
            if let mapping = AppleApp.legacyPluginToolNames[name] {
                renamed[name] = mapping.native
                apps.insert(mapping.app)
                if seen.insert(mapping.native).inserted { next.append(mapping.native) }
            } else if seen.insert(name).inserted {
                next.append(name)
            }
        }
        guard !renamed.isEmpty else {
            return Outcome(agent: agent, changed: false, enabledApps: [], renamedTools: [:])
        }
        var updated = agent
        updated.manualToolNames = next
        // Turning an app on also exposes its sibling tools (the plugin had
        // e.g. `get_events` but no update/delete); pull the whole family in so
        // manual mode sees the complete native set.
        for app in apps {
            for tool in app.toolNames where seen.insert(tool).inserted {
                updated.manualToolNames?.append(tool)
            }
        }
        updated.settings.enabledAppleApps.formUnion(apps)
        return Outcome(agent: updated, changed: true, enabledApps: apps, renamedTools: renamed)
    }

    /// Launch sweep. Runs once (marker in `apple-apps.json`); `agents` /
    /// `persist` are test seams, production uses `AgentManager.shared`.
    @discardableResult
    public static func migrateIfNeeded(
        agents: [Agent]? = nil,
        persist: ((Agent) -> Void)? = nil
    ) -> Int {
        var config = AppleAppsConfigurationStore.load()
        guard !config.pluginToolNamesMigrated else { return 0 }

        let source = agents ?? AgentManager.shared.agents
        let save = persist ?? { AgentManager.shared.update($0) }
        var migrated = 0
        for agent in source {
            let outcome = migrate(agent: agent)
            guard outcome.changed else { continue }
            save(outcome.agent)
            migrated += 1
            print(
                "[Osaurus] Apple apps: migrated \(outcome.renamedTools.count) plugin tool name(s) on \"\(agent.name)\" → enabled \(AppleApp.sorted(outcome.enabledApps).map(\.rawValue).joined(separator: ", "))"
            )
        }

        config.pluginToolNamesMigrated = true
        AppleAppsConfigurationStore.save(config)
        return migrated
    }
}
