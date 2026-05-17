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
    /// Whether to attach `CLAUDE.md` (and other plugin-root markdown like
    /// `CONNECTORS.md` / `README.md`) as references on every imported skill.
    public var attachClaudeMd: Bool
    /// Whether to walk each skill's directory and pull in co-located
    /// supporting files (`scripts/`, `references/`, `assets/`,
    /// `templates/`, plus loose files at the skill's root). On by default
    /// so plugins like `financial-services` get their Python helpers and
    /// troubleshooting docs imported instead of silently dropped.
    public var includeSkillAssets: Bool

    public init(
        manifest: ClaudePluginManifest,
        selectedSkillPaths: Set<String>? = nil,
        selectedAgentPaths: Set<String>? = nil,
        selectedCommandPaths: Set<String>? = nil,
        importMCP: Bool = true,
        attachClaudeMd: Bool = true,
        includeSkillAssets: Bool = true
    ) {
        self.manifest = manifest
        self.selectedSkillPaths = selectedSkillPaths ?? Set(manifest.skills.map { $0.path })
        self.selectedAgentPaths = selectedAgentPaths ?? Set(manifest.agents.map { $0.path })
        self.selectedCommandPaths = selectedCommandPaths ?? Set(manifest.commands.map { $0.path })
        self.importMCP = importMCP
        self.attachClaudeMd = attachClaudeMd
        self.includeSkillAssets = includeSkillAssets
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
        /// Total co-located asset files (Python helpers, references, etc.)
        /// attached to imported skills.
        public var importedSkillAssetCount: Int = 0
        /// Server names from `.mcp.json` that we couldn't auto-install because
        /// Osaurus's remote MCP transport is HTTP/SSE only — these need manual
        /// stdio configuration.
        public var skippedStdioMCPServers: [String] = []
        /// MCP servers whose env-style token was a placeholder (e.g.
        /// `${VAULT_TOKEN}`). The provider was created without a token so the
        /// user must paste a real one before enabling.
        public var placeholderTokensSkipped: [String] = []
        /// OAuth-protected MCP servers (e.g. Slack, Notion in knowledge-work
        /// plugins) imported as `authType: .oauth` and left disabled. The
        /// user must complete the OAuth sign-in flow in MCP settings before
        /// these will actually authenticate.
        public var oauthProvidersNeedingSignIn: [String] = []
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
    public var totalImportedSkillAssets: Int {
        perPlugin.reduce(0) { $0 + $1.importedSkillAssetCount }
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
    public var allOAuthProvidersNeedingSignIn: [String] {
        perPlugin.flatMap { $0.oauthProvidersNeedingSignIn }
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
            // and these fetches are independent.  External-source plugins
            // (`MarketplaceSource.externalRepo`/`.externalSubdir`) carry
            // their own `sourceRepo` on the manifest — we never hit
            // the marketplace repo for those file fetches.
            let fetched = await fetchArtifacts(for: selection)

            // ── Phase 2: apply fetched content sequentially on the main
            // actor.

            // 1. Skills (with optional CLAUDE.md + auxiliary root docs +
            // co-located scripts/references attached).
            for fetchedSkill in fetched.skills {
                defer { tick() }
                switch fetchedSkill.content {
                case .failure(let error):
                    summary.errors.append(
                        "skill \(fetchedSkill.entry.path): \(error.localizedDescription)"
                    )
                case .success(let rawContent):
                    do {
                        // Rewrite `${CLAUDE_PLUGIN_ROOT}/...` and relative
                        // `../../<file>` references inside SKILL.md so they
                        // point at the local `references/`/`assets/` paths
                        // we're about to attach. Returns extra root-doc
                        // attachments we discovered while resolving links.
                        let rewriteOutcome = Self.rewriteSkillBody(
                            rawContent,
                            skillDir: fetchedSkill.entry.path,
                            sourceDir: manifest.source,
                            fetchedAssets: fetchedSkill.assets,
                            fetchedRootDocs: fetched.rootDocs
                        )

                        var parsed = try Self.parseSkillWithFallback(
                            rewriteOutcome.rewritten,
                            skillPath: fetchedSkill.entry.path
                        )
                        parsed.pluginId = pluginId
                        if parsed.category == nil || parsed.category?.isEmpty == true {
                            parsed.category = manifest.name
                        }
                        if parsed.author == nil, let owner = manifest.authorName {
                            parsed.author = owner
                        }

                        let imported = await SkillManager.shared
                            .importSkillsPreservingPluginId([parsed])

                        if let savedSkill = imported.first {
                            // 1a. Attach plugin-root auxiliary docs (CLAUDE.md,
                            // CONNECTORS.md, README.md when they exist).
                            if selection.attachClaudeMd {
                                for (name, data) in fetched.rootDocs.asReferenceAttachments {
                                    try? await SkillManager.shared.addReference(
                                        to: savedSkill.id,
                                        name: name,
                                        content: data
                                    )
                                    summary.importedSkillAssetCount += 1
                                }
                            }

                            // 1b. Attach skill-local co-located assets
                            // (scripts/, requirements.txt, TROUBLESHOOTING.md,
                            // dashboard.html, …).
                            for asset in fetchedSkill.assets {
                                let basename =
                                    (asset.relativePath as NSString).lastPathComponent
                                if Self.shouldStoreAsReference(basename) {
                                    try? await SkillManager.shared.addReference(
                                        to: savedSkill.id,
                                        name: basename,
                                        content: asset.data
                                    )
                                } else {
                                    try? await SkillManager.shared.addAsset(
                                        to: savedSkill.id,
                                        name: basename,
                                        content: asset.data
                                    )
                                }
                                summary.importedSkillAssetCount += 1
                            }

                            // 1c. Attach extra references the body rewriter
                            // discovered (e.g. a `[X](../../X.md)` link).
                            for extra in rewriteOutcome.additionalReferences {
                                try? await SkillManager.shared.addReference(
                                    to: savedSkill.id,
                                    name: extra.name,
                                    content: extra.data
                                )
                                summary.importedSkillAssetCount += 1
                            }
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

            // 4. MCP providers (HTTP/SSE only — stdio is reported as
            //    skipped; OAuth servers are imported with `authType: .oauth`
            //    and surfaced as needing sign-in).
            if selection.importMCP, let mcpPath = manifest.mcpJsonPath {
                defer { tick() }
                if let content = fetched.mcpJson {
                    let parsed = MCPJSONParser.parse(content)
                    for server in parsed.servers {
                        switch server.kind {
                        case .stdio, .empty:
                            summary.skippedStdioMCPServers.append(server.name)

                        case .oauth:
                            // OAuth provider: create disabled so the user can
                            // complete the sign-in flow in MCP settings before
                            // anything tries to connect. We pre-seed the
                            // `clientId` and a loopback `redirectURI` matching
                            // the plugin's declared callback port — the MCP
                            // OAuth service uses these when the user hits
                            // "Sign in".
                            guard let url = server.url, !url.isEmpty else {
                                summary.skippedStdioMCPServers.append(server.name)
                                continue
                            }
                            let oauthConfig = MCPOAuthConfig(
                                clientId: server.oauth?.clientId,
                                redirectURI: server.oauth?.callbackPort.map {
                                    "http://127.0.0.1:\($0)/callback"
                                }
                            )
                            let provider = MCPProvider(
                                name: "\(manifest.name): \(server.name)",
                                url: url,
                                enabled: false,
                                customHeaders: server.headers ?? [:],
                                authType: .oauth,
                                oauth: oauthConfig,
                                pluginId: pluginId
                            )
                            MCPProviderManager.shared.addProvider(provider, token: nil)
                            summary.oauthProvidersNeedingSignIn.append(server.name)
                            summary.importedMCPProviderCount += 1

                        case .bearer:
                            guard let url = server.url, !url.isEmpty else {
                                summary.skippedStdioMCPServers.append(server.name)
                                continue
                            }
                            let hasRealToken = (server.token?.isEmpty == false)
                            let provider = MCPProvider(
                                name: "\(manifest.name): \(server.name)",
                                url: url,
                                enabled: false,
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

    /// One co-located file pulled from a skill directory or referenced from
    /// the skill body. `relativePath` is rooted at the skill folder (e.g.
    /// `scripts/recalc.py`, `TROUBLESHOOTING.md`) — the installer flattens
    /// it to `references/<basename>` or `assets/<basename>` depending on the
    /// extension when persisting.
    internal struct FetchedSkillAsset: Sendable {
        let relativePath: String
        let data: Data

        internal init(relativePath: String, data: Data) {
            self.relativePath = relativePath
            self.data = data
        }
    }

    /// Result of fetching one skill / agent / command markdown file. We use
    /// `Result` so a single failure doesn't poison the whole batch — each
    /// failed artifact is reported individually in the install summary.
    private struct FetchedSkill {
        let entry: ClaudeSkillEntry
        let content: Result<String, Error>
        let assets: [FetchedSkillAsset]
    }
    private struct FetchedAgent {
        let entry: ClaudeAgentEntry
        let content: Result<String, Error>
    }
    private struct FetchedCommand {
        let entry: ClaudeCommandEntry
        let content: Result<String, Error>
    }

    /// All files we picked up from the plugin's root (CLAUDE.md, CONNECTORS.md,
    /// README.md). Keyed by basename so the rewriter can resolve
    /// `[CONNECTORS.md](../../CONNECTORS.md)` style markdown links against
    /// any of them.
    internal struct FetchedRootDocs: Sendable {
        let files: [String: String]  // basename -> content

        internal init(files: [String: String]) {
            self.files = files
        }

        var claudeMd: String? { files["CLAUDE.md"] }

        var asReferenceAttachments: [(name: String, data: Data)] {
            files.compactMap { (name, body) in
                guard let data = body.data(using: .utf8) else { return nil }
                return (name: name, data: data)
            }
        }
    }

    private struct FetchedArtifacts {
        let rootDocs: FetchedRootDocs
        let skills: [FetchedSkill]
        let agents: [FetchedAgent]
        let commands: [FetchedCommand]
        let mcpJson: String?
    }

    /// Fetch every file referenced by `selection` in parallel. Preserves the
    /// declared order in `manifest` so the install summary renders in the
    /// same order regardless of which fetch finished first.
    ///
    /// Every fetch is gated through `GitHubFetchLimiter.shared` so plugins
    /// with dozens of co-located assets (e.g. `pitch-agent` × 13 skills ×
    /// ~5 supporting files) don't blow through the unauthenticated GitHub
    /// rate limit.
    private func fetchArtifacts(
        for selection: ClaudePluginSelection
    ) async -> FetchedArtifacts {
        let manifest = selection.manifest
        let repo = manifest.sourceRepo
        let limiter = GitHubFetchLimiter.shared
        let svc = github

        async let rootDocsTask: FetchedRootDocs = {
            guard selection.attachClaudeMd else { return FetchedRootDocs(files: [:]) }
            var paths = manifest.auxMarkdownPaths
            // Backwards compatibility: older callers may construct a
            // manifest with only `claudeMdPath` populated.
            if paths.isEmpty, let cm = manifest.claudeMdPath {
                paths = [cm]
            }
            guard !paths.isEmpty else { return FetchedRootDocs(files: [:]) }
            return await withTaskGroup(of: (String, String?).self) { group in
                for path in paths {
                    group.addTask {
                        let body = await limiter.runNoThrow {
                            await svc.fetchOptionalFileContent(from: repo, path: path)
                        }
                        let name = (path as NSString).lastPathComponent
                        return (name, body)
                    }
                }
                var out: [String: String] = [:]
                for await (name, body) in group {
                    if let body = body { out[name] = body }
                }
                return FetchedRootDocs(files: out)
            }
        }()

        async let mcpJsonTask: String? = {
            guard selection.importMCP, let path = manifest.mcpJsonPath else { return nil }
            return await limiter.runNoThrow {
                await svc.fetchOptionalFileContent(from: repo, path: path)
            }
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
                group.addTask {
                    let result: Result<String, Error>
                    do {
                        let content = try await limiter.run {
                            try await svc.fetchSkillContent(from: repo, skillPath: entry.path)
                        }
                        result = .success(content)
                    } catch {
                        result = .failure(error)
                    }
                    // Skill assets are best-effort — a failure here must
                    // never block the import of the SKILL.md itself.
                    var assets: [FetchedSkillAsset] = []
                    if selection.includeSkillAssets {
                        assets = await Self.fetchSkillAssets(
                            entry: entry,
                            repo: repo,
                            service: svc,
                            limiter: limiter
                        )
                    }
                    return (idx, FetchedSkill(entry: entry, content: result, assets: assets))
                }
            }
            var out: [(Int, FetchedSkill)] = []
            for await pair in group { out.append(pair) }
            return out.sorted { $0.0 < $1.0 }.map { $0.1 }
        }

        async let agents = withTaskGroup(of: (Int, FetchedAgent).self) { group -> [FetchedAgent] in
            for (idx, entry) in agentEntries.enumerated() {
                group.addTask {
                    do {
                        let content = try await limiter.run {
                            try await svc.fetchFileContent(from: repo, path: entry.path)
                        }
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
                group.addTask {
                    do {
                        let content = try await limiter.run {
                            try await svc.fetchFileContent(from: repo, path: entry.path)
                        }
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
            rootDocs: rootDocsTask,
            skills: skills,
            agents: agents,
            commands: commands,
            mcpJson: mcpJsonTask
        )
    }

    /// Walk a single skill directory and grab every supporting file we can
    /// find (top-level files like `requirements.txt` / `TROUBLESHOOTING.md`,
    /// plus one level deep into the conventional `scripts/`, `references/`,
    /// `assets/`, and `templates/` subdirectories). Skips anything larger
    /// than `maxAssetBytes` to keep imports bounded.
    nonisolated private static func fetchSkillAssets(
        entry: ClaudeSkillEntry,
        repo: GitHubRepo,
        service: GitHubSkillService,
        limiter: GitHubFetchLimiter
    ) async -> [FetchedSkillAsset] {
        let listing: [GitHubSkillAsset]
        do {
            listing = try await limiter.run {
                try await service.listSkillAssets(repo: repo, skillDir: entry.path)
            }
        } catch {
            return []
        }
        let bounded = listing.filter { $0.size <= maxAssetBytes }
        return await withTaskGroup(of: FetchedSkillAsset?.self) { group in
            for asset in bounded {
                group.addTask {
                    do {
                        let content = try await limiter.run {
                            try await service.fetchFileContent(from: repo, path: asset.path)
                        }
                        guard let data = content.data(using: .utf8) else {
                            return FetchedSkillAsset(
                                relativePath: asset.relativePath,
                                data: Data()
                            )
                        }
                        return FetchedSkillAsset(
                            relativePath: asset.relativePath,
                            data: data
                        )
                    } catch {
                        return nil
                    }
                }
            }
            var out: [FetchedSkillAsset] = []
            for await maybeAsset in group {
                if let asset = maybeAsset { out.append(asset) }
            }
            // Sort for determinism (matches manifest iteration order).
            return out.sorted { $0.relativePath < $1.relativePath }
        }
    }

    /// Upper bound on the size of a single co-located skill asset we pull
    /// down. Plugins like `financial-services` ship per-skill PowerPoint
    /// templates and similar binaries — anything bigger than ~2 MiB is
    /// almost certainly something the user wants to fetch themselves.
    nonisolated private static let maxAssetBytes: Int = 2 * 1024 * 1024

    /// Decide whether a file should land under `references/` (indexed and
    /// loaded into context by `SkillManager.loadReferenceContents`) or
    /// `assets/` (carried alongside the skill but not surfaced as part of
    /// the prompt). Text-y extensions go to references so the agent can
    /// read them; everything else goes to assets.
    nonisolated fileprivate static func shouldStoreAsReference(_ name: String) -> Bool {
        let textExtensions: Set<String> = [
            "md", "txt", "json", "yaml", "yml", "xml", "html", "css",
            "js", "ts", "swift", "py", "rb", "go", "rs", "java", "kt",
            "c", "cpp", "h", "hpp", "sql", "sh", "bash", "zsh",
            "toml", "ini", "cfg", "conf", "csv", "tsv",
        ]
        let ext = (name as NSString).pathExtension.lowercased()
        // Treat extension-less files (e.g. `Makefile`) as references.
        if ext.isEmpty { return true }
        return textExtensions.contains(ext)
    }

    // MARK: - SKILL.md parsing with free-form fallback

    /// Try to parse a SKILL.md the strict way first (YAML frontmatter with
    /// either `name:` Agent-Skills format or `id:` Osaurus format). When that
    /// fails because the file ships *no* frontmatter at all — a real
    /// production pattern in `anthropics/financial-services/plugins/vertical-plugins/*`
    /// where each skill starts with `# <Title>\n\ndescription: …\n\n## Workflow`
    /// instead of a fenced YAML block — synthesise a skill from the H1
    /// header plus any plain `description:` line we can find near the top.
    ///
    /// Anything beyond `.noFrontmatter` / `.missingRequiredField` is bubbled
    /// up so we don't paper over malformed frontmatter (those probably
    /// indicate a real authoring bug the user should know about).
    nonisolated internal static func parseSkillWithFallback(
        _ content: String,
        skillPath: String
    ) throws -> Skill {
        do {
            return try Skill.parseAnyFormat(from: content)
        } catch let error as SkillParseError {
            switch error {
            case .noFrontmatter, .missingRequiredField:
                return synthesizeSkillFromFreeformMarkdown(content, skillPath: skillPath)
            case .malformedFrontmatter:
                throw error
            }
        }
    }

    /// Build a `Skill` from a SKILL.md that has no YAML frontmatter at all.
    /// Heuristics:
    ///   - `name`: first `# H1` line; otherwise the last component of
    ///     `skillPath` (e.g. `buyer-list` → "Buyer List").
    ///   - `description`: first plain-text `description:` line below the H1
    ///     (Claude Code authors often inline it here instead of in
    ///     frontmatter). Falls back to the first non-empty paragraph.
    ///   - `instructions`: the whole document, including the H1 we read
    ///     `name` from, so the model still sees the original framing.
    nonisolated internal static func synthesizeSkillFromFreeformMarkdown(
        _ content: String,
        skillPath: String
    ) -> Skill {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = trimmed.components(separatedBy: "\n")

        // Derive a default name from the directory the file lives in.
        // `plugins/.../investment-banking/skills/buyer-list` → `buyer-list`.
        let dirName = (skillPath as NSString).lastPathComponent
        var name = humanReadableName(from: dirName)
        var firstContentLineIndex = 0

        // Pull the H1 title (single `#`, not `##`, `###`, …) as the name.
        for (idx, line) in lines.enumerated() {
            let stripped = line.trimmingCharacters(in: .whitespaces)
            if stripped.isEmpty { continue }
            if stripped.hasPrefix("# ") && !stripped.hasPrefix("## ") {
                let title = String(stripped.dropFirst(2))
                    .trimmingCharacters(in: .whitespaces)
                if !title.isEmpty { name = title }
                firstContentLineIndex = idx + 1
            }
            break
        }

        // Pull the first `description:` line that lives outside YAML
        // frontmatter (the buyer-list / cim-builder pattern). We scan a
        // bounded window so we don't accidentally pick up a `description:`
        // inside a much later code block.
        var description = ""
        let scanEnd = min(firstContentLineIndex + 10, lines.count)
        for idx in firstContentLineIndex..<scanEnd {
            let stripped = lines[idx].trimmingCharacters(in: .whitespaces)
            if stripped.isEmpty { continue }
            if stripped.lowercased().hasPrefix("description:") {
                description = String(stripped.dropFirst("description:".count))
                    .trimmingCharacters(in: .whitespaces)
                break
            }
            // Heading or markdown structure — stop searching.
            if stripped.hasPrefix("#") || stripped.hasPrefix("---") { break }
            // First plain paragraph: use it as a description fallback so
            // the picker has *something* to show even when authors didn't
            // include an explicit description line.
            if description.isEmpty { description = stripped }
        }

        return Skill(
            name: name,
            description: description,
            instructions: trimmed,
            directoryName: dirName
        )
    }

    /// `buyer-list` → "Buyer List". Strips path separators just in case.
    nonisolated private static func humanReadableName(from dirName: String) -> String {
        let cleaned = dirName.replacingOccurrences(of: "_", with: "-")
        let words = cleaned.split(separator: "-").map { word -> String in
            let s = String(word)
            return s.prefix(1).uppercased() + s.dropFirst()
        }
        let joined = words.joined(separator: " ")
        return joined.isEmpty ? dirName : joined
    }

    // MARK: - SKILL.md body rewriting

    /// Plugin authors freely use Claude Code-isms in SKILL.md that don't
    /// resolve once the skill lives in `~/.osaurus/skills/<name>/`:
    /// `${CLAUDE_PLUGIN_ROOT}/...` (runtime env var pointing at the materialised
    /// plugin tree), relative markdown links like `[X](../../X.md)` that
    /// traverse up to the plugin root, and bare references like `python
    /// recalc.py` that assume the script is on PATH. This rewriter:
    ///
    /// - Replaces `${CLAUDE_PLUGIN_ROOT}/<rel>` with `references/<basename>` or
    ///   `assets/<basename>` when `<rel>` matches a file we already fetched
    ///   (either co-located under the skill dir or attached as a root doc).
    /// - Rewrites `[text](../../<file>)` links the same way against the
    ///   fetched root docs.
    /// - Appends a short footnote listing the unbundled paths so the user
    ///   knows what wasn't materialised.
    ///
    /// Returns the rewritten body plus any extra reference files the
    /// rewriter wants attached (e.g. a root-level CONNECTORS.md it pulled
    /// in to resolve a `../../CONNECTORS.md` link).
    nonisolated internal static func rewriteSkillBody(
        _ body: String,
        skillDir: String,
        sourceDir: String,
        fetchedAssets: [FetchedSkillAsset],
        fetchedRootDocs: FetchedRootDocs
    ) -> (rewritten: String, additionalReferences: [(name: String, data: Data)]) {
        // Build a lookup of fetched assets by basename so a rewrite can
        // map "scripts/recalc.py" → "references/recalc.py".
        var assetByBasename: [String: String] = [:]   // basename → "references|assets/<name>"
        for asset in fetchedAssets {
            let basename = (asset.relativePath as NSString).lastPathComponent
            let bucket = shouldStoreAsReference(basename) ? "references" : "assets"
            assetByBasename[basename] = "\(bucket)/\(basename)"
        }

        // Strip the marketplace-relative skill prefix so a `${CLAUDE_PLUGIN_ROOT}/<plug-rel>`
        // path can be tested against the assets we did fetch.
        // We don't need the full prefix machinery — the basename lookup
        // catches the common cases (`${CLAUDE_PLUGIN_ROOT}/skills/dashboard.html`,
        // `${CLAUDE_PLUGIN_ROOT}/scripts/recalc.py`, …).

        // Pull in any matching root doc when a link refers to it by name.
        var additionalRefs: [(name: String, data: Data)] = []
        var addedNames = Set<String>()
        var unresolved = Set<String>()
        _ = skillDir  // Reserved for future per-skill-relative resolution.
        _ = sourceDir

        var output = body

        // 1. Rewrite `${CLAUDE_PLUGIN_ROOT}/<rel>` occurrences. The right
        //    boundary is any whitespace or paired-bracket terminator we'd
        //    plausibly find in markdown / code blocks.
        if let regex = try? NSRegularExpression(
            pattern: #"\$\{CLAUDE_PLUGIN_ROOT\}/([^\s\)\]\`"']+)"#,
            options: []
        ) {
            output = Self.replaceMatches(in: output, regex: regex) { rel in
                let basename = (rel as NSString).lastPathComponent
                if let local = assetByBasename[basename] {
                    return local
                }
                if let docData = fetchedRootDocs.files[basename]?.data(using: .utf8) {
                    if addedNames.insert(basename).inserted {
                        additionalRefs.append((name: basename, data: docData))
                    }
                    return "references/\(basename)"
                }
                unresolved.insert(rel)
                return "${CLAUDE_PLUGIN_ROOT}/\(rel)"
            }
        }

        // 2. Rewrite relative `../../<file>` (or `../<file>`) markdown link
        //    targets when the file matches a fetched root doc. We only touch
        //    the URL component inside `[text](URL)` to avoid mangling code
        //    or prose that happens to contain `../`.
        if let mdLink = try? NSRegularExpression(
            pattern: #"(\[[^\]]+\]\()((?:\.\./){1,4}[^\)]+)(\))"#,
            options: []
        ) {
            output = Self.replaceMatches(in: output, regex: mdLink, captureGroups: [1, 2, 3]) {
                groups in
                let lead = groups[0]
                let target = groups[1]
                let tail = groups[2]
                let basename = (target as NSString).lastPathComponent
                if let docData = fetchedRootDocs.files[basename]?.data(using: .utf8) {
                    if addedNames.insert(basename).inserted {
                        additionalRefs.append((name: basename, data: docData))
                    }
                    return "\(lead)references/\(basename)\(tail)"
                }
                if let local = assetByBasename[basename] {
                    return "\(lead)\(local)\(tail)"
                }
                unresolved.insert(target)
                return "\(lead)\(target)\(tail)"
            }
        }

        // 3. Footer summarising what we attached / couldn't bundle. Keeps the
        //    operator honest about the difference between Claude Code's
        //    runtime layout and our snapshot.
        var footerLines: [String] = []
        let attached = assetByBasename.values.sorted()
        if !attached.isEmpty {
            footerLines.append("")
            footerLines.append("---")
            footerLines.append("**Imported assets:**")
            for path in attached {
                footerLines.append("- \(path)")
            }
        }
        if !addedNames.isEmpty {
            if footerLines.isEmpty {
                footerLines.append("")
                footerLines.append("---")
            }
            footerLines.append("")
            footerLines.append("**Imported plugin-root docs:**")
            for name in addedNames.sorted() {
                footerLines.append("- references/\(name)")
            }
        }
        if !unresolved.isEmpty {
            if footerLines.isEmpty {
                footerLines.append("")
                footerLines.append("---")
            }
            footerLines.append("")
            footerLines.append(
                "_The following paths were not bundled with this import and may not resolve at run time:_"
            )
            for path in unresolved.sorted() {
                footerLines.append("- `\(path)`")
            }
        }
        if !footerLines.isEmpty {
            output.append("\n")
            output.append(footerLines.joined(separator: "\n"))
            output.append("\n")
        }

        return (output, additionalRefs)
    }

    /// Run a single-capture-group regex and replace each match using
    /// `transform(captured-group-1) -> String`. Iterates in reverse so the
    /// indices in earlier matches stay valid as we splice in replacements.
    nonisolated private static func replaceMatches(
        in input: String,
        regex: NSRegularExpression,
        transform: (String) -> String
    ) -> String {
        let ns = input as NSString
        let matches = regex.matches(
            in: input,
            options: [],
            range: NSRange(location: 0, length: ns.length)
        )
        guard !matches.isEmpty else { return input }
        var result = input
        for match in matches.reversed() {
            guard match.numberOfRanges >= 2 else { continue }
            let captured = ns.substring(with: match.range(at: 1))
            let replacement = transform(captured)
            let fullRange = match.range(at: 0)
            if let r = Range(fullRange, in: result) {
                result.replaceSubrange(r, with: replacement)
            }
        }
        return result
    }

    // MARK: - Sibling-skill references

    /// Extract every sibling skill name referenced inside an agent-style
    /// SKILL.md / agent markdown body. Anthropic plugin authors describe
    /// orchestration like:
    ///
    ///     - "Invoke the `comps-analysis` skill"
    ///     - "Use the `dcf-model` skill"
    ///     - "Run the `audit-xls` skill"
    ///     - "this agent uses: `sector-overview` · `comps-analysis`"
    ///
    /// The picker uses the returned names to auto-select sibling plugins
    /// that own those skills, so the user doesn't have to puzzle out which
    /// vertical-plugin a referenced skill lives in.
    public nonisolated static func extractSiblingSkillNames(from body: String)
        -> Set<String>
    {
        var names = Set<String>()

        // Phrases like `Invoke the \`comps-analysis\` skill`.
        let verbPhrases = [
            #"[Ii]nvoke\s+(?:the\s+)?`([^`]+)`\s+skill"#,
            #"[Uu]se\s+(?:the\s+)?`([^`]+)`\s+skill"#,
            #"[Rr]un\s+(?:the\s+)?`([^`]+)`\s+skill"#,
            #"[Cc]all\s+(?:the\s+)?`([^`]+)`\s+skill"#,
            #"[Dd]elegate\s+to\s+(?:the\s+)?`([^`]+)`\s+skill"#,
        ]
        for pattern in verbPhrases {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { continue }
            let ns = body as NSString
            let matches = regex.matches(in: body, range: NSRange(location: 0, length: ns.length))
            for match in matches where match.numberOfRanges >= 2 {
                let name = ns.substring(with: match.range(at: 1))
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { names.insert(trimmed) }
            }
        }

        // "Skills this agent uses: `a` · `b` · `c`" — pick up the backticked
        // tokens. We use this as a fallback so we don't have to enumerate
        // every connecting word ("uses", "invokes", "calls").
        let listSignals: [String] = [
            "Skills this agent uses",
            "Skills used",
            "Uses skills",
            "Dependencies",
        ]
        for signal in listSignals {
            guard let signalRange = body.range(of: signal) else { continue }
            // Capture the rest of the markdown section after the signal so
            // we pick up backticked names that sit on the line below it
            // (the common pattern is a `## Skills this agent uses\n\n` header
            // followed by a single line of pipe/dot-separated names). We
            // stop at the next markdown heading or a double-blank break.
            let after = body[signalRange.upperBound...]
            let endByHeading = after.range(of: "\n#")?.lowerBound
            let endByDoubleBlank = after.range(of: "\n\n\n")?.lowerBound
            let blockEnd: Substring.Index = {
                switch (endByHeading, endByDoubleBlank) {
                case (let h?, let d?):
                    return min(h, d)
                case (let h?, nil):
                    return h
                case (nil, let d?):
                    return d
                case (nil, nil):
                    return after.endIndex
                }
            }()
            let block = String(after[..<blockEnd])
            if let regex = try? NSRegularExpression(pattern: #"`([^`]+)`"#) {
                let ns = block as NSString
                let matches = regex.matches(
                    in: block,
                    range: NSRange(location: 0, length: ns.length)
                )
                for match in matches where match.numberOfRanges >= 2 {
                    let name = ns.substring(with: match.range(at: 1))
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    // Filter out paths and shell snippets — sibling skill
                    // names are lowercase-with-hyphens, no `/`, no spaces.
                    if !trimmed.isEmpty,
                        !trimmed.contains("/"),
                        !trimmed.contains(" "),
                        !trimmed.contains("$"),
                        !trimmed.hasPrefix(".")
                    {
                        names.insert(trimmed)
                    }
                }
            }
        }

        return names
    }

    /// Variant of `replaceMatches` for regexes with multiple capture groups.
    /// `captureGroups` enumerates the group indices passed (in order) to
    /// `transform` so callers can drop arbitrary groups.
    nonisolated private static func replaceMatches(
        in input: String,
        regex: NSRegularExpression,
        captureGroups: [Int],
        transform: ([String]) -> String
    ) -> String {
        let ns = input as NSString
        let matches = regex.matches(
            in: input,
            options: [],
            range: NSRange(location: 0, length: ns.length)
        )
        guard !matches.isEmpty else { return input }
        var result = input
        for match in matches.reversed() {
            var groups: [String] = []
            var ok = true
            for groupIdx in captureGroups {
                guard groupIdx < match.numberOfRanges else { ok = false; break }
                let range = match.range(at: groupIdx)
                guard range.location != NSNotFound else { ok = false; break }
                groups.append(ns.substring(with: range))
            }
            guard ok else { continue }
            let replacement = transform(groups)
            let fullRange = match.range(at: 0)
            if let r = Range(fullRange, in: result) {
                result.replaceSubrange(r, with: replacement)
            }
        }
        return result
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

/// Minimal `.mcp.json` parser. Supports the legacy Claude Code shape
/// (`mcpServers: { "name": { ... } }`), the equivalent `servers: { ... }`
/// shape used by some forks, and the OAuth-discovery shape used by Anthropic's
/// knowledge-work plugins (`type: "http"` + `oauth: { clientId, callbackPort }`).
/// Everything stdio-style is surfaced as a "skipped" entry; OAuth servers
/// are surfaced as needing sign-in.
enum MCPJSONParser {
    /// Classification of a single `.mcp.json` server entry.
    enum ServerKind: Sendable, Equatable {
        /// HTTP/SSE with (optional) bearer token. Default for entries that
        /// declare a `url`.
        case bearer
        /// HTTP/SSE that declares an explicit `oauth` block. The provider
        /// is created with `authType: .oauth` and left disabled until the
        /// user finishes sign-in.
        case oauth
        /// stdio entry (`command` + `args`). Can't be auto-installed —
        /// surfaced for manual configuration.
        case stdio
        /// Declares HTTP but with an empty `url`. Treated like stdio for
        /// reporting purposes — the user still has to configure it manually.
        case empty
    }

    struct Parsed: Sendable {
        struct OAuth: Sendable, Equatable {
            let clientId: String?
            let callbackPort: Int?
        }

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
            /// OAuth client metadata declared inline (knowledge-work-plugins
            /// shape). When present, `kind == .oauth` and the installer
            /// stashes these so the OAuth service can complete sign-in.
            let oauth: OAuth?
            let kind: ServerKind
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

            // OAuth metadata block (used by knowledge-work-plugins). We
            // accept either spelling `clientId` / `client_id`.
            var oauth: Parsed.OAuth? = nil
            if let oauthDict = serverDict["oauth"] as? [String: Any] {
                let clientId =
                    (oauthDict["clientId"] as? String)
                    ?? (oauthDict["client_id"] as? String)
                let callbackPort =
                    (oauthDict["callbackPort"] as? Int)
                    ?? (oauthDict["callback_port"] as? Int)
                    ?? Self.intFromNumberOrString(
                        oauthDict["callbackPort"] ?? oauthDict["callback_port"]
                    )
                oauth = Parsed.OAuth(clientId: clientId, callbackPort: callbackPort)
            }

            // Classification: explicit oauth block wins, then url presence,
            // then anything else (stdio-style `command` etc.).
            let kind: ServerKind
            if oauth != nil, let u = url, !u.isEmpty {
                kind = .oauth
            } else if let u = url, !u.isEmpty {
                kind = .bearer
            } else if url != nil {
                kind = .empty
            } else {
                kind = .stdio
            }

            result.append(
                Parsed.Server(
                    name: name,
                    url: url,
                    token: token,
                    tokenIsPlaceholder: isPlaceholder,
                    headers: headers,
                    oauth: oauth,
                    kind: kind
                )
            )
        }
        return Parsed(servers: result.sorted { $0.name < $1.name })
    }

    private static func intFromNumberOrString(_ value: Any?) -> Int? {
        if let n = value as? Int { return n }
        if let n = value as? Double { return Int(n) }
        if let s = value as? String, let n = Int(s) { return n }
        return nil
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
