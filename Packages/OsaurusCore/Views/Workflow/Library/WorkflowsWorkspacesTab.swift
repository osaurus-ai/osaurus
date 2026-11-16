//
//  WorkflowsWorkspacesTab.swift
//  osaurus
//
//  The Workflows window's Workspaces tab: one section per workspace this
//  Mac belongs to, with the workflows members shared there (Install, then
//  Update, Set Up or Open) and the ones teammates' agents run on their own
//  Macs (Add to My Workflows, then Run). Everything comes from
//  `WorkspaceWorkflowCatalog`, which Settings → workspace → Workflows
//  shares. Hosted workflows you added also list under All.
//

import SwiftUI

struct WorkflowsWorkspacesTab: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var catalog = WorkspaceWorkflowCatalog.shared
    @ObservedObject private var workspaces = WorkspacesService.shared
    @ObservedObject private var installed = InstalledWorkflowStore.shared
    @ObservedObject private var links = HostedWorkflowLinkStore.shared
    let windowState: ChatWindowState
    let onSetUp: (InstalledWorkflow) -> Void

    @State private var runningLink: HostedWorkflowLink?

    var body: some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: theme.space.s24) {
                if workspaces.workspaces.isEmpty {
                    SettingsEmptyState(
                        inline: "person.3", title: "You're not in a workspace yet.",
                        hint: "Workflows your workspaces share show up here.")
                } else {
                    Text(
                        "Install keeps a copy that runs here. Add to My Workflows runs it on its owner's Mac, after they approve.",
                        bundle: .module
                    )
                    .textStyle(.caption)
                    .foregroundStyle(theme.text.tertiary)
                    .settingsLandingAnchor("workflows.addHosted")
                }
                ForEach(workspaces.workspaces) { workspace in
                    section(workspace).id(workspace.id)
                }
            }
            .settingsLandingAnchor("workflows.workspaces")
            .task { await catalog.refreshAll() }
            .onAppear { scroll(proxy) }
            .onChange(of: windowState.workflowsWorkspaceFocus) { _, _ in scroll(proxy) }
        }
        .sheet(item: $runningLink) { link in
            HostedWorkflowRunSheet(link: link) { runningLink = nil }
                .environment(\.theme, theme)
        }
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        guard let id = windowState.workflowsWorkspaceFocus else { return }
        windowState.workflowsWorkspaceFocus = nil
        withAnimation(theme.motion.quick) { proxy.scrollTo(id, anchor: .top) }
    }

    // MARK: Section

    private func section(_ workspace: OsaurusRouterWorkspaceSummary) -> some View {
        let entry = catalog.entry(workspace.id)
        let hostedByTemplate = Dictionary(
            entry.hosted.map { ($0.templateID, $0) }, uniquingKeysWith: { first, _ in first })
        let listedTemplates = Set(entry.workflows.map(\.templateID))
        let hostedOnly = entry.hosted.filter { !listedTemplates.contains($0.templateID) }
        return VStack(alignment: .leading, spacing: theme.space.s12) {
            WorkflowSectionHeader(title: workspace.name, count: entry.workflows.count + hostedOnly.count) {
                Spacer(minLength: theme.space.s8)
                WorkflowTextLink(title: L("Workspace settings"), icon: "gearshape") {
                    WorkspacesService.shared.openInSettings(workspaceId: workspace.id, tab: .workflows)
                }
                SettingsIconButton(
                    "arrow.clockwise", isLoading: entry.state == .loading, help: "Refresh", size: .extraSmall
                ) {
                    Task { await catalog.refresh(workspace.id, force: true) }
                }
            }
            stateBanner(entry.state, workspaceID: workspace.id)
            if entry.workflows.isEmpty, hostedOnly.isEmpty, entry.fetchedAt != nil || entry.state == .loaded {
                Text(verbatim: L("Nothing shared in \(workspace.name) yet."))
                    .textStyle(.caption)
                    .foregroundStyle(theme.text.tertiary)
            } else if entry.workflows.isEmpty, hostedOnly.isEmpty, entry.state == .loading {
                SettingsEmptyState(loading: "Loading workflows…")
            }
            VStack(alignment: .leading, spacing: theme.space.s8) {
                ForEach(entry.workflows) { item in
                    listingRow(item, hosted: hostedByTemplate[item.templateID], workspace: workspace)
                }
                ForEach(hostedOnly) { offer in
                    hostedRow(offer)
                }
            }
        }
    }

    @ViewBuilder
    private func stateBanner(_ state: WorkspaceWorkflowCatalog.State, workspaceID: String) -> some View {
        switch state {
        case .failed(let message):
            InlineBanner(kind: .error, title: message)
        case .suspended:
            InlineBanner(
                kind: .warning,
                title: L("This workspace is suspended. Its shared workflows come back when its plan is active again."))
        case .routerOff:
            InlineBanner(
                kind: .info, title: L("Turn on Osaurus Router in Settings to see what this workspace shares."))
        case .idle, .loading, .loaded:
            EmptyView()
        }
    }

    // MARK: Rows

    private func listingRow(
        _ item: WorkflowsRegistryWorkspaceItem, hosted: HostedWorkflowOffer?, workspace: OsaurusRouterWorkspaceSummary
    ) -> some View {
        let state = catalog.installState(for: item)
        let local = installed.workflow(templateID: item.templateID)
        let link = hosted.flatMap { links.link(for: $0) }
        return WorkflowHomepageRow(
            title: item.name, summary: item.summary,
            onOpen: { if let local { windowState.pushWorkflowsPage(.workflow(local.id)) } },
            leading: { EmptyView() },
            meta: {
                HStack(spacing: theme.space.s6) {
                    if let hosted { StatusChip(L("Runs on \(hosted.hostLabel)"), tone: .info) }
                    Text(verbatim: [item.author.handle, L("Version \(item.latestVersion)")].joined(separator: " · "))
                        .textStyle(.caption)
                        .foregroundStyle(theme.text.tertiary)
                        .lineLimit(1)
                }
                .fixedSize()
            },
            accessory: {
                HStack(spacing: theme.space.s6) {
                    if let hosted, link == nil, local == nil {
                        SettingsButton(.tertiary, "Add to My Workflows", size: .extraSmall) {
                            _ = links.add(hosted)
                        }
                        .help(L("Run it on \(hosted.hostLabel) without installing a copy. Its owner approves each run."))
                    }
                    installAction(item, state: state, local: local, workspaceID: workspace.id, workspaceActive: !workspace.isSuspended)
                }
            },
            actions: {
                if let link {
                    Button(role: .destructive) { links.remove(id: link.id) } label: {
                        Label(L("Remove from My Workflows"), systemImage: "minus.circle")
                    }
                }
            },
            expanded: { EmptyView() })
    }

    @ViewBuilder
    private func installAction(
        _ item: WorkflowsRegistryWorkspaceItem, state: WorkspaceWorkflowCatalog.InstallState, local: InstalledWorkflow?,
        workspaceID: String, workspaceActive: Bool
    ) -> some View {
        switch state {
        case .notInstalled, .update:
            SettingsButton(
                .secondary, state == .notInstalled ? "Install" : "Update", icon: "square.and.arrow.down",
                size: .extraSmall
            ) {
                TemplateImportRouter.importRegistryFile(item.rawURL, workspaceID: workspaceID)
            }
            .disabled(!workspaceActive)
        case .setUp:
            SettingsButton(.secondary, "Set Up", icon: "checklist", size: .extraSmall) {
                if let local { onSetUp(local) }
            }
        case .installed:
            SettingsButton(.tertiary, "Open", size: .extraSmall) {
                if let local { windowState.pushWorkflowsPage(.workflow(local.id)) }
            }
        }
    }

    private func hostedRow(_ offer: HostedWorkflowOffer) -> some View {
        let link = links.link(for: offer)
        return WorkflowHomepageRow(
            title: offer.name, summary: offer.summary ?? "",
            onOpen: { if let link { runningLink = link } },
            leading: { EmptyView() },
            meta: {
                HStack(spacing: theme.space.s6) {
                    StatusChip(L("Runs on \(offer.hostLabel)"), tone: .info)
                    if let link { HostedWorkflowRunStatus(link: link) }
                }
                .fixedSize()
            },
            accessory: {
                if let link {
                    SettingsIconButton("play.fill", help: "Run", size: .extraSmall, role: .primary) {
                        runningLink = link
                    }
                    .accessibilityLabel(Text("Run \(link.name)", bundle: .module))
                } else {
                    SettingsButton(.secondary, "Add to My Workflows", icon: "plus", size: .extraSmall) {
                        _ = links.add(offer)
                    }
                    .help(L("Its owner approves each run, and it runs with their keys and folders."))
                }
            },
            actions: {
                if let link {
                    Button(role: .destructive) { links.remove(id: link.id) } label: {
                        Label(L("Remove from My Workflows"), systemImage: "minus.circle")
                    }
                }
            },
            expanded: { EmptyView() })
    }
}

