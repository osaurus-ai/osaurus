//
//  InstalledClaudePluginsAggregator.swift
//  osaurus
//
//  Aggregates installed Claude-plugin artifacts (skills, schedules, slash
//  commands, MCP providers) plus the rich manifest snapshots persisted by
//  `ClaudePluginManifestStore`. The Plugins tab renders one
//  `ClaudePluginCard` per entry alongside its existing native
//  `PluginCard`s, and `ClaudePluginDetailView` consumes the per-item
//  projection arrays (`InstalledClaude{Skill,Schedule,Command,MCP}`)
//  to render rich preview popovers inside its Components section.
//
//  Responsibilities:
//   - Reads manifest snapshots from disk for descriptive metadata.
//   - Joins live records from the four managers so the card surfaces
//     accurate "N skills / M MCP" counts and the detail view can list
//     each individual item with its preview-driving fields.
//   - Probes the source repo for newer versions (`plugin.json.version`
//     > marketplace > git SHA) and surfaces an `Update` affordance on
//     the card.
//

import Foundation
import SwiftUI

// MARK: - Public types

/// The four artifact families a Claude plugin can install. Mirrors the
/// per-kind chip metadata the card UI needs.
public enum ClaudePluginArtifactKind: CaseIterable, Sendable {
    case skill
    case schedule
    case command
    case mcp

    public var icon: String {
        switch self {
        case .skill: return "sparkles"
        case .schedule: return "calendar.badge.clock"
        case .command: return "text.bubble.fill"
        case .mcp: return "antenna.radiowaves.left.and.right"
        }
    }

    // `ThemeProtocol` is internal, so this helper can't be public itself.
    // Callers live in the same module (`PluginsView`, the card and detail
    // SwiftUI files), so internal visibility is sufficient.
    func tint(_ theme: any ThemeProtocol) -> Color {
        switch self {
        case .skill: return theme.accentColor
        case .schedule: return .orange
        case .command: return .blue
        case .mcp: return .purple
        }
    }

    /// "N skills" / "N schedule" — used by detail / card subtitles.
    public func label(count: Int) -> String {
        switch self {
        case .mcp: return "\(count) MCP"
        case .skill: return "\(count) skill\(count == 1 ? "" : "s")"
        case .schedule: return "\(count) schedule\(count == 1 ? "" : "s")"
        case .command: return "\(count) command\(count == 1 ? "" : "s")"
        }
    }

    /// Plural section heading used as the group title in the detail
    /// view's Components section. "Slash commands" / "MCP providers"
    /// are written out long-form so the section reads as a real label
    /// instead of an abbreviation.
    public var titlePlural: String {
        switch self {
        case .skill: return L("Skills")
        case .schedule: return L("Schedules")
        case .command: return L("Slash commands")
        case .mcp: return L("MCP providers")
        }
    }
}

/// Per-kind counters, indexed via key paths so a single helper can
/// increment any field. Equatable so the aggregator can avoid
/// publishing no-op updates.
public struct ClaudePluginArtifactCounts: Equatable, Sendable {
    public var skill = 0
    public var schedule = 0
    public var command = 0
    public var mcp = 0

    public var total: Int { skill + schedule + command + mcp }

    public init(skill: Int = 0, schedule: Int = 0, command: Int = 0, mcp: Int = 0) {
        self.skill = skill
        self.schedule = schedule
        self.command = command
        self.mcp = mcp
    }

    public subscript(kind: ClaudePluginArtifactKind) -> Int {
        switch kind {
        case .skill: return skill
        case .schedule: return schedule
        case .command: return command
        case .mcp: return mcp
        }
    }

    public static func + (
        lhs: ClaudePluginArtifactCounts,
        rhs: ClaudePluginArtifactCounts
    ) -> ClaudePluginArtifactCounts {
        ClaudePluginArtifactCounts(
            skill: lhs.skill + rhs.skill,
            schedule: lhs.schedule + rhs.schedule,
            command: lhs.command + rhs.command,
            mcp: lhs.mcp + rhs.mcp
        )
    }
}

