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
            let specs = ToolRegistry.shared.alwaysLoadedSpecs(mode: .sandbox(hostRead: nil))

            #expect(specs.contains(where: { $0.function.name == "capabilities_discover" }))
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
            executionMode: .sandbox(hostRead: nil)
        )
        let standardPrompt = standardCtx.prompt
        let sandboxPrompt = sandboxCtx.prompt

        #expect(standardPrompt.contains(SystemPromptTemplates.sandboxSectionHeading) == false)
        #expect(sandboxPrompt.contains(SystemPromptTemplates.sandboxSectionHeading))
        // Pinning a tool name keeps the sandbox section honest.
        #expect(sandboxPrompt.contains("sandbox_exec"))
        // Plain sandbox (no host folder) must NOT emit the combined
        // read-only workspace section or the unified Files block.
        #expect(sandboxPrompt.contains("## Host workspace (read-only)") == false)
        #expect(sandboxPrompt.contains("## Files") == false)
        // Plain sandbox keeps the sandbox read tools in its dispatch guide.
        #expect(sandboxPrompt.contains("sandbox_read_file"))
    }

    /// The sandbox section must state the agent's ABSOLUTE home (so the
    /// model stops guessing `/root` for `cwd`) and tell it to default
    /// there. Pins both the prompt env-block and the threaded home path.
    @Test
    func buildSystemPrompt_sandboxStatesAbsoluteHomeAndCwdDefault() async {
        let sandboxCtx = await SystemPromptComposer.composeChatContext(
            agentId: Agent.defaultId,
            executionMode: .sandbox(hostRead: nil)
        )
        let prompt = sandboxCtx.prompt

        let expectedHome = OsaurusPaths.inContainerAgentHome(
            SandboxAgentProvisioner.linuxName(for: Agent.defaultId.uuidString)
        )
        #expect(expectedHome.isEmpty == false)
        // The absolute home path is named verbatim in the env block...
        #expect(prompt.contains(expectedHome))
        // ...with the "default there / omit cwd" guidance.
        #expect(prompt.contains("default"))
        #expect(prompt.contains("`cwd`"))
    }

    @Test
    func buildSystemPrompt_combinedMode_emitsSandboxAndReadOnlyWorkspaceSections() async {
        let folder = FolderContext(
            rootPath: URL(fileURLWithPath: "/tmp/osaurus-combined-prompt-\(UUID().uuidString)"),
            projectType: .swift,
            tree: "./\nREADME.md\nSources/App.swift",
            manifest: nil,
            gitStatus: nil,
            isGitRepo: false,
            contextFiles: nil
        )
        let combinedCtx = await SystemPromptComposer.composeChatContext(
            agentId: Agent.defaultId,
            executionMode: .sandbox(hostRead: folder)
        )
        let prompt = combinedCtx.prompt

        // Sandbox framing is present (exec is sandbox-only)...
        #expect(prompt.contains(SystemPromptTemplates.sandboxSectionHeading))
        // ...alongside the read-only host workspace section and the
        // unified Files block that routes one file family by path so the
        // model never picks between `file_*` and `sandbox_*` read tools.
        #expect(prompt.contains("## Host workspace (read-only)"))
        #expect(prompt.contains("## Files"))
        // The unified Files block must name the real exec tools, never the
        // (hidden in this mode) host `shell_run`.
        #expect(prompt.contains("sandbox_exec"))
        #expect(prompt.contains("shell_run") == false)
        // Combined mode hides the redundant sandbox read tools; the
        // dispatch guide steers to the unified `file_*` family instead.
        // `file_read` reads files AND lists directories, so there is no
        // separate `file_tree`.
        #expect(prompt.contains("file_read"))
        #expect(prompt.contains("file_tree") == false)
    }

    @Test
    func estimatedContextBreakdown_includesSandboxPromptAndToolsWhenEnabled() async {
        await SandboxTestLock.runWithStoragePaths {
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

        #expect(specs.contains(where: { $0.function.name == "capabilities_discover" }))
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
        await SandboxTestLock.runWithStoragePaths {
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

    /// Toggling sandbox on/off for the current agent must re-price the
    /// estimate on the SAME session — not just across two freshly-built
    /// sessions. This pins the cache-invalidation contract the debounced
    /// budget-input pipeline relies on: after a resync the breakdown grows
    /// when sandbox is enabled and shrinks back to the original total when
    /// it is disabled. `invalidateTokenCache()` stands in for the
    /// `.agentUpdated` / `SandboxManager.State` signals the pipeline
    /// debounces in the running app.
    @Test
    func estimatedContextBreakdown_resyncsAcrossSandboxToggleOnSameSession() async {
        await SandboxTestLock.runWithStoragePaths {
            let manager = AgentManager.shared
            let originalActiveAgentId = manager.activeAgentId
            var agent = Agent(
                name: "Resync Sandbox",
                agentAddress: "test-resync-sandbox-\(UUID().uuidString)"
            )
            manager.add(agent)

            let session = ChatSession()
            session.agentId = agent.id

            // Baseline: sandbox off. Reading populates the preview cache.
            let offTotal = session.estimatedContextBreakdown.total
            #expect(offTotal > 0)

            // Enable sandbox on the same agent + register the built-ins,
            // then resync. Direct mutation avoids the provisioning side
            // effects of `updateAutonomousExec`.
            agent.autonomousExec = AutonomousExecConfig(enabled: true)
            manager.update(agent)
            BuiltinSandboxTools.register(
                agentId: agent.id.uuidString,
                agentName: agent.name,
                config: AutonomousExecConfig(enabled: true)
            )
            session.invalidateTokenCache()
            let onTotal = session.estimatedContextBreakdown.total
            #expect(onTotal > offTotal)

            // Disable again → resync must shrink back to the original total.
            agent.autonomousExec = nil
            manager.update(agent)
            ToolRegistry.shared.unregisterAllSandboxTools()
            session.invalidateTokenCache()
            let backTotal = session.estimatedContextBreakdown.total
            #expect(backTotal < onTotal)
            #expect(backTotal == offTotal)

            manager.setActiveAgent(originalActiveAgentId)
            _ = await manager.delete(id: agent.id)
        }
    }

    /// A per-agent feature toggle (`render_chart`) must change the `Tools`
    /// row once the budget cache is invalidated — and must NOT change it
    /// before, proving the preview is genuinely cached (so typing doesn't
    /// recompose) yet never goes stale across a resync.
    @Test
    func estimatedContextBreakdown_resyncsToolTokensWhenFeatureToggled() async {
        await SandboxTestLock.runWithStoragePaths {
            let manager = AgentManager.shared
            let originalActiveAgentId = manager.activeAgentId
            var agent = Agent(
                name: "Resync Feature",
                agentAddress: "test-resync-feature-\(UUID().uuidString)",
                toolSelectionMode: .auto
            )
            manager.add(agent)

            let session = ChatSession()
            session.agentId = agent.id

            @MainActor func toolTokens() -> Int {
                session.estimatedContextBreakdown.context.first { $0.id == "tools" }?.tokens ?? 0
            }

            let baseTools = toolTokens()
            #expect(baseTools > 0)

            // Enable render_chart. Without an invalidation signal the cached
            // preview still reports the pre-toggle tool tokens.
            agent.settings.renderChartEnabled = true
            manager.update(agent)
            #expect(toolTokens() == baseTools)

            // The resync re-prices the schema: render_chart now survives the
            // auto-mode strip, so the Tools row grows.
            session.invalidateTokenCache()
            #expect(toolTokens() > baseTools)

            manager.setActiveAgent(originalActiveAgentId)
            _ = await manager.delete(id: agent.id)
        }
    }

    /// Editing the agent's autonomous-exec config after a send must update
    /// the Context Budget popover. Before the fix, the authoritative
    /// last-send context (`cachedContext`) stayed pinned and the
    /// `.agentUpdated`-driven resync only refreshed the (unused) preview, so
    /// toggling e.g. background processes never moved the number until the
    /// next send.
    @Test
    func estimatedContextBreakdown_updatesWhenAutonomousConfigEditedAfterSend() async {
        await SandboxTestLock.runWithStoragePaths {
            let manager = AgentManager.shared
            let originalActiveAgentId = manager.activeAgentId
            var agent = Agent(
                name: "Budget Edit",
                agentAddress: "test-budget-edit-\(UUID().uuidString)",
                autonomousExec: AutonomousExecConfig(enabled: true)
            )
            manager.add(agent)
            manager.setActiveAgent(agent.id)

            let session = ChatSession()
            session.agentId = agent.id

            // Prime the preview cache (background OFF) and stand in for a
            // completed send by seeding a composed context as authoritative.
            session.resyncBudgetEstimateForTests()
            let sentContext = await SystemPromptComposer.composeChatContext(
                agentId: agent.id,
                executionMode: .sandbox(hostRead: nil),
                query: "do some work"
            )
            session.seedSendContextForTests(sentContext)
            let beforeEdit = session.estimatedContextBreakdown.total
            #expect(beforeEdit > 0)

            // A benign resync (no config change) must NOT drop the
            // authoritative send context.
            #expect(session.resyncBudgetEstimateForTests() == false)
            #expect(session.estimatedContextBreakdown.total == beforeEdit)

            // Edit the agent: enable background processes. The cached send
            // context is now stale for the next send.
            agent.autonomousExec = AutonomousExecConfig(
                enabled: true,
                backgroundProcessEnabled: true
            )
            manager.update(agent)

            // The resync the running app drives on `.agentUpdated` must now
            // drop the stale send context and re-price from the edited config.
            #expect(session.resyncBudgetEstimateForTests() == true)
            #expect(session.estimatedContextBreakdown.total != beforeEdit)

            manager.setActiveAgent(originalActiveAgentId)
            _ = await manager.delete(id: agent.id)
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
