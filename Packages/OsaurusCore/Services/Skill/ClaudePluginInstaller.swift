//
//  ClaudePluginInstaller.swift
//  osaurus
//
//  Installs a "Claude plugin" (claude-for-legal-style) discovered by
//  `GitHubSkillService.fetchPlugins`. Maps each compatible part to its
//  Osaurus equivalent and tags everything with a stable plugin id so the
//  whole bundle can be enabled/disabled/uninstalled as a unit.
//

import Foundation

// MARK: - Selection

/// Per-plugin selection of which artifacts to install. UI populates this from
/// the user's checkbox tree.
public struct ClaudePluginSelection: Sendable {
    public let manifest: ClaudePluginManifest
    /// Skill paths (subset of `manifest.skills`) to install.
    public var selectedSkillPaths: Set<String>
    /// Agent .md paths (subset of `manifest.agents`) to install as schedules.
    public var selectedAgentPaths: Set<String>
    /// Command .md paths (subset of `manifest.commands`) to install as slash commands.
    public var selectedCommandPaths: Set<String>
    /// Whether to import `.mcp.json` HTTP/SSE servers (stdio entries are always skipped).
    public var importMCP: Bool
    /// Whether to attach `CLAUDE.md` as a reference on every imported skill.
    public var attachClaudeMd: Bool

    public init(
        manifest: ClaudePluginManifest,
        selectedSkillPaths: Set<String>? = nil,
        selectedAgentPaths: Set<String>? = nil,
        selectedCommandPaths: Set<String>? = nil,
        importMCP: Bool = true,
        attachClaudeMd: Bool = true
    ) {
        self.manifest = manifest
        self.selectedSkillPaths = selectedSkillPaths ?? Set(manifest.skills.map { $0.path })
        self.selectedAgentPaths = selectedAgentPaths ?? Set(manifest.agents.map { $0.path })
        self.selectedCommandPaths = selectedCommandPaths ?? Set(manifest.commands.map { $0.path })
        self.importMCP = importMCP
        self.attachClaudeMd = attachClaudeMd
    }

    public var totalSelected: Int {
        selectedSkillPaths.count + selectedAgentPaths.count + selectedCommandPaths.count
            + (importMCP && manifest.mcpJsonPath != nil ? 1 : 0)
    }
}

// MARK: - Report

/// Summary of what an install actually did. Surfaced in the UI so the user can
/// see exactly what landed and what was skipped.
public struct ClaudePluginInstallReport: Sendable {
    /// Identifies a schedule that landed disabled because no cron could be
    /// inferred. Exposed as an Identifiable struct so the install summary can
    /// render it in a SwiftUI ForEach and deep-link to the editor.
    public struct PendingSchedule: Sendable, Identifiable, Hashable {
        public let id: UUID
        public let name: String

        public init(id: UUID, name: String) {
            self.id = id
            self.name = name
        }
    }

    public struct PluginSummary: Sendable {
        public let pluginId: String
        public let pluginName: String
        public var importedSkillCount: Int = 0
        public var importedAgentCount: Int = 0
        public var importedCommandCount: Int = 0
        public var importedMCPProviderCount: Int = 0
        /// Server names from `.mcp.json` that we couldn't auto-install because
        /// Osaurus's remote MCP transport is HTTP/SSE only — these need manual
        /// stdio configuration.
        public var skippedStdioMCPServers: [String] = []
        /// MCP servers whose env-style token was a placeholder (e.g.
        /// `${VAULT_TOKEN}`). The provider was created without a token so the
        /// user must paste a real one before enabling.
        public var placeholderTokensSkipped: [String] = []
        /// Schedules that couldn't infer a cron — created disabled so the
        /// user can review and configure. Identified by `Schedule.id` so the
        /// UI can deep-link to the editor.
        public var schedulesNeedingCron: [PendingSchedule] = []
        public var errors: [String] = []
    }

    public var perPlugin: [PluginSummary] = []