/// A hosted workflow under All: it runs on the owner's Mac. Who can start
/// it is the same as for an install.
struct HostedWorkflowLinkRow: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var links = HostedWorkflowLinkStore.shared
    let link: HostedWorkflowLink
    let onRun: () -> Void

    var body: some View {
        WorkflowHomepageRow(
            title: link.name, summary: link.summary ?? "",
            onOpen: onRun,
            leading: { EmptyView() },
            meta: {
                HStack(spacing: theme.space.s6) {
                    StatusChip(L("Runs on \(link.hostLabel)"), tone: .info)
                        .fixedSize()
                    HostedWorkflowRunStatus(link: link)
                        .frame(maxWidth: theme.space.s48 * 5, alignment: .leading)
                }
            },
            accessory: {
                SettingsIconButton("play.fill", help: "Run", size: .extraSmall, role: .primary, action: onRun)
                    .accessibilityLabel(Text("Run \(link.name)", bundle: .module))
            },
            actions: {
                Toggle(
                    L("Osaurus can run this for you"),
                    isOn: Binding(
                        get: { link.orchestratorVisible },
                        set: { links.setOrchestratorVisible($0, id: link.id) })
                )
                .settingsCheckbox()
                Divider()
                Button(role: .destructive) { links.remove(id: link.id) } label: {
                    Label(L("Remove from My Workflows"), systemImage: "minus.circle")
                }
            },
            expanded: { EmptyView() })
    }
}

