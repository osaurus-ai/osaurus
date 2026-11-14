//
//  HostedWorkflowTests.swift
//  OsaurusCoreTests
//
//  Workflows a workspace shares: the catalog's states and what it says is
//  available, install provenance, the Workflows window's workspace
//  destinations, the owner's hosted-run endpoints (what's offered, who may
//  read a ticket, approval and refusal), and the consumer's links and
//  remote runs.
//

import Foundation
import NIOHTTP1
import Testing

@testable import OsaurusCore

private let guest = Participant(kind: .invitePeer, handle: "guest")

private func item(
    _ name: String, templateID: UUID = UUID(), version: Int = 1, kind: TemplateKind = .workflow
) -> WorkflowsRegistryWorkspaceItem {
    WorkflowsRegistryWorkspaceItem(
        id: "reg-\(name)", kind: kind, slug: name.lowercased(), name: name, summary: "\(name) summary",
        templateID: templateID, author: WorkflowsRegistryAuthor(address: "0xauthor", osaurusID: nil, displayName: "Ana"),
        latestVersion: version, sharedAt: nil, rawURL: URL(string: "https://store.example/\(name).json")!, deepLink: nil)
}

private func offer(
    _ name: String, templateID: UUID = UUID(), id: UUID = UUID(), agent: String = "0xAGENT", owner: String? = "Alice"
) -> HostedWorkflowOffer {
    HostedWorkflowOffer(
        wire: HostedWorkflowWire(
            id: id, templateID: templateID, name: name, summary: "\(name) hosted",
            inputs: WorkflowTool.parameters(for: WF.intake().inputSchema)),
        workspaceID: "ws-1", agentAddress: agent, agentName: "Helper", ownerName: owner)
}

// MARK: - Catalog

@MainActor
struct WorkspaceWorkflowCatalogTests {
    private static let workspace = OsaurusRouterWorkspaceSummary(id: "ws-1", name: "Team", role: "member", active: true)

    private func catalog(
        listings: @escaping @MainActor (String) async throws -> [WorkflowsRegistryWorkspaceItem] = { _ in [] },
        hosted: @escaping @MainActor (String) async -> [HostedWorkflowOffer] = { _ in [] },
        workspaces: [OsaurusRouterWorkspaceSummary] = [Self.workspace],
        routerOn: Bool = true, now: @escaping () -> Date = Date.init
    ) -> WorkspaceWorkflowCatalog {
        WorkspaceWorkflowCatalog(
            fetchListings: listings, fetchHosted: hosted, workspaces: { workspaces }, routerEnabled: { routerOn },
            now: now)
    }

    @Test
    func aFetchFillsListingsAndHostedWorkflows_andStaysFreshForAWhile() async {
        var fetches = 0
        var clock = Date(timeIntervalSince1970: 1000)
        let catalog = catalog(
            listings: { _ in
                fetches += 1
                return [item("Intake")]
            }, hosted: { _ in [offer("Triage")] }, now: { clock })
        await catalog.refresh("ws-1")
        #expect(catalog.entry("ws-1").state == .loaded)
        #expect(catalog.entry("ws-1").workflows.map(\.name) == ["Intake"])
        #expect(catalog.entry("ws-1").hosted.map(\.name) == ["Triage"])

        await catalog.refresh("ws-1")
        #expect(fetches == 1, "fresh: no second fetch")
        clock = clock.addingTimeInterval(WorkspaceWorkflowCatalog.freshness + 1)
        await catalog.refresh("ws-1")
        #expect(fetches == 2)
        await catalog.refresh("ws-1", force: true)
        #expect(fetches == 3)
    }

    @Test
    func aFailedFetch_aSuspendedWorkspace_andRouterOffAreStatesNotEmptyLists() async {
        struct Boom: Error {}
        let failing = catalog(listings: { _ in throw Boom() }, hosted: { _ in [offer("Triage")] })
        await failing.refresh("ws-1")
        guard case .failed = failing.entry("ws-1").state else {
            Issue.record("expected failed, got \(failing.entry("ws-1").state)")
            return
        }
        #expect(failing.entry("ws-1").hosted.count == 1, "hosted workflows still show when the registry fails")

        let suspended = catalog(
            workspaces: [OsaurusRouterWorkspaceSummary(id: "ws-1", name: "Team", role: "member", source: "suspended")])
        await suspended.refresh("ws-1")
        #expect(suspended.entry("ws-1").state == .suspended)

        let off = catalog(routerOn: false)
        await off.refresh("ws-1")
        #expect(off.entry("ws-1").state == .routerOff)
    }