    public var totalImportedSkills: Int { perPlugin.reduce(0) { $0 + $1.importedSkillCount } }
    public var totalImportedAgents: Int { perPlugin.reduce(0) { $0 + $1.importedAgentCount } }
    public var totalImportedCommands: Int { perPlugin.reduce(0) { $0 + $1.importedCommandCount } }
    public var totalImportedMCPProviders: Int {
        perPlugin.reduce(0) { $0 + $1.importedMCPProviderCount }
    }
    public var hasAnyImports: Bool {
        totalImportedSkills + totalImportedAgents + totalImportedCommands + totalImportedMCPProviders
            > 0
    }
    public var allSkippedStdioServers: [String] {
        perPlugin.flatMap { $0.skippedStdioMCPServers }
    }
    public var allPlaceholderTokensSkipped: [String] {
        perPlugin.flatMap { $0.placeholderTokensSkipped }
    }
    public var allSchedulesNeedingCron: [PendingSchedule] {
        perPlugin.flatMap { $0.schedulesNeedingCron }
    }
    public var allErrors: [String] {
        perPlugin.flatMap { $0.errors }
    }
}

// MARK: - Installer

@MainActor
public final class ClaudePluginInstaller {
    public static let shared = ClaudePluginInstaller()

    private let github: GitHubSkillService

    public init(github: GitHubSkillService = .shared) {
        self.github = github
    }

    // MARK: - Install

