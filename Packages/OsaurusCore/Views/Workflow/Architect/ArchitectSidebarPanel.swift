//
//  ArchitectSidebarPanel.swift
//  osaurus
//
//  The draft half of an Architect chat. The name is the title; under it
//  Design → Test → Save → Publish says where the draft stands, a line says
//  what it is (and which saved workflow it edits), and small Design | Test
//  tabs switch the body. Design shows it in plain words: the
//  steps as cards that open into their editor (or the graph), what you
//  fill in, what you get, and what it uses. Test runs it on real input.
//  Test Run and Save sit in the footer. Everything here edits the same
//  draft the Architect's tools patch; the next turn hears about it.
//

import SwiftUI

enum WorkflowCanvasLayout {
    /// The draft's column grows with its pane up to this width; past it the
    /// creation split gives the extra room to the chat.
    static let columnWidth: CGFloat = 880
}

struct ArchitectSidebarPanel: View {
    let sessionId: UUID?
    var isGenerating = false
    /// Puts text in the Architect chat's composer.
    var onAsk: ((String) -> Void)?
    /// Sends a message to the Architect chat.
    var onSend: ((String) -> Void)?
    /// Shows the Workflows lens, to pick a saved workflow to change.
    var onBrowse: (() -> Void)?

    enum Tab: Hashable { case design, test }
    enum DesignPanel: Hashable { case steps, fields, outputs, files, uses, changes }
    enum TestPanel: Hashable { case input, progress, result, history }

    @ObservedObject private var drafts = WorkflowDraftStore.shared
    @ObservedObject private var runs = WorkflowRunStore.shared
    @State private var tab: Tab = .design
    @State private var nameDraft = ""
    @FocusState private var nameFocused: Bool
    @State private var openRunID: UUID?
    @State private var designCollapsed: Set<DesignPanel> = [.uses, .changes]
    @State private var testCollapsed: Set<TestPanel> = [.history]
    /// A test section to open and scroll to, for a test starting or ending.
    @State private var testReveal: TestPanel?
    @State private var testValues: [String: JSONValue] = [:]
    @State private var testIssues: [String: String] = [:]
    @State private var testError: String?
    @State private var showsSave = false
    @State private var setupSubject: WorkflowSetupSubject?
    @State private var editingNodeID: String?

    @Environment(\.theme) private var theme

    private var draft: WorkflowDraft? { drafts.draft(forSession: sessionId?.uuidString) }

