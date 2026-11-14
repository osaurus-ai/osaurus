//
//  AgentWrapperCatalogTests.swift
//  OsaurusCoreTests
//
//  Agent wrappers: derived from the agents and the Orchestrator's pool on
//  every read, run through `run_workflow` as one agent step, and seen by
//  nothing that lists installed workflows.
//

import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import Testing

@testable import OsaurusCore

@Suite("Agent wrappers")
struct AgentWrapperCatalogTests {

    static func agent(_ name: String, id: UUID = UUID()) -> Agent {
        Agent(id: id, name: name, description: "\(name) does things.", systemPrompt: "")
    }

    static func config(pool: [UUID]) -> SubagentConfiguration {
        var config = SubagentConfiguration()
        config.spawnableAgentIDs = pool
        return config
    }

    // MARK: Code worker sandbox

    @Test @MainActor func theCodeWorkerHasAFixedSandboxPolicyWhereverTheSandboxRuns() throws {
        let policy = try #require(AgentManager.codeWorkerAutonomousExec(availability: .available))
        #expect(policy.enabled)
        #expect(!policy.pluginCreate)
        #expect(policy.sandboxNetworkEnabled)
        #expect(policy.sandboxAllowedDomains == nil)
        #expect(!policy.backgroundProcessEnabled)
        #expect(!policy.hostServicesEnabled)
        #expect(AgentManager.codeWorkerAutonomousExec(availability: .unavailable(reason: "no VM")) == nil)

        // An agent record claiming the worker's id can't loosen the policy.
        var claimed = Self.agent("Code", id: BuiltInWorker.code.agentId)
        claimed.autonomousExec = AutonomousExecConfig(enabled: true, pluginCreate: true, backgroundProcessEnabled: true)
        #expect(AgentManager.resolvedAutonomousExec(for: claimed, availability: .available) == policy)
    }

    @Test func theCodeWorkerRunsAsItsOwnSandboxMemberAndOtherWorkersHaveNone() async {
        await SandboxTestLock.runWithStoragePaths {
            let codeId = BuiltInWorker.code.agentId
            #expect(SandboxAgentProvisioner.linuxName(for: codeId.uuidString) == "worker-code")

            let previous = SandboxManager.State.shared.availability
            SandboxManager.State.shared.availability = .available
            defer { SandboxManager.State.shared.availability = previous }

            let expected = AgentManager.codeWorkerAutonomousExec(availability: .available)
            #expect(expected != nil)
            let bound = await ChatExecutionContext.$currentAgentId.withValue(codeId) {
                await SandboxToolRequestContext.resolve(fallbackAgentId: Agent.defaultId.uuidString)
            }
            let unbound = await SandboxToolRequestContext.resolve(fallbackAgentId: codeId.uuidString)
            for context in [bound, unbound] {
                #expect(context.agentName == "worker-code")
                #expect(context.home == OsaurusPaths.inContainerAgentHome("worker-code"))
                #expect(context.config == expected)
            }
            #expect(bound.rejection(for: .autonomous, tool: "sandbox_exec") == nil)
            #expect(bound.rejection(for: .pluginCreate, tool: "sandbox_plugin_register") != nil)
            #expect(bound.rejection(for: .backgroundProcess, tool: "sandbox_exec") != nil)

            #expect(AgentManager.shared.effectiveAutonomousExec(for: BuiltInWorker.research.agentId) == nil)
        }
    }

    // MARK: Catalog

    @Test func onlyPooledAgentsGetWrappersAndEveryWorkerDoes() {
        let pooled = Self.agent("Writer")
        let other = Self.agent("Accountant")
        let wrappers = AgentWrapperCatalog.wrappers(agents: [pooled, other], config: Self.config(pool: [pooled.id]))
        #expect(wrappers.map(\.name) == ["Writer", "Research", "Files", "Browser", "Code"])
        #expect(wrappers.first?.agentID == pooled.id)
        #expect(wrappers.dropFirst().allSatisfy { $0.worker != nil })
    }

