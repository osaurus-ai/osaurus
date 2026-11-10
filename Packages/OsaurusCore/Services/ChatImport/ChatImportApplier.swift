//
//  ChatImportApplier.swift
//  osaurus
//
//  Installs the rows the user kept, all or nothing: the config part
//  (`mcp_servers`, `agents`, `commands`) is validated first, then skills
//  and plugins install, then `ConfigApplier` runs. If any part fails,
//  everything this apply created is removed and replaced skills are
//  restored, and each row reports what happened to it.
//

import Foundation

enum ChatImportApplier {
    struct Context: Sendable {
        var caller: ConfigChangeCaller?
        var approvalId: UUID?
        var requestText: String?
        /// Agent creation: the new agent's entry. Imported skills and MCP
        /// servers attach to it, and it is created in the same apply.
        var agentEntry: AgentEntry?

        init(
            caller: ConfigChangeCaller? = nil, approvalId: UUID? = nil, requestText: String? = nil,
            agentEntry: AgentEntry? = nil
        ) {
            self.caller = caller
            self.approvalId = approvalId
            self.requestText = requestText
            self.agentEntry = agentEntry
        }
    }

    struct Outcome: Sendable {
        var results: [ChatImportItemResult] = []
        /// `ConfigApplier` rows for the agent entry, when one was passed.
        var agentResult: ConfigApplyResult?
        /// Final names, by row id, after "keep both" renames.
        var finalNames: [String: String] = [:]

        var succeeded: Bool {
            !results.contains { $0.status == .failed || $0.status == .rolledBack }
                && agentResult?.status != .failed
        }
    }

    /// One selected row, resolved to what it installs as.
    private struct Planned {
        let item: ChatImportItem
        let kind: ChatImportItemKind
        let name: String
        let replace: Bool
    }