    /// Install one or more selected Claude plugins from a GitHub repository.
    ///
    /// - Parameters:
    ///   - selections: per-plugin choices (skills, agents, commands, MCP, CLAUDE.md).
    ///   - repo: the resolved GitHub repository the manifests came from.
    ///   - replaceExisting: when true (default), every non-skill artifact
    ///     previously installed for the plugin is removed before the new
    ///     install runs. Skills are always idempotent via
    ///     `SkillManager.importSkillsPreservingPluginId(_:)`. Tests can
    ///     opt out to verify the underlying create paths in isolation.
    ///   - progressHandler: optional callback `(current, total)` used for UI progress.
    ///     The callback is invoked on the main actor so it can write to
    ///     `@State` directly — do not wrap it in `Task` from the caller.
    @discardableResult
    public func install(
        selections: [ClaudePluginSelection],
        from repo: GitHubRepo,
        replaceExisting: Bool = true,
        progressHandler: (@MainActor (Int, Int) -> Void)? = nil
    ) async -> ClaudePluginInstallReport {
        var report = ClaudePluginInstallReport()

        let totalSteps = selections.reduce(0) { $0 + $1.totalSelected }
        var step = 0
        func tick() {
            step += 1
            progressHandler?(step, max(totalSteps, 1))
        }

        for selection in selections {
            let manifest = selection.manifest
            let pluginId = Self.pluginId(repo: repo, pluginName: manifest.name)
            var summary = ClaudePluginInstallReport.PluginSummary(
                pluginId: pluginId,
                pluginName: manifest.name
            )

            // Replace semantics: wipe any artifacts this plugin previously
            // installed so re-running install on the same repo never piles
            // up duplicate schedules / commands / MCP providers (skills
            // dedupe by `(pluginId, name)` further down).
            if replaceExisting {
                ScheduleManager.shared.deleteByPluginId(pluginId)
                SlashCommandRegistry.shared.deleteByPluginId(pluginId)
                MCPProviderManager.shared.deleteByPluginId(pluginId)
            }

            // ── Phase 1: fetch every file we need for this plugin in
            // parallel.  Managers are all `@MainActor`, so we cannot apply
            // mutations concurrently, but the network is the dominant cost
            // and these fetches are independent.
            let fetched = await fetchArtifacts(for: selection, repo: repo)

            // ── Phase 2: apply fetched content sequentially on the main
            // actor.

            // 1. Skills (with optional CLAUDE.md attached as a reference).
            for fetchedSkill in fetched.skills {
                defer { tick() }
                switch fetchedSkill.content {
                case .failure(let error):
                    summary.errors.append(
                        "skill \(fetchedSkill.entry.path): \(error.localizedDescription)"
                    )
                case .success(let content):
                    do {
                        var parsed = try Skill.parseAnyFormat(from: content)
                        parsed.pluginId = pluginId
                        if parsed.category == nil || parsed.category?.isEmpty == true {
                            parsed.category = manifest.name
                        }
                        if parsed.author == nil, let owner = manifest.authorName {
                            parsed.author = owner
                        }

                        let imported = await SkillManager.shared
                            .importSkillsPreservingPluginId([parsed])

                        if let savedSkill = imported.first,
                            let claudeMdContent = fetched.claudeMd,
                            let data = claudeMdContent.data(using: .utf8)
                        {
                            try? await SkillManager.shared.addReference(
                                to: savedSkill.id,
                                name: "CLAUDE.md",
                                content: data
                            )
                        }

                        summary.importedSkillCount += 1
                    } catch {
                        summary.errors.append(
                            "skill \(fetchedSkill.entry.path): \(error.localizedDescription)"
                        )
                    }
                }
            }

            // 2. Scheduled agents
            for fetchedAgent in fetched.agents {
                defer { tick() }
                switch fetchedAgent.content {
                case .failure(let error):
                    summary.errors.append(
                        "agent \(fetchedAgent.entry.path): \(error.localizedDescription)"
                    )
                case .success(let content):
                    let (frontmatter, body) = ClaudeMarkdownParser.extract(content)
                    let scheduleName = "\(manifest.name):\(fetchedAgent.entry.displayName)"
                    let description = frontmatter["description"]?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let inferredCron = inferCron(from: frontmatter)

                    let frequency: ScheduleFrequency
                    let isEnabled: Bool
                    let needsCronReview: Bool
                    if let cron = inferredCron {
                        frequency = .cron(expression: cron)
                        isEnabled = true
                        needsCronReview = false
                    } else {
                        // Default placeholder: weekly Monday 9 AM. Created
                        // disabled so we never silently run something the
                        // user didn't review.
                        frequency = .cron(expression: "0 9 * * 1")
                        isEnabled = false
                        needsCronReview = true
                    }

                    let instructions: String = {
                        var pieces: [String] = []
                        if let description, !description.isEmpty {
                            pieces.append(description)
                        }
                        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmedBody.isEmpty {
                            pieces.append(trimmedBody)
                        }
                        return pieces.joined(separator: "\n\n")
                    }()

                    let created = ScheduleManager.shared.create(
                        name: scheduleName,
                        instructions: instructions,
                        parameters: [
                            ScheduleManager.pluginIdParameterKey: pluginId,
                            "claudePluginName": manifest.name,
                        ],
                        frequency: frequency,
                        isEnabled: isEnabled
                    )

                    if needsCronReview {
                        summary.schedulesNeedingCron.append(
                            ClaudePluginInstallReport.PendingSchedule(
                                id: created.id,
                                name: scheduleName
                            )
                        )
                    }

                    summary.importedAgentCount += 1
                }
            }

            // 3. Slash commands
            for fetchedCommand in fetched.commands {
                defer { tick() }
                switch fetchedCommand.content {
                case .failure(let error):
                    summary.errors.append(
                        "command \(fetchedCommand.entry.path): \(error.localizedDescription)"
                    )
                case .success(let content):
                    let (frontmatter, body) = ClaudeMarkdownParser.extract(content)
                    let displaySlug =
                        (frontmatter["name"]?
                        .trimmingCharacters(in: .whitespacesAndNewlines))
                        .flatMap { $0.isEmpty ? nil : $0 }
                        ?? (fetchedCommand.entry.path as NSString)
                        .lastPathComponent
                        .replacingOccurrences(of: ".md", with: "")
                    let cmdName = "\(manifest.name):\(displaySlug)"
                    let description =
                        frontmatter["description"]?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                    _ = SlashCommandRegistry.shared.create(
                        name: cmdName,
                        description: description,
                        icon: "text.bubble",
                        template: body.trimmingCharacters(in: .whitespacesAndNewlines),
                        pluginId: pluginId
                    )

                    summary.importedCommandCount += 1
                }
            }

            // 4. MCP providers (HTTP/SSE only — stdio is reported as skipped).
            if selection.importMCP, let mcpPath = manifest.mcpJsonPath {
                defer { tick() }
                if let content = fetched.mcpJson {
                    let parsed = MCPJSONParser.parse(content)
                    for server in parsed.servers {
                        if let url = server.url, !url.isEmpty {
                            let hasRealToken = (server.token?.isEmpty == false)
                            let provider = MCPProvider(
                                name: "\(manifest.name): \(server.name)",
                                url: url,
                                enabled: false,  // Created disabled so user reviews tokens first.
                                customHeaders: server.headers ?? [:],
                                authType: hasRealToken ? .bearerToken : .none,
                                pluginId: pluginId
                            )
                            MCPProviderManager.shared.addProvider(
                                provider,
                                token: hasRealToken ? server.token : nil
                            )
                            if server.tokenIsPlaceholder {
                                summary.placeholderTokensSkipped.append(server.name)
                            }
                            summary.importedMCPProviderCount += 1
                        } else {
                            summary.skippedStdioMCPServers.append(server.name)
                        }
                    }
                } else {
                    summary.errors.append("Could not fetch \(mcpPath)")
                }
            }

            report.perPlugin.append(summary)
        }

        return report
    }