/// Per-item projections used by `ClaudePluginDetailView` to render rich
/// rows under Components. These intentionally mirror only the fields the
/// row UI needs so the detail view doesn't have to bind to mutable
/// manager models (which would pull entire `@Published` arrays into the
/// view as render dependencies).
///
/// All four projection structs are `Sendable`/`Equatable` so the
/// aggregator's `@Published plugins` array stays diff-friendly.
public struct InstalledClaudeSkill: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let description: String
    public let category: String?
    public let enabled: Bool
    /// Full SKILL.md instructions body. Surfaced in the preview popover.
    public let instructions: String
    public let keywords: [String]
    public let version: String
    public let author: String?
    public let referenceCount: Int
    public let assetCount: Int

    public init(
        id: UUID,
        name: String,
        description: String,
        category: String?,
        enabled: Bool,
        instructions: String = "",
        keywords: [String] = [],
        version: String = "1.0.0",
        author: String? = nil,
        referenceCount: Int = 0,
        assetCount: Int = 0
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.category = category
        self.enabled = enabled
        self.instructions = instructions
        self.keywords = keywords
        self.version = version
        self.author = author
        self.referenceCount = referenceCount
        self.assetCount = assetCount
    }
}

public struct InstalledClaudeSchedule: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let frequencyText: String
    public let nextRunText: String?
    public let isEnabled: Bool
    /// Full instructions text sent to the agent when the schedule runs.
    public let instructions: String
    public let folderPath: String?
    public let lastRunAt: Date?

    public init(
        id: UUID,
        name: String,
        frequencyText: String,
        nextRunText: String?,
        isEnabled: Bool,
        instructions: String = "",
        folderPath: String? = nil,
        lastRunAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.frequencyText = frequencyText
        self.nextRunText = nextRunText
        self.isEnabled = isEnabled
        self.instructions = instructions
        self.folderPath = folderPath
        self.lastRunAt = lastRunAt
    }
}

public struct InstalledClaudeCommand: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let icon: String
    public let description: String
    /// First line / truncated preview used by the row subtitle.
    public let templatePreview: String?
    /// Full template body. May be `nil` for `.action`-kind commands.
    public let template: String?
    public let kindLabel: String

    public init(
        id: UUID,
        name: String,
        icon: String,
        description: String,
        templatePreview: String?,
        template: String? = nil,
        kindLabel: String = "Template"
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.description = description
        self.templatePreview = templatePreview
        self.template = template
        self.kindLabel = kindLabel
    }
}

/// Unified MCP projection covering both HTTP/SSE and stdio servers so a
/// plugin's "MCP providers" group can list them in one place rather
/// than the old split between count chip + separate stdio section.
public struct InstalledClaudeMCP: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let transport: MCPProviderTransport
    public let executionHost: MCPProviderExecutionHost
    public let enabled: Bool
    /// HTTP URL for `.http`, `command [args...]` for `.stdio`.
    public let subtitle: String
    /// HTTP URL (empty for stdio).
    public let url: String
    /// Stdio command (empty for HTTP).
    public let command: String
    public let args: [String]
    /// Working directory the stdio subprocess inherits, if set.
    public let workingDirectory: String?
    /// `env` keys with their plain values (sensitive keys are stripped
    /// from values but their key names remain so the preview can still
    /// surface them as "[secret]"). Safe to render in UI.
    public let envEntries: [InstalledClaudeMCPEnv]

    public init(
        id: UUID,
        name: String,
        transport: MCPProviderTransport,
        executionHost: MCPProviderExecutionHost,
        enabled: Bool,
        subtitle: String,
        url: String = "",
        command: String = "",
        args: [String] = [],
        workingDirectory: String? = nil,
        envEntries: [InstalledClaudeMCPEnv] = []
    ) {
        self.id = id
        self.name = name
        self.transport = transport
        self.executionHost = executionHost
        self.enabled = enabled
        self.subtitle = subtitle
        self.url = url
        self.command = command
        self.args = args
        self.workingDirectory = workingDirectory
        self.envEntries = envEntries
    }

    public var isStdio: Bool { transport == .stdio }
}

