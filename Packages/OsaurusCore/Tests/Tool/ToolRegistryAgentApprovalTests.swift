//
//  ToolRegistryAgentApprovalTests.swift
//  osaurus
//
//  Pins the per-agent approval contract in `runPermissionGate`: an agent's
//  Tool Approvals mode and its per-tool policy overrides. Never Ask replaces
//  only the standard approval card; Deny, per-call tools, headless and
//  external denials still win, and workflow runs and built-in agents keep
//  the global behaviour.
//
//  Under tests an approval card that would be shown resolves as a denial
//  (`ToolPermissionPromptService.isHeadlessTestProcess`), so "the card was
//  shown" is observed as a thrown denial without opening a panel.
//

import Foundation
import Testing

@testable import OsaurusCore

private final class AgentApprovalProbeTool: OsaurusTool, PermissionedTool, @unchecked Sendable {
    let name: String
    let description = "Test-only per-agent approval probe."
    let parameters: JSONValue? = nil
    let requirements: [String] = []
    let defaultPermissionPolicy: ToolPermissionPolicy
    private(set) var executions = 0

    init(name: String, policy: ToolPermissionPolicy) {
        self.name = name
        self.defaultPermissionPolicy = policy
    }

    func execute(argumentsJSON: String) async throws -> String {
        executions += 1
        return ToolEnvelope.success(tool: name, text: "ran")
    }
}

private final class AgentApprovalPerCallProbeTool: OsaurusTool, PermissionedTool, PerCallApprovalTool,
    @unchecked Sendable
{
    let name: String
    let description = "Test-only per-call probe."
    let parameters: JSONValue? = nil
    let requirements: [String] = []
    let defaultPermissionPolicy: ToolPermissionPolicy = .ask
    private(set) var executions = 0

    init(name: String) { self.name = name }

    func execute(argumentsJSON: String) async throws -> String {
        executions += 1
        return ToolEnvelope.success(tool: name, text: "ran")
    }
}

private final class AgentApprovalBlanketExemptProbeTool: OsaurusTool, PermissionedTool, BlanketApprovalExemptTool,
    @unchecked Sendable
{
    let name: String
    let description = "Test-only blanket-exempt probe."
    let parameters: JSONValue? = nil
    let requirements: [String] = []
    let defaultPermissionPolicy: ToolPermissionPolicy = .ask
    let isExemptFromBlanketApproval = true
    private(set) var executions = 0

    init(name: String) { self.name = name }

    func execute(argumentsJSON: String) async throws -> String {
        executions += 1
        return ToolEnvelope.success(tool: name, text: "ran")
    }
}

@Suite(.serialized)
@MainActor
struct ToolRegistryAgentApprovalTests {

    // MARK: Helpers

    /// Adding a custom agent seeds the subagent spawn pool, so the agent's
    /// lifetime stays inside a subagent store sandbox.
    private func runFixture(
        _ body: @MainActor @Sendable (DynamicToolProbeFixture) async throws -> Void
    ) async throws {
        try await DynamicToolProbeFixture.run { fixture in
            let lease = await acquireSubagentStoreSandbox("agent-approval")
            defer { lease.release() }
            try await body(fixture)
        }
    }

    private func probeName(_ label: String) -> String {
        "test_agent_approval_\(label)_" + UUID().uuidString.prefix(8).lowercased()
    }

    private func withAgent(
        mode: AgentToolApprovalMode = .useGlobal,
        policies: [String: ToolPermissionPolicy] = [:],
        _ body: (Agent) async throws -> Void
    ) async throws {
        var agent = AgentManager.newCustomAgentRecord(name: "Approval Probe \(UUID().uuidString.prefix(6))")
        agent.settings.toolApprovalMode = mode
        agent.settings.toolPolicies = policies
        AgentManager.shared.add(agent)
        do {
            try await body(agent)
        } catch {
            _ = await AgentManager.shared.delete(id: agent.id)
            throw error
        }
        _ = await AgentManager.shared.delete(id: agent.id)
    }

