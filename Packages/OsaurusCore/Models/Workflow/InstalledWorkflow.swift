//
//  InstalledWorkflow.swift
//  osaurus
//
//  A workflow template installed on this Mac, with local bindings. One
//  installed workflow per template per Mac: every agent that enables it
//  shares it and its saved answers.
//
//  The pinned template version is snapshotted into the record, so deleting
//  the template from the library never breaks a workflow agents rely on.
//  Updating re-pins to a newer version through the setup wizard.
//

import Foundation

public struct InstallBindings: Codable, Equatable, Sendable {
    /// Model slot -> model id on this Mac.
    public var models: [String: String]
    /// Secret key -> Keychain account in `WorkflowSecretsKeychain`.
    public var secrets: [String: String]
    /// MCP server name in the template -> server name on this Mac.
    public var mcpServers: [String: String]
    /// Plugin id in the template -> plugin id on this Mac.
    public var plugins: [String: String]
    /// Declared folder key -> absolute path of the folder chosen on this Mac.
    public var folders: [String: String]
    /// Folders the person allowed for every run from a run's "Allow this
    /// workflow to save in…" card (or the older "use…" card), as absolute
    /// paths. Runs may read and save there.
    public var folderGrants: [String]
    /// Folders the person allowed for every run from an "Allow this
    /// workflow to read…" card. Runs may only read there.
    public var folderReadGrants: [String]
    /// Folders where the person allowed every run to replace files that
    /// already exist ("Replace files in…" → Always allow).
    public var replaceGrants: [String]
    /// `AgentRequirement.id` -> the agent on this Mac's side that answers
    /// it: a local agent's id, a shared agent's `WorkspaceAgentRef.key`, or
    /// `agentByName` when the person chose the agent the template names.
    /// An imported workflow's unbound requirement blocks setup.
    public var agents: [String: String]

    /// The binding for "As the workflow names it".
    public static let agentByName = "@name"

    public init(
        models: [String: String] = [:], secrets: [String: String] = [:],
        mcpServers: [String: String] = [:], plugins: [String: String] = [:],
        folders: [String: String] = [:], folderGrants: [String] = [], folderReadGrants: [String] = [],
        replaceGrants: [String] = [], agents: [String: String] = [:]
    ) {
        self.agents = agents
        self.models = models
        self.secrets = secrets
        self.mcpServers = mcpServers
        self.plugins = plugins
        self.folders = folders
        self.folderGrants = folderGrants
        self.folderReadGrants = folderReadGrants
        self.replaceGrants = replaceGrants
    }