    @Test func scoutTakesResearchsAsksOnlyWhileItCanSearch() {
        var scout = Self.agent("Scout")
        scout.sourceTemplateID = Teammate.scout.templateID
        let config = Self.config(pool: [scout.id])
        func names() -> [String] { AgentWrapperCatalog.wrappers(agents: [scout], config: config).map(\.name) }
        #expect(names() == ["Scout", "Files", "Browser", "Code"])
        scout.settings.webSearchEnabled = false
        #expect(names() == ["Scout", "Research", "Files", "Browser", "Code"])
        scout.settings.webSearchEnabled = true
        scout.toolsEnabled = false
        #expect(names().contains("Research"))
    }

    @Test func wrappersFollowEditsWithAStableID() {
        let id = UUID()
        let before = AgentWrapperCatalog.wrappers(agents: [Self.agent("Writer", id: id)], config: Self.config(pool: [id]))
        let after = AgentWrapperCatalog.wrappers(agents: [Self.agent("Editor", id: id)], config: Self.config(pool: [id]))
        let removed = AgentWrapperCatalog.wrappers(agents: [], config: Self.config(pool: [id]))
        let unpooled = AgentWrapperCatalog.wrappers(agents: [Self.agent("Editor", id: id)], config: Self.config(pool: []))
        #expect(before.first?.name == "Writer")
        #expect(after.first?.name == "Editor")
        #expect(before.first?.id == after.first?.id, "a rename keeps the wrapper's id")
        #expect(before.first?.id == AgentWrapperCatalog.id(forAgent: id))
        #expect(!removed.contains { $0.agentID == id })
        #expect(!unpooled.contains { $0.agentID == id })
    }

    @Test func aCustomAgentKeepsAWorkersName() {
        let research = Self.agent("Research")
        let wrappers = AgentWrapperCatalog.wrappers(agents: [research], config: Self.config(pool: [research.id]))
        #expect(wrappers.filter { $0.name == "Research" }.map(\.agentID) == [research.id])
        #expect(!wrappers.contains { $0.worker == .research })
    }

    @Test func aCustomAgentNamedLikeAWorkerIsReportedAsShadowingIt() {
        let research = Self.agent("research")
        let listing = AgentWrapperCatalog.listing(agents: [research], config: Self.config(pool: [research.id]))
        #expect(listing.shadowed == [.init(name: "research", by: .agent, worker: .research)])
        #expect(listing.shadowed.first?.logLine.contains("custom agent \"research\" shadows the built-in Research worker") == true)
        let unshadowed = AgentWrapperCatalog.listing(agents: [], config: Self.config(pool: []))
        #expect(unshadowed.shadowed.isEmpty)
    }

    @Test func idsAreDistinctVersion5UUIDs() {
        let ids = BuiltInWorker.allCases.map { AgentWrapperCatalog.id(forAgent: $0.agentId) }
        #expect(Set(ids).count == ids.count)
        #expect(ids.allSatisfy { $0.uuidString.dropFirst(14).first == "5" })
        #expect(AgentWrapperCatalog.id(forAgent: BuiltInWorker.code.agentId) == ids[3])
    }

    /// A config document can't bind a wrapper id where an installed workflow
    /// goes; the refusal says why instead of "not installed".
    @Test @MainActor func aConfigDocumentNamingAWrapperIDIsRefused() throws {
        let workerWrapper = AgentWrapperCatalog.id(forAgent: BuiltInWorker.research.agentId)
        let refusal = try #require(AgentWrapperCatalog.configRefusal(workerWrapper.uuidString))
        #expect(refusal.contains("not an installed workflow"))
        #expect(AgentWrapperCatalog.configRefusal(UUID().uuidString) == nil)
        #expect(AgentWrapperCatalog.configRefusal("No Such Workflow") == nil)
    }