    private func run(
        _ tool: OsaurusTool,
        agentId: UUID?,
        workflowRunId: UUID? = nil,
        callId: String? = nil
    ) async throws -> String {
        try await ChatExecutionContext.$currentAgentId.withValue(agentId) {
            try await ChatExecutionContext.$currentWorkflowRunId.withValue(workflowRunId) {
                try await ChatExecutionContext.$currentToolCallId.withValue(callId) {
                    try await ToolRegistry.shared.execute(name: tool.name, argumentsJSON: "{}")
                }
            }
        }
    }

    private func setGlobalAutoAllow(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: ToolApprovalSettings.autoAllowAllDefaultsKey)
    }

    // MARK: Never Ask

    @Test func neverAskSkipsTheAskCard() async throws {
        try await runFixture { fixture in
            setGlobalAutoAllow(false)
            let tool = AgentApprovalProbeTool(name: probeName("never_ask"), policy: .ask)
            try fixture.register(tool)
            try await withAgent(mode: .neverAsk) { agent in
                let callId = "call-\(UUID().uuidString)"
                let result = try await run(tool, agentId: agent.id, callId: callId)
                #expect(tool.executions == 1)
                #expect(!ToolEnvelope.isError(result))
                #expect(ToolApprovalAudit.take(callId: callId) == .agentNeverAsk)
            }
        }
    }

    @Test func withoutTheSettingTheCardStillShows() async throws {
        try await runFixture { fixture in
            setGlobalAutoAllow(false)
            let tool = AgentApprovalProbeTool(name: probeName("use_global"), policy: .ask)
            try fixture.register(tool)
            try await withAgent(mode: .useGlobal) { agent in
                await #expect(throws: (any Error).self) {
                    _ = try await run(tool, agentId: agent.id)
                }
                #expect(tool.executions == 0)
            }
        }
    }

    @Test func denyOutranksNeverAsk() async throws {
        try await runFixture { fixture in
            let tool = AgentApprovalProbeTool(name: probeName("deny"), policy: .deny)
            try fixture.register(tool)
            try await withAgent(mode: .neverAsk) { agent in
                await #expect(throws: (any Error).self) {
                    _ = try await run(tool, agentId: agent.id)
                }
                #expect(tool.executions == 0)
            }
        }
    }

    @Test func perCallToolOutranksNeverAsk() async throws {
        try await runFixture { fixture in
            let tool = AgentApprovalPerCallProbeTool(name: probeName("per_call"))
            try fixture.register(tool)
            try await withAgent(mode: .neverAsk, policies: [tool.name: .auto]) { agent in
                await #expect(throws: (any Error).self) {
                    _ = try await run(tool, agentId: agent.id)
                }
                #expect(tool.executions == 0)
            }
        }
    }

    /// Never Ask never named a declared-destructive MCP tool; the agent's own
    /// Auto for that tool (Always Allow for *Agent*) does.
    @Test func blanketExemptToolNeedsAGrantThatNamesIt() async throws {
        try await runFixture { fixture in
            setGlobalAutoAllow(false)
            let tool = AgentApprovalBlanketExemptProbeTool(name: probeName("blanket_exempt"))
            try fixture.register(tool)
            try await withAgent(mode: .neverAsk) { agent in
                await #expect(throws: (any Error).self) {
                    _ = try await run(tool, agentId: agent.id)
                }
                #expect(tool.executions == 0)
            }
            try await withAgent(mode: .neverAsk, policies: [tool.name: .auto]) { agent in
                let callId = "call-\(UUID().uuidString)"
                _ = try await run(tool, agentId: agent.id, callId: callId)
                #expect(tool.executions == 1)
                #expect(ToolApprovalAudit.take(callId: callId) == .agentToolPolicy)
            }
        }
    }

    @Test func headlessDenyOutranksNeverAsk() async throws {
        try await runFixture { fixture in
            let tool = AgentApprovalProbeTool(name: probeName("headless"), policy: .ask)
            try fixture.register(tool)
            try await withAgent(mode: .neverAsk) { agent in
                await #expect(throws: (any Error).self) {
                    _ = try await ChatExecutionContext.$denyUnapprovedToolPrompts.withValue(true) {
                        try await run(tool, agentId: agent.id)
                    }
                }
                #expect(tool.executions == 0)
            }
        }
    }

    @Test func externalSurfaceOutranksNeverAsk() async throws {
        try await runFixture { fixture in
            let tool = AgentApprovalProbeTool(name: probeName("external"), policy: .ask)
            try fixture.register(tool)
            try await withAgent(mode: .neverAsk) { agent in
                await #expect(throws: (any Error).self) {
                    _ = try await ChatExecutionContext.$isExternalSurface.withValue(true) {
                        try await run(tool, agentId: agent.id)
                    }
                }
                #expect(tool.executions == 0)
            }
        }
    }

    // MARK: Ask and Use Global Setting

    @Test func askModeKeepsTheCardWhenTheGlobalSwitchIsOn() async throws {
        try await runFixture { fixture in
            setGlobalAutoAllow(true)
            let tool = AgentApprovalProbeTool(name: probeName("ask_mode"), policy: .ask)
            try fixture.register(tool)
            try await withAgent(mode: .ask) { agent in
                await #expect(throws: (any Error).self) {
                    _ = try await run(tool, agentId: agent.id)
                }
                #expect(tool.executions == 0)
            }
        }
    }

    @Test func useGlobalFollowsTheGlobalSwitch() async throws {
        try await runFixture { fixture in
            setGlobalAutoAllow(true)
            let tool = AgentApprovalProbeTool(name: probeName("follow_global"), policy: .ask)
            try fixture.register(tool)
            try await withAgent(mode: .useGlobal) { agent in
                let callId = "call-\(UUID().uuidString)"
                _ = try await run(tool, agentId: agent.id, callId: callId)
                #expect(tool.executions == 1)
                #expect(ToolApprovalAudit.take(callId: callId) == .globalAutoAllow)
            }
        }
    }

    // MARK: Per-agent tool policies

    @Test func agentAutoLoosensAGlobalAsk() async throws {
        try await runFixture { fixture in
            setGlobalAutoAllow(false)
            let tool = AgentApprovalProbeTool(name: probeName("agent_auto"), policy: .ask)
            try fixture.register(tool)
            try await withAgent(policies: [tool.name: .auto]) { agent in
                let callId = "call-\(UUID().uuidString)"
                _ = try await run(tool, agentId: agent.id, callId: callId)
                #expect(tool.executions == 1)
                #expect(ToolApprovalAudit.take(callId: callId) == .agentToolPolicy)
            }
        }
    }

    @Test func agentDenyTightensAGlobalAuto() async throws {
        try await runFixture { fixture in
            let tool = AgentApprovalProbeTool(name: probeName("agent_deny"), policy: .auto)
            try fixture.register(tool)
            try await withAgent(mode: .neverAsk, policies: [tool.name: .deny]) { agent in
                await #expect(throws: (any Error).self) {
                    _ = try await run(tool, agentId: agent.id)
                }
                #expect(tool.executions == 0)
            }
        }
    }

    @Test func agentAskTightensAGlobalAuto() async throws {
        try await runFixture { fixture in
            setGlobalAutoAllow(false)
            let tool = AgentApprovalProbeTool(name: probeName("agent_ask"), policy: .auto)
            try fixture.register(tool)
            try await withAgent(policies: [tool.name: .ask]) { agent in
                await #expect(throws: (any Error).self) {
                    _ = try await run(tool, agentId: agent.id)
                }
                #expect(tool.executions == 0)
            }
        }
    }

    @Test func globalDenyOutranksAgentAuto() async throws {
        try await runFixture { fixture in
            let tool = AgentApprovalProbeTool(name: probeName("global_deny"), policy: .ask)
            try fixture.register(tool)
            ToolRegistry.shared.setPolicy(.deny, for: tool.name)
            try await withAgent(mode: .neverAsk, policies: [tool.name: .auto]) { agent in
                await #expect(throws: (any Error).self) {
                    _ = try await run(tool, agentId: agent.id)
                }
                #expect(tool.executions == 0)
            }
        }
    }

    // MARK: Out of scope

    @Test func workflowRunIgnoresBothFields() async throws {
        try await runFixture { fixture in
            setGlobalAutoAllow(false)
            let askTool = AgentApprovalProbeTool(name: probeName("wf_ask"), policy: .ask)
            let autoTool = AgentApprovalProbeTool(name: probeName("wf_auto"), policy: .auto)
            try fixture.register(askTool)
            try fixture.register(autoTool)
            try await withAgent(mode: .neverAsk, policies: [autoTool.name: .deny]) { agent in
                let runId = UUID()
                await #expect(throws: (any Error).self) {
                    _ = try await run(askTool, agentId: agent.id, workflowRunId: runId)
                }
                #expect(askTool.executions == 0)
                _ = try await run(autoTool, agentId: agent.id, workflowRunId: runId)
                #expect(autoTool.executions == 1)
            }
        }
    }

    @Test func builtInAgentsIgnoreBothFields() async throws {
        try await runFixture { fixture in
            #expect(ToolApprovalResolver.scope(agentId: Agent.defaultId, inWorkflowRun: false) == nil)
            #expect(ToolApprovalResolver.scope(agentId: Agent.architectId, inWorkflowRun: false) == nil)
            #expect(ToolApprovalResolver.scope(agentId: Agent.configuratorId, inWorkflowRun: false) == nil)

            setGlobalAutoAllow(false)
            let tool = AgentApprovalProbeTool(name: probeName("built_in"), policy: .ask)
            try fixture.register(tool)
            await #expect(throws: (any Error).self) {
                _ = try await run(tool, agentId: Agent.defaultId)
            }
            #expect(tool.executions == 0)
        }
    }

    /// A spawned worker binds its own agent id, so the launcher's Never Ask
    /// does not travel with it.
    @Test func workerUsesItsOwnAgentSettings() async throws {
        try await runFixture { fixture in
            setGlobalAutoAllow(false)
            let tool = AgentApprovalProbeTool(name: probeName("worker"), policy: .ask)
            try fixture.register(tool)
            try await withAgent(mode: .neverAsk) { launcher in
                try await withAgent(mode: .ask) { worker in
                    _ = try await run(tool, agentId: launcher.id)
                    #expect(tool.executions == 1)
                    await #expect(throws: (any Error).self) {
                        _ = try await run(tool, agentId: worker.id)
                    }
                    #expect(tool.executions == 1)
                }
            }
        }
    }

    // MARK: Batch audit

    @Test func batchRecordsTheSkipReasonPerCall() async throws {
        try await runFixture { fixture in
            setGlobalAutoAllow(false)
            let askTool = AgentApprovalProbeTool(name: probeName("batch_ask"), policy: .ask)
            let autoTool = AgentApprovalProbeTool(name: probeName("batch_auto"), policy: .auto)
            try fixture.register(askTool)
            try fixture.register(autoTool)
            try await withAgent(mode: .neverAsk) { agent in
                let askId = "call-\(UUID().uuidString)"
                let autoId = "call-\(UUID().uuidString)"
                let calls: [(invocation: ServiceToolInvocation, callId: String)] = [
                    (ServiceToolInvocation(toolName: askTool.name, jsonArguments: "{}", toolCallId: nil), askId),
                    (ServiceToolInvocation(toolName: autoTool.name, jsonArguments: "{}", toolCallId: nil), autoId),
                ]
                let executions = await AgentToolLoop.runBatchInParallel(
                    calls,
                    sessionId: "test-session",
                    agentId: agent.id
                )
                #expect(executions.allSatisfy { !$0.isError })
                #expect(ToolApprovalAudit.take(callId: askId) == .agentNeverAsk)
                #expect(ToolApprovalAudit.take(callId: autoId) == nil)
            }
        }
    }

    @Test func auditStoreKeepsOnlyTheNewestEntries() {
        for index in 0..<(ToolApprovalAudit.capacity + 10) {
            ToolApprovalAudit.record(.globalAutoAllow, callId: "audit-cap-\(index)")
        }
        #expect(ToolApprovalAudit.take(callId: "audit-cap-0") == nil)
        #expect(ToolApprovalAudit.take(callId: "audit-cap-\(ToolApprovalAudit.capacity + 9)") == .globalAutoAllow)
        for index in 0..<(ToolApprovalAudit.capacity + 10) {
            _ = ToolApprovalAudit.take(callId: "audit-cap-\(index)")
        }
    }
}
