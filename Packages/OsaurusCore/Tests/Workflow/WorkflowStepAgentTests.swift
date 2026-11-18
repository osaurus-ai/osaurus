//
//  WorkflowStepAgentTests.swift
//  OsaurusCoreTests
//
//  A tool step's `agent` key: which agent it resolves to, that the call
//  runs as that agent (an Apple tool on the agent's own switch, a folder
//  tool in the agent's folder), that a missing agent fails the step, and
//  that a step without the key behaves as before. Setup: a permission is
//  advisory only for an attended run of an agent-keyed step that macOS
//  asks for. Also the Onboarding agent's handoff, and teammates
//  superseding workers.
//

import Foundation
import Testing

@testable import OsaurusCore

struct WorkflowStepAgentTests {

    private static let calendarTool = AppleApp.toolNames(for: [.calendar]).sorted().first!

    private static func agent(_ name: String, teammate: Teammate? = nil, builtIn: Bool = false) -> Agent {
        var agent = Agent(name: name, description: "\(name) does things.", systemPrompt: "", isBuiltIn: builtIn)
        agent.sourceTemplateID = teammate?.templateID
        return agent
    }

    // MARK: - ToolRef

    @Test
    func toolRef_withoutAnAgent_decodesAndEncodesAsBefore() throws {
        let decoded = try JSONDecoder().decode(ToolRef.self, from: Data(#"{"name":"calendar_list"}"#.utf8))
        #expect(decoded.agent == nil)
        let encoded = String(decoding: try JSONEncoder().encode(ToolRef(name: "calendar_list")), as: UTF8.self)
        #expect(!encoded.contains("agent"))
        let keyed = try JSONDecoder().decode(
            ToolRef.self, from: Data(#"{"name":"calendar_list","agent":"Planner"}"#.utf8))
        #expect(keyed.agent == "Planner")
    }

    @Test
    func agentKeyedToolNames_dropsAToolAnUnkeyedStepAlsoCalls() {
        let def = WorkflowDefinition(
            inputSchema: .object([:]),
            nodes: [
                WorkflowNode(id: "a", name: "A", kind: .tool(ToolNodeSpec(tool: ToolRef(name: "x", agent: "Planner")))),
                WorkflowNode(id: "b", name: "B", kind: .tool(ToolNodeSpec(tool: ToolRef(name: "y", agent: "Planner")))),
                WorkflowNode(id: "c", name: "C", kind: .tool(ToolNodeSpec(tool: ToolRef(name: "y")))),
            ],
            output: .object([:]))
        #expect(def.agentKeyedToolNames == ["x"])
        #expect(def.agentKeyedToolCalls.map(\.tool) == ["x", "y"])
    }

    @Test
    func agentKeyedToolStep_needsFormat5_soAnOlderBuildRefusesIt() {
        let keyed = WorkflowDefinition(
            inputSchema: .object([:]),
            nodes: [WorkflowNode(id: "a", name: "A", kind: .tool(ToolNodeSpec(tool: ToolRef(name: "x", agent: "Planner"))))],
            output: .object([:]))
        let plain = WorkflowDefinition(
            inputSchema: .object([:]),
            nodes: [WorkflowNode(id: "a", name: "A", kind: .tool(ToolNodeSpec(tool: ToolRef(name: "x"))))],
            output: .object([:]))
        #expect(keyed.requiredFormatVersion == 5)
        #expect(plain.requiredFormatVersion == 1)
        #expect(Template.currentFormatVersion == 5)
    }

    // MARK: - Resolution

    @Test
    func resolve_templateIDThenAgentIDThenAUniqueName_neverABuiltIn() {
        let planner = Self.agent("My Calendar", teammate: .planner)
        let other = Self.agent("Writer")
        let twinA = Self.agent("Twin")
        let twinB = Self.agent("twin")
        let builtIn = Self.agent("Builtin", builtIn: true)
        let agents = [planner, other, twinA, twinB, builtIn]

        #expect(WorkflowStepAgent.resolve(Teammate.planner.templateID.uuidString, in: agents)?.id == planner.id)
        #expect(WorkflowStepAgent.resolve(other.id.uuidString, in: agents)?.id == other.id)
        #expect(WorkflowStepAgent.resolve("writer", in: agents)?.id == other.id)
        #expect(WorkflowStepAgent.resolve("Twin", in: agents) == nil, "an ambiguous name matches nothing")
        #expect(WorkflowStepAgent.resolve("Builtin", in: agents) == nil)
        #expect(WorkflowStepAgent.resolve(builtIn.id.uuidString, in: agents) == nil)
        #expect(WorkflowStepAgent.resolve(Teammate.keeper.templateID.uuidString, in: agents) == nil)
        #expect(WorkflowStepAgent.resolve("  ", in: agents) == nil)
    }

    @Test
    func missingMessage_namesTheTeammate() {
        #expect(WorkflowStepAgent.missingMessage(Teammate.keeper.templateID.uuidString).contains("Keeper"))
        #expect(WorkflowStepAgent.missingMessage("Accountant").contains("Accountant"))
    }

    // MARK: - Execution

    private actor Seen {
        var agentIds: [UUID?] = []
        var grants: [Set<String>?] = []
        var roots: [URL?] = []
        var paths: [[URL]?] = []
        func record(_ agentId: UUID?, _ grant: Set<String>?, _ root: URL?, _ paths: [URL]?) {
            agentIds.append(agentId)
            grants.append(grant)
            roots.append(root)
            self.paths.append(paths)
        }
    }

    private static func run(
        tool: String, agent reference: String?, match: WorkflowStepAgent.Match?, seen: Seen
    ) async throws -> WorkflowNodeOutcome {
        let spec = ToolNodeSpec(tool: ToolRef(name: tool, agent: reference))
        let node = WorkflowNode(id: "read", name: "Read", kind: .tool(spec))
        let context = WorkflowNodeContext(
            runID: UUID(), workflowID: UUID(), workflowName: "Week", node: node, input: .object([:]),
            bindings: BindingContext(input: .object([:])), model: nil, secretAccounts: [:],
            caller: WorkflowCaller(kind: .user), workspace: WF.tempDir(), attempt: 1, timeout: 60)
        let runtime = ToolNodeExecutor.Runtime(
            resolve: { name in
                ToolNodeExecutor.Resolved(
                    spec: Tool(type: "function", function: ToolFunction(name: name, description: name, parameters: nil)),
                    outputSchema: nil)
            },
            execute: { name, _, _ in
                await seen.record(
                    ChatExecutionContext.currentAgentId, ChatExecutionContext.workflowGrantedToolNames,
                    ChatExecutionContext.currentFolderRoot, ChatExecutionContext.workflowGrantedPaths)
                return ToolEnvelope.success(tool: name, result: ["events": 2])
            },
            resolveAgent: { _ in match })
        return try await ChatExecutionContext.$workflowGrantedToolNames.withValue([tool]) {
            try await ToolNodeExecutor.run(spec: spec, context: context, runtime: runtime)
        }
    }

    @Test
    func anAgentKeyedAppleStep_runsAsTheAgent_withoutTheStepsGrant() async throws {
        let seen = Seen()
        let id = UUID()
        let match = WorkflowStepAgent.Match(id: id, name: "Planner", enabledAppleApps: [.calendar])
        _ = try await Self.run(tool: Self.calendarTool, agent: "Planner", match: match, seen: seen)
        #expect(await seen.agentIds == [id])
        #expect(await seen.grants.first??.contains(Self.calendarTool) == false)
    }

    /// Regression: an existing Apple-tool step without `agent` keeps the
    /// step's grant and runs with no agent bound, exactly as before.
    @Test
    func anUnkeyedAppleStep_keepsTheGrantAndBindsNoAgent() async throws {
        let seen = Seen()
        _ = try await Self.run(tool: Self.calendarTool, agent: nil, match: nil, seen: seen)
        #expect(await seen.agentIds == [nil])
        #expect(await seen.grants.first??.contains(Self.calendarTool) == true)
    }

    @Test
    func anAgentKeyedFolderStep_readsInTheAgentsFolder() async throws {
        let seen = Seen()
        let folder = URL(fileURLWithPath: "/tmp/keeper-\(UUID().uuidString)", isDirectory: true)
        let match = WorkflowStepAgent.Match(id: UUID(), name: "Keeper", enabledAppleApps: [], workingFolder: folder)
        _ = try await Self.run(tool: "file_search", agent: "Keeper", match: match, seen: seen)
        #expect(await seen.roots == [folder])
        #expect(await seen.paths.first??.contains(folder) == true)
        #expect(await seen.grants.first??.contains("file_search") == true, "only an Apple tool loses the grant")
    }

    @Test
    func aMissingAgent_failsTheStepBeforeTheCall() async {
        let seen = Seen()
        do {
            _ = try await Self.run(tool: Self.calendarTool, agent: "Gone", match: nil, seen: seen)
            Issue.record("expected agent_missing")
        } catch {
            let underlying = (error as? RecordedNodeFailure)?.underlying ?? error
            guard case WorkflowNodeError.toolFailed(_, let kind, _, let retryable)? = underlying as? WorkflowNodeError
            else {
                Issue.record("unexpected \(error)")
                return
            }
            #expect(kind == "agent_missing")
            #expect(!retryable)
        }
        #expect(await seen.agentIds.isEmpty)
    }

    // MARK: - Setup

    private static func template(tool: String, agent: String?) -> Template {
        WF.template(
            WorkflowDefinition(
                inputSchema: .object([:]),
                nodes: [
                    WorkflowNode(
                        id: "step", name: "Step", kind: .tool(ToolNodeSpec(tool: ToolRef(name: tool, agent: agent))),
                        outputSchema: .object([:]))
                ],
                output: .object(["text": "{{nodes.step.output.text}}"])))
    }

    private static func environment(
        tool: String, permission: SystemPermission, attended: Bool,
        stepAgent: WorkflowStepAgent.Match? = WorkflowStepAgent.Match(
            id: UUID(), name: "Planner", enabledAppleApps: Set(AppleApp.allCases))
    ) -> SetupChecker.Environment {
        var env = SetupChecker.Environment(
            registeredToolNames: [tool],
            modelCatalog: ConfigModelReference.Catalog(localModelIds: [], providers: []),
            isPermissionGranted: { _ in false }, bookmarkResolves: { _ in true },
            knowledgeCollectionExists: { _ in true })
        env.defaultModel = "gpt-test"
        env.toolSystemPermissions = { $0 == tool ? [permission] : [] }
        env.stepAgent = { _ in stepAgent }
        env.attended = attended
        return env
    }

    private static func permissionSeverity(
        agent: String?, permission: SystemPermission = .calendar, attended: Bool
    ) -> SetupItem.Severity? {
        let report = SetupChecker.check(
            template(tool: calendarTool, agent: agent), bindings: InstallBindings(), subjectId: UUID(),
            environment: environment(tool: calendarTool, permission: permission, attended: attended))
        return report.items.first { $0.kind == .systemPermission }?.severity
    }

    @Test
    func setup_aPromptablePermission_isAdvisoryOnlyAttendedAndAgentKeyed() {
        #expect(Self.permissionSeverity(agent: "Planner", attended: true) == .advisory)
        #expect(Self.permissionSeverity(agent: "Planner", attended: false) == .blocking, "automations stay blocking")
        #expect(Self.permissionSeverity(agent: nil, attended: true) == .blocking, "unkeyed steps stay blocking")
        #expect(
            Self.permissionSeverity(agent: "Planner", permission: .accessibility, attended: true) == .blocking,
            "macOS never prompts for Accessibility")
    }

    @Test
    func setup_aMissingStepAgent_isBlocking() {
        let report = SetupChecker.check(
            Self.template(tool: Self.calendarTool, agent: "Gone"), bindings: InstallBindings(), subjectId: UUID(),
            environment: Self.environment(
                tool: Self.calendarTool, permission: .calendar, attended: true, stepAgent: nil))
        let agentItems = report.blocking.filter { $0.kind == .agent }
        #expect(agentItems.map(\.value) == ["Gone"])
    }

    @Test
    func setup_aStepAgentWithTheAppOff_isBlocking() {
        let report = SetupChecker.check(
            Self.template(tool: Self.calendarTool, agent: "Planner"), bindings: InstallBindings(), subjectId: UUID(),
            environment: Self.environment(
                tool: Self.calendarTool, permission: .calendar, attended: true,
                stepAgent: WorkflowStepAgent.Match(id: UUID(), name: "Planner", enabledAppleApps: [])))
        #expect(report.blocking.contains { $0.kind == .agent && $0.value == "Planner:\(AppleApp.calendar.rawValue)" })
    }

    @Test
    func attendedCallers() {
        #expect(WorkflowCaller(kind: .user).isAttended)
        #expect(WorkflowCaller(kind: .orchestrator).isAttended)
        #expect(!WorkflowCaller(kind: .event).isAttended)
        #expect(!WorkflowCaller(kind: .test).isAttended)
    }

    @Test
    func permissionsMacOSAsksFor() {
        #expect(SystemPermission.calendar.promptsWhenMissing)
        #expect(SystemPermission.automationMail.promptsWhenMissing)
        for manual in [SystemPermission.disk, .accessibility, .screenRecording] {
            #expect(!manual.promptsWhenMissing)
        }
    }

    // MARK: - Onboarding agent

    @Test
    func theOnboardingAgentIsHidden() {
        #expect(Agent.onboardingId.uuidString == "00000000-0000-0000-0000-000000000008")
        #expect(Agent.isHiddenBuiltIn(Agent.onboardingId))
    }

    @Test
    func configuratorHandoff_admitsTheOrchestratorAndTheOnboardingAgentOnly() async throws {
        #expect(ConfiguratorHandoffTool.allowedCallerIds == [Agent.defaultId, Agent.onboardingId])
        let unknown = try await ChatExecutionContext.$currentAgentId.withValue(UUID()) {
            try await ConfiguratorHandoffTool().execute(argumentsJSON: #"{"user_message":"hi","brief":"x"}"#)
        }
        #expect(ToolEnvelope.isError(unknown))
        #expect(unknown.contains("Only the Orchestrator"))
        let none = try await ConfiguratorHandoffTool().execute(argumentsJSON: #"{"user_message":"hi","brief":"x"}"#)
        #expect(none.contains("Only the Orchestrator"))
        let onboarding = try await ChatExecutionContext.$currentAgentId.withValue(Agent.onboardingId) {
            try await ConfiguratorHandoffTool().execute(argumentsJSON: #"{"brief":"x"}"#)
        }
        #expect(!onboarding.contains("Only the Orchestrator"), "past the caller guard: \(onboarding)")
    }

    // MARK: - Worker superseding

    private static func wrapperNames(_ agents: [Agent], pool: [UUID]? = nil) -> [String] {
        var config = SubagentConfiguration()
        config.spawnableAgentIDs = pool ?? agents.map(\.id)
        return AgentWrapperCatalog.wrappers(agents: agents, config: config).map(\.name)
    }

    @Test
    func scoutHidesResearch_builderHidesCode_keeperKeepsFiles() {
        let scout = Self.agent("Scout", teammate: .scout)
        let builder = Self.agent("Builder", teammate: .builder)
        let keeper = Self.agent("Keeper", teammate: .keeper)
        let names = Self.wrapperNames([scout, builder, keeper])
        #expect(names == ["Scout", "Builder", "Keeper", "Files", "Browser"])
    }

    @Test
    func aRenamedTeammateStillSupersedes_andTheWorkerReturnsWithoutIt() {
        let renamed = Self.agent("Web Digger", teammate: .scout)
        #expect(!Self.wrapperNames([renamed]).contains("Research"))
        #expect(Self.wrapperNames([]).contains("Research"))
        #expect(Self.wrapperNames([renamed], pool: []).contains("Research"), "an unpooled teammate takes no asks")
    }
}