    @Test
    func aRemovedListingLeavesAtOnce() async {
        let catalog = catalog(listings: { _ in [item("Intake"), item("Report")] })
        await catalog.refresh("ws-1")
        catalog.removeListing("reg-Intake", from: "ws-1")
        #expect(catalog.entry("ws-1").listings.map(\.name) == ["Report"])
    }

    @Test
    func availableListsWhatIsNeitherInstalledNorAdded_mergingAListingItsAuthorHosts() {
        let shared = UUID()
        let installedID = UUID()
        let hostedOnly = offer("Triage")
        let added = offer("Added")
        var entry = WorkspaceWorkflowCatalog.Entry()
        entry.listings = [item("Intake", templateID: shared), item("Mine", templateID: installedID), item("Agent", kind: .agent)]
        entry.hosted = [offer("Intake hosted", templateID: shared), hostedOnly, added]
        let available = WorkspaceWorkflowCatalog.available(
            entry, workspaceID: "ws-1", workspaceName: "Team", installedTemplateIDs: [installedID],
            addedHostedIDs: [added.remoteKey])
        #expect(available.map(\.name) == ["Intake", "Triage"])
        #expect(available.map(\.kind) == [.both, .runOnTheirMac])
        #expect(available.allSatisfy { $0.workspaceName == "Team" })
        #expect(available.last?.author == "Alice")
    }

    @Test
    func installStateCountsUnfinishedSetupAndUpdates() {
        #expect(WorkspaceWorkflowCatalog.installState(localVersion: nil, sharedVersion: 2) == .notInstalled)
        #expect(WorkspaceWorkflowCatalog.installState(localVersion: 1, sharedVersion: 2) == .update(from: 1))
        #expect(WorkspaceWorkflowCatalog.installState(localVersion: 2, sharedVersion: 2, needsSetup: true) == .setUp)
        #expect(WorkspaceWorkflowCatalog.installState(localVersion: 2, sharedVersion: 2) == .installed)
    }

    @Test
    func offeredNamesFindAWorkflowByNameOrToolName() async {
        let catalog = catalog(listings: { _ in [item("Weekly Report")] })
        await catalog.refresh("ws-1")
        let byName = catalog.offeredNames(matching: "weekly report")
        #expect(byName == ["Weekly Report (Team)"])
        #expect(catalog.offeredNames(matching: InstalledWorkflow.toolName(for: "Weekly Report")) == byName)
        #expect(catalog.offeredNames(matching: "Other").isEmpty)
    }
}

// MARK: - Provenance and destinations

@MainActor
struct WorkspaceWorkflowProvenanceTests {
    @Test
    func anInstallRemembersTheWorkspaceItCameFrom_andOlderFilesHaveNone() throws {
        var workflow = InstalledWorkflow(template: WF.template(WF.intake()), bindings: InstallBindings())
        workflow.source = .init(registryID: "reg-1", workspaceID: "ws-1")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try encoder.encode(workflow)
        #expect(String(decoding: data, as: UTF8.self).contains(#""workspace_id":"ws-1""#))
        let decoded = try decoder.decode(InstalledWorkflow.self, from: data)
        #expect(decoded.source == .init(registryID: "reg-1", workspaceID: "ws-1"))

        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["source"] = nil
        let legacy = try decoder.decode(InstalledWorkflow.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(legacy.source == nil)
    }

    @Test
    func workspaceDestinationsParseFromSearchAndDeepLinks() {
        typealias Destination = ChatWindowState.WorkflowsDestination
        #expect(Destination(subTab: "workflows.workspaces") == .home(.workspaces))
        #expect(Destination(subTab: "workflows.workspaces.ws-1") == .workspace("ws-1"))
        #expect(Destination(subTab: "workflows.all.ws-1") == nil, "only Workspaces takes an id")
        #expect(Destination(url: URL(string: "osaurus://workflows/workspaces")!) == .home(.workspaces))
        #expect(Destination(url: URL(string: "osaurus://workflows/workspaces/ws-1")!) == .workspace("ws-1"))
        #expect(Destination(url: URL(string: "osaurus://workflows")!) == .home(nil))
        #expect(Destination(url: URL(string: "osaurus://templates-import?url=x")!) == nil)
    }

    @Test
    func theWorkspacesTabShowsOnlyWhileThisMacIsInAWorkspace() {
        let chosen = ChatWindowState.workflowsTab(
            chosen: .workspaces, hasInstalled: true, hasDrafts: false, hasPublished: false, hasWorkspaces: true)
        #expect(chosen == .workspaces)
        let gone = ChatWindowState.workflowsTab(
            chosen: .workspaces, hasInstalled: true, hasDrafts: false, hasPublished: false, hasWorkspaces: false)
        #expect(gone == .all)
    }
}

// MARK: - Owner side

@MainActor
struct HostedWorkflowHostTests {
    private func installed(open: Bool) -> InstalledWorkflow {
        var workflow = InstalledWorkflow(template: WF.template(WF.intake(), name: "Intake"), bindings: InstallBindings())
        workflow.teammatesCanRun = open
        return workflow
    }

