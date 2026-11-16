//
//  WorkflowsView.swift
//  osaurus
//
//  Main window → Workflows. One home: what is running now, then the
//  workflows in tabs (All, Drafts to continue, and what this Mac has
//  published), each row opening to its recent runs. New Workflow, a
//  workflow's page, and a run's page push over it; the title bar's back
//  button pops them. With no workflows and no drafts, the New Workflow
//  page is the whole screen.
//
//  Workflow files arrive through Import, a drop anywhere on the screen, or
//  a store.osaurus.ai install link, and leave through Share (as a file, or
//  published to the store registry).
//

import Combine
import SwiftUI

/// Republishes only `ChatWindowState.workflowsRouteWillChange`.
@MainActor
final class WorkflowsRouteObserver: ObservableObject {
    private var subscription: AnyCancellable?

    init(_ windowState: ChatWindowState) {
        subscription = windowState.workflowsRouteWillChange.sink { [weak self] in self?.objectWillChange.send() }
    }
}

struct WorkflowsView: View {
    @Environment(\.workflowSharedGrid) var sharedGrid
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    let windowState: ChatWindowState
    @StateObject private var route: WorkflowsRouteObserver
    @ObservedObject var themeManager = ThemeManager.shared
    @ObservedObject var managementState = ManagementStateManager.shared
    @ObservedObject var installed = InstalledWorkflowStore.shared
    @ObservedObject var templates = TemplateStore.shared
    @ObservedObject var agents = AgentManager.shared
    @ObservedObject var registryRecords = WorkflowRegistryRecordStore.shared
    @ObservedObject var drafts = WorkflowDraftStore.shared
    @ObservedObject var runGlances = WorkflowRunGlances.shared
    @ObservedObject var workspaces = WorkspacesService.shared
    @ObservedObject var hostedLinks = HostedWorkflowLinkStore.shared
    @ObservedObject var workspaceCatalog = WorkspaceWorkflowCatalog.shared
    @State var runningLink: HostedWorkflowLink?
    /// Read, not observed: it publishes on every step of every run. What
    /// the home shows of runs comes through `runGlances` and views that
    /// observe the store themselves.
    var runs: WorkflowRunStore { WorkflowRunStore.shared }

    var theme: ThemeProtocol { themeManager.currentTheme }

    @State var setupSubject: WorkflowSetupSubject?
    @State var importText: String?
    /// Set with `importText` when the file came from a deep link.
    @State var importSourceHost: String?
    /// The registry workflow the text in the import sheet came from; nil
    /// for files.
    @State var importRegistry: RegistryImportSource?
    @State var renaming: Template?
    @State var renamingInstalled: InstalledWorkflow?
    @State var history: Template?
    @State var preview: Template?
    @State var isDropTargeted = false
    @State var sharing: ShareRequest?
    @State var runSheet: RunSheetRequest?
    @State var showingConnections = false
    @State var query = ""
    @State var selectedTag: String?
    @State var deletingDraft: WorkflowDraft?
    /// Workflow rows open to show their recent runs.
    @State var expandedWorkflows: Set<UUID> = []
    /// The row ↑/↓ asked to focus next.
    @State var rowFocus: WorkflowRowFocusRequest?

    /// Past this many installed workflows the list offers a search field
    /// even when none is tagged.
    static let searchThreshold = 8

    init(windowState: ChatWindowState, expandedWorkflows: Set<UUID> = []) {
        self.windowState = windowState
        _route = StateObject(wrappedValue: WorkflowsRouteObserver(windowState))
        _expandedWorkflows = State(initialValue: expandedWorkflows)
    }

    struct ShareRequest: Identifiable {
        let id = UUID()
        let template: Template
        let bindings: InstallBindings?
        let entry: ShareWorkflowSheet.Entry
    }

    struct RunSheetRequest: Identifiable {
        let id = UUID()
        let workflow: InstalledWorkflow
        var prefill: [String: JSONValue]? = nil
    }