    @Test func aWrapperIsOneAgentStepBoundByID() throws {
        let writer = Self.agent("Writer")
        let wrapper = try #require(
            AgentWrapperCatalog.wrappers(agents: [writer], config: Self.config(pool: [writer.id])).first)
        let installed = wrapper.installed
        let nodes = installed.definition.nodes
        #expect(nodes.count == 1)
        guard case .agent(let spec) = nodes.first?.kind else {
            Issue.record("a wrapper runs one agent step")
            return
        }
        #expect(spec.task == "{{input.task}}")
        #expect(installed.bindings.agents[spec.requirement.id] == writer.id.uuidString)
        #expect(wrapper.doc.inputs.map(\.name) == ["task"])
        #expect(wrapper.doc.kind == .wrapper)
        #expect(
            JSONSchemaValidator.validate(.object(["task": .string("Draft it")]), against: installed.definition.inputSchema)
                .isEmpty)
        #expect(!JSONSchemaValidator.validate(.object([:]), against: installed.definition.inputSchema).isEmpty)
    }

    // MARK: Workers

    final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var _workers: [(BuiltInWorker, String)] = []
        private var _gated = 0
        func worker(_ worker: BuiltInWorker, _ task: String) { lock.withLock { _workers.append((worker, task)) } }
        func gate() { lock.withLock { _gated += 1 } }
        var workers: [(BuiltInWorker, String)] { lock.withLock { _workers } }
        var gated: Int { lock.withLock { _gated } }
    }

    static func runtime(_ calls: Calls) -> AgentNodeExecutor.Runtime {
        AgentNodeExecutor.Runtime(
            directory: { AgentNodeExecutor.Directory(localAgents: [], sharedAgents: [], memberWorkspaceIDs: []) },
            allowed: { _, _ in
                calls.gate()
                return false
            },
            policy: { _, _ in
                calls.gate()
                return .deny
            },
            ask: { _, _ in .denied },
            persistAlwaysAllow: { _, _ in },
            askOwner: { _, _ in nil },
            dispatch: { _, _, _, _ in throw WorkflowNodeError.unsupported("not a worker") },
            insideDelegation: { false },
            runWorker: { worker, task, _ in
                calls.worker(worker, task)
                return AgentNodeExecutor.Delegated(
                    sessionID: UUID(), text: "Found it.", needsInput: false, completionTokens: 7, artifacts: [])
            })
    }

    static func context(wrapperAgentID: UUID?, task: String = "{{input.task}}") -> WorkflowNodeContext {
        WorkflowNodeContext(
            runID: UUID(), workflowID: UUID(), workflowName: "Research", node: WorkflowNode(
                id: AgentWrapperCatalog.nodeID, name: "Research", kind: .agent(AgentNodeSpec(agent: "Research", task: task))),
            input: .object([:]),
            bindings: BindingContext(input: .object(["task": .string("Find the 2025 solar output")]), outputs: [:]),
            model: nil, secretAccounts: [:], caller: WorkflowCaller(kind: .orchestrator), workspace: WF.tempDir(),
            attempt: 1, timeout: 60, wrapperAgentID: wrapperAgentID)
    }

    @Test func aWorkerStepSkipsOnlyThePoolAndSpawnPermission() async throws {
        let calls = Calls()
        let outcome = try await AgentNodeExecutor.run(
            spec: AgentNodeSpec(agent: "Research", task: "{{input.task}}"),
            context: Self.context(wrapperAgentID: BuiltInWorker.research.agentId), runtime: Self.runtime(calls))
        #expect(calls.workers.map(\.0) == [.research])
        #expect(calls.workers.first?.1 == "Find the 2025 solar output")
        #expect(calls.gated == 0, "a worker is not on a pool and has no spawn permission")
        #expect(outcome.output.objectValue?["text"] == .string("Found it."))
        #expect(outcome.outputTokens == 7)
    }

    @Test func aWorkerNameOutsideAWrapperRunIsNotAWorker() async {
        let calls = Calls()
        await #expect(throws: WorkflowNodeError.self) {
            try await AgentNodeExecutor.run(
                spec: AgentNodeSpec(agent: "Research", task: "{{input.task}}"),
                context: Self.context(wrapperAgentID: nil), runtime: Self.runtime(calls))
        }
        #expect(calls.workers.isEmpty)
    }

    @Test func aCustomAgentsWrapperStillChecksThePoolAndPermission() async {
        let calls = Calls()
        await #expect(throws: WorkflowNodeError.self) {
            try await AgentNodeExecutor.run(
                spec: AgentNodeSpec(agent: "Research", task: "{{input.task}}"),
                context: Self.context(wrapperAgentID: UUID()), runtime: Self.runtime(calls))
        }
        #expect(calls.workers.isEmpty)
    }

    @MainActor
    @Test func workerBudgetsFollowTheOrchestratorsDelegationBudgets() {
        let budgets = SpawnFanOutPolicy.effectiveBudgets(
            scope: SubagentScope(sessionId: "", toolCallId: "", agentId: Agent.defaultId))
        let target = BuiltInWorkerRunner.target(for: .files, timeout: 30)
        #expect(target.maxSteps == max(1, budgets.maxDelegateTurns))
        #expect(target.wallClockSeconds <= 30)
        #expect(target.toolNames() == BuiltInWorker.files.toolNames)
        #expect(target.agentId == BuiltInWorker.files.agentId)
        #expect(BuiltInWorker.browser.toolNames == ["browser_use"])
        #expect(Agent.isHiddenBuiltIn(BuiltInWorker.code.agentId))
    }

    @Test func aFailedWorkerEnvelopeIsAStepFailure() {
        let envelope = ToolEnvelope.failure(kind: .unavailable, message: "No sandbox.", tool: "agent", retryable: false)
        #expect(throws: WorkflowNodeError.self) { try BuiltInWorkerRunner.delegated(from: envelope, worker: .code) }
        let ok = ToolEnvelope.success(tool: "agent", result: ["text": "Done.", "usage": ["completion_tokens": 3]])
        #expect((try? BuiltInWorkerRunner.delegated(from: ok, worker: .research))?.text == "Done.")
        let browser = ToolEnvelope.success(tool: "browser_use", result: ["summary": "Signed in."])
        #expect((try? BuiltInWorkerRunner.delegated(from: browser, worker: .browser))?.text == "Signed in.")
    }

    // MARK: Runs

    @MainActor
    @Test func aWrapperRunRecordsItsAgentAndIsNeitherResumedNorRetried() throws {
        var run = WorkflowRun(
            workflowID: UUID(), workflowName: "Research", templateID: UUID(), templateVersion: 1,
            caller: WorkflowCaller(kind: .orchestrator), input: .object([:]), nodeIDs: ["agent"])
        run.wrapperAgentID = BuiltInWorker.research.agentId
        let decoded = try JSONDecoder().decode(WorkflowRun.self, from: try JSONEncoder().encode(run))
        #expect(decoded.wrapperAgentID == BuiltInWorker.research.agentId)
        #expect(decoded.isDerived)
        #expect(WorkflowRunService.reasonNotToResume(decoded) != nil)
        run.status = .failed
        #expect(WorkflowRunService.reasonNotToRetry(run) != nil)
    }
}

