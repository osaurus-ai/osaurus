//
//  WorkflowCallingTests.swift
//  OsaurusCoreTests
//
//  Calling installed workflows: the per-agent `workflow_<slug>` tools, the
//  Orchestrator's `run_workflow`, which agents see which tool, the setup
//  check before every call, and `agents[].workflows` in osaurus_config.
//

import Foundation
import Testing

@testable import OsaurusCore

struct WorkflowToolShapeTests {
    @Test
    func parameters_areAClosedObjectUnlessTheSchemaSaysOtherwise() {
        let closed = WorkflowTool.parameters(for: WF.object(["client": WF.string], required: ["client"]))
        #expect(closed.objectValue?["type"]?.stringValue == "object")
        #expect(closed.objectValue?["additionalProperties"] == .bool(false))
        #expect(closed.objectValue?["required"] == .array([.string("client")]))

        let open = WorkflowTool.parameters(for: .object(["additionalProperties": .bool(true)]))
        #expect(open.objectValue?["additionalProperties"] == .bool(true))
        #expect(open.objectValue?["properties"] == .object([:]))
    }

    @Test
    func workflowCalls_areRecognizedByName_butArchitectToolsAreNot() {
        #expect(WorkflowToolCall.isWorkflowCall(RunWorkflowTool.toolName))
        #expect(WorkflowToolCall.isWorkflowCall("workflow_client_intake"))
        for name in ToolRegistry.architectToolNames where name.hasPrefix(WorkflowTool.namePrefix) {
            #expect(!WorkflowToolCall.isWorkflowCall(name), "\(name)")
        }
        #expect(!WorkflowToolCall.isWorkflowCall("file_read"))
    }

    @Test
    func runID_isReadFromSuccessAndFailureEnvelopes() {
        let id = UUID()
        let parked = WorkflowToolCall.envelope(
            WorkflowCallResult(status: .awaitingUser, runID: id), workflow: "Intake", tool: "workflow_intake")
        #expect(WorkflowToolCall.runID(inResult: parked) == id)
        #expect(!ToolEnvelope.isError(parked))

        let failed = WorkflowToolCall.envelope(
            WorkflowCallResult(status: .failed, runID: id), workflow: "Intake", tool: "workflow_intake")
        #expect(WorkflowToolCall.runID(inResult: failed) == id)
        #expect(ToolEnvelope.isError(failed))
    }
}

/// Drives `DialogCoordinator.shared`, so it runs with the other suites that do.
extension DialogSharedQueueTests {
@Suite(.serialized)
@MainActor
struct WorkflowCallingTests {
    private func withStore(_ body: @MainActor (InstalledWorkflowStore) async throws -> Void) async throws {
        try await ChatHistoryTestStorage.run {
            let store = InstalledWorkflowStore.shared
            store.reload()
            defer { store.resetForTesting() }
            try await body(store)
        }
    }

    private static func snapshot(
        _ agentId: UUID, workflows: [String] = [], orchestratorWorkflows: Bool = false
    ) -> AgentConfigSnapshot {
        AgentConfigSnapshot(
            agentId: agentId, toolsDisabled: false, memoryDisabled: false, autonomousConfig: nil, toolMode: .auto,
            model: nil, manualToolNames: nil, systemPrompt: "", dbEnabled: false, workflowToolNames: workflows,
            hasOrchestratorWorkflows: orchestratorWorkflows)
    }

    private static func toolNames(_ snapshot: AgentConfigSnapshot) -> Set<String> {
        Set(SystemPromptComposer.resolveTools(snapshot: snapshot, executionMode: .none).map(\.function.name))
    }

    @Test
    func installingRegistersTheTool_andUninstallingRemovesIt() async throws {
        try await withStore { store in
            let installed = try store.install(WF.template(WF.intake()), bindings: InstallBindings())
            #expect(installed.toolName == "workflow_client_intake")
            #expect(ToolRegistry.shared.specs(forTools: [installed.toolName]).count == 1)
            #expect(WorkflowTool.toolNames(enabled: [installed.id, UUID()]) == [installed.toolName])

            store.delete(id: installed.id)
            #expect(ToolRegistry.shared.specs(forTools: [installed.toolName]).isEmpty)
        }
    }