    /// Nothing installed, nothing in progress, no teammate's workflow added
    /// and no workspace to browse: the New Workflow page stands in for the
    /// home.
    @MainActor
    static func isFirstRun(
        installed: InstalledWorkflowStore, drafts: WorkflowDraftStore,
        hostedLinks: HostedWorkflowLinkStore = .shared, workspaces: WorkspacesService = .shared
    ) -> Bool {
        installed.workflows.isEmpty && drafts.libraryDrafts.isEmpty && hostedLinks.links.isEmpty
            && workspaces.workspaces.isEmpty
    }

    /// Templates with no workflow installed from them.
    var notSetUp: [Template] {
        templates.allTemplates(kind: .workflow).filter { installed.workflow(templateID: $0.id) == nil }
    }

    var body: some View {
        ZStack {
            page
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .animation(reduceMotion ? theme.motion.quick : theme.motion.standard, value: windowState.workflowsPath)
        .animation(theme.motion.quick, value: windowState.workflowsTab)
        .background { if !sharedGrid { theme.surface.canvas } }
        .environment(\.theme, theme)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            TemplateFileExport.loadDroppedFile(
                providers, onText: { openImport($0, registry: nil) },
                onError: { _ = ToastManager.shared.error(L("Import"), message: $0) })
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: theme.radius.large)
                    .strokeBorder(theme.border.focus, style: StrokeStyle(lineWidth: theme.stroke.focus, dash: [8, 6]))
                    .padding(theme.space.s12)
                    .allowsHitTesting(false)
            }
        }
        .onAppear {
            installed.reload()
            templates.reload()
            resumeParkedSetupIfNeeded()
            consumePendingImport()
            consumePendingShare()
            consumePendingDetail()
            // The numbers the rows show: the public read, never signed, so
            // opening Workflows never asks to authenticate.
            Task { await WorkflowShareService.shared.refreshAllStats() }
        }
        .task { await runs.loadRecentRunsIfNeeded() }
        .onReceive(managementState.$pendingSetupSubject) { _ in resumeParkedSetupIfNeeded() }
        .onReceive(managementState.$pendingTemplateImport) { _ in consumePendingImport() }
        .onReceive(managementState.$pendingWorkflowShare) { _ in consumePendingShare() }
        .onReceive(managementState.$pendingWorkflowDetailId) { _ in consumePendingDetail() }
        .sheet(item: $setupSubject) { subject in
            WorkflowSetupWizardView(subject: subject, onClose: { setupSubject = nil }) { _ in }
                .environment(\.theme, theme)
        }
        .sheet(isPresented: $showingConnections) {
            WorkflowConnectionsSheet(
                onSetUp: { workflow in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { setupSubject = .setup(workflow) }
                },
                onClose: { showingConnections = false })
            .environment(\.theme, theme)
        }
        .sheet(item: $runningLink) { link in
            HostedWorkflowRunSheet(link: link) { runningLink = nil }
                .environment(\.theme, theme)
        }
        .sheet(item: $runSheet) { request in
            WorkflowRunInputSheet(
                workflow: request.workflow, windowAgent: windowState.agentId, prefill: request.prefill,
                onStarted: { runID in
                    runSheet = nil
                    reveal(runID, of: request.workflow.id)
                },
                onSetUp: { workflow in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { setupSubject = .setup(workflow) }
                },
                onClose: { runSheet = nil })
            .environment(\.theme, theme)
        }
        .sheet(
            isPresented: Binding(get: { importText != nil }, set: { if !$0 { importText = nil } })
        ) {
            TemplateImportSheet(
                initialText: importText ?? "",
                sourceHost: importSourceHost,
                expectedKind: .workflow,
                importLabel: importSourceHost == nil ? "Import and Add" : "Import and Set Up",
                onImported: { template, _ in
                    let remote = importSourceHost != nil
                    let registry = importRegistry
                    importText = nil
                    importSourceHost = nil
                    importRegistry = nil
                    DispatchQueue.main.async { afterImport(template, isRemote: remote, registry: registry) }
                },
                onCancel: {
                    importText = nil
                    importSourceHost = nil
                    importRegistry = nil
                }
            )
            .environment(\.theme, theme)
        }
        .sheet(item: $preview) { template in
            WorkflowStarterPreviewSheet(
                template: template, onClose: { preview = nil },
                onAdded: { workflow in
                    preview = nil
                    if let example = template.workflow?.examples.first?.input.objectValue {
                        WorkflowRunLauncher.stagePrefill(example, for: workflow.id)
                    }
                    if windowState.workflowsPath.last == .create { windowState.popWorkflowsPage() }
                    windowState.showWorkflowRun(workflowID: workflow.id, runID: nil, agentId: windowState.agentId)
                })
            .environment(\.theme, theme)
        }
        .sheet(item: $sharing) { request in
            ShareWorkflowSheet(
                template: request.template, bindings: request.bindings, entry: request.entry,
                onDone: { sharing = nil }
            )
            .environment(\.theme, theme)
        }
        .sheet(item: $renaming) { template in
            RenameAgentTemplateSheet(template: template, onDone: { renaming = nil })
                .environment(\.theme, theme)
        }
        .sheet(item: $renamingInstalled) { workflow in
            RenameInstalledWorkflowSheet(workflowID: workflow.id, onDone: { renamingInstalled = nil })
                .environment(\.theme, theme)
        }
        .sheet(item: $history) { template in
            TemplateVersionHistorySheet(templateID: template.id, onDone: { history = nil })
                .environment(\.theme, theme)
        }
        .themedAlert(
            L("Delete Draft"),
            isPresented: Binding(get: { deletingDraft != nil }, set: { if !$0 { deletingDraft = nil } }),
            message: L("Delete this unfinished workflow and its test history?"),
            primaryButton: .destructive(L("Delete"), action: {
                if let draft = deletingDraft { drafts.delete(draft.id) }
                deletingDraft = nil
            }),
            secondaryButton: .cancel(L("Cancel")))
    }

    // MARK: - Pages

    private var pushTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .asymmetric(
                insertion: .opacity.combined(with: .offset(x: theme.space.s24)),
                removal: .opacity.combined(with: .offset(x: theme.space.s24)))
    }

    @ViewBuilder
    private var page: some View {
        switch windowState.workflowsPath.last {
        case .workflow(let id)?:
            WorkflowDetailPage(
                workflowID: id,
                onSetUp: { setupSubject = .setup($0) },
                onRun: { play($0) },
                onOpenRun: { runID in
                    windowState.showWorkflowRun(workflowID: id, runID: runID, agentId: windowState.agentId)
                },
                onShare: { share($0.template, entry: shareEntry(for: $0.templateID)) },
                onRename: { renamingInstalled = $0 },
                onEdit: { ArchitectLauncher.edit($0, in: windowState) },
                onDone: { windowState.popWorkflowsPage() },
                actionMenu: { workflow in installedCard(workflow, detailActionMenu: true) }
            )
            .id("workflow-\(id)")
            .transition(pushTransition)
        case .run(let workflowID, let runID, let agentId)?:
            WorkflowRunPage(
                windowState: windowState, workflowID: workflowID, runID: runID, agentId: agentId,
                onBack: { windowState.popWorkflowsPage() },
                onShowRun: { windowState.showWorkflowRun(workflowID: workflowID, runID: $0, agentId: agentId) },
                onShowWorkflow: previousPage == .workflow(workflowID)
                    ? nil : { windowState.pushWorkflowsPage(.workflow($0)) },
                onSetUp: { setupSubject = .setup($0) })
            .id("run-\(workflowID)")
            .transition(pushTransition)
        case .create?:
            newWorkflowPage(onBack: { windowState.popWorkflowsPage() })
                .id("create")
                .transition(pushTransition)
        case nil:
            home
                .transition(.opacity)
        }
    }

    private var previousPage: ChatWindowState.WorkflowsPage? {
        let path = windowState.workflowsPath
        return path.count >= 2 ? path[path.count - 2] : nil
    }

    /// The title-bar back button's label for returning to `page`; nil is
    /// the home.
    @MainActor
    static func backTitle(to page: ChatWindowState.WorkflowsPage?, installed: InstalledWorkflowStore = .shared) -> String {
        switch page {
        case .workflow(let id)?: return installed.workflow(id: id)?.name ?? L("Workflow")
        case .run?: return L("Run")
        case .create?: return L("New Workflow")
        case nil: return L("Workflows")
        }
    }

    @ViewBuilder
    private var home: some View {
        if Self.isFirstRun(installed: installed, drafts: drafts, hostedLinks: hostedLinks, workspaces: workspaces) {
            newWorkflowPage(onBack: nil)
                .transition(.opacity)
        } else {
            ScrollView {
                workflowsHome
                    .frame(maxWidth: WorkflowLibraryLayout.columnWidth, alignment: .leading)
                    .padding(.horizontal, theme.space.s24)
                    .padding(.top, WorkflowLibraryLayout.pageTopInset(theme))
                    .padding(.bottom, theme.space.s64)
                    .frame(maxWidth: .infinity, alignment: .top)
            }
            .transition(.opacity)
            .settingsLandingAnchor("workflows.overview")
        }
    }

    /// New Workflow: pushed over the home, or the whole screen (`onBack`
    /// nil) while there are no workflows and no drafts.
    private func newWorkflowPage(onBack: (() -> Void)?) -> some View {
        WorkflowCreationLanding(
            windowState: windowState, draft: windowState.workflowCreationSession,
            title: onBack == nil ? L("Create your first workflow") : L("New Workflow"),
            starters: notSetUp, starterCard: { templateCard($0) },
            onBack: onBack, onImport: chooseFile)
            .settingsLandingAnchor("workflows.new")
    }

    /// The large title of a home half, its one primary action, and what
    /// sits beside it.
    func homeTitle<Actions: View>(_ title: String, @ViewBuilder actions: () -> Actions) -> some View {
        HStack(alignment: .center, spacing: theme.space.s12) {
            Text(verbatim: title)
                .textStyle(.title)
                .foregroundStyle(theme.text.primary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: theme.space.s12)
            actions()
        }
    }

    // MARK: - Running

    /// Play: runs at once when nothing has to be filled in, else asks.
    func play(_ workflow: InstalledWorkflow) {
        switch WorkflowRunStarter.play(workflow, windowAgent: windowState.agentId) {
        case .started(let runID): reveal(runID, of: workflow.id)
        case .needsInput, .blocked: runSheet = RunSheetRequest(workflow: workflow)
        }
    }

    /// A run just started from here: on the home its row opens to show it;
    /// on a workflow's page the page shows it at the top of its runs.
    func reveal(_ runID: UUID, of workflowID: UUID) {
        windowState.workflowsSpotlightRunID = runID
        if windowState.workflowsPath.isEmpty {
            if workflowsTab == .drafts { windowState.workflowsTab = .all }
            withAnimation(expandAnimation) { _ = expandedWorkflows.insert(workflowID) }
        }
    }

    var expandAnimation: Animation {
        reduceMotion ? theme.motion.quick : theme.motion.springAnimation(responseMultiplier: 1)
    }

    func openRun(_ run: WorkflowRun) {
        windowState.showWorkflowRun(
            workflowID: run.workflowID, runID: run.id, agentId: run.caller.agentID ?? windowState.agentId)
    }

    // MARK: - Cards

    func installedCard(
        _ workflow: InstalledWorkflow, row: WorkflowRowParts? = nil, detailActionMenu: Bool = false,
        onOpen: (() -> Void)? = nil
    ) -> InstalledWorkflowCard {
        let update = installed.availableUpdate(for: workflow)
        return InstalledWorkflowCard(
            workflow: workflow,
            update: update,
            published: registryRecords.record(for: workflow.templateID),
            agentCount: agentCount(workflow.id),
            hasHistory: templates.latest(id: workflow.templateID) != nil,
            animationDelay: 0,
            hasAppeared: true,
            openHelp: "Open workflow",
            row: row,
            isDetailActionMenu: detailActionMenu,
            menuButtonSize: .standard,
            onDetails: detailActionMenu ? nil : { windowState.pushWorkflowsPage(.workflow(workflow.id)) },
            onOpen: onOpen ?? { windowState.pushWorkflowsPage(.workflow(workflow.id)) },
            onRun: { play(workflow) },
            onSaveAsFile: { share(workflow.template, entry: .file) },
            onShare: { share(workflow.template, entry: .choose) },
            onPublish: { share(workflow.template, entry: .publish) },
            onManage: { share(workflow.template, entry: .manage) },
            onTakeDown: { takeDown(templateID: workflow.templateID, name: workflow.name) },
            onSetUp: { setupSubject = .setup(workflow) },
            onUpdate: { if let update { setupSubject = .update(workflow, to: update) } },
            onEdit: { ArchitectLauncher.edit(workflow, in: windowState) },
            onVersionHistory: { history = templates.latest(id: workflow.templateID) },
            onToggleOrchestrator: {
                try? installed.setOrchestratorVisible(!workflow.orchestratorVisible, id: workflow.id)
            },
            onRename: { renamingInstalled = workflow },
            onUninstall: {
                if detailActionMenu { windowState.popWorkflowsPage() }
                uninstall(workflow)
            }
        )
    }

    /// What an installed workflow's row shows: the `WorkflowRowSnapshot`
    /// key for `installedCard` rows.
    struct InstalledRowKey: Equatable, Sendable {
        let workflow: InstalledWorkflow
        let updateVersion: Int?
        let published: WorkflowRegistryRecord?
        let agentCount: Int
        let hasHistory: Bool
        /// The row's pending keyboard focus request, and its list's order.
        let focus: Int
        let ids: [UUID]
        let theme: Int
        var isExpanded = false
        var spotlight: UUID?
        var automations = 0
        var runs = WorkflowRunGlances.Glance()
    }

    func installedRowKey(_ workflow: InstalledWorkflow, ids: [UUID]) -> InstalledRowKey {
        InstalledRowKey(
            workflow: workflow,
            updateVersion: installed.availableUpdate(for: workflow)?.version,
            published: registryRecords.record(for: workflow.templateID),
            agentCount: agentCount(workflow.id),
            hasHistory: templates.latest(id: workflow.templateID) != nil,
            focus: rowFocus?.id == workflow.id ? rowFocus?.serial ?? 0 : 0,
            ids: ids,
            theme: theme.renderFingerprint)
    }

    func templateCard(_ template: Template) -> WorkflowTemplateCard {
        WorkflowTemplateCard(
            template: template,
            isBuiltIn: templates.isBuiltIn(template),
            published: registryRecords.record(for: template.id),
            animationDelay: 0,
            hasAppeared: true,
            onOpen: { preview = template },
            onAdd: { preview = template },
            onEdit: { ArchitectLauncher.open(template: template) },
            onSaveAsFile: { share(template, entry: .file) },
            onShare: { share(template, entry: .choose) },
            onPublish: { share(template, entry: .publish) },
            onManage: { share(template, entry: .manage) },
            onTakeDown: { takeDown(templateID: template.id, name: template.name) },
            onVersionHistory: { history = template },
            onRename: { renaming = template },
            onDelete: { delete(template) },
            isHomepageCard: true,
            homepageIcon: starterIcon(template),
            isSelected: preview?.id == template.id
        )
    }

    private func starterIcon(_ template: Template) -> String {
        switch template.id.uuidString.lowercased() {
        case "0f5c1a4e-6b7d-4c1a-9a01-000000000103": return "envelope"
        case "0f5c1a4e-6b7d-4c1a-9a01-000000000102": return "list.bullet"
        case "0f5c1a4e-6b7d-4c1a-9a01-000000000101": return "at"
        default: return "flowchart"
        }
    }

    // MARK: - Filtering

    /// What this Mac has published.
    var publishedWorkflows: [InstalledWorkflow] {
        installed.workflows.filter { registryRecords.record(for: $0.templateID) != nil }
    }

    /// The workflows a tab lists before search and tag narrow it.
    func tabWorkflows(_ tab: ChatWindowState.WorkflowsTab) -> [InstalledWorkflow] {
        tab == .published ? publishedWorkflows : installed.workflows
    }

    func shownInstalled(_ tab: ChatWindowState.WorkflowsTab) -> [InstalledWorkflow] {
        InstalledWorkflow.filter(tabWorkflows(tab), query: query, tag: selectedTag)
    }

    var showsSearch: Bool {
        !installed.allTags.isEmpty || installed.workflows.count > Self.searchThreshold || !query.isEmpty
    }

    /// Search by name or tag; it sits in the tab row.
    var searchField: some View {
        SearchField(text: $query, placeholder: "Search by name or tag…", width: 240)
            .settingsLandingAnchor("workflows.tagFilter")
    }

    /// All and one chip per tag in use within `tab`; a chip narrows the
    /// list to workflows carrying that tag.
    @ViewBuilder
    func filterChips(_ tab: ChatWindowState.WorkflowsTab) -> some View {
        let base = tabWorkflows(tab)
        let tags = Self.tagCounts(base)
        if !tags.isEmpty {
            FilterChipScroller {
                tagChip(nil, label: L("All"), count: base.count)
                ForEach(tags, id: \.tag) { entry in
                    tagChip(entry.tag, label: entry.tag, count: entry.count)
                }
            }
        }
    }

    static func tagCounts(_ workflows: [InstalledWorkflow]) -> [(tag: String, count: Int)] {
        var counts: [String: Int] = [:]
        for w in workflows { for t in w.tags { counts[t, default: 0] += 1 } }
        return counts.keys.sorted().map { ($0, counts[$0] ?? 0) }
    }

    private func tagChip(_ tag: String?, label: String, count: Int) -> some View {
        FilterChip(
            label, icon: nil, count: count, isSelected: selectedTag == tag,
            help: tag == nil ? L("Every workflow in this tab") : L("Only workflows tagged “\(label)”")
        ) {
            selectedTag = tag
        }
    }

    var noMatches: some View {
        SettingsEmptyState(
            inline: "line.3.horizontal.decrease.circle", title: "No workflow matches.",
            hint: "Try another name or tag.",
            action: .init(title: L("Clear Filters"), icon: "xmark.circle") {
                query = ""
                selectedTag = nil
            })
    }

    // MARK: - Actions

    func uninstall(_ workflow: InstalledWorkflow) {
        installed.delete(id: workflow.id)
        _ = ToastManager.shared.success(L("Uninstalled \"\(workflow.name)\""))
    }

    func agentCount(_ workflowID: UUID) -> Int {
        agents.agents.filter { $0.settings.enabledWorkflowIDs.contains(workflowID) }.count
    }

    func chooseFile() {
        TemplateFileExport.chooseFile(
            onText: { openImport($0, registry: nil) },
            onError: { _ = ToastManager.shared.error(L("Import"), message: $0) })
    }

    func openImport(_ text: String, sourceHost: String? = nil, registry: RegistryImportSource?) {
        importSourceHost = sourceHost
        importRegistry = registry
        importText = text
    }

    /// Where Share opens for a template: its dashboard when published,
    /// the chooser otherwise.
    func shareEntry(for templateID: UUID) -> ShareWorkflowSheet.Entry {
        registryRecords.record(for: templateID) != nil ? .manage : .choose
    }

    func share(_ template: Template, entry: ShareWorkflowSheet.Entry) {
        sharing = ShareRequest(
            template: template, bindings: installed.workflow(templateID: template.id)?.bindings, entry: entry)
    }

    func takeDown(templateID: UUID, name: String) {
        Task { @MainActor in
            do {
                try await WorkflowShareService.shared.unpublish(templateID: templateID)
                _ = ToastManager.shared.success(
                    L("Took down \"\(name)\""), message: L("Its page no longer works. Publish again to bring it back."))
            } catch {
                _ = ToastManager.shared.error(L("Take Down"), message: WorkflowErrorText.text(error))
            }
        }
    }

    /// Opens a workflow's page requested from Management search.
    private func consumePendingDetail() {
        guard let id = managementState.pendingWorkflowDetailId else { return }
        managementState.pendingWorkflowDetailId = nil
        guard installed.workflow(id: id) != nil else { return }
        windowState.workflowsPath = [.workflow(id)]
    }

    private var isSheetOpen: Bool {
        importText != nil || setupSubject != nil || preview != nil || renaming != nil || history != nil
            || sharing != nil || runSheet != nil || renamingInstalled != nil || showingConnections
    }

    private func closeSheets() {
        importText = nil
        importSourceHost = nil
        importRegistry = nil
        setupSubject = nil
        preview = nil
        renaming = nil
        renamingInstalled = nil
        history = nil
        sharing = nil
        runSheet = nil
        showingConnections = false
    }

    /// Opens Share for the workflow the Architect just saved, when the
    /// person chose Share on its Saved card.
    private func consumePendingShare() {
        guard let templateID = managementState.pendingWorkflowShare else { return }
        managementState.pendingWorkflowShare = nil
        let resubmits = managementState.pendingWorkflowShareResubmits
        managementState.pendingWorkflowShareResubmits = false
        guard let template = installed.workflow(templateID: templateID)?.template ?? templates.latest(id: templateID)
        else { return }
        let entry = resubmits ? .publish : shareEntry(for: templateID)
        guard isSheetOpen else {
            share(template, entry: entry)
            return
        }
        closeSheets()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { share(template, entry: entry) }
    }

    /// Sends the signed install receipt for a confirmed import from a
    /// registry link. Fire-and-forget: it never blocks or reports on the
    /// import.
    private static func countInstall(_ registry: RegistryImportSource?) {
        guard let registry else { return }
        Task { @MainActor in
            let counted = await WorkflowShareService.shared.recordInstall(registry)
            print("[WorkflowsRegistry] install receipt \(registry.workflowID.uuidString.lowercased()) v\(registry.version) counted=\(String(describing: counted))")
        }
    }

    /// An imported file is meant to be used, and the import sheet already
    /// showed what it does: a newer version of an installed workflow offers
    /// its update, a workflow this Mac can run as is is added, and anything
    /// else opens setup on what it still needs. A file that arrived through
    /// a link (`isRemote`) always goes through setup: one click on a web
    /// page must not end with a workflow installed and callable.
    private func afterImport(_ template: Template, isRemote: Bool = false, registry: RegistryImportSource? = nil) {
        if let existing = installed.workflow(templateID: template.id) {
            if template.version > existing.templateVersion {
                Self.countInstall(registry)
                var subject = WorkflowSetupSubject.update(existing, to: template)
                subject.source = registry?.installSource
                setupSubject = subject
            } else {
                _ = ToastManager.shared.success(L("\"\(template.name)\" is already on this Mac"))
            }
            return
        }
        Self.countInstall(registry)
        if !isRemote {
            do {
                if WorkflowStarterPreviewSheet.missingPreferredModels(template).isEmpty,
                    let added = try WorkflowStarterPreviewSheet.addDirectly(template)
                {
                    Self.toastAdded(added)
                    return
                }
            } catch {
                _ = ToastManager.shared.error(L("Import"), message: WorkflowErrorText.text(error))
                return
            }
        }
        var subject = WorkflowSetupSubject.install(template)
        subject.bindings = WorkflowStarterPreviewSheet.startingBindings(template)
        subject.source = registry?.installSource
        setupSubject = subject
    }

    /// "Added", with Run opening the workflow's run form in the Workflows
    /// window.
    static func toastAdded(_ workflow: InstalledWorkflow) {
        let actionId = "workflow.run.\(workflow.id.uuidString)"
        ToastManager.shared.registerActionHandler(for: actionId) { _ in
            WorkflowRunLauncher.openTab(workflowID: workflow.id)
        }
        ToastManager.shared.action(
            L("Added \"\(workflow.name)\""), message: L("It's ready to run."),
            action: .custom(id: actionId), buttonTitle: L("Run"))
    }

    private func consumePendingImport() {
        guard let pending = managementState.pendingTemplateImport, pending.kind == .workflow else { return }
        managementState.pendingTemplateImport = nil
        guard isSheetOpen else {
            openImport(pending.text, sourceHost: pending.sourceHost, registry: pending.registry)
            return
        }
        // One sheet at a time: close what is up, then open the import.
        closeSheets()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            openImport(pending.text, sourceHost: pending.sourceHost, registry: pending.registry)
        }
    }

    func delete(_ template: Template) {
        do {
            try templates.delete(id: template.id)
            _ = ToastManager.shared.success(L("Deleted \"\(template.name)\""))
        } catch {
            _ = ToastManager.shared.error(L("Template"), message: WorkflowErrorText.text(error))
        }
    }

    private func resumeParkedSetupIfNeeded() {
        guard case .workflow(let parked)? = managementState.pendingSetupSubject else { return }
        managementState.pendingSetupSubject = nil
        setupSubject = parked
    }
}
