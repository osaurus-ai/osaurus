//
//  WorkflowRunPage.swift
//  osaurus
//
//  Running a workflow from the Workflows window. Play on a row starts the
//  run at once when nothing needs filling in; otherwise
//  `WorkflowRunInputSheet` asks first. A run opens on `WorkflowRunPage`:
//  how far it has got, any form it is waiting on, the result (Copy All in
//  its header), and the steps, with Stop and Run Again in a footer that
//  never scrolls away.
//

import AppKit
import SwiftUI

// MARK: - Starting a run

@MainActor
enum WorkflowRunStarter {
    enum Outcome: Equatable {
        case started(UUID)
        /// Setup or keys stand in the way.
        case blocked
        /// Something has to be filled in first.
        case needsInput
    }

    /// The person, running as `windowAgent` when that agent has the
    /// workflow turned on.
    static func caller(for workflowID: UUID, windowAgent: UUID) -> WorkflowCaller {
        let agentId = WorkflowRunLauncher.runAgent(for: workflowID, windowAgent: windowAgent)
        return WorkflowCaller(
            kind: .user, agentID: agentId, agentName: agentId.flatMap { AgentManager.shared.agent(for: $0)?.name })
    }

    static func setupReport(_ workflow: InstalledWorkflow, windowAgent: UUID) -> SetupReport {
        SetupChecker.check(
            workflow, secrets: .caller(WorkflowRunLauncher.runAgent(for: workflow.id, windowAgent: windowAgent)),
            attended: true)
    }

    /// Play: starts at once with each field's default when nothing is
    /// required.
    static func play(_ workflow: InstalledWorkflow, windowAgent: UUID) -> Outcome {
        guard !setupReport(workflow, windowAgent: windowAgent).hasBlockers else { return .blocked }
        guard !WorkflowRunPresentation.needsInput(workflow.definition) else { return .needsInput }
        let form = WorkflowRunForm(workflow: workflow, prefill: [:])
        return form.start(workflow, windowAgent: windowAgent).map(Outcome.started) ?? .needsInput
    }
}

/// A workflow's input form: the values typed so far, the problems found,
/// and starting a run with them.
@MainActor
final class WorkflowRunForm: ObservableObject {
    let fields: [DialogField]
    @Published var values: [String: JSONValue]
    @Published var issues: [String: String] = [:]
    @Published var generalIssue: String?

    /// Starts from `prefill`; when nil, from input staged for this
    /// workflow, else the last run's.
    init(workflow: InstalledWorkflow, prefill: [String: JSONValue]? = nil) {
        fields = WorkflowFormFields.fields(fromInputSchema: workflow.definition.inputSchema)
        let start =
            prefill ?? WorkflowRunLauncher.takePrefill(for: workflow.id)
            ?? WorkflowRunStore.shared.recentRuns().first { $0.workflowID == workflow.id }?.input.objectValue
            ?? [:]
        values = WorkflowFormFields.initialValues(fields, prefill: start)
    }

    func fill(_ input: [String: JSONValue]) {
        values = WorkflowFormFields.initialValues(fields, prefill: input)
        issues = [:]
        generalIssue = nil
    }

    /// The new run's id, or nil with `issues` set when the input does not
    /// fit the workflow.
    func start(_ workflow: InstalledWorkflow, windowAgent: UUID) -> UUID? {
        let schema = workflow.definition.inputSchema
        let input = WorkflowFormFields.inputValue(values, fields: fields, schema: schema)
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
            generalIssue = other.isEmpty ? nil : other.joined(separator: "; ")
            return nil
        }
        issues = [:]
        generalIssue = nil
        return WorkflowRunService.shared.start(
            workflow, input: input, caller: WorkflowRunStarter.caller(for: workflow.id, windowAgent: windowAgent))
    }
}

// MARK: - Input

