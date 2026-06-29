//
//  SystemPromptComposerToolResolutionTests.swift
//  osaurusTests
//
//  Verifies the contract of `SystemPromptComposer.resolveTools` across the
//  matrix of (toolMode: auto|manual) x (executionMode: none|sandbox) x
//  (manualNames empty|set). These tests pin down the user-facing spec:
//   - Auto mode = always-loaded built-ins (the fixed hot set) plus tools
//     loaded mid-session via `capabilities_load` (`additionalToolNames`).
//     Under Design C there is no per-turn preflight injection.
//   - Manual mode (pragmatic) = always-loaded built-ins + sandbox/folder
//     runtime when active + user-picked names.
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

    /// Minimal snapshot for the gate tests that exercise `resolveTools`
    /// directly (no `AgentManager` round-trip). A fresh random `agentId`
    /// keeps it off the Default-agent allowlist path so the only thing
    /// under test is the per-capability gate.
    private func makeSnapshot(
        toolMode: ToolSelectionMode = .auto,
        manualToolNames: [String]? = nil,
        computerUseEnabled: Bool = false,
        spawnDelegationEnabled: Bool = false,
        imageEnabled: Bool = false,
        spawnableAgentNames: [String] = [],
        spawnableModelNames: [String] = []
    ) -> AgentConfigSnapshot {
        AgentConfigSnapshot(
            agentId: UUID(),
            toolsDisabled: false,
            memoryDisabled: true,
            autonomousConfig: nil,
            toolMode: toolMode,
            model: nil,
            manualToolNames: manualToolNames,
            systemPrompt: "",
            dbEnabled: false,
            computerUseEnabled: computerUseEnabled,
            spawnDelegationEnabled: spawnDelegationEnabled,
            imageEnabled: imageEnabled,
            spawnableAgentNames: spawnableAgentNames,
            spawnableModelNames: spawnableModelNames
        )
    }

    /// A ready on-device image picker item for the availability-gate tests.
    /// `edit` toggles whether it advertises image editing (`imageEdit`); both
    /// kinds advertise text-to-image so they count as a generation candidate.
    private func readyImageItem(edit: Bool) -> ModelPickerItem {
        ModelPickerItem(
            id: edit ? "test-image-edit" : "test-image-gen",
            displayName: edit ? "Test Edit Model" : "Test Gen Model",
            source: .imageGeneration,
            imageKind: edit ? "image_edit" : "image_generation",
            imageCapabilities: ImageModelCapabilities(textToImage: true, imageEdit: edit),
            imageReady: true
        )
    }

    /// Seed the shared picker cache with `items` for the duration of `body`,
    /// restoring the prior items afterward so seeded image models don't leak
    /// into other suites that read the same singleton. The image-availability
    /// gate in `resolveTools` reads this cache, so the tests must seed it
    /// rather than depend on whatever bundles happen to be on the test machine.
    private func withSeededPickerItems(
        _ items: [ModelPickerItem],
        _ body: @MainActor () -> Void
    ) {
        let previous = ModelPickerItemCache.shared._setItemsForTesting(items)
        defer { ModelPickerItemCache.shared._setItemsForTesting(previous) }
        body()
    }

    /// The property names declared by the resolved `image` tool's schema, used
    /// to assert the generation-only variant drops `source_paths` / `strength`.
    private func imageParameterNames(_ tools: [Tool]) -> Set<String> {
        guard let image = tools.first(where: { $0.function.name == "image" }),
            let params = image.function.parameters,
            case let .object(root) = params,
            let propsValue = root["properties"],
            case let .object(props) = propsValue
        else { return [] }
        return Set(props.keys)
    }

    // MARK: - Auto mode

    @Test
    func autoMode_includesAlwaysLoadedAndPreflightAdditions() async {
        await withSandboxAgent(autonomous: false) { agentId in
            let tools = SystemPromptComposer.resolveTools(
                agentId: agentId,
                executionMode: .none,
                additionalToolNames: ["render_chart"]
            )
            let names = Set(tools.map { $0.function.name })
            // Built-ins like capabilities_discover must be present in auto mode.
            #expect(names.contains("capabilities_discover"))
            #expect(names.contains("capabilities_load"))
            // A tool loaded mid-session via capabilities_load/preflight must
            // survive the lean auto-mode gate even if it is normally hidden.
            #expect(names.contains("render_chart"))
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
            #expect(names.contains("capabilities_discover"))
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
                #expect(names.contains("capabilities_discover"))
            }
        }
    }

    // MARK: - db_* capability gate (manual keep-set consistency)

    @Test
    func autoMode_stripsDbToolsWhenDbDisabled() async {
        // dbEnabled defaults false; auto mode trims the always-loaded db_*
        // baseline so the schema stays lean.
        await withSandboxAgent(autonomous: false) { agentId in
            let tools = SystemPromptComposer.resolveTools(
                agentId: agentId,
                executionMode: .none
            )
            let names = Set(tools.map { $0.function.name })
            #expect(!names.contains("db_schema"))
            #expect(!names.contains("db_query"))
        }
    }

    @Test
    func autoMode_keepsManuallyLoadedDbTool() async {
        // A db tool pulled in via additionalToolNames is a deliberate
        // "I want this" signal and survives the gate even with db off.
        await withSandboxAgent(autonomous: false) { agentId in
            let tools = SystemPromptComposer.resolveTools(
                agentId: agentId,
                executionMode: .none,
                additionalToolNames: ["db_query"]
            )
            let names = Set(tools.map { $0.function.name })
            #expect(names.contains("db_query"))
        }
    }

    @Test
    func manualMode_keepsDbToolsEvenWhenDbDisabled() async {
        // Manual mode curates the list, so the always-loaded db_* baseline
        // stays — uniform with the other gated built-ins (render_chart,
        // speak, search_memory).
        await withSandboxAgent(autonomous: false, manualToolNames: ["render_chart"]) { agentId in
            let tools = SystemPromptComposer.resolveTools(
                agentId: agentId,
                executionMode: .none
            )
            let names = Set(tools.map { $0.function.name })
            #expect(names.contains("db_schema"))
        }
    }

    // MARK: - Computer Use gate (authoritative; auto-injected, never discovered)

    @Test
    func autoMode_injectsComputerUseWhenEnabled() {
        // Opting in must auto-inject `computer_use` into the baseline schema —
        // the user should never have to discover/load it via capabilities.
        let tools = SystemPromptComposer.resolveTools(
            snapshot: makeSnapshot(computerUseEnabled: true),
            executionMode: .none
        )
        let names = Set(tools.map { $0.function.name })
        #expect(names.contains(ComputerUseTool.toolName))
    }

    @Test
    func autoMode_stripsComputerUseWhenDisabled() {
        let tools = SystemPromptComposer.resolveTools(
            snapshot: makeSnapshot(computerUseEnabled: false),
            executionMode: .none
        )
        let names = Set(tools.map { $0.function.name })
        #expect(!names.contains(ComputerUseTool.toolName))
    }

    @Test
    func computerUseHasNoCapabilitiesLoadCarveOut() {
        // Unlike the lean-by-default built-ins, `computer_use` is stripped even
        // when a stray `capabilities_load` names it — the gate is authoritative.
        let tools = SystemPromptComposer.resolveTools(
            snapshot: makeSnapshot(computerUseEnabled: false),
            executionMode: .none,
            additionalToolNames: [ComputerUseTool.toolName]
        )
        let names = Set(tools.map { $0.function.name })
        #expect(!names.contains(ComputerUseTool.toolName))
    }

    @Test
    func manualMode_injectsComputerUseWhenEnabled() {
        let tools = SystemPromptComposer.resolveTools(
            snapshot: makeSnapshot(
                toolMode: .manual,
                manualToolNames: ["render_chart"],
                computerUseEnabled: true
            ),
            executionMode: .none
        )
        let names = Set(tools.map { $0.function.name })
        #expect(names.contains(ComputerUseTool.toolName))
    }

    @Test
    func computerUseIsBuiltInButExcludedFromDiscovery() {
        // Registered as a built-in so the runtime can execute it and ChatView
        // can intercept its feed, but it must stay out of the dynamic discovery
        // catalog (`listDynamicTools`) and be flagged non-discoverable so the
        // index sync keeps it out of `capabilities_discover`.
        #expect(ToolRegistry.shared.builtInToolNames.contains(ComputerUseTool.toolName))
        #expect(ToolRegistry.nonDiscoverableBuiltInToolNames.contains(ComputerUseTool.toolName))
        let dynamicNames = Set(ToolRegistry.shared.listDynamicTools().map(\.name))
        #expect(!dynamicNames.contains(ComputerUseTool.toolName))
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
        // (just suppressed from the schema) so tear-down and capability
        // indexing keep tracking it.
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
                    // ...but still registered (tear-down + capability indexing).
                    let callable = ToolRegistry.shared.specs(forTools: ["sandbox_read_file"])
                    #expect(
                        callable.count == 1,
                        "sandbox_read_file must stay registered even when hidden"
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

    // MARK: - Effective-query fallback

    @Test
    func resolveEffectiveQuery_prefersExplicitQuery() {
        let messages: [ChatMessage] = [
            ChatMessage(role: "user", content: "old question")
        ]
        let resolved = SystemPromptComposer.resolveEffectiveQuery(
            query: "fresh question",
            messages: messages
        )
        #expect(resolved == "fresh question")
    }

    @Test
    func resolveEffectiveQuery_fallsBackToLastUserMessageWhenQueryEmpty() {
        let messages: [ChatMessage] = [
            ChatMessage(role: "user", content: "first"),
            ChatMessage(role: "assistant", content: "ok"),
            ChatMessage(role: "user", content: "second"),
        ]
        let resolved = SystemPromptComposer.resolveEffectiveQuery(
            query: "",
            messages: messages
        )
        #expect(resolved == "second")
    }

    @Test
    func resolveEffectiveQuery_returnsEmptyWhenNothingAvailable() {
        let resolved = SystemPromptComposer.resolveEffectiveQuery(
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

    // MARK: - Delegation gates (spawn / image — per-capability, per-agent)

    /// Run `body` in an isolated subagent-store sandbox with a default global
    /// config, then reset. There is no master switch anymore; delegation
    /// visibility is driven entirely by the per-agent snapshot in `resolveTools`.
    /// Mirrors `SubagentToolAvailabilityTests`' cross-suite lock so the global
    /// config stays stable while we read the delegation-gated schema.
    private func withSubagentSandbox(_ body: @MainActor @Sendable () async -> Void) async {
        let lease = await acquireSubagentStoreSandbox("composer-delegation")
        defer { lease.release() }
        SubagentConfigurationStore.save(SubagentConfiguration())
        await body()
    }

    /// A custom agent surfaces `image` purely on its OWN `imageEnabled` toggle,
    /// independent of spawn — `image` is its own per-agent flag now, and
    /// `resolveTools` resolves each delegation capability separately.
    @Test
    func autoMode_customAgentSurfacesImageIndependentlyOfSpawn() async {
        await withSubagentSandbox {
            // A ready edit-capable model is installed, so `image` surfaces.
            withSeededPickerItems([readyImageItem(edit: true)]) {
                let names = Set(
                    SystemPromptComposer.resolveTools(
                        snapshot: makeSnapshot(imageEnabled: true),
                        executionMode: .none
                    ).map { $0.function.name }
                )
                #expect(names.contains("image"))
                // No spawn toggle / list → spawn stays hidden even though image is on.
                #expect(!names.contains("spawn_agent"))
                #expect(!names.contains("spawn_model"))
            }
        }
    }

    /// Installed-capability gate: with the image toggle on but NO ready image
    /// model on device, `image` must stay out of the schema entirely — the
    /// model is never offered an image capability the runtime can't satisfy.
    @Test
    func autoMode_imageWithheldWhenNoImageModelInstalled() async {
        await withSubagentSandbox {
            withSeededPickerItems([]) {
                let names = Set(
                    SystemPromptComposer.resolveTools(
                        snapshot: makeSnapshot(imageEnabled: true),
                        executionMode: .none
                    ).map { $0.function.name }
                )
                #expect(!names.contains("image"))
            }
        }
    }

    /// With a generation model but NO ready edit model, `image` surfaces but as
    /// the generation-only variant: the edit-only `source_paths` / `strength`
    /// fields are absent so the model can't request an edit it can't run.
    @Test
    func autoMode_imageSchemaIsGenerationOnlyWhenNoEditModel() async {
        await withSubagentSandbox {
            withSeededPickerItems([readyImageItem(edit: false)]) {
                let tools = SystemPromptComposer.resolveTools(
                    snapshot: makeSnapshot(imageEnabled: true),
                    executionMode: .none
                )
                #expect(tools.contains { $0.function.name == "image" })
                let props = imageParameterNames(tools)
                #expect(props.contains("prompt"))
                #expect(!props.contains("source_paths"))
                #expect(!props.contains("strength"))
            }
        }
    }

    /// With a ready edit model installed, `image` keeps its full schema: the
    /// edit affordance (`source_paths`) is present.
    @Test
    func autoMode_imageSchemaIsFullWhenEditModelReady() async {
        await withSubagentSandbox {
            withSeededPickerItems([readyImageItem(edit: true)]) {
                let tools = SystemPromptComposer.resolveTools(
                    snapshot: makeSnapshot(imageEnabled: true),
                    executionMode: .none
                )
                let props = imageParameterNames(tools)
                #expect(props.contains("prompt"))
                #expect(props.contains("source_paths"))
            }
        }
    }

    /// A custom agent surfaces `spawn_agent` only with its own toggle AND a
    /// non-empty per-agent AGENT list, and `spawn_model` only with a non-empty
    /// MODEL list — each spawn tool gates independently on its own pool. `image`
    /// stays hidden when its own toggle is off.
    @Test
    func autoMode_customAgentSurfacesSpawnOnlyWithToggleAndTargets() async {
        await withSubagentSandbox {
            // Agent pool only → spawn_agent, not spawn_model.
            let withAgents = Set(
                SystemPromptComposer.resolveTools(
                    snapshot: makeSnapshot(
                        spawnDelegationEnabled: true,
                        spawnableAgentNames: ["Helper"]
                    ),
                    executionMode: .none
                ).map { $0.function.name }
            )
            #expect(withAgents.contains("spawn_agent"))
            #expect(!withAgents.contains("spawn_model"))
            #expect(!withAgents.contains("image"))

            // Model pool only → spawn_model, not spawn_agent.
            let withModels = Set(
                SystemPromptComposer.resolveTools(
                    snapshot: makeSnapshot(
                        spawnDelegationEnabled: true,
                        spawnableModelNames: ["qwen3-4b-4bit"]
                    ),
                    executionMode: .none
                ).map { $0.function.name }
            )
            #expect(withModels.contains("spawn_model"))
            #expect(!withModels.contains("spawn_agent"))

            // Toggle on but BOTH lists empty → nothing to spawn → both hidden.
            let noTargets = Set(
                SystemPromptComposer.resolveTools(
                    snapshot: makeSnapshot(
                        spawnDelegationEnabled: true,
                        spawnableAgentNames: []
                    ),
                    executionMode: .none
                ).map { $0.function.name }
            )
            #expect(!noTargets.contains("spawn_agent"))
            #expect(!noTargets.contains("spawn_model"))
        }
    }

    /// Off-by-default now lives at the per-agent level (there is no master kill
    /// switch): a custom agent that opted into nothing surfaces no delegation
    /// tools — even when the main chat's OWN pool / image switch are populated,
    /// they must not leak to another agent.
    @Test
    func autoMode_customAgentWithNoOptInHidesAllDelegationTools() async {
        let lease = await acquireSubagentStoreSandbox("composer-no-optin")
        defer { lease.release() }
        SubagentConfigurationStore.save(
            SubagentConfiguration(spawnableAgentNames: ["Helper"], imageDelegationEnabled: true)
        )
        let names = Set(
            SystemPromptComposer.resolveTools(
                snapshot: makeSnapshot(
                    spawnDelegationEnabled: false,
                    imageEnabled: false,
                    spawnableAgentNames: []
                ),
                executionMode: .none
            ).map { $0.function.name }
        )
        #expect(!names.contains("image"))
        #expect(!names.contains("spawn_agent"))
        #expect(!names.contains("spawn_model"))
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
                    let firstCapability = aNames.firstIndex(of: "capabilities_discover")
                {
                    #expect(firstSandbox < firstCapability)
                }
            }
        }
    }
}
