//
//  WorkflowToolPermissionTests.swift
//  OsaurusCoreTests
//
//  Workflow steps authorize the subagent tools they list: the scope
//  captures the step's grant, Browser Use and Computer Use pass authority
//  on the Default agent only with it, setup reports what the step really
//  needs (permissions, models), `workflow_test` names the fix for a
//  refused step, and the tool catalog labels self-gating tools.
//

import Foundation
import Testing

@testable import OsaurusCore

struct WorkflowToolPermissionTests {

    // MARK: - Scope grant

    @Test
    func scopeCurrent_capturesTheWorkflowGrant() {
        let scope = ChatExecutionContext.$workflowGrantedToolNames.withValue([BrowserUseTool.toolName]) {
            SubagentScope.current()
        }
        #expect(scope.workflowGrantedToolNames == [BrowserUseTool.toolName])
        #expect(scope.agentId == Agent.defaultId)
        #expect(SubagentScope.current().workflowGrantedToolNames == nil)
    }

    @Test
    func isGrantedByWorkflow_matchesAnyOfTheCapabilityTools() {
        func scope(_ names: Set<String>?) -> SubagentScope {
            SubagentScope(sessionId: "s", toolCallId: "t", agentId: Agent.defaultId, workflowGrantedToolNames: names)
        }
        let registry = SubagentCapabilityRegistry.self
        #expect(scope([BrowserUseTool.toolName]).isGrantedByWorkflow(registry.browserUse))
        #expect(scope([ComputerUseTool.toolName]).isGrantedByWorkflow(registry.computerUse))
        #expect(scope([AppleScriptTool.toolName]).isGrantedByWorkflow(registry.appleScript))
        #expect(scope([MacQueryTool.toolName]).isGrantedByWorkflow(registry.appleScript))
        #expect(scope(["image"]).isGrantedByWorkflow(registry.image))
        #expect(scope(["video"]).isGrantedByWorkflow(registry.video))
        #expect(!scope([BrowserUseTool.toolName]).isGrantedByWorkflow(registry.computerUse))
        #expect(!scope([]).isGrantedByWorkflow(registry.browserUse))
        #expect(!scope(nil).isGrantedByWorkflow(registry.browserUse))
    }

