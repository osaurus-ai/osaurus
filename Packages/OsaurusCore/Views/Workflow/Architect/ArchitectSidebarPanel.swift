//
//  ArchitectSidebarPanel.swift
//  osaurus
//
//  The draft half of an Architect chat: the living preview
//  (`ArchitectPreviewPanel`), the workflow as the person will use it,
//  building itself while the Architect works. Its depth opens in place: a
//  step opens into its model, instructions, and actions; what it touches,
//  what it uses, and its changes open under the steps. It edits the same
//  draft the Architect's tools patch, and the next turn hears about it.
//

import SwiftUI

enum WorkflowCanvasLayout {
    /// The draft's column grows with its pane up to this width; past it the
    /// creation split gives the extra room to the chat.
    static let columnWidth: CGFloat = 880
}

/// Hosts the preview and what it opens: setup, and Share for a saved
/// workflow.
struct ArchitectSidebarPanel: View {
    let sessionId: UUID?
    var isGenerating = false
    /// Puts text in the Architect chat's composer.
    var onAsk: ((String) -> Void)?
    /// Sends a message to the Architect chat.
    var onSend: ((String) -> Void)?
    /// Shows the Workflows lens, to pick a saved workflow to change.
    var onBrowse: (() -> Void)?

    /// How long the preview stays in Building after a turn ends, so it
    /// doesn't flicker between the Architect's tool rounds.
    static let buildingGrace: TimeInterval = 0.4

    @ObservedObject private var drafts = WorkflowDraftStore.shared
    @State private var isBuilding = false
    @State private var buildingTurn = 0
    @State private var setupSubject: WorkflowSetupSubject?
    @State private var sharing: ArchitectShareSheetRequest?
    @Environment(\.theme) private var theme

    private var draft: WorkflowDraft? { drafts.draft(forSession: sessionId?.uuidString) }

    /// Nothing drafted yet: no steps, nothing to fill in, nothing it gives back.
    static func hasNothingDrafted(_ definition: WorkflowDefinition) -> Bool {
        func noFields(_ schema: JSONValue) -> Bool { schema.objectValue?["properties"]?.objectValue?.isEmpty ?? true }
        return definition.nodes.isEmpty && noFields(definition.inputSchema) && noFields(definition.outputSchema)
    }

    var body: some View {
        ArchitectPreviewPanel(
            sessionId: sessionId, isGenerating: isBuilding, onAsk: onAsk, onSend: onSend,
            onSetUp: { draft in setupSubject = .draft(draft) },
            onBrowse: onBrowse)
            .onAppear {
                isBuilding = isGenerating
                presentRequestedSetup()
                presentRequestedShare()
            }
            .onChange(of: isGenerating) { _, generating in
                buildingTurn += 1
                if generating {
                    isBuilding = true
                } else {
                    let turn = buildingTurn
                    DispatchQueue.main.asyncAfter(deadline: .now() + Self.buildingGrace) {
                        if buildingTurn == turn { isBuilding = false }
                    }
                }
            }
            .onChange(of: drafts.setupRequest) { _, _ in presentRequestedSetup() }
            .onChange(of: drafts.shareRequest) { _, _ in presentRequestedShare() }
            .sheet(item: $setupSubject) { subject in
                WorkflowSetupWizardView(subject: subject, onClose: { setupSubject = nil })
            }
            .sheet(item: $sharing) { request in
                ShareWorkflowSheet(
                    template: request.template, bindings: request.bindings, entry: request.entry,
                    onDone: { sharing = nil }
                )
                .environment(\.theme, theme)
            }
    }

    private func presentRequestedSetup() {
        guard let draft, drafts.setupRequest == draft.id else { return }
        drafts.setupRequest = nil
        setupSubject = .draft(draft)
    }

    private func presentRequestedShare() {
        guard let draft, let request = drafts.shareRequest, request.draftID == draft.id else { return }
        drafts.shareRequest = nil
        sharing = ArchitectShareSheetRequest(draft: draft, resubmits: request.resubmits)
    }
}