    private func agent(enabled: [UUID], asks: Bool = true, builtIn: Bool = false) -> Agent {
        var agent = Agent(name: "Helper", isBuiltIn: builtIn)
        agent.settings.enabledWorkflowIDs = enabled
        agent.sharedToolApproval = asks ? SharedToolApprovalPolicy(mode: .askOwner) : .deny
        return agent
    }

    private let caller = HostedWorkflowHost.Caller(participant: guest, workspaceId: nil, key: "key-a")

    @Test
    func anAgentOffersOnlyWorkflowsOnForItAndOpenToTeammates() {
        let open = installed(open: true)
        let closed = installed(open: false)
        let other = installed(open: true)
        let helper = agent(enabled: [open.id, closed.id])
        let offers = HostedWorkflowHost.offers(for: helper, workflows: [open, closed, other])
        #expect(offers.map(\.id) == [open.id])
        #expect(offers.first?.inputs.objectValue?["type"] == .string("object"))
        #expect(HostedWorkflowHost.offers(for: agent(enabled: [open.id], builtIn: true), workflows: [open]).isEmpty)
    }

    private func runtime(
        agent: Agent?, workflow: InstalledWorkflow?, decision: OwnerApprovalDecision = .approved,
        started: @escaping @Sendable (WorkflowCaller, Participant?) -> Void = { _, _ in }
    ) -> HostedWorkflowHost.Runtime {
        let runID = UUID()
        var runtime = HostedWorkflowHost.Runtime(
            askOwner: { _, _, _ in decision },
            start: { _, _, workflowCaller, _ in
                started(workflowCaller, ChatExecutionContext.currentParticipant)
                return .success(runID)
            })
        runtime.agent = { _ in agent }
        runtime.workflow = { _ in workflow }
        runtime.finished = { _ in nil }
        return runtime
    }

    @Test
    func theChecksThatAnswerAtOnce() {
        let open = installed(open: true)
        let closed = installed(open: false)
        let runs = HostedWorkflowRuns(runStatus: { _ in (nil, false) }, cancelRun: { _ in })
        func refusal(_ runtime: HostedWorkflowHost.Runtime, _ id: UUID) -> HostedWorkflowHost.Refusal? {
            if case .failure(let refusal) = HostedWorkflowHost.begin(
                agentId: UUID(), workflowID: id, input: .object([:]), caller: caller, runs: runs, runtime: runtime)
            {
                return refusal
            }
            return nil
        }
        #expect(refusal(runtime(agent: agent(enabled: []), workflow: open), open.id)?.code == "workflow_not_found")
        #expect(refusal(runtime(agent: nil, workflow: open), open.id)?.status == 404)
        #expect(refusal(runtime(agent: agent(enabled: [closed.id]), workflow: closed), closed.id)?.code == "not_open_to_teammates")
        #expect(refusal(runtime(agent: agent(enabled: [open.id], asks: false), workflow: open), open.id)?.code == "owner_approval_off")
        #expect(
            refusal(runtime(agent: agent(enabled: [open.id], builtIn: true), workflow: open), open.id)?.status == 404)
        let badInput = HostedWorkflowHost.begin(
            agentId: UUID(), workflowID: open.id, input: .string("x"), caller: caller, runs: runs,
            runtime: runtime(agent: agent(enabled: [open.id]), workflow: open))
        if case .failure(let refusal) = badInput { #expect(refusal.code == "invalid_input") } else {
            Issue.record("expected invalid_input")
        }
    }