    @MainActor
    static func apply(
        items: [ChatImportItem],
        choices: [String: ChatImportItemChoice],
        context: Context
    ) async -> Outcome {
        var outcome = Outcome()
        var planned: [Planned] = []
        for item in items where item.kind != .manualStep {
            guard let choice = choices[item.id], choice.included, item.isActionable else {
                outcome.results.append(.init(kind: item.kind, name: item.name, status: .skipped))
                continue
            }
            let kind = item.allowsKindChoice ? choice.kind : item.kind
            let replace = (choice.clash ?? item.clashChoice) == .replace
            let name = replace ? baseName(item, kind: kind) : uniqueName(baseName(item, kind: kind), kind: kind)
            planned.append(Planned(item: item, kind: kind, name: name, replace: replace))
            outcome.finalNames[item.id] = name
        }

        let skillNames = planned.filter { $0.kind == .skill }.map(\.name)
        var document = OsaurusConfigDocument()
        var mcpNames: [String] = []
        for plan in planned {
            switch (plan.item.payload, plan.kind) {
            case (.instructions(let spec), .agent):
                document.agents = (document.agents ?? []) + [agentEntry(spec, name: plan.name)]
            case (.mcpServer(let spec), _):
                var entry = spec.entry
                entry.name = plan.name
                document.mcpServers = (document.mcpServers ?? []) + [entry]
                mcpNames.append(plan.name)
            case (.command(let command), _):
                var entry = command
                entry.name = plan.name
                document.commands = (document.commands ?? []) + [entry]
            default:
                break
            }
        }
        if var entry = context.agentEntry {
            if !skillNames.isEmpty {
                var names: [String] = []
                if case .value(let existing) = entry.skills { names = existing }
                entry.skills = .value(names + skillNames)
            }
            if !mcpNames.isEmpty {
                var groups = entry.mcpServers ?? AgentToolGroupsEntry()
                groups.enabled = (groups.enabled ?? []) + mcpNames
                entry.mcpServers = groups
            }
            document.agents = [entry] + (document.agents ?? [])
        }

        let hasConfig = document.agents != nil || document.mcpServers != nil || document.commands != nil
        if hasConfig {
            do {
                _ = try ConfigPlanner.plan(document: document, prune: false)
            } catch let issues as ConfigPlanIssues {
                let message = issues.issues.prefix(3).joined(separator: " ")
                for plan in planned {
                    outcome.results.append(.init(kind: plan.kind, name: plan.name, status: .failed, message: message))
                }
                if context.agentEntry != nil {
                    outcome.agentResult = ConfigApplyResult(
                        section: "agents", target: context.agentEntry?.name ?? "", status: .failed, message: message)
                }
                return outcome
            } catch {
                for plan in planned {
                    outcome.results.append(
                        .init(kind: plan.kind, name: plan.name, status: .failed, message: error.localizedDescription))
                }
                return outcome
            }
        }

        var undo = Undo()
        var rows: [String: ChatImportItemResult] = [:]

        for plan in planned where plan.kind == .skill {
            guard case .instructions(let spec) = plan.item.payload else { continue }
            do {
                let existing = plan.replace ? replaceableSkill(named: plan.name) : nil
                if let existing { undo.replacedSkills.append(try backup(existing)) }
                let skill = try await installSkill(spec, name: plan.name, replacing: existing)
                if existing == nil { undo.createdSkillDirectories.append(SkillStore.skillDirectory(for: skill)) }
                rows[plan.item.id] = .init(kind: .skill, name: plan.name, status: existing == nil ? .installed : .updated)
            } catch {
                rows[plan.item.id] = .init(
                    kind: .skill, name: plan.name, status: .failed, message: error.localizedDescription)
            }
        }

        for plan in planned where plan.kind == .plugin {
            guard case .plugin(let repo) = plan.item.payload else { continue }
            rows[plan.item.id] = await installPlugin(repo, name: plan.name, undo: &undo)
        }

        let preexisting = Snapshot.capture()
        var configResults: [ConfigApplyResult] = []
        if hasConfig, !rows.values.contains(where: { $0.status == .failed }) {
            configResults = await ConfigApplier.apply(
                document: document, prune: false, options: .bundleImport, caller: context.caller,
                approvalId: context.approvalId, requestText: context.requestText)
        }
        for plan in planned where [.agent, .mcpServer, .command].contains(plan.kind) {
            let section = plan.kind == .agent ? "agents" : plan.kind == .mcpServer ? "mcp_servers" : "commands"
            let match = configResults.first { $0.section == section && $0.target == plan.name }
            rows[plan.item.id] = row(for: plan, result: match, existed: preexisting.contains(plan.kind, plan.name))
        }
        if let entry = context.agentEntry {
            outcome.agentResult = configResults.first { $0.section == "agents" && $0.target == entry.name }
                ?? (hasConfig && configResults.isEmpty
                    ? ConfigApplyResult(
                        section: "agents", target: entry.name, status: .failed,
                        message: L("Nothing was created because another item failed to install."))
                    : nil)
        }

        let failed = rows.values.contains { $0.status == .failed } || outcome.agentResult?.status == .failed
        if failed {
            await rollBack(&undo, planned: planned, rows: &rows, preexisting: preexisting, agentEntry: context.agentEntry)
        } else {
            for plan in planned {
                guard let row = rows[plan.item.id], [.installed, .updated, .needsSetup].contains(row.status) else {
                    continue
                }
                ChatImportProvenanceStore.shared.record(
                    kind: plan.kind, name: plan.name, source: plan.item.origin, hash: plan.item.contentHash)
            }
        }
        for plan in planned {
            if let row = rows[plan.item.id] { outcome.results.append(row) }
        }
        return outcome
    }

    // MARK: - Rows

    private static func row(for plan: Planned, result: ConfigApplyResult?, existed: Bool) -> ChatImportItemResult {
        guard let result else {
            return .init(
                kind: plan.kind, name: plan.name, status: .failed,
                message: L("Not installed because another item failed."))
        }
        switch result.status {
        case .done, .started:
            if !plan.item.needsSetup.isEmpty {
                return .init(
                    kind: plan.kind, name: plan.name, status: .needsSetup,
                    message: L("Needs setup: \(plan.item.needsSetup.joined(separator: ", "))"))
            }
            return .init(kind: plan.kind, name: plan.name, status: existed ? .updated : .installed)
        case .needsUserAction:
            let pending = plan.item.needsSetup.isEmpty ? (result.message ?? "") : plan.item.needsSetup.joined(separator: ", ")
            return .init(kind: plan.kind, name: plan.name, status: .needsSetup, message: L("Needs setup: \(pending)"))
        case .failed, .cancelled:
            return .init(kind: plan.kind, name: plan.name, status: .failed, message: result.message)
        }
    }

    // MARK: - Names

    private static func baseName(_ item: ChatImportItem, kind: ChatImportItemKind) -> String {
        switch item.payload {
        case .command(let entry): return entry.name
        case .mcpServer(let spec): return spec.entry.name
        case .instructions(let spec): return spec.name
        case .plugin, .manualStep: return item.name
        }
    }

