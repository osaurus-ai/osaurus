//
//  Template+Agent.swift
//  osaurus
//
//  Agent-kind helpers on `Template`: building one from a live agent,
//  leaving sections out, resolving the pinned model and knowledge names on
//  this Mac, and turning the payload into a declarative document for
//  `ConfigPlanner` / `ConfigApplier`.
//

import Foundation

/// Agent templates are `Template`s whose payload is an agent entry.
public typealias AgentTemplate = Template

/// One chat quick action carried by a template. Ids are left behind so
/// every agent built from the template gets fresh ones.
public struct TemplateAction: Codable, Equatable, Sendable {
    public var icon: String?
    public var text: String
    public var prompt: String

    public init(icon: String? = nil, text: String, prompt: String) {
        self.icon = icon
        self.text = text
        self.prompt = prompt
    }

    init(_ action: AgentQuickAction) {
        self.init(icon: action.icon, text: action.text, prompt: action.prompt)
    }

    var quickAction: AgentQuickAction {
        AgentQuickAction(icon: icon ?? "sparkles", text: text, prompt: prompt)
    }
}

extension Template {

    /// Convenience for agent templates.
    public init(
        name: String,
        agent: AgentEntry,
        summary: String? = nil,
        author: String? = nil,
        createdAt: Date = Date(),
        availableToOrchestrator: Bool = true,
        requirements: TemplateRequirements = TemplateRequirements(),
        actions: [TemplateAction]? = nil
    ) {
        self.init(
            name: name, summary: summary,
            author: author.map { TemplateAuthor(name: $0) },
            createdAt: createdAt, availableToOrchestrator: availableToOrchestrator,
            requirements: requirements,
            payload: .agent(AgentTemplatePayload(agent: agent, actions: actions)))
    }

    /// The name to offer on import. When the envelope name collides and a
    /// hand-edited `agent.name` does not, prefer the agent name.
    public func suggestedImportName(takenSlugs: Set<String>) -> String {
        var base = name
        if case .agent = payload {
            let agentName = agent.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !agentName.isEmpty, agentName != name,
                takenSlugs.contains(Self.slug(for: name)),
                !takenSlugs.contains(Self.slug(for: agentName))
            {
                base = agentName
            }
        }
        return Self.availableName(for: base, takenSlugs: takenSlugs)
    }

    /// The template as a one-agent declarative document. `overrides`
    /// (a new name or prompt from the orchestrator) are merged on top.
    public func document(overrides: AgentEntry? = nil) -> OsaurusConfigDocument {
        var entry = agent
        if let overrides {
            entry.name = overrides.name.isEmpty ? entry.name : overrides.name
            if let v = overrides.description { entry.description = v }
            if let v = overrides.systemPrompt { entry.systemPrompt = v }
            if overrides.model.isSpecified { entry.model = overrides.model }
            if overrides.temperature.isSpecified { entry.temperature = overrides.temperature }
            if overrides.maxTokens.isSpecified { entry.maxTokens = overrides.maxTokens }
            if overrides.workingFolder.isSpecified { entry.workingFolder = overrides.workingFolder }
            if let v = overrides.capabilities { entry.capabilities = merge(entry.capabilities, v) }
            if let v = overrides.tools { entry.tools = v }
            if let v = overrides.mcpServers { entry.mcpServers = v }
            if let v = overrides.plugins { entry.plugins = v }
            if let v = overrides.sandbox { entry.sandbox = v }
            if let v = overrides.subagents { entry.subagents = v }
        }
        var doc = OsaurusConfigDocument()
        doc.version = 1
        doc.agents = [entry]
        return doc
    }