    @Test
    func anApprovedRunStartsAsTheCaller_andItsTicketIsTheirsAlone() async throws {
        let open = installed(open: true)
        let helper = agent(enabled: [open.id])
        let runs = HostedWorkflowRuns(runStatus: { _ in (nil, true) }, cancelRun: { _ in })
        let seen = Locked<(WorkflowCaller, Participant?)?>(nil)
        let runtime = runtime(agent: helper, workflow: open) { workflowCaller, participant in
            seen.value = (workflowCaller, participant)
        }
        let ticket = try HostedWorkflowHost.begin(
            agentId: helper.id, workflowID: open.id, input: .object(["client": .string("Acme")]), caller: caller,
            runs: runs, runtime: runtime
        ).get()
        #expect(runs.status(ticket, agentId: helper.id, callerKey: "key-a")?.phase == .awaitingOwner)
        try await waitUntil { seen.value != nil }
        #expect(seen.value?.0.onBehalfOf == guest)
        #expect(seen.value?.0.agentID == helper.id)
        #expect(seen.value?.1 == guest, "the run starts inside the caller's task-locals")
        try await waitUntil { runs.status(ticket, agentId: helper.id, callerKey: "key-a")?.phase == .running }

        #expect(runs.status(ticket, agentId: helper.id, callerKey: "key-b") == nil, "another caller's ticket")
        #expect(runs.status(ticket, agentId: UUID(), callerKey: "key-a") == nil, "through another agent")
        #expect(!runs.cancel(ticket, agentId: helper.id, callerKey: "key-b"))
    }

    @Test
    func aDeclinedRunReadsAsRefusedWithTheReason() async throws {
        let open = installed(open: true)
        let helper = agent(enabled: [open.id])
        let runs = HostedWorkflowRuns(runStatus: { _ in (nil, false) }, cancelRun: { _ in })
        let started = Locked(false)
        let ticket = try HostedWorkflowHost.begin(
            agentId: helper.id, workflowID: open.id, input: .object([:]), caller: caller, runs: runs,
            runtime: runtime(agent: helper, workflow: open, decision: .denied) { _, _ in started.value = true }
        ).get()
        try await waitUntil { runs.status(ticket, agentId: helper.id, callerKey: "key-a")?.phase == .refused }
        let status = try #require(runs.status(ticket, agentId: helper.id, callerKey: "key-a"))
        #expect(status.isFinal)
        #expect(status.message?.isEmpty == false)
        #expect(!started.value)
    }

    @Test
    func aTicketFollowsItsRun() {
        let runID = UUID()
        var run = WorkflowRun(
            id: runID, workflowID: UUID(), workflowName: "Intake", templateID: UUID(), templateVersion: 1,
            caller: WorkflowCaller(kind: .agent), input: .object([:]), nodeIDs: [])
        var active = true
        let runs = HostedWorkflowRuns(runStatus: { _ in (run, active) }, cancelRun: { _ in })
        let ticket = runs.open(agentId: UUID(), workflowID: UUID(), callerKey: "k")
        let agentId = UUID()
        #expect(runs.status(ticket, agentId: agentId, callerKey: "k") == nil, "opened for another agent")

        let own = runs.open(agentId: agentId, workflowID: UUID(), callerKey: "k")
        runs.started(own, runID: runID)
        run.status = .running
        #expect(runs.status(own, agentId: agentId, callerKey: "k")?.phase == .running)
        run.status = .awaitingUser
        #expect(runs.status(own, agentId: agentId, callerKey: "k")?.phase == .awaitingUser)
        run.status = .completed
        active = false
        let done = runs.status(own, agentId: agentId, callerKey: "k")
        #expect(done?.phase == .completed)
        #expect(done?.result?.status == .completed)
        _ = ticket
    }

    @Test
    func theWireFormatAndRoutes() throws {
        let status = HostedWorkflowStatus(ticket: UUID(), phase: .awaitingOwner)
        let json = String(decoding: try JSONEncoder().encode(status), as: UTF8.self)
        #expect(json.contains(#""status":"awaiting_owner""#))
        #expect(json.contains(#""run_id""#))

        let body = #"{"hosted_workflows":[{"id":"\#(UUID().uuidString)","template_id":"\#(UUID().uuidString)","name":"A","inputs":{}},{"bad":1}]}"#
        #expect(RemoteProviderService.parseHostedWorkflows(from: Data(body.utf8)).map(\.name) == ["A"])
        #expect(RemoteProviderService.parseAgentMetadata(from: Data(body.utf8))?.hostedWorkflows.count == 1)
        #expect(RemoteProviderService.parseAgentMetadata(from: Data(#"{"name":"x"}"#.utf8))?.hostedWorkflows == [])

        let id = UUID().uuidString
        typealias Route = HTTPHandler.HostedWorkflowRoute
        #expect(Route(["agents", "a", "workflows", id, "run"])?.action == .run(workflowID: UUID(uuidString: id)!))
        #expect(Route(["agents", "a", "workflows", "runs", id])?.method == .GET)
        #expect(Route(["agents", "a", "workflows", "runs", id, "cancel"])?.action == .cancel(ticket: UUID(uuidString: id)!))
        #expect(Route(["agents", "a", "workflows", "nope", "run"]) == nil)
        #expect(Route(["agents", "a", "run"]) == nil)
    }
}

