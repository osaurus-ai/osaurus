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