    @MainActor
    static func nameInUse(_ name: String, kind: ChatImportItemKind) -> Bool {
        switch kind {
        case .skill: return SkillManager.shared.skill(named: name) != nil
        case .agent: return AgentManager.shared.agents.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        case .mcpServer:
            return MCPProviderManager.shared.configuration.providers.contains {
                $0.name.caseInsensitiveCompare(name) == .orderedSame
            }
        case .command:
            return SlashCommandRegistry.shared.customCommands.contains {
                $0.name.caseInsensitiveCompare(name) == .orderedSame
            }
        case .plugin, .manualStep: return false
        }
    }

    /// "Keep both": the first free "Name 2", "Name 3", … (commands use
    /// "name-2" so they stay slash-friendly).
    @MainActor
    static func uniqueName(_ base: String, kind: ChatImportItemKind) -> String {
        guard nameInUse(base, kind: kind) else { return base }
        let separator = kind == .command ? "-" : " "
        for n in 2...99 {
            let candidate = "\(base)\(separator)\(n)"
            if !nameInUse(candidate, kind: kind) { return candidate }
        }
        return "\(base)\(separator)\(UUID().uuidString.prefix(4).lowercased())"
    }

    // MARK: - Agents

    static func agentEntry(_ spec: ChatImportInstructionsSpec, name: String) -> AgentEntry {
        var entry = AgentEntry(name: name)
        if !spec.description.isEmpty { entry.description = spec.description }
        entry.systemPrompt = spec.instructions
        if let model = spec.model { entry.model = .value(model) }
        if !spec.capabilities.isEmpty {
            var capabilities = AgentCapabilitiesEntry()
            ChatImportCapabilities.apply(spec.capabilities, to: &capabilities)
            entry.capabilities = capabilities
        }
        if spec.deniesShell || spec.deniesNetwork {
            var sandbox = AgentSandboxEntry()
            if spec.deniesShell { sandbox.enabled = false }
            if spec.deniesNetwork { sandbox.networkEnabled = false }
            entry.sandbox = sandbox
        }
        return entry
    }

    // MARK: - Skills

    @MainActor
    private static func replaceableSkill(named name: String) -> Skill? {
        SkillManager.shared.skills(named: name).first { !$0.isBuiltIn && !$0.isFromPlugin }
    }