/// What Share opens on for a saved draft: its latest saved version, the
/// install's bindings, and the manage page once it is published.
struct ArchitectShareSheetRequest: Identifiable {
    let id = UUID()
    let template: Template
    let bindings: InstallBindings?
    let entry: ShareWorkflowSheet.Entry

    @MainActor
    init?(draft: WorkflowDraft, resubmits: Bool = false) {
        guard let templateID = draft.templateID else { return nil }
        let installed = InstalledWorkflowStore.shared.workflow(templateID: templateID)
        guard let template = installed?.template ?? TemplateStore.shared.latest(id: templateID) else { return nil }
        self.template = template
        bindings = installed?.bindings
        if resubmits {
            entry = .publish
        } else {
            entry = WorkflowRegistryRecordStore.shared.record(for: templateID) != nil ? .manage : .choose
        }
    }
}

// MARK: - Status

/// Where the draft stands, which the preview's phase is derived from.
struct DraftStatus {
    enum Kind: Equatable { case drafting, needsSetup, ready, testing, tested, testFailed }

    let kind: Kind
    /// Why it can't run yet, in the validator's words.
    let issues: [String]
    let blockers: [SetupItem]
    let nameMissing: Bool

    @MainActor
    init(draft: WorkflowDraft, latest: WorkflowRun?) {
        let def = draft.definition
        issues =
            def.nodes.isEmpty
            ? [] : WorkflowValidator.validate(def, allowPlaceholders: false).map(\.message)
        blockers =
            SetupChecker.check(DraftRevisionCache.template(draft), bindings: draft.bindings, subjectId: draft.id, agentsByName: true).blocking
        nameMissing = draft.name.trimmingCharacters(in: .whitespaces).isEmpty
        // A rename or summary edit doesn't invalidate a passing test.
        let lastEdit = WorkflowTestEvidence.stepsChangedAt(draft) ?? draft.createdAt
        let current = latest.flatMap { $0.startedAt >= lastEdit ? $0 : nil }
        if let latest, !latest.status.isTerminal {
            kind = .testing
        } else if def.nodes.isEmpty || !issues.isEmpty {
            kind = .drafting
        } else if !blockers.isEmpty {
            kind = .needsSetup
        } else if current?.status == .completed {
            kind = .tested
        } else if current?.status == .failed {
            kind = .testFailed
        } else {
            kind = .ready
        }
    }

    var canSave: Bool { saveBlocker == nil }

    var saveBlocker: String? {
        if nameMissing { return L("Name the workflow first.") }
        if kind == .drafting { return issues.first ?? L("Add a step first.") }
        return nil
    }
}

/// What the draft pane reads several times per redraw, built once per draft
/// revision. Validating, deriving requirements, and hashing the definition
/// on every publish stalled the pane while the Architect patched.
@MainActor
enum DraftRevisionCache {
    private struct StatusKey: Equatable {
        let updatedAt: Date
        let runID: UUID?
        let runStatus: WorkflowRunStatus?
    }

    /// Setup blockers also read the machine (models, keys, tools), which no
    /// draft revision records, so a status is rebuilt at least this often.
    static let statusLifetime: TimeInterval = 1

    private static var templates: [UUID: (updatedAt: Date, template: Template)] = [:]
    private static var statuses: [UUID: (key: StatusKey, builtAt: Date, status: DraftStatus)] = [:]

    static func template(_ draft: WorkflowDraft) -> Template {
        if let cached = templates[draft.id], cached.updatedAt == draft.updatedAt { return cached.template }
        let template = draft.template()
        templates[draft.id] = (draft.updatedAt, template)
        return template
    }