    /// Every folder the bindings let a run use: the bound folders and the
    /// standing grants.
    public var grantedFolderURLs: [URL] {
        (folders.values.sorted() + folderGrants + folderReadGrants).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    enum CodingKeys: String, CodingKey {
        case models, secrets, plugins, folders, agents
        case mcpServers = "mcp_servers"
        case folderGrants = "folder_grants"
        case folderReadGrants = "folder_read_grants"
        case replaceGrants = "replace_grants"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        models = try c.decodeIfPresent([String: String].self, forKey: .models) ?? [:]
        secrets = try c.decodeIfPresent([String: String].self, forKey: .secrets) ?? [:]
        mcpServers = try c.decodeIfPresent([String: String].self, forKey: .mcpServers) ?? [:]
        plugins = try c.decodeIfPresent([String: String].self, forKey: .plugins) ?? [:]
        folders = try c.decodeIfPresent([String: String].self, forKey: .folders) ?? [:]
        folderGrants = try c.decodeIfPresent([String].self, forKey: .folderGrants) ?? []
        folderReadGrants = try c.decodeIfPresent([String].self, forKey: .folderReadGrants) ?? []
        replaceGrants = try c.decodeIfPresent([String].self, forKey: .replaceGrants) ?? []
        agents = try c.decodeIfPresent([String: String].self, forKey: .agents) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(models, forKey: .models)
        try c.encode(secrets, forKey: .secrets)
        try c.encode(mcpServers, forKey: .mcpServers)
        try c.encode(plugins, forKey: .plugins)
        if !folders.isEmpty { try c.encode(folders, forKey: .folders) }
        if !folderGrants.isEmpty { try c.encode(folderGrants, forKey: .folderGrants) }
        if !folderReadGrants.isEmpty { try c.encode(folderReadGrants, forKey: .folderReadGrants) }
        if !replaceGrants.isEmpty { try c.encode(replaceGrants, forKey: .replaceGrants) }
        if !agents.isEmpty { try c.encode(agents, forKey: .agents) }
    }
}

public struct InstalledWorkflow: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let templateID: UUID
    /// Pinned until the user updates.
    public var templateVersion: Int
    public var name: String
    public var bindings: InstallBindings
    public var needsSetup: Bool
    public var orchestratorVisible: Bool
    /// Opt-in: a workspace teammate (or guest, or their agent) chatting with
    /// one of this Mac's shared agents may start this workflow through the
    /// agent's `workflow_<slug>` tool. The run uses this Mac's keys,
    /// connections and folders, so it is off until the owner turns it on,
    /// and every call still goes through the agent's teammate approval.
    public var teammatesCanRun: Bool
    /// Opt-in: this workflow's agent steps hand their task over without an
    /// approval card, including in runs nobody watches. Only this
    /// workflow's steps; never a teammate-started run, and never over a
    /// Deny. Cleared when an update adds an agent to ask.
    public var agentStepsAllowed: Bool
    /// Opt-in: after the same failure repeats, the Architect drafts a fix
    /// in a background chat and a notification offers it for review
    /// (`WorkflowSelfHealMonitor`).
    public var selfHeal: Bool
    /// The failure signature self-heal last drafted a fix for, so one
    /// recurring failure gets one draft until something changes.
    public var selfHealedSignature: String?
    /// The person's own labels for finding this workflow in the library
    /// ("finance", "weekly"). Lower-cased, unique, in the order given; not
    /// part of the template and never exported.
    public var tags: [String]
    /// The template name the person chose not to take on ("Keep" on the
    /// name notice), so the notice stays quiet until the template is
    /// renamed again.
    public var keptName: String?
    /// Names this workflow had before a rename, newest last, so a step or
    /// a model that still uses one finds it (`workflow(named:)`).
    public var formerNames: [String]
    /// Where the template came from when it was installed from the store
    /// registry: the listing and, for a workspace listing, the workspace.
    /// Nil for files, starters and the Architect's own.
    public var source: Source?
    /// Snapshot of the pinned template version.
    public var template: Template
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(), template: Template, bindings: InstallBindings,
        name: String? = nil, needsSetup: Bool = false, orchestratorVisible: Bool = true, selfHeal: Bool = false,
        tags: [String] = []
    ) {
        self.id = id
        self.templateID = template.id
        self.templateVersion = template.version
        self.name = name ?? template.name
        self.bindings = bindings
        self.needsSetup = needsSetup
        self.orchestratorVisible = orchestratorVisible
        self.teammatesCanRun = false
        self.agentStepsAllowed = false
        self.selfHeal = selfHeal
        self.tags = Self.normalizedTags(tags)
        self.formerNames = []
        self.template = template
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    public var definition: WorkflowDefinition { template.workflow ?? WorkflowDefinition() }

    public struct Source: Codable, Equatable, Sendable {
        /// The registry listing's id.
        public var registryID: String
        /// The workspace whose catalog listed it; nil for a public or
        /// unlisted listing.
        public var workspaceID: String?

        public init(registryID: String, workspaceID: String? = nil) {
            self.registryID = registryID
            self.workspaceID = workspaceID
        }

        enum CodingKeys: String, CodingKey {
            case registryID = "registry_id"
            case workspaceID = "workspace_id"
        }
    }

    public static let maximumFormerNames = 8
    public static let maximumTags = 12
    public static let maximumTagLength = 32

    /// Trims, lower-cases, drops empties and duplicates, and caps the
    /// count and length. "Finance, finance , Weekly" → ["finance", "weekly"].
    public static func normalizedTags(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in tags {
            let tag = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().prefix(maximumTagLength))
            guard !tag.isEmpty, seen.insert(tag).inserted else { continue }
            out.append(tag)
            if out.count == maximumTags { break }
        }
        return out
    }

    /// Splits "finance, weekly" (or newlines/semicolons) into tags.
    public static func parseTags(_ text: String) -> [String] {
        normalizedTags(text.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isNewline }).map(String.init))
    }

    /// What a library search looks through: the name, then the tags.
    public var searchText: String {
        tags.isEmpty ? name : name + " " + tags.joined(separator: " ")
    }

    /// The workflows that match a free-text `query` (name or tag) and, when
    /// given, carry `tag`. An empty query with no tag returns everything.
    public static func filter(_ workflows: [InstalledWorkflow], query: String, tag: String?) -> [InstalledWorkflow] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let wanted = tag?.trimmingCharacters(in: .whitespaces).lowercased()
        return workflows.filter { w in
            if let wanted, !wanted.isEmpty, !w.tags.contains(wanted) { return false }
            if trimmed.isEmpty { return true }
            return SearchService.matches(query: trimmed, in: w.searchText)
        }
    }

    public var summary: String? { template.summary }

    /// The pinned version's name when this workflow is still called
    /// something else and the person has not chosen to keep the old name.
    /// Updating never renames an installed workflow on its own; this is
    /// what the library shows instead.
    public var nameMismatch: String? {
        let pinned = template.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pinned.isEmpty, pinned != name, pinned != keptName else { return nil }
        return pinned
    }

    /// Tool name agents see for this workflow: `workflow_<slug>`.
    public var toolName: String { Self.toolName(for: name) }

    public static func toolName(for name: String) -> String {
        "workflow_" + Template.slug(for: name).replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: ".", with: "_")
    }

    enum CodingKeys: String, CodingKey {
        case id, name, bindings, template, tags
        case templateID = "template_id"
        case templateVersion = "template_version"
        case needsSetup = "needs_setup"
        case orchestratorVisible = "orchestrator_visible"
        case teammatesCanRun = "teammates_can_run"
        case agentStepsAllowed = "agent_steps_allowed"
        case selfHeal = "self_heal"
        case selfHealedSignature = "self_healed_signature"
        case keptName = "kept_name"
        case formerNames = "former_names"
        case source
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        templateID = try c.decode(UUID.self, forKey: .templateID)
        templateVersion = try c.decode(Int.self, forKey: .templateVersion)
        name = try c.decode(String.self, forKey: .name)
        bindings = try c.decode(InstallBindings.self, forKey: .bindings)
        needsSetup = try c.decodeIfPresent(Bool.self, forKey: .needsSetup) ?? false
        orchestratorVisible = try c.decodeIfPresent(Bool.self, forKey: .orchestratorVisible) ?? true
        teammatesCanRun = try c.decodeIfPresent(Bool.self, forKey: .teammatesCanRun) ?? false
        agentStepsAllowed = try c.decodeIfPresent(Bool.self, forKey: .agentStepsAllowed) ?? false
        selfHeal = try c.decodeIfPresent(Bool.self, forKey: .selfHeal) ?? false
        selfHealedSignature = try c.decodeIfPresent(String.self, forKey: .selfHealedSignature)
        tags = Self.normalizedTags(try c.decodeIfPresent([String].self, forKey: .tags) ?? [])
        keptName = try c.decodeIfPresent(String.self, forKey: .keptName)
        formerNames = try c.decodeIfPresent([String].self, forKey: .formerNames) ?? []
        source = try c.decodeIfPresent(Source.self, forKey: .source)
        template = try c.decode(Template.self, forKey: .template)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }
}
