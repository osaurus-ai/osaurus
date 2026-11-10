//
//  WorkflowDetailPage.swift
//  osaurus
//
//  Workflows → one workflow, pushed over the home. One
//  installed workflow on this Mac, runs first: what it is and whether it
//  can run, its runs (live ones at the top, each opening on its run page),
//  then what it does (what you give, the steps, what you get), what it
//  needs before it runs, who can start it, tags, and saved answers. Share
//  saves it as a file or publishes it to the store registry; once
//  published, Manage Published opens its dashboard.
//  The tool name agents call it by sits under Advanced.
//

import SwiftUI

struct WorkflowDetailPage<Actions: View>: View {
    @Environment(\.workflowSharedGrid) private var sharedGrid
    @Environment(\.theme) private var theme
    @ObservedObject private var store = InstalledWorkflowStore.shared
    @ObservedObject private var agents = AgentManager.shared
    @ObservedObject private var runs = WorkflowRunStore.shared
    @ObservedObject private var registryRecords = WorkflowRegistryRecordStore.shared

    let workflowID: UUID
    let onSetUp: (InstalledWorkflow) -> Void
    let onRun: (InstalledWorkflow) -> Void
    let onOpenRun: (UUID) -> Void
    /// Share: the chooser before publishing, the dashboard after.
    let onShare: (InstalledWorkflow) -> Void
    let onRename: (InstalledWorkflow) -> Void
    /// Opens it in the Architect.
    let onEdit: (InstalledWorkflow) -> Void
    /// Back to the library.
    let onDone: () -> Void
    let actionMenu: (InstalledWorkflow) -> Actions

    @State private var showsAllRuns = false
    /// Recorded runs, read when the page opens and when one of its runs
    /// ends; runs going now come from the store's live list.
    @State private var recordedRuns: [WorkflowRun] = []
    @State private var tagText = ""
    @State private var editingTags = false

    private static var collapsedRunCount: Int { 5 }