/// One row in the MCP preview's env table. `value` is `nil` when the
/// key is sensitive (stored in Keychain) so the UI can render
/// "[secret]" without surfacing the actual material.
public struct InstalledClaudeMCPEnv: Identifiable, Equatable, Sendable {
    public let key: String
    public let value: String?
    public var id: String { key }
    public var isSensitive: Bool { value == nil }

    public init(key: String, value: String?) {
        self.key = key
        self.value = value
    }
}

extension SlashCommandKind {
    /// Short human-friendly label used by the slash-command preview row
    /// header. `template` is by far the most common kind for plugin
    /// commands; `action` and `skill` exist mainly for built-ins.
    fileprivate var previewLabel: String {
        switch self {
        case .template: return "Template"
        case .action: return "Action"
        case .skill: return "Skill"
        }
    }
}

/// Card-ready view-model for an installed Claude plugin. Combines the
/// persisted manifest snapshot with live counts, the per-artifact
/// projection arrays the detail view uses, and version-update status.
public struct ClaudePluginInstalled: Identifiable, Equatable, Sendable {
    public let pluginId: String
    /// Persisted snapshot — may be `nil` for plugins installed before
    /// the snapshot store was introduced. In that case the card falls
    /// back to deriving a display name from the pluginId.
    public let snapshot: ClaudePluginManifestSnapshot?
    public let counts: ClaudePluginArtifactCounts
    public let skills: [InstalledClaudeSkill]
    public let schedules: [InstalledClaudeSchedule]
    public let commands: [InstalledClaudeCommand]
    public let mcps: [InstalledClaudeMCP]
    public let availableVersion: String?

    public init(
        pluginId: String,
        snapshot: ClaudePluginManifestSnapshot?,
        counts: ClaudePluginArtifactCounts,
        skills: [InstalledClaudeSkill] = [],
        schedules: [InstalledClaudeSchedule] = [],
        commands: [InstalledClaudeCommand] = [],
        mcps: [InstalledClaudeMCP] = [],
        availableVersion: String? = nil
    ) {
        self.pluginId = pluginId
        self.snapshot = snapshot
        self.counts = counts
        self.skills = skills
        self.schedules = schedules
        self.commands = commands
        self.mcps = mcps
        self.availableVersion = availableVersion
    }

    public var id: String { pluginId }

    public var displayName: String {
        snapshot?.displayName
            ?? Self.derivedDisplayName(from: pluginId)
    }

    public var sourceLabel: String {
        if let snap = snapshot {
            return "\(snap.sourceOwner)/\(snap.sourceRepo)"
        }
        return Self.derivedSourceLabel(from: pluginId)
    }

    public var totalCount: Int { counts.total }

    public var version: String? { snapshot?.version }

    public var declaredCounts: ClaudePluginArtifactCounts {
        guard let declared = snapshot?.declaredCounts else { return counts }
        return ClaudePluginArtifactCounts(
            skill: declared.skills,
            schedule: declared.agents,
            command: declared.commands,
            mcp: declared.mcp
        )
    }

    public var missingDeclaredCounts: ClaudePluginArtifactCounts {
        let declared = declaredCounts
        return ClaudePluginArtifactCounts(
            skill: max(declared.skill - counts.skill, 0),
            schedule: max(declared.schedule - counts.schedule, 0),
            command: max(declared.command - counts.command, 0),
            mcp: max(declared.mcp - counts.mcp, 0)
        )
    }

    public var hasPartialImport: Bool { missingDeclaredCounts.total > 0 }

    public var needsPostInstallAttention: Bool {
        snapshot?.installOutcome?.requiresAttention == true || hasPartialImport
    }

    public func declaredCount(for kind: ClaudePluginArtifactKind) -> Int {
        declaredCounts[kind]
    }

    public var hasUpdate: Bool {
        GitHubSkillService.ClaudePluginVersionResolver.hasUpdate(
            installed: snapshot?.version,
            available: availableVersion
        )
    }

    // MARK: - pluginId helpers

