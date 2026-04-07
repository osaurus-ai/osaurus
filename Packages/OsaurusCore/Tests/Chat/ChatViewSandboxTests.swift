import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct ChatViewSandboxTests {
    @Test
    func buildToolSpecs_sandboxDisabledExcludesBuiltInSandboxTools() {
        let session = ChatSession()

        withRegisteredSandboxBuiltins {
            let specs = session.buildToolSpecs(executionMode: .none)

            #expect(specs.contains(where: { $0.function.name == "sandbox_exec" }) == false)
            #expect(specs.contains(where: { $0.function.name == "sandbox_read_file" }) == false)
        }
    }

    @Test
    func buildToolSpecs_sandboxEnabledIncludesBuiltIns() {
        withRegisteredSandboxBuiltins {
            let session = ChatSession()
            let specs = session.buildToolSpecs(executionMode: .sandbox)

            #expect(specs.contains(where: { $0.function.name == "capabilities_search" }))
            #expect(specs.contains(where: { $0.function.name == "capabilities_load" }))
        }
    }

    @Test
    func buildSystemPrompt_includesSandboxContextOnlyWhenExpected() async {
        let session = ChatSession()

        let (standardPrompt, _) = await session.buildChatSystemPrompt(
            agentId: Agent.defaultId,
            executionMode: .none
        )
        let (sandboxPrompt, _) = await session.buildChatSystemPrompt(
            agentId: Agent.defaultId,
            executionMode: .sandbox
        )

        #expect(standardPrompt.contains(SystemPromptTemplates.sandboxSectionHeading) == false)
        #expect(sandboxPrompt.contains(SystemPromptTemplates.sandboxSectionHeading))
        #expect(sandboxPrompt.contains("sandbox_run_script"))
    }

    @Test
    func estimatedContextBreakdown_includesSandboxPromptAndToolsWhenEnabled() {
        let manager = AgentManager.shared
        let originalActiveAgentId = manager.activeAgentId
        let inactiveAgent = Agent(name: "Chat Estimate Off")
        let sandboxAgent = Agent(
            name: "Chat Estimate On",
            autonomousExec: AutonomousExecConfig(enabled: true)
        )
        manager.add(inactiveAgent)
        manager.add(sandboxAgent)
        defer {
            manager.setActiveAgent(originalActiveAgentId)
            Task {
                _ = await manager.delete(id: inactiveAgent.id)
                _ = await manager.delete(id: sandboxAgent.id)
            }
        }

        let inactiveSession = ChatSession()
        inactiveSession.agentId = inactiveAgent.id
        let sandboxSession = ChatSession()
        sandboxSession.agentId = sandboxAgent.id

        withRegisteredSandboxBuiltins {
            let inactiveBreakdown = inactiveSession.estimatedContextBreakdown
            let sandboxBreakdown = sandboxSession.estimatedContextBreakdown

            #expect(sandboxBreakdown.systemPrompt > inactiveBreakdown.systemPrompt)
            #expect(sandboxBreakdown.tools > inactiveBreakdown.tools)
            #expect(sandboxBreakdown.tools >= ToolRegistry.shared.estimatedTokens(for: "sandbox_exec"))
        }
    }

    @Test
    func alwaysLoadedSpecs_includesCapabilityTools() {
        let specs = ToolRegistry.shared.alwaysLoadedSpecs(mode: .none)

        #expect(specs.contains(where: { $0.function.name == "capabilities_search" }))
        #expect(specs.contains(where: { $0.function.name == "capabilities_load" }))
        #expect(specs.contains(where: { $0.function.name == "methods_save" }))
        #expect(specs.contains(where: { $0.function.name == "methods_report" }))
    }

    @Test
    func prepareChatExecutionMode_usesSessionAgentInsteadOfActiveAgent() async {
        let manager = AgentManager.shared
        let registrar = SandboxToolRegistrar.shared
        let originalActiveAgentId = manager.activeAgentId
        let originalStatus = SandboxManager.State.shared.status
        let originalProvisionOverride = registrar.provisionAgentOverride

        let inactiveAgent = Agent(name: "Chat Sandbox Off")
        let sandboxAgent = Agent(
            name: "Chat Sandbox On",
            autonomousExec: AutonomousExecConfig(enabled: true)
        )
        manager.add(inactiveAgent)
        manager.add(sandboxAgent)
        manager.setActiveAgent(inactiveAgent.id)

        SandboxManager.State.shared.status = .running
        registrar.provisionAgentOverride = { _ in }

        let session = ChatSession()
        let inactiveMode = await session.prepareChatExecutionMode(agentId: inactiveAgent.id)
        let sandboxMode = await session.prepareChatExecutionMode(agentId: sandboxAgent.id)

        #expect(inactiveMode.usesSandboxTools == false)
        #expect(sandboxMode.usesSandboxTools)

        let specs = session.buildToolSpecs(executionMode: sandboxMode)
        #expect(specs.contains(where: { $0.function.name == "sandbox_exec" }))

        ToolRegistry.shared.unregisterAllSandboxTools()
        SandboxManager.State.shared.status = originalStatus
        registrar.provisionAgentOverride = originalProvisionOverride
        manager.setActiveAgent(originalActiveAgentId)
        _ = await manager.delete(id: inactiveAgent.id)
        _ = await manager.delete(id: sandboxAgent.id)
    }

    @Test
    func workSessionEstimate_includesSandboxPromptAndToolsWhenEnabled() {
        let manager = AgentManager.shared
        let originalActiveAgentId = manager.activeAgentId
        let inactiveAgent = Agent(name: "Work Estimate Off")
        let sandboxAgent = Agent(
            name: "Work Estimate On",
            autonomousExec: AutonomousExecConfig(enabled: true)
        )
        manager.add(inactiveAgent)
        manager.add(sandboxAgent)
        defer {
            manager.setActiveAgent(originalActiveAgentId)
            Task {
                _ = await manager.delete(id: inactiveAgent.id)
                _ = await manager.delete(id: sandboxAgent.id)
            }
        }

        let issue = Issue(taskId: "task-1", title: "Verify sandbox budget")
        let inactiveSession = WorkSession(agentId: inactiveAgent.id)
        let sandboxSession = WorkSession(agentId: sandboxAgent.id)

        withRegisteredSandboxBuiltins {
            let inactiveBreakdown = inactiveSession.estimateContextBreakdown(for: issue)
            let sandboxBreakdown = sandboxSession.estimateContextBreakdown(for: issue)
            let sandboxTools = ToolRegistry.shared.alwaysLoadedSpecs(mode: .sandbox)

            #expect(sandboxBreakdown.systemPrompt > inactiveBreakdown.systemPrompt)
            #expect(sandboxBreakdown.tools > inactiveBreakdown.tools)
            #expect(sandboxBreakdown.tools == ToolRegistry.shared.totalEstimatedTokens(for: sandboxTools))
        }
    }
}

@MainActor
private func withRegisteredSandboxBuiltins(_ body: () -> Void) {
    BuiltinSandboxTools.register(
        agentId: "chat-sandbox-test",
        agentName: "chat-sandbox-test",
        config: AutonomousExecConfig(enabled: true)
    )
    defer {
        ToolRegistry.shared.unregisterAllSandboxTools()
    }
    body()
}
