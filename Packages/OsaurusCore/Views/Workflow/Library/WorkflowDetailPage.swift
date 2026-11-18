//
//  WorkflowDetailPage.swift
//  osaurus
//
//  Workflows → one workflow. It answers four questions and keeps the rest
//  out of the way: how do I run it (the header's one button), did it work
//  (Recent Runs), when does it run (When It Runs, each automation as a
//  sentence you change in place) and what does it do (its steps). Setup,
//  who can start it, saved answers, stored data, tags and its technical
//  name sit under More Options, closed until asked for or until a search
//  lands there. Recent Runs sits in a column beside the rest when the
//  window is wide. Everything else (Edit, Pin, Share, Rename, Uninstall)
//  is in the header's ⋯ menu.
//
//  The page body never watches the run store: what it shows of runs going
//  now comes from `WorkflowLiveRuns`, and the slow facts (setup, where it
//  runs, recorded runs) from `WorkflowDetailModel`.
//

import SwiftUI

struct WorkflowDetailPage<Actions: View>: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var store = InstalledWorkflowStore.shared
    @ObservedObject private var registryRecords = WorkflowRegistryRecordStore.shared
    @ObservedObject private var highlight = SettingsHighlightCoordinator.shared
    @StateObject private var model: WorkflowDetailModel

    let workflowID: UUID
    let onSetUp: (InstalledWorkflow) -> Void
    let onRun: (InstalledWorkflow) -> Void
    let onOpenRun: (UUID) -> Void
    /// Share: the chooser before publishing, the dashboard after.
    let onShare: (InstalledWorkflow) -> Void
    /// Back to the library.
    let onDone: () -> Void
    /// Every run of it (Activity, filtered to this workflow).
    let onSeeAllRuns: (InstalledWorkflow) -> Void
    /// What the page was opened to do (the automate popover, Home), once.
    var takeIntent: () -> WorkflowAutomationIntent? = { nil }
    let actionMenu: (InstalledWorkflow) -> Actions

    @State private var tagText = ""
    @State private var editingTags = false
    @State private var pageWidth: CGFloat = 0

    /// Settings-search results that open More Options.
    static var moreOptionsAnchors: Set<String> {
        [
            "workflows.orchestratorVisible", "workflows.teammatesCanRun", "workflows.selfHeal",
            "workflows.savedAnswers", "workflows.storedData", "workflows.tags", "workflows.moreOptions",
        ]
    }

    init(
        workflowID: UUID,
        onSetUp: @escaping (InstalledWorkflow) -> Void,
        onRun: @escaping (InstalledWorkflow) -> Void,
        onOpenRun: @escaping (UUID) -> Void,
        onShare: @escaping (InstalledWorkflow) -> Void,
        onDone: @escaping () -> Void,
        onSeeAllRuns: @escaping (InstalledWorkflow) -> Void,
        takeIntent: @escaping () -> WorkflowAutomationIntent? = { nil },
        actionMenu: @escaping (InstalledWorkflow) -> Actions
    ) {
        self.workflowID = workflowID
        self.onSetUp = onSetUp
        self.onRun = onRun
        self.onOpenRun = onOpenRun
        self.onShare = onShare
        self.onDone = onDone
        self.onSeeAllRuns = onSeeAllRuns
        self.takeIntent = takeIntent
        self.actionMenu = actionMenu
        _model = StateObject(wrappedValue: WorkflowDetailModel(workflowID: workflowID))
    }

    private static var runsColumnWidth: CGFloat { 300 }

    /// Room for the reading column and the runs column beside it.
    private var isWide: Bool {
        pageWidth >= WorkflowLibraryLayout.columnWidth + Self.runsColumnWidth + theme.space.s32 * 3
    }

    var body: some View {
        VStack(spacing: theme.space.s0) {
            if let workflow = store.workflow(id: workflowID) {
                let needsSetup = model.report?.hasBlockers ?? workflow.needsSetup
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: theme.space.s32) {
                            header(workflow, needsSetup: needsSetup)
                            nameNotice(workflow)
                            HStack(alignment: .top, spacing: theme.space.s32) {
                                VStack(alignment: .leading, spacing: theme.space.s32) {
                                    if !isWide { recentRuns(workflow, needsSetup: needsSetup) }
                                    WorkflowAutomationsSection(workflow: workflow, needsSetup: needsSetup, takeIntent: takeIntent)
                                    whatItDoes(workflow)
                                    moreOptions(workflow)
                                }
                                .frame(maxWidth: WorkflowLibraryLayout.columnWidth, alignment: .leading)
                                if isWide {
                                    recentRuns(workflow, needsSetup: needsSetup)
                                        .frame(width: Self.runsColumnWidth)
                                }
                            }
                        }
                        .frame(
                            maxWidth: WorkflowLibraryLayout.columnWidth
                                + (isWide ? Self.runsColumnWidth + theme.space.s32 : 0),
                            alignment: .leading
                        )
                        .padding(.horizontal, theme.space.s24)
                        .padding(.top, WorkflowLibraryLayout.pageTopInset(theme))
                        .padding(.bottom, theme.space.s48)
                        .frame(maxWidth: .infinity)
                    }
                    .onGeometryChange(for: CGFloat.self, of: \.size.width) { pageWidth = $0 }
                    .onAppear { scrollToLanding(highlight.pending, proxy: proxy) }
                    .onChange(of: highlight.pending) { _, id in scrollToLanding(id, proxy: proxy) }
                }
                .environment(\.settingsLandingPending, highlight.pending)
            } else {
                Spacer()
                SettingsEmptyState(
                    inline: "trash", title: "This workflow was uninstalled.",
                    hint: "Its template is still under New Workflow, ready to add again.",
                    action: .init(title: L("Back"), icon: "chevron.left", handler: onDone))
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.surface.canvas)
    }

    /// A search landed on a control of this page: scroll to it once More
    /// Options has had a moment to open.
    private func scrollToLanding(_ id: String?, proxy: ScrollViewProxy) {
        guard let id, id.hasPrefix("workflows.") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            withAnimation(theme.motion.standard) { proxy.scrollTo(id, anchor: .center) }
        }
    }

    // MARK: - Header

    /// Name, one-line summary, and the one thing to do: Run now, or Set Up…
    /// while something blocks the run. Everything else is in ⋯.
    private func header(_ workflow: InstalledWorkflow, needsSetup: Bool) -> some View {
        WorkflowPageHeader(title: workflow.name, subtitle: workflow.summary) {
            if let published = registryRecords.record(for: workflow.templateID) {
                publishedChip(published, workflow: workflow)
            }
        } actions: {
            if needsSetup {
                SettingsButton(.primary, "Set Up…", icon: "wrench.and.screwdriver", help: "Finish setup so it can run") {
                    onSetUp(workflow)
                }
            } else {
                SettingsButton(.primary, "Run Now", icon: "play.fill", help: "Run now (⌘Return)") { onRun(workflow) }
                    .keyboardShortcut(.return, modifiers: .command)
            }
            HStack(spacing: theme.space.s0) {
                actionMenu(workflow)
                    .settingsLandingAnchor("workflows.edit")
            }
            .settingsLandingAnchor("workflows.rename")
        } status: {
            WorkflowDetailStatusLine(workflow: workflow, needsSetup: needsSetup, lastRun: model.recordedRuns.first)
        }
    }

    /// Only once it is published: who can see it, and whether the store's
    /// review wants something. Click to manage.
    @ViewBuilder
    private func publishedChip(_ published: WorkflowRegistryRecord, workflow: InstalledWorkflow) -> some View {
        let review = PublishReviewState(record: published)
        Button {
            onShare(workflow)
        } label: {
            StatusChip(
                WorkflowShareCopy.status(published, includesReview: false), tone: .neutral,
                icon: published.isLive ? published.visibility.symbol : "eye.slash")
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .help(
            !published.isLive
                ? L("Taken down. Click to publish again.")
                : review.chipText != nil ? L("\(review.detail()) Click to manage.") : L("Published. Click to manage."))
        if published.isLive, review.chipText != nil || review.unseen {
            Button {
                onShare(workflow)
            } label: {
                PublishReviewChip(record: published)
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
        }
    }

    // MARK: - Name

    /// The pinned version carries another name than the one agents call.
    /// Updating never renames a workflow on its own; this is where the
    /// person picks one.
    @ViewBuilder
    private func nameNotice(_ workflow: InstalledWorkflow) -> some View {
        if let pinned = workflow.nameMismatch {
            SettingsCallout(
                icon: "character.cursor.ibeam",
                title: L("Version \(workflow.templateVersion) is named “\(pinned)”"),
                message: L("Agents still call this workflow “\(workflow.name)”. Use the new name, or keep this one."),
                tone: .info
            ) {
                SettingsButton(.primary, L("Use “\(pinned)”"), verbatim: true) {
                    do {
                        let renamed = try store.rename(id: workflow.id, to: pinned)
                        _ = ToastManager.shared.success(L("Renamed to \(renamed.name)"))
                    } catch {
                        _ = ToastManager.shared.error(L("Rename"), message: WorkflowErrorText.text(error))
                    }
                }
                SettingsButton(.secondary, L("Keep “\(workflow.name)”"), verbatim: true) {
                    WorkflowErrorText.saving(L("Couldn’t keep the name")) { try store.keepName(id: workflow.id) }
                }
            }
        }
    }

    // MARK: - Recent Runs

    private func recentRuns(_ workflow: InstalledWorkflow, needsSetup: Bool) -> some View {
        WorkflowRecentRuns(
            workflow: workflow, recorded: model.recordedRuns, needsSetup: needsSetup, onRun: { onRun(workflow) },
            onOpenRun: onOpenRun,
            onSeeAll: { onSeeAllRuns(workflow) })
    }

    // MARK: - What It Does

    /// Its steps in run order, what it needs from you and gives back, and
    /// what it touches on this Mac, when it touches anything.
    private func whatItDoes(_ workflow: InstalledWorkflow) -> some View {
        let definition = workflow.definition
        let inputs = WorkflowSummary.inputs(definition)
        let outputs = WorkflowSummary.outputs(definition)
        let steps = WorkflowSummary.steps(definition)
        let access = WorkflowAccessScope.derive(definition)
        let touchesFiles =
            !access.sources.isEmpty || access.asksToRead || access.asksToWrite || access.runsInSandbox
            || !access.hostReach.isEmpty
        let hosts = workflow.template.requirements.network
        return SettingsSection(
            title: "What It Does", caption: WorkflowCardFacts.steps(definition), layout: .plain
        ) {
            if !steps.isEmpty { WorkflowFlowViewerButton(source: .workflow(workflow.id)) }
        } content: {
            if steps.isEmpty {
                Text("No steps yet. Edit it to add some.", bundle: .module)
                    .font(SettingsFont.rowDescription)
                    .foregroundStyle(theme.text.secondary)
            }
            let facts = [
                inputs.isEmpty ? nil : WorkflowStepList.Fact(icon: "arrow.right.circle", text: L("You give it: \(WorkflowSummary.list(inputs)).")),
                outputs.isEmpty ? nil : WorkflowStepList.Fact(icon: "arrow.down.circle", text: L("You get: \(WorkflowSummary.list(outputs)).")),
                touchesFiles ? WorkflowStepList.Fact(icon: "folder", text: access.architectSentence) : nil,
                hosts.isEmpty ? nil : WorkflowStepList.Fact(icon: "network", text: L("It connects to \(WorkflowSummary.list(hosts)).")),
                model.locality.map { WorkflowStepList.Fact(icon: $0.icon, text: $0.text + ".") },
            ].compactMap { $0 }
            if !steps.isEmpty || !facts.isEmpty {
                WorkflowStepList(steps: steps, facts: facts)
            }
        }
    }

    // MARK: - More Options

    /// What only some people change: closed until asked for.
    private func moreOptions(_ workflow: InstalledWorkflow) -> some View {
        SettingsAdvancedDisclosure(title: "More Options", anchorIds: Self.moreOptionsAnchors) {
            beforeItRuns(workflow)
            whoCanStart(workflow)
            SavedAnswersSection(workflowID: workflow.id, definition: workflow.definition)
            WorkflowStoredDataSection(workflowID: workflow.id, definition: workflow.definition)
            tags(workflow)
            technicalName(workflow)
        }
        .settingsLandingAnchor("workflows.moreOptions")
    }

    private func subheading(_ title: LocalizedStringKey) -> some View {
        Text(title, bundle: .module)
            .textStyle(.body, weight: 600)
            .foregroundStyle(theme.text.primary)
            .accessibilityAddTraits(.isHeader)
    }

    private func note(_ text: String) -> some View {
        Text(verbatim: text)
            .font(SettingsFont.caption)
            .foregroundColor(theme.isDark ? theme.text.tertiary : theme.text.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Before It Runs

    /// Whether this Mac has what it needs, then what it uses, with the one
    /// button that changes it.
    private func beforeItRuns(_ workflow: InstalledWorkflow) -> some View {
        // What its steps reach, including through the workflows they run.
        let reach = WorkflowRequirementsDeriver.reach(workflow.definition) { store.workflow(named: $0)?.definition }
        let reqs = reach.requirements
        let tools = workflow.definition.calledTools
        let usesNothing =
            reqs.models.isEmpty && reqs.secrets.isEmpty && reqs.network.isEmpty && tools.isEmpty
            && reqs.dependencies.isEmpty && reqs.folders.isEmpty && workflow.bindings.folderGrants.isEmpty
            && workflow.bindings.folderReadGrants.isEmpty && workflow.bindings.replaceGrants.isEmpty
            && reach.subworkflows.isEmpty
        let report = model.report
        let missingKeys = report.map(SetupChecker.missingKeys) ?? []
        return VStack(alignment: .leading, spacing: theme.space.s10) {
            HStack(spacing: theme.space.s8) {
                subheading("Before It Runs")
                Spacer(minLength: theme.space.s8)
                if report?.hasBlockers == true || !usesNothing {
                    SettingsButton(
                        report?.hasBlockers == true ? .primary : .secondary,
                        report?.hasBlockers == true ? "Set Up…" : "Change…", size: .compact
                    ) { onSetUp(workflow) }
                }
            }
            if let report, report.hasBlockers {
                AgentSetupChecklistView(report: report)
            } else if report != nil, missingKeys.isEmpty {
                StepDoneBanner(text: L("Ready to run on this Mac."))
            }
            if !missingKeys.isEmpty {
                HStack(alignment: .top, spacing: theme.space.s8) {
                    note(L("No shared value for \(missingKeys.joined(separator: ", ")) yet. Add one in the Vault."))
                    Spacer(minLength: 0)
                    SettingsButton(.secondary, "Open Vault", icon: "key", size: .compact) {
                        WorkflowRunLauncher.openKeys()
                    }
                }
            }
            if usesNothing {
                if report == nil { note(L("It needs nothing else to run.")) }
            } else {
                VStack(spacing: theme.space.s0) {
                    ForEach(reqs.models) { slot in
                        requirementRow(
                            "cube",
                            modelLabel(slot, in: workflow, slotCount: reqs.models.count),
                            runsOn(slot, in: workflow)
                        )
                    }
                    ForEach(reqs.secrets) { secret in
                        let status = secretStatus(secret.key, in: workflow)
                        requirementRow("key", secret.label, status.text, isProblem: status.isProblem)
                    }
                    if !reqs.network.isEmpty {
                        requirementRow("network", L("Internet access"), reqs.network.joined(separator: ", "))
                    }
                    ForEach(reach.subworkflows) { child in
                        requirementRow(
                            "flowchart",
                            L("Runs \(child.name)"),
                            TemplateImportReviewView.summary(of: child),
                            isProblem: child.requirements == nil
                        )
                    }
                    ForEach(tools, id: \.name) { tool in
                        requirementRow(
                            "wrench.and.screwdriver",
                            tool.name,
                            WorkflowToolCatalog.status(of: tool.name)
                        )
                    }
                    ForEach(reqs.dependencies) { dependency in
                        let status = WorkflowSandboxEnvironment.shared.status(
                            of: dependency,
                            environmentID: workflow.templateID
                        )
                        requirementRow(
                            "shippingbox",
                            dependency.summary,
                            WorkflowDependenciesStep.label(status),
                            isProblem: status != .installed
                        )
                    }
                    if !reqs.dependencies.isEmpty {
                        note(L("Installed in this workflow's own sandbox."))
                    }
                    ForEach(reqs.folders) { folder in
                        let path = workflow.bindings.folders[folder.key]
                        requirementRow("folder", folder.label, path ?? L("Not chosen yet"), isProblem: path == nil)
                    }
                    ForEach(workflow.bindings.folderGrants, id: \.self) { path in
                        folderGrantRow(path, title: L("Always allowed to save")) {
                            store.removeFolderGrant(path, id: workflow.id)
                        }
                    }
                    ForEach(workflow.bindings.folderReadGrants, id: \.self) { path in
                        folderGrantRow(path, title: L("Always allowed to read")) {
                            store.removeFolderGrant(path, id: workflow.id)
                        }
                    }
                    ForEach(workflow.bindings.replaceGrants, id: \.self) { path in
                        folderGrantRow(path, title: L("Always allowed to replace files"), symbol: "arrow.triangle.2.circlepath") {
                            store.removeReplaceGrant(path, id: workflow.id)
                        }
                    }
                }
            }
        }
    }

    /// A folder the person chose "Always allow" for from a run's card.
    private func folderGrantRow(
        _ path: String, title: String, symbol: String = "folder.badge.checkmark", remove: @escaping () -> Void
    ) -> some View {
        HStack(spacing: theme.space.s10) {
            LibraryIcon(symbol: symbol, tint: theme.text.secondary, size: 22)
            Text(verbatim: title)
                .font(SettingsFont.compactLabel)
                .foregroundColor(theme.text.primary)
                .lineLimit(1)
            Spacer(minLength: theme.space.s8)
            Text(verbatim: path)
                .font(SettingsFont.caption)
                .foregroundColor(theme.text.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(path)
            SettingsButton(.secondary, "Remove", size: .compact, action: remove)
        }
        .padding(.vertical, theme.space.s6)
    }

    /// Where a key's value comes from: a connection, the shared Keys, or
    /// only some agents' own values. A key a nested workflow declares is
    /// looked up under that workflow.
    private func secretStatus(_ key: String, in workflow: InstalledWorkflow) -> (text: String, isProblem: Bool) {
        let owner =
            workflow.template.requirements.secrets.contains { $0.key == key }
            ? workflow
            : workflow.definition.subworkflowNames.lazy.compactMap { store.workflow(named: $0) }
                .first { $0.template.requirements.secrets.contains { $0.key == key } }
        guard let owner else { return (L("Missing"), true) }
        if let bound = owner.bindings.secrets[key], WorkflowSecretsKeychain.isConnectionAccount(bound) {
            switch SetupChecker.liveConnectionState(bound) {
            case .ready: return (connectionSessionStatus(bound), false)
            case .signInNeeded: return (L("Sign in again"), true)
            case .missing: return (L("Connection gone"), true)
            }
        }
        if WorkflowCredentials.isSetUp(scope: owner.id, key: key) { return (L("Shared"), false) }
        let agents = WorkflowCredentials.agentsWithOwnValue(scope: owner.id, key: key)
            .compactMap { AgentManager.shared.agent(for: $0)?.displayName }
        if !agents.isEmpty { return (L("Only for \(agents.joined(separator: ", "))"), true) }
        return (L("Missing"), true)
    }

    /// "Session: Work · Scout uses Personal": the workflow's own pick and
    /// the agents that sign in with another session of the same service.
    private func connectionSessionStatus(_ bound: String) -> String {
        let state = SignInSessionResolver.state
        guard let id = WorkflowSecretsKeychain.connectionID(of: bound), let picked = state.session(id: id) else {
            return L("Connection")
        }
        let others = state.assignments(for: picked.service).filter { $0.session.id != picked.id }
            .compactMap { pair in
                AgentManager.shared.agent(for: pair.agentId).map { L("\($0.displayName) uses \(pair.session.name)") }
            }
        return ([L("Signs in with \(picked.name)")] + others).joined(separator: " · ")
    }

    private func requirementRow(_ icon: String, _ label: String, _ value: String, isProblem: Bool = false)
        -> some View
    {
        HStack(spacing: theme.space.s10) {
            LibraryIcon(symbol: icon, tint: theme.text.secondary, size: 22)
            Text(verbatim: label)
                .font(SettingsFont.compactLabel)
                .foregroundColor(theme.text.primary)
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: theme.space.s8)
            Text(verbatim: value)
                .font(SettingsFont.caption)
                .foregroundColor(isProblem ? theme.statusInk(.warning) : theme.text.secondary)
                .multilineTextAlignment(.trailing)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(.vertical, theme.space.s6)
    }

    private func modelLabel(_ slot: ModelRequirement, in workflow: InstalledWorkflow, slotCount: Int) -> String {
        guard slotCount > 1 else { return L("Runs on") }
        return WorkflowSummary.slotLabel(slot.slot, in: workflow.definition)
    }

    private func runsOn(_ slot: ModelRequirement, in workflow: InstalledWorkflow) -> String {
        guard let env = model.environment,
            let resolved = SetupChecker.resolvedModel(for: slot, bindings: workflow.bindings, environment: env)
        else { return L("Not chosen yet") }
        return WorkflowModelChoices.runsOn(resolved)
    }

    // MARK: Who Can Start It

    private func whoCanStart(_ workflow: InstalledWorkflow) -> some View {
        VStack(alignment: .leading, spacing: theme.space.s12) {
            subheading("Who Can Start It")
            SettingsToggle(
                title: "Osaurus can run this for you",
                description: "When you ask in chat, Osaurus may start it.",
                anchorId: "workflows.orchestratorVisible",
                isOn: Binding(
                    get: { workflow.orchestratorVisible },
                    set: { on in
                        WorkflowErrorText.saving(L("Couldn’t save the setting")) { try store.setOrchestratorVisible(on, id: workflow.id) }
                    }
                )
            )
            SettingsToggle(
                title: "Teammates can run this",
                description: "People using an agent you shared can start it. It runs on this Mac and asks you first.",
                anchorId: "workflows.teammatesCanRun",
                isOn: Binding(
                    get: { workflow.teammatesCanRun },
                    set: { on in
                        WorkflowErrorText.saving(L("Couldn’t save the setting")) { try store.setTeammatesCanRun(on, id: workflow.id) }
                    }
                )
            )
            SettingsToggle(
                title: L("Fix repeated failures automatically"),
                description: L(
                    "After the same step fails \(WorkflowSelfHealMonitor.threshold) runs in a row, Osaurus drafts a fix for you to review."
                ),
                anchorId: "workflows.selfHeal",
                verbatim: true,
                isOn: Binding(
                    get: { workflow.selfHeal },
                    set: { on in
                        WorkflowErrorText.saving(L("Couldn’t save the setting")) { try store.setSelfHeal(on, id: workflow.id) }
                    }
                )
            )
            agentsUsingIt(workflow)
        }
    }

    private func agentsUsingIt(_ workflow: InstalledWorkflow) -> some View {
        WorkflowAgentsUsingIt(workflowID: workflow.id)
    }

    // MARK: Tags

    /// The person's labels for finding the workflow in the sidebar. Edited
    /// as one comma-separated line; saved on Return or Save.
    private func tags(_ workflow: InstalledWorkflow) -> some View {
        VStack(alignment: .leading, spacing: theme.space.s8) {
            HStack(spacing: theme.space.s8) {
                subheading("Tags")
                Spacer(minLength: theme.space.s8)
                if editingTags {
                    SettingsButton(.secondary, "Cancel", size: .compact) { editingTags = false }
                    SettingsButton(.primary, "Save", size: .compact) { commitTags(workflow) }
                } else {
                    SettingsButton(.secondary, workflow.tags.isEmpty ? "Add Tags" : "Edit", size: .compact) {
                        tagText = workflow.tags.joined(separator: ", ")
                        editingTags = true
                    }
                }
            }
            if editingTags {
                SettingsTextField(placeholder: L("finance, weekly, reports"), text: $tagText, autofocus: true)
                    .onSubmit { commitTags(workflow) }
                note(L("Separate tags with commas, up to \(InstalledWorkflow.maximumTags). They stay on this Mac."))
            } else if workflow.tags.isEmpty {
                note(L("Tags help you find it in the sidebar's search."))
            } else {
                FlowLayout(spacing: theme.space.s6) {
                    ForEach(workflow.tags, id: \.self) { tag in
                        StatusChip(tag)
                    }
                }
            }
        }
        .settingsLandingAnchor("workflows.tags")
    }

    private func commitTags(_ workflow: InstalledWorkflow) {
        WorkflowErrorText.saving(L("Couldn’t save the tags")) { try store.setTags(InstalledWorkflow.parseTags(tagText), id: workflow.id) }
        editingTags = false
    }

    // MARK: Technical name

    private func technicalName(_ workflow: InstalledWorkflow) -> some View {
        HStack(spacing: theme.space.s8) {
            Text("Technical name", bundle: .module)
                .font(SettingsFont.rowDescription)
                .foregroundColor(theme.text.secondary)
            Spacer(minLength: theme.space.s8)
            Text(workflow.toolName)
                .font(SettingsFont.monoSmall)
                .foregroundColor(theme.text.secondary)
                .textSelection(.enabled)
        }
        .help(L("The name agents use to call it."))
    }
}

// MARK: - Live parts

/// The line under the header: where a run going now is, else whether it
/// runs on its own, else how the last run went. The only part of the
/// header that watches runs.
private struct WorkflowDetailStatusLine: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var live = WorkflowLiveRuns.shared
    let workflow: InstalledWorkflow
    let needsSetup: Bool
    let lastRun: WorkflowRun?

    var body: some View {
        let going = live.going(of: workflow.id).first
        let line = WorkflowStatusLine.line(
            needsSetup: needsSetup, liveRun: going, liveStepName: going?.stepName(in: workflow.definition),
            automations: EventManager.shared.events(forWorkflowID: workflow.id), lastRun: lastRun)
        HStack(spacing: theme.space.s6) {
            Group {
                if let going, !going.isWaitingOnYou {
                    SettingsSpinner(size: .mini)
                } else {
                    Circle()
                        .fill(line.tone.map(theme.statusInk) ?? theme.text.tertiary)
                        .frame(width: theme.space.s6, height: theme.space.s6)
                }
            }
            .frame(width: theme.space.s12, height: theme.space.s12)
            .accessibilityHidden(true)
            Text(verbatim: line.text)
                .font(SettingsFont.rowDescription)
                .foregroundStyle(
                    line.tone == .warning || line.tone == .error
                        ? line.tone.map(theme.statusInk) ?? theme.text.secondary : theme.text.secondary
                )
                .fixedSize(horizontal: false, vertical: true)
        }
        .animation(theme.motion.quick, value: line.text)
    }
}

/// Did it work: one sentence about the last runs, the runs going now on
/// top, then the last few, each opening its run page.
private struct WorkflowRecentRuns: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var live = WorkflowLiveRuns.shared
    @ObservedObject private var agents = AgentManager.shared
    let workflow: InstalledWorkflow
    /// Settled, newest first.
    let recorded: [WorkflowRun]
    let needsSetup: Bool
    let onRun: () -> Void
    let onOpenRun: (UUID) -> Void
    let onSeeAll: () -> Void

    private static var shownRunCount: Int { 5 }
    private static var summaryRunCount: Int { 10 }

    private enum Item: Identifiable {
        case going(WorkflowLiveRuns.Summary)
        case settled(WorkflowRun)

        var id: UUID {
            switch self {
            case .going(let summary): return summary.id
            case .settled(let run): return run.id
            }
        }
    }

    var body: some View {
        let going = live.going(of: workflow.id)
        let goingIDs = Set(going.map(\.id))
        let settled = recorded.filter { !goingIDs.contains($0.id) }
        let items = going.map(Item.going) + settled.prefix(Self.shownRunCount).map(Item.settled)
        let bars = WorkflowHealth.bars(newestFirst: WorkflowHealth.outcomes(settled), count: Self.summaryRunCount)
        SettingsSection(title: "Recent Runs", layout: .plain) {
            if !items.isEmpty {
                WorkflowTextLink(title: L("See all"), action: onSeeAll)
                    .help(L("Every run of this workflow"))
            }
        } content: {
            if items.isEmpty {
                empty
            } else {
                if let headline = WorkflowHealth.headline(bars, running: going.count) {
                    Text(verbatim: headline)
                        .font(SettingsFont.rowDescription)
                        .foregroundStyle(theme.text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                WorkflowRowList(items: items) { item in
                    switch item {
                    case .going(let summary):
                        WorkflowRunRow(
                            status: summary.status, title: WorkflowRunPresentation.shortStatus(summary.status),
                            line: summary.progress(stepName: summary.stepName(in: workflow.definition)),
                            time: .elapsed(since: summary.startedAt)
                        ) { onOpenRun(summary.id) }
                    case .settled(let run):
                        let event = run.caller.eventID.flatMap { EventManager.shared.event(for: $0) }
                        WorkflowRunRow(
                            status: run.status, title: WorkflowRunWords.when(run.startedAt),
                            line: WorkflowRunWords.detail(run, event: event) { agents.agent(for: $0)?.displayName },
                            lineIsProblem: run.status == .failed || run.status == .needsSetup
                        ) { onOpenRun(run.id) }
                    }
                }
                .animation(theme.motion.quick, value: items.map(\.id))
            }
        }
        .settingsLandingAnchor("workflows.recentRuns")
    }

    /// One quiet row in the runs' place. Until setup is done the header's
    /// Set Up… is the only thing to do, so it offers no run.
    private var empty: some View {
        HStack(alignment: .center, spacing: theme.space.s12) {
            Image(systemName: "clock")
                .glyphSize(.footnote, weight: .semibold)
                .foregroundStyle(theme.text.tertiary)
                .frame(width: theme.space.s16, height: theme.space.s16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: theme.space.s2) {
                Text("No runs yet", bundle: .module)
                    .textStyle(.body, weight: 500)
                    .foregroundStyle(theme.text.primary)
                Text(needsSetup ? "Finish setup, then try it." : "Try it once to see what you get.", bundle: .module)
                    .font(SettingsFont.footnote)
                    .foregroundStyle(theme.text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !needsSetup {
                SettingsButton(.secondary, "Try It Now", icon: "play.fill", size: .small, action: onRun)
            }
        }
        .padding(.horizontal, theme.space.s16)
        .padding(.vertical, theme.space.s12)
        .settingsChrome(.card)
    }
}

/// The agents that have this workflow turned on.
private struct WorkflowAgentsUsingIt: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var agents = AgentManager.shared
    let workflowID: UUID

    var body: some View {
        let users = agents.agents.filter { $0.settings.enabledWorkflowIDs.contains(workflowID) }
        VStack(alignment: .leading, spacing: theme.space.s8) {
            Text("Agents that can use it", bundle: .module)
                .font(SettingsFont.smallLabel)
                .foregroundColor(theme.text.secondary)
            if users.isEmpty {
                Text("None yet. Open an agent and turn it on under Workflows.", bundle: .module)
                    .font(SettingsFont.caption)
                    .foregroundColor(theme.isDark ? theme.text.tertiary : theme.text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                FlowLayout(spacing: theme.space.s8) {
                    ForEach(users) { agent in
                        HStack(spacing: theme.space.s6) {
                            AgentAvatarView(
                                mascotId: agent.avatar,
                                name: agent.displayName,
                                tint: theme.dataInk(seed: agent.displayName),
                                diameter: 20,
                                customImageURL: agent.customAvatarURL,
                                monogramFontSize: 9,
                                borderWidth: 1
                            )
                            Text(verbatim: agent.displayName)
                                .font(SettingsFont.compactLabel)
                                .foregroundColor(theme.text.primary)
                                .lineLimit(1)
                        }
                        .padding(.leading, theme.space.s4)
                        .padding(.trailing, theme.space.s8)
                        .padding(.vertical, theme.space.s4)
                        .settingsChrome(.subtle)
                    }
                }
            }
        }
    }
}