    /// Friendly title-cased plugin name from `github:owner/repo/my-plugin`.
    /// Falls back to the raw id when the format is unexpected.
    public static func derivedDisplayName(from pluginId: String) -> String {
        guard let parts = githubIdComponents(pluginId) else { return pluginId }
        return parts.plugin
            .split(separator: "-")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    public static func derivedSourceLabel(from pluginId: String) -> String {
        guard let parts = githubIdComponents(pluginId) else { return pluginId }
        return "\(parts.owner)/\(parts.repo)"
    }

    public static func isClaudePluginId(_ id: String) -> Bool {
        id.hasPrefix("github:")
    }

    private static func githubIdComponents(_ id: String) -> (
        owner: String, repo: String, plugin: String
    )? {
        guard id.hasPrefix("github:") else { return nil }
        let tail = id.dropFirst("github:".count)
        let parts = tail.split(separator: "/", maxSplits: 2).map(String.init)
        guard parts.count == 3 else { return nil }
        return (parts[0], parts[1], parts[2])
    }
}

// MARK: - Aggregator

/// Aggregates Claude-plugin state across the manifest store and the
/// four managers. Live-refreshed whenever a manager publishes a change.
@MainActor
public final class InstalledClaudePluginsAggregator: ObservableObject {
    @Published public private(set) var plugins: [ClaudePluginInstalled] = []
    @Published public private(set) var totals = ClaudePluginArtifactCounts()
    /// True while `checkForUpdates` is in flight. UI can dim the Update
    /// button to avoid double-clicks.
    @Published public private(set) var isCheckingForUpdates: Bool = false

    private let skillManager: SkillManager
    private let scheduleManager: ScheduleManager
    private let slashCommands: SlashCommandRegistry
    private let mcpManager: MCPProviderManager

    /// Cached "available" versions keyed by pluginId. Persisted only in
    /// memory; rebuilt by `checkForUpdates()`.
    private var availableVersions: [String: String] = [:]

    public init(
        skillManager: SkillManager = .shared,
        scheduleManager: ScheduleManager = .shared,
        slashCommands: SlashCommandRegistry = .shared,
        mcpManager: MCPProviderManager = .shared
    ) {
        self.skillManager = skillManager
        self.scheduleManager = scheduleManager
        self.slashCommands = slashCommands
        self.mcpManager = mcpManager
        Task { @MainActor [weak self] in
            self?.refresh()
        }
    }

    /// Re-aggregate every Claude-plugin record. Cheap on small N — the
    /// section calls this from manager `onChange` listeners with a
    /// 200 ms debounce upstream so a 170-skill import only fires once.
    public func refresh() {
        let result = Self.buildPlugins(
            snapshots: ClaudePluginManifestStore.all(),
            skills: skillManager.skills,
            schedules: scheduleManager.schedules,
            commands: slashCommands.customCommands,
            providers: mcpManager.configuration.providers,
            availableVersions: availableVersions
        )

        let aggregate = result.map(\.counts).reduce(ClaudePluginArtifactCounts(), +)

        if result != plugins { plugins = result }
        if aggregate != totals { totals = aggregate }
    }