    private func merge(_ base: AgentCapabilitiesEntry?, _ over: AgentCapabilitiesEntry) -> AgentCapabilitiesEntry {
        var out = base ?? AgentCapabilitiesEntry()
        if let v = over.toolsEnabled { out.toolsEnabled = v }
        if let v = over.memoryEnabled { out.memoryEnabled = v }
        if let v = over.searchMemoryEnabled { out.searchMemoryEnabled = v }
        if let v = over.webSearchEnabled { out.webSearchEnabled = v }
        if let v = over.knowledgeEnabled { out.knowledgeEnabled = v }
        if let v = over.knowledgeCollectionIds { out.knowledgeCollectionIds = v }
        if let v = over.dbEnabled { out.dbEnabled = v }
        if let v = over.selfSchedulingEnabled { out.selfSchedulingEnabled = v }
        if let v = over.computerUseEnabled { out.computerUseEnabled = v }
        if let v = over.browserUseEnabled { out.browserUseEnabled = v }
        if let v = over.speakEnabled { out.speakEnabled = v }
        if let v = over.renderChartEnabled { out.renderChartEnabled = v }
        if let v = over.relayEnabled { out.relayEnabled = v }
        return out
    }

    // MARK: - Sections

    /// Optional parts of an agent template a user can leave out when saving.
    public enum Section: String, CaseIterable, Identifiable, Sendable {
        case systemPrompt = "system_prompt"
        case description
        case model
        case tools
        case sandbox
        case subagents
        case workingFolder = "working_folder"
        case knowledge
        case pluginInstructions = "plugin_instructions"
        case actions

        public var id: String { rawValue }
    }

    /// A copy without the given sections; their requirements go too.
    public func excluding(_ sections: Set<Section>) -> Template {
        guard !sections.isEmpty, case .agent(var p) = payload else { return self }
        var copy = self
        var entry = p.agent
        var reqs = copy.requirements
        if sections.contains(.systemPrompt) { entry.systemPrompt = nil }
        if sections.contains(.description) { entry.description = nil }
        if sections.contains(.model) { entry.model = .absent }
        if sections.contains(.tools) {
            entry.tools = nil
            entry.mcpServers = nil
            entry.plugins = nil
        }
        if sections.contains(.sandbox) { entry.sandbox = nil }
        if sections.contains(.subagents) { entry.subagents = nil }
        if sections.contains(.workingFolder) {
            entry.workingFolder = .absent
            reqs.workingFolder = nil
        }
        if sections.contains(.knowledge) {
            entry.capabilities?.knowledgeEnabled = nil
            entry.capabilities?.knowledgeCollectionIds = nil
            reqs.knowledge = []
        }
        if sections.contains(.pluginInstructions) { entry.pluginInstructions = nil }
        if sections.contains(.actions) { p.actions = nil }
        p.agent = entry
        copy.payload = .agent(p)
        copy.requirements = reqs
        copy.requirements = copy.derivedRequirements()
        return copy.sealed()
    }

    /// MCP servers and plugins the template turns on, by name.
    public var toolGroups: [PortableToolGroup] {
        guard case .agent = payload else {
            return requirements.mcpServers.map { .mcpServer($0) } + requirements.plugins.map { .plugin($0) }
        }
        return (agent.mcpServers?.enabled ?? []).map { .mcpServer($0) }
            + (agent.plugins?.enabled ?? []).map { .plugin($0) }
    }

    public var quickActions: [AgentQuickAction]? {
        actions?.map(\.quickAction)
    }

    public func requirements(of kind: TemplateRequirement.Kind) -> [TemplateRequirement] {
        requires.filter { $0.kind == kind }
    }

    public var knowledgeCollectionNames: [String] { requirements.knowledge }

    public var modelPolicy: ModelStrictness {
        requirements.models.first { $0.slot == ModelRequirement.agentSlot }?.strictness ?? .preferred
    }
}

// MARK: - Building from a live agent

extension Template {

