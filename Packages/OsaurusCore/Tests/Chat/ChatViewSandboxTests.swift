import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct ChatViewSandboxTests {
    @Test
    func buildToolSpecs_sandboxDisabledExcludesBuiltInSandboxTools() async {
        await withRegisteredSandboxBuiltins {
            let specs = ToolRegistry.shared.alwaysLoadedSpecs(mode: .none)

            #expect(specs.contains(where: { $0.function.name == "sandbox_exec" }) == false)
            #expect(specs.contains(where: { $0.function.name == "sandbox_read_file" }) == false)
        }
    }

    @Test
    func buildToolSpecs_sandboxEnabledIncludesBuiltIns() async {
        await withRegisteredSandboxBuiltins {
            let specs = ToolRegistry.shared.alwaysLoadedSpecs(mode: .sandbox)

            #expect(specs.contains(where: { $0.function.name == "capabilities_search" }))
            #expect(specs.contains(where: { $0.function.name == "capabilities_load" }))
        }
    }

    @Test
    func buildSystemPrompt_includesSandboxContextOnlyWhenExpected() async {
        let standardCtx = await SystemPromptComposer.composeChatContext(
            agentId: Agent.defaultId,
            executionMode: .none
        )
        let sandboxCtx = await SystemPromptComposer.composeChatContext(
            agentId: Agent.defaultId,
            executionMode: .sandbox
        )
        let standardPrompt = standardCtx.prompt
        let sandboxPrompt = sandboxCtx.prompt

        #expect(standardPrompt.contains(SystemPromptTemplates.sandboxSectionHeading) == false)
        #expect(sandboxPrompt.contains(SystemPromptTemplates.sandboxSectionHeading))
        #expect(sandboxPrompt.contains("sandbox_run_script"))
    }

    @Test
    func estimatedContextBreakdown_includesSandboxPromptAndToolsWhenEnabled() async {
        await SandboxTestLock.shared.run {
            let manager = AgentManager.shared
            let originalActiveAgentId = manager.activeAgentId
            let inactiveAgent = Agent(
                name: "Chat Estimate Off",
                agentAddress: "test-chat-estimate-off"
            )
            let sandboxAgent = Agent(
                name: "Chat Estimate On",
                agentAddress: "test-chat-estimate-on",
                autonomousExec: AutonomousExecConfig(enabled: true)
            )
            manager.add(inactiveAgent)
            manager.add(sandboxAgent)

            let inactiveSession = ChatSession()
            inactiveSession.agentId = inactiveAgent.id
            let sandboxSession = ChatSession()
            sandboxSession.agentId = sandboxAgent.id

            BuiltinSandboxTools.register(
                agentId: sandboxAgent.id.uuidString,
                agentName: sandboxAgent.name,
                config: AutonomousExecConfig(enabled: true)
            )

            let inactiveBreakdown = inactiveSession.estimatedContextBreakdown
            let sandboxBreakdown = sandboxSession.estimatedContextBreakdown

            let inactiveContextTokens = inactiveBreakdown.context.reduce(0) { $0 + $1.tokens }
            let sandboxContextTokens = sandboxBreakdown.context.reduce(0) { $0 + $1.tokens }
            #expect(sandboxContextTokens > inactiveContextTokens)

            let sandboxToolTokens = sandboxBreakdown.context.first { $0.id == "tools" }?.tokens ?? 0
            let inactiveToolTokens = inactiveBreakdown.context.first { $0.id == "tools" }?.tokens ?? 0
            #expect(sandboxToolTokens > inactiveToolTokens)
            #expect(sandboxToolTokens >= ToolRegistry.shared.estimatedTokens(for: "sandbox_exec"))

            ToolRegistry.shared.unregisterAllSandboxTools()
            manager.setActiveAgent(originalActiveAgentId)
            _ = await manager.delete(id: inactiveAgent.id)
            _ = await manager.delete(id: sandboxAgent.id)
        }
    }

    @Test
    func alwaysLoadedSpecs_includesCapabilityTools() {
        let specs = ToolRegistry.shared.alwaysLoadedSpecs(mode: .none)

        #expect(specs.contains(where: { $0.function.name == "capabilities_search" }))
        #expect(specs.contains(where: { $0.function.name == "capabilities_load" }))
    }

    @Test
    func alwaysLoadedSpecs_includesAgentLoopTools() {
        let specs = ToolRegistry.shared.alwaysLoadedSpecs(mode: .none)

        #expect(specs.contains(where: { $0.function.name == "todo" }))
        #expect(specs.contains(where: { $0.function.name == "complete" }))
        #expect(specs.contains(where: { $0.function.name == "clarify" }))
    }

    @Test
    func alwaysLoadedSpecs_includesShareArtifactGlobally() {
        let specs = ToolRegistry.shared.alwaysLoadedSpecs(mode: .none)

        #expect(specs.contains(where: { $0.function.name == "share_artifact" }))
    }

    @Test
    func alwaysLoadedSpecs_includesUnifiedSearchMemory() {
        let specs = ToolRegistry.shared.alwaysLoadedSpecs(mode: .none)

        #expect(specs.contains(where: { $0.function.name == "search_memory" }))
        #expect(!specs.contains(where: { $0.function.name == "search_working_memory" }))
        #expect(!specs.contains(where: { $0.function.name == "search_conversations" }))
        #expect(!specs.contains(where: { $0.function.name == "search_summaries" }))
        #expect(!specs.contains(where: { $0.function.name == "search_graph" }))
    }

    @Test
    func prepareChatExecutionMode_usesSessionAgentInsteadOfActiveAgent() async {
        await SandboxTestLock.shared.run {
            let manager = AgentManager.shared
            let registrar = SandboxToolRegistrar.shared
            let originalActiveAgentId = manager.activeAgentId
            let originalStatus = SandboxManager.State.shared.status
            let originalProvisionOverride = registrar.provisionAgentOverride

            let inactiveAgent = Agent(
                name: "Chat Sandbox Off",
                agentAddress: "test-chat-sandbox-off"
            )
            let sandboxAgent = Agent(
                name: "Chat Sandbox On",
                agentAddress: "test-chat-sandbox-on",
                autonomousExec: AutonomousExecConfig(enabled: true)
            )
            manager.add(inactiveAgent)
            manager.add(sandboxAgent)
            manager.setActiveAgent(inactiveAgent.id)

            SandboxManager.State.shared.status = .running
            registrar.provisionAgentOverride = { _ in }
            BuiltinSandboxTools.register(
                agentId: sandboxAgent.id.uuidString,
                agentName: sandboxAgent.name,
                config: AutonomousExecConfig(enabled: true)
            )

            let session = ChatSession()
            let inactiveMode = await session.prepareChatExecutionMode(agentId: inactiveAgent.id)
            let sandboxMode = await session.prepareChatExecutionMode(agentId: sandboxAgent.id)

            #expect(inactiveMode.usesSandboxTools == false)
            #expect(sandboxMode.usesSandboxTools)

            let specs = ToolRegistry.shared.alwaysLoadedSpecs(mode: sandboxMode)
            #expect(specs.contains(where: { $0.function.name == "sandbox_exec" }))

            ToolRegistry.shared.unregisterAllSandboxTools()
            SandboxManager.State.shared.status = originalStatus
            registrar.provisionAgentOverride = originalProvisionOverride
            manager.setActiveAgent(originalActiveAgentId)
            _ = await manager.delete(id: inactiveAgent.id)
            _ = await manager.delete(id: sandboxAgent.id)
        }
    }

    // Chat session budget estimation is covered indirectly via
    // SystemPromptComposer + ContextBudgetManager tests.
}

@MainActor
private func withRegisteredSandboxBuiltins(_ body: @MainActor @Sendable () -> Void) async {
    await SandboxTestLock.shared.run {
        BuiltinSandboxTools.register(
            agentId: "chat-sandbox-test",
            agentName: "chat-sandbox-test",
            config: AutonomousExecConfig(enabled: true)
        )
        body()
        ToolRegistry.shared.unregisterAllSandboxTools()
    }
}
