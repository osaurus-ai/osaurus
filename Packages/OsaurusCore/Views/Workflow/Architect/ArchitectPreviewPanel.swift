//
//  ArchitectPreviewPanel.swift
//  osaurus
//
//  The living preview: the workflow being made, shown as the thing the
//  person will use, not as an editor. A card with its name and what it
//  does builds itself while the Architect works, then asks for one thing
//  at a time: set something up, try it, fix it, add it, share it. Depth
//  opens in place: a step opens into its settings, and what it touches,
//  what it uses, and its changes open at the foot of the card.
//

import AppKit
import SwiftUI

struct ArchitectPreviewPanel: View {
    let sessionId: UUID?
    var isGenerating = false
    var onAsk: ((String) -> Void)?
    var onSend: ((String) -> Void)?
    /// Opens the setup wizard for the draft.
    var onSetUp: ((WorkflowDraft) -> Void)?
    /// Shows the Workflows lens, to pick a saved workflow to change.
    var onBrowse: (() -> Void)?

    enum MoreSection: Hashable { case files, uses, changes }

    /// The preview's reading column.
    static let columnWidth: CGFloat = 560

    @ObservedObject private var drafts = WorkflowDraftStore.shared
    @ObservedObject private var runs = WorkflowRunStore.shared
    @ObservedObject private var registry = WorkflowRegistryRecordStore.shared
    @ObservedObject private var installed = InstalledWorkflowStore.shared
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var nameDraft = ""
    @FocusState private var nameFocused: Bool
    @State private var values: [String: JSONValue] = [:]
    @State private var issues: [String: String] = [:]
    @State private var formError: String?
    /// Shows the form again after a try, to change what it is given.
    @State private var editsInput = false
    @State private var includeTrigger = true
    @State private var addError: String?
    @State private var lastAdd: WorkflowSavePromptState?
    @State private var celebrates = false
    @State private var openMore: Set<MoreSection> = []
    @State private var editingNodeID: String?

    private var draft: WorkflowDraft? { drafts.draft(forSession: sessionId?.uuidString) }