    // MARK: - Concurrent fetch helpers

    /// Result of fetching one skill / agent / command markdown file. We use
    /// `Result` so a single failure doesn't poison the whole batch — each
    /// failed artifact is reported individually in the install summary.
    private struct FetchedSkill {
        let entry: ClaudeSkillEntry
        let content: Result<String, Error>
    }
    private struct FetchedAgent {
        let entry: ClaudeAgentEntry
        let content: Result<String, Error>
    }
    private struct FetchedCommand {
        let entry: ClaudeCommandEntry
        let content: Result<String, Error>
    }

    private struct FetchedArtifacts {
        let claudeMd: String?
        let skills: [FetchedSkill]
        let agents: [FetchedAgent]
        let commands: [FetchedCommand]
        let mcpJson: String?
    }

    /// Fetch every file referenced by `selection` in parallel. Preserves the
    /// declared order in `manifest` so the install summary renders in the
    /// same order regardless of which fetch finished first.
    private func fetchArtifacts(
        for selection: ClaudePluginSelection,
        repo: GitHubRepo
    ) async -> FetchedArtifacts {
        let manifest = selection.manifest

        async let claudeMdTask: String? = {
            guard selection.attachClaudeMd, let path = manifest.claudeMdPath else { return nil }
            return await github.fetchOptionalFileContent(from: repo, path: path)
        }()

        async let mcpJsonTask: String? = {
            guard selection.importMCP, let path = manifest.mcpJsonPath else { return nil }
            return await github.fetchOptionalFileContent(from: repo, path: path)
        }()

        let skillEntries = manifest.skills.filter {
            selection.selectedSkillPaths.contains($0.path)
        }
        let agentEntries = manifest.agents.filter {
            selection.selectedAgentPaths.contains($0.path)
        }
        let commandEntries = manifest.commands.filter {
            selection.selectedCommandPaths.contains($0.path)
        }

        async let skills = withTaskGroup(of: (Int, FetchedSkill).self) { group -> [FetchedSkill] in
            for (idx, entry) in skillEntries.enumerated() {
                group.addTask { [github] in
                    do {
                        let content = try await github.fetchSkillContent(
                            from: repo,
                            skillPath: entry.path
                        )
                        return (idx, FetchedSkill(entry: entry, content: .success(content)))
                    } catch {
                        return (idx, FetchedSkill(entry: entry, content: .failure(error)))
                    }
                }
            }
            var out: [(Int, FetchedSkill)] = []
            for await pair in group { out.append(pair) }
            return out.sorted { $0.0 < $1.0 }.map { $0.1 }
        }

        async let agents = withTaskGroup(of: (Int, FetchedAgent).self) { group -> [FetchedAgent] in
            for (idx, entry) in agentEntries.enumerated() {
                group.addTask { [github] in
                    do {
                        let content = try await github.fetchFileContent(from: repo, path: entry.path)
                        return (idx, FetchedAgent(entry: entry, content: .success(content)))
                    } catch {
                        return (idx, FetchedAgent(entry: entry, content: .failure(error)))
                    }
                }
            }
            var out: [(Int, FetchedAgent)] = []
            for await pair in group { out.append(pair) }
            return out.sorted { $0.0 < $1.0 }.map { $0.1 }
        }

        async let commands = withTaskGroup(of: (Int, FetchedCommand).self) {
            group -> [FetchedCommand] in
            for (idx, entry) in commandEntries.enumerated() {
                group.addTask { [github] in
                    do {
                        let content = try await github.fetchFileContent(from: repo, path: entry.path)
                        return (idx, FetchedCommand(entry: entry, content: .success(content)))
                    } catch {
                        return (idx, FetchedCommand(entry: entry, content: .failure(error)))
                    }
                }
            }
            var out: [(Int, FetchedCommand)] = []
            for await pair in group { out.append(pair) }
            return out.sorted { $0.0 < $1.0 }.map { $0.1 }
        }

        return await FetchedArtifacts(
            claudeMd: claudeMdTask,
            skills: skills,
            agents: agents,
            commands: commands,
            mcpJson: mcpJsonTask
        )
    }