    var body: some View {
        VStack(spacing: 0) {
            if let workflow = store.workflow(id: workflowID) {
                let report = SetupChecker.check(workflow, secrets: .install, attended: true)
                ScrollView {
                    VStack(alignment: .leading, spacing: theme.space.s24) {
                        hero(workflow, report: report)
                        nameNotice(workflow)
                        recentRuns(workflow)
                        whatItDoes(workflow)
                        beforeItRuns(workflow, report: report)
                        whoCanStart(workflow)
                        tags(workflow)
                        SavedAnswersSection(workflowID: workflow.id, definition: workflow.definition)
                            .background(theme.surface.canvas)
                        WorkflowStoredDataSection(workflowID: workflow.id, definition: workflow.definition)
                            .background(theme.surface.canvas)
                        advanced(workflow)
                    }
                    .frame(maxWidth: WorkflowLibraryLayout.columnWidth, alignment: .leading)
                    .padding(.horizontal, theme.space.s24)
                    .padding(.top, WorkflowLibraryLayout.pageTopInset(theme))
                    .padding(.bottom, theme.space.s24)
                    .frame(maxWidth: .infinity)
                }
                footer(workflow)
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
        .background { if !sharedGrid { theme.surface.canvas } }
        // The home's recent runs first, so the page opens filled in; then
        // the full record, read off the main actor.
        .onAppear { recordedRuns = runs.recentRuns().filter { $0.workflowID == workflowID } }
        .task(id: endedLiveRuns) {
            // Architect tests and eval runs are not what the workflow did for anyone.
            let loaded = await runs.loadRuns(workflowID: workflowID, limit: 50, includeTests: false)
            guard !Task.isCancelled else { return }
            recordedRuns = loaded
        }
    }

    private var liveRuns: [WorkflowRun] {
        runs.live.values.filter { $0.workflowID == workflowID && !$0.isTest }
    }

    private var endedLiveRuns: Set<UUID> { Set(liveRuns.filter(\.status.isTerminal).map(\.id)) }

    /// Newest first; a run this launch knows live wins over its record.
    private var allRuns: [WorkflowRun] {
        var byID = Dictionary(recordedRuns.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for run in liveRuns { byID[run.id] = run }
        return byID.values.sorted { $0.startedAt > $1.startedAt }
    }

    // MARK: - Hero

    /// Name, one-line summary, and the facts a person checks first:
    /// can it run, how big is it, where does it run.
    private func hero(_ workflow: InstalledWorkflow, report: SetupReport) -> some View {
        SettingsDetailHeader(
            icon: "flowchart",
            title: workflow.name,
            subtitle: workflow.summary
        ) {
            let missingKeys = !SetupChecker.missingKeys(report).isEmpty
            StatusChip(
                report.hasBlockers ? L("Needs setup") : missingKeys ? L("Keys missing") : L("Ready to run"),
                tone: report.hasBlockers || missingKeys ? .warning : .success,
                icon: report.hasBlockers
                    ? "exclamationmark.circle.fill" : missingKeys ? "key.fill" : "checkmark.circle.fill"
            )
            let stepCount = workflow.definition.nodes.count
            chip(icon: "list.number", text: stepCount == 1 ? L("1 step") : L("\(stepCount) steps"))
            if let locality = locality(workflow) {
                chip(icon: locality.icon, text: locality.text)
            }
            chip(icon: "clock.arrow.circlepath", text: L("Version \(workflow.templateVersion)"))
            if let published = registryRecords.record(for: workflow.templateID) {
                let review = PublishReviewState(record: published)
                Button {
                    onShare(workflow)
                } label: {
                    chip(
                        icon: published.isLive ? published.visibility.symbol : "eye.slash",
                        text: WorkflowShareCopy.status(published, includesReview: false))
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
        } actions: {
            actionMenu(workflow)
        }
    }

    private func chip(icon: String, text: String) -> some View {
        StatusChip(text, tone: .neutral, icon: icon)
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
                message: L(
                    "Agents and the Orchestrator still call this workflow “\(workflow.name)”. Use the new name, or keep the current one."
                ),
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

    /// Where its model steps run once chosen; nil when it uses no model or
    /// none is chosen yet.
    private func locality(_ workflow: InstalledWorkflow) -> (icon: String, text: String)? {
        let env = SetupChecker.Environment.live()
        let models = workflow.template.requirements.models.compactMap {
            SetupChecker.resolvedModel(for: $0, bindings: workflow.bindings, environment: env)
        }
        guard !models.isEmpty else { return nil }
        return models.allSatisfy({ SetupChecker.isLocalModel($0, catalog: env.modelCatalog) })
            ? ("lock.laptopcomputer", L("Runs on this Mac"))
            : ("cloud", L("Uses the cloud"))
    }

    // MARK: - Cards

    private var subtleCardBorder: some View {
        RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous)
            .strokeBorder(theme.border.subtle, lineWidth: theme.stroke.default)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func card<Trailing: View, Content: View>(
        _ title: LocalizedStringKey,
        icon: String,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: theme.space.s16) {
            HStack(spacing: theme.space.s8) {
                Image(systemName: icon)
                    .glyphSize(12, weight: .semibold)
                    .foregroundColor(theme.text.secondary)
                    .frame(width: 16)
                Text(title, bundle: .module)
                    .font(SettingsFont.sectionTitle)
                    .foregroundColor(theme.text.primary)
                Spacer(minLength: 8)
                trailing()
            }
            content()
        }
        .padding(theme.space.s16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface.canvas, in: RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous))
        .overlay { subtleCardBorder }
    }

    private func card<Content: View>(
        _ title: LocalizedStringKey,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        card(title, icon: icon, trailing: { EmptyView() }, content: content)
    }

    private func note(_ text: String) -> some View {
        Text(verbatim: text)
            .font(SettingsFont.caption)
            .foregroundColor(theme.isDark ? theme.text.tertiary : theme.text.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - What It Does

    /// What you give → the steps in run order → what you get.
    private func whatItDoes(_ workflow: InstalledWorkflow) -> some View {
        let definition = workflow.definition
        let inputs = WorkflowSummary.inputs(definition)
        let outputs = WorkflowSummary.outputs(definition)
        let steps = WorkflowSummary.steps(definition)
        let catalog = ConfigModelReference.liveCatalog()
        let give = flowColumn(L("You give"), icon: "square.and.pencil") {
            if inputs.isEmpty {
                note(L("Nothing. It runs as is."))
            } else {
                labelChips(inputs)
            }
        }
        let does = flowColumn(L("Osaurus does"), icon: "gearshape.2", hasSurface: false) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                    if index > 0 {
                        Rectangle()
                            .fill(theme.border.subtle)
                            .frame(width: theme.stroke.default, height: theme.space.s12)
                            .frame(maxWidth: .infinity)
                            .accessibilityHidden(true)
                    }
                    stepRow(
                        index: index,
                        step: step,
                        badges: definition.node(step.id).map {
                            WorkflowStepRisk.badges(for: $0, in: workflow, catalog: catalog)
                        } ?? []
                    )
                    .padding(theme.space.s16)
                    .settingsChrome(.inset)
                    .overlay { subtleCardBorder }
                }
            }
        }
        let get = flowColumn(L("You get"), icon: "tray.and.arrow.down") {
            if outputs.isEmpty {
                note(L("A finished run"))
            } else {
                labelChips(outputs)
            }
        }
        let access = WorkflowAccessScope.derive(definition)
        let files = flowColumn(L("Your files"), icon: WorkflowAccessScope.Place.mac.systemImage) {
            WorkflowAccessRows(scope: access)
            note(access.architectSentence)
        }
        return card(
            "What It Does", icon: "point.topleft.down.to.point.bottomright.curvepath",
            trailing: {
                if !definition.nodes.isEmpty { WorkflowFlowViewerButton(source: .workflow(workflow.id)) }
            }
        ) {
            VStack(alignment: .leading, spacing: theme.space.s24) {
                give
                does
                get
                files
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func flowColumn<Content: View>(
        _ title: String,
        icon: String,
        hasSurface: Bool = true,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: theme.space.s12) {
            HStack(spacing: theme.space.s6) {
                Image(systemName: icon).glyphSize(10, weight: .semibold)
                Text(verbatim: title).font(SettingsFont.compactLabel)
            }
            .foregroundColor(theme.text.secondary)
            content()
        }
        .padding(hasSurface ? theme.space.s16 : 0)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .settingsChrome(hasSurface ? .inset : nil)
        .overlay { if hasSurface { subtleCardBorder } }
    }

    private func labelChips(_ labels: [String]) -> some View {
        FlowLayout(spacing: theme.space.s6) {
            ForEach(Array(labels.enumerated()), id: \.offset) { _, label in
                StatusChip(label)
            }
        }
    }

    private func stepRow(index: Int, step: WorkflowSummary.Step, badges: [WorkflowStepBadge]) -> some View {
        HStack(alignment: .top, spacing: theme.space.s12) {
            Text(verbatim: "\(index + 1)")
                .textStyle(.label, weight: 500)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .padding(.horizontal, theme.space.s2)
                .foregroundColor(theme.text.inverse)
                .frame(width: theme.space.s16, height: theme.space.s16)
                .background(Circle().fill(theme.surface.inverse ?? theme.text.primary))
            VStack(alignment: .leading, spacing: theme.space.s8) {
                Text(verbatim: step.name)
                    .textStyle(.label, weight: 500)
                    .foregroundColor(theme.text.primary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 4) {
                    Image(systemName: step.icon).glyphSize(9)
                    Text(verbatim: step.kind).font(SettingsFont.footnote)
                }
                .foregroundColor(theme.isDark ? theme.text.tertiary : theme.text.secondary)
                if !badges.isEmpty {
                    WorkflowStepBadgesView(badges: badges)
                        .padding(.top, theme.space.s2)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Before It Runs

    /// Whether this Mac has what it needs, then what it uses, with the one
    /// button that changes it.
    private func beforeItRuns(_ workflow: InstalledWorkflow, report: SetupReport) -> some View {
        // What its steps reach, including through the workflows they run.
        let reach = WorkflowRequirementsDeriver.reach(workflow.definition) { store.workflow(named: $0)?.definition }
        let reqs = reach.requirements
        let tools = workflow.definition.calledTools
        let usesNothing =
            reqs.models.isEmpty && reqs.secrets.isEmpty && reqs.network.isEmpty && tools.isEmpty
            && reqs.dependencies.isEmpty && reqs.folders.isEmpty && workflow.bindings.folderGrants.isEmpty
            && workflow.bindings.folderReadGrants.isEmpty && workflow.bindings.replaceGrants.isEmpty
            && reach.subworkflows.isEmpty
        return card("Before It Runs", icon: "checklist") {
            if report.hasBlockers {
                Button {
                    onSetUp(workflow)
                } label: {
                    Text("Set Up…", bundle: .module)
                }
                .assignedSettingsButtonStyle(.primary, size: .compact)
            } else {
                Button {
                    onSetUp(workflow)
                } label: {
                    Text("Change…", bundle: .module)
                }
                .assignedSettingsButtonStyle(.secondary, size: .compact)
            }
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                if report.hasBlockers {
                    AgentSetupChecklistView(report: report)
                } else if SetupChecker.missingKeys(report).isEmpty {
                    StepDoneBanner(text: L("Ready to run on this Mac."))
                }
                let missingKeys = SetupChecker.missingKeys(report)
                if !missingKeys.isEmpty {
                    HStack(alignment: .top, spacing: theme.space.s8) {
                        note(
                            L("No shared value for \(missingKeys.joined(separator: ", ")). Runs without an agent stop until you add it in the Vault; an agent with its own value can still run this."))
                        Spacer(minLength: 0)
                        SettingsButton(.secondary, "Open Vault", icon: "key", size: .compact) {
                            WorkflowRunLauncher.openKeys()
                        }
                    }
                }
                if usesNothing {
                    note(L("It needs no models, keys, tools, or internet access."))
                } else {
                    VStack(spacing: 0) {
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
                            note(
                                L("Shell steps run in this workflow's own sandbox, where these packages are installed.")
                            )
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
    }

    /// A folder the person chose "Always allow" for from a run's card.
    private func folderGrantRow(
        _ path: String, title: String, symbol: String = "folder.badge.checkmark", remove: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            LibraryIcon(symbol: symbol, tint: theme.text.secondary, size: 22)
            Text(verbatim: title)
                .font(SettingsFont.compactLabel)
                .foregroundColor(theme.text.primary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(verbatim: path)
                .font(SettingsFont.caption)
                .foregroundColor(theme.text.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Button {
                remove()
            } label: {
                Text("Remove", bundle: .module)
            }
            .assignedSettingsButtonStyle(.secondary, size: .compact)
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
        HStack(spacing: 10) {
            LibraryIcon(symbol: icon, tint: theme.text.secondary, size: 22)
            Text(verbatim: label)
                .font(SettingsFont.compactLabel)
                .foregroundColor(theme.text.primary)
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 8)
            Text(verbatim: value)
                .font(SettingsFont.caption)
                .foregroundColor(isProblem ? theme.statusInk.warning : theme.text.secondary)
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
        guard let model = SetupChecker.resolvedModel(for: slot, bindings: workflow.bindings, environment: .live())
        else { return L("Not chosen yet") }
        return WorkflowModelChoices.runsOn(model)
    }

    // MARK: - Who Can Start It

    private func whoCanStart(_ workflow: InstalledWorkflow) -> some View {
        let users = agents.agents.filter { $0.settings.enabledWorkflowIDs.contains(workflow.id) }
        return card("Who Can Start It", icon: "person.2") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Osaurus can run this for you", bundle: .module)
                            .font(SettingsFont.compactLabel)
                            .foregroundColor(theme.text.primary)
                        Text("When you ask in chat, Osaurus may start this workflow on its own.", bundle: .module)
                            .font(SettingsFont.rowDescription)
                            .foregroundColor(theme.text.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    Toggle(
                        isOn: Binding(
                            get: { workflow.orchestratorVisible },
                            set: { on in WorkflowErrorText.saving(L("Couldn’t save the setting")) { try store.setOrchestratorVisible(on, id: workflow.id) } }
                        )
                    ) {
                        Text("Osaurus can run this for you", bundle: .module)
                    }
                    .settingsSwitch()
                }
                .settingsLandingAnchor("workflows.orchestratorVisible")

                Divider().opacity(0.5)

                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Teammates can run this", bundle: .module)
                            .font(SettingsFont.compactLabel)
                            .foregroundColor(theme.text.primary)
                        Text(
                            "People chatting with an agent you shared may start this workflow through that agent. It runs on this Mac with your keys and folders. Each call asks you first, so the agent needs Require Approval for Teammate Tool Calls turned on.",
                            bundle: .module
                        )
                        .font(SettingsFont.rowDescription)
                        .foregroundColor(theme.text.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    Toggle(
                        isOn: Binding(
                            get: { workflow.teammatesCanRun },
                            set: { on in WorkflowErrorText.saving(L("Couldn’t save the setting")) { try store.setTeammatesCanRun(on, id: workflow.id) } }
                        )
                    ) {
                        Text("Teammates can run this", bundle: .module)
                    }
                    .settingsSwitch()
                }
                .settingsLandingAnchor("workflows.teammatesCanRun")

                Divider().opacity(0.5)

                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Fix repeated failures automatically", bundle: .module)
                            .font(SettingsFont.compactLabel)
                            .foregroundColor(theme.text.primary)
                        Text(
                            "When the same step fails \(WorkflowSelfHealMonitor.threshold) runs in a row, the Architect drafts a fix in a background chat and notifies you. Nothing is saved until you review it.",
                            bundle: .module
                        )
                        .font(SettingsFont.rowDescription)
                        .foregroundColor(theme.text.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    Toggle(
                        isOn: Binding(
                            get: { workflow.selfHeal },
                            set: { on in WorkflowErrorText.saving(L("Couldn’t save the setting")) { try store.setSelfHeal(on, id: workflow.id) } }
                        )
                    ) {
                        Text("Fix repeated failures automatically", bundle: .module)
                    }
                    .settingsSwitch()
                }
                .settingsLandingAnchor("workflows.selfHeal")

                Divider().opacity(0.5)

                Text("Agents that can use it", bundle: .module)
                    .font(SettingsFont.smallLabel)
                    .foregroundColor(theme.text.secondary)
                if users.isEmpty {
                    note(L("None yet. To give it to an agent, open the agent and turn it on under Workflows."))
                } else {
                    FlowLayout(spacing: 8) {
                        ForEach(users) { agent in
                            HStack(spacing: 6) {
                                AgentAvatarView(
                                    mascotId: agent.avatar,
                                    name: agent.displayName,
                                    tint: agentColorFor(agent.displayName),
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

    // MARK: - Recent Runs

    /// Every run, live ones filling in as they go; each opens its run page.
    private func recentRuns(_ workflow: InstalledWorkflow) -> some View {
        let list = allRuns
        let shown = showsAllRuns ? list : Array(list.prefix(Self.collapsedRunCount))
        return card("Runs", icon: "clock") {
            SettingsButton(.tertiary, "All Tasks", size: .compact) {
                TaskControl.showHistory(.workflow(workflow.id))
            }
            .help(L("Every run of this workflow in Tasks → History"))
            if list.count > Self.collapsedRunCount {
                SettingsButton(
                    .tertiary, showsAllRuns ? L("Show Less") : L("Show All \(list.count)"), size: .compact,
                    verbatim: true
                ) {
                    withAnimation(theme.motion.quick) { showsAllRuns.toggle() }
                }
            }
        } content: {
            if list.isEmpty {
                SettingsEmptyState(
                    inline: "clock", title: "No runs yet",
                    hint: "Press Run to try it. Runs agents and automations start show up here too.")
            } else {
                VStack(alignment: .leading, spacing: theme.space.s2) {
                    ForEach(shown) { run in
                        WorkflowRunCompactRow(run: run, definition: workflow.definition) { onOpenRun(run.id) }
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .padding(.horizontal, -theme.space.s8)
                .animation(theme.motion.quick, value: shown.map(\.id))
            }
        }
    }

    // MARK: - Advanced

    private func advanced(_ workflow: InstalledWorkflow) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("Agents call it as", bundle: .module)
                        .font(SettingsFont.rowDescription)
                        .foregroundColor(theme.text.tertiary)
                    Text(workflow.toolName)
                        .font(SettingsFont.monoSmall)
                        .foregroundColor(theme.text.secondary)
                        .textSelection(.enabled)
                }
                Text("Osaurus starts it with run_workflow.", bundle: .module)
                    .font(SettingsFont.rowDescription)
                    .foregroundColor(theme.text.tertiary)
            }
            .padding(.top, theme.space.s6)
        } label: {
            Text("Advanced", bundle: .module)
                .font(SettingsFont.compactLabel)
                .foregroundColor(theme.text.secondary)
        }
        .padding(theme.space.s16)
        .background(theme.surface.canvas, in: RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous))
        .overlay { subtleCardBorder }
    }

    // MARK: - Tags

    /// The person's labels for finding the workflow in the library. Edited
    /// as one comma-separated line; saved on Return or Save.
    private func tags(_ workflow: InstalledWorkflow) -> some View {
        card(
            "Tags",
            icon: "tag",
            trailing: {
                if editingTags {
                    Button {
                        editingTags = false
                    } label: {
                        Text("Cancel", bundle: .module)
                    }
                    .assignedSettingsButtonStyle(.secondary)
                    Button {
                        commitTags(workflow)
                    } label: {
                        Text("Save", bundle: .module)
                    }
                    .assignedSettingsButtonStyle(.secondary)
                } else {
                    Button {
                        tagText = workflow.tags.joined(separator: ", ")
                        editingTags = true
                    } label: {
                        Text(workflow.tags.isEmpty ? "Add Tags" : "Edit", bundle: .module)
                    }
                    .assignedSettingsButtonStyle(.secondary)
                }
            },
            content: {
                VStack(alignment: .leading, spacing: 8) {
                    if editingTags {
                        SettingsTextField(placeholder: L("finance, weekly, reports"), text: $tagText, autofocus: true)
                            .onSubmit { commitTags(workflow) }
                        note(
                            L(
                                "Separate tags with commas. Up to \(InstalledWorkflow.maximumTags); they stay on this Mac and are not exported."
                            )
                        )
                    } else if workflow.tags.isEmpty {
                        note(L("No tags yet. Tags group workflows in the library and are searchable there."))
                    } else {
                        FlowLayout(spacing: theme.space.s6) {
                            ForEach(workflow.tags, id: \.self) { tag in
                                StatusChip(tag)
                            }
                        }
                    }
                }
            }
        )
        .settingsLandingAnchor("workflows.tags")
    }

    private func commitTags(_ workflow: InstalledWorkflow) {
        WorkflowErrorText.saving(L("Couldn’t save the tags")) { try store.setTags(InstalledWorkflow.parseTags(tagText), id: workflow.id) }
        editingTags = false
    }

    // MARK: - Footer

    private func footer(_ workflow: InstalledWorkflow) -> some View {
        VStack(spacing: 0) {
            Divider().opacity(0.5)
            HStack(spacing: 10) {
                let published = registryRecords.record(for: workflow.templateID)
                Button {
                    onShare(workflow)
                } label: {
                    Label {
                        if published != nil {
                            Text("Manage Published…", bundle: .module)
                        } else {
                            Text("Share…", bundle: .module)
                        }
                    } icon: {
                        Image(systemName: published != nil ? "globe" : "square.and.arrow.up")
                    }
                }
                .assignedSettingsButtonStyle(.secondary)
                .help(
                    published != nil
                        ? Text("Stats, who can see it, versions, take down", bundle: .module)
                        : Text("Save a file, or publish a page you control", bundle: .module))
                Button {
                    onRename(workflow)
                } label: {
                    Text("Rename…", bundle: .module)
                }
                .assignedSettingsButtonStyle(.secondary)
                .help(Text("Change the name agents and the Orchestrator call this workflow by", bundle: .module))
                .settingsLandingAnchor("workflows.rename")
                Spacer()
                SettingsButton(.secondary, "Edit", icon: "pencil.and.outline", help: "Edit with the Architect") {
                    onEdit(workflow)
                }
                .settingsLandingAnchor("workflows.edit")
                SettingsButton(.primary, "Run", icon: "play.fill", help: "Run (⌘Return)") { onRun(workflow) }
                    .keyboardShortcut(.return, modifiers: .command)
            }
            .frame(maxWidth: WorkflowLibraryLayout.columnWidth)
            .padding(.horizontal, theme.space.s24)
            .padding(.vertical, theme.space.s16)
            .frame(maxWidth: .infinity)
            .background(theme.surface.canvas)
        }
    }
}