    /// Pure projection of manifest snapshots + live manager records into
    /// the card/detail view-model array. Extracted out of `refresh()` so
    /// tests can drive the mapping deterministically without binding to
    /// `.shared` singletons. Public-but-unstable: only the aggregator
    /// itself and its tests call this directly. `nonisolated` so test
    /// suites can call it from any actor (the function touches no
    /// actor-isolated state).
    public nonisolated static func buildPlugins(
        snapshots: [ClaudePluginManifestSnapshot],
        skills: [Skill],
        schedules: [Schedule],
        commands: [SlashCommand],
        providers: [MCPProvider],
        availableVersions: [String: String] = [:]
    ) -> [ClaudePluginInstalled] {
        var snapshotById: [String: ClaudePluginManifestSnapshot] = [:]
        for snap in snapshots {
            snapshotById[snap.pluginId] = snap
        }

        var perPlugin: [String: ClaudePluginArtifactCounts] = [:]
        var perPluginSkills: [String: [InstalledClaudeSkill]] = [:]
        var perPluginSchedules: [String: [InstalledClaudeSchedule]] = [:]
        var perPluginCommands: [String: [InstalledClaudeCommand]] = [:]
        var perPluginMCPs: [String: [InstalledClaudeMCP]] = [:]

        func bump(
            _ pluginId: String?,
            _ field: WritableKeyPath<ClaudePluginArtifactCounts, Int>
        ) {
            guard let pluginId,
                ClaudePluginInstalled.isClaudePluginId(pluginId)
            else { return }
            perPlugin[pluginId, default: ClaudePluginArtifactCounts()][keyPath: field] += 1
        }

        for skill in skills {
            bump(skill.pluginId, \.skill)
            if let pluginId = skill.pluginId,
                ClaudePluginInstalled.isClaudePluginId(pluginId)
            {
                perPluginSkills[pluginId, default: []].append(
                    InstalledClaudeSkill(
                        id: skill.id,
                        name: skill.name,
                        description: skill.description,
                        category: skill.category,
                        enabled: skill.enabled,
                        instructions: skill.instructions,
                        keywords: skill.keywords,
                        version: skill.version,
                        author: skill.author,
                        referenceCount: skill.references.count,
                        assetCount: skill.assets.count
                    )
                )
            }
        }
        for schedule in schedules {
            let pluginId = schedule.parameters[ScheduleManager.pluginIdParameterKey]
            bump(pluginId, \.schedule)
            if let pluginId,
                ClaudePluginInstalled.isClaudePluginId(pluginId)
            {
                perPluginSchedules[pluginId, default: []].append(
                    InstalledClaudeSchedule(
                        id: schedule.id,
                        name: schedule.name,
                        frequencyText: schedule.frequency.displayDescription,
                        nextRunText: schedule.nextRunDescription,
                        isEnabled: schedule.isEnabled,
                        instructions: schedule.instructions,
                        folderPath: schedule.folderPath,
                        lastRunAt: schedule.lastRunAt
                    )
                )
            }
        }
        for command in commands {
            bump(command.pluginId, \.command)
            if let pluginId = command.pluginId,
                ClaudePluginInstalled.isClaudePluginId(pluginId)
            {
                perPluginCommands[pluginId, default: []].append(
                    InstalledClaudeCommand(
                        id: command.id,
                        name: command.name,
                        icon: command.icon,
                        description: command.description,
                        templatePreview: templatePreview(for: command.template),
                        template: command.template,
                        kindLabel: command.kind.previewLabel
                    )
                )
            }
        }
        for provider in providers {
            bump(provider.pluginId, \.mcp)
            if let pluginId = provider.pluginId,
                ClaudePluginInstalled.isClaudePluginId(pluginId)
            {
                perPluginMCPs[pluginId, default: []].append(
                    InstalledClaudeMCP(
                        id: provider.id,
                        name: provider.name,
                        transport: provider.transport,
                        executionHost: provider.executionHost,
                        enabled: provider.enabled,
                        subtitle: mcpSubtitle(for: provider),
                        url: provider.url,
                        command: provider.command,
                        args: provider.args,
                        workingDirectory: provider.workingDirectory,
                        envEntries: envEntries(for: provider)
                    )
                )
            }
        }

        // Union of pluginIds known to the manifest store and the live
        // managers. A snapshot with no live artifacts is still rendered
        // (count==0) so users can see plugins that haven't loaded yet,
        // and a live artifact without a snapshot still appears with
        // derived display name (pre-snapshot installs).
        var allPluginIds = Set(perPlugin.keys)
        for id in snapshotById.keys { allPluginIds.insert(id) }

        return allPluginIds.map { id in
            ClaudePluginInstalled(
                pluginId: id,
                snapshot: snapshotById[id],
                counts: perPlugin[id] ?? ClaudePluginArtifactCounts(),
                skills: (perPluginSkills[id] ?? []).sorted { byName($0.name, $1.name) },
                schedules: (perPluginSchedules[id] ?? []).sorted { byName($0.name, $1.name) },
                commands: (perPluginCommands[id] ?? []).sorted { byName($0.name, $1.name) },
                mcps: (perPluginMCPs[id] ?? []).sorted { byName($0.name, $1.name) },
                availableVersion: availableVersions[id]
            )
        }
        .sorted { lhs, rhs in
            lhs.displayName.lowercased() < rhs.displayName.lowercased()
        }
    }

    // MARK: - Projection helpers