    /// Snapshot a live agent into a template. Machine-local details become
    /// requirements instead of travelling as ids.
    @MainActor
    public static func make(
        from agent: Agent,
        name: String? = nil,
        summary: String? = nil,
        author: String? = nil,
        availableToOrchestrator: Bool = true,
        id: UUID? = nil
    ) -> Template {
        var entry = ConfigExporter.exportAgent(agent)
        entry = droppingUnregisteredTools(entry, registered: Set(ToolRegistry.shared.listTools().map(\.name)))
        var reqs = TemplateRequirements()

        let grantedIds = agent.settings.knowledgeCollectionIds
        if !grantedIds.isEmpty {
            let collections = KnowledgeCollectionStore.loadAll()
            for gid in grantedIds {
                if let collection = collections.first(where: { $0.id == gid }) {
                    reqs.knowledge.append(collection.name)
                    if !collection.summary.isEmpty {
                        reqs.notes["knowledge_collection:\(collection.name.lowercased())"] = collection.summary
                    }
                }
            }
        }
        entry.capabilities?.knowledgeCollectionIds = nil
        // Relay exposure is a per-Mac decision, never part of a template.
        entry.capabilities?.relayEnabled = nil

        if let path = agent.workingFolderPath, !path.isEmpty {
            reqs.workingFolder = PathHint(path: abbreviateHome(path), label: L("Working Folder"))
            entry.workingFolder = .value(abbreviateHome(path))
        }
        if agent.settings.appleScriptEnabled {
            reqs.permissions.append(SystemPermission.automation.rawValue)
        }

        let displayName = (name?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
            $0.isEmpty ? nil : $0
        } ?? agent.name
        var template = Template(
            id: id ?? agent.sourceTemplateID ?? UUID(),
            name: displayName,
            summary: summary ?? (agent.description.isEmpty ? nil : agent.description),
            author: author.map { TemplateAuthor(name: $0) },
            availableToOrchestrator: availableToOrchestrator,
            requirements: reqs,
            payload: .agent(
                AgentTemplatePayload(
                    agent: entry, actions: agent.chatQuickActions?.map(TemplateAction.init))))
        template = template.renamed(to: displayName)
        return template.sealed()
    }

    /// `tools.enabled` keeps only tools registered on this Mac. Stale MCP
    /// tool names carry per-connection ids; live ones travel as
    /// `mcp_servers` by server name.
    static func droppingUnregisteredTools(_ entry: AgentEntry, registered: Set<String>) -> AgentEntry {
        guard let enabled = entry.tools?.enabled else { return entry }
        var copy = entry
        copy.tools?.enabled = enabled.filter { registered.contains($0) }
        return copy
    }

    static func abbreviateHome(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    // MARK: - Resolving on this machine

    public enum ModelResolution: Equatable, Sendable {
        /// No model pinned, or the exact model (canonical id) is available.
        case available(String?)
        /// `preferred` and missing: use the user's default and say so.
        case fallbackToDefault(requested: String)
        /// `always` and missing: setup waits for the model or a substitute.
        case blocked(requested: String)

        public var requestedModel: String? {
            switch self {
            case .available: return nil
            case .fallbackToDefault(let m), .blocked(let m): return m
            }
        }
    }

    @MainActor
    public func modelResolution() -> ModelResolution {
        modelResolution(catalog: ConfigModelReference.liveCatalog())
    }

    func modelResolution(catalog: ConfigModelReference.Catalog) -> ModelResolution {
        guard let requested = agent.model.valueOrNil?.trimmingCharacters(in: .whitespacesAndNewlines),
            !requested.isEmpty
        else { return .available(nil) }
        switch ConfigModelReference.resolve(requested, catalog: catalog) {
        case .resolved(let canonical):
            return .available(canonical)
        case .invalid:
            return modelPolicy == .always
                ? .blocked(requested: requested)
                : .fallbackToDefault(requested: requested)
        }
    }

    /// The agent entry mapped onto this Mac: knowledge names become local
    /// ids, a missing model becomes `null` (the user's default).
    @MainActor
    public func resolvedEntry(overrides: AgentEntry? = nil) -> AgentEntry {
        var entry = document(overrides: overrides).agents?.first ?? agent
        if overrides?.model.isSpecified != true {
            switch modelResolution() {
            case .available(let canonical):
                entry.model = canonical.map { .value($0) } ?? .null
            case .fallbackToDefault, .blocked:
                entry.model = .null
            }
        }
        let wanted = knowledgeCollectionNames
        if !wanted.isEmpty {
            let collections = KnowledgeCollectionStore.loadAll()
            let ids = wanted.compactMap { name in
                collections.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.id.uuidString
            }
            if !ids.isEmpty {
                var caps = entry.capabilities ?? AgentCapabilitiesEntry()
                caps.knowledgeCollectionIds = ids
                if caps.knowledgeEnabled == nil { caps.knowledgeEnabled = true }
                entry.capabilities = caps
            }
        }
        return entry
    }
}