// MARK: - Consumer side

@MainActor
struct HostedWorkflowLinkTests {
    private func store() -> (HostedWorkflowLinkStore, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hosted-links-\(UUID().uuidString).json")
        return (HostedWorkflowLinkStore(fileURL: url), url)
    }

    @Test
    func addingKeepsOneLinkPerOffer_andNeverReusesAnInstallsName() {
        let (links, url) = store()
        defer { try? FileManager.default.removeItem(at: url) }
        let triage = offer("Triage")
        let first = links.add(triage, installedNames: [])
        #expect(links.add(triage, installedNames: []).id == first.id)
        #expect(links.remoteKeys == [triage.remoteKey])

        let clash = links.add(offer("Intake"), installedNames: ["Intake"])
        #expect(clash.name == "Intake (Alice)")
        #expect(clash.toolName != InstalledWorkflow.toolName(for: "Intake"))

        let reloaded = HostedWorkflowLinkStore(fileURL: url)
        #expect(reloaded.links.map(\.name) == ["Triage", "Intake (Alice)"])
        #expect(reloaded.link(named: "triage")?.id == first.id)
        #expect(reloaded.link(named: first.toolName)?.id == first.id)
    }

    @Test
    func freshOffersUpdateALinksInput_andRemovingForgetsIt() {
        let (links, url) = store()
        defer { try? FileManager.default.removeItem(at: url) }
        var triage = offer("Triage")
        let link = links.add(triage, installedNames: [])
        triage.wire.inputs = .object(["type": .string("object"), "properties": .object(["x": WF.string])])
        triage.wire.summary = "New"
        links.refresh(from: [triage])
        #expect(links.link(id: link.id)?.summary == "New")
        #expect(links.link(id: link.id)?.inputs == triage.wire.inputs)
        links.setOrchestratorVisible(false, id: link.id)
        #expect(links.orchestratorVisible.isEmpty)
        links.remove(id: link.id)
        #expect(links.links.isEmpty)
    }

    private func target() -> HostedWorkflowClient.Target {
        HostedWorkflowClient.Target(
            ref: WorkspaceAgentRef(workspaceId: "ws-1", agentAddress: "0xAGENT"), remoteWorkflowID: UUID(),
            name: "Triage", agentName: "Helper", hostLabel: "Alice's Mac")
    }

    private func runtime(
        supported: Bool = true, prepare: @escaping @Sendable () throws -> UUID = { UUID() },
        responses: @escaping @Sendable (String, String) -> (Data, Int)?
    ) -> HostedWorkflowClient.Runtime {
        HostedWorkflowClient.Runtime(
            prepare: { _ in try prepare() }, supportsHostedWorkflows: { _ in supported },
            send: { _, method, path, _ in responses(method, path).map { (data: $0.0, statusCode: $0.1) } },
            pollInterval: .milliseconds(5))
    }


    @Test
    func aRunWaitsForTheOwnerThenReturnsTheResult() async throws {
        let ticket = UUID()
        let polls = Locked(0)
        let phases = Locked<[HostedWorkflowStatus.Phase]>([])
        let outcome = await HostedWorkflowClient.run(
            target(), input: .object([:]),
            runtime: runtime { method, path in
                if method == "POST", path.hasSuffix("/run") { return (statusBody(ticket, .awaitingOwner), 202) }
                polls.value += 1
                return polls.value < 3
                    ? (statusBody(ticket, .running), 200)
                    : (statusBody(ticket, .completed, result: WorkflowCallResult(status: .completed)), 200)
            }, onPhase: { phases.value.append($0.phase) })
        let status = try outcome.get()
        #expect(status.phase == .completed)
        #expect(phases.value == [.awaitingOwner, .running, .completed])
    }

