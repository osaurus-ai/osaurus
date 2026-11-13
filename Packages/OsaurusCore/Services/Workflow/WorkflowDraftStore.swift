//
//  WorkflowDraftStore.swift
//  osaurus
//
//  Architect drafts at `~/.osaurus/workflows/drafts/<id>.json`, one per
//  chat. Every change writes through so a draft survives quitting
//  mid-design, and publishes so the sidebar redraws.
//

import Foundation

@MainActor
public final class WorkflowDraftStore: ObservableObject {
    public static let shared = WorkflowDraftStore()

    @Published public private(set) var drafts: [UUID: WorkflowDraft] = [:]
    /// A draft whose test run needs setup first; its sidebar opens the
    /// setup wizard.
    @Published public var setupRequest: UUID?

    nonisolated static var directory: URL { OsaurusPaths.workflowDrafts() }

    nonisolated static func fileURL(_ id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString.lowercased()).json")
    }

    private init() { reload() }

    public func reload() {
        WorkflowDraftDiskWriter.shared.flush()
        var loaded: [UUID: WorkflowDraft] = [:]
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                let draft = try? decoder.decode(WorkflowDraft.self, from: data)
            else { continue }
            loaded[draft.id] = draft
        }
        drafts = loaded
    }

    public func draft(id: UUID) -> WorkflowDraft? { drafts[id] }

    /// Unfinished creations and edits belong on Workflows home, alongside
    /// saved workflows. A saved, unchanged draft remains available for Edit
    /// without appearing a second time as unfinished work.
    public var libraryDrafts: [WorkflowDraft] {
        drafts.values.filter { draft in
            guard !Self.isInline(draft) else { return false }
            guard let id = draft.templateID,
                let saved = InstalledWorkflowStore.shared.workflow(templateID: id)
            else { return true }
            return draft.definition != saved.definition || draft.name != saved.name
                || draft.summary != (saved.summary ?? "")
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func draft(forSession sessionID: String?) -> WorkflowDraft? {
        guard let sessionID else { return nil }
        return drafts.values.filter { $0.sessionID == sessionID }.max { $0.updatedAt < $1.updatedAt }
    }

    /// Drafts that edit `templateID`, most recently touched first. Inline
    /// drafts have no Architect chat to resume, so they are left out.
    public func drafts(templateID: UUID) -> [WorkflowDraft] {
        drafts.values.filter { $0.templateID == templateID && !Self.isInline($0) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    // MARK: - Inline drafts

    /// Session key prefix of drafts the Architect builds inline from chat.
    /// Each handoff gets a key of its own.
    public static let inlineSessionPrefix = "architect-inline-"

    public static func isInline(_ draft: WorkflowDraft) -> Bool {
        draft.sessionID?.hasPrefix(inlineSessionPrefix) == true
    }

    /// How long an inline draft nobody kept stays available to keep.
    static let inlineDraftLifetime: TimeInterval = 24 * 60 * 60

    /// A new empty inline draft, first dropping inline drafts nobody kept
    /// within `inlineDraftLifetime`. Their runs stay in the Tasks view.
    func createInline(now: Date = Date()) -> WorkflowDraft {
        for draft in drafts.values
        where Self.isInline(draft) && draft.templateID == nil
            && now.timeIntervalSince(draft.updatedAt) > Self.inlineDraftLifetime
        {
            delete(draft.id, keepTestRuns: true)
        }
        return create(sessionID: Self.inlineSessionPrefix + UUID().uuidString, telemetryOrigin: "inline")
    }

    /// Brings a draft up to `template`, a newer saved version of what it
    /// edits. Undo restores what the draft held.
    public func rebase(_ id: UUID, onto template: Template) {
        guard let definition = template.workflow, let draft = drafts[id], draft.baseVersion != template.version
        else { return }
        mutate(id) { d in
            d.edit(source: .user, summary: "Loaded saved version \(template.version)") { d in
                d.definition = definition
                d.name = template.name
                d.summary = template.summary ?? ""
                d.baseVersion = template.version
                d.lastPatchedNodeIDs = []
            }
            d.pendingUserEdits.append(
                "The draft now holds saved version \(template.version) of \"\(template.name)\", "
                    + "which is newer than what this chat last edited.")
        }
    }

    // MARK: - Creating

    /// A new draft, empty or starting from `template` (Edit in the Architect).
    @discardableResult
    public func create(sessionID: String?, from template: Template? = nil) -> WorkflowDraft {
        create(sessionID: sessionID, from: template, telemetryOrigin: nil)
    }

    /// `telemetryOrigin` overrides the `workflow_draft_started` origin token
    /// (`inline` for a chat handoff); otherwise `edit` or `blank`.
    private func create(sessionID: String?, from template: Template? = nil, telemetryOrigin: String?) -> WorkflowDraft {
        var draft = WorkflowDraft(sessionID: sessionID)
        if let template, let definition = template.workflow {
            draft.name = template.name
            draft.summary = template.summary ?? ""
            draft.templateID = template.id
            draft.baseVersion = template.version
            draft.definition = definition
            draft.serverHints = template.serverHints
            if let installed = InstalledWorkflowStore.shared.workflow(templateID: template.id) {
                draft.bindings = installed.bindings
                // Saving renames the install to the draft's name, so a name
                // the person gave or kept is where the draft starts. An
                // undecided mismatch starts from the template's name, and
                // the save card says it renames the workflow.
                if installed.nameMismatch == nil { draft.name = installed.name }
            }
        }
        write(draft)
        FeatureTelemetry.workflowDraftStarted(
            origin: telemetryOrigin ?? (draft.templateID == nil ? "blank" : "edit"))
        return draft
    }

    /// Replaces the draft's graph with `template`'s (a registry or library
    /// workflow the Architect adapts instead of building from scratch).
    /// A draft that edits a saved workflow is detached first, so the saved
    /// one is left as it is. Returns the draft id afterwards.
    @discardableResult
    public func adopt(_ id: UUID, template: Template, source: String) -> UUID? {
        guard let current = drafts[id], let definition = template.workflow else { return nil }
        var target = id
        if current.templateID != nil, let newID = unbind(id) { target = newID }
        mutate(target) { draft in
            draft.edit(source: .architect, summary: L("Started from “\(template.name)” (\(source))")) { d in
                d.definition = definition
                d.name = template.name
                d.summary = template.summary ?? ""
                d.serverHints = template.serverHints
                d.lastPatchedNodeIDs = definition.nodes.map(\.id)
            }
        }
        return target
    }

    /// Binds a draft created before its chat had an id.
    public func bind(_ id: UUID, to sessionID: String) {
        mutate(id) { $0.sessionID = sessionID }
    }

    // MARK: - Editing

    /// Applies the Architect's ops. Throws without changing the draft when
    /// any op fails.
    @discardableResult
    public func applyArchitectPatch(_ id: UUID, ops: [WorkflowDraftOp], why: String? = nil) throws -> WorkflowDraftPatcher.Result {
        guard let current = drafts[id] else { throw WorkflowDraftPatcher.Failure(index: 0, message: "No draft.") }
        let result = try WorkflowDraftPatcher.apply(ops, to: current.definition)
        // `summary` is the compact, id-based form the Architect reads back
        // (undo reports, turn context); `lines` is the same change in the
        // person's words for the Changes list and the save card.
        let changes = WorkflowDiff.changes(from: current.definition, to: result.definition, details: false)
        var compact = changes.map(\.line)
        var lines = WorkflowDiff.plainLines(changes, from: current.definition, to: result.definition)
        func both(_ line: String, first: Bool = false) {
            if first {
                compact.insert(line, at: 0)
                lines.insert(line, at: 0)
            } else {
                compact.append(line)
                lines.append(line)
            }
        }
        if result.detached, current.templateID != nil { both(L("Made it a new workflow"), first: true) }
        var hints = current.serverHints
        for (hint, remove) in result.serverHints {
            hints.removeAll { $0.id == hint.id }
            if remove {
                both(L("Removed the MCP server “\(hint.name)”"))
            } else {
                hints.append(hint)
                both(L("Declared the MCP server “\(hint.name)”"))
            }
        }
        if let name = result.name, name != current.name { both(L("Renamed the workflow to \"\(name)\"")) }
        if let summary = result.summary, summary != current.summary { both(L("Changed the summary")) }
        let summary = compact.joined(separator: "; ")
        let reason = why?.trimmingCharacters(in: .whitespacesAndNewlines)
        mutate(id) { draft in
            draft.edit(source: .architect, summary: summary.isEmpty ? L("Updated details") : summary) { d in
                d.definition = result.definition
                if let name = result.name { d.name = name }
                if let summary = result.summary { d.summary = summary }
                d.serverHints = hints
                d.lastPatchedNodeIDs = result.touchedNodeIDs
            }
            if var last = draft.history.popLast() {
                last.lines = lines
                if let reason, !reason.isEmpty { last.why = reason }
                draft.history.append(last)
            }
        }
        if result.detached { unbind(id) }
        return result
    }

    /// The draft stops editing the saved workflow it was opened from or
    /// last saved; saving creates a new workflow and leaves that one as it
    /// is. Undo does not rebind it: opening the saved workflow again edits it.
    public func detach(_ id: UUID) {
        let saved = drafts[id]?.templateID.flatMap { TemplateStore.shared.latest(id: $0)?.name }
        guard let newID = unbind(id) else { return }
        notePending(
            newID,
            saved.map { "The user made this draft a new workflow; saving no longer changes \"\($0)\"." }
                ?? "The user made this draft a new workflow.")
    }

    /// Clears a draft's saved workflow and returns its id. An unbound draft
    /// saves under its own id, so a draft whose first save created a
    /// workflow under that id moves to a new id; answers given in its test
    /// runs stay behind.
    @discardableResult
    private func unbind(_ id: UUID) -> UUID? {
        guard let old = drafts[id], old.templateID != nil else { return nil }
        guard TemplateStore.shared.latest(id: id) != nil else {
            mutate(id) { d in
                d.templateID = nil
                d.baseVersion = nil
                d.forgetSavedIdentityInHistory()
            }
            return id
        }
        var copy = WorkflowDraft(
            sessionID: old.sessionID, name: old.name, summary: old.summary, definition: old.definition,
            bindings: old.bindings)
        copy.history = old.history
        copy.forgetSavedIdentityInHistory()
        copy.serverHints = old.serverHints
        copy.testRunIDs = old.testRunIDs
        copy.lastPatchedNodeIDs = old.lastPatchedNodeIDs
        copy.pendingUserEdits = old.pendingUserEdits
        copy.selectedNodeID = old.selectedNodeID
        copy.createdAt = old.createdAt
        delete(id, keepTestRuns: true)
        write(copy)
        return copy.id
    }

    /// A direct edit from the sidebar. The change summary waits for the
    /// Architect's next turn.
    public func applyUserEdit(_ id: UUID, _ change: (inout WorkflowDraft) -> Void) {
        guard var draft = drafts[id] else { return }
        let before = draft
        change(&draft)
        guard draft.definition != before.definition || draft.name != before.name || draft.summary != before.summary
        else { return }
        let changes = WorkflowDiff.changes(from: before.definition, to: draft.definition, details: false)
        var compact = changes.map(\.line)
        var lines = WorkflowDiff.plainLines(changes, from: before.definition, to: draft.definition)
        if draft.name != before.name {
            compact.append("Renamed the workflow to \"\(draft.name)\"")
            lines.append("Renamed the workflow to \"\(draft.name)\"")
        }
        if draft.summary != before.summary {
            compact.append("Changed the summary")
            lines.append("Changed the summary")
        }
        let edited = draft
        mutate(id) { d in
            d.edit(source: .user, summary: compact.joined(separator: "; ")) { d in
                d.definition = edited.definition
                d.name = edited.name
                d.summary = edited.summary
                d.lastPatchedNodeIDs = []
            }
            if var last = d.history.popLast() {
                last.lines = lines
                d.history.append(last)
            }
            d.pendingUserEdits += compact
        }
    }

    public func undo(_ id: UUID) {
        mutate(id) { draft in
            guard let undone = draft.undo() else { return }
            draft.pendingUserEdits.append("Undid: \(undone.summary)")
            draft.lastPatchedNodeIDs = []
        }
    }

    public func setBindings(_ id: UUID, _ bindings: InstallBindings) {
        mutate(id) { $0.bindings = bindings }
    }

    /// Saves a folder the person allowed for every test run of the draft;
    /// it carries over to the install when the draft is saved.
    public func addFolderGrant(_ path: String, access: FolderRequirement.Access = .write, draftID: UUID) {
        guard let draft = drafts[draftID], !draft.bindings.folderGrants.contains(path) else { return }
        switch access {
        case .write:
            mutate(draftID) {
                $0.bindings.folderGrants.append(path)
                $0.bindings.folderReadGrants.removeAll { $0 == path }
            }
        case .read:
            guard !draft.bindings.folderReadGrants.contains(path) else { return }
            mutate(draftID) { $0.bindings.folderReadGrants.append(path) }
        }
    }

    /// Saves a folder where every test run of the draft may replace files.
    public func addReplaceGrant(_ path: String, draftID: UUID) {
        guard let draft = drafts[draftID], !draft.bindings.replaceGrants.contains(path) else { return }
        mutate(draftID) { $0.bindings.replaceGrants.append(path) }
    }

    public func select(nodeID: String?, in id: UUID) {
        guard drafts[id]?.selectedNodeID != nodeID else { return }
        mutate(id) { $0.selectedNodeID = nodeID }
    }

    public func recordTestRun(_ id: UUID, runID: UUID) {
        var dropped: [UUID] = []
        mutate(id) { draft in
            draft.testRunIDs.append(runID)
            if draft.testRunIDs.count > 20 {
                dropped = Array(draft.testRunIDs.prefix(draft.testRunIDs.count - 20))
                draft.testRunIDs.removeFirst(dropped.count)
            }
        }
        let repair = drafts[id]?.repairRunID
        WorkflowRunStore.shared.deleteRuns(ids: dropped.filter { $0 != repair })
    }

    public func markSaved(_ id: UUID, template: Template) {
        mutate(id) { draft in
            draft.templateID = template.id
            draft.baseVersion = template.version
        }
    }

    /// A note for the Architect's next turn that is not a definition edit.
    public func notePending(_ id: UUID, _ line: String) {
        mutate(id) { $0.pendingUserEdits.append(line) }
    }

    /// The failed run the draft's Architect chat is fixing. `workflow_runs`
    /// `get` and `workflow_test` `from_run` default to it.
    public func setRepairRun(_ id: UUID, runID: UUID?) {
        guard drafts[id]?.repairRunID != runID else { return }
        mutate(id) { $0.repairRunID = runID }
    }

    // MARK: - Seeds for chats without a window

    /// What a draft should start from when an Architect chat is created
    /// without a window to seed it (self-heal dispatches). Keyed by the
    /// dispatch's `externalSessionKey`; claimed by the first draft tool
    /// call in that chat.
    public struct Seed: Sendable {
        public var template: Template
        public var repairRunID: UUID?
    }

    private var seeds: [String: Seed] = [:]

    public func registerSeed(_ seed: Seed, key: String) {
        seeds[key] = seed
    }

    /// The draft for `sessionID`, created from the seed registered under
    /// `key` when the chat has none yet.
    @discardableResult
    public func claimSeed(key: String, sessionID: String) -> WorkflowDraft? {
        guard let seed = seeds.removeValue(forKey: key) else { return nil }
        if let existing = draft(forSession: sessionID) { return existing }
        let draft = create(sessionID: sessionID, from: seed.template)
        if let runID = seed.repairRunID { setRepairRun(draft.id, runID: runID) }
        return self.draft(id: draft.id)
    }

    /// `keepTestRuns` is for a draft replaced by a copy that carries its
    /// test history on.
    public func delete(_ id: UUID, keepTestRuns: Bool = false) {
        let removed = drafts[id]
        drafts[id] = nil
        WorkflowDraftDiskWriter.shared.remove(Self.fileURL(id))
        if let removed, !keepTestRuns {
            WorkflowRunStore.shared.deleteRuns(ids: removed.testRunIDs.filter { $0 != removed.repairRunID })
        }
        SavedAnswersStore.shared.clearAll(workflowID: id)
        WorkflowStateStore.shared.deleteAll(workflow: id)
        if let removed {
            WorkflowCredentials.forget(keys: removed.template().requirements.secrets.map(\.key), scope: id)
        }
        // The draft's sandbox environment is keyed by its template id; keep
        // it when the template is installed (the draft was editing it).
        if let removed, removed.definition.usesSandbox {
            let environmentID = removed.template().id
            guard InstalledWorkflowStore.shared.workflow(templateID: environmentID) == nil else { return }
            Task { await WorkflowSandboxEnvironment.shared.remove(environmentID: environmentID) }
        }
    }

    // MARK: - Save proposals from harness turns

    /// A `workflow_propose_save` that ran over the harness bridge. The
    /// built-in loop raises the Save card from the tool result itself; a
    /// harness turn only streams the call's name, so the chat raises the
    /// card from this when the turn ends.
    public struct SaveProposal: Equatable, Sendable {
        public var draftID: UUID
        public var name: String
        public var version: Int
        public var changelog: String
        public var updates: String?
    }

    private var saveProposals: [UUID: SaveProposal] = [:]

    public func recordSaveProposal(_ proposal: SaveProposal) {
        saveProposals[proposal.draftID] = proposal
    }

    /// The proposal for this chat's draft, once.
    public func takeSaveProposal(sessionID: String?) -> SaveProposal? {
        guard let draft = draft(forSession: sessionID) else { return nil }
        return saveProposals.removeValue(forKey: draft.id)
    }

    // MARK: - Turn context

    /// The user's direct edits and selected node, for the next message to
    /// The Architect. Clears the pending edits.
    public func takeTurnContext(sessionID: String?) -> String? {
        guard let draft = draft(forSession: sessionID) else { return nil }
        var sections: [String] = []
        if !draft.pendingUserEdits.isEmpty {
            sections.append(
                "Since your last turn, in the sidebar:\n"
                    + draft.pendingUserEdits.map { "- \($0)" }.joined(separator: "\n"))
        }
        if let selected = draft.selectedNodeID, let node = draft.definition.node(selected) {
            sections.append(
                "The user has node `\(node.id)` selected:\n```json\n\(WorkflowDiff.pretty(node))\n```")
        }
        guard !sections.isEmpty else { return nil }
        if !draft.pendingUserEdits.isEmpty { mutate(draft.id) { $0.pendingUserEdits = [] } }
        return sections.joined(separator: "\n\n")
    }

    // MARK: - Test bindings

    /// Bindings for a test run: the user's choices on the draft, completed
    /// for this run only. An unbound slot takes the first model that can
    /// run it — the slot's preferred (or default) model, else The
    /// Architect's model — and an unbound secret its draft account. Nothing
    /// is written back: the draft's `bindings` stay what the user chose,
    /// so saving installs those and the setup wizard asks about the rest
    /// instead of a test-time fallback becoming the installed model.
    /// The tests the draft's current steps stand on (`WorkflowTestEvidence`).
    public func testEvidence(_ id: UUID) -> WorkflowTestEvidence {
        guard let draft = drafts[id] else { return .empty }
        let runs = draft.testRunIDs.compactMap { WorkflowRunStore.shared.run(id: $0) }
        let base = draft.templateID.flatMap { templateID -> WorkflowDefinition? in
            if let version = draft.baseVersion, let exact = TemplateStore.shared.template(id: templateID, version: version) {
                return exact.workflow
            }
            return TemplateStore.shared.latest(id: templateID)?.workflow
        }
        let env = SetupChecker.Environment.live()
        var required: [String: String] = [:]
        for slot in draft.template().requirements.models where slot.requiredModel != nil {
            required[slot.slot] = SetupChecker.resolvedModel(for: slot, bindings: draft.bindings, environment: env)
                ?? slot.requiredModel
        }
        return WorkflowTestEvidence.evidence(for: draft, runs: runs, base: base, requiredModels: required)
    }

    public func testBindings(_ id: UUID) -> InstallBindings {
        guard let draft = drafts[id] else { return InstallBindings() }
        return Self.completedForTest(draft, environment: SetupChecker.Environment.live())
    }

    static func completedForTest(_ draft: WorkflowDraft, environment env: SetupChecker.Environment)
        -> InstallBindings
    {
        var bindings = draft.bindings
        let template = draft.template()
        for slot in template.requirements.models where bindings.models[slot.slot] == nil {
            if slot.requiredModel != nil {
                if let required = SetupChecker.resolvedModel(for: slot, bindings: bindings, environment: env),
                    SetupChecker.canBind(required, to: slot, environment: env)
                {
                    bindings.models[slot.slot] = required
                }
                continue
            }
            let candidates = [
                SetupChecker.resolvedModel(for: slot, bindings: bindings, environment: env),
                ArchitectConfigurationStore.load().model,
                AgentManager.shared.effectiveModel(for: Agent.architectId),
            ].compactMap { $0 }
            if let fallback = candidates.first(where: { SetupChecker.canBind($0, to: slot, environment: env) }) {
                bindings.models[slot.slot] = fallback
            }
        }
        for secret in template.requirements.secrets where bindings.secrets[secret.key] == nil {
            bindings.secrets[secret.key] = WorkflowSecretsKeychain.secretAccount(scope: draft.id, key: secret.key)
        }
        return bindings
    }

    // MARK: - Disk

    private func mutate(_ id: UUID, _ change: (inout WorkflowDraft) -> Void) {
        guard var draft = drafts[id] else { return }
        change(&draft)
        draft.updatedAt = Date()
        write(draft)
    }

    private func write(_ draft: WorkflowDraft) {
        drafts[draft.id] = draft
        WorkflowDraftDiskWriter.shared.save(draft, to: Self.fileURL(draft.id))
    }

    /// Blocks until every draft write queued so far has landed, bounded by
    /// `timeout`. Called at quit, where `_exit` would skip a pending write.
    nonisolated public static func flushPendingWrites(timeout: TimeInterval = 3.0) {
        WorkflowDraftDiskWriter.shared.flush(timeout: timeout)
    }

    func resetForTesting() {
        drafts = [:]
    }
}

/// Writes draft files off the main actor. A draft carries its undo history,
/// so encoding it on every Architect patch stalled the UI. Pending writes to
/// one file collapse to the latest draft; writes and removals run in order.
final class WorkflowDraftDiskWriter: @unchecked Sendable {
    static let shared = WorkflowDraftDiskWriter()

    private let queue = DispatchQueue(label: "ai.osaurus.workflow-draft-write", qos: .utility)
    private let lock = NSLock()
    private var pending: [URL: WorkflowDraft] = [:]

    func save(_ draft: WorkflowDraft, to url: URL) {
        let scheduled = lock.withLock {
            let scheduled = pending[url] != nil
            pending[url] = draft
            return scheduled
        }
        guard !scheduled else { return }
        queue.async { self.drain(url) }
    }

    func remove(_ url: URL) {
        lock.withLock { pending[url] = nil }
        queue.async { try? FileManager.default.removeItem(at: url) }
    }

    /// Waits for everything queued so far; with no `timeout`, as long as it takes.
    func flush(timeout: TimeInterval? = nil) {
        guard let timeout else { return queue.sync {} }
        let done = DispatchSemaphore(value: 0)
        queue.async { done.signal() }
        _ = done.wait(timeout: .now() + timeout)
    }

    private func drain(_ url: URL) {
        guard let draft = lock.withLock({ pending.removeValue(forKey: url) }) else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            try OsaurusPaths.ensureExists(url.deletingLastPathComponent())
            try encoder.encode(draft).write(to: url, options: .atomic)
        } catch {
            print("[Osaurus] Failed to save workflow draft: \(error)")
        }
    }
}

/// The saved workflow a draft edits: saving makes its next version.
struct DraftEditing: Equatable {
    let name: String
    /// The saved version the draft started from.
    let version: Int

    @MainActor
    init?(_ draft: WorkflowDraft) {
        guard let templateID = draft.templateID else { return nil }
        let saved = TemplateStore.shared.latest(id: templateID)
        name = saved?.name ?? draft.name
        version = draft.baseVersion ?? saved?.version ?? 1
    }

    /// "Editing v2", naming the saved workflow once the draft is renamed.
    func label(draftName: String) -> String {
        draftName == name ? L("Editing v\(version)") : L("Editing \(name) v\(version)")
    }
}
