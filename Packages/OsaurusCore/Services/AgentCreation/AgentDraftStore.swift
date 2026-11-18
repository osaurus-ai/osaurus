//
//  AgentDraftStore.swift
//  osaurus
//
//  New Agent drafts at `~/.osaurus/agent-drafts/<id>.json`, one per
//  Configurator chat. Every change writes through so a draft survives
//  quitting mid-design, and publishes so the draft panel redraws.
//

import Foundation

@MainActor
public final class AgentDraftStore: ObservableObject {
    public static let shared = AgentDraftStore()

    @Published public private(set) var drafts: [UUID: AgentDraft] = [:]

    nonisolated static var directory: URL { OsaurusPaths.agentDrafts() }

    nonisolated static func fileURL(_ id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString.lowercased()).json")
    }

    private init() { reload() }

    public func reload() {
        var loaded: [UUID: AgentDraft] = [:]
        let files =
            (try? FileManager.default.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                let draft = try? decoder.decode(AgentDraft.self, from: data)
            else { continue }
            loaded[draft.id] = draft
        }
        drafts = loaded
    }

    public func draft(id: UUID) -> AgentDraft? { drafts[id] }

    public func draft(forSession sessionID: String?) -> AgentDraft? {
        guard let sessionID else { return nil }
        return drafts.values.filter { $0.sessionID == sessionID }.max { $0.updatedAt < $1.updatedAt }
    }

    /// Drafts with something in them that were never created, newest first.
    public var unfinishedDrafts: [AgentDraft] {
        drafts.values.filter { !$0.isCreated && !$0.isEmpty }.sorted { $0.updatedAt > $1.updatedAt }
    }

    // MARK: - Creating

    /// A new, empty draft. Tools start in auto mode with every installed
    /// tool assigned, the same set a new agent gets.
    @discardableResult
    public func create(sessionID: String?) -> AgentDraft {
        var agent = AgentManager.newCustomAgentRecord(name: "")
        agent.toolSelectionMode = .auto
        agent.manualToolNames = ToolRegistry.shared.listDynamicTools().map(\.name)
        let draft = AgentDraft(sessionID: sessionID, agent: agent)
        write(draft)
        return draft
    }

    public func bind(_ id: UUID, to sessionID: String) {
        mutate(id) { $0.sessionID = sessionID }
    }

    // MARK: - Configurator patches

    public struct PatchResult: Sendable {
        /// Fields the patch changed.
        public var changed: [AgentDraft.Field]
        /// Fields the patch named but the person had edited, left as is.
        public var keptUserEdits: [AgentDraft.Field]
        /// Portability notes from the shared agent mapping.
        public var notes: [String]
    }

    public struct PatchError: Error, Sendable {
        public let message: String
    }

    /// Applies the Configurator's `agent_draft` `patch`. The entry goes
    /// through the same mapping `osaurus_config` apply uses
    /// (`ConfigApplier.patchDraft`), so a draft and a declared agent cannot
    /// drift. Throws without changing the draft when any part is invalid.
    @discardableResult
    public func applyConfiguratorPatch(
        _ id: UUID, entry: AgentEntry, reasons: [String: String] = [:], overrideUserEdits: Bool = false
    ) throws -> PatchResult {
        guard let current = drafts[id] else { throw PatchError(message: "No draft.") }
        guard !current.isCreated else {
            throw PatchError(message: "This agent was already created; change it in its settings instead.")
        }
        var entry = entry
        let named = Self.fields(in: entry)
        let kept = overrideUserEdits ? [] : named.filter { current.userEdited.contains($0) }
        for field in kept { Self.clear(field, in: &entry) }
        if let unknown = Self.unknownToolNames(in: entry), !unknown.isEmpty {
            throw PatchError(
                message: "Not assignable tools on this Mac: \(unknown.joined(separator: ", ")). "
                    + "Built-in tools come from `capabilities`; use `tools` with a `query` to find exact names. "
                    + "Nothing was changed.")
        }
        let queued = Self.takeQueuedMCPServers(from: &entry, draft: current)
        var agent = current.agent
        var outcome: ConfigApplier.AgentPatchOutcome
        do {
            outcome = try ConfigApplier.patchDraft(&agent, with: entry)
        } catch let error as ConfigApplier.DraftPatchError {
            throw PatchError(message: error.message + " Nothing was changed.")
        }
        if !queued.isEmpty {
            outcome.notes.append(
                "Installs when the user clicks Create, and is attached to the agent then: "
                    + queued.joined(separator: ", ") + ".")
        }
        let changed = named.filter { !kept.contains($0) }
        let patched = agent
        mutate(id) { draft in
            draft.agent = patched
            draft.touched.formUnion(changed)
            if overrideUserEdits { draft.userEdited.subtract(changed) }
            for (key, why) in reasons {
                let trimmed = why.trimmingCharacters(in: .whitespacesAndNewlines)
                draft.reasons[key] = trimmed.isEmpty ? nil : trimmed
            }
        }
        return PatchResult(changed: changed, keptUserEdits: kept, notes: outcome.notes)
    }

    /// Removes queued MCP server names from the entry's `mcp_servers` so the
    /// patch doesn't report them as missing; Create attaches them.
    private static func takeQueuedMCPServers(from entry: inout AgentEntry, draft: AgentDraft) -> [String] {
        guard var groups = entry.mcpServers, let enabled = groups.enabled else { return [] }
        let queued = Set(draft.queuedMCPServerNames.map { $0.lowercased() })
        guard !queued.isEmpty else { return [] }
        let taken = enabled.filter { queued.contains($0.lowercased()) }
        guard !taken.isEmpty else { return [] }
        groups.enabled = enabled.filter { !queued.contains($0.lowercased()) }
        entry.mcpServers = groups
        return taken
    }

    // MARK: - Imports

    /// Where queued skill folders wait until Create.
    nonisolated static func importsDirectory(_ id: UUID) -> URL {
        directory.appendingPathComponent("imports", isDirectory: true)
            .appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
    }

    /// Queues import items to install on Create. An item with the same kind
    /// and name replaces the queued one. Skill folders are copied out of
    /// the temporary download so they survive until Create.
    @discardableResult
    func queueImports(_ id: UUID, items: [ChatImportItem]) -> [ChatImportItem] {
        guard let draft = drafts[id], !draft.isCreated else { return [] }
        let fm = FileManager.default
        var queued = draft.queuedImports
        var added: [ChatImportItem] = []
        for var item in items {
            if case .instructions(var spec) = item.payload, let source = spec.packageDirectory {
                let target = Self.importsDirectory(id).appendingPathComponent(item.id, isDirectory: true)
                try? fm.removeItem(at: target)
                do {
                    try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.copyItem(at: source, to: target)
                    spec.packageDirectory = target
                } catch {
                    spec.packageDirectory = nil
                    item.warnings.append(L("Its scripts and reference files couldn't be kept; only the instructions install."))
                }
                item.payload = .instructions(spec)
            }
            queued.removeAll {
                $0.id == item.id || ($0.kind == item.kind && $0.name.caseInsensitiveCompare(item.name) == .orderedSame)
            }
            queued.append(item)
            added.append(item)
        }
        mutate(id) { $0.pendingImports = queued }
        return added
    }

    /// The person removed a queued item on the card.
    func removePendingImport(_ id: UUID, itemId: String) {
        guard let draft = drafts[id], !draft.isCreated,
            let item = draft.queuedImports.first(where: { $0.id == itemId })
        else { return }
        let target = Self.importsDirectory(id).appendingPathComponent(item.id, isDirectory: true)
        try? FileManager.default.removeItem(at: target)
        let note = "The user removed \(item.name) from what installs on Create."
        mutate(id) { d in
            d.pendingImports = d.queuedImports.filter { $0.id != itemId }
            d.pendingUserEdits.append(note)
        }
    }

    /// Create installed everything; the queue and its folders go.
    func clearPendingImports(_ id: UUID) {
        try? FileManager.default.removeItem(at: Self.importsDirectory(id))
        mutate(id) { $0.pendingImports = nil }
    }

    /// Hand-picked tool names that are not installed, assignable tools here.
    static func unknownToolNames(in entry: AgentEntry) -> [String]? {
        guard let names = entry.tools?.enabled else { return nil }
        let assignable = Set(ToolRegistry.shared.listDynamicTools().map(\.name))
        return names.filter { !assignable.contains($0) }
    }

    static func fields(in entry: AgentEntry) -> [AgentDraft.Field] {
        var fields: [AgentDraft.Field] = []
        if !entry.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { fields.append(.name) }
        if entry.description != nil { fields.append(.description) }
        if entry.avatar != nil { fields.append(.avatar) }
        if entry.model.isSpecified { fields.append(.model) }
        if entry.tools != nil || entry.capabilities != nil || entry.mcpServers != nil || entry.plugins != nil {
            fields.append(.tools)
        }
        if entry.systemPrompt != nil || entry.template != nil { fields.append(.instructions) }
        return fields
    }

    private static func clear(_ field: AgentDraft.Field, in entry: inout AgentEntry) {
        switch field {
        case .name: entry.name = ""
        case .description: entry.description = nil
        case .avatar: entry.avatar = nil
        case .model: entry.model = .absent
        case .tools:
            entry.tools = nil
            entry.capabilities = nil
            entry.mcpServers = nil
            entry.plugins = nil
        case .instructions:
            entry.systemPrompt = nil
            entry.template = nil
        }
    }

    // MARK: - Panel edits

    /// A direct edit from the draft panel. The note waits for the
    /// Configurator's next turn.
    public func applyUserEdit(_ id: UUID, _ field: AgentDraft.Field, _ change: (inout Agent) -> Void) {
        guard var draft = drafts[id], !draft.isCreated else { return }
        let before = draft.agent
        change(&draft.agent)
        guard draft.agent != before else { return }
        let note = Self.note(for: field, agent: draft.agent)
        let edited = draft.agent
        if !draft.userEdited.contains(field) { FeatureTelemetry.agentCreationEdited(field: field.rawValue) }
        mutate(id) { d in
            d.agent = edited
            d.userEdited.insert(field)
            d.touched.insert(field)
            d.pendingUserEdits.removeAll { $0.hasPrefix(Self.notePrefix(field)) }
            d.pendingUserEdits.append(note)
        }
    }

    /// A panel setting the Configurator never authors (generation overrides,
    /// response metrics): no note and no edited mark.
    public func applyPanelSetting(_ id: UUID, _ change: (inout Agent) -> Void) {
        guard var agent = drafts[id]?.agent, drafts[id]?.isCreated == false else { return }
        let before = agent
        change(&agent)
        guard agent != before else { return }
        mutate(id) { $0.agent = agent }
    }

    private static func notePrefix(_ field: AgentDraft.Field) -> String {
        "The user set the \(field.rawValue)"
    }

    private static func note(for field: AgentDraft.Field, agent: Agent) -> String {
        let prefix = notePrefix(field)
        switch field {
        case .name: return "\(prefix) to \"\(agent.name)\"."
        case .description: return "\(prefix) to \"\(agent.description)\"."
        case .avatar: return "\(prefix) to \(agent.avatar ?? "the name's initial")."
        case .model: return "\(prefix) to \(agent.defaultModel ?? "the default model")."
        case .tools:
            let mode = agent.toolSelectionMode ?? .auto
            let apps = agent.settings.enabledAppleApps.map(\.rawValue).sorted()
            var line = "\(prefix) on the card: \(mode.rawValue) mode"
            if mode == .manual { line += " with \(agent.manualToolNames?.count ?? 0) tools picked" }
            if !apps.isEmpty { line += ", Apple apps: \(apps.joined(separator: ", "))" }
            return line + "."
        case .instructions: return "\(prefix) on the card; read them with `get` before changing them."
        }
    }

    // MARK: - Creating the agent

    public func markCreated(_ id: UUID, agentId: UUID) {
        mutate(id) { $0.createdAgentId = agentId }
    }

    // MARK: - Turn context

    /// The person's panel edits, for the next message to the Configurator.
    /// Clears them.
    public func takeTurnContext(sessionID: String?) -> String? {
        guard let draft = draft(forSession: sessionID), !draft.pendingUserEdits.isEmpty else { return nil }
        let text =
            "Since your last turn, in the draft panel:\n"
            + draft.pendingUserEdits.map { "- \($0)" }.joined(separator: "\n")
        mutate(draft.id) { $0.pendingUserEdits = [] }
        return text
    }

    // MARK: - Disk

    public func delete(_ id: UUID) {
        drafts[id] = nil
        try? FileManager.default.removeItem(at: Self.fileURL(id))
        try? FileManager.default.removeItem(at: Self.importsDirectory(id))
    }

    private func mutate(_ id: UUID, _ change: (inout AgentDraft) -> Void) {
        guard var draft = drafts[id] else { return }
        change(&draft)
        draft.updatedAt = Date()
        write(draft)
    }

    private func write(_ draft: AgentDraft) {
        drafts[draft.id] = draft
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        do {
            try OsaurusPaths.ensureExists(Self.directory)
            try encoder.encode(draft).write(to: Self.fileURL(draft.id), options: .atomic)
        } catch {
            print("[Osaurus] Failed to save agent draft: \(error)")
        }
    }

    func resetForTesting() {
        drafts = [:]
    }
}