    @Test
    func onlyAgentsThatEnabledAWorkflowSeeItsTool_andOnlyTheOrchestratorSeesRunWorkflow() async throws {
        try await withStore { store in
            ConfigurationDomainBootstrap.registerBuiltIns()
            let installed = try store.install(WF.template(WF.intake()), bindings: InstallBindings())

            let custom = Self.toolNames(Self.snapshot(UUID(), workflows: [installed.toolName]))
            #expect(custom.contains(installed.toolName))
            #expect(!custom.contains(RunWorkflowTool.toolName))

            let other = Self.toolNames(Self.snapshot(UUID()))
            #expect(!other.contains(installed.toolName))

            let orchestrator = Self.toolNames(Self.snapshot(Agent.defaultId, orchestratorWorkflows: true))
            #expect(orchestrator.contains(RunWorkflowTool.toolName))
            #expect(!orchestrator.contains(installed.toolName))

            let nothingVisible = Self.toolNames(Self.snapshot(Agent.defaultId))
            #expect(!nothingVisible.contains(RunWorkflowTool.toolName), "no visible workflow, no run_workflow")
            #expect(
                !DefaultAgentSystemPromptBuilder.render(
                    compact: true, exposure: .from(toolNames: nothingVisible, folderBound: false)
                ).contains(RunWorkflowTool.toolName))

            let architect = Self.toolNames(Self.snapshot(Agent.architectId))
            #expect(!architect.contains(RunWorkflowTool.toolName))
        }
    }

    @Test
    func aCallWithMissingSetupFailsWithReasons_andFlagsTheWorkflow() async throws {
        try await withStore { store in
            let installed = try store.install(WF.template(WF.intake()), bindings: InstallBindings())
            #expect(!SetupChecker.check(installed).blocking.isEmpty, "the decision slot is unbound")

            let result = await WorkflowToolCall.run(
                workflowID: installed.id, input: .object(["client": .string("Acme")]),
                caller: WorkflowCaller(kind: .agent), tool: installed.toolName)
            #expect(ToolEnvelope.isError(result))
            #expect(result.contains(WorkflowCallResult.Status.needsSetup.rawValue))
            #expect(result.contains("\"no_model\":true"))
            #expect(result.contains("Choose a Model"))
            #expect(!result.contains("Main window → Workflows"))
            #expect(store.workflow(id: installed.id)?.needsSetup == true)
        }
    }

    @Test
    func aMissingKey_pointsToKeys_andAnAgentWithItsOwnValueRuns() async throws {
        try await withStore { store in
            try await CredentialStore._withIsolatedStoreForTesting { @MainActor in
                var template = WF.template(
                    WorkflowDefinition(
                        inputSchema: WF.object([:]),
                        nodes: [
                            WorkflowNode(
                                id: "fetch", name: "Fetch",
                                kind: .code(
                                    CodeSpec(source: "async function run() { return {} }", secrets: ["CLIO_API_KEY"])))
                        ],
                        output: .object([:])),
                    name: "Billing")
                template.requirements.secrets = [SecretRequirement(key: "CLIO_API_KEY", label: "Clio")]
                let installed = try store.install(template, bindings: InstallBindings())
                let agent = UUID()
                CredentialStore.current.save(
                    "CLIO_API_KEY", scope: .agent(agent), value: "agent-only", kind: .secret, origin: .workflow)

                let standalone = await WorkflowToolCall.run(
                    workflowID: installed.id, input: .object([:]), caller: WorkflowCaller(kind: .orchestrator),
                    tool: installed.toolName)
                #expect(ToolEnvelope.isError(standalone))
                #expect(standalone.contains("CLIO_API_KEY"))
                #expect(standalone.contains("Settings → Vault"))
                #expect(store.workflow(id: installed.id)?.needsSetup == false, "a missing key is not setup")

                let owned = await WorkflowToolCall.run(
                    workflowID: installed.id, input: .object([:]), caller: WorkflowCaller(kind: .agent, agentID: agent),
                    tool: installed.toolName)
                #expect(!owned.contains(WorkflowCallResult.Status.needsSetup.rawValue), "\(owned)")
                #expect(!ToolEnvelope.isError(owned), "\(owned)")
            }
        }
    }

    private static func askOnly() -> WorkflowDefinition {
        let spec = DialogSpec(title: "Client", fields: [DialogField(key: "firm", label: "Firm")])
        return WorkflowDefinition(
            outputSchema: WF.object(["firm": WF.string]),
            nodes: [WorkflowNode(id: "ask", name: "Ask", kind: .dialog(spec))],
            output: .object(["firm": "{{nodes.ask.output.firm}}"]))
    }