    static func status(_ draft: WorkflowDraft, latest: WorkflowRun?, now: Date = Date()) -> DraftStatus {
        let key = StatusKey(updatedAt: draft.updatedAt, runID: latest?.id, runStatus: latest?.status)
        if let cached = statuses[draft.id], cached.key == key,
            now.timeIntervalSince(cached.builtAt) < statusLifetime
        {
            return cached.status
        }
        let status = DraftStatus(draft: draft, latest: latest)
        statuses[draft.id] = (key, now, status)
        return status
    }

    private static var savedStates: [UUID: (updatedAt: Date, builtAt: Date, state: DraftSavedState)] = [:]

    /// Publishing changes the registry, not the draft, so this too is
    /// rebuilt at least every `statusLifetime`.
    static func savedState(_ draft: WorkflowDraft, now: Date = Date()) -> DraftSavedState {
        if let cached = savedStates[draft.id], cached.updatedAt == draft.updatedAt,
            now.timeIntervalSince(cached.builtAt) < statusLifetime
        {
            return cached.state
        }
        let state = DraftSavedState.live(draft)
        savedStates[draft.id] = (draft.updatedAt, now, state)
        return state
    }
}

/// An open step: the model it runs on, a glance at its instructions, and
/// the ways to change it.
struct DraftStepDetail: View {
    let draft: WorkflowDraft
    let node: WorkflowNode
    let onEdit: (String) -> Void
    let onAsk: ((String) -> Void)?

    @Environment(\.theme) private var theme

    /// Runs this step and the ones after it again, reusing the latest
    /// test's results for the steps before it.
    private func testFromHere() {
        switch WorkflowDraftTester.startFromStep(draftID: draft.id, nodeID: node.id, sessionID: draft.sessionID) {
        case .success: break
        case .failure(let refusal): ToastManager.shared.error(L("Can't Test From This Step"), message: refusal.message)
        }
    }

    /// What the step does, in the Architect's words.
    static func description(_ node: WorkflowNode) -> String? {
        if let intent = node.intent?.trimmingCharacters(in: .whitespacesAndNewlines), !intent.isEmpty {
            return intent
        }
        if case .dialog(let spec) = node.kind, !spec.message.isEmpty { return spec.message }
        return nil
    }

    /// "Uses a model · Apple Foundation Models (this Mac)"
    @MainActor
    static func meta(_ node: WorkflowNode, in draft: WorkflowDraft) -> String {
        let kind = WorkflowSummary.kind(node)
        guard case .inference(let spec) = node.kind else { return kind }
        let model =
            draft.bindings.models[spec.modelSlot]
            ?? DraftRevisionCache.template(draft).requirements.models.first { $0.slot == spec.modelSlot }?.preferred
        return model.map { "\(kind) · \(WorkflowModelChoices.runsOn($0))" } ?? kind
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s10) {
            if case .inference(let spec) = node.kind {
                VStack(alignment: .leading, spacing: theme.space.s4) {
                    label(L("Runs on"))
                    WorkflowStepModelMenu(draftID: draft.id, node: node, slotID: spec.modelSlot)
                }
                if !spec.instructions.isEmpty {
                    VStack(alignment: .leading, spacing: theme.space.s4) {
                        label(L("Instructions"))
                        Text(verbatim: spec.instructions)
                            .textStyle(.caption)
                            .foregroundColor(theme.text.secondary)
                            .lineLimit(4)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(theme.space.s8)
                            .settingsChrome(.inset)
                    }
                }
            }
            HStack(spacing: theme.space.s8) {
                SettingsButton(.secondary, "Edit Step…", size: .compact) { onEdit(node.id) }
                Spacer()
                SettingsOverflowMenu(help: "More", size: .compact) {
                    if let onAsk {
                        Button {
                            onAsk(L("About the “\(node.name)” step: "))
                        } label: {
                            Text("Ask the Architect", bundle: .module)
                        }
                        Divider()
                    }
                    if node.kind != nil {
                        Button {
                            testFromHere()
                        } label: {
                            Text("Test From This Step", bundle: .module)
                        }
                        .disabled(draft.testRunIDs.isEmpty)
                        Button {
                            WorkflowStepActions.setBypassed(node.mode != .bypass, node, in: draft.id)
                        } label: {
                            Text(node.mode == .bypass ? "Run This Step" : "Bypass This Step", bundle: .module)
                        }
                        Divider()
                    }
                    Button(role: .destructive) {
                        WorkflowStepActions.delete(node, in: draft.id)
                    } label: {
                        Text("Delete Step", bundle: .module)
                    }
                }
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(verbatim: text)
            .textStyle(.footnote, weight: 500)
            .foregroundColor(theme.text.tertiary)
    }
}

/// The real form, filled with the first example, in a popover.
struct DraftFormPreviewButton: View {
    let definition: WorkflowDefinition
    let fields: [DialogField]