    @Test
    func refusalsComeBackInTheirOwnWords() async {
        let unreachable = await HostedWorkflowClient.run(
            target(), input: .object([:]),
            runtime: runtime(prepare: { throw WorkspaceAgentRunError.offline(lastSeen: nil) }) { _, _ in nil })
        guard case .failure(.unreachable) = unreachable else {
            Issue.record("expected unreachable, got \(unreachable)")
            return
        }

        let old = await HostedWorkflowClient.run(
            target(), input: .object([:]), runtime: runtime(supported: false) { _, _ in nil })
        #expect(old == .failure(.tooOld(String(format: L("%@ needs a newer Osaurus to run workflows for you."), "Alice's Mac"))))

        let closed = await HostedWorkflowClient.run(
            target(), input: .object([:]),
            runtime: runtime { _, _ in (Data(#"{"error":"not_open_to_teammates","message":"Not open."}"#.utf8), 403) })
        #expect(closed == .failure(.refused("Not open.")))

        let ticket = UUID()
        let declined = await HostedWorkflowClient.run(
            target(), input: .object([:]),
            runtime: runtime { method, _ in
                method == "POST"
                    ? (statusBody(ticket, .awaitingOwner), 202)
                    : (try! JSONEncoder().encode(HostedWorkflowStatus(ticket: ticket, phase: .refused, message: "No.")), 200)
            })
        #expect(declined == .failure(.refused("No.")))
    }

    @Test
    func cancellingTheCallCancelsTheRunOnTheOwnersMac() async throws {
        let ticket = UUID()
        let cancelled = Locked(false)
        let rt = runtime { method, path in
            if path.hasSuffix("/cancel") {
                cancelled.value = true
                return (Data("{}".utf8), 200)
            }
            if method == "POST" { return (statusBody(ticket, .running), 202) }
            return (statusBody(ticket, .running), 200)
        }
        let task = Task { await HostedWorkflowClient.run(self.target(), input: .object([:]), runtime: rt) }
        try await Task.sleep(for: .milliseconds(30))
        task.cancel()
        let outcome = await task.value
        #expect(outcome == .failure(.cancelled))
        #expect(cancelled.value)
    }

    @Test
    func aTeammateDrivingThisMacsAgentCantPassARunOn() async {
        let (links, url) = store()
        defer { try? FileManager.default.removeItem(at: url) }
        let link = links.add(offer("Triage"), installedNames: [])
        let result = await ChatExecutionContext.$isExternalSurface.withValue(true) {
            await ChatExecutionContext.$currentParticipant.withValue(guest) {
                await WorkflowToolCall.runHosted(link: link, input: .object(["client": .string("x")]), tool: link.toolName)
            }
        }
        #expect(!ToolEnvelope.isSuccess(result))
        #expect(ToolEnvelope.failureMessage(result).contains("owner only"))
    }
}

// MARK: - Helpers

private func statusBody(_ ticket: UUID, _ phase: HostedWorkflowStatus.Phase, result: WorkflowCallResult? = nil) -> Data {
    try! JSONEncoder().encode(HostedWorkflowStatus(ticket: ticket, phase: phase, result: result))
}

private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

@MainActor
private func waitUntil(timeout: Duration = .seconds(2), _ condition: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("timed out")
            return
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}

struct HostedWorkflowKeyScopeTests {
    @Test
    func aWorkspaceKeyReachesTheHostedRoutesWithTheirMethodsOnly() {
        let id = UUID().uuidString
        func reach(_ method: HTTPMethod, _ path: String) -> Bool {
            HTTPHandler.workspaceKeyMayReach(method: method, path: path, peerInferenceEnabled: false)
        }
        #expect(reach(.POST, "/agents/a/workflows/\(id)/run"))
        #expect(reach(.GET, "/agents/a/workflows/runs/\(id)"))
        #expect(reach(.POST, "/agents/a/workflows/runs/\(id)/cancel"))
        #expect(!reach(.GET, "/agents/a/workflows/\(id)/run"))
        #expect(!reach(.POST, "/agents/a/workflows/runs/\(id)"))
        #expect(!reach(.POST, "/workflows/\(id)/run"), "the owner's local workflow API stays closed")
    }
}

@MainActor
struct WorkspaceWorkflowDiscoveryTests {
    @Test
    func theConfiguratorIsToldWhereWorkspaceWorkflowsLive() {
        for compact in [true, false] {
            let prompt = ConfiguratorSystemPromptBuilder._renderForTests(domains: [], compact: compact)
            #expect(prompt.contains("available_in_workspaces"))
            #expect(prompt.contains("Workflows → Workspaces"))
        }
    }
}