/// These run the live catalog against `AgentManager.shared`, so they use
/// the Browser worker: no teammate supersedes it, and a team another suite
/// creates meanwhile cannot hide it.
@Suite("Agent wrapper visibility", .serialized)
@MainActor
struct AgentWrapperVisibilityTests {

    @Test func wrappersAreRunnableButListedNowhereElse() async throws {
        let wrappers = AgentWrapperCatalog.live()
        #expect(wrappers.contains { $0.worker == .browser })
        let ids = Set(wrappers.map(\.id))
        let names = Set(wrappers.map(\.name))

        #expect(Set(RoutableWorkflowCatalog.names()).isSuperset(of: names))
        #expect(!InstalledWorkflowStore.shared.workflows.contains { ids.contains($0.id) })
        #expect(
            !SettingsEntitySearch.liveCandidates().contains { $0.kind == .workflow && ids.contains(UUID(uuidString: $0.key) ?? UUID()) })
        #expect(!WorkflowRunsTool.workflowsSummary().contains { names.contains($0["name"] as? String ?? "") })

        let status = try await StatusTool().execute(argumentsJSON: "{}")
        let payload = try #require(ToolEnvelope.successPayload(status) as? [String: Any])
        let runnable = try #require(payload["runnable_workflows"] as? [[String: Any]])
        #expect(runnable.contains { $0["name"] as? String == "Browser" })
    }

    /// Every surface that lists workflows or agents, by name: none of them
    /// shows a wrapper's id, or a worker as an agent or a workflow.
    @Test func noListingSurfaceShowsAWrapper() async throws {
        ConfigurationDomainBootstrap.registerBuiltIns()
        let wrappers = AgentWrapperCatalog.live()
        try #require(wrappers.contains { $0.worker == .browser })
        let wrapperIDs = wrappers.map { $0.id.uuidString.lowercased() }
        let workerIDs = BuiltInWorker.allCases.map { $0.agentId.uuidString.lowercased() }
        let workerNames = Set(BuiltInWorker.allCases.map(\.displayName))
        func leaks(_ text: String) -> String? {
            let lower = text.lowercased()
            return (wrapperIDs + workerIDs).first { lower.contains($0) }
        }

        // osaurus_config `workflows` and `export`.
        let config = try await ChatExecutionContext.$currentAgentId.withValue(Agent.configuratorId) {
            (
                workflows: try await OsaurusConfigTool().execute(argumentsJSON: #"{"action":"workflows"}"#),
                export: try await OsaurusConfigTool().execute(argumentsJSON: #"{"action":"export"}"#)
            )
        }
        #expect(ToolEnvelope.isSuccess(config.workflows), "\(config.workflows)")
        let rows = (ToolEnvelope.successPayload(config.workflows) as? [String: Any])?["workflows"] as? [[String: Any]] ?? []
        #expect(!rows.contains { workerNames.contains($0["name"] as? String ?? "") })
        #expect(leaks(config.workflows) == nil)
        #expect(ToolEnvelope.isSuccess(config.export), "\(config.export)")
        #expect(leaks(config.export) == nil)

        // osaurus_inspect `list` and `describe`.
        let inspect = try await ChatExecutionContext.$currentAgentId.withValue(Agent.configuratorId) {
            (
                list: try await OsaurusInspectTool().execute(argumentsJSON: #"{"action":"list","scope":"agents"}"#),
                automations: try await OsaurusInspectTool().execute(
                    argumentsJSON: #"{"action":"list","scope":"automations"}"#),
                describe: try await OsaurusInspectTool().execute(
                    argumentsJSON: #"{"action":"describe","scope":"agents","id":"Research"}"#)
            )
        }
        #expect(ToolEnvelope.isSuccess(inspect.list), "\(inspect.list)")
        #expect(leaks(inspect.list) == nil)
        #expect(leaks(inspect.automations) == nil)
        #expect(ToolEnvelope.isError(inspect.describe), "describe resolved a worker: \(inspect.describe)")

        // workflow_discover: the library and the agents an `agent` step can ask.
        let discover = try await ChatExecutionContext.$currentAgentId.withValue(Agent.architectId) {
            try await WorkflowDiscoverTool().execute(argumentsJSON: #"{"action":"templates"}"#)
        }
        #expect(ToolEnvelope.isSuccess(discover), "\(discover)")
        #expect(leaks(discover) == nil)
        let library = WorkflowDiscoverTool.templates(query: "", limit: 25)
        #expect(!library.contains { workerNames.contains($0["name"] as? String ?? "") })

        // Event and channel pickers read these two stores.
        #expect(!AgentManager.shared.agents.contains { Agent.isHiddenBuiltIn($0.id) })
        #expect(!InstalledWorkflowStore.shared.workflows.contains { wrapperIDs.contains($0.id.uuidString.lowercased()) })
        #expect(!HostedWorkflowLinkStore.shared.links.contains { wrapperIDs.contains($0.id.uuidString.lowercased()) })

        // HTTP: `GET /agents` and `GET /mcp/tools`.
        let server = try await startWrapperVisibilityServer()
        defer { Task { await server.shutdown() } }
        for path in ["/agents", "/mcp/tools"] {
            let (data, response) = try await URLSession.shared.data(
                from: URL(string: "http://\(server.host):\(server.port)\(path)")!)
            let body = String(decoding: data, as: UTF8.self)
            #expect((response as? HTTPURLResponse)?.statusCode == 200, "\(path): \(body)")
            #expect(leaks(body) == nil, "\(path) listed a wrapper")
            for name in workerNames {
                #expect(!body.contains(#""name":"\#(name)""#), "\(path) listed \(name)")
            }
        }
    }

    private func statusPayload() async throws -> [String: Any] {
        let status = try await StatusTool().execute(argumentsJSON: "{}")
        return try #require(ToolEnvelope.successPayload(status) as? [String: Any])
    }

    @Test func aWorkflowNamedLikeAWorkerShadowsItAndStatusSaysSo() async throws {
        let definition = WorkflowDefinition(
            inputSchema: WF.object(["task": WF.string]), outputSchema: WF.object([:]),
            nodes: [WF.code("echo", input: .object([:]), output: WF.object([:]))], edges: [])
        let template = try TemplateStore.shared.save(WF.template(definition, name: "Browser"))
        let installed = try InstalledWorkflowStore.shared.install(template, bindings: InstallBindings())
        defer {
            InstalledWorkflowStore.shared.delete(id: installed.id)
            try? TemplateStore.shared.delete(id: template.id)
        }
        try InstalledWorkflowStore.shared.setOrchestratorVisible(true, id: installed.id)

        let listing = RoutableWorkflowCatalog.listing()
        #expect(listing.shadowed.contains(.init(name: "Browser", by: .workflow, worker: .browser)))
        #expect(listing.docs.filter { $0.name == "Browser" }.map(\.kind) == [.installed])
        let shadowed = try #require(try await statusPayload()["shadowed_workers"] as? [[String: Any]])
        #expect(shadowed.contains { $0["name"] as? String == "Browser" && $0["shadowed_by"] as? String == "workflow" })
    }

    @Test func aCustomAgentShadowingAWorkerShowsInStatus() async throws {
        let code = Agent(id: UUID(), name: "Code", description: "Mine.", systemPrompt: "")
        var config = SubagentConfiguration()
        config.spawnableAgentIDs = [code.id]
        let saved = RoutableWorkflowCatalog.wrapperListing
        RoutableWorkflowCatalog.wrapperListing = { AgentWrapperCatalog.listing(agents: [code], config: config) }
        defer { RoutableWorkflowCatalog.wrapperListing = saved }

        let shadowed = try #require(try await statusPayload()["shadowed_workers"] as? [[String: Any]])
        #expect(
            shadowed.contains {
                $0["name"] as? String == "Code" && $0["shadowed_by"] as? String == "agent" && $0["worker"] as? String == "Code"
            })
    }

    @Test func runWorkflowRunsAWorkersWrapper() async throws {
        let seen = SeenContext()
        try await WorkflowExecutorOverride.with({
            ClosureExecutor { context, _ in
                await seen.record(context.wrapperAgentID)
                return WorkflowNodeOutcome(
                    output: .object(["text": .string("Three sources."), "agent": .string("Browser"), "needs_input": .bool(false)]))
            }
        }) {
            let result = try await ChatExecutionContext.$currentAgentId.withValue(Agent.defaultId) {
                try await RunWorkflowTool().execute(
                    argumentsJSON: #"{"workflow":"Browser","input":{"task":"Find sources on solar output"}}"#)
            }
            #expect(ToolEnvelope.isSuccess(result), "\(result)")
            #expect(await seen.ids == [BuiltInWorker.browser.agentId])
            let runID = try #require(WorkflowToolCall.runID(inResult: result))
            let run = try #require(WorkflowRunStore.shared.run(id: runID))
            #expect(run.wrapperAgentID == BuiltInWorker.browser.agentId)
            #expect(run.output?.objectValue?["text"] == .string("Three sources."))
            #expect(!WorkflowRunStore.shared.recentRuns().contains { $0.id == runID })

            let missing = try await ChatExecutionContext.$currentAgentId.withValue(Agent.defaultId) {
                try await RunWorkflowTool().execute(argumentsJSON: #"{"workflow":"Browser","input":{}}"#)
            }
            #expect(ToolEnvelope.isError(missing))
        }
    }

    @Test func aSingleStepToolAskShowsAStepFeedInChat() async throws {
        let latch = Latch()
        try await WorkflowExecutorOverride.with({
            ClosureExecutor { _, _ in
                await latch.wait()
                return WorkflowNodeOutcome(
                    output: .object(["text": .string("Done."), "agent": .string("Browser"), "needs_input": .bool(false)]))
            }
        }) {
            let toolCallID = "call-step-feed-\(UUID().uuidString)"
            let call = Task {
                try await ChatExecutionContext.$currentAgentId.withValue(Agent.defaultId) {
                    try await ChatExecutionContext.$currentToolCallId.withValue(toolCallID) {
                        try await RunWorkflowTool().execute(
                            argumentsJSON: #"{"workflow":"Browser","input":{"task":"Open the solar output page"}}"#)
                    }
                }
            }

            var feed: SubagentFeed?
            var stepShown = false
            for _ in 0 ..< 500 where !stepShown {
                feed = SubagentFeedRegistry.shared.feed(for: toolCallID)
                stepShown = feed.map { $0.currentEvents().count >= 2 } ?? false
                if !stepShown { try await Task.sleep(for: .milliseconds(10)) }
            }
            let live = try #require(feed, "the run_workflow tool card has a live feed")
            #expect(live.kindId == WorkflowCallFeed.kindId)
            #expect(live.title == "Browser")
            #expect(stepShown, "a row for the running step, after the run's own: \(live.currentEvents().map(\.title))")

            await latch.release()
            let result = try await call.value
            #expect(ToolEnvelope.isSuccess(result), "\(result)")
            #expect(live.currentStatus() == .finished(success: true, summary: "Finished 1 step"))
        }
    }

    actor SeenContext {
        var ids: [UUID?] = []
        func record(_ id: UUID?) { ids.append(id) }
    }

    actor Latch {
        private var open = false
        func release() { open = true }
        func wait() async {
            while !open { try? await Task.sleep(for: .milliseconds(5)) }
        }
    }
}

// MARK: - Server harness (loopback, no access keys)

private struct WrapperVisibilityServer {
    let group: MultiThreadedEventLoopGroup
    let channel: Channel
    let lease: HTTPServerTestLease
    let host: String
    let port: Int

    func shutdown() async {
        _ = try? await channel.close()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            group.shutdownGracefully { _ in cont.resume() }
        }
        await lease.release()
    }
}

private func startWrapperVisibilityServer() async throws -> WrapperVisibilityServer {
    let config = ServerConfiguration.default
    let lease = await HTTPServerTestLock.shared.acquire()
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    do {
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(
                        HTTPHandler(
                            configuration: config, apiKeyValidator: .empty, eventLoop: channel.eventLoop,
                            trustLoopback: true))
                }
            }
        let ch = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        return WrapperVisibilityServer(
            group: group, channel: ch, lease: lease, host: "127.0.0.1", port: ch.localAddress?.port ?? 0)
    } catch {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            group.shutdownGracefully { _ in cont.resume() }
        }
        await lease.release()
        throw error
    }
}