    private func withSilentNotifier(_ body: @MainActor () async throws -> Void) async rethrows {
        let previous = WorkflowDialogNotifier.onPresented
        WorkflowDialogNotifier.onPresented = { _ in }
        defer {
            WorkflowDialogNotifier.onPresented = previous
            DialogCoordinator.shared.resetForTesting()
        }
        try await body()
    }

    @Test
    func anExternalCallerParksOnAForm_insteadOfHoldingTheCall() async throws {
        try await withStore { store in
            try await withSilentNotifier {
                let installed = try store.install(WF.template(Self.askOnly(), name: "Ask"), bindings: InstallBindings())
                let result = await ChatExecutionContext.$isExternalSurface.withValue(true) {
                    let caller = await WorkflowToolCall.caller(kind: .agent)
                    #expect(caller.background)
                    return await WorkflowToolCall.run(
                        workflowID: installed.id, input: .object([:]), caller: caller, tool: installed.toolName)
                }
                #expect(!ToolEnvelope.isError(result))
                #expect(result.contains(WorkflowCallResult.Status.awaitingUser.rawValue))
                #expect(result.contains("cannot wait"))

                let runID = try #require(WorkflowToolCall.runID(inResult: result))
                let dialog = try #require(DialogCoordinator.shared.pending.first { $0.runID == runID })
                _ = DialogCoordinator.shared.answer(dialog.id, values: ["firm": .string("Acme")])
                let run = await WorkflowRunService.shared.result(of: runID)
                #expect(run?.status == .completed)
                #expect(run?.output == .object(["firm": .string("Acme")]))
            }
        }
    }

    @Test
    func anInAppChatCallerStillWaitsForTheForm() async {
        let caller = await WorkflowToolCall.caller(kind: .agent)
        #expect(!caller.background)
        let phone = await ChatExecutionContext.$isExternalSurface.withValue(true) {
            await ChatExecutionContext.$hasRemoteReviewer.withValue(true) { await WorkflowToolCall.caller(kind: .agent) }
        }
        #expect(!phone.background, "the paired phone answers forms over the relay")
    }

    @Test
    func stoppingAParkedTaskCancelsTheRun_withoutResumingIt() async throws {
        try await withStore { store in
            try await withSilentNotifier {
                let installed = try store.install(WF.template(Self.askOnly(), name: "Ask"), bindings: InstallBindings())
                let runID = WorkflowRunService.shared.start(
                    installed, input: .object([:]), caller: WorkflowCaller(kind: .agent, background: true))
                #expect(await WorkflowRunService.shared.settledOrParked(runID)?.status == .awaitingUser)

                let session = ChatSession()
                session.parkOnWorkflowRun(runID, callId: "call-1", toolName: installed.toolName)
                #expect(session.awaitingWorkflowRuns[runID]?.callId == "call-1")
                session.stop()
                #expect(session.awaitingWorkflowRuns.isEmpty)
                #expect(await WorkflowRunService.shared.result(of: runID)?.status == .cancelled)
                #expect(!session.isStreaming)
            }
        }
    }