    #if OSAURUS_DESIGN_SYSTEM
    var inspectorMenuVerification = false
    #endif
    @ViewBuilder var body: some View {
        #if OSAURUS_DESIGN_SYSTEM
        if inspectorMenuVerification {
            let sample = WorkflowRun(workflowID: UUID(), workflowName: "Local input menu", templateID: UUID(), templateVersion: 1, caller: WorkflowCaller(kind: .test), input: .object(["topic": .string("Local saved input")]), nodeIDs: [])
            VStack(alignment: .leading) {
                historyRow(sample, isShown: false, fields: [DialogField(key: "topic", label: "Topic")], draft: WorkflowDraft(name: "Local draft"))
                Text("Local form values: " + (testValues["topic"]?.stringValue ?? "empty"))
            }
        } else { normalBody }
        #else
        normalBody
        #endif
    }
    @ViewBuilder private var normalBody: some View {
        if let draft, !Self.hasNothingDrafted(draft.definition) {
            let status = DraftRevisionCache.status(draft, latest: latestRun(draft))
            VStack(alignment: .leading, spacing: 0) {
                VStack(spacing: theme.space.s24) {
                    header(draft, status: status)
                    tabBar
                }
                .padding(.bottom, theme.space.s24)
                Group {
                    switch tab {
                    case .design: designSections(draft, status: status)
                    case .test: testSections(draft)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .sheet(
                    isPresented: Binding(
                        get: { editingNodeID != nil }, set: { if !$0 { editingNodeID = nil } })
                ) {
                    if let id = editingNodeID, let node = drafts.draft(id: draft.id)?.definition.node(id) {
                        WorkflowNodeEditor(draftID: draft.id, node: node) { editingNodeID = nil }
                    }
                }
                footer(draft, status: status)
                    .frame(maxWidth: WorkflowCanvasLayout.columnWidth)
                    .frame(maxWidth: .infinity)
                    .padding(.top, theme.space.s16)
            }
            .padding(theme.space.s8)
            .onAppear {
                nameDraft = draft.name
                prefillTest(draft)
                if let latest = latestRun(draft) {
                    adoptInput(of: latest, draft: draft)
                    testCollapsed.insert(.input)
                }
                presentRequestedSetup(draft)
            }
            .onChange(of: draft.name) { _, name in nameDraft = name }
            .onChange(of: draft.definition.inputSchema) { _, _ in prefillTest(draft) }
            .onChange(of: draft.definition.examples) { _, _ in prefillTest(draft) }
            .onChange(of: draft.testRunIDs.last) { _, latest in
                guard let latest else { return }
                openRunID = latest
                if let run = runs.run(id: latest) { adoptInput(of: run, draft: draft) }
                testReveal = .progress
                if draft.selectedNodeID == nil { tab = .test }
            }
            .onChange(of: latestRun(draft)?.status) { _, status in
                guard let status, status.isTerminal, let latest = latestRun(draft), openRunID == latest.id else { return }
                testReveal = Self.panel(after: latest)
            }
            .onChange(of: drafts.setupRequest) { _, _ in presentRequestedSetup(draft) }
            .sheet(item: $setupSubject) { subject in
                WorkflowSetupWizardView(subject: subject, onClose: { setupSubject = nil })
            }
        } else {
            emptyCanvas(draft)
        }
    }

    /// Nothing drafted yet: no steps, nothing to fill in, nothing it gives back.
    static func hasNothingDrafted(_ definition: WorkflowDefinition) -> Bool {
        func noFields(_ schema: JSONValue) -> Bool { schema.objectValue?["properties"]?.objectValue?.isEmpty ?? true }
        return definition.nodes.isEmpty && noFields(definition.inputSchema) && noFields(definition.outputSchema)
    }

    /// Before the Architect has drafted anything: the name, where making
    /// a workflow starts, and the shape of what is coming.
    private func emptyCanvas(_ draft: WorkflowDraft?) -> some View {
        VStack(spacing: theme.space.s24) {
            VStack(alignment: .leading, spacing: theme.space.s12) {
                HStack(spacing: theme.space.s12) {
                    nameField(draft)
                    emptyWorkflowMenu
                }
                WorkflowStageStepper(stage: .design)
            }
            .frame(maxWidth: WorkflowCanvasLayout.columnWidth)
            .frame(maxWidth: .infinity)
            ScrollView {
                VStack(spacing: theme.space.s16) {
                    VStack(spacing: 0) {
                        ForEach(1...3, id: \.self) { number in
                            if number > 1 {
                                Rectangle()
                                    .fill(theme.border.subtle)
                                    .frame(width: theme.stroke.default, height: theme.space.s12)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.leading, theme.space.s24)
                            }
                            placeholderStep(number)
                        }
                    }
                    .accessibilityHidden(true)
                    HStack(spacing: theme.space.s8) {
                        if isGenerating { ProgressView().controlSize(.small) }
                        Text(
                            isGenerating
                                ? L("The Architect is planning the steps…")
                                : L("Steps, what you fill in, and what you get show up here as the Architect drafts them."))
                            .textStyle(.caption)
                            .foregroundStyle(theme.text.tertiary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: WorkflowCanvasLayout.columnWidth)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .padding(theme.space.s8)
        .onAppear { nameDraft = draft?.name ?? "" }
    }

    private func placeholderStep(_ number: Int) -> some View {
        HStack(spacing: theme.space.s8) {
            Text(verbatim: "\(number)")
                .textStyle(.label, weight: 500)
                .foregroundStyle(theme.text.tertiary)
                .frame(width: theme.space.s16, height: theme.space.s16)
                .overlay { Circle().strokeBorder(theme.border.default, lineWidth: theme.stroke.default) }
            Rectangle()
                .fill(theme.border.subtle)
                .frame(width: theme.space.s48 * CGFloat(5 - number), height: theme.space.s8)
                .clipShape(Capsule())
            Spacer(minLength: 0)
        }
        .padding(.horizontal, theme.space.s16)
        .padding(.vertical, theme.space.s12)
        .draftCardChrome(isDashed: true)
    }

    private var emptyWorkflowMenu: some View {
        SettingsOverflowMenu(help: "More", size: .small) {
            if let onBrowse {
                Button(action: onBrowse) { Text("Change a Saved Workflow…", bundle: .module) }
            }
        }
    }


    // MARK: - Header

    private func nameField(_ draft: WorkflowDraft?) -> some View {
        SettingsTitleField(
            placeholder: L("Untitled Workflow"), text: $nameDraft, focus: $nameFocused,
            onCommit: { commitName(draft) })
        .accessibilityLabel(Text("Workflow name", bundle: .module))
        .help(L("Rename the workflow"))
    }

    private func workflowMenu(_ draft: WorkflowDraft) -> some View {
        SettingsOverflowMenu(help: "More", size: .small) {
            Button {
                drafts.undo(draft.id)
            } label: {
                Text(verbatim: WorkflowStepActions.undoTitle(draft) ?? L("Undo"))
            }
            .disabled(draft.history.isEmpty)
            Button {
                setupSubject = .draft(draft)
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
    }

    private func header(_ draft: WorkflowDraft, status: DraftStatus) -> some View {
        VStack(alignment: .leading, spacing: theme.space.s12) {
            HStack(spacing: theme.space.s12) {
                nameField(draft)
                workflowMenu(draft)
            }
            ViewThatFits(in: .horizontal) {
                stageRow(status, compact: false)
                stageRow(status, compact: true)
            }
            if let editing = DraftEditing(draft) {
                Text(verbatim: editing.label(draftName: draft.name))
                    .textStyle(.caption)
                    .foregroundColor(theme.text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(L("Saving creates the next version. Choose Save as New Workflow to keep the saved version unchanged."))
            }
            summary(draft)
        }
        .frame(maxWidth: WorkflowCanvasLayout.columnWidth)
        .frame(maxWidth: .infinity)
    }

    private func stageRow(_ status: DraftStatus, compact: Bool) -> some View {
        HStack(spacing: theme.space.s12) {
            WorkflowStageStepper(stage: status.stage, compact: compact)
            Spacer(minLength: theme.space.s8)
            statusPill(status)
        }
    }

    @ViewBuilder
    private func summary(_ draft: WorkflowDraft) -> some View {
        let summary = draft.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !summary.isEmpty {
            Text(verbatim: summary)
                .textStyle(.caption)
                .foregroundColor(theme.text.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(summary)
        }
    }

    @ViewBuilder private var tabBar: some View {
        #if OSAURUS_DESIGN_SYSTEM
        AssignedBaseSegmentedPicker(selection: $tab,
            options: [.init(.design, L("Design"), verbatim: true), .init(.test, L("Test"), verbatim: true)],
            size: .compact, minimumOptionWidth: theme.space.s48 * 2,
            busyValue: isGenerating ? .design : nil)
            .accessibilityLabel(Text("Workflow view", bundle: .module))
        #else
        Picker("Workflow view", selection: $tab) {
            Text("Design", bundle: .module).tag(Tab.design)
            Text("Test", bundle: .module).tag(Tab.test)
        }.pickerStyle(.segmented).frame(width: 204)
        #endif
    }

    private func statusPill(_ status: DraftStatus) -> some View {
        HStack(spacing: theme.space.s4) {
            if status.kind == .testing {
                ProgressView().controlSize(.mini)
            }
            StatusChip(
                status.title, tone: status.chipTone, showsDot: status.kind != .testing, help: status.detail)
        }
    }

    private func commitName(_ draft: WorkflowDraft?) {
        let name = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            nameDraft = draft?.name ?? ""
            return
        }
        guard name != draft?.name else { return }
        // Naming is an explicit user edit. Use the existing draft store so
        // the name is saved even before the Architect supplies its first step.
        guard let sessionID = sessionId?.uuidString else { return }
        let target = draft ?? drafts.draft(forSession: sessionID) ?? drafts.create(sessionID: sessionID)
        drafts.applyUserEdit(target.id) { $0.name = name }
    }

    private func presentRequestedSetup(_ draft: WorkflowDraft) {
        guard drafts.setupRequest == draft.id else { return }
        drafts.setupRequest = nil
        setupSubject = .draft(draft)
    }

    // MARK: - Design

    private func designSections(_ draft: WorkflowDraft, status: DraftStatus) -> some View {
        let def = draft.definition
        let fields = WorkflowFormFields.fields(fromInputSchema: def.inputSchema)
        let outputs = WorkflowSummary.outputs(def)
        let needsAttention = !status.blockers.isEmpty || (!status.issues.isEmpty && !def.nodes.isEmpty)
        var panels: [DraftSection<DesignPanel>] = [
            DraftSection(
                .steps, title: L("Steps"),
                subtitle: def.nodes.isEmpty
                    ? L("None yet")
                    : [
                        def.nodes.count == 1 ? L("1 step") : L("\(def.nodes.count) steps"),
                        needsAttention ? L("needs attention") : nil,
                    ].compactMap { $0 }.joined(separator: " · ")
            ) {
                VStack(alignment: .leading, spacing: 12) {
                    if needsAttention { beforeTestingCallout(draft, status: status) }
                    if def.nodes.isEmpty {
                        note(L("None yet"))
                    } else {
                        DraftStepList(draft: draft, onEdit: { editingNodeID = $0 }, onAsk: onAsk)
                    }
                }
            }
            .accessory(
                Group {
                    if !def.nodes.isEmpty {
                        WorkflowFlowViewerButton(source: .draft(draft.id), onAsk: onAsk)
                    }
                }).bounded(),
            DraftSection(
                .fields, title: L("You fill in"),
                subtitle: fields.isEmpty ? L("None yet") : fields.map(\.label).joined(separator: ", ")
            ) {
                DraftFieldsList(fields: fields)
            }
            .accessory(DraftFormPreviewButton(definition: def, fields: fields)).alwaysOpen(),
            DraftSection(
                .outputs, title: L("You get"),
                subtitle: outputs.isEmpty ? L("None yet") : outputs.joined(separator: ", ")
            ) {
                if outputs.isEmpty {
                    note(L("None yet"))
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(outputs, id: \.self) { label in
                            HStack(spacing: 8) {
                                Image(systemName: "checkmark.circle")
                                    .glyphSize(11)
                                    .foregroundColor(theme.text.link)
                                    .frame(width: 16)
                                Text(verbatim: label)
                                    .textStyle(.bodySmall)
                                    .foregroundColor(theme.text.primary)
                            }
                        }
                    }
                }
            }.alwaysOpen(),
        ]
        if !def.nodes.isEmpty {
            let scope = WorkflowAccessScope.derive(def)
            panels.append(
                DraftSection(
                    .files, title: L("Your files"),
                    subtitle: scope.places.isEmpty
                        ? L("Doesn't use your files") : scope.places.map(\.title).joined(separator: " · ")
                ) {
                    VStack(alignment: .leading, spacing: theme.space.s8) {
                        WorkflowAccessRows(scope: scope)
                        note(scope.architectSentence)
                    }
                    .settingsLandingAnchor("workflows.yourFiles")
                })
        }
        if WorkflowRequirementsPanel.hasContent(draft) {
            panels.append(
                DraftSection(.uses, title: L("It uses"), subtitle: WorkflowRequirementsPanel.summary(draft)) {
                    WorkflowRequirementsPanel(draft: draft)
                })
        }
        if !draft.history.isEmpty {
            let architectEdits = draft.history.filter { $0.source == .architect }.count
            panels.append(
                DraftSection(
                    .changes, title: L("Changes"),
                    subtitle: draft.history.count == 1 ? L("1 change") : L("\(draft.history.count) changes")
                        + (architectEdits > 0 ? L(" · \(architectEdits) by the Architect") : "")
                ) {
                    DraftChangeList(draft: draft)
                })
        }
        return DraftSectionList(sections: panels, collapsed: $designCollapsed, reveal: .constant(nil))
    }

    private func beforeTestingCallout(_ draft: WorkflowDraft, status: DraftStatus) -> some View {
        let tint = status.blockers.isEmpty ? theme.text.secondary : theme.statusInk.warning
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: status.blockers.isEmpty ? "hourglass" : "exclamationmark.triangle.fill")
                    .foregroundColor(tint)
                Text(verbatim: L("Before it can be tested"))
                    .textStyle(.label, weight: 600)
                    .foregroundColor(theme.text.primary)
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(status.issues.prefix(4), id: \.self) { line in
                    bullet(line)
                }
                ForEach(status.blockers) { item in
                    bullet(item.detail.isEmpty ? item.title : "\(item.title): \(item.detail)")
                }
            }
            if !status.blockers.isEmpty {
                SettingsButton(.tertiary, "Set Up…", size: .compact) { setupSubject = .draft(draft) }
            }
        }
        .padding(theme.space.s12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsChrome(status.blockers.isEmpty ? .inset : .status(.warning))
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(verbatim: "•").foregroundColor(theme.text.tertiary)
            Text(verbatim: text)
                .foregroundColor(theme.text.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .textStyle(.caption)
    }

    // MARK: - Test

    /// Input, then the test on screen: its steps, its result, and every
    /// earlier test, each section opening and closing on its own.
    private func testSections(_ draft: WorkflowDraft) -> some View {
        let all = draft.testRunIDs.reversed().compactMap { runs.run(id: $0) }
        let shown = all.first { $0.id == openRunID } ?? all.first
        let fields = WorkflowFormFields.fields(fromInputSchema: draft.definition.inputSchema)
        var panels: [DraftSection<TestPanel>] = [
            DraftSection(
                .input, title: L("Input"),
                subtitle: fields.isEmpty ? L("None") : Self.inputSummary(fields, values: testValues)
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    if fields.isEmpty {
                        note(L("This workflow takes no input."))
                    } else {
                        WorkflowFormView(
                            fields: fields, values: $testValues, issues: testIssues,
                            onSubmit: { if canRunTest(draft) { runTest(draft) } },
                            accessCaptions: WorkflowAccessScope.derive(draft.definition).inputCaptions)
                    }
                    if let testError {
                        Text(testError)
                            .textStyle(.caption)
                            .foregroundColor(theme.statusInk.error)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if shown == nil {
                        note(L("Run a test to watch each step work on real input. The Architect can run tests too."))
                    }
                }
            }
            .accessory(examplesMenu(draft, fields: fields)),
        ]
        if let shown {
            // The same order as a run's page: what it gave back, then how.
            if let output = shown.output {
                panels.append(
                    DraftSection(
                        .result, title: L("Result"),
                        subtitle: Self.firstLine(
                            WorkflowResultCard.plainText(output, schema: draft.definition.outputSchema))
                    ) {
                        VStack(alignment: .leading, spacing: theme.space.s12) {
                            if !shown.hostWrites.isEmpty {
                                WorkflowHostWritesSummary(
                                    run: shown, definition: draft.definition, boundFolders: draft.bindings.folders)
                            }
                            WorkflowResultCard(
                                output: output, schema: draft.definition.outputSchema, showsTitle: false,
                                files: shown.artifacts)
                        }
                    }
                    .icon(runIcon(shown.status))
                    .accessory(WorkflowResultCopyAllButton(output: output, schema: draft.definition.outputSchema))
                    .bounded())
            }
            panels.append(
                DraftSection(
                    .progress, title: shown.output == nil ? WorkflowRunTabView.testStatusText(shown.status) : L("Steps"),
                    subtitle: Self.progressSummary(shown, definition: draft.definition)
                ) {
                    VStack(alignment: .leading, spacing: theme.space.s12) {
                        if !shown.status.isTerminal {
                            WorkflowRunProgressBar(run: shown)
                        }
                        WorkflowRunView(
                            run: shown, definition: draft.definition, showsOutput: false, header: .timing,
                            onFix: onSend.map { send in
                                {
                                    drafts.setRepairRun(draft.id, runID: shown.id)
                                    drafts.notePending(
                                        draft.id, WorkflowRepairBrief.note(shown, workflowName: draft.name))
                                    send(WorkflowRepairBrief.message(shown, definition: draft.definition))
                                }
                            })
                    }
                }
                .icon(shown.output == nil ? AnyView(runIcon(shown.status)) : AnyView(
                    Image(systemName: "list.bullet").glyphSize(12).foregroundStyle(theme.text.secondary))))
        }
        if all.count > 1 {
            panels.append(
                DraftSection(.history, title: L("Earlier tests"), subtitle: L("\(all.count) tests")) {
                    VStack(spacing: 4) {
                        ForEach(all) { run in
                            historyRow(run, isShown: run.id == shown?.id, fields: fields, draft: draft)
                        }
                    }
                })
        }
        return DraftSectionList(sections: panels, collapsed: $testCollapsed, reveal: $testReveal)
    }

    @ViewBuilder
    private func examplesMenu(_ draft: WorkflowDraft, fields: [DialogField]) -> some View {
        if !fields.isEmpty, !draft.definition.examples.isEmpty {
            SettingsMenuButton(.tertiary, "Fill with Example", size: .compact) {
                ForEach(draft.definition.examples, id: \.name) { example in
                    Button(example.name) {
                        testValues = WorkflowFormFields.initialValues(fields, prefill: example.input.objectValue ?? [:])
                        testIssues = [:]
                    }
                }
            }
        }
    }

    private func historyRow(_ run: WorkflowRun, isShown: Bool, fields: [DialogField], draft: WorkflowDraft) -> some View {
        Button {
            openRunID = run.id
            testReveal = Self.panel(after: run)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                runIcon(run.status)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(verbatim: WorkflowRunTabView.testStatusText(run.status))
                            .foregroundColor(theme.text.primary)
                        Spacer()
                        Text(run.startedAt, style: .time)
                            .foregroundColor(theme.text.tertiary)
                    }
                    .textStyle(.caption, weight: 500)
                    Text(verbatim: Self.inputSummary(fields, values: run.input.objectValue ?? [:]))
                        .textStyle(.footnote)
                        .foregroundColor(theme.text.tertiary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, theme.space.s8)
            .padding(.vertical, theme.space.s6)
            .settingsChrome(isShown ? .selected : .inset)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .assignedContextMenu {
            Button {
                testValues = WorkflowFormFields.initialValues(fields, prefill: run.input.objectValue ?? [:])
                testIssues = [:]
            } label: {
                Text("Use This Input", bundle: .module)
            }
        }
    }

    /// The panel to show once `run` is on screen: its result when it has
    /// one, else its steps.
    static func panel(after run: WorkflowRun) -> TestPanel {
        run.status.isTerminal && run.output != nil ? .result : .progress
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

    static func firstLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
    }

    /// The form follows the latest test, so Test Run repeats it unless the
    /// user typed something since.
    private func adoptInput(of run: WorkflowRun, draft: WorkflowDraft) {
        guard let input = run.input.objectValue, !input.isEmpty else { return }
        let fields = WorkflowFormFields.fields(fromInputSchema: draft.definition.inputSchema)
        testValues = WorkflowFormFields.initialValues(fields, prefill: input)
        testIssues = [:]
    }

    /// "Channel URL: https://… · Folder: ~/Videos", secrets hidden.
    static func inputSummary(_ fields: [DialogField], values: [String: JSONValue]) -> String {
        let parts = fields.compactMap { field -> String? in
            guard let value = values[field.key] else { return nil }
            let text: String
            switch value {
            case .null: return nil
            case .string(let s): text = s.trimmingCharacters(in: .whitespacesAndNewlines)
            default: text = value.compactJSONString
            }
            guard !text.isEmpty else { return nil }
            return "\(field.label): \(field.type == .secret ? "••••" : text)"
        }
        return parts.isEmpty ? L("Nothing entered yet") : parts.joined(separator: " · ")
    }

    private func runIcon(_ status: WorkflowRunStatus) -> some View {
        WorkflowRunStatusIcon(status: status)
    }

    private func prefillTest(_ draft: WorkflowDraft) {
        let fields = WorkflowFormFields.fields(fromInputSchema: draft.definition.inputSchema)
        let example = draft.definition.examples.first?.input.objectValue ?? [:]
        let entered = testValues.filter { _, value in
            if case .string(let s) = value { return !s.isEmpty }
            return true
        }
        testValues = WorkflowFormFields.initialValues(fields, prefill: example.merging(entered) { _, mine in mine })
        testIssues = [:]
    }

    private func latestRun(_ draft: WorkflowDraft) -> WorkflowRun? {
        draft.testRunIDs.last.flatMap { runs.run(id: $0) }
    }

    // MARK: - Footer

    /// One primary button, always the next step: Set Up… while something
    /// is missing, Test Run until a test passes, then Save…. Stop replaces
    /// it while a test runs.
    private func footer(_ draft: WorkflowDraft, status: DraftStatus) -> some View {
        let running = latestRun(draft).flatMap { $0.status.isTerminal ? nil : $0 }
        return HStack(spacing: theme.space.s8) {
            if status.kind == .tested, running == nil {
                SettingsButton(.secondary, "Test Again", icon: "arrow.clockwise", help: L("Run the draft on the test input again")) {
                    runTest(draft)
                }
            } else {
                saveButton(draft, status: status, prominent: false)
            }
            Spacer(minLength: theme.space.s8)
            ViewThatFits(in: .horizontal) {
                Text(verbatim: Self.nextStep(status, isRunning: running != nil))
                    .textStyle(.caption)
                    .foregroundStyle(theme.text.tertiary)
                    .lineLimit(1)
                    .fixedSize()
                EmptyView()
            }
            if let running {
                SettingsButton(.secondary, "Stop", icon: "stop.fill") {
                    WorkflowRunService.shared.cancel(running.id)
                }
            } else if !status.blockers.isEmpty {
                SettingsButton(
                    .primary, "Set Up…", icon: "wrench.and.screwdriver",
                    help: L("Set up what the draft needs before it can be tested")
                ) { setupSubject = .draft(draft) }
            } else if status.kind == .tested {
                saveButton(draft, status: status, prominent: true)
            } else {
                SettingsButton(.primary, "Test Run", icon: "play.fill", help: L("Run the draft on the test input")) {
                    runTest(draft)
                }
                .disabled(draft.definition.nodes.isEmpty)
            }
        }
    }

    private func saveButton(_ draft: WorkflowDraft, status: DraftStatus, prominent: Bool) -> some View {
        SettingsButton(
            prominent ? .primary : .secondary, "Save…", icon: prominent ? "checkmark" : nil,
            help: status.canSave ? L("Save this workflow on this Mac") : (status.saveBlocker ?? "")
        ) { showsSave = true }
        .disabled(!status.canSave)
        .popover(isPresented: $showsSave, arrowEdge: .top) {
            DraftSaveForm(draft: draft, tested: status.kind == .tested) { showsSave = false }
        }
    }

    /// The footer's hint at what comes next, beside its primary button.
    static func nextStep(_ status: DraftStatus, isRunning: Bool) -> String {
        if isRunning { return L("Testing on real input…") }
        switch status.kind {
        case .drafting: return L("Next: finish the steps with the Architect")
        case .needsSetup: return L("Next: set up what it needs")
        case .ready: return L("Next: test it on real input")
        case .testing: return L("Testing on real input…")
        case .testFailed: return L("Next: fix the failed step and test again")
        case .tested: return L("Next: save it, then publish from Workflows")
        }
    }

    /// When the footer offers Test Run, so Return in the test input does the same.
    private func canRunTest(_ draft: WorkflowDraft) -> Bool {
        if let latest = latestRun(draft), !latest.status.isTerminal { return false }
        let status = DraftRevisionCache.status(draft, latest: latestRun(draft))
        return status.blockers.isEmpty && !draft.definition.nodes.isEmpty
    }

    private func runTest(_ draft: WorkflowDraft) {
        let schema = draft.definition.inputSchema
        let fields = WorkflowFormFields.fields(fromInputSchema: schema)
        let input = WorkflowFormFields.inputValue(testValues, fields: fields, schema: schema)
        testError = nil
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
            testIssues = byField
            testError = other.isEmpty ? nil : other.joined(separator: "; ")
            testReveal = .input
            tab = .test
            return
        }
        testIssues = [:]
        switch WorkflowDraftTester.startFromPanel(draftID: draft.id, input: input, sessionID: sessionId?.uuidString) {
        case .success(let runID):
            openRunID = runID
            testReveal = .progress
            tab = .test
        case .failure(.invalid(let issues)):
            testError = L("Fix these first: \(issues.map(\.message).joined(separator: "; "))")
            testReveal = .input
            tab = .test
        case .failure(.needsSetup), .failure(.missingDraft):
            break
        }
    }

    // MARK: - Pieces

    private func note(_ text: String) -> some View {
        Text(verbatim: text)
            .textStyle(.caption)
            .foregroundColor(theme.text.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Status

/// Where the draft stands, in the header pill and the footer's rules.
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

    var title: String {
        switch kind {
        case .drafting: return L("Drafting")
        case .needsSetup: return blockers.count == 1 ? L("1 thing to set up") : L("\(blockers.count) things to set up")
        case .ready: return L("Ready to test")
        case .testing: return L("Testing…")
        case .tested: return L("Tested")
        case .testFailed: return L("Test failed")
        }
    }

    var detail: String? {
        switch kind {
        case .drafting: return issues.first
        case .needsSetup: return blockers.first.map(\.title)
        case .tested: return L("The latest test passed and the steps haven't changed since.")
        default: return nil
        }
    }

    var chipTone: StatusChip.Tone {
        switch kind {
        case .drafting, .needsSetup: return .warning
        case .ready, .testing: return .info
        case .tested: return .success
        case .testFailed: return .error
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
}

// MARK: - Steps

/// The steps in run order as cards joined by a line from number to
/// number, green once the latest test got past it. A card opens into a
/// short summary with its model; editing happens in a sheet or in chat.
private struct DraftStepList: View {
    let draft: WorkflowDraft
    let onEdit: (String) -> Void
    let onAsk: ((String) -> Void)?

    @ObservedObject private var drafts = WorkflowDraftStore.shared
    @ObservedObject private var runs = WorkflowRunStore.shared
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let def = draft.definition
        // Once per body: every card asks where its slot's model runs.
        let catalog = ConfigModelReference.liveCatalog()
        let steps = WorkflowSummary.steps(def)
        let latest = draft.testRunIDs.last.flatMap { runs.run(id: $0) }
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                if let node = def.node(step.id) {
                    if index > 0 {
                        connector(passed: Self.passed(steps[index - 1].id, in: latest))
                    }
                    card(node, number: index + 1, catalog: catalog)
                }
            }
        }
    }

    /// Whether the latest test finished (or skipped past) this step.
    static func passed(_ nodeID: String, in run: WorkflowRun?) -> Bool {
        guard let status = run?.node(nodeID)?.status else { return false }
        return status == .done || status == .pinned || status == .skipped
    }

    private func connector(passed: Bool) -> some View {
        Rectangle()
            .fill(passed ? theme.statusInk.success : theme.border.default)
            .frame(width: theme.stroke.default, height: theme.space.s12)
            .padding(.leading, theme.space.s24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityHidden(true)
    }

    private func card(_ node: WorkflowNode, number: Int, catalog: ConfigModelReference.Catalog) -> some View {
        let isOpen = draft.selectedNodeID == node.id
        let isPlaceholder = node.kind == nil
        let isChanged = draft.lastPatchedNodeIDs.contains(node.id)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : theme.motion.quick) {
                    drafts.select(nodeID: isOpen ? nil : node.id, in: draft.id)
                }
            } label: {
                HStack(alignment: .top, spacing: theme.space.s8) {
                    Text(verbatim: "\(number)")
                        .textStyle(.label, weight: 500)
                        .foregroundColor(theme.text.inverse)
                        .frame(width: theme.space.s16, height: theme.space.s16)
                        .background(Circle().fill(theme.surface.inverse ?? theme.text.primary))
                    VStack(alignment: .leading, spacing: theme.space.s8) {
                        HStack(spacing: theme.space.s8) {
                            Text(verbatim: node.name)
                                .textStyle(.label, weight: 500)
                                .foregroundColor(theme.text.primary)
                                .multilineTextAlignment(.leading)
                            if isChanged {
                                StatusChip(
                                    L("Changed"), tone: .info,
                                    help: L("The Architect changed this step in its latest edit."))
                            }
                        }
                        if isOpen, let description = DraftStepDetail.description(node) {
                            Text(verbatim: description)
                                .textStyle(.caption)
                                .foregroundColor(theme.text.secondary)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        HStack(spacing: 4) {
                            Image(systemName: metadataIcon(node, catalog: catalog))
                                .glyphSize(9)
                            Text(verbatim: DraftStepDetail.meta(node, in: draft))
                                .lineLimit(1)
                        }
                        .textStyle(.footnote)
                        .foregroundColor(theme.isDark ? theme.text.tertiary : theme.text.secondary)
                        let badges = WorkflowStepRisk.badges(for: node, in: draft, catalog: catalog)
                        let visibleBadges = isOpen ? badges : badges.filter {
                            if case .neutral = $0.tone { return false }
                            return true
                        }
                        if !visibleBadges.isEmpty { WorkflowStepBadgesView(badges: visibleBadges) }
                        ForEach(Array(WorkflowFlowLayout.branchLines(node, in: draft.definition).enumerated()), id: \.offset) { _, line in
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.turn.down.right").glyphSize(9)
                                Text(verbatim: line).lineLimit(2)
                            }
                            .textStyle(.footnote)
                            .foregroundColor(theme.text.secondary)
                        }
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .glyphSize(10, weight: .semibold)
                        .foregroundColor(theme.text.tertiary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .padding(.top, theme.space.s4)
                }
                .padding(.horizontal, theme.space.s16)
                .padding(.vertical, theme.space.s12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .assignedBaseKeyboardButton(13) {
                withAnimation(reduceMotion ? nil : theme.motion.quick) {
                    drafts.select(nodeID: isOpen ? nil : node.id, in: draft.id)
                }
            }
            .accessibilityValue(Text(isOpen ? "Expanded" : "Collapsed", bundle: .module))
            if isOpen {
                ThemeHairlineDivider(color: theme.border.subtle)
                    .padding(.horizontal, theme.space.s16)
                DraftStepDetail(draft: draft, node: node, onEdit: onEdit, onAsk: onAsk)
                    .padding(.leading, theme.space.s40)
                    .padding(.trailing, theme.space.s16)
                    .padding(.vertical, theme.space.s12)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous))
        .draftCardChrome(isSelected: isOpen, isHighlighted: isChanged, isDashed: isPlaceholder)
    }

    private func metadataIcon(_ node: WorkflowNode, catalog: ConfigModelReference.Catalog) -> String {
        guard case .inference(let spec) = node.kind else { return WorkflowFlowStyle.icon(node) }
        let model = draft.bindings.models[spec.modelSlot]
            ?? DraftRevisionCache.template(draft).requirements.models.first { $0.slot == spec.modelSlot }?.preferred
        guard let model else { return "cpu" }
        return SetupChecker.isLocalModel(model, catalog: catalog) ? "desktopcomputer" : "cloud"
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
        VStack(alignment: .leading, spacing: 10) {
            if case .inference(let spec) = node.kind {
                VStack(alignment: .leading, spacing: 5) {
                    label(L("Runs on"))
                    WorkflowStepModelMenu(draftID: draft.id, node: node, slotID: spec.modelSlot)
                }
                if !spec.instructions.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
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

extension View {
    /// A step card's surface: quiet at rest, the selection surface while
    /// open, tinted while it holds the Architect's latest change, and
    /// dashed while it is still a placeholder.
    func draftCardChrome(isSelected: Bool = false, isHighlighted: Bool = false, isDashed: Bool = false) -> some View {
        modifier(DraftCardChrome(isSelected: isSelected, isHighlighted: isHighlighted, isDashed: isDashed))
    }
}

private struct DraftCardChrome: ViewModifier {
    let isSelected: Bool
    let isHighlighted: Bool
    let isDashed: Bool

    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous)
        content
            .settingsChrome(chrome)
            .overlay {
                if isDashed && !isSelected {
                    shape.strokeBorder(
                        theme.border.default,
                        style: StrokeStyle(lineWidth: theme.stroke.default, dash: [4, 3]))
                    .accessibilityHidden(true)
                }
            }
    }

    private var chrome: SettingsChrome {
        if isSelected { return .selected }
        if isHighlighted { return .status(.info) }
        return isDashed ? .inset : .subtle
    }
}

// MARK: - You fill in

/// The form's fields as a list.
private struct DraftFieldsList: View {
    let fields: [DialogField]

    @Environment(\.theme) private var theme

    var body: some View {
        if fields.isEmpty {
            Text("None yet", bundle: .module)
                .textStyle(.caption)
                .foregroundColor(theme.text.tertiary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(fields) { field in
                    HStack(spacing: 8) {
                        Image(systemName: Self.icon(field.type))
                            .glyphSize(11)
                            .foregroundColor(theme.text.tertiary)
                            .frame(width: 16)
                        Text(field.label)
                            .textStyle(.bodySmall)
                            .foregroundColor(theme.text.primary)
                            .lineLimit(1)
                            .help(field.help ?? "")
                        Spacer(minLength: 4)
                        Text(verbatim: field.required ? L("Required") : L("Optional"))
                            .textStyle(.footnote)
                            .foregroundColor(theme.text.tertiary)
                    }
                }
            }
        }
    }

    static func icon(_ type: DialogFieldType) -> String {
        switch type {
        case .text: return "textformat"
        case .longText: return "text.alignleft"
        case .number: return "number"
        case .bool: return "checkmark.square"
        case .choice: return "list.bullet"
        case .date: return "calendar"
        case .file: return "doc"
        case .folder: return "folder"
        case .secret: return "key"
        }
    }
}

/// The real form, filled with the first example, in a popover.
private struct DraftFormPreviewButton: View {
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

// MARK: - Save

/// Save from the panel: what this version changes, then Try It.
private struct DraftSaveForm: View {
    let draft: WorkflowDraft
    let tested: Bool
    let onClose: () -> Void

    @State private var changelog = ""
    @State private var error: String?
    @State private var saved: WorkflowSavePromptState?
    @Environment(\.theme) private var theme

    private var evidence: WorkflowTestEvidence { WorkflowDraftStore.shared.testEvidence(draft.id) }

    private var version: Int {
        draft.templateID.flatMap { TemplateStore.shared.latest(id: $0)?.version }.map { $0 + 1 } ?? 1
    }

    private var title: String {
        guard version > 1 else { return L("Save \(draft.name)") }
        if let editing = DraftEditing(draft), editing.name != draft.name {
            return L("Save \(draft.name) as v\(version) of \(editing.name)")
        }
        return L("Save \(draft.name) as v\(version)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if saved != nil {
                Label {
                    Text(verbatim: L("\(draft.name) is saved"))
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(theme.statusInk.success)
                }
                .textStyle(.body, weight: 600)
                .foregroundColor(theme.text.primary)
                Text("Find it under Workflows beside any chat.", bundle: .module)
                    .textStyle(.caption)
                    .foregroundColor(theme.text.secondary)
                HStack {
                    Spacer()
                    Button(action: onClose) { Text("Done", bundle: .module) }
                        .assignedSettingsButtonStyle(.secondary)
                    Button {
                        saved?.tryIt()
                        onClose()
                    } label: {
                        Label {
                            Text("Try It", bundle: .module)
                        } icon: {
                            Image(systemName: "play.fill")
                        }
                    }
                    .assignedSettingsButtonStyle(.primary)
                    .keyboardShortcut(.defaultAction)
                }
            } else {
                Text(verbatim: title)
                    .textStyle(.body, weight: 600)
                    .foregroundColor(theme.text.primary)
                Text("Saving installs it on this Mac with the models picked on each step.", bundle: .module)
                    .textStyle(.caption)
                    .foregroundColor(theme.text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let notice = WorkflowDraftSaver.renameNotice(for: draft) {
                    WorkflowRenameNotice(text: notice)
                }
                WorkflowTestEvidenceView(evidence: evidence)
                SettingsTextField(
                    placeholder: version > 1 ? L("What changed in this version") : L("What it does (optional)"),
                    text: $changelog)
                if let error {
                    Text(error)
                        .textStyle(.caption)
                        .foregroundColor(theme.statusInk.error)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Spacer()
                    Button(action: onClose) { Text("Cancel", bundle: .module) }
                        .assignedSettingsButtonStyle(.secondary)
                    Button(action: save) { Text("Save", bundle: .module) }
                        .assignedSettingsButtonStyle(.primary)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!evidence.satisfied)
                        .help(evidence.blocker ?? L("Save this workflow on this Mac"))
                }
            }
        }
        .padding(theme.space.s16)
        .frame(width: 340)
    }

    private func save() {
        let line = changelog.trimmingCharacters(in: .whitespacesAndNewlines)
        let state = WorkflowSavePromptState(
            draftID: draft.id, name: draft.name, version: version,
            changelog: line.isEmpty ? (version > 1 ? L("Updated") : L("First version")) : line,
            updates: DraftEditing(draft)?.name, evidence: evidence)
        if state.save() {
            saved = state
        } else {
            error = state.error
        }
    }
}

// MARK: - Sections

/// One section of a `DraftSectionList`: a header row, and content shown
/// while it is open.
struct DraftSection<ID: Hashable>: Identifiable {
    let id: ID
    let title: String
    var subtitle: String?
    var iconView: AnyView?
    var accessoryView: AnyView?
    /// Content that can be very long (a run's steps, its result) scrolls
    /// inside a box instead of stretching the list.
    var isBounded = false
    var isCollapsible = true
    let content: AnyView

    init<Content: View>(
        _ id: ID, title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.content = AnyView(content())
    }

    /// Shown before the title.
    func icon<V: View>(_ view: V) -> Self {
        var copy = self
        copy.iconView = AnyView(view)
        return copy
    }

    /// Shown at the header's end while the section is open.
    func accessory<V: View>(_ view: V) -> Self {
        var copy = self
        copy.accessoryView = AnyView(view)
        return copy
    }

    func alwaysOpen() -> Self {
        var copy = self
        copy.isCollapsible = false
        return copy
    }

    func bounded() -> Self {
        var copy = self
        copy.isBounded = true
        return copy
    }
}

/// Sections in one scrolling column, each header opening or closing its
/// own section, like an inspector's. A section closed while scrolled past
/// keeps its header on screen; `reveal` opens one and scrolls to it.
struct DraftSectionList<ID: Hashable>: View {
    let sections: [DraftSection<ID>]
    @Binding var collapsed: Set<ID>
    @Binding var reveal: ID?

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The tallest a bounded section gets: most of the list, never so
    /// little that it is a slit.
    static func boundedHeight(listHeight: CGFloat) -> CGFloat {
        max(200, listHeight * 0.6)
    }

    var body: some View {
        GeometryReader { geo in
            list(boundedHeight: Self.boundedHeight(listHeight: geo.size.height))
        }
    }

    private func list(boundedHeight: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: theme.space.s16) {
                    ForEach(sections) { section in
                        let isOpen = !section.isCollapsible || !collapsed.contains(section.id)
                        VStack(alignment: .leading, spacing: theme.space.s12) {
                            header(section, isOpen: isOpen, proxy: proxy)
                            if isOpen {
                                Group {
                                    if section.isBounded {
                                        DraftBoundedScroll(maxHeight: boundedHeight) { section.content }
                                    } else {
                                        section.content
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            } else if let subtitle = section.subtitle, !subtitle.isEmpty {
                                Text(verbatim: subtitle)
                                    .textStyle(.caption)
                                    .foregroundColor(theme.text.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.horizontal, theme.space.s16)
                        .padding(.vertical, theme.space.s12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .workflowCanvasCard()
                        .id(section.id)
                    }
                }
                .frame(maxWidth: WorkflowCanvasLayout.columnWidth)
                .padding(.bottom, theme.space.s8)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .onChange(of: reveal) { _, target in
                guard let target else { return }
                collapsed.remove(target)
                reveal = nil
                DispatchQueue.main.async {
                    withAnimation(reduceMotion ? nil : theme.motion.quick) { proxy.scrollTo(target, anchor: .top) }
                }
            }
        }
    }

    private func heading(_ section: DraftSection<ID>) -> some View {
        HStack(spacing: theme.space.s8) {
            if let icon = section.iconView { icon }
            Text(verbatim: section.title)
                .textStyle(.body)
                .foregroundColor(theme.text.primary)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
        }
        .accessibilityAddTraits(.isHeader)
    }

    private func header(_ section: DraftSection<ID>, isOpen: Bool, proxy: ScrollViewProxy) -> some View {
        HStack(alignment: .center, spacing: theme.space.s8) {
            if section.isCollapsible {
                Button { toggle(section.id, isOpen: isOpen, proxy: proxy) } label: {
                    HStack(spacing: theme.space.s8) {
                        heading(section)
                        Spacer(minLength: theme.space.s4)
                        Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                            .glyphSize(10)
                            .foregroundColor(theme.text.secondary)
                    }
                    .frame(minHeight: theme.space.s24)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .accessibilityValue(Text(isOpen ? "Expanded" : "Collapsed", bundle: .module))
            } else {
                heading(section)
                Spacer(minLength: theme.space.s4)
            }
            if isOpen, let accessory = section.accessoryView { accessory }
        }
    }

    private func toggle(_ id: ID, isOpen: Bool, proxy: ScrollViewProxy) {
        if isOpen {
            collapsed.insert(id)
            DispatchQueue.main.async { proxy.scrollTo(id) }
        } else {
            collapsed.remove(id)
        }
    }
}

/// Content at its own height up to `maxHeight`; past it, the same content
/// scrolling by itself, with no frame or padding added that would shift it.
private struct DraftBoundedScroll<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder let content: Content

    @State private var contentHeight: CGFloat = 0

    private var overflows: Bool { contentHeight > maxHeight }

    var body: some View {
        ScrollView(.vertical) {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: DraftContentHeightKey.self, value: geo.size.height)
                    })
        }
        .scrollIndicators(overflows ? .visible : .hidden)
        .scrollDisabled(!overflows)
        .frame(height: overflows ? maxHeight : max(1, contentHeight))
        .onPreferenceChange(DraftContentHeightKey.self) { contentHeight = $0 }
    }
}

private struct DraftContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}


// MARK: - Changes

/// Every edit to the draft, newest first: who made it, why (when the
/// Architect said), and each change in the diff's words. The newest can
/// be undone from here.
private struct DraftChangeList: View {
    let draft: WorkflowDraft

    @ObservedObject private var drafts = WorkflowDraftStore.shared
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(draft.history.enumerated().reversed()), id: \.offset) { index, edit in
                row(edit, isNewest: index == draft.history.count - 1)
            }
        }
        .settingsLandingAnchor("workflows.draftChanges")
    }

    private func row(_ edit: WorkflowDraftEdit, isNewest: Bool) -> some View {
        let lines = edit.lines.isEmpty ? edit.summary.components(separatedBy: "; ").filter { !$0.isEmpty } : edit.lines
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: edit.source == .architect ? "wand.and.stars" : "person")
                    .glyphSize(9)
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
                HStack(alignment: .firstTextBaseline, spacing: 6) {
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
