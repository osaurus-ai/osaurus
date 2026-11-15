//
//  OrchestratorPromptSurfaceTests.swift
//
//  The Orchestrator's composed prompt names only tools its schema carries,
//  with no folder, with a folder attached, and in sandbox mode. A section
//  that points at an absent tool sends a small model into `tool_not_found`.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct OrchestratorPromptSurfaceTests {

    private static let workerOnlyMentions = [
        "`todo(", "`complete(", "`share_artifact(", "Todo is advisory", "`file_read`", "`file_write`",
        "shell_run", "sandbox_install",
    ]

    private func compose(_ mode: ExecutionMode, model: String) async -> ComposedContext {
        ConfigurationDomainBootstrap.registerBuiltIns()
        return await DynamicCatalogTestLock.shared.run {
            await SystemPromptComposer.composeChatContext(
                agentId: Agent.defaultId, executionMode: mode, model: model)
        }
    }

    private func expectNoWorkerTools(_ ctx: ComposedContext, _ label: String) {
        let tools = Set(ctx.tools.map(\.function.name))
        #expect(tools.isDisjoint(with: ToolRegistry.coreWorkspaceToolNames), "\(label): \(tools)")
        for mention in Self.workerOnlyMentions {
            #expect(!ctx.prompt.contains(mention), "\(label) prompt mentions \(mention)")
        }
    }

    @Test(arguments: ["qwen3-8b", "anthropic/claude-x"])
    func noFolder_agentLoopKeepsOnlyClarify(model: String) async {
        let ctx = await compose(.none, model: model)
        let section = ctx.manifest.sections.first { $0.id == "agentLoopGuidance" }
        #expect(section?.content.contains("`clarify(") == true)
        expectNoWorkerTools(ctx, "none/\(model)")
    }

    @Test(arguments: ["qwen3-8b", "anthropic/claude-x"])
    func folderAttached_hasNoWorkingDirectoryFraming(model: String) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("orchestrator-folder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = FolderContext(
            rootPath: root, projectType: .swift, tree: "./\nREADME.md", manifest: nil, gitStatus: nil,
            isGitRepo: false)
        FolderToolManager.shared.ensureFolderToolsRegistered()

        let ctx = await compose(.hostFolder(folder), model: model)
        #expect(!ctx.manifest.sections.contains { $0.id == "folderContext" })
        expectNoWorkerTools(ctx, "folder/\(model)")
    }

    // MARK: - Team section

    @Test(arguments: ["qwen3-8b", "anthropic/claude-x"])
    func teamSection_matchesTheCatalogWhenRunWorkflowIsExposed(model: String) async {
        let ctx = await compose(.none, model: model)
        let tools = Set(ctx.tools.map(\.function.name))
        #expect(tools.contains(RunWorkflowTool.toolName), "built-in workers keep run_workflow exposed")
        let section = ctx.manifest.sections.first { $0.id == "orchestratorTeam" }
        #expect(section?.content == SystemPromptTemplates.orchestratorTeam(RoutableWorkflowCatalog.team()))
        for worker in BuiltInWorker.allCases where RoutableWorkflowCatalog.names().contains(worker.displayName) {
            #expect(section?.content.contains("**\(worker.displayName)**") == true)
        }
        let advertised = DefaultAgentSystemPromptBuilder.advertisedToolNames(
            in: section?.content ?? "",
            known: Set(ToolRegistry.shared.registeredToolNames()).union(ToolRegistry.orchestratorRoutingToolNames))
        #expect(advertised.isSubset(of: tools), "Team section names \(advertised.subtracting(tools))")
    }

    @Test
    func teamSection_isAbsentWithToolsOff_andForOtherAgents() async {
        ConfigurationDomainBootstrap.registerBuiltIns()
        let toolsOff = await DynamicCatalogTestLock.shared.run {
            await SystemPromptComposer.composeChatContext(
                agentId: Agent.defaultId, executionMode: .none, model: "qwen3-8b", toolsDisabled: true)
        }
        #expect(!toolsOff.manifest.sections.contains { $0.id == "orchestratorTeam" })
        let architect = await DynamicCatalogTestLock.shared.run {
            await SystemPromptComposer.composeChatContext(
                agentId: Agent.architectId, executionMode: .none, model: "qwen3-8b")
        }
        #expect(!architect.manifest.sections.contains { $0.id == "orchestratorTeam" })
    }

    private static func doc(_ name: String, _ summary: String = "", kind: RoutableWorkflowDoc.Kind = .wrapper)
        -> RoutableWorkflowDoc
    {
        RoutableWorkflowDoc(id: UUID().uuidString, name: name, summary: summary, kind: kind)
    }

    @Test
    func teamTemplate_listsAgentsFirst_andSaysWhenTheUserHasNone() throws {
        #expect(SystemPromptTemplates.orchestratorTeam(OrchestratorTeam()) == nil)

        let withAgents = try #require(
            SystemPromptTemplates.orchestratorTeam(
                OrchestratorTeam(
                    agents: [Self.doc("Planner", "Reads and adds Calendar events and Reminders.\nSecond line.")],
                    workers: [Self.doc("Research", "Searches the web.")],
                    workflows: [Self.doc("Morning Brief", "Your day at a glance.", kind: .installed)])))
        let planner = try #require(withAgents.range(of: "**Planner** — Reads and adds Calendar events and Reminders."))
        let research = try #require(withAgents.range(of: "**Research**"))
        let brief = try #require(withAgents.range(of: "**Morning Brief**"))
        #expect(planner.lowerBound < research.lowerBound && research.lowerBound < brief.lowerBound)
        #expect(!withAgents.contains("Second line."))
        #expect(!withAgents.contains("no agents of their own"))

        let workersOnly = try #require(
            SystemPromptTemplates.orchestratorTeam(OrchestratorTeam(workers: [Self.doc("Research")])))
        #expect(workersOnly.contains("no agents of their own"))
        #expect(workersOnly.contains("Create starter agents"))
    }

    @Test
    func teamTemplate_capsTheListAndPointsAtStatus() throws {
        let limit = SystemPromptTemplates.orchestratorTeamLimit
        let agents = (0 ..< limit + 3).map { Self.doc("Agent \($0)", String(repeating: "x", count: 400)) }
        let rendered = try #require(SystemPromptTemplates.orchestratorTeam(OrchestratorTeam(agents: agents)))
        #expect(rendered.contains("**Agent \(limit - 1)**"))
        #expect(!rendered.contains("**Agent \(limit)**"))
        #expect(rendered.contains("…and 3 more; `status` lists them all."))
        #expect(!rendered.contains(String(repeating: "x", count: SystemPromptTemplates.orchestratorTeamSummaryLimit)))
    }

    @Test
    func sandboxMode_hasNoSandboxFraming() async {
        await SandboxTestLock.shared.run {
            BuiltinSandboxTools.register(
                agentId: Agent.defaultId.uuidString, agentName: "Osaurus",
                config: AutonomousExecConfig(enabled: true))
            let ctx = await compose(.sandbox, model: "qwen3-8b")
            #expect(!ctx.manifest.sections.contains { $0.id == "sandbox" })
            expectNoWorkerTools(ctx, "sandbox")
            ToolRegistry.shared.unregisterAllSandboxTools()
        }
    }
}