    // MARK: - Uninstall

    /// Remove every artifact previously installed for `pluginId` across skills,
    /// schedules, slash commands, and MCP providers.
    @discardableResult
    public func uninstall(pluginId: String) async -> ClaudePluginInstallReport.PluginSummary {
        var summary = ClaudePluginInstallReport.PluginSummary(
            pluginId: pluginId,
            pluginName: pluginId
        )

        let skillCount = SkillManager.shared.pluginSkills(for: pluginId).count
        await SkillManager.shared.unregisterPluginSkills(pluginId: pluginId)
        summary.importedSkillCount = skillCount

        summary.importedAgentCount = ScheduleManager.shared.deleteByPluginId(pluginId)
        summary.importedCommandCount = SlashCommandRegistry.shared.deleteByPluginId(pluginId)
        summary.importedMCPProviderCount = MCPProviderManager.shared.deleteByPluginId(pluginId)

        return summary
    }

    // MARK: - Plugin Identity

    /// Stable identity key for a plugin installed from a GitHub repo. Used
    /// across `Skill.pluginId`, `Schedule.parameters[pluginId]`,
    /// `SlashCommand.pluginId`, and `MCPProvider.pluginId` so we can find
    /// every artifact at uninstall time.
    public nonisolated static func pluginId(repo: GitHubRepo, pluginName: String) -> String {
        "github:\(repo.owner)/\(repo.name)/\(pluginName)"
    }

    // MARK: - Cron Inference

    /// Look for common keys that describe when a scheduled agent should run.
    /// Returns nil if none is present.
    private func inferCron(from frontmatter: [String: String]) -> String? {
        // Direct cron expression
        if let cron = frontmatter["cron"]?.trimmingCharacters(in: .whitespacesAndNewlines),
            !cron.isEmpty
        {
            return cron
        }
        if let schedule = frontmatter["schedule"]?.trimmingCharacters(in: .whitespacesAndNewlines),
            !schedule.isEmpty
        {
            // Recognise common natural keywords used by Claude plugin authors.
            let lower = schedule.lowercased()
            if lower.contains("hourly") { return "0 * * * *" }
            if lower.contains("daily") { return "0 9 * * *" }
            if lower.contains("weekly") || lower.contains("weekday") {
                return "0 9 * * 1"
            }
            if lower.contains("monthly") { return "0 9 1 * *" }
            // If it looks like a 5-field cron, accept it verbatim.
            let parts = schedule.split(separator: " ")
            if parts.count == 5 || parts.count == 6 { return schedule }
        }
        return nil
    }
}