    var body: some View {
        let draft = draft
        let latest = draft.flatMap(latestRun)
        let status = draft.map { DraftRevisionCache.status($0, latest: latest) }
        let phase =
            draft.flatMap { d in status.map { ArchitectPreviewPhase.derive(draft: d, status: $0, isGenerating: isGenerating) } }
            ?? .imagining
        ScrollView {
            VStack(spacing: theme.space.s20) {
                WorkflowStageStepper(stage: phase.stage, isActive: phase.isActive, isComplete: phase == .live)
                card(draft, phase: phase, status: status, latest: latest)
            }
            .frame(maxWidth: Self.columnWidth)
            .padding(.horizontal, theme.space.s8)
            .padding(.vertical, theme.space.s16)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .overlay { ArchitectCelebrationBurst(trigger: celebrates) }
        .animation(reduceMotion ? nil : theme.motion.springAnimation, value: phase)
        .onAppear {
            nameDraft = draft?.name ?? ""
            if let draft { prefill(draft, latest: latest) }
        }
        .onChange(of: draft?.name) { _, name in nameDraft = name ?? "" }
        .onChange(of: draft?.definition.inputSchema) { _, _ in if let draft { prefill(draft, latest: nil) } }
        .onChange(of: draft?.testRunIDs.last) { _, _ in
            editsInput = false
            if let draft, let latest = latestRun(draft) { adopt(latest, draft: draft) }
        }
        .onChange(of: phase) { old, new in
            if new == .added, old == .worked || old == .trying {
                celebrates = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { celebrates = false }
            }
            if new == .building { editingNodeID = nil }
        }
        .sheet(
            isPresented: Binding(get: { editingNodeID != nil }, set: { if !$0 { editingNodeID = nil } })
        ) {
            if let draft, let id = editingNodeID, let node = draft.definition.node(id) {
                WorkflowNodeEditor(draftID: draft.id, node: node) { editingNodeID = nil }
            }
        }
    }

    // MARK: - Card

    private func card(_ draft: WorkflowDraft?, phase: ArchitectPreviewPhase, status: DraftStatus?, latest: WorkflowRun?)
        -> some View
    {
        VStack(alignment: .leading, spacing: theme.space.s0) {
            VStack(alignment: .leading, spacing: theme.space.s20) {
                header(draft, phase: phase)
                if let draft, let status {
                    phaseBody(draft, phase: phase, status: status, latest: latest)
                        .transition(.opacity)
                } else {
                    imagining
                }
            }
            .padding(theme.space.s20)
            if let draft, phase != .imagining, !draft.definition.nodes.isEmpty {
                ThemeHairlineDivider()
                moreAboutIt(draft)
            }
            ThemeHairlineDivider()
            footer(draft, phase: phase, status: status, latest: latest)
                .padding(.horizontal, theme.space.s20)
                .padding(.vertical, theme.space.s12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsChrome(.canvas)
        .architectTracing(isActive: phase == .imagining && isGenerating || phase == .building)
        .allowsHitTesting(phase != .building)
        .accessibilityElement(children: .contain)
    }

    /// The workflow as it will sit in My Workflows: its icon, name, and
    /// what it does. Only the chip changes as it moves along.
    private func header(_ draft: WorkflowDraft?, phase: ArchitectPreviewPhase) -> some View {
        HStack(alignment: .top, spacing: theme.space.s12) {
            LibraryIcon(symbol: "flowchart", tint: theme.statusInk(.info), size: theme.space.s40)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: theme.space.s4) {
                if draft == nil || draft?.name.isEmpty == true, phase == .imagining {
                    SettingsSkeletonBar(width: theme.space.s48 * 3, height: theme.space.s16)
                        .settingsShimmer()
                } else {
                    SettingsTitleField(
                        placeholder: L("Untitled Workflow"), text: $nameDraft, focus: $nameFocused,
                        onCommit: { commitName(draft) })
                    .accessibilityLabel(Text("Workflow name", bundle: .module))
                    .help(L("Rename the workflow"))
                    .disabled(phase == .building)
                }
                let summary = draft?.summary.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !summary.isEmpty {
                    Text(verbatim: summary)
                        .textStyle(.body)
                        .foregroundStyle(theme.text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if phase == .imagining {
                    SettingsSkeletonBar(height: theme.space.s10)
                        .settingsShimmer(delay: 0.15)
                }
                if let draft, phase != .added, phase != .live, let editing = DraftEditing(draft) {
                    Text(verbatim: editing.label(draftName: draft.name))
                        .textStyle(.caption)
                        .foregroundStyle(theme.text.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(L("Adding it updates that workflow. Choose Save as New Workflow in the … menu to keep it as it is."))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: theme.space.s4) {
                if let chip = Self.chip(phase) {
                    StatusChip(chip.text, tone: chip.tone, showsDot: true, pulses: chip.pulses)
                        .fixedSize()
                }
                menu(draft)
            }
        }
    }

    @ViewBuilder
    private func menu(_ draft: WorkflowDraft?) -> some View {
        if let draft, !ArchitectSidebarPanel.hasNothingDrafted(draft.definition) {
            SettingsOverflowMenu(help: "More", size: .small) {
                Button {
                    drafts.undo(draft.id)
                } label: {
                    Text(verbatim: WorkflowStepActions.undoTitle(draft) ?? L("Undo"))
                }
                .disabled(draft.history.isEmpty)
                Button {
                    onSetUp?(draft)
                } label: {
                    Text("Set Up…", bundle: .module)
                }
                if draft.templateID != nil {
                    Divider()
                    Button {
                        drafts.detach(draft.id)
                    } label: {
                        Text("Save as New Workflow", bundle: .module)
                    }
                }
            }
        } else if let onBrowse {
            SettingsOverflowMenu(help: "More", size: .small) {
                Button(action: onBrowse) { Text("Change a Saved Workflow…", bundle: .module) }
            }
        }
    }

    struct Chip: Equatable {
        let text: String
        let tone: StatusChip.Tone
        var pulses = false
    }

    /// Where the workflow is, in two words.
    static func chip(_ phase: ArchitectPreviewPhase) -> Chip? {
        switch phase {
        case .imagining: return nil
        case .building: return Chip(text: L("Building"), tone: .info, pulses: true)
        case .needsSomething: return Chip(text: L("Needs setup"), tone: .warning)
        case .almostThere: return Chip(text: L("Unfinished"), tone: .neutral)
        case .readyToTry: return Chip(text: L("Ready to try"), tone: .info)
        case .trying: return Chip(text: L("Trying"), tone: .info, pulses: true)
        case .didntWork: return Chip(text: L("Didn't work"), tone: .error)
        case .worked: return Chip(text: L("Works"), tone: .success)
        case .added: return Chip(text: L("In My Workflows"), tone: .success)
        case .live: return Chip(text: L("Live"), tone: .success)
        }
    }

    // MARK: - Footer

    /// Every action sits here, the next step on the right; while the
    /// Architect works, what it is doing instead.
    private func footer(_ draft: WorkflowDraft?, phase: ArchitectPreviewPhase, status: DraftStatus?, latest: WorkflowRun?)
        -> some View
    {
        HStack(spacing: theme.space.s8) {
            switch phase {
            case .imagining:
                liveLineView(
                    isGenerating ? L("Sketching your workflow…") : L("Describe it in the chat and it takes shape here."),
                    spins: isGenerating)
                Spacer(minLength: theme.space.s0)
            case .building:
                liveLineView(draft.map { Self.liveLine($0, latest: latest) } ?? L("Planning the steps…"), spins: true)
                Spacer(minLength: theme.space.s0)
            default:
                Spacer(minLength: theme.space.s0)
                if let draft, let status {
                    actions(draft, phase: phase, status: status, latest: latest)
                }
            }
        }
        .frame(minHeight: theme.space.s32)
    }

    @ViewBuilder
    private func actions(_ draft: WorkflowDraft, phase: ArchitectPreviewPhase, status: DraftStatus, latest: WorkflowRun?)
        -> some View
    {
        switch phase {
        case .imagining, .building:
            EmptyView()
        case .needsSomething:
            SettingsButton(.primary, "Set Up…", icon: "wrench.and.screwdriver") { onSetUp?(draft) }
                .keyboardShortcut(.defaultAction)
        case .almostThere:
            if let onSend {
                SettingsButton(.primary, "Finish It", icon: "wand.and.stars") {
                    onSend(L("Please finish the workflow so I can try it."))
                }
            }
        case .readyToTry:
            SettingsButton(.primary, "Try It", icon: "play.fill", help: L("Run it once on what you entered")) {
                tryIt(draft)
            }
            .keyboardShortcut(.defaultAction)
        case .trying:
            if let latest {
                SettingsButton(.secondary, "Stop", icon: "stop.fill") { WorkflowRunService.shared.cancel(latest.id) }
            }
        case .didntWork:
            if !editsInput {
                SettingsButton(.tertiary, "Change Input") { editsInput = true }
            }
            SettingsButton(.secondary, "Try Again", icon: "arrow.clockwise") { tryIt(draft) }
            if let latest, let onSend {
                SettingsButton(.primary, "Fix It", icon: "wand.and.stars", help: L("Ask the Architect to fix what went wrong")) {
                    drafts.setRepairRun(draft.id, runID: latest.id)
                    drafts.notePending(draft.id, WorkflowRepairBrief.note(latest, workflowName: draft.name))
                    onSend(WorkflowRepairBrief.message(latest, definition: draft.definition))
                }
            }
        case .worked:
            let evidence = drafts.testEvidence(draft.id)
            if editsInput {
                SettingsButton(.secondary, "Try Again", icon: "arrow.clockwise") { tryIt(draft) }
            } else {
                SettingsButton(.tertiary, "Change Input") { editsInput = true }
            }
            SettingsButton(
                .primary, draft.templateID == nil ? "Add to My Workflows" : "Update My Workflow",
                icon: "plus.circle.fill",
                help: L("Keep it on this Mac, ready to run any time")
            ) { add(draft, trigger: WorkflowDraftTrigger.proposed(for: draft.id), evidence: evidence) }
            .disabled(!evidence.satisfied)
            .keyboardShortcut(.defaultAction)
        case .added:
            SettingsButton(.secondary, "Run…", icon: "play.fill", help: L("Open its form, filled with the example")) {
                runIt(draft)
            }
            SettingsButton(.primary, "Share…", icon: "square.and.arrow.up", help: L("Save it as a file, or publish a page you control")) {
                drafts.shareRequest = WorkflowShareRequest(draftID: draft.id)
            }
            .keyboardShortcut(.defaultAction)
            .settingsLandingAnchor("workflows.shareAfterSave")
        case .live:
            let record = draft.templateID.flatMap { registry.record(for: $0) }
            SettingsButton(.secondary, "Manage…", help: L("Change who can see it, publish a new version, or take it down")) {
                drafts.shareRequest = WorkflowShareRequest(draftID: draft.id)
            }
            if let record {
                SettingsButton(.primary, "Copy Link", icon: "link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(record.url.absoluteString, forType: .string)
                    ToastManager.shared.success(L("Link copied"))
                }
            }
        }
    }

    /// What sits above the steps, the steps, and what sits below them. The
    /// steps are one view across every phase so a try lights them up in
    /// place instead of swapping in a second copy.
    @ViewBuilder
    private func phaseBody(_ draft: WorkflowDraft, phase: ArchitectPreviewPhase, status: DraftStatus, latest: WorkflowRun?)
        -> some View
    {
        if phase == .imagining {
            imagining
        } else {
            VStack(alignment: .leading, spacing: theme.space.s20) {
                aboveSteps(draft, phase: phase, latest: latest)
                steps(draft, phase: phase, latest: latest)
                belowSteps(draft, phase: phase, status: status)
            }
        }
    }

    @ViewBuilder
    private func aboveSteps(_ draft: WorkflowDraft, phase: ArchitectPreviewPhase, latest: WorkflowRun?) -> some View {
        switch phase {
        case .imagining:
            EmptyView()
        case .building, .needsSomething, .almostThere, .added:
            contract(draft)
        case .readyToTry:
            if WorkflowFormFields.fields(fromInputSchema: draft.definition.inputSchema).isEmpty {
                contract(draft)
            } else {
                inputForm(draft)
            }
        case .trying:
            if let latest { WorkflowRunProgressBar(run: latest) }
        case .didntWork:
            failure(draft, latest: latest)
        case .worked:
            result(draft, latest: latest)
            if editsInput { inputForm(draft) }
        case .live:
            contract(draft)
            page(draft)
        }
    }

    @ViewBuilder
    private func belowSteps(_ draft: WorkflowDraft, phase: ArchitectPreviewPhase, status: DraftStatus) -> some View {
        switch phase {
        case .needsSomething:
            blockers(status)
        case .almostThere:
            note(L("The Architect stopped before it was done. Finish it, or say what's missing in the chat."))
        case .didntWork:
            if editsInput { inputForm(draft) }
        case .worked:
            addNotes(draft)
        case .added:
            if let triggerNote = lastAdd?.triggerNote { note(triggerNote) }
        case .imagining, .building, .readyToTry, .trying, .live:
            EmptyView()
        }
    }

    // MARK: - Making it

    private var imagining: some View {
        VStack(alignment: .leading, spacing: theme.space.s12) {
            ForEach(0..<3, id: \.self) { index in
                HStack(spacing: theme.space.s12) {
                    SettingsSkeletonBar(width: theme.space.s20, height: theme.space.s20)
                    SettingsSkeletonBar(width: theme.space.s48 * CGFloat(4 - index), height: theme.space.s10)
                }
                .settingsShimmer(delay: Double(index) * 0.15)
            }
        }
        .accessibilityHidden(true)
    }

    private func blockers(_ status: DraftStatus) -> some View {
        section(L("Before it can run")) {
            VStack(alignment: .leading, spacing: theme.space.s8) {
                ForEach(status.blockers) { item in
                    HStack(alignment: .top, spacing: theme.space.s8) {
                        Image(systemName: "circle.dashed")
                            .glyphSize(.caption)
                            .foregroundStyle(theme.text.tertiary)
                            .padding(.top, theme.space.s2)
                        VStack(alignment: .leading, spacing: theme.space.s2) {
                            Text(verbatim: item.title)
                                .textStyle(.label, weight: 500)
                                .foregroundStyle(theme.text.primary)
                            if !item.detail.isEmpty {
                                Text(verbatim: item.detail)
                                    .textStyle(.caption)
                                    .foregroundStyle(theme.text.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: theme.space.s0)
                    }
                }
            }
            .padding(theme.space.s12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .settingsChrome(.inset)
        }
    }

    // MARK: - Trying it

    private func failure(_ draft: WorkflowDraft, latest: WorkflowRun?) -> some View {
        let failedStep = latest?.error?.nodeID.flatMap { draft.definition.node($0)?.name }
        let reason = latest?.error?.reason.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return VStack(alignment: .leading, spacing: theme.space.s4) {
            Text(verbatim: failedStep.map { L("It stopped at “\($0)”.") } ?? L("It stopped before it finished."))
                .textStyle(.label, weight: 600)
                .foregroundStyle(theme.text.primary)
            if !reason.isEmpty {
                Text(verbatim: reason)
                    .textStyle(.caption)
                    .foregroundStyle(theme.text.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            note(L("The Architect can find the problem and fix it."))
        }
        .padding(theme.space.s12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsChrome(.status(.error))
    }

    @ViewBuilder
    private func result(_ draft: WorkflowDraft, latest: WorkflowRun?) -> some View {
        if let output = latest?.output {
            section(L("Result")) {
                WorkflowResultCard(
                    output: output, schema: draft.definition.outputSchema, showsTitle: false,
                    files: latest?.artifacts ?? [])
                .padding(theme.space.s12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .settingsChrome(.inset)
                .architectGlowIn(trigger: latest?.id)
            }
        }
    }

    private func addNotes(_ draft: WorkflowDraft) -> some View {
        let evidence = drafts.testEvidence(draft.id)
        let trigger = WorkflowDraftTrigger.proposed(for: draft.id)
        return VStack(alignment: .leading, spacing: theme.space.s8) {
            if let notice = WorkflowDraftSaver.renameNotice(for: draft) {
                WorkflowRenameNotice(text: notice)
            }
            if let trigger {
                WorkflowSaveTriggerRow(trigger: trigger, isOn: $includeTrigger)
            }
            if let blocker = evidence.blocker {
                note(blocker)
            }
            if let addError {
                Text(verbatim: addError)
                    .textStyle(.caption)
                    .foregroundStyle(theme.statusInk(.error))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Sharing it

    @ViewBuilder
    private func page(_ draft: WorkflowDraft) -> some View {
        if let record = draft.templateID.flatMap({ registry.record(for: $0) }) {
            section(L("Its page")) {
                HStack(spacing: theme.space.s8) {
                    Text(verbatim: record.url.absoluteString)
                        .textStyle(.caption)
                        .foregroundStyle(theme.text.link)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer(minLength: theme.space.s8)
                    if let installs = record.installCount, installs > 0 {
                        Text(verbatim: installs == 1 ? L("1 install") : L("\(installs) installs"))
                            .textStyle(.caption)
                            .foregroundStyle(theme.text.tertiary)
                    }
                }
                .padding(theme.space.s12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .settingsChrome(.inset)
            }
        }
    }

    // MARK: - Pieces

    @ViewBuilder
    private func inputForm(_ draft: WorkflowDraft) -> some View {
        let fields = WorkflowFormFields.fields(fromInputSchema: draft.definition.inputSchema)
        section(L("Try it with")) {
            VStack(alignment: .leading, spacing: theme.space.s8) {
                if fields.isEmpty {
                    note(L("Nothing. It runs on its own."))
                } else {
                    WorkflowFormView(
                        fields: fields, values: $values, issues: issues,
                        onSubmit: { tryIt(draft) },
                        accessCaptions: WorkflowAccessScope.derive(draft.definition).inputCaptions)
                    if draft.definition.examples.count > 1 {
                        SettingsMenuButton(.tertiary, "Fill with Example", size: .compact) {
                            ForEach(draft.definition.examples, id: \.name) { example in
                                Button(example.name) {
                                    values = WorkflowFormFields.initialValues(fields, prefill: example.input.objectValue ?? [:])
                                    issues = [:]
                                }
                            }
                        }
                    }
                }
                if let formError {
                    Text(verbatim: formError)
                        .textStyle(.caption)
                        .foregroundStyle(theme.statusInk(.error))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// The steps; each opens in place to its model, instructions, and
    /// actions. The open step is also what the Architect hears is selected.
    /// While the Architect builds or a try runs they only read.
    @ViewBuilder
    private func steps(_ draft: WorkflowDraft, phase: ArchitectPreviewPhase, latest: WorkflowRun?) -> some View {
        if !draft.definition.nodes.isEmpty {
            let readOnly = phase == .building || phase == .trying
            let run: WorkflowRun? =
                switch phase {
                case .building: latest.flatMap { $0.status.isTerminal ? nil : $0 }
                case .trying, .didntWork, .worked: latest
                default: nil
                }
            section(L("How it works")) {
                if !readOnly {
                    WorkflowFlowViewerButton(source: .draft(draft.id), onAsk: onAsk)
                }
            } content: {
                WorkflowStoryView(
                    definition: draft.definition, run: run, changed: draft.lastPatchedNodeIDs,
                    selection: readOnly ? nil : draft.selectedNodeID,
                    onSelect: readOnly ? nil : { drafts.select(nodeID: $0, in: draft.id) },
                    detail: { node in AnyView(stepDetail(draft, node: node)) })
            }
            .settingsLandingAnchor("workflows.architectSteps")
        }
    }

    private func stepDetail(_ draft: WorkflowDraft, node: WorkflowNode) -> some View {
        let badges = WorkflowStepRisk.badges(for: node, in: draft, catalog: ConfigModelReference.liveCatalog())
        let branches = WorkflowFlowLayout.branchLines(node, in: draft.definition)
        return VStack(alignment: .leading, spacing: theme.space.s10) {
            Text(verbatim: DraftStepDetail.meta(node, in: draft))
                .textStyle(.footnote)
                .foregroundStyle(theme.text.tertiary)
            if !badges.isEmpty { WorkflowStepBadgesView(badges: badges) }
            ForEach(Array(branches.enumerated()), id: \.offset) { _, line in
                Label {
                    Text(verbatim: line).lineLimit(2)
                } icon: {
                    Image(systemName: "arrow.turn.down.right").glyphSize(.tiny)
                }
                .textStyle(.footnote)
                .foregroundStyle(theme.text.secondary)
            }
            DraftStepDetail(draft: draft, node: node, onEdit: { editingNodeID = $0 }, onAsk: onAsk)
        }
    }

    // MARK: - More about it

    /// What it touches, what it uses, and how it changed: one line each,
    /// opening in place.
    private func moreAboutIt(_ draft: WorkflowDraft) -> some View {
        let scope = WorkflowAccessScope.derive(draft.definition)
        let architectEdits = draft.history.filter { $0.source == .architect }.count
        return VStack(alignment: .leading, spacing: theme.space.s0) {
            moreRow(
                .files, title: L("Your files"),
                summary: scope.places.isEmpty ? L("Doesn't use your files") : scope.places.map(\.title).joined(separator: " · ")
            ) {
                VStack(alignment: .leading, spacing: theme.space.s8) {
                    WorkflowAccessRows(scope: scope)
                    note(scope.architectSentence)
                }
            }
            .settingsLandingAnchor("workflows.yourFiles")
            if WorkflowRequirementsPanel.hasContent(draft) {
                ThemeHairlineDivider().padding(.horizontal, theme.space.s20)
                moreRow(.uses, title: L("It uses"), summary: WorkflowRequirementsPanel.summary(draft)) {
                    WorkflowRequirementsPanel(draft: draft)
                }
            }
            if !draft.history.isEmpty {
                ThemeHairlineDivider().padding(.horizontal, theme.space.s20)
                moreRow(
                    .changes, title: L("Changes"),
                    summary: (draft.history.count == 1 ? L("1 change") : L("\(draft.history.count) changes"))
                        + (architectEdits > 0 ? L(" · \(architectEdits) by the Architect") : "")
                ) {
                    DraftChangeList(draft: draft)
                }
                .settingsLandingAnchor("workflows.draftChanges")
            }
        }
        .padding(.vertical, theme.space.s4)
    }

    private func moreRow<Content: View>(
        _ id: MoreSection, title: String, summary: String, @ViewBuilder content: () -> Content
    ) -> some View {
        let isOpen = openMore.contains(id)
        return VStack(alignment: .leading, spacing: theme.space.s10) {
            Button {
                withAnimation(reduceMotion ? nil : theme.motion.quick) {
                    if isOpen { openMore.remove(id) } else { openMore.insert(id) }
                }
            } label: {
                HStack(spacing: theme.space.s8) {
                    Text(verbatim: title)
                        .textStyle(.label, weight: 500)
                        .foregroundStyle(theme.text.primary)
                        .fixedSize()
                    Text(verbatim: summary)
                        .textStyle(.caption)
                        .foregroundStyle(theme.text.tertiary)
                        .lineLimit(1)
                    Spacer(minLength: theme.space.s8)
                    Image(systemName: "chevron.right")
                        .glyphSize(.micro, weight: .semibold)
                        .foregroundStyle(theme.text.tertiary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .accessibilityHidden(true)
                }
                .frame(minHeight: theme.space.s24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .accessibilityValue(Text(isOpen ? "Expanded" : "Collapsed", bundle: .module))
            if isOpen {
                content()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, theme.space.s20)
        .padding(.vertical, theme.space.s8)
    }

    /// "You give Paragraph → You get Summary", the workflow's promise in
    /// one line.
    @ViewBuilder
    private func contract(_ draft: WorkflowDraft) -> some View {
        let gives = WorkflowSummary.inputs(draft.definition)
        let gets = WorkflowSummary.outputs(draft.definition)
        if !gives.isEmpty || !gets.isEmpty {
            let give = gives.isEmpty ? L("Nothing, it runs on its own") : WorkflowSummary.list(gives)
            let get = gets.isEmpty ? nil : WorkflowSummary.list(gets)
            HStack(alignment: .top, spacing: theme.space.s12) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: theme.space.s12) {
                        contractSide(L("You give"), give)
                        if let get {
                            Image(systemName: "arrow.right")
                                .glyphSize(.caption, weight: .semibold)
                                .foregroundStyle(theme.text.tertiary)
                                .accessibilityHidden(true)
                            contractSide(L("You get"), get)
                        }
                    }
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: theme.space.s12, verticalSpacing: theme.space.s8) {
                        contractRow(L("You give"), give)
                        if let get { contractRow(L("You get"), get) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                DraftFormPreviewButton(
                    definition: draft.definition,
                    fields: WorkflowFormFields.fields(fromInputSchema: draft.definition.inputSchema))
                .fixedSize()
            }
            .padding(theme.space.s12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .settingsChrome(.inset)
            .accessibilityElement(children: .contain)
        }
    }

    /// One side of the contract when both fit on one line each.
    private func contractSide(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: theme.space.s2) {
            Text(verbatim: title)
                .textStyle(.caption)
                .foregroundStyle(theme.text.tertiary)
            Text(verbatim: value)
                .textStyle(.label, weight: 500)
                .foregroundStyle(theme.text.primary)
                .lineLimit(1)
                .fixedSize()
        }
    }

    /// One side of the contract when the line is too long: label beside a
    /// value that wraps in full.
    private func contractRow(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(verbatim: title)
                .textStyle(.caption)
                .foregroundStyle(theme.text.tertiary)
                .fixedSize()
            Text(verbatim: value)
                .textStyle(.label, weight: 500)
                .foregroundStyle(theme.text.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        section(title, accessory: { EmptyView() }, content: content)
    }

    private func section<Accessory: View, Content: View>(
        _ title: String, @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content
    ) -> some View {
        let trailing = accessory()
        return VStack(alignment: .leading, spacing: theme.space.s10) {
            WorkflowSectionHeader(title: title, trailing: { trailing })
            content()
        }
    }

    private func note(_ text: String) -> some View {
        Text(verbatim: text)
            .textStyle(.caption)
            .foregroundStyle(theme.text.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func liveLineView(_ text: String, spins: Bool) -> some View {
        HStack(spacing: theme.space.s8) {
            if spins { SettingsSpinner(size: .mini) }
            Text(verbatim: text)
                .textStyle(.caption)
                .foregroundStyle(theme.text.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .id(text)
                .transition(.opacity)
        }
        .animation(reduceMotion ? nil : theme.motion.quick, value: text)
        .accessibilityElement(children: .combine)
    }

    /// What the Architect is doing, in one line: the try it is running,
    /// else why it made its latest change, else that it is planning.
    static func liveLine(_ draft: WorkflowDraft, latest: WorkflowRun?) -> String {
        if let latest, !latest.status.isTerminal {
            return L("Trying it out · ") + progressSummary(latest, definition: draft.definition)
        }
        if let edit = draft.history.last(where: { $0.source == .architect }) {
            let why = edit.why?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !why.isEmpty { return why }
            if let line = edit.lines.first, !line.isEmpty { return line }
            if !edit.summary.isEmpty { return edit.summary }
        }
        return L("Planning the steps…")
    }

    /// "9:08 PM · 3 of 3 steps" or "9:02 PM · failed at Download".
    static func progressSummary(_ run: WorkflowRun, definition: WorkflowDefinition) -> String {
        let time = run.startedAt.formatted(date: .omitted, time: .shortened)
        let steps = WorkflowSummary.steps(definition)
        if let failed = run.nodes.first(where: { $0.status == .failed }) {
            let name = definition.node(failed.nodeID)?.name ?? failed.nodeID
            return "\(time) · " + L("failed at \(name)")
        }
        let done = steps.filter { step in
            guard let status = run.node(step.id)?.status else { return false }
            return status == .done || status == .pinned || status == .skipped
        }.count
        return "\(time) · " + L("\(done) of \(steps.count) steps")
    }

    // MARK: - Actions

    private func latestRun(_ draft: WorkflowDraft) -> WorkflowRun? {
        draft.testRunIDs.last.flatMap { runs.run(id: $0) }
    }

    private func commitName(_ draft: WorkflowDraft?) {
        let name = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            nameDraft = draft?.name ?? ""
            return
        }
        guard name != draft?.name, let sessionID = sessionId?.uuidString else { return }
        let target = draft ?? drafts.draft(forSession: sessionID) ?? drafts.create(sessionID: sessionID)
        drafts.applyUserEdit(target.id) { $0.name = name }
    }

    /// The form starts on the first example, keeping anything typed, and
    /// follows the latest try.
    private func prefill(_ draft: WorkflowDraft, latest: WorkflowRun?) {
        let fields = WorkflowFormFields.fields(fromInputSchema: draft.definition.inputSchema)
        if let latest, let input = latest.input.objectValue, !input.isEmpty {
            values = WorkflowFormFields.initialValues(fields, prefill: input)
        } else {
            let example = draft.definition.examples.first?.input.objectValue ?? [:]
            let entered = values.filter { _, value in
                if case .string(let s) = value { return !s.isEmpty }
                return true
            }
            values = WorkflowFormFields.initialValues(fields, prefill: example.merging(entered) { _, mine in mine })
        }
        issues = [:]
    }

    private func adopt(_ run: WorkflowRun, draft: WorkflowDraft) {
        guard let input = run.input.objectValue, !input.isEmpty else { return }
        let fields = WorkflowFormFields.fields(fromInputSchema: draft.definition.inputSchema)
        values = WorkflowFormFields.initialValues(fields, prefill: input)
        issues = [:]
    }

    private func tryIt(_ draft: WorkflowDraft) {
        let schema = draft.definition.inputSchema
        let fields = WorkflowFormFields.fields(fromInputSchema: schema)
        let input = WorkflowFormFields.inputValue(values, fields: fields, schema: schema)
        formError = nil
        let problems = JSONSchemaValidator.validate(input, against: schema)
        guard problems.isEmpty else {
            var byField: [String: String] = [:]
            var other: [String] = []
            for problem in problems {
                if let field = fields.first(where: { problem.path.hasPrefix("$.\($0.key)") }) {
                    byField[field.key] = problem.message
                } else {
                    other.append(problem.description)
                }
            }
            issues = byField
            formError = other.isEmpty ? nil : other.joined(separator: "; ")
            editsInput = true
            return
        }
        issues = [:]
        switch WorkflowDraftTester.startFromPanel(draftID: draft.id, input: input, sessionID: sessionId?.uuidString) {
        case .success:
            editsInput = false
        case .failure(.invalid(let found)):
            formError = L("Fix these first: \(found.map(\.message).joined(separator: "; "))")
            editsInput = true
        case .failure(.needsSetup), .failure(.missingDraft):
            break
        }
    }

    private func add(_ draft: WorkflowDraft, trigger: WorkflowDraftTrigger?, evidence: WorkflowTestEvidence) {
        addError = nil
        let version = draft.templateID.flatMap { TemplateStore.shared.latest(id: $0)?.version }.map { $0 + 1 } ?? 1
        let state = WorkflowSavePromptState(
            draftID: draft.id, name: draft.name, version: version,
            changelog: version > 1 ? L("Updated") : L("First version"),
            updates: DraftEditing(draft)?.name, evidence: evidence, trigger: trigger)
        state.includeTrigger = includeTrigger
        if state.save() {
            lastAdd = state
        } else {
            addError = state.error
        }
    }

    private func runIt(_ draft: WorkflowDraft) {
        if let lastAdd, lastAdd.saved != nil {
            lastAdd.tryIt()
            return
        }
        guard let templateID = draft.templateID, let workflow = installed.workflow(templateID: templateID) else { return }
        if let example = workflow.definition.examples.first?.input.objectValue {
            WorkflowRunLauncher.stagePrefill(example, for: workflow.id)
        }
        WorkflowRunLauncher.openTab(workflowID: workflow.id)
    }
}