    @Test
    func browserUse_onTheDefaultAgent_needsTheWorkflowGrant() async throws {
        let model = ResolvedModel(name: "test-model", isLocal: false)
        let kind = BrowserUseKind(goal: "Open the invoice page")
        let plain = SubagentScope(sessionId: "s", toolCallId: "t", agentId: Agent.defaultId)
        await #expect(throws: SubagentError.self) {
            try await kind.validateExecutionAuthority(plain, resolved: model)
        }
        let granted = SubagentScope(
            sessionId: "s", toolCallId: "t", agentId: Agent.defaultId,
            workflowGrantedToolNames: [BrowserUseTool.toolName])
        try await kind.validateExecutionAuthority(granted, resolved: model)
    }

    @Test
    func computerUse_onTheDefaultAgent_needsTheWorkflowGrant() async throws {
        let model = ResolvedModel(name: "test-model", isLocal: false)
        let kind = ComputerUseKind(goal: "Open Numbers", limits: RunLimits(wallClockSeconds: 30))
        let plain = SubagentScope(sessionId: "s", toolCallId: "t", agentId: Agent.defaultId)
        await #expect(throws: SubagentError.self) {
            try await kind.validateExecutionAuthority(plain, resolved: model)
        }
        let granted = SubagentScope(
            sessionId: "s", toolCallId: "t", agentId: Agent.defaultId,
            workflowGrantedToolNames: [ComputerUseTool.toolName])
        try await kind.validateExecutionAuthority(granted, resolved: model)
    }

    // MARK: - Setup items

    private static func toolStep(_ name: String) -> WorkflowNode {
        WorkflowNode(
            id: "step", name: "Step", kind: .tool(ToolNodeSpec(tool: ToolRef(name: name))),
            input: .object(["goal": "{{input.goal}}"]), outputSchema: .object([:]))
    }

    private static func template(calling tool: String) -> Template {
        WF.template(
            WorkflowDefinition(
                inputSchema: WF.object(["goal": WF.string], required: ["goal"]),
                nodes: [toolStep(tool)], output: .object(["text": "{{nodes.step.output.text}}"])))
    }

    private static func environment(
        tools: Set<String>, granted: Bool = true, defaultModel: String? = "gpt-test",
        permissions: [String: [SystemPermission]] = [:], capability: [String: String] = [:]
    ) -> SetupChecker.Environment {
        var env = SetupChecker.Environment(
            registeredToolNames: tools,
            modelCatalog: ConfigModelReference.Catalog(localModelIds: [], providers: []),
            isPermissionGranted: { _ in granted }, bookmarkResolves: { _ in true },
            knowledgeCollectionExists: { _ in true })
        env.defaultModel = defaultModel
        env.toolSystemPermissions = { permissions[$0] ?? [] }
        env.capabilityBlockReason = { capability[$0] }
        return env
    }

    @Test
    func setup_computerUseWithoutAccessibility_isABlockingPermissionItem() {
        let tool = ComputerUseTool.toolName
        let missing = SetupChecker.check(
            Self.template(calling: tool), bindings: InstallBindings(), subjectId: UUID(),
            environment: Self.environment(tools: [tool], granted: false, permissions: [tool: [.accessibility]]))
        let items = missing.items.filter { $0.kind == .systemPermission }
        #expect(items.map(\.value) == [SystemPermission.accessibility.rawValue])
        #expect(items.first?.isBlocking == true)

        let granted = SetupChecker.check(
            Self.template(calling: tool), bindings: InstallBindings(), subjectId: UUID(),
            environment: Self.environment(tools: [tool], granted: true, permissions: [tool: [.accessibility]]))
        #expect(granted.isClean)
    }

    @Test
    func setup_appleScriptWithoutAModel_isABlockingToolItem() {
        let tool = AppleScriptTool.toolName
        let reason = "No AppleScript model is installed."
        let missing = SetupChecker.check(
            Self.template(calling: tool), bindings: InstallBindings(), subjectId: UUID(),
            environment: Self.environment(tools: [tool], capability: [tool: reason]))
        #expect(missing.blocking.map(\.kind) == [.tool])
        #expect(missing.blocking.first?.detail == reason)

        let ready = SetupChecker.check(
            Self.template(calling: tool), bindings: InstallBindings(), subjectId: UUID(),
            environment: Self.environment(tools: [tool]))
        #expect(ready.isClean)
    }

    @Test
    func setup_browserUseWithoutADefaultModel_isBlocking() {
        let tool = BrowserUseTool.toolName
        let noModel = SetupChecker.check(
            Self.template(calling: tool), bindings: InstallBindings(), subjectId: UUID(),
            environment: Self.environment(tools: [tool], defaultModel: nil))
        #expect(noModel.blocking.map(\.kind) == [.tool])
        #expect(noModel.blocking.first?.value == tool)

        let withModel = SetupChecker.check(
            Self.template(calling: tool), bindings: InstallBindings(), subjectId: UUID(),
            environment: Self.environment(tools: [tool]))
        #expect(withModel.isClean)
    }

    // MARK: - workflow_test hint

    private static func failedRun(nodeError: String, envelope: String?) -> WorkflowRun {
        var run = WorkflowRun(
            workflowID: UUID(), workflowName: "Invoices", templateID: UUID(), templateVersion: 1,
            caller: WorkflowCaller(kind: .test), input: .object([:]), nodeIDs: ["step"])
        run.status = .failed
        run.error = WorkflowRunError(nodeID: "step", reason: nodeError)
        run.update("step") {
            $0.status = .failed
            $0.error = nodeError
            if let envelope {
                $0.toolCallRecords = [
                    WorkflowToolCallRecord(name: "browser_use", arguments: "{}", result: envelope, durationMs: 5, isError: true)
                ]
            }
        }
        return run
    }

    @Test
    func refusal_readsTheEnvelopeKind_andIgnoresOtherFailures() {
        let rejected = Self.failedRun(
            nodeError: "browser_use failed (rejected): Browser Use is not enabled.",
            envelope: ToolEnvelope.failure(kind: .rejected, message: "Browser Use is not enabled.", tool: "browser_use"))
        #expect(WorkflowTestTool.refusal(in: rejected)?.kind == "rejected")
        #expect(WorkflowTestTool.refusal(in: rejected)?.message == "Browser Use is not enabled.")

        let fromText = Self.failedRun(nodeError: "browser_use failed (user_denied): Declined.", envelope: nil)
        #expect(WorkflowTestTool.refusal(in: fromText)?.kind == "user_denied")

        let timeout = Self.failedRun(
            nodeError: "browser_use failed (timeout): Took too long.",
            envelope: ToolEnvelope.failure(kind: .timeout, message: "Took too long.", tool: "browser_use"))
        #expect(WorkflowTestTool.refusal(in: timeout) == nil)

        let folderDenied = Self.failedRun(
            nodeError: "file_copy failed (folder_denied): The person did not allow it.",
            envelope: ToolEnvelope.failure(kind: .rejected, message: "outside", tool: "file_copy"))
        #expect(WorkflowTestTool.refusal(in: folderDenied)?.kind == WorkflowTestTool.folderDeniedKind)
    }

    @Test
    func refusalHint_namesTheRealFix_andNeverAgentSettings() {
        let denied = WorkflowTestTool.refusalHint(kind: "user_denied", message: "")
        #expect(denied.contains("declined"))
        let permission = WorkflowTestTool.refusalHint(kind: "permission_denied", message: "Accessibility is off.")
        #expect(permission.contains("Accessibility is off."))
        #expect(permission.contains("System Settings"))
        let policy = WorkflowTestTool.refusalHint(kind: "rejected", message: "file_copy is denied by policy.")
        #expect(policy.contains("Deny in Tools"))
        let folder = WorkflowTestTool.refusalHint(kind: WorkflowTestTool.folderDeniedKind, message: "")
        #expect(folder.contains("declare_folder"))
        let scope = WorkflowTestTool.refusalHint(
            kind: "rejected", message: "'/Users/x/Desktop/a.pdf' is outside the folders this workflow may use: /tmp.")
        #expect(scope.contains("declare_folder"))
        for hint in [denied, permission, policy, folder, scope] {
            #expect(hint.contains("never ask the person to enable a feature on an agent"))
        }
    }

    // MARK: - Catalog label

    @Test @MainActor
    func catalog_labelsSelfGatingTools() {
        #expect(
            WorkflowToolCatalog.selfGatingToolNames
                == [BrowserUseTool.toolName, ComputerUseTool.toolName, AppleScriptTool.toolName])
        let status = WorkflowToolCatalog.status(of: BrowserUseTool.toolName)
        #expect(status != L("Runs without asking"))
    }
}