    @State private var showsPreview = false
    @State private var previewValues: [String: JSONValue] = [:]
    @Environment(\.theme) private var theme

    var body: some View {
        if !fields.isEmpty {
            SettingsButton(.tertiary, "Preview Form", size: .compact) {
                previewValues = WorkflowFormFields.initialValues(
                    fields, prefill: definition.examples.first?.input.objectValue ?? [:])
                showsPreview = true
            }
            .popover(isPresented: $showsPreview, arrowEdge: .leading) {
                ScrollView {
                    WorkflowFormView(fields: fields, values: $previewValues)
                        .padding(theme.space.s16)
                }
                .frame(width: 340)
                .frame(maxHeight: 480)
            }
        }
    }
}

// MARK: - Changes

/// Every edit to the draft, newest first: who made it, why (when the
/// Architect said), and each change in the diff's words. The newest can
/// be undone from here.
struct DraftChangeList: View {
    let draft: WorkflowDraft

    @ObservedObject private var drafts = WorkflowDraftStore.shared
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s8) {
            ForEach(Array(draft.history.enumerated().reversed()), id: \.offset) { index, edit in
                row(edit, isNewest: index == draft.history.count - 1)
            }
        }
    }

    private func row(_ edit: WorkflowDraftEdit, isNewest: Bool) -> some View {
        let lines = edit.lines.isEmpty ? edit.summary.components(separatedBy: "; ").filter { !$0.isEmpty } : edit.lines
        return VStack(alignment: .leading, spacing: theme.space.s4) {
            HStack(spacing: theme.space.s6) {
                Image(systemName: edit.source == .architect ? "wand.and.stars" : "person")
                    .glyphSize(.tiny)
                    .foregroundColor(theme.text.tertiary)
                Text(edit.source == .architect ? "The Architect" : "You", bundle: .module)
                    .textStyle(.caption, weight: 600)
                    .foregroundColor(theme.text.primary)
                Text(edit.at, style: .time)
                    .textStyle(.footnote)
                    .foregroundColor(theme.text.tertiary)
                Spacer()
                if isNewest {
                    SettingsButton(.tertiary, "Undo", size: .compact) { drafts.undo(draft.id) }
                }
            }
            if let why = edit.why, !why.isEmpty {
                Text(verbatim: why)
                    .textStyle(.caption)
                    .foregroundColor(theme.text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(lines.prefix(8).enumerated()), id: \.offset) { _, line in
                HStack(alignment: .firstTextBaseline, spacing: theme.space.s6) {
                    Text(verbatim: "•").foregroundColor(theme.text.tertiary)
                    Text(verbatim: line).fixedSize(horizontal: false, vertical: true)
                }
                .textStyle(.footnote)
                .foregroundColor(theme.text.secondary)
            }
            if lines.count > 8 {
                Text(verbatim: L("and \(lines.count - 8) more"))
                    .textStyle(.footnote)
                    .foregroundColor(theme.text.tertiary)
            }
        }
        .padding(theme.space.s12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsChrome(.inset)
    }
}