/// What a hosted workflow's latest run from this Mac is doing, or how it
/// ended.
struct HostedWorkflowRunStatus: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var center = HostedWorkflowRunCenter.shared
    let link: HostedWorkflowLink

    var body: some View {
        if let run = center.runs(for: link.id).last {
            HStack(spacing: theme.space.s4) {
                SettingsSpinner(size: .mini)
                Text(verbatim: HostedWorkflowRunCenter.phaseLabel(run.phase, hostLabel: link.hostLabel))
                    .textStyle(.caption)
                    .foregroundStyle(theme.text.secondary)
                    .lineLimit(1)
                if center.canCancel(run.id) {
                    Button { center.cancel(run.id) } label: { Text("Cancel", bundle: .module) }
                        .assignedSettingsButtonStyle(.tertiary, size: .extraSmall)
                }
            }
        } else if let outcome = center.lastOutcome[link.id] {
            Text(verbatim: outcome.message)
                .textStyle(.caption)
                .foregroundStyle(outcome.succeeded ? theme.text.tertiary : theme.statusInk(.error))
                .lineLimit(1)
                .help(outcome.message)
        }
    }
}

/// The input form for a hosted workflow; Run sends it to the owner's Mac.
struct HostedWorkflowRunSheet: View {
    let link: HostedWorkflowLink
    let onClose: () -> Void

    @State private var values: [String: JSONValue]
    @State private var issues: [String: String] = [:]
    private let fields: [DialogField]

    init(link: HostedWorkflowLink, onClose: @escaping () -> Void) {
        self.link = link
        self.onClose = onClose
        let fields = WorkflowFormFields.fields(fromInputSchema: link.inputs)
        self.fields = fields
        _values = State(initialValue: WorkflowFormFields.initialValues(fields, prefill: [:]))
    }

    var body: some View {
        SettingsSheet(
            icon: "play.fill",
            title: "Run \(link.name)",
            width: SettingsSheetWidth.regular,
            maxBodyHeight: 520,
            primary: .init(label: "Run", handler: run),
            secondary: .init(label: "Cancel", handler: onClose),
            onClose: onClose
        ) {
            if !fields.isEmpty {
                WorkflowFormView(fields: fields, values: $values, issues: issues, onSubmit: run)
            }
            Text(
                verbatim: L(
                    "Runs on \(link.hostLabel) with their keys and folders. They approve the run first; the result comes back here."
                )
            )
            .textStyle(.caption)
        }
        .subtitle(verbatim: link.summary.flatMap { $0.isEmpty ? nil : $0 }, lineLimit: 2)
    }

    private func run() {
        let input = WorkflowFormFields.inputValue(values, fields: fields, schema: link.inputs)
        let problems = JSONSchemaValidator.validate(input, against: link.inputs)
        guard problems.isEmpty else {
            var byField: [String: String] = [:]
            for problem in problems {
                if let field = fields.first(where: { problem.path.hasPrefix("$.\($0.key)") }) {
                    byField[field.key] = problem.message
                }
            }
            issues = byField
            return
        }
        HostedWorkflowRunCenter.shared.start(link, input: input)
        onClose()
    }
}