/// What a run needs before it starts: the form, or what stands in the way.
struct WorkflowRunInputBody: View {
    @Environment(\.theme) private var theme
    let workflow: InstalledWorkflow
    let windowAgent: UUID
    @ObservedObject var form: WorkflowRunForm
    let onSubmit: () -> Void
    let onSetUp: (InstalledWorkflow) -> Void

    private var runAgentId: UUID? { WorkflowRunLauncher.runAgent(for: workflow.id, windowAgent: windowAgent) }

    var body: some View {
        let report = WorkflowRunStarter.setupReport(workflow, windowAgent: windowAgent)
        if SetupChecker.onlyKeysMissing(report) {
            blocked(
                title: L("Add the missing keys to run this workflow"), blocking: report.blocking,
                action: L("Open Vault"), icon: "key.fill"
            ) { WorkflowRunLauncher.openKeys(agentId: runAgentId) }
        } else if !report.blocking.isEmpty {
            blocked(
                title: L("Finish setup to run this workflow"), blocking: report.blocking,
                action: L("Set Up"), icon: "wrench.and.screwdriver"
            ) { onSetUp(workflow) }
        } else {
            VStack(alignment: .leading, spacing: theme.space.s16) {
                if form.fields.isEmpty {
                    Text("This workflow needs nothing from you. Press Run to start it.", bundle: .module)
                        .textStyle(.body)
                        .foregroundStyle(theme.text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    WorkflowFormView(
                        fields: form.fields, values: $form.values, issues: form.issues, onSubmit: onSubmit,
                        accessCaptions: WorkflowAccessScope.derive(workflow.definition).inputCaptions)
                }
                if let issue = form.generalIssue {
                    Text(verbatim: issue)
                        .textStyle(.caption)
                        .foregroundStyle(theme.statusInk(.error))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func blocked(
        title: String, blocking: [SetupItem], action: String, icon: String, perform: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: theme.space.s12) {
            Text(verbatim: title)
                .textStyle(.body, weight: 600)
                .foregroundStyle(theme.text.primary)
            ForEach(blocking) { item in
                HStack(alignment: .top, spacing: theme.space.s8) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(theme.statusInk(.warning))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: theme.space.s2) {
                        Text(verbatim: item.title)
                            .textStyle(.body)
                            .foregroundStyle(theme.text.primary)
                        if !item.detail.isEmpty {
                            Text(verbatim: item.detail)
                                .textStyle(.caption)
                                .foregroundStyle(theme.text.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            HStack {
                Spacer()
                SettingsButton(.primary, action, icon: icon, verbatim: true, action: perform)
            }
        }
    }
}

/// Whose keys a run started here uses, so a missing or different value is
/// no surprise.
struct WorkflowRunKeysCaption: View {
    @Environment(\.theme) private var theme
    let workflow: InstalledWorkflow
    let windowAgent: UUID

    var body: some View {
        if !workflow.template.requirements.secrets.isEmpty {
            let name = WorkflowRunLauncher.runAgent(for: workflow.id, windowAgent: windowAgent)
                .flatMap { AgentManager.shared.agent(for: $0)?.displayName }
            Text(verbatim: name.map { L("Uses \($0)'s keys") } ?? L("Uses shared keys"))
                .textStyle(.caption)
                .foregroundStyle(theme.text.tertiary)
                .help(
                    name == nil
                        ? L("Runs started here use the keys shared by all agents in Settings → Vault.")
                        : L("This agent's own keys override the shared ones in Settings → Vault."))
        }
    }
}

/// Fill with Example: one button for one example, a menu for several.
struct WorkflowRunExampleButton: View {
    let examples: [WorkflowExample]
    let onFill: (WorkflowExample) -> Void

    var body: some View {
        if examples.count == 1, let example = examples.first {
            SettingsButton(.secondary, "Fill with Example", icon: "wand.and.stars") { onFill(example) }
        } else if examples.count > 1 {
            SettingsMenuButton(.secondary, "Fill with Example", icon: "wand.and.stars") {
                ForEach(examples) { example in
                    Button(example.name) { onFill(example) }
                }
            }
        }
    }
}

/// Start from an example, above the run sheet's form. A picker rather than
/// a menu button: picker menus open from sheets.
struct WorkflowRunExampleRow: View {
    @Environment(\.theme) private var theme
    let examples: [WorkflowExample]
    let onFill: (WorkflowExample) -> Void

    @State private var chosen = ""

    var body: some View {
        HStack(spacing: theme.space.s12) {
            Label {
                Text("Start from an example", bundle: .module)
            } icon: {
                Image(systemName: "wand.and.stars")
                    .foregroundStyle(theme.text.tertiary)
            }
            .textStyle(.bodySmall)
            .foregroundStyle(theme.text.secondary)
            .lineLimit(1)
            Spacer(minLength: theme.space.s8)
            if examples.count == 1, let example = examples.first {
                SettingsButton(.secondary, example.name, size: .compact, verbatim: true) { onFill(example) }
                    .help(L("Fills in the form with this example"))
            } else {
                SettingsMenuPicker(selection: selection) {
                    if chosen.isEmpty {
                        Text("Choose…", bundle: .module).tag("")
                    }
                    ForEach(examples) { example in
                        Text(verbatim: example.name).tag(example.name)
                    }
                }
                .settingsPickerHugging()
                .accessibilityLabel(Text("Start from an example", bundle: .module))
            }
        }
        .padding(.leading, theme.space.s12)
        .padding(.trailing, theme.space.s6)
        .padding(.vertical, theme.space.s6)
        .settingsChrome(.inset)
    }

    private var selection: Binding<String> {
        Binding(
            get: { chosen },
            set: { name in
                chosen = name
                if let example = examples.first(where: { $0.name == name }) { onFill(example) }
            })
    }
}

/// Run on a workflow that needs input: its form in a sheet. Run starts it
/// and hands back the new run.
struct WorkflowRunInputSheet: View {
    @Environment(\.theme) private var theme
    let workflow: InstalledWorkflow
    let windowAgent: UUID
    let onStarted: (UUID) -> Void
    let onSetUp: (InstalledWorkflow) -> Void
    let onClose: () -> Void

    @StateObject private var form: WorkflowRunForm

    init(
        workflow: InstalledWorkflow, windowAgent: UUID, prefill: [String: JSONValue]? = nil,
        onStarted: @escaping (UUID) -> Void, onSetUp: @escaping (InstalledWorkflow) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.workflow = workflow
        self.windowAgent = windowAgent
        self.onStarted = onStarted
        self.onSetUp = onSetUp
        self.onClose = onClose
        _form = StateObject(wrappedValue: WorkflowRunForm(workflow: workflow, prefill: prefill))
    }

    private var isBlocked: Bool { WorkflowRunStarter.setupReport(workflow, windowAgent: windowAgent).hasBlockers }

    var body: some View {
        let blocked = isBlocked
        SettingsSheet(
            icon: "play.fill",
            title: "Run \(workflow.name)",
            width: SettingsSheetWidth.regular,
            maxBodyHeight: 520,
            primary: blocked ? nil : .init(label: "Run", handler: run),
            secondary: .init(label: "Cancel", handler: onClose),
            onClose: onClose
        ) {
            if !blocked, !form.fields.isEmpty, !workflow.definition.examples.isEmpty {
                WorkflowRunExampleRow(examples: workflow.definition.examples) {
                    form.fill($0.input.objectValue ?? [:])
                }
            }
            WorkflowRunInputBody(
                workflow: workflow, windowAgent: windowAgent, form: form, onSubmit: run,
                onSetUp: { workflow in
                    onClose()
                    onSetUp(workflow)
                })
            if !blocked {
                WorkflowRunKeysCaption(workflow: workflow, windowAgent: windowAgent)
            }
        }
        .subtitle(verbatim: workflow.summary.flatMap { $0.isEmpty ? nil : $0 }, lineLimit: 2)
    }

    private func run() {
        guard let runID = form.start(workflow, windowAgent: windowAgent) else { return }
        onStarted(runID)
    }
}

// MARK: - Run page

/// One run in the Workflows window, or the form for a new one when
/// `runID` is nil.
struct WorkflowRunPage: View {
    @Environment(\.workflowSharedGrid) private var sharedGrid
    @Environment(\.theme) private var theme
    let windowState: ChatWindowState
    let workflowID: UUID
    let runID: UUID?
    /// The agent whose window a new run starts from (see
    /// `WorkflowRunLauncher.runAgent`).
    let agentId: UUID
    /// Esc, and the way out once the workflow is uninstalled.
    var onBack: (() -> Void)? = nil
    /// Shows another run of this workflow here, or the form for nil.
    let onShowRun: (UUID?) -> Void
    /// Opens the workflow's own page; nil leaves the link out.
    var onShowWorkflow: ((UUID) -> Void)? = nil
    var onSetUp: (InstalledWorkflow) -> Void = { WorkflowRunLauncher.openSetup($0) }

    @ObservedObject private var workflows = InstalledWorkflowStore.shared
    @ObservedObject private var runs = WorkflowRunStore.shared
    @ObservedObject private var dialogs = DialogCoordinator.shared

    @State private var form: WorkflowRunForm?
    @State private var formWorkflowID: UUID?

    private var workflow: InstalledWorkflow? { workflows.workflow(id: workflowID) }
    private var run: WorkflowRun? { runID.flatMap { runs.run(id: $0) } }
    private var windowAgent: UUID { agentId }

    var body: some View {
        VStack(spacing: theme.space.s0) {
            if let workflow {
                ScrollView {
                    VStack(alignment: .leading, spacing: theme.space.s24) {
                        hero(workflow)
                        if let run {
                            runContent(run, workflow: workflow)
                        } else if let form {
                            formContent(workflow, form: form)
                        }
                    }
                    .frame(maxWidth: WorkflowLibraryLayout.columnWidth, alignment: .leading)
                    .padding(.horizontal, theme.space.s24)
                    .padding(.top, WorkflowLibraryLayout.pageTopInset(theme))
                    .padding(.bottom, theme.space.s32)
                    .frame(maxWidth: .infinity)
                }
                footer(workflow)
            } else {
                Spacer()
                SettingsEmptyState(
                    inline: "trash", title: "This workflow was uninstalled.",
                    hint: "Its runs are gone with it.",
                    action: onBack.map { back in .init(title: L("Back to Workflows"), icon: "chevron.left", handler: back) })
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { if !sharedGrid { theme.surface.canvas } }
        .onAppear(perform: prepareForm)
        .onChange(of: runID) { _, _ in prepareForm() }
    }

    // MARK: Hero

    @ViewBuilder
    private func hero(_ workflow: InstalledWorkflow) -> some View {
        if let run {
            VStack(alignment: .leading, spacing: theme.space.s16) {
                SettingsDetailHeader(
                    title: workflow.name,
                    subtitle: nil,
                    leading: {
                        SettingsIconTile(
                            icon: run.status == .running ? "play.fill" : WorkflowRunStyle.icon(run.status), size: 40,
                            tint: WorkflowRunStyle.color(run.status, theme: theme))
                    },
                    chips: {
                        StatusChip(
                            WorkflowRunPresentation.shortStatus(run.status),
                            tone: WorkflowRunPresentation.tone(run.status), showsDot: !run.status.isTerminal)
                        WorkflowStartedByLabel(caller: run.caller)
                        Text(verbatim: run.startedAt.formatted(date: .abbreviated, time: .shortened))
                            .textStyle(.caption)
                            .foregroundStyle(theme.text.tertiary)
                            .lineLimit(1)
                    },
                    actions: {
                        workflowLink(workflow)
                        WorkflowInsightsLink(runID: run.id, refresh: run.finishedAt)
                        pastRunsMenu
                    })
                if !run.status.isTerminal {
                    VStack(alignment: .leading, spacing: theme.space.s8) {
                        HStack(spacing: theme.space.s8) {
                            Text(verbatim: WorkflowRunPresentation.progressLine(run, definition: definition(run, workflow)))
                                .textStyle(.body)
                                .foregroundStyle(theme.text.secondary)
                                .lineLimit(1)
                            Spacer(minLength: theme.space.s8)
                            WorkflowRunElapsed(run: run)
                        }
                        WorkflowRunProgressBar(run: run)
                    }
                    .transition(.opacity)
                }
            }
            .animation(theme.motion.quick, value: run.status)
        } else {
            SettingsDetailHeader(
                icon: "flowchart", title: workflow.name, subtitle: workflow.summary,
                chips: {
                    let sentence = WorkflowSummary.sentence(workflow.definition)
                    if !sentence.isEmpty {
                        Text(verbatim: sentence)
                            .textStyle(.caption)
                            .foregroundStyle(theme.text.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                },
                actions: {
                    workflowLink(workflow)
                    pastRunsMenu
                })
        }
    }

    @ViewBuilder
    private func workflowLink(_ workflow: InstalledWorkflow) -> some View {
        if let onShowWorkflow {
            WorkflowTextLink(title: L("About this workflow"), icon: "info.circle") { onShowWorkflow(workflow.id) }
        }
    }

    private func definition(_ run: WorkflowRun, _ workflow: InstalledWorkflow) -> WorkflowDefinition? {
        run.workflowID == workflow.id ? workflow.definition : nil
    }

    // MARK: Run

    @ViewBuilder
    private func runContent(_ run: WorkflowRun, workflow: InstalledWorkflow) -> some View {
        let definition = definition(run, workflow)
        if let dialog = dialogs.presentable.first(where: { $0.runID == run.id }) {
            WorkflowPageCard(title: dialog.title, icon: "text.badge.checkmark") {
                VStack(alignment: .leading, spacing: theme.space.s12) {
                    if !dialog.message.isEmpty {
                        Text(verbatim: dialog.message)
                            .textStyle(.body)
                            .foregroundStyle(theme.text.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    WorkflowDialogForm(dialog: dialog).id(dialog.id)
                }
            }
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
        if !run.hostWrites.isEmpty {
            WorkflowPageCard(title: L("On your Mac"), icon: WorkflowAccessScope.Place.mac.systemImage) {
                WorkflowHostWritesSummary(run: run, definition: definition, boundFolders: workflow.bindings.folders)
            }
            .transition(.opacity)
        }
        if let output = run.output {
            let schema = definition?.outputSchema ?? .object([:])
            WorkflowPageCard(title: L("Result"), icon: "tray.and.arrow.down") {
                WorkflowResultCopyAllButton(output: output, schema: schema)
            } content: {
                WorkflowResultCard(output: output, schema: schema, showsTitle: false, files: run.artifacts)
            }
            .transition(.opacity)
        } else if !run.artifacts.isEmpty {
            WorkflowPageCard(title: L("Files"), icon: "doc.on.doc") {
                WorkflowRunFiles(files: run.artifacts)
            }
        }
        let ownRun = run.workflowID == workflow.id
        WorkflowPageCard(title: L("Steps"), icon: "list.number") {
            HStack(spacing: theme.space.s8) {
                if run.status.isTerminal { WorkflowRunTiming(run: run) }
                if definition != nil {
                    WorkflowFlowViewerButton(source: .run(runID: run.id, workflowID: workflow.id))
                }
            }
        } content: {
            WorkflowRunView(
                run: run, definition: definition, showsOutput: false, header: .none,
                onFix: ownRun ? { ArchitectLauncher.repair(run, of: workflow, in: windowState) } : nil,
                onRetry: ownRun && WorkflowRunService.reasonNotToRetry(run) == nil
                    ? {
                        guard let newID = WorkflowRunService.shared.retry(runID: run.id) else { return }
                        onShowRun(newID)
                    } : nil)
        }
    }

    // MARK: Form

    private func formContent(_ workflow: InstalledWorkflow, form: WorkflowRunForm) -> some View {
        WorkflowPageCard(title: L("What it needs"), icon: "square.and.pencil") {
            WorkflowRunInputBody(
                workflow: workflow, windowAgent: windowAgent, form: form, onSubmit: { start(workflow) },
                onSetUp: onSetUp)
        }
    }

    private func prepareForm() {
        guard run == nil, let workflow else { return }
        if let staged = WorkflowRunLauncher.takePrefill(for: workflowID) {
            form = WorkflowRunForm(workflow: workflow, prefill: staged)
            formWorkflowID = workflowID
        } else if form == nil || formWorkflowID != workflowID {
            form = WorkflowRunForm(workflow: workflow)
            formWorkflowID = workflowID
        }
    }

    private func start(_ workflow: InstalledWorkflow) {
        guard let form, let runID = form.start(workflow, windowAgent: windowAgent) else { return }
        onShowRun(runID)
    }

    // MARK: Footer

    @ViewBuilder
    private func footer(_ workflow: InstalledWorkflow) -> some View {
        let content = footerContent(workflow)
        VStack(spacing: theme.space.s0) {
            ThemeHairlineDivider(color: theme.border.subtle)
            content
                .frame(maxWidth: WorkflowLibraryLayout.columnWidth)
                .padding(.horizontal, theme.space.s24)
                .padding(.vertical, theme.space.s12)
                .frame(maxWidth: .infinity)
        }
        .background(theme.surface.canvas)
    }

    @ViewBuilder
    private func footerContent(_ workflow: InstalledWorkflow) -> some View {
        if let run {
            HStack(spacing: theme.space.s8) {
                if !run.status.isTerminal {
                    SettingsButton(.secondary, "Stop", icon: "stop.fill") { WorkflowRunService.shared.cancel(run.id) }
                }
                Spacer()
                if run.status.isTerminal {
                    SettingsButton(.primary, "Run Again", icon: "arrow.clockwise") { runAgain(run, workflow: workflow) }
                        .keyboardShortcut(.return, modifiers: .command)
                }
            }
        } else if !WorkflowRunStarter.setupReport(workflow, windowAgent: windowAgent).hasBlockers {
            HStack(spacing: theme.space.s8) {
                WorkflowRunExampleButton(examples: workflow.definition.examples) {
                    form?.fill($0.input.objectValue ?? [:])
                }
                Spacer()
                WorkflowRunKeysCaption(workflow: workflow, windowAgent: windowAgent)
                SettingsButton(.primary, "Run", icon: "play.fill") { start(workflow) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .help(L("Run (⌘Return)"))
            }
        }
    }

    /// Same input again: at once when the workflow takes none, else the
    /// form, filled in with it.
    private func runAgain(_ run: WorkflowRun, workflow: InstalledWorkflow) {
        let input = run.input.objectValue ?? [:]
        let fields = WorkflowFormFields.fields(fromInputSchema: workflow.definition.inputSchema)
        if fields.isEmpty,
            case .started(let newID) = WorkflowRunStarter.play(workflow, windowAgent: windowAgent)
        {
            onShowRun(newID)
            return
        }
        form = WorkflowRunForm(workflow: workflow, prefill: input)
        formWorkflowID = workflowID
        onShowRun(nil)
    }

    // MARK: Past runs

    private var pastRunsMenu: some View {
        let past = runs.recentRuns().filter { $0.workflowID == workflowID }.prefix(20)
        return SettingsMenuButton(.secondary, "Runs", icon: "clock.arrow.circlepath", size: .extraSmall) {
            Button { onShowRun(nil) } label: { Label(L("New Run"), systemImage: "plus") }
            if !past.isEmpty { Divider() }
            ForEach(Array(past)) { item in
                Button { onShowRun(item.id) } label: {
                    Text(
                        verbatim:
                            "\(item.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(WorkflowRunPresentation.shortStatus(item.status))"
                    )
                }
            }
        }
    }
}