    /// Compact one-line subtitle for an MCP row: the HTTP URL for
    /// `.http` providers, or `command [args...]` for `.stdio`. The
    /// detail view uses this verbatim as the row's secondary line.
    private nonisolated static func mcpSubtitle(for provider: MCPProvider) -> String {
        switch provider.transport {
        case .stdio:
            return provider.args.isEmpty
                ? provider.command
                : "\(provider.command) \(provider.args.joined(separator: " "))"
        case .http:
            return provider.url
        }
    }

    /// Truncate the slash command template to a one-line preview so the
    /// detail row doesn't expand to fit a 200-line prompt body.
    private nonisolated static func templatePreview(for template: String?) -> String? {
        guard
            let template = template?
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !template.isEmpty
        else { return nil }
        if template.count <= 80 { return template }
        return template.prefix(77).trimmingCharacters(in: .whitespaces) + "..."
    }

    private nonisolated static func byName(_ lhs: String, _ rhs: String) -> Bool {
        lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
    }

    /// Render the stdio MCP's `env` dictionary as preview-safe rows:
    /// plain values pass through; values for keys in
    /// `secretEnvKeys` (Keychain-backed) are scrubbed to `nil` so the
    /// popover can show `[secret]` without revealing the material.
    /// Sorted by key for stable UI.
    private nonisolated static func envEntries(
        for provider: MCPProvider
    ) -> [InstalledClaudeMCPEnv] {
        let secretKeys = Set(provider.secretEnvKeys)
        var entries: [InstalledClaudeMCPEnv] = []
        for key in provider.env.keys {
            let value = secretKeys.contains(key) ? nil : provider.env[key]
            entries.append(InstalledClaudeMCPEnv(key: key, value: value))
        }
        // Include secret-only keys that have no plain entry (rare but
        // possible when a value lives entirely in Keychain).
        for key in provider.secretEnvKeys where provider.env[key] == nil {
            entries.append(InstalledClaudeMCPEnv(key: key, value: nil))
        }
        return entries.sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
    }

    /// Probe the source repo for newer versions and re-emit the
    /// `plugins` list with `availableVersion` populated. Honours the
    /// shared `GitHubFetchLimiter` so a refresh on 20 plugins doesn't
    /// burn through the unauthenticated GitHub rate limit.
    public func checkForUpdates(using service: GitHubSkillService = .shared) async {
        guard !isCheckingForUpdates else { return }
        isCheckingForUpdates = true
        defer { isCheckingForUpdates = false }

        let snapshots = plugins.compactMap { $0.snapshot }
        guard !snapshots.isEmpty else { return }

        let limiter = GitHubFetchLimiter.shared
        var newVersions: [String: String] = [:]

        await withTaskGroup(of: (String, String?).self) { group in
            for snap in snapshots {
                group.addTask { @Sendable in
                    let pluginJSONPath: String = {
                        guard let path = snap.sourcePath, !path.isEmpty else {
                            return ".claude-plugin/plugin.json"
                        }
                        return "\(path)/.claude-plugin/plugin.json"
                    }()
                    let repo = GitHubRepo(
                        owner: snap.sourceOwner,
                        name: snap.sourceRepo,
                        branch: snap.sourceBranch ?? "main"
                    )
                    let json = await limiter.runNoThrow {
                        await service.fetchOptionalFileContent(
                            from: repo,
                            path: pluginJSONPath
                        )
                    }
                    if let parsed = json.flatMap(ClaudePluginJSON.parse),
                        let v = parsed.version
                    {
                        return (snap.pluginId, v)
                    }
                    // Fallback: ask for the head SHA on the source path
                    // so SHA-versioned plugins still surface updates.
                    let sha: String? = await limiter.runNoThrow {
                        await service.fetchSourceSHANonIsolated(
                            owner: snap.sourceOwner,
                            repo: snap.sourceRepo,
                            branch: snap.sourceBranch ?? "main",
                            path: snap.sourcePath
                        )
                    }
                    if let s = sha { return (snap.pluginId, String(s.prefix(7))) }
                    return (snap.pluginId, nil)
                }
            }
            for await (id, version) in group {
                if let version { newVersions[id] = version }
            }
        }

        availableVersions = newVersions
        refresh()
    }
}
