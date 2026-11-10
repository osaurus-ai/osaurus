//
//  InstalledWorkflowStore.swift
//  osaurus
//
//  Installed workflows on disk: `~/.osaurus/workflows/<uuid>.json`, next to
//  each workflow's `<uuid>/` side directory (saved answers, run workspaces).
//  Install happens only from the setup wizard's Next on review (or the
//  orchestrator's equivalent gate), never while a requirement blocks.
//

import Combine
import CryptoKit
import Foundation

@MainActor
public final class InstalledWorkflowStore: ObservableObject {
    public static let shared = InstalledWorkflowStore()

    @Published public private(set) var workflows: [InstalledWorkflow] = [] {
        didSet { WorkflowCallNames.setInstalled(workflows) }
    }

    private init() {
        reload()
        // After launch settles, so the setup check sees models and tools.
        Task { @MainActor in
            self.clearStaleSetupFlags()
            _ = HostedWorkflowLinkStore.shared
        }
    }

    nonisolated static var directory: URL { OsaurusPaths.workflows() }

    nonisolated static func fileURL(_ id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString.lowercased()).json")
    }

    /// Workflows whose file no longer matches what Osaurus last saved. They
    /// block in setup until reviewed and saved again.
    @Published public private(set) var modifiedOutsideApp: Set<UUID> = []

    public func reload() {
        templateNameCache = [:]
        let loaded = Self.loadAllWithContents()
        modifiedOutsideApp = Self.reconcileIntegrity(loaded.map { ($0.workflow.id, $0.contents) })
        workflows = loaded.map(\.workflow)
        ToolRegistry.shared.syncWorkflowTools(workflows)
    }

    nonisolated static func loadAll() -> [InstalledWorkflow] {
        loadAllWithContents().map(\.workflow)
    }

    nonisolated static func loadAllWithContents() -> [(workflow: InstalledWorkflow, contents: Data)] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return files.filter {
            $0.pathExtension == "json" && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil
        }
            .compactMap { url -> (InstalledWorkflow, Data)? in
                guard let data = try? Data(contentsOf: url),
                    let workflow = try? decoder.decode(InstalledWorkflow.self, from: data)
                else { return nil }
                return (workflow, data)
            }
            .sorted { $0.0.name.localizedStandardCompare($1.0.name) == .orderedAscending }
    }

    // MARK: - Integrity

    /// SHA-256 of each workflow file as Osaurus last wrote it, by id.
    nonisolated static var integrityFile: URL { directory.appendingPathComponent(".integrity.json") }

    nonisolated static func contentHash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func loadIntegrity() -> [UUID: String]? {
        guard let data = try? Data(contentsOf: integrityFile),
            let raw = try? JSONDecoder().decode([String: String].self, from: data)
        else { return nil }
        return Dictionary(uniqueKeysWithValues: raw.compactMap { key, value in UUID(uuidString: key).map { ($0, value) } })
    }

    nonisolated static func saveIntegrity(_ hashes: [UUID: String]) {
        let raw = Dictionary(uniqueKeysWithValues: hashes.map { ($0.key.uuidString.lowercased(), $0.value) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(raw) else { return }
        try? OsaurusPaths.ensureExists(directory)
        try? data.write(to: integrityFile, options: .atomic)
    }

    /// The ids whose file differs from the recorded hash, or that have no
    /// hash while others do (a file Osaurus did not write). The first load
    /// after this check shipped records every file as it is.
    nonisolated static func reconcileIntegrity(_ files: [(id: UUID, contents: Data)]) -> Set<UUID> {
        let result = integrityCheck(files, recorded: loadIntegrity())
        if let updated = result.updated { saveIntegrity(updated) }
        return result.modified
    }

    /// Pure half of `reconcileIntegrity`: the modified ids, and the hashes
    /// to write back when they change (first record, or removed files).
    nonisolated static func integrityCheck(
        _ files: [(id: UUID, contents: Data)], recorded: [UUID: String]?
    ) -> (modified: Set<UUID>, updated: [UUID: String]?) {
        guard let recorded else {
            guard !files.isEmpty else { return ([], nil) }
            return ([], Dictionary(files.map { ($0.id, contentHash($0.contents)) }) { first, _ in first })
        }
        let modified = Set(files.filter { recorded[$0.id] != contentHash($0.contents) }.map(\.id))
        let present = Set(files.map(\.id))
        let kept = recorded.filter { present.contains($0.key) }
        return (modified, kept.count == recorded.count ? nil : kept)
    }

    nonisolated static func recordIntegrity(_ id: UUID, contents: Data?) {
        var hashes = loadIntegrity() ?? [:]
        hashes[id] = contents.map(contentHash)
        saveIntegrity(hashes)
    }

    public func workflow(id: UUID) -> InstalledWorkflow? {
        workflows.first { $0.id == id }
    }

    /// One installed workflow per template on this Mac.
    public func workflow(templateID: UUID) -> InstalledWorkflow? {
        workflows.first { $0.templateID == templateID }
    }

    /// Resolves a workflow by tool name, display name, or id, then by a
    /// name it had before: a former name of its own or an earlier version
    /// of its template's, when exactly one workflow had it. Steps that
    /// call a workflow by name and models repeating an old name keep
    /// working after a rename.
    public func workflow(named raw: String) -> InstalledWorkflow? {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = UUID(uuidString: key), let w = workflow(id: id) { return w }
        if let current = workflows.first(where: {
            $0.toolName == key || $0.toolName == "workflow_" + key.lowercased()
                || $0.name.caseInsensitiveCompare(key) == .orderedSame
                || Template.slug(for: $0.name) == Template.slug(for: key)
        }) {
            return current
        }
        let slug = Template.slug(for: key)
        let formerTool = key.hasPrefix(WorkflowTool.namePrefix) ? key : nil
        let matches = workflows.filter { w in
            previousNames(of: w).contains { name in
                name.caseInsensitiveCompare(key) == .orderedSame || Template.slug(for: name) == slug
                    || InstalledWorkflow.toolName(for: name) == formerTool
            }
        }
        return matches.count == 1 ? matches[0] : nil
    }

    /// Names `workflow` answered to before: its own former names and the
    /// names earlier versions of its template carried.
    func previousNames(of workflow: InstalledWorkflow) -> [String] {
        let versions: [String]
        if let cached = templateNameCache[workflow.templateID] {
            versions = cached
        } else {
            versions = Array(Set(TemplateStore.shared.versions(of: workflow.templateID).map(\.name)))
            templateNameCache[workflow.templateID] = versions
        }
        return (workflow.formerNames + versions + [workflow.template.name]).filter {
            !$0.isEmpty && $0 != workflow.name
        }
    }

    /// Template id → names its stored versions carry; cleared on reload.
    private var templateNameCache: [UUID: [String]] = [:]

    public var orchestratorVisible: [InstalledWorkflow] { workflows.filter(\.orchestratorVisible) }

    /// Writes the workflow and records its hash. A workflow changed
    /// outside Osaurus stays flagged through ordinary saves; only a
    /// `reviewed` save (installing it again from setup) clears that.
    public func save(_ workflow: InstalledWorkflow, reviewed: Bool = false) throws {
        var copy = workflow
        copy.updatedAt = Date()
        try OsaurusPaths.ensureExists(Self.directory)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(copy)
        try data.write(to: Self.fileURL(copy.id), options: .atomic)
        if reviewed || !modifiedOutsideApp.contains(copy.id) { Self.recordIntegrity(copy.id, contents: data) }
        reload()
    }

    /// Installs a template version, or re-pins the existing install of the
    /// same template. A free tool name is chosen when another workflow
    /// already uses the name. A re-pin keeps the workflow's name unless
    /// `name` asks for another: a newer version never renames what agents
    /// call on its own (`InstalledWorkflow.nameMismatch` shows it instead).
    @discardableResult
    public func install(_ template: Template, bindings: InstallBindings, name: String? = nil) throws
        -> InstalledWorkflow
    {
        precondition(template.kind == .workflow, "only workflow templates install as workflows")
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let wanted = trimmedName.isEmpty ? nil : trimmedName
        if var existing = workflow(templateID: template.id) {
            // A new agent to ask is asked about again.
            if !TemplateDiff.newRequirements(from: existing.template.requirements, to: template.requirements)
                .agents.isEmpty
            {
                existing.agentStepsAllowed = false
            }
            existing.template = template
            existing.templateVersion = template.version
            existing.bindings = bindings
            existing.needsSetup = false
            try save(existing, reviewed: true)
            if let wanted, wanted != existing.name { _ = try rename(id: existing.id, to: wanted) }
            return workflow(id: existing.id) ?? existing
        }
        let taken = Set(workflows.map { Template.slug(for: $0.name) }).union(Self.reservedSlugs)
        let chosen = Self.availableName(
            for: wanted ?? template.name, takenSlugs: taken, template: template, bindings: bindings)
        var installed = InstalledWorkflow(template: template, bindings: bindings, name: chosen)
        if chosen != template.name { installed.keptName = template.name }
        try save(installed, reviewed: true)
        return workflow(id: installed.id) ?? installed
    }

    /// Renames an installed workflow: the name Settings shows and the one
    /// agents and the Orchestrator call (`workflow_<slug>`). Takes a
    /// numbered name when another workflow or tool holds it, carries the
    /// tool's permission policy over to the new tool name, and records a
    /// name other than the template's as kept, so only a later template
    /// rename raises the name notice.
    @discardableResult
    public func rename(id: UUID, to newName: String) throws -> InstalledWorkflow {
        guard var w = workflow(id: id) else { throw RenameError.notFound }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw RenameError.emptyName }
        let oldName = w.name
        let oldToolName = w.toolName
        w.name = renamedName(for: trimmed, id: id) ?? w.name
        // A name other than the template's is the person's choice; only a
        // later template rename brings the notice back.
        w.keptName = w.name == w.template.name ? nil : w.template.name
        if w.name != oldName {
            w.formerNames.removeAll { $0 == oldName || $0 == w.name }
            w.formerNames.append(oldName)
            w.formerNames = Array(w.formerNames.suffix(InstalledWorkflow.maximumFormerNames))
        }
        try save(w)
        let saved = workflow(id: id) ?? w
        if saved.toolName != oldToolName {
            let registry = ToolRegistry.shared
            if let policy = registry.configuredPolicy(for: oldToolName) {
                registry.setPolicy(policy, for: saved.toolName)
                registry.clearPolicy(for: oldToolName)
            }
        }
        return saved
    }

    /// The name `rename` would give workflow `id` for `requested`: the
    /// requested name, or a numbered one when it is taken. Nil when the
    /// workflow is gone.
    public func renamedName(for requested: String, id: UUID) -> String? {
        guard let w = workflow(id: id) else { return nil }
        let trimmed = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed == w.name { return trimmed }
        let taken = Set(workflows.filter { $0.id != id }.map { Template.slug(for: $0.name) })
            .union(Self.reservedSlugs)
        return Self.availableName(for: trimmed, takenSlugs: taken, template: w.template, bindings: w.bindings)
    }

    /// "Keep" on the name notice: the pinned version's name is not taken on,
    /// and the notice stays quiet until the template is renamed again.
    public func keepName(id: UUID) throws {
        guard var w = workflow(id: id), w.keptName != w.template.name else { return }
        w.keptName = w.template.name
        try save(w)
    }

    public enum RenameError: LocalizedError, Equatable {
        case notFound
        case emptyName

        public var errorDescription: String? {
            switch self {
            case .notFound: return L("This workflow is no longer installed.")
            case .emptyName: return L("Give the workflow a name.")
            }
        }
    }

    /// A name free among installed workflows whose `workflow_<slug>` tool
    /// is not already held by a plugin, MCP, or built-in tool: a template
    /// named to shadow one would otherwise install without a callable tool
    /// (or, worse, claim the other's name).
    static func availableName(
        for base: String, takenSlugs: Set<String>, template: Template, bindings: InstallBindings
    ) -> String {
        var slugs = takenSlugs
        while true {
            let candidate = Template.availableName(for: base, takenSlugs: slugs)
            let probe = InstalledWorkflow(template: template, bindings: bindings, name: candidate)
            if ToolRegistry.shared.isWorkflowToolNameAvailable(probe.toolName) { return candidate }
            slugs.insert(Template.slug(for: candidate))
        }
    }

    /// Names whose tool would collide with the Architect's `workflow_*` tools.
    static var reservedSlugs: Set<String> {
        Set(
            ToolRegistry.architectToolNames.map {
                String($0.dropFirst(WorkflowTool.namePrefix.count)).replacingOccurrences(of: "_", with: "-")
            })
    }

    public func setOrchestratorVisible(_ visible: Bool, id: UUID) throws {
        guard var w = workflow(id: id) else { return }
        w.orchestratorVisible = visible
        try save(w)
    }

    public func setTeammatesCanRun(_ allowed: Bool, id: UUID) throws {
        guard var w = workflow(id: id), w.teammatesCanRun != allowed else { return }
        w.teammatesCanRun = allowed
        try save(w)
    }

    public func setAgentStepsAllowed(_ allowed: Bool, id: UUID) throws {
        guard var w = workflow(id: id), w.agentStepsAllowed != allowed else { return }
        w.agentStepsAllowed = allowed
        try save(w)
    }

    /// Turning self-heal on starts fresh: a failure already drafted for
    /// is drafted again if it keeps happening.
    public func setSelfHeal(_ enabled: Bool, id: UUID) throws {
        guard var w = workflow(id: id), w.selfHeal != enabled else { return }
        w.selfHeal = enabled
        w.selfHealedSignature = nil
        try save(w)
    }

    /// Replaces the workflow's tags (normalized: lower-cased, unique).
    public func setTags(_ tags: [String], id: UUID) throws {
        let normalized = InstalledWorkflow.normalizedTags(tags)
        guard var w = workflow(id: id), w.tags != normalized else { return }
        w.tags = normalized
        try save(w)
    }

    /// Every tag in use, with how many workflows carry it, by name.
    public var allTags: [(tag: String, count: Int)] {
        var counts: [String: Int] = [:]
        for w in workflows { for t in w.tags { counts[t, default: 0] += 1 } }
        return counts.keys.sorted().map { ($0, counts[$0] ?? 0) }
    }

    public func setSelfHealedSignature(_ signature: String?, id: UUID) {
        guard var w = workflow(id: id), w.selfHealedSignature != signature else { return }
        w.selfHealedSignature = signature
        try? save(w)
    }

    /// Saves a folder the person allowed for every run ("Always allow"):
    /// to save in it, or with `access: .read` only to read it.
    public func addFolderGrant(_ path: String, access: FolderRequirement.Access = .write, id: UUID) {
        guard var w = workflow(id: id) else { return }
        switch access {
        case .write:
            guard !w.bindings.folderGrants.contains(path) else { return }
            w.bindings.folderGrants.append(path)
            w.bindings.folderReadGrants.removeAll { $0 == path }
        case .read:
            guard !w.bindings.folderGrants.contains(path), !w.bindings.folderReadGrants.contains(path) else { return }
            w.bindings.folderReadGrants.append(path)
        }
        try? save(w)
    }

    public func removeFolderGrant(_ path: String, id: UUID) {
        guard var w = workflow(id: id),
            w.bindings.folderGrants.contains(path) || w.bindings.folderReadGrants.contains(path)
        else { return }
        w.bindings.folderGrants.removeAll { $0 == path }
        w.bindings.folderReadGrants.removeAll { $0 == path }
        try? save(w)
    }

    /// Saves a folder where every run may replace existing files.
    public func addReplaceGrant(_ path: String, id: UUID) {
        guard var w = workflow(id: id), !w.bindings.replaceGrants.contains(path) else { return }
        w.bindings.replaceGrants.append(path)
        try? save(w)
    }

    public func removeReplaceGrant(_ path: String, id: UUID) {
        guard var w = workflow(id: id), w.bindings.replaceGrants.contains(path) else { return }
        w.bindings.replaceGrants.removeAll { $0 == path }
        try? save(w)
    }

    public func setNeedsSetup(_ needs: Bool, id: UUID) {
        guard var w = workflow(id: id), w.needsSetup != needs else { return }
        w.needsSetup = needs
        try? save(w)
    }

    /// Clears Needs setup on the flagged workflows (all when `ids` is nil)
    /// whose install check now passes. Only ever clears, so a check that
    /// runs before models or tools load can't flag anything.
    public func clearStaleSetupFlags(ids: Set<UUID>? = nil) {
        for w in workflows where w.needsSetup && (ids?.contains(w.id) ?? true) {
            if SetupChecker.check(w, secrets: .install, attended: true).blocking.isEmpty {
                setNeedsSetup(false, id: w.id)
            }
        }
    }

    /// Removes the workflow, its saved answers, its stored data, and its
    /// run history, and disables it on every agent.
    public func delete(id: UUID) {
        let removed = workflow(id: id)
        try? FileManager.default.removeItem(at: Self.fileURL(id))
        Self.recordIntegrity(id, contents: nil)
        SavedAnswersStore.shared.clearAll(workflowID: id)
        if let removed {
            WorkflowCredentials.forget(keys: removed.template.requirements.secrets.map(\.key), scope: id)
        }
        WorkflowRunStore.shared.deleteRuns(workflowID: id)
        WorkflowStateStore.shared.deleteAll(workflow: id)
        try? FileManager.default.removeItem(at: OsaurusPaths.workflowDirectory(id))
        AgentManager.shared.removeWorkflowFromAllAgents(id)
        reload()
        // Its sandbox environment (venv, npm workspace, Linux user) goes
        // too, unless an Architect draft of the same template still uses it.
        if let removed, removed.template.requirements.usesSandbox || removed.definition.usesSandbox,
            !WorkflowDraftStore.shared.drafts.values.contains(where: { $0.template().id == removed.templateID })
        {
            let environmentID = removed.templateID
            Task { await WorkflowSandboxEnvironment.shared.remove(environmentID: environmentID) }
        }
    }

    /// Newest template version on this Mac, when it is newer than the pin.
    /// A pin signed by some Osaurus ID only updates to a version validly
    /// signed by the same one.
    public func availableUpdate(for workflow: InstalledWorkflow) -> Template? {
        guard let latest = TemplateStore.shared.latest(id: workflow.templateID),
            latest.version > workflow.templateVersion
        else { return nil }
        let knownAgent: (String) -> UUID? = { AgentIdentityRegistry.shared.agentId(forAddress: $0) }
        guard TemplateSigner.continuityBreak(from: [workflow.template], to: latest, knownAgent: knownAgent) == nil
        else { return nil }
        return latest
    }

    func resetForTesting() {
        for workflow in workflows { try? FileManager.default.removeItem(at: Self.fileURL(workflow.id)) }
        try? FileManager.default.removeItem(at: Self.integrityFile)
        workflows = []
        modifiedOutsideApp = []
        ToolRegistry.shared.syncWorkflowTools([])
    }
}