    /// Writes a fresh `SKILL.md` with the final name next to copies of the
    /// package's `scripts/`, `references/`, and `assets/`, then installs it.
    @MainActor
    private static func installSkill(
        _ spec: ChatImportInstructionsSpec, name: String, replacing existing: Skill?
    ) async throws -> Skill {
        let fm = FileManager.default
        let stage = fm.temporaryDirectory.appendingPathComponent("chat-import-skill-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: stage) }
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        if let package = spec.packageDirectory {
            for sub in SkillManager.packageSubdirectories {
                let source = package.appendingPathComponent(sub, isDirectory: true)
                var isDirectory: ObjCBool = false
                if fm.fileExists(atPath: source.path, isDirectory: &isDirectory), isDirectory.boolValue {
                    try fm.copyItem(at: source, to: stage.appendingPathComponent(sub, isDirectory: true))
                }
            }
        }
        let skill = Skill(name: name, description: spec.description, instructions: spec.instructions)
        try skill.toAgentSkillsFormat().write(to: stage.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        return try await SkillManager.shared.installSkill(fromDirectory: stage, replacing: existing)
    }

    private struct SkillBackup {
        let skill: Skill
        let directory: URL
        let copy: URL
    }

    @MainActor
    private static func backup(_ skill: Skill) throws -> SkillBackup {
        let directory = SkillStore.skillDirectory(for: skill)
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent(
            "chat-import-backup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.copyItem(at: directory, to: copy)
        return SkillBackup(skill: skill, directory: directory, copy: copy)
    }

    // MARK: - Plugins

    @MainActor
    private static func installPlugin(_ repo: ChatImportPluginRepo, name: String, undo: inout Undo) async
        -> ChatImportItemResult
    {
        do {
            let fetched = try await GitHubSkillService.shared.fetchPlugins(from: repo.url)
            guard !fetched.plugins.isEmpty else {
                return .init(kind: .plugin, name: name, status: .failed, message: L("The marketplace lists no plugins."))
            }
            let selections = fetched.plugins.map { ClaudePluginSelection(manifest: $0) }
            let report = await ClaudePluginInstaller.shared.install(selections: selections, from: fetched.repo)
            undo.pluginIds += report.perPlugin.map(\.pluginId)
            guard report.hasAnyImports else {
                let reason = report.allErrors.first ?? L("Nothing in the plugin could be installed here.")
                return .init(kind: .plugin, name: name, status: .failed, message: reason)
            }
            let counts = [
                (report.totalImportedSkills, L("skills")), (report.totalImportedAgents, L("agents")),
                (report.totalImportedCommands, L("commands")), (report.totalImportedMCPProviders, L("MCP servers")),
            ].filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }.joined(separator: ", ")
            if report.requiresAttention {
                return .init(
                    kind: .plugin, name: name, status: .needsSetup,
                    message: L("Installed \(counts). Some parts need setup in Settings."))
            }
            return .init(kind: .plugin, name: name, status: .installed, message: L("Installed \(counts)."))
        } catch {
            return .init(kind: .plugin, name: name, status: .failed, message: error.localizedDescription)
        }
    }

    // MARK: - Rollback

    private struct Undo {
        /// By folder: the id `installSkill` returns isn't the one the
        /// reloaded skill gets, so an id can't find it again.
        var createdSkillDirectories: [URL] = []
        var replacedSkills: [SkillBackup] = []
        var pluginIds: [String] = []
    }

    /// Names that existed before this apply, so rollback only removes what
    /// the apply created.
    @MainActor
    private struct Snapshot {
        var agents: Set<String>
        var mcpServers: Set<String>
        var commands: Set<String>

        static func capture() -> Snapshot {
            Snapshot(
                agents: Set(AgentManager.shared.agents.map { $0.name.lowercased() }),
                mcpServers: Set(MCPProviderManager.shared.configuration.providers.map { $0.name.lowercased() }),
                commands: Set(SlashCommandRegistry.shared.customCommands.map { $0.name.lowercased() }))
        }

        func contains(_ kind: ChatImportItemKind, _ name: String) -> Bool {
            switch kind {
            case .agent: return agents.contains(name.lowercased())
            case .mcpServer: return mcpServers.contains(name.lowercased())
            case .command: return commands.contains(name.lowercased())
            default: return false
            }
        }
    }

    @MainActor
    private static func rollBack(
        _ undo: inout Undo, planned: [Planned], rows: inout [String: ChatImportItemResult], preexisting: Snapshot,
        agentEntry: AgentEntry?
    ) async {
        for directory in undo.createdSkillDirectories { try? FileManager.default.removeItem(at: directory) }
        for backup in undo.replacedSkills {
            try? FileManager.default.removeItem(at: backup.directory)
            try? FileManager.default.moveItem(at: backup.copy, to: backup.directory)
        }
        if !undo.replacedSkills.isEmpty || !undo.createdSkillDirectories.isEmpty { await SkillManager.shared.refresh() }
        for pluginId in undo.pluginIds { _ = await ClaudePluginInstaller.shared.uninstall(pluginId: pluginId) }

        var createdAgents = planned.filter { $0.kind == .agent }.map(\.name)
        if let agentEntry { createdAgents.append(agentEntry.name) }
        for name in createdAgents where !preexisting.contains(.agent, name) {
            if let agent = AgentManager.shared.agents.first(where: { $0.name == name && !$0.isBuiltIn }) {
                _ = await AgentManager.shared.delete(id: agent.id)
            }
        }
        for plan in planned where plan.kind == .mcpServer && !preexisting.contains(.mcpServer, plan.name) {
            if let provider = MCPProviderManager.shared.configuration.providers.first(where: { $0.name == plan.name }) {
                MCPProviderManager.shared.removeProvider(id: provider.id)
            }
        }
        for plan in planned where plan.kind == .command && !preexisting.contains(.command, plan.name) {
            if let command = SlashCommandRegistry.shared.customCommands.first(where: { $0.name == plan.name }) {
                _ = SlashCommandRegistry.shared.delete(id: command.id)
            }
        }
        for plan in planned {
            guard let row = rows[plan.item.id], row.status != .failed else { continue }
            let replaced = plan.replace && row.status == .updated && plan.kind != .skill
            rows[plan.item.id] = .init(
                kind: plan.kind, name: plan.name, status: .rolledBack,
                message: replaced
                    ? L("Undone because another item failed; the earlier version was already replaced.")
                    : L("Undone because another item failed."))
        }
    }
}
