//
//  WorkflowsView.swift
//  osaurus
//
//  Main window → Workflows. The sidebar lists every workflow, draft and
//  workspace; picking one replaces the page beside it. Home says what is
//  running now. A run's page pushes over a workflow's page; the title
//  bar's back button pops it. With no workflows and no drafts, the New
//  Workflow page is the whole screen and there is no sidebar.
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
    @State var runningLink: HostedWorkflowLink?
    /// Where the sidebar sits; nil draws none.
    let sidebar: WorkflowsSidebarColumn?
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
    @State var deletingDraft: WorkflowDraft?

    init(windowState: ChatWindowState, sidebar: WorkflowsSidebarColumn? = nil) {
        self.windowState = windowState
        self.sidebar = sidebar
        _route = StateObject(wrappedValue: WorkflowsRouteObserver(windowState))
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

    /// The sidebar on screen: none on the first-run page.
    private var shownSidebar: WorkflowsSidebarColumn? {
        guard let sidebar, sidebar.mode != .hidden,
            !Self.isFirstRun(installed: installed, drafts: drafts, hostedLinks: hostedLinks, workspaces: workspaces)
        else { return nil }
        return sidebar
    }

    var body: some View {
        let shown = shownSidebar
        HStack(spacing: theme.space.s0) {
            if let shown, shown.mode == .docked {
                sidebarView(width: shown.width)
                    .overlay(alignment: .trailing) { shown.resizeHandle }
                    .transition(.move(edge: .leading).combined(with: .opacity))
                    .zIndex(1)
            }
            ZStack {
                page
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
        .overlay { compactDrawer(shown) }
        .animation(theme.motion.quick, value: shown?.mode)
        .animation(reduceMotion ? theme.motion.quick : theme.motion.standard, value: windowState.workflowsPath)
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
                onDone: { windowState.popWorkflowsPage() },
                onSeeAllRuns: { windowState.showWorkflowsActivity(.init(workflowID: $0.id)) },
                takeIntent: { windowState.takeWorkflowsAutomationIntent() },
                actionMenu: { detailMenu($0) }
            )
            .id("workflow-\(id)")
            .transition(pushTransition)
        case .run(let workflowID, let runID, let agentId)?:
            WorkflowRunPage(
                windowState: windowState, workflowID: workflowID, runID: runID, agentId: agentId,
                onBack: { windowState.popWorkflowsPage() },
                onShowRun: { windowState.showWorkflowRun(workflowID: workflowID, runID: $0, agentId: agentId) },
                onSetUp: { setupSubject = .setup($0) })
            .id("run-\(workflowID)")
            .transition(pushTransition)
        case .create?:
            newWorkflowPage(onBack: { windowState.popWorkflowsPage() })
                .id("create")
                .transition(pushTransition)
        case .workspace(let id)?:
            workspacePage(id)
                .id("workspace-\(id)")
                .transition(.opacity)
        case .activity?:
            WorkflowsActivityPage(
                windowState: windowState, overview: windowState.workflowsOverview,
                onRun: { workflow in
                    if workflow.needsSetup { setupSubject = .setup(workflow) } else { play(workflow) }
                },
                onSetUp: { setupSubject = .setup($0) })
            .id("activity")
            .transition(.opacity)
        case nil:
            home
                .transition(.opacity)
        }
    }

    /// The title-bar back button's label for returning to `page`; nil is
    /// the home.
    @MainActor
    static func backTitle(to page: ChatWindowState.WorkflowsPage?, installed: InstalledWorkflowStore = .shared) -> String {
        switch page {
        case .workflow(let id)?: return installed.workflow(id: id)?.name ?? L("Workflow")
        case .run?: return L("Run")
        case .create?: return L("New Workflow")
        case .workspace(let id)?: return WorkspacesService.shared.workspaces.first { $0.id == id }?.name ?? L("Workspace")
        case .activity?: return L("Activity")
        case nil: return L("Workflows")
        }
    }

    // MARK: - Sidebar

    private func sidebarView(width: CGFloat) -> some View {
        WorkflowsSidebar(
            windowState: windowState,
            overview: windowState.workflowsOverview,
            width: width,
            selection: windowState.workflowsSidebarSelection,
            workflowMenu: { workflow, label in AnyView(sidebarMenu(workflow, label: label)) },
            onRun: runFromSidebar,
            onDeleteDraft: { deletingDraft = $0 })
    }

    /// A compact window's sidebar: a drawer over the page above a scrim
    /// that closes it. Esc closes it too.
    @ViewBuilder
    private func compactDrawer(_ shown: WorkflowsSidebarColumn?) -> some View {
        ZStack(alignment: .leading) {
            if let shown, shown.mode == .overlay {
                theme.scrimSubtle
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(theme.motion.quick) { windowState.isWorkflowsDrawerPresented = false }
                    }
                    .transition(.opacity)
                sidebarView(width: shown.width)
                    .themeElevation(theme.elevation.overlay)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    /// The workflow page's ⋯: the card's menu with Pin and Share first.
    private func detailMenu(_ workflow: InstalledWorkflow) -> InstalledWorkflowCard {
        var card = installedCard(workflow, detailActionMenu: true)
        let published = registryRecords.record(for: workflow.templateID)
        card.leadingMenuItems = AnyView(
            Group {
                pinButton(workflow)
                Button { share(workflow.template, entry: shareEntry(for: workflow.templateID)) } label: {
                    Label(published == nil ? L("Share…") : L("Manage Published…"), systemImage: "square.and.arrow.up")
                }
            })
        return card
    }

    private func pinButton(_ workflow: InstalledWorkflow) -> some View {
        Button {
            try? installed.setPinned(!workflow.isPinned, id: workflow.id)
        } label: {
            Label(
                workflow.isPinned ? L("Unpin") : L("Pin"),
                systemImage: workflow.isPinned ? "pin.slash" : "pin")
        }
    }

    /// The card's menu on a sidebar row, with Pin, Automate and Share first.
    private func sidebarMenu(_ workflow: InstalledWorkflow, label: AnyView) -> InstalledWorkflowCard {
        var card = installedCard(workflow)
        card.contextMenuLabel = label
        card.leadingMenuItems = AnyView(
            Group {
                pinButton(workflow)
                Button { windowState.selectWorkflowsPage(.workflow(workflow.id)) } label: {
                    Label(L("Automate…"), systemImage: "bolt")
                }
                Button { share(workflow.template, entry: shareEntry(for: workflow.templateID)) } label: {
                    Label(L("Share…"), systemImage: "square.and.arrow.up")
                }
            })
        return card
    }

    /// Run from a sidebar row: Set Up first when the workflow can't run
    /// yet; a teammate's workflow asks its owner.
    private func runFromSidebar(_ row: WorkflowsSidebarModel.Row) {
        switch row.kind {
        case .installed(let id):
            guard let workflow = installed.workflow(id: id) else { return }
            if workflow.needsSetup { setupSubject = .setup(workflow) } else { play(workflow) }
        case .hosted(let id):
            runningLink = hostedLinks.link(id: id)
        }
    }

    private func workspacePage(_ id: String) -> some View {
        ScrollView {
            WorkflowsWorkspacesTab(windowState: windowState, workspaceID: id, onSetUp: { setupSubject = .setup($0) })
                .frame(maxWidth: WorkflowLibraryLayout.columnWidth, alignment: .leading)
                .padding(.horizontal, theme.space.s24)
                .padding(.top, WorkflowLibraryLayout.pageTopInset(theme))
                .padding(.bottom, theme.space.s64)
                .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    @ViewBuilder
    private var home: some View {
        if Self.isFirstRun(installed: installed, drafts: drafts, hostedLinks: hostedLinks, workspaces: workspaces) {
            newWorkflowPage(onBack: nil)
                .transition(.opacity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    workflowsHome
                        .frame(maxWidth: WorkflowLibraryLayout.columnWidth, alignment: .leading)
                        .padding(.horizontal, theme.space.s24)
                        .padding(.top, WorkflowLibraryLayout.pageTopInset(theme))
                        .padding(.bottom, theme.space.s64)
                        .frame(maxWidth: .infinity, alignment: .top)
                }
                .onAppear { scrollHome(proxy, to: windowState.takeWorkflowsHomeScrollTarget()) }
                .onReceive(NotificationCenter.default.publisher(for: .workflowsHomeScroll)) { _ in
                    scrollHome(proxy, to: windowState.takeWorkflowsHomeScrollTarget())
                }
            }
            .transition(.opacity)
            .settingsLandingAnchor("workflows.overview")
        }
    }

    private func scrollHome(_ proxy: ScrollViewProxy, to section: String?) {
        guard let section else { return }
        DispatchQueue.main.async {
            withAnimation(theme.motion.standard) { proxy.scrollTo(section, anchor: .top) }
        }
    }

    /// New Workflow: pushed over the home, or the whole screen (`onBack`
    /// nil) while there are no workflows and no drafts.
    private func newWorkflowPage(onBack: (() -> Void)?) -> some View {
        WorkflowCreationLanding(
            windowState: windowState, draft: windowState.workflowCreationSession,
            title: L("What would you like to automate?"),
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

    /// A run just started from here: Home lists it under Running now; a
    /// workflow's page shows it at the top of its runs.
    func reveal(_ runID: UUID, of workflowID: UUID) {
        windowState.workflowsSpotlightRunID = runID
    }

    func openRun(_ run: WorkflowLiveRuns.Summary) {
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
        windowState.selectWorkflowsPage(.workflow(id))
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
