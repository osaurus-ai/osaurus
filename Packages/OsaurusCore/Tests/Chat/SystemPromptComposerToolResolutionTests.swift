//
//  SystemPromptComposerToolResolutionTests.swift
//  osaurusTests
//
//  Verifies the contract of `SystemPromptComposer.resolveTools` across the
//  matrix of (toolMode: auto|manual) x (executionMode: none|sandbox) x
//  (manualNames empty|set). These tests pin down the user-facing spec:
//   - Auto mode = always-loaded built-ins + preflight additions.
//   - Manual mode (pragmatic) = always-loaded built-ins + sandbox/folder
//     runtime when active + user-picked names. Same shape as auto, minus
//     the LLM-driven preflight specs (manual mode is opt-in).
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct SystemPromptComposerToolResolutionTests {

    // MARK: - Helpers

    private func withSandboxAgent(
        autonomous: Bool,
        manualToolNames: [String]? = nil,
        body: @MainActor @Sendable (UUID) async -> Void
    ) async {
        await SandboxTestLock.runWithStoragePaths {
            let manager = AgentManager.shared
            let agent: Agent
            if let names = manualToolNames {
                agent = Agent(
                    name: "ToolResolutionTestAgent-\(UUID().uuidString.prefix(6))",
                    agentAddress: "test-tool-resolution-\(UUID().uuidString)",
                    autonomousExec: autonomous ? AutonomousExecConfig(enabled: true) : nil,
                    toolSelectionMode: .manual,
                    manualToolNames: names
                )
            } else {
                agent = Agent(
                    name: "ToolResolutionTestAgent-\(UUID().uuidString.prefix(6))",
                    agentAddress: "test-tool-resolution-\(UUID().uuidString)",
                    autonomousExec: autonomous ? AutonomousExecConfig(enabled: true) : nil
                )
            }
            manager.add(agent)
            await body(agent.id)
            _ = await manager.delete(id: agent.id)
        }
    }

    private func withRegisteredSandboxBuiltins(_ body: @MainActor @Sendable () -> Void) {
        BuiltinSandboxTools.register(
            agentId: "tool-resolution-test",
            agentName: "tool-resolution-test",
            config: AutonomousExecConfig(enabled: true)
        )
        body()
        ToolRegistry.shared.unregisterAllSandboxTools()
    }

    private func withRegisteredFolderTools(_ body: @MainActor @Sendable (FolderContext) -> Void) {
        let folder = FolderContext(
            rootPath: URL(fileURLWithPath: "/tmp/osaurus-tool-resolution-\(UUID().uuidString)"),
            projectType: .swift,
            tree: "./\nREADME.md\nSources/App.swift",
            manifest: nil,
            gitStatus: nil,
            isGitRepo: false
        )
        FolderToolManager.shared.registerFolderTools(for: folder)
        body(folder)
        FolderToolManager.shared.unregisterFolderTools()
    }

    // MARK: - Auto mode

    @Test
    func autoMode_includesAlwaysLoadedAndPreflightAdditions() async {
        await withSandboxAgent(autonomous: false) { agentId in
            let preflight = PreflightResult(toolSpecs: [], items: [])
            let tools = SystemPromptComposer.resolveTools(
                agentId: agentId,
                executionMode: .none,
                preflight: preflight
            )
            // Built-ins like capabilities_search must be present in auto mode.
            #expect(tools.contains { $0.function.name == "capabilities_search" })
        }
    }

    // MARK: - Manual mode (pragmatic)

    @Test
    func manualMode_includesAlwaysLoadedBuiltinsAndUserPicks() async {
        await withSandboxAgent(autonomous: false, manualToolNames: ["render_chart"]) { agentId in
            let tools = SystemPromptComposer.resolveTools(
                agentId: agentId,
                executionMode: .none
            )
            let names = Set(tools.map { $0.function.name })
            // User pick is present.
            #expect(names.contains("render_chart"))
            // Pragmatic manual mode keeps the always-loaded built-ins so
            // the agent loop, share_artifact, and capability discovery
            // remain usable without the user having to re-pick them.
            #expect(names.contains("todo"))
            #expect(names.contains("complete"))
            #expect(names.contains("clarify"))
            #expect(names.contains("share_artifact"))
            #expect(names.contains("capabilities_search"))
            #expect(names.contains("capabilities_load"))
            #expect(names.contains("search_memory"))
        }
    }

    @Test
    func manualMode_includesSandboxBuiltinsWhenSandboxActive() async {
        await withSandboxAgent(autonomous: true, manualToolNames: ["render_chart"]) { agentId in
            withRegisteredSandboxBuiltins {
                let tools = SystemPromptComposer.resolveTools(
                    agentId: agentId,
                    executionMode: .sandbox(hostRead: nil)
                )
                let names = Set(tools.map { $0.function.name })
                #expect(names.contains("render_chart"))
                // Sandbox built-ins are additive when sandbox is active.
                #expect(names.contains("sandbox_exec"))
                // Always-loaded built-ins remain present too.
                #expect(names.contains("todo"))
                #expect(names.contains("share_artifact"))
            }
        }
    }

    @Test
    func manualMode_emptyManualNames_stillIncludesAlwaysLoaded() async {
        await withSandboxAgent(autonomous: true, manualToolNames: []) { agentId in
            withRegisteredSandboxBuiltins {
                let tools = SystemPromptComposer.resolveTools(
                    agentId: agentId,
                    executionMode: .sandbox(hostRead: nil)
                )
                let names = Set(tools.map { $0.function.name })
                // No manual selection — but always-loaded built-ins and
                // sandbox runtime tools are still present (pragmatic mode).
                #expect(names.contains("todo"))
                #expect(names.contains("share_artifact"))
                #expect(names.contains("sandbox_exec"))
                #expect(names.contains("capabilities_search"))
            }
        }
    }

    @Test
    func hostFolderMode_includesFolderMutationAndArtifactTools() async {
        await withSandboxAgent(autonomous: false) { agentId in
            withRegisteredFolderTools { folder in
                let tools = SystemPromptComposer.resolveTools(
                    agentId: agentId,
                    executionMode: .hostFolder(folder)
                )
                let names = Set(tools.map { $0.function.name })
                #expect(names.contains("file_write"))
                #expect(names.contains("file_edit"))
                #expect(names.contains("share_artifact"))
            }
        }
    }

    @Test
    func combinedMode_showsHostReadToolsAndSandboxExec_hidesHostWrite() async {
        // Combined sandbox + host-read: both the sandbox builtins and the
        // folder tools are registered, but only the read-only host subset
        // (`file_read`/`file_search`) should surface alongside sandbox exec.
        // Host write/edit/shell stay hidden — the host is read-only and
        // exec is sandbox-only.
        await withSandboxAgent(autonomous: true) { agentId in
            withRegisteredSandboxBuiltins {
                withRegisteredFolderTools { folder in
                    let tools = SystemPromptComposer.resolveTools(
                        agentId: agentId,
                        executionMode: .sandbox(hostRead: folder)
                    )
                    let names = Set(tools.map { $0.function.name })
                    // Read-only host subset is visible — now the single,
                    // path-routed read family (serves `/workspace/...`
                    // sandbox paths too via the bridge). `file_read` also
                    // lists directories, so there is no separate `file_tree`.
                    #expect(names.contains("file_read"))
                    #expect(names.contains("file_search"))
                    #expect(!names.contains("file_tree"))
                    // Sandbox exec is visible.
                    #expect(names.contains("sandbox_exec"))
                    // Host write / edit are hidden (read-only host).
                    #expect(!names.contains("file_write"))
                    #expect(!names.contains("file_edit"))
                    // The redundant sandbox read tools are hidden in
                    // combined mode (`file_*` reach sandbox paths now), but
                    // the single sandbox writer stays visible.
                    #expect(!names.contains("sandbox_read_file"))
                    #expect(!names.contains("sandbox_search_files"))
                    #expect(names.contains("sandbox_write_file"))
                    // `sandbox_edit_file` folded into `sandbox_write_file`.
                    #expect(!names.contains("sandbox_edit_file"))
                    // Global egress + loop tools remain.
                    #expect(names.contains("share_artifact"))
                }
            }
        }
    }

    @Test
    func combinedMode_unifiedReadTools_advertiseRoutingAndKeepSandboxReadCallable() async {
        // The unified `file_*` read tools must tell the model (at the
        // schema level) that they also reach `/workspace/...` sandbox
        // paths, and the hidden `sandbox_read_file` must remain registered
        // so the `sandbox_execute_code` Python bridge can still dispatch it.
        // The note rides the FULL spec (turn-1 bootstrap compaction keeps
        // only the first sentence; the `## Files` prompt block carries the
        // routing on turn 1), so assert against `alwaysLoadedSpecs`.
        await withSandboxAgent(autonomous: true) { _ in
            withRegisteredSandboxBuiltins {
                withRegisteredFolderTools { folder in
                    let specs = ToolRegistry.shared.alwaysLoadedSpecs(
                        mode: .sandbox(hostRead: folder)
                    )
                    let byName = Dictionary(
                        uniqueKeysWithValues: specs.map { ($0.function.name, $0) }
                    )
                    for readTool in ["file_read", "file_search"] {
                        let desc = byName[readTool]?.function.description ?? ""
                        #expect(
                            desc.contains("/workspace/"),
                            "\(readTool) should advertise the sandbox route in combined mode"
                        )
                    }
                    // `file_tree` is merged into `file_read` — absent from the schema.
                    #expect(byName["file_tree"] == nil)

                    // Hidden from the schema...
                    #expect(byName["sandbox_read_file"] == nil)
                    // ...but still registered (callable for the Python bridge).
                    let callable = ToolRegistry.shared.specs(forTools: ["sandbox_read_file"])
                    #expect(
                        callable.count == 1,
                        "sandbox_read_file must stay registered for the execute-code bridge"
                    )
                }
            }
        }
    }

    @Test
    func pureFolderMode_readToolDescriptionsHaveNoSandboxRoutingNote() async {
        // The routing note is combined-mode only — pure folder schemas must
        // not mention `/workspace/...` (there is no sandbox to route to).
        await withSandboxAgent(autonomous: false) { _ in
            withRegisteredFolderTools { folder in
                let specs = ToolRegistry.shared.alwaysLoadedSpecs(
                    mode: .hostFolder(folder)
                )
                let byName = Dictionary(
                    uniqueKeysWithValues: specs.map { ($0.function.name, $0) }
                )
                for readTool in ["file_read", "file_search"] {
                    let desc = byName[readTool]?.function.description ?? ""
                    #expect(!desc.contains("/workspace/"))
                }
                // `file_tree` no longer exists as a separate tool.
                #expect(byName["file_tree"] == nil)
            }
        }
    }

    // MARK: - Loop tools + share_artifact visibility

    @Test
    func loopToolsAreVisibleAcrossEveryMode() async {
        let modes: [ExecutionMode] = [.none]
        for mode in modes {
            await withSandboxAgent(autonomous: false) { agentId in
                let names = Set(
                    SystemPromptComposer.resolveTools(agentId: agentId, executionMode: mode)
                        .map { $0.function.name }
                )
                #expect(names.contains("todo"))
                #expect(names.contains("complete"))
                #expect(names.contains("clarify"))
                #expect(names.contains("share_artifact"))
            }
        }

        await withSandboxAgent(autonomous: true) { agentId in
            withRegisteredSandboxBuiltins {
                let names = Set(
                    SystemPromptComposer.resolveTools(agentId: agentId, executionMode: .sandbox(hostRead: nil))
                        .map { $0.function.name }
                )
                #expect(names.contains("todo"))
                #expect(names.contains("complete"))
                #expect(names.contains("clarify"))
                #expect(names.contains("share_artifact"))
            }
        }
    }

    @Test
    func canonicalToolOrder_pinsLoopToolsToTheTop() async {
        await withSandboxAgent(autonomous: true) { agentId in
            withRegisteredSandboxBuiltins {
                let names = SystemPromptComposer.resolveTools(
                    agentId: agentId,
                    executionMode: .sandbox(hostRead: nil)
                ).map { $0.function.name }
                // The first four entries must be the loop tools in fixed
                // order. This is what makes the rendered <tools> prefix
                // stable across sends regardless of what late-arriving
                // plugins or MCP providers register.
                #expect(names.prefix(4) == ["todo", "complete", "clarify", "share_artifact"])
            }
        }
    }

    // MARK: - Tools disabled

    @Test
    func toolsDisabled_returnsEmpty() async {
        await withSandboxAgent(autonomous: true) { agentId in
            withRegisteredSandboxBuiltins {
                let tools = SystemPromptComposer.resolveTools(
                    agentId: agentId,
                    executionMode: .sandbox(hostRead: nil),
                    toolsDisabled: true
                )
                #expect(tools.isEmpty)
            }
        }
    }

    // MARK: - Auto-mode preflight query fallback

    @Test
    func resolvePreflightQuery_prefersExplicitQuery() {
        let messages: [ChatMessage] = [
            ChatMessage(role: "user", content: "old question")
        ]
        let resolved = SystemPromptComposer.resolvePreflightQuery(
            query: "fresh question",
            messages: messages
        )
        #expect(resolved == "fresh question")
    }

    @Test
    func resolvePreflightQuery_fallsBackToLastUserMessageWhenQueryEmpty() {
        let messages: [ChatMessage] = [
            ChatMessage(role: "user", content: "first"),
            ChatMessage(role: "assistant", content: "ok"),
            ChatMessage(role: "user", content: "second"),
        ]
        let resolved = SystemPromptComposer.resolvePreflightQuery(
            query: "",
            messages: messages
        )
        #expect(resolved == "second")
    }

    @Test
    func resolvePreflightQuery_returnsEmptyWhenNothingAvailable() {
        let resolved = SystemPromptComposer.resolvePreflightQuery(
            query: "",
            messages: []
        )
        #expect(resolved.isEmpty)
    }

    // MARK: - additionalToolNames

    @Test
    func resolveTools_autoMode_mergesAdditionalToolNames() async {
        await withSandboxAgent(autonomous: false) { agentId in
            // share_artifact is a built-in always-loaded tool; ask the
            // resolver to also include `search_memory` via additionalToolNames
            // and verify the union has no duplicates (search_memory is already
            // a built-in but additional should still be a no-op merge).
            let tools = SystemPromptComposer.resolveTools(
                agentId: agentId,
                executionMode: .none,
                additionalToolNames: ["search_memory"]
            )
            let names = tools.map { $0.function.name }
            #expect(names.contains("search_memory"))
            #expect(Set(names).count == names.count)
        }
    }

    // MARK: - Per-agent built-in tool gates

    /// With default agent settings (every feature gate off, including the
    /// self-scheduling opt-in) the `render_chart` / `speak` / `search_memory`
    /// built-ins and the scheduler trio are all stripped from the auto-mode
    /// schema — that's the lean default surface.
    @Test
    func autoMode_stripsGatedBuiltInsByDefault() async {
        await withSandboxAgent(autonomous: false) { agentId in
            let names = Set(
                SystemPromptComposer.resolveTools(agentId: agentId, executionMode: .none)
                    .map { $0.function.name }
            )
            #expect(!names.contains("render_chart"))
            #expect(!names.contains("speak"))
            #expect(!names.contains("search_memory"))
            // Self-scheduling defaults off → scheduler trio stripped.
            #expect(!names.contains("schedule_next_run"))
            #expect(!names.contains("cancel_next_run"))
            #expect(!names.contains("notify"))
        }
    }

    /// Enabling each per-agent gate surfaces the matching built-in; the
    /// self-scheduling opt-in surfaces the scheduler trio independently of
    /// the schedule-mode picker.
    @Test
    func autoMode_includesGatedBuiltInsWhenEnabled() async {
        await withSandboxAgent(autonomous: false) { agentId in
            let manager = AgentManager.shared
            guard var agent = manager.agent(for: agentId) else {
                Issue.record("agent vanished")
                return
            }
            agent.settings.renderChartEnabled = true
            agent.settings.speakEnabled = true
            agent.settings.searchMemoryEnabled = true
            agent.settings.selfSchedulingEnabled = true
            manager.update(agent)

            let names = Set(
                SystemPromptComposer.resolveTools(agentId: agentId, executionMode: .none)
                    .map { $0.function.name }
            )
            #expect(names.contains("render_chart"))
            #expect(names.contains("speak"))
            #expect(names.contains("search_memory"))
            // Self-scheduling on → scheduler trio present.
            #expect(names.contains("schedule_next_run"))
            #expect(names.contains("cancel_next_run"))
            #expect(names.contains("notify"))
        }
    }

    /// The self-scheduling gate is decoupled from the schedule-mode picker:
    /// an ambient-mode agent that hasn't opted into self-scheduling still has
    /// the scheduler trio stripped.
    @Test
    func autoMode_scheduleModeDoesNotImplySelfScheduling() async {
        await withSandboxAgent(autonomous: false) { agentId in
            let manager = AgentManager.shared
            guard var agent = manager.agent(for: agentId) else {
                Issue.record("agent vanished")
                return
            }
            agent.settings.schedule = AgentScheduleSettings.defaults(for: .ambient)
            agent.settings.selfSchedulingEnabled = false
            manager.update(agent)

            let names = Set(
                SystemPromptComposer.resolveTools(agentId: agentId, executionMode: .none)
                    .map { $0.function.name }
            )
            #expect(!names.contains("schedule_next_run"))
            #expect(!names.contains("cancel_next_run"))
            #expect(!names.contains("notify"))
        }
    }

    // MARK: - canonicalToolOrder

    @Test
    func canonicalToolOrder_isStableAcrossInvocations() async {
        await withSandboxAgent(autonomous: true) { agentId in
            withRegisteredSandboxBuiltins {
                // Two compositions with identical inputs must return the
                // exact same tool ordering — that's what makes the rendered
                // <tools> block byte-stable across sends.
                let a = SystemPromptComposer.resolveTools(agentId: agentId, executionMode: .sandbox(hostRead: nil))
                let b = SystemPromptComposer.resolveTools(agentId: agentId, executionMode: .sandbox(hostRead: nil))
                let aNames = a.map { $0.function.name }
                let bNames = b.map { $0.function.name }
                #expect(aNames == bNames)

                // Sandbox built-ins must come first, capability tools next.
                if let firstSandbox = aNames.firstIndex(where: { $0.hasPrefix("sandbox_") }),
                    let firstCapability = aNames.firstIndex(of: "capabilities_search")
                {
                    #expect(firstSandbox < firstCapability)
                }
            }
        }
    }
}