    @Test
    func workflowTool_refusesAgentsThatDidNotEnableIt() async throws {
        try await withStore { store in
            let installed = try store.install(WF.template(WF.intake()), bindings: InstallBindings())
            let tool = WorkflowTool(installed)
            let result = try await ChatExecutionContext.$currentAgentId.withValue(UUID()) {
                try await tool.execute(argumentsJSON: #"{"client": "Acme"}"#)
            }
            #expect(ToolEnvelope.isError(result))
            #expect(result.contains("not enabled for this agent"))
        }
    }

    @Test
    func runWorkflow_isOrchestratorOnly_andResolvesOnlyVisibleWorkflows() async throws {
        try await withStore { store in
            let installed = try store.install(WF.template(WF.intake()), bindings: InstallBindings())
            let tool = RunWorkflowTool()

            let notOrchestrator = try await ChatExecutionContext.$currentAgentId.withValue(UUID()) {
                try await tool.execute(argumentsJSON: #"{"workflow": "Client Intake"}"#)
            }
            #expect(notOrchestrator.contains("Only the Orchestrator"))

            try store.setOrchestratorVisible(false, id: installed.id)
            let hidden = try await ChatExecutionContext.$currentAgentId.withValue(Agent.defaultId) {
                try await tool.execute(argumentsJSON: #"{"workflow": "Client Intake"}"#)
            }
            #expect(hidden.contains(#""kind":"rejected""#))
            #expect(hidden.contains("not marked \\\"Osaurus can run this for you\\\""))
            #expect(hidden.contains("An automation can still run it"))

            let unknown = try await ChatExecutionContext.$currentAgentId.withValue(Agent.defaultId) {
                try await tool.execute(argumentsJSON: #"{"workflow": "Nope"}"#)
            }
            #expect(unknown.contains(#"No workflow named \"Nope\""#))
            #expect(!unknown.contains("Client Intake"))

            try store.setOrchestratorVisible(true, id: installed.id)
            let visible = try await ChatExecutionContext.$currentAgentId.withValue(Agent.defaultId) {
                try await tool.execute(argumentsJSON: #"{"workflow": "client_intake", "input": {"client": "Acme"}}"#)
            }
            #expect(visible.contains(WorkflowCallResult.Status.needsSetup.rawValue), "resolved and reached setup")
        }
    }
}
}

@Suite(.serialized)
@MainActor
struct WorkflowDeclarativeConfigTests {
    private func withAgentAndWorkflow(
        _ body: @MainActor (Agent, InstalledWorkflow) async throws -> Void
    ) async throws {
        try await SandboxTestLock.runWithStoragePaths {
            await SubagentStoreTestLock.shared.acquire()
            defer { SubagentStoreTestLock.shared.release() }
            let store = InstalledWorkflowStore.shared
            store.reload()
            defer { store.resetForTesting() }
            let installed = try store.install(WF.template(WF.intake()), bindings: InstallBindings())
            let agent = AgentManager.shared.create(
                name: "Workflow Config Probe \(UUID().uuidString.prefix(6))",
                description: "Exercises agent workflow configuration in this isolated test.", systemPrompt: "")
            do {
                try await body(agent, installed)
            } catch {
                _ = await AgentManager.shared.delete(id: agent.id)
                throw error
            }
            _ = await AgentManager.shared.delete(id: agent.id)
        }
    }

    @Test
    func theWorkflowsLens_followsTheAgent_andAddsOrRemovesForIt() async throws {
        try await withAgentAndWorkflow { agent, installed in
            #expect(WorkflowListModel.workflows(for: agent.id).isEmpty)
            WorkflowListModel.add(installed.id, for: agent.id)
            #expect(WorkflowListModel.workflows(for: agent.id).map(\.id) == [installed.id])
            WorkflowListModel.remove(installed.id, for: agent.id)
            #expect(WorkflowListModel.workflows(for: agent.id).isEmpty)

            #expect(WorkflowListModel.workflows(for: Agent.defaultId).map(\.id) == [installed.id])
            WorkflowListModel.remove(installed.id, for: Agent.defaultId)
            #expect(WorkflowListModel.workflows(for: Agent.defaultId).isEmpty, "the Orchestrator lists what it may run")
            #expect(InstalledWorkflowStore.shared.workflow(id: installed.id)?.orchestratorVisible == false)
            WorkflowListModel.add(installed.id, for: Agent.defaultId)
            #expect(WorkflowListModel.workflows(for: Agent.defaultId).map(\.id) == [installed.id])
            #expect(WorkflowListModel.workflows(for: Agent.architectId).isEmpty)
        }
    }

    private func document(agent: String, workflows: [String]?) -> OsaurusConfigDocument {
        var entry = AgentEntry(name: agent)
        entry.workflows = workflows
        var document = OsaurusConfigDocument()
        document.agents = [entry]
        return document
    }

    @Test
    func theManifestAndYAMLKnowTheKey() throws {
        #expect(ConfigManifest.knownKeys["agents[]"]?.contains("workflows") == true)
        let decoded = try ConfigYAML.decode(
            """
            agents:
              - name: Planner
                workflows: [Client Intake]
            """)
        #expect(decoded.agents?.first?.workflows == ["Client Intake"])
    }

    @Test
    func unknownWorkflowNamesFailValidation_listingTheInstalledOnes() async throws {
        try await withAgentAndWorkflow { agent, installed in
            do {
                _ = try ConfigPlanner.plan(document: document(agent: agent.name, workflows: ["Nope"]), prune: false)
                Issue.record("expected validation failure for `Nope`")
            } catch let issues as ConfigPlanIssues {
                let joined = issues.issues.joined(separator: "\n")
                #expect(joined.contains("Nope"))
                #expect(joined.contains(installed.name))
            }
        }
    }

    @Test
    func anAgentTemplateWaitsForItsBundledWorkflows_thenEnablesThem() async throws {
        try await SandboxTestLock.runWithStoragePaths {
            let store = InstalledWorkflowStore.shared
            store.reload()
            let templates = TemplateStore.shared
            templates.reload()
            let intake = WF.template(WF.intake())
            let deskName = "Intake Desk \(UUID().uuidString.prefix(6))"
            var agent = AgentTemplate(name: deskName, agent: AgentEntry(name: deskName))
            agent.workflowReferences = [WorkflowReference(id: intake.id, minVersion: 1)]
            agent.bundled = [intake]
            let saved = try templates.save(agent)
            defer {
                store.resetForTesting()
                try? templates.delete(id: saved.id)
                templates.reload()
            }
            let args = #"{"action": "plan", "template": "\#(saved.id.uuidString)"}"#

            func plan() async throws -> String {
                try await ChatExecutionContext.$currentAgentId.withValue(Agent.configuratorId) {
                    try await OsaurusConfigTool().execute(argumentsJSON: args)
                }
            }
            let refused = try await plan()
            #expect(ToolEnvelope.isError(refused))
            #expect(refused.contains("needs_setup"))
            #expect(refused.contains(intake.name))

            let installed = try store.install(intake, bindings: InstallBindings())
            let planned = try await plan()
            #expect(!ToolEnvelope.isError(planned), "\(planned)")
            #expect(planned.contains("workflows") && planned.contains(installed.name), "\(planned)")
        }
    }

    @Test
    func planApplyAndExportRoundTrip() async throws {
        try await withAgentAndWorkflow { agent, installed in
            let plan = try ConfigPlanner.plan(document: document(agent: agent.name, workflows: [installed.name]), prune: false)
            let action = plan.actions.first { $0.section == "agents" && $0.target == agent.name }
            #expect(action?.changes.contains { $0.contains("workflows") && $0.contains(installed.name) } == true)

            let results = await ConfigApplier.apply(
                document: document(agent: agent.name, workflows: [installed.name]), prune: false)
            #expect(results.allSatisfy { $0.status != .failed }, "\(results)")
            #expect(AgentManager.shared.agent(for: agent.id)?.settings.enabledWorkflowIDs == [installed.id])

            let exported = ConfigExporter.export(sections: [.agents])
            #expect(exported.agents?.first { $0.name == agent.name }?.workflows == [installed.name])
            let replan = try ConfigPlanner.plan(document: exported, prune: false)
            #expect(!replan.actions.contains { $0.section == "agents" && $0.target == agent.name }, "\(replan.actions)")

            _ = await ConfigApplier.apply(document: document(agent: agent.name, workflows: nil), prune: false)
            #expect(AgentManager.shared.agent(for: agent.id)?.settings.enabledWorkflowIDs == [installed.id], "absent key")
            _ = await ConfigApplier.apply(document: document(agent: agent.name, workflows: []), prune: false)
            #expect(AgentManager.shared.agent(for: agent.id)?.settings.enabledWorkflowIDs == [])
        }
    }

    @Test
    func theSlashMenuListsTheAgentsEnabledWorkflows() async throws {
        try await withAgentAndWorkflow { agent, installed in
            let registry = SlashCommandRegistry.shared
            #expect(registry.workflowCommands(agentId: agent.id).isEmpty)

            var enabled = try #require(AgentManager.shared.agent(for: agent.id))
            enabled.settings.enabledWorkflowIDs = [installed.id, UUID()]
            AgentManager.shared.update(enabled)

            let commands = registry.workflowCommands(agentId: agent.id)
            #expect(commands.map(\.id) == [installed.id], "an uninstalled id is skipped")
            #expect(commands.first?.name == "client-intake")
            #expect(commands.first?.kind == .workflow)
            #expect(registry.filtered(query: "client-in", agentId: agent.id).contains { $0.id == installed.id })
            #expect(!registry.filtered(query: "client-in").contains { $0.id == installed.id }, "no agent, no workflows")
        }
    }
}
