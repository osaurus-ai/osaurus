import Combine
import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct WorkflowsWindowPresentationTests {
    private func run(
        _ status: WorkflowRunStatus, caller: WorkflowCaller = WorkflowCaller(kind: .user),
        startedAt: Date, finishedAt: Date? = nil
    ) -> WorkflowRun {
        var run = WorkflowRun(
            workflowID: UUID(), workflowName: "Inbox Sorter", templateID: UUID(), templateVersion: 1,
            caller: caller, input: .object([:]), nodeIDs: ["a", "b"])
        run.status = status
        run.startedAt = startedAt
        run.finishedAt = finishedAt
        return run
    }

    @Test
    func runningNow_putsWaitingFirst_thenRunning_thenJustEnded_andDropsTestsAndOldRuns() {
        let now = Date()
        let running = run(.running, startedAt: now.addingTimeInterval(-30))
        let newerRunning = run(.running, startedAt: now.addingTimeInterval(-5))
        let waiting = run(.awaitingUser, startedAt: now.addingTimeInterval(-60))
        let justDone = run(.completed, startedAt: now.addingTimeInterval(-20), finishedAt: now.addingTimeInterval(-2))
        let longDone = run(
            .completed, startedAt: now.addingTimeInterval(-120),
            finishedAt: now.addingTimeInterval(-(WorkflowRunPresentation.lingerInterval + 1)))
        let test = run(.running, caller: WorkflowCaller(kind: .test), startedAt: now)

        let shown = WorkflowRunPresentation.activity(
            [running, longDone, justDone, test, newerRunning, waiting], now: now)
        #expect(shown.map(\.id) == [waiting.id, newerRunning.id, running.id, justDone.id])
    }

    @Test
    func aRunAnAutomationStarted_namesTheAutomation() {
        let named = WorkflowCaller(kind: .event, eventID: UUID(), eventName: "Morning digest")
        #expect(WorkflowRunStyle.caller(named) == "Automation · Morning digest")
        #expect(WorkflowRunStyle.caller(WorkflowCaller(kind: .event)) == "An automation")
        #expect(WorkflowRunPresentation.startedByIcon(named) == "bolt.fill")
        #expect(WorkflowRunStyle.caller(WorkflowCaller(kind: .user)) == "You")
        #expect(WorkflowRunPresentation.startedByIcon(WorkflowCaller(kind: .user)) == nil)
    }

    @Test
    func runsGroupByWorkflow_newestFirst_withoutTests() {
        let now = Date()
        let workflowID = UUID()
        var older = run(.completed, startedAt: now.addingTimeInterval(-100), finishedAt: now.addingTimeInterval(-90))
        var newer = run(.failed, startedAt: now.addingTimeInterval(-10), finishedAt: now.addingTimeInterval(-5))
        var test = run(.completed, caller: WorkflowCaller(kind: .test), startedAt: now)
        older.workflowID = workflowID
        newer.workflowID = workflowID
        test.workflowID = workflowID

        let grouped = WorkflowRunPresentation.runsByWorkflow([older, test, newer])
        #expect(grouped[workflowID]?.map(\.id) == [newer.id, older.id])
    }

    @Test
    func makingAWorkflow_readsDesignTestSavePublish_inOrder() {
        #expect(WorkflowMakeStage.allCases.map(\.title) == ["Design", "Test", "Save", "Publish"])
        #expect(WorkflowMakeStage.design < .test && .save < .publish)
    }

    @Test
    func arrowKeys_moveToTheNeighbouringRow_andStopAtTheEnds() {
        let ids = [UUID(), UUID(), UUID()]
        #expect(WorkflowRowFocusRequest.neighbour(of: ids[0], in: ids, delta: 1) == ids[1])
        #expect(WorkflowRowFocusRequest.neighbour(of: ids[2], in: ids, delta: -1) == ids[1])
        #expect(WorkflowRowFocusRequest.neighbour(of: ids[0], in: ids, delta: -1) == nil)
        #expect(WorkflowRowFocusRequest.neighbour(of: ids[2], in: ids, delta: 1) == nil)
        #expect(WorkflowRowFocusRequest.neighbour(of: UUID(), in: ids, delta: 1) == nil)
    }

    @Test
    func statusInk_readsOnTheCanvas_inLightAndDark() {
        for theme in [CustomizableTheme.light(), CustomizableTheme.dark()] as [ThemeProtocol] {
            let canvas = WorkflowStatusInk.luminance(theme.surface.canvas)
            let ink = WorkflowStatusInk(theme)
            for (name, color) in [("success", ink.success), ("warning", ink.warning), ("error", ink.error), ("info", ink.info)] {
                let ratio = WorkflowStatusInk.contrast(WorkflowStatusInk.luminance(color), canvas)
                #expect(ratio >= 3, "\(name) ink is \(ratio):1 on the \(theme.isDark ? "dark" : "light") canvas")
            }
        }
    }

    @Test
    func aDraft_showsTheEmptyCanvasUntilItHasStepsOrFields() {
        #expect(ArchitectSidebarPanel.hasNothingDrafted(WorkflowDefinition()))
        var fields = WorkflowDefinition()
        fields.inputSchema = WF.object(["topic": WF.string])
        #expect(!ArchitectSidebarPanel.hasNothingDrafted(fields))
        #expect(!ArchitectSidebarPanel.hasNothingDrafted(WF.intake()))
    }

    @Test
    func installedWorkflows_listInFinderOrder() async throws {
        try await ChatHistoryTestStorage.run {
            let store = InstalledWorkflowStore.shared
            store.reload()
            defer { store.resetForTesting() }
            for name in ["Report 10", "report 2", "Report 1"] {
                _ = try store.install(WF.template(WF.intake(), name: name), bindings: InstallBindings())
            }
            #expect(store.workflows.map(\.name) == ["Report 1", "report 2", "Report 10"])
        }
    }

    @Test
    func aStepGoingBy_leavesTheListAlone_untilTheRunEnds() async throws {
        try await ChatHistoryTestStorage.run {
            let store = WorkflowRunStore.shared
            var live = run(.running, startedAt: Date())
            defer {
                store.deleteRuns(workflowID: live.workflowID)
                store.resetForTesting()
            }
            let glances = WorkflowRunGlances(store: store)
            store.record(live)
            #expect(glances.byWorkflow[live.workflowID]?.liveRunID == live.id)

            var changes = 0
            let watching = glances.objectWillChange.sink { changes += 1 }
            defer { watching.cancel() }
            for i in 1...3 {
                live.update("a") { $0.progress = WorkflowNodeProgress(fraction: Double(i) / 4, detail: "Item \(i)") }
                store.record(live)
            }
            #expect(changes == 0)

            live.status = .completed
            live.finishedAt = Date()
            store.record(live)
            #expect(changes > 0)
            #expect(glances.byWorkflow[live.workflowID]?.liveRunID == nil)
            #expect(glances.byWorkflow[live.workflowID]?.lastRun?.status == .completed)
        }
    }

    @Test
    func chatChanges_doNotReachTheWorkflowsWindow_butItsRouteDoes() async throws {
        try await ChatHistoryTestStorage.run {
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer {
                window.cleanup()
                UserDefaults.standard.removeObject(forKey: ChatWindowState.workflowsTabDefaultsKey)
            }
            let route = WorkflowsRouteObserver(window)
            var changes = 0
            let watching = route.objectWillChange.sink { changes += 1 }
            defer { watching.cancel() }

            window.findBarFocusRequestID += 1
            window.showSidebar.toggle()
            #expect(changes == 0)

            window.workflowsTab = window.workflowsTab == .drafts ? .all : .drafts
            window.workflowsTab = window.workflowsTab
            #expect(changes == 1)
            window.pushWorkflowsPage(.workflow(UUID()))
            #expect(changes == 2)
        }
    }

    @Test
    func theArchitect_opensOnWhicheverHalfHasSomethingToShow() {
        #expect(WorkflowCreationPane.opening(hasChat: false, hasSteps: true) == .workflow)
        #expect(WorkflowCreationPane.opening(hasChat: true, hasSteps: true) == .chat)
        #expect(WorkflowCreationPane.opening(hasChat: false, hasSteps: false) == .chat)
    }

    @Test
    func home_opensOnTheTabLastUsed_whileItHasAnything_elseAll() {
        typealias State = ChatWindowState
        #expect(State.workflowsTab(chosen: nil, hasInstalled: true, hasDrafts: true, hasPublished: true) == .all)
        #expect(State.workflowsTab(chosen: .drafts, hasInstalled: true, hasDrafts: true, hasPublished: false) == .drafts)
        #expect(State.workflowsTab(chosen: .drafts, hasInstalled: true, hasDrafts: false, hasPublished: false) == .all)
        #expect(State.workflowsTab(chosen: .published, hasInstalled: true, hasDrafts: false, hasPublished: true) == .published)
        #expect(State.workflowsTab(chosen: .published, hasInstalled: true, hasDrafts: true, hasPublished: false) == .all)
        #expect(State.workflowsTab(chosen: .all, hasInstalled: true, hasDrafts: true, hasPublished: true) == .all)
    }

    @Test
    func home_withDraftsButNothingInstalled_opensOnDrafts() {
        typealias State = ChatWindowState
        #expect(State.workflowsTab(chosen: nil, hasInstalled: false, hasDrafts: true, hasPublished: false) == .drafts)
        #expect(State.workflowsTab(chosen: .all, hasInstalled: false, hasDrafts: true, hasPublished: false) == .drafts)
        #expect(State.workflowsTab(chosen: .published, hasInstalled: false, hasDrafts: true, hasPublished: false) == .drafts)
    }

    @Test
    func newWorkflow_pushesItsPage_withTheComposerAskedForOnce() async throws {
        try await ChatHistoryTestStorage.run {
            let installed = InstalledWorkflowStore.shared
            installed.reload()
            _ = try installed.install(WF.template(WF.intake(), name: "Client Intake"), bindings: InstallBindings())
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer {
                window.cleanup()
                installed.resetForTesting()
                UserDefaults.standard.removeObject(forKey: ChatWindowState.workflowsTabDefaultsKey)
            }
            window.showWorkflowsHome(tab: .published)
            window.pushWorkflowsPage(.workflow(UUID()))

            window.showNewWorkflow()
            #expect(window.workflowsPath == [.create])
            #expect(window.workflowsTab == .published)
            #expect(window.consumeNewWorkflowComposerFocus())
            #expect(!window.consumeNewWorkflowComposerFocus())

            window.showNewWorkflow()
            #expect(window.workflowsPath == [.create])
            window.popWorkflowsPage()
            #expect(window.workflowsPath.isEmpty)
        }
    }

    @Test
    func goBack_stepsOutOneLevelAtATime_andStopsAtTheTop() async throws {
        try await ChatHistoryTestStorage.run {
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer {
                window.cleanup()
                UserDefaults.standard.removeObject(forKey: ChatWindowState.workflowsTabDefaultsKey)
            }
            #expect(!window.goBack())

            let workflowID = UUID()
            window.pushWorkflowsPage(.workflow(workflowID))
            window.showWorkflowRun(workflowID: workflowID, runID: nil)
            window.showWorkflowDetail()

            #expect(window.goBack())
            #expect(window.showsWorkflowLibrary)
            #expect(window.workflowsPath.count == 2)
            #expect(window.goBack())
            #expect(window.workflowsPath == [.workflow(workflowID)])
            #expect(window.goBack())
            #expect(window.workflowsPath.isEmpty)
            #expect(!window.goBack())
            #expect(window.mainSurface == .workflows)
        }
    }

    @Test
    func backTitle_namesThePageItReturnsTo() async throws {
        try await ChatHistoryTestStorage.run {
            let installed = InstalledWorkflowStore.shared
            installed.reload()
            defer { installed.resetForTesting() }
            let workflow = try installed.install(WF.template(WF.intake(), name: "Client Intake"), bindings: InstallBindings())

            #expect(WorkflowsView.backTitle(to: nil) == "Workflows")
            #expect(WorkflowsView.backTitle(to: .create) == "New Workflow")
            #expect(WorkflowsView.backTitle(to: .workflow(workflow.id)) == "Client Intake")
            #expect(WorkflowsView.backTitle(to: .workflow(UUID())) == "Workflow")
            #expect(WorkflowsView.backTitle(to: .run(workflowID: workflow.id, runID: nil, agentId: Agent.defaultId)) == "Run")
        }
    }

    @Test
    func startingADraft_fromNewWorkflow_backSkipsItsEmptiedPage() {
        let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
        defer { window.cleanup() }
        let workflowID = UUID()
        window.workflowsPath = [.workflow(workflowID), .create]

        window.leaveNewWorkflowPage()
        #expect(window.workflowsPath == [.workflow(workflowID)])
        window.leaveNewWorkflowPage()
        #expect(window.workflowsPath == [.workflow(workflowID)], "only New Workflow is dropped")
    }

    @Test
    func newWorkflow_withNoWorkflowsAndNoDrafts_isTheHome_soNothingIsPushed() async throws {
        try await ChatHistoryTestStorage.run {
            InstalledWorkflowStore.shared.reload()
            WorkflowDraftStore.shared.resetForTesting()
            #expect(WorkflowsView.isFirstRun(installed: .shared, drafts: .shared))
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer { window.cleanup() }
            window.pushWorkflowsPage(.workflow(UUID()))

            window.showNewWorkflow()
            #expect(window.workflowsPath.isEmpty)
            #expect(window.consumeNewWorkflowComposerFocus())
        }
    }

    @Test
    func aTeammatesAddedWorkflow_showsTheHome_notTheFirstRunPage() async throws {
        try await ChatHistoryTestStorage.run {
            InstalledWorkflowStore.shared.reload()
            WorkflowDraftStore.shared.resetForTesting()
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("hosted-links-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: url) }
            let links = HostedWorkflowLinkStore(fileURL: url)
            #expect(WorkflowsView.isFirstRun(installed: .shared, drafts: .shared, hostedLinks: links))

            let offer = HostedWorkflowOffer(
                wire: HostedWorkflowWire(id: UUID(), templateID: UUID(), name: "Digest", summary: nil, inputs: .object([:])),
                workspaceID: "ws-1", agentAddress: "0xagent", agentName: "Scout", ownerName: "Alice")
            let link = links.add(offer, installedNames: [])
            defer { links.remove(id: link.id) }
            #expect(!WorkflowsView.isFirstRun(installed: .shared, drafts: .shared, hostedLinks: links),
                "the All tab is the only place an added teammate's workflow shows")
        }
    }

    @Test
    func searchDestinations_nameATab_orNewWorkflow() {
        typealias Destination = ChatWindowState.WorkflowsDestination
        #expect(Destination(subTab: "workflows") == .home(nil))
        #expect(Destination(subTab: "workflows.all") == .home(.all))
        #expect(Destination(subTab: "workflows.drafts") == .home(.drafts))
        #expect(Destination(subTab: "workflows.published") == .home(.published))
        #expect(Destination(subTab: "new") == .newWorkflow)
        #expect(Destination(subTab: "studio") == nil)
        #expect(Destination(subTab: "studio.library") == nil)
        #expect(Destination(subTab: "workflows.nowhere") == nil)
        #expect(Destination(subTab: "settings") == nil)
    }
}
