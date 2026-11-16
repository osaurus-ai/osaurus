//
//  ToolApprovalCardAgentEntryTests.swift
//  osaurus
//
//  Pins the approval card's agent-scoped "Don't ask again" entries through
//  the real `ToolRegistry` gate: Always Allow for the agent, Always Allow for
//  every agent, and Never Ask for the agent. Each answer is saved before the
//  next queued card is re-checked, so cards it covers settle without
//  showing. Per-call tools, built-in agents, workflow runs and cards answered
//  from a paired phone keep the card exactly as before.
//

import Foundation
import Testing

@testable import OsaurusCore

private final class CardEntryProbeTool: OsaurusTool, PermissionedTool, @unchecked Sendable {
    let name: String
    let description = "Test-only approval card probe."
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

private final class CardEntryPerCallProbeTool: OsaurusTool, PermissionedTool, PerCallApprovalTool,
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

private final class CardProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(id: UUID, toolName: String)] = []

    var presented: [(id: UUID, toolName: String)] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    var presenter: ToolPermissionPromptService.TestPresenter {
        { [self] id, name, _ in
            lock.lock()
            entries.append((id, name))
            lock.unlock()
        }
    }

    func waitForPresented(_ count: Int) async {
        for _ in 0 ..< 400 where presented.count < count {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

@Suite(.serialized, .toolPermissionPromptQueue)
@MainActor
struct ToolApprovalCardAgentEntryTests {

    // MARK: Helpers

    /// Adding a custom agent seeds the subagent spawn pool, so the agent's
    /// lifetime stays inside a subagent store sandbox.
    private func runFixture(
        _ body: @MainActor @Sendable (DynamicToolProbeFixture) async throws -> Void
    ) async throws {
        try await DynamicToolProbeFixture.run { fixture in
            let lease = await acquireSubagentStoreSandbox("card-entry")
            defer { lease.release() }
            try await body(fixture)
        }
    }

    private func probeName(_ label: String) -> String {
        "test_card_entry_\(label)_" + UUID().uuidString.prefix(8).lowercased()
    }

    private func withAgent(_ body: (Agent) async throws -> Void) async throws {
        let agent = AgentManager.newCustomAgentRecord(name: "Card Probe \(UUID().uuidString.prefix(6))")
        AgentManager.shared.add(agent)
        ToolPermissionPromptService.resetForTesting()
        defer { ToolPermissionPromptService.resetForTesting() }
        do {
            try await body(agent)
        } catch {
            _ = await AgentManager.shared.delete(id: agent.id)
            throw error
        }
        _ = await AgentManager.shared.delete(id: agent.id)
    }

    private func start(
        _ toolName: String,
        agentId: UUID?,
        probe: CardProbe,
        callId: String? = nil,
        workflowRunId: UUID? = nil,
        remoteReviewer: Bool = false
    ) -> Task<String, Error> {
        ToolPermissionPromptService.$presentationOverrideForTests.withValue(probe.presenter) {
            ChatExecutionContext.$currentAgentId.withValue(agentId) {
                ChatExecutionContext.$currentWorkflowRunId.withValue(workflowRunId) {
                    ChatExecutionContext.$hasRemoteReviewer.withValue(remoteReviewer) {
                        ChatExecutionContext.$currentToolCallId.withValue(callId) {
                            Task { @MainActor in
                                try await ToolRegistry.shared.execute(name: toolName, argumentsJSON: "{}")
                            }
                        }
                    }
                }
            }
        }
    }

    private func settings(_ agent: Agent) -> AgentSettings? {
        AgentManager.shared.agent(for: agent.id)?.settings
    }

    // MARK: Entries

    @Test func alwaysAllowForAgentSavesAnAgentPolicyOnly() async throws {
        try await runFixture { fixture in
            UserDefaults.standard.set(false, forKey: ToolApprovalSettings.autoAllowAllDefaultsKey)
            let tool = CardEntryProbeTool(name: probeName("agent_allow"))
            try fixture.register(tool)
            try await withAgent { agent in
                let probe = CardProbe()
                let first = start(tool.name, agentId: agent.id, probe: probe)
                await probe.waitForPresented(1)
                #expect(
                    ToolPermissionPromptService.presentedAgentChoiceForTesting
                        == .init(agentId: agent.id, agentName: agent.displayName))
                ToolPermissionPromptService.resolveForTesting(id: probe.presented[0].id, outcome: .alwaysAllowForAgent)
                _ = try await first.value
                #expect(tool.executions == 1)
                #expect(settings(agent)?.toolPolicies[tool.name] == .auto)
                #expect(settings(agent)?.toolApprovalMode == .useGlobal)
                #expect(ToolRegistry.shared.configuredPolicy(for: tool.name) == nil)

                let callId = "call-\(UUID().uuidString)"
                _ = try await start(tool.name, agentId: agent.id, probe: probe, callId: callId).value
                #expect(tool.executions == 2)
                #expect(probe.presented.count == 1, "the saved agent policy skips the next card")
                #expect(ToolApprovalAudit.take(callId: callId) == .agentToolPolicy)
            }
        }
    }

    @Test func alwaysAllowForEveryAgentSavesTheGlobalPolicy() async throws {
        try await runFixture { fixture in
            UserDefaults.standard.set(false, forKey: ToolApprovalSettings.autoAllowAllDefaultsKey)
            let tool = CardEntryProbeTool(name: probeName("every_agent"))
            try fixture.register(tool)
            try await withAgent { agent in
                let probe = CardProbe()
                let task = start(tool.name, agentId: agent.id, probe: probe)
                await probe.waitForPresented(1)
                ToolPermissionPromptService.resolveForTesting(id: probe.presented[0].id, outcome: .alwaysAllow)
                _ = try await task.value
                #expect(tool.executions == 1)
                #expect(ToolRegistry.shared.configuredPolicy(for: tool.name) == .auto)
                #expect(settings(agent)?.toolPolicies.isEmpty == true)
            }
        }
    }

    @Test func neverAskForAgentSwitchesTheMode() async throws {
        try await runFixture { fixture in
            UserDefaults.standard.set(false, forKey: ToolApprovalSettings.autoAllowAllDefaultsKey)
            let tool = CardEntryProbeTool(name: probeName("never_ask"))
            let other = CardEntryProbeTool(name: probeName("never_ask_other"))
            try fixture.register(tool)
            try fixture.register(other)
            try await withAgent { agent in
                let probe = CardProbe()
                let task = start(tool.name, agentId: agent.id, probe: probe)
                await probe.waitForPresented(1)
                ToolPermissionPromptService.resolveForTesting(id: probe.presented[0].id, outcome: .neverAskForAgent)
                _ = try await task.value
                #expect(tool.executions == 1)
                #expect(settings(agent)?.toolApprovalMode == .neverAsk)
                #expect(settings(agent)?.toolPolicies.isEmpty == true)

                let callId = "call-\(UUID().uuidString)"
                _ = try await start(other.name, agentId: agent.id, probe: probe, callId: callId).value
                #expect(other.executions == 1)
                #expect(probe.presented.count == 1)
                #expect(ToolApprovalAudit.take(callId: callId) == .agentNeverAsk)
            }
        }
    }

    // MARK: Queued cards

    @Test func queuedCardsTheAnswerCoversSettleSilently() async throws {
        try await runFixture { fixture in
            UserDefaults.standard.set(false, forKey: ToolApprovalSettings.autoAllowAllDefaultsKey)
            let tool = CardEntryProbeTool(name: probeName("queued"))
            try fixture.register(tool)
            try await withAgent { agent in
                let probe = CardProbe()
                let firstId = "call-\(UUID().uuidString)"
                let secondId = "call-\(UUID().uuidString)"
                let first = start(tool.name, agentId: agent.id, probe: probe, callId: firstId)
                await probe.waitForPresented(1)
                let second = start(tool.name, agentId: agent.id, probe: probe, callId: secondId)
                for _ in 0 ..< 200 where ToolPermissionPromptService.queuedPromptCountForTesting < 1 {
                    try? await Task.sleep(for: .milliseconds(5))
                }
                #expect(ToolPermissionPromptService.queuedPromptCountForTesting == 1)

                ToolPermissionPromptService.resolveForTesting(id: probe.presented[0].id, outcome: .neverAskForAgent)
                _ = try await first.value
                _ = try await second.value
                #expect(tool.executions == 2)
                #expect(probe.presented.count == 1, "the queued card never showed")
                #expect(ToolApprovalAudit.take(callId: firstId) == nil, "the first card was answered")
                #expect(ToolApprovalAudit.take(callId: secondId) == .agentNeverAsk)
            }
        }
    }

    @Test func queuedPerCallCardStillShowsAfterNeverAsk() async throws {
        try await runFixture { fixture in
            UserDefaults.standard.set(false, forKey: ToolApprovalSettings.autoAllowAllDefaultsKey)
            let tool = CardEntryProbeTool(name: probeName("queued_ask"))
            let perCall = CardEntryPerCallProbeTool(name: probeName("queued_per_call"))
            try fixture.register(tool)
            try fixture.register(perCall)
            try await withAgent { agent in
                let probe = CardProbe()
                let first = start(tool.name, agentId: agent.id, probe: probe)
                await probe.waitForPresented(1)
                let second = start(perCall.name, agentId: agent.id, probe: probe)
                for _ in 0 ..< 200 where ToolPermissionPromptService.queuedPromptCountForTesting < 1 {
                    try? await Task.sleep(for: .milliseconds(5))
                }
                ToolPermissionPromptService.resolveForTesting(id: probe.presented[0].id, outcome: .neverAskForAgent)
                _ = try await first.value

                await probe.waitForPresented(2)
                #expect(probe.presented.count == 2)
                #expect(probe.presented.last?.toolName == perCall.name)
                #expect(ToolPermissionPromptService.presentedAgentChoiceForTesting == nil)
                ToolPermissionPromptService.resolveForTesting(id: probe.presented[1].id, outcome: .denied)
                await #expect(throws: (any Error).self) { _ = try await second.value }
                #expect(perCall.executions == 0)
            }
        }
    }

    @Test func globalDenyWhileQueuedDeniesWithoutACard() async throws {
        try await runFixture { fixture in
            UserDefaults.standard.set(false, forKey: ToolApprovalSettings.autoAllowAllDefaultsKey)
            let blocker = CardEntryProbeTool(name: probeName("blocker"))
            let tool = CardEntryProbeTool(name: probeName("queued_deny"))
            try fixture.register(blocker)
            try fixture.register(tool)
            try await withAgent { agent in
                let probe = CardProbe()
                let first = start(blocker.name, agentId: agent.id, probe: probe)
                await probe.waitForPresented(1)
                let second = start(tool.name, agentId: agent.id, probe: probe)
                for _ in 0 ..< 200 where ToolPermissionPromptService.queuedPromptCountForTesting < 1 {
                    try? await Task.sleep(for: .milliseconds(5))
                }
                ToolRegistry.shared.setPolicy(.deny, for: tool.name)
                ToolPermissionPromptService.resolveForTesting(id: probe.presented[0].id, outcome: .allowOnce)
                _ = try await first.value
                await #expect(throws: (any Error).self) { _ = try await second.value }
                #expect(tool.executions == 0)
                #expect(probe.presented.count == 1)
            }
        }
    }

    // MARK: Where the entries are not offered

    @Test func noAgentEntriesOutsideACustomAgentsOwnRun() async throws {
        try await runFixture { fixture in
            UserDefaults.standard.set(false, forKey: ToolApprovalSettings.autoAllowAllDefaultsKey)
            let tool = CardEntryProbeTool(name: probeName("not_offered"))
            let perCall = CardEntryPerCallProbeTool(name: probeName("not_offered_per_call"))
            try fixture.register(tool)
            try fixture.register(perCall)
            try await withAgent { agent in
                let cases: [(label: String, tool: String, agentId: UUID?, workflowRunId: UUID?, remote: Bool)] = [
                    ("built-in agent", tool.name, Agent.defaultId, nil, false),
                    ("no agent", tool.name, nil, nil, false),
                    ("workflow run", tool.name, agent.id, UUID(), false),
                    ("per-call tool", perCall.name, agent.id, nil, false),
                    ("paired phone", tool.name, agent.id, nil, true),
                ]
                for entry in cases {
                    let probe = CardProbe()
                    let task = start(
                        entry.tool, agentId: entry.agentId, probe: probe,
                        workflowRunId: entry.workflowRunId, remoteReviewer: entry.remote)
                    await probe.waitForPresented(1)
                    #expect(probe.presented.count == 1, "\(entry.label): the card shows")
                    #expect(
                        ToolPermissionPromptService.presentedAgentChoiceForTesting == nil,
                        "\(entry.label): no agent entries")
                    if let id = probe.presented.first?.id {
                        ToolPermissionPromptService.resolveForTesting(id: id, outcome: .denied)
                    }
                    await #expect(throws: (any Error).self) { _ = try await task.value }
                }
                #expect(tool.executions == 0)
                #expect(perCall.executions == 0)
                #expect(settings(agent)?.toolApprovalMode == .useGlobal)
            }
        }
    }
}