// MARK: - Markdown / JSON helpers

/// Extracts YAML frontmatter and body from agent/command markdown.
///
/// Delegates parsing to `Skill.parseYamlBlock` so folded (`>`) and literal
/// (`|`) block scalars behave identically to `SKILL.md` parsing. Flattens
/// the resulting `[String: Any]` to `[String: String]` since installer
/// consumers only need string-valued metadata.
enum ClaudeMarkdownParser {
    static func extract(_ markdown: String) -> (frontmatter: [String: String], body: String) {
        guard let split = Skill.splitFrontmatter(markdown) else {
            return ([:], markdown)
        }
        let parsed = Skill.parseYamlBlock(split.frontmatterLines)
        var flattened: [String: String] = [:]
        for (key, value) in parsed {
            if let str = value as? String {
                flattened[key] = str
            } else if let bool = value as? Bool {
                flattened[key] = bool ? "true" : "false"
            } else {
                flattened[key] = String(describing: value)
            }
        }
        return (flattened, split.body)
    }
}

/// Minimal `.mcp.json` parser. Supports both the legacy Claude Code shape
/// (`mcpServers: { "name": { ... } }`) and the equivalent `servers: { ... }`
/// shape used by some forks. Extracts what we need for HTTP/SSE remote
/// providers; everything stdio-style is surfaced as a "skipped" entry.
enum MCPJSONParser {
    struct Parsed: Sendable {
        struct Server: Sendable {
            let name: String
            let url: String?
            let token: String?
            /// True when an env-style token was found but it looked like a
            /// placeholder (e.g. `${VAULT_TOKEN}`). The provider should be
            /// created without a token and surfaced to the user as needing
            /// manual configuration.
            let tokenIsPlaceholder: Bool
            let headers: [String: String]?
        }
        let servers: [Server]
    }

    static func parse(_ text: String) -> Parsed {
        guard let data = text.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return Parsed(servers: [])
        }
        let serversDict =
            (root["mcpServers"] as? [String: Any])
            ?? (root["servers"] as? [String: Any])
            ?? [:]

        var result: [Parsed.Server] = []
        for (name, value) in serversDict {
            guard let serverDict = value as? [String: Any] else { continue }
            let url =
                (serverDict["url"] as? String)
                ?? (serverDict["endpoint"] as? String)
            let headers = (serverDict["headers"] as? [String: String])
            let env = serverDict["env"] as? [String: String] ?? [:]
            let rawToken =
                env["MCP_TOKEN"]
                ?? env["TOKEN"]
                ?? env["API_KEY"]
                ?? (serverDict["token"] as? String)
            let isPlaceholder = rawToken.map(Self.isPlaceholder) ?? false
            let token: String? = (rawToken != nil && !isPlaceholder) ? rawToken : nil
            result.append(
                Parsed.Server(
                    name: name,
                    url: url,
                    token: token,
                    tokenIsPlaceholder: isPlaceholder,
                    headers: headers
                )
            )
        }
        return Parsed(servers: result.sorted { $0.name < $1.name })
    }

    /// Recognises env-var / template placeholders that show up in publicly
    /// shipped `.mcp.json` files. Storing these as literal bearer tokens
    /// breaks auth silently, so the installer skips them and surfaces a
    /// "needs token" notice instead.
    static func isPlaceholder(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        // `${VAR}` or `${VAR:-default}` style.
        if trimmed.hasPrefix("${") && trimmed.hasSuffix("}") { return true }
        // `$VAR` style (uppercase + underscores only).
        if trimmed.hasPrefix("$"), trimmed.count > 1 {
            let body = trimmed.dropFirst()
            let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_")
            if body.unicodeScalars.allSatisfy({ allowed.contains($0) }) {
                return true
            }
        }
        // `<your token here>` style.
        if trimmed.hasPrefix("<") && trimmed.hasSuffix(">") && trimmed.count > 2 {
            return true
        }
        return false
    }
}
