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
        backgroundProcesses: Bool = false,
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
                    autonomousExec: autonomous
                        ? AutonomousExecConfig(
                            enabled: true,
                            backgroundProcessEnabled: backgroundProcesses
                        )
                        : nil,
                    toolSelectionMode: .manual,
                    manualToolNames: names
                )
            } else {
                agent = Agent(
                    name: "ToolResolutionTestAgent-\(UUID().uuidString.prefix(6))",
                    agentAddress: "test-tool-resolution-\(UUID().uuidString)",
                    autonomousExec: autonomous
                        ? AutonomousExecConfig(
                            enabled: true,
                            backgroundProcessEnabled: backgroundProcesses
                        )
                        : nil
                )
            }
            manager.add(agent)
            await body(agent.id)
            _ = await manager.delete(id: agent.id)
        }
    }

    private func withRegisteredSandboxBuiltins(
        backgroundProcesses: Bool = false,
        _ body: @MainActor @Sendable () -> Void
    ) {
        BuiltinSandboxTools.register(
            agentId: "tool-resolution-test",
            agentName: "tool-resolution-test",
            config: AutonomousExecConfig(
                enabled: true,
                backgroundProcessEnabled: backgroundProcesses
            )
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
        FolderToolManager.shared.ensureFolderToolsRegistered()
        body(folder)
        FolderToolManager.shared._unregisterAllForTesting()
    }

    /// Minimal snapshot for the gate tests that exercise `resolveTools`
    /// directly (no `AgentManager` round-trip). A fresh random `agentId`
    /// keeps it off the Default-agent allowlist path so the only thing
    /// under test is the per-capability gate.
    private func makeSnapshot(
        toolMode: ToolSelectionMode = .auto,
        manualToolNames: [String]? = nil,
        renderChartEnabled: Bool = false,
        webSearchEnabled: Bool = false,
        computerUseEnabled: Bool = false,
        browserUseEnabled: Bool = false,
        spawnDelegationEnabled: Bool = false,
        imageEnabled: Bool = false,
        spawnableAgentIDs: [UUID] = [],
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
            renderChartEnabled: renderChartEnabled,
            webSearchEnabled: webSearchEnabled,
            computerUseEnabled: computerUseEnabled,
            browserUseEnabled: browserUseEnabled,
            spawnDelegationEnabled: spawnDelegationEnabled,
            imageEnabled: imageEnabled,
            spawnableAgentIDs: spawnableAgentIDs,
            spawnableModelNames: spawnableModelNames
        )
    }

    /// Minimal Default/main-chat snapshot. Its delegation pools and budgets
    /// intentionally come from `SubagentConfigurationStore`, matching the
    /// production Default-agent contract.
    private func makeSnapshotForDefaultAgent() -> AgentConfigSnapshot {
        AgentConfigSnapshot(
            agentId: Agent.defaultId,
            toolsDisabled: false,
            memoryDisabled: true,
            autonomousConfig: nil,
            toolMode: .auto,
            model: nil,
            manualToolNames: nil,
            systemPrompt: "",
            dbEnabled: false
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

    /// Exact ids published in the request-local `spawn_model.model` enum.
    private func spawnModelEnum(_ tools: [Tool]) -> [String] {
        guard let spawn = tools.first(where: { $0.function.name == "spawn_model" }),
            case .object(let root)? = spawn.function.parameters,
            case .object(let properties)? = root["properties"],
            case .object(let model)? = properties["model"],
            case .array(let values)? = model["enum"]
        else { return [] }
        return values.compactMap {
            if case .string(let value) = $0 { return value }
            return nil
        }
    }

    /// Exact union of agent names and model ids published in
    /// `spawn_batch.jobs.items.properties.target.enum`.
    private func spawnBatchTargetEnum(_ tools: [Tool]) -> [String] {
        guard let spawn = tools.first(where: { $0.function.name == "spawn_batch" }),
            case .object(let root)? = spawn.function.parameters,
            case .object(let properties)? = root["properties"],
            case .object(let jobs)? = properties["jobs"],
            case .object(let items)? = jobs["items"],
            case .object(let jobProperties)? = items["properties"],
            case .object(let target)? = jobProperties["target"],
            case .array(let values)? = target["enum"]
        else { return [] }
        return values.compactMap {
            if case .string(let value) = $0 { return value }
            return nil
        }
    }

    /// Request-local batch cap published in `spawn_batch.jobs.maxItems`.
    private func spawnBatchMaxItems(_ tools: [Tool]) -> Int? {
        guard let spawn = tools.first(where: { $0.function.name == "spawn_batch" }),
            case .object(let root)? = spawn.function.parameters,
            case .object(let properties)? = root["properties"],
            case .object(let jobs)? = properties["jobs"],
            case .number(let value)? = jobs["maxItems"]
        else { return nil }
        return Int(value)
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
            #expect(!names.contains("capabilities_discover"))
            #expect(!names.contains("capabilities_load"))
            #expect(names.isSuperset(of: SystemPromptComposer.agentLoopToolNames))
            #expect(names.contains("render_chart"))
        }
    }

    @Test
    func queryWordingDoesNotChangeCompactGatewayBaseline() {
        let pluginQuery = SystemPromptComposer.resolveTools(
            snapshot: makeSnapshot(),
            executionMode: .none,
            query: "Use an installed plugin capability for this task"
        )
        let unrelatedQuery = SystemPromptComposer.resolveTools(
            snapshot: makeSnapshot(),
            executionMode: .none,
            query: "Summarize these notes"
        )
        let names = Set(pluginQuery.map(\.function.name))
        #expect(names.contains("capabilities"))
        #expect(!names.contains("capabilities_discover"))
        #expect(!names.contains("capabilities_load"))
        #expect(
            pluginQuery.map { $0.canonicalHashPayload() }
                == unrelatedQuery.map { $0.canonicalHashPayload() }
        )
    }

    @Test
    func workspaceWebAppRequestKeepsCapabilityGatewayWithoutDisabledSearch() {
        withRegisteredFolderTools { folder in
            let tools = SystemPromptComposer.resolveTools(
                snapshot: makeSnapshot(),
                executionMode: .hostFolder(folder),
                query: "Create a polished single-file web app in index.html"
            )
            let names = Set(tools.map(\.function.name))
            #expect(names.isSuperset(of: ToolRegistry.coreWorkspaceToolNames))
            #expect(names.contains("capabilities"))
            #expect(!names.contains("web_search"))
        }
    }

    @Test
    func workspacePreservesEnabledCapabilitiesWithoutQueryHints() {
        withRegisteredFolderTools { folder in
            let tools = SystemPromptComposer.resolveTools(
                snapshot: makeSnapshot(
                    renderChartEnabled: true,
                    webSearchEnabled: true,
                    browserUseEnabled: true
                ),
                executionMode: .hostFolder(folder),
                query: "Update the project documentation"
            )
            let names = Set(tools.map(\.function.name))
            #expect(names.isSuperset(of: ToolRegistry.coreWorkspaceToolNames))
            #expect(names.contains("capabilities"))
            #expect(names.contains("render_chart"))
            #expect(names.contains("web_search"))
            #expect(names.contains("search_and_extract"))
            #expect(names.contains(BrowserUseTool.toolName))
        }
    }

    @Test
    func sandboxPreservesEnabledCapabilitiesWithoutQueryHints() {
        withRegisteredSandboxBuiltins {
            let tools = SystemPromptComposer.resolveTools(
                snapshot: makeSnapshot(
                    renderChartEnabled: true,
                    webSearchEnabled: true,
                    browserUseEnabled: true
                ),
                executionMode: .sandbox(hostRead: nil),
                query: "Update the project documentation"
            )
            let names = Set(tools.map(\.function.name))
            #expect(names.isSuperset(of: ToolRegistry.coreWorkspaceToolNames))
            #expect(names.contains("capabilities"))
            #expect(names.contains("render_chart"))
            #expect(names.contains("web_search"))
            #expect(names.contains("search_and_extract"))
            #expect(names.contains(BrowserUseTool.toolName))
        }
    }

    @Test
    func workspaceToolSchemaIsQueryInvariant() {
        withRegisteredFolderTools { folder in
            let snapshot = makeSnapshot(
                renderChartEnabled: true,
                webSearchEnabled: true,
                browserUseEnabled: true
            )
            let documentationQuery = SystemPromptComposer.resolveTools(
                snapshot: snapshot,
                executionMode: .hostFolder(folder),
                query: "Update the project documentation"
            )
            let chartQuery = SystemPromptComposer.resolveTools(
                snapshot: snapshot,
                executionMode: .hostFolder(folder),
                query: "Render a chart from data.csv in the workspace"
            )
            let names = Set(chartQuery.map(\.function.name))
            #expect(names.isSuperset(of: ToolRegistry.coreWorkspaceToolNames))
            #expect(names.contains("render_chart"))
            #expect(names.contains("web_search"))
            #expect(names.contains(BrowserUseTool.toolName))
            #expect(
                documentationQuery.map { $0.canonicalHashPayload() }
                    == chartQuery.map { $0.canonicalHashPayload() }
            )
        }
    }

    @Test
    func workspaceUsesCompactSchemasWithThirtyPercentSurfaceReduction() {
        withRegisteredFolderTools { folder in
            let compact = SystemPromptComposer.resolveTools(
                snapshot: makeSnapshot(),
                executionMode: .hostFolder(folder),
                query: "Create a polished single-file web app in index.html"
            )
            let full = ToolRegistry.shared.specs(
                forTools: Array(ToolRegistry.coreWorkspaceToolNames)
            )
            let compactWorkspace = compact.filter {
                ToolRegistry.coreWorkspaceToolNames.contains($0.function.name)
            }
            let compactTokens = ToolRegistry.shared.totalEstimatedTokens(for: compactWorkspace)
            let fullTokens = ToolRegistry.shared.totalEstimatedTokens(for: full)
            #expect(compactTokens * 10 <= fullTokens * 7)

            let shell = compact.first { $0.function.name == "shell_run" }
            guard case .object(let root)? = shell?.function.parameters,
                case .object(let properties)? = root["properties"]
            else {
                Issue.record("missing compact shell schema")
                return
            }
            #expect(Set(properties.keys) == ["command"])
        }
    }

    @Test
    func workspaceKeywordsDoNotChangeToolSchema() {
        withRegisteredFolderTools { folder in
            let ordinary = SystemPromptComposer.resolveTools(
                snapshot: makeSnapshot(),
                executionMode: .hostFolder(folder),
                query: "Update one paragraph in README.md"
            )
            let keywordHeavy = SystemPromptComposer.resolveTools(
                snapshot: makeSnapshot(),
                executionMode: .hostFolder(folder),
                query: "Plot the latest results today and start a server"
            )
            let names = Set(ordinary.map(\.function.name))
            #expect(names.contains("get_current_time"))
            #expect(!names.contains("render_chart"))
            #expect(
                ordinary.map { $0.canonicalHashPayload() }
                    == keywordHeavy.map { $0.canonicalHashPayload() }
            )
        }
    }

    @Test("baseline tool payloads are canonically stable across repeated resolves")
    func baselineToolPayloads_areStableAcrossRepeatedResolves() async {
        await withSandboxAgent(autonomous: false) { agentId in
            // Turn 1: the payloads captured here become the session's frozen
            // baseline in production.
            let first = SystemPromptComposer.resolveTools(
                agentId: agentId,
                executionMode: .none,
                query: "what time is it?"
            )
            #expect(first.contains { $0.function.name == "get_current_time" })

            // Turn 2 (frozen fields echoed like ChatView / PluginHostAPI do):
            // every baseline tool must resolve to the exact same canonical
            // payload, in the same canonical order, so the tokenizer prefix —
            // and with it the KV cache — survives the turn boundary.
            let second = SystemPromptComposer.resolveTools(
                agentId: agentId,
                executionMode: .none,
                query: "what time is it?",
                frozenAlwaysLoadedNames: Set(first.map(\.function.name)),
                frozenToolSpecs: first
            )
            #expect(first.map(\.function.name) == second.map(\.function.name))
            for (a, b) in zip(first, second) {
                #expect(
                    a.canonicalHashPayload() == b.canonicalHashPayload(),
                    "baseline payload drifted for \(a.function.name)"
                )
            }
            #expect(
                PromptPrefixHasher.hash(systemContent: "prefix", tools: second)
                    == PromptPrefixHasher.hash(systemContent: "prefix", tools: first)
            )

            // A fresh un-frozen resolve must ALSO be identical: baseline
            // schemas are immutable by contract, so the freeze is a backstop
            // for dynamically registered tools, not a crutch that hides
            // mutable built-in schemas.
            let fresh = SystemPromptComposer.resolveTools(
                agentId: agentId,
                executionMode: .none,
                query: "what time is it?"
            )
            #expect(
                PromptPrefixHasher.hash(systemContent: "prefix", tools: fresh)
                    == PromptPrefixHasher.hash(systemContent: "prefix", tools: first)
            )

            // Explicit loading remains an intentional schema upgrade: it
            // replaces the compact bootstrap baseline with the full contract.
            let explicitlyLoaded = SystemPromptComposer.resolveTools(
                agentId: agentId,
                executionMode: .none,
                query: "what time is it?",
                additionalToolNames: ["web_search"],
                frozenAlwaysLoadedNames: Set(first.map(\.function.name)),
                frozenToolSpecs: first
            )
            let loadedWeb = explicitlyLoaded.first { $0.function.name == "web_search" }
            #expect(loadedWeb != nil)
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
            #expect(!names.contains("todo"))
            #expect(!names.contains("complete"))
            #expect(!names.contains("share_artifact"))
            #expect(!names.contains("capabilities_discover"))
            #expect(!names.contains("capabilities_load"))
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
                #expect(names.isSuperset(of: ToolRegistry.coreWorkspaceToolNames))
                #expect(!names.contains("sandbox_exec"))
                #expect(!names.contains("todo"))
                #expect(!names.contains("share_artifact"))
            }
        }
    }

    @Test
    func manualMode_emptyManualNames_keepsBaselineWhenSandboxActive() async {
        await withSandboxAgent(autonomous: true, manualToolNames: []) { agentId in
            withRegisteredSandboxBuiltins {
                let baseline = Set(
                    SystemPromptComposer.resolveTools(
                        agentId: agentId,
                        executionMode: .none
                    ).map(\.function.name)
                )
                let tools = SystemPromptComposer.resolveTools(
                    agentId: agentId,
                    executionMode: .sandbox(hostRead: nil)
                )
                let names = Set(tools.map { $0.function.name })
                #expect(names.isSuperset(of: ToolRegistry.coreWorkspaceToolNames))
                #expect(names.isSuperset(of: baseline))
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
    func manualMode_doesNotAddUnselectedDbToolsWhenDbDisabled() async {
        await withSandboxAgent(autonomous: false, manualToolNames: ["render_chart"]) { agentId in
            let tools = SystemPromptComposer.resolveTools(
                agentId: agentId,
                executionMode: .none
            )
            let names = Set(tools.map { $0.function.name })
            #expect(!names.contains("db_schema"))
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

    // MARK: - Browser Use gate (authoritative; auto-injected, never discovered)

    @Test
    func autoMode_injectsBrowserUseWhenEnabled() {
        // Opting in must auto-inject `browser_use` into the baseline schema —
        // the user should never have to discover/load it via capabilities.
        let tools = SystemPromptComposer.resolveTools(
            snapshot: makeSnapshot(browserUseEnabled: true),
            executionMode: .none
        )
        let names = Set(tools.map { $0.function.name })
        #expect(names.contains(BrowserUseTool.toolName))
    }

    @Test
    func autoMode_stripsBrowserUseWhenDisabled() {
        let tools = SystemPromptComposer.resolveTools(
            snapshot: makeSnapshot(browserUseEnabled: false),
            executionMode: .none
        )
        let names = Set(tools.map { $0.function.name })
        #expect(!names.contains(BrowserUseTool.toolName))
    }

    @Test
    func browserUseHasNoCapabilitiesLoadCarveOut() {
        // Like `computer_use`, `browser_use` is stripped even when a stray
        // `capabilities_load` names it — the per-agent gate is authoritative.
        let tools = SystemPromptComposer.resolveTools(
            snapshot: makeSnapshot(browserUseEnabled: false),
            executionMode: .none,
            additionalToolNames: [BrowserUseTool.toolName]
        )
        let names = Set(tools.map { $0.function.name })
        #expect(!names.contains(BrowserUseTool.toolName))
    }

    @Test
    func browserUseIsBuiltInButExcludedFromDiscovery() {
        #expect(ToolRegistry.shared.builtInToolNames.contains(BrowserUseTool.toolName))
        #expect(ToolRegistry.nonDiscoverableBuiltInToolNames.contains(BrowserUseTool.toolName))
        let dynamicNames = Set(ToolRegistry.shared.listDynamicTools().map(\.name))
        #expect(!dynamicNames.contains(BrowserUseTool.toolName))
        let manifestNames = Set(
            SystemPromptComposer.deriveEnabledManifest(agentId: UUID())
                .flatMap(\.tools)
                .map(\.name)
        )
        #expect(!manifestNames.contains(BrowserUseTool.toolName))
        #expect(!manifestNames.contains("image"))
    }

    @Test
    func httpClientToolsCannotReintroduceAWithheldRegisteredCapability() async throws {
        func spec(_ name: String) -> Tool {
            Tool(
                type: "function",
                function: ToolFunction(name: name, description: "test", parameters: nil)
            )
        }

        let externalName = "client_callback_\(UUID().uuidString)"
        let resolved = await HTTPHandler.mergeAgentContextTools(
            [],
            clientTools: [spec(BrowserUseTool.toolName), spec(externalName)]
        )
        let merged = try #require(resolved)
        let names = Set(merged.map(\.function.name))
        #expect(!names.contains(BrowserUseTool.toolName))
        #expect(names.contains(externalName))
    }

    /// Like `computer_use`, Browser Use is a custom-agent capability: the
    /// Default agent must NEVER see `browser_use` — even if a stray snapshot
    /// carries the flag, the configure-surface allowlist strips it.
    @Test
    func defaultAgent_neverGetsBrowserUse() {
        for strayFlag in [true, false] {
            let snapshot = AgentConfigSnapshot(
                agentId: Agent.defaultId,
                toolsDisabled: false,
                memoryDisabled: true,
                autonomousConfig: nil,
                toolMode: .auto,
                model: nil,
                manualToolNames: nil,
                systemPrompt: "",
                dbEnabled: false,
                browserUseEnabled: strayFlag
            )
            let tools = SystemPromptComposer.resolveTools(snapshot: snapshot, executionMode: .none)
            let names = Set(tools.map { $0.function.name })
            #expect(
                !names.contains(BrowserUseTool.toolName),
                "the Default agent must never get browser_use (flag=\(strayFlag))"
            )
        }
    }

    @Test
    func hostFolderModeAddsWorkspaceToolsWithoutDroppingBaseline() async {
        await withSandboxAgent(autonomous: false) { agentId in
            withRegisteredFolderTools { folder in
                let baseline = Set(
                    SystemPromptComposer.resolveTools(
                        agentId: agentId,
                        executionMode: .none
                    ).map(\.function.name)
                )
                let tools = SystemPromptComposer.resolveTools(
                    agentId: agentId,
                    executionMode: .hostFolder(folder)
                )
                let names = Set(tools.map { $0.function.name })
                #expect(names.isSuperset(of: ToolRegistry.coreWorkspaceToolNames))
                #expect(names.isSuperset(of: baseline))
            }
        }
    }

    @Test
    func legacyCombinedConstructor_resolvesToPureVMContract() async {
        await withSandboxAgent(autonomous: true) { agentId in
            withRegisteredSandboxBuiltins {
                withRegisteredFolderTools { folder in
                    let tools = SystemPromptComposer.resolveTools(
                        agentId: agentId,
                        executionMode: .sandbox(hostRead: folder)
                    )
                    let names = Set(tools.map { $0.function.name })
                    #expect(names.isSuperset(of: ToolRegistry.coreWorkspaceToolNames))
                    #expect(names.contains("capabilities"))
                }
            }
        }
    }

    @Test
    func legacyWritableCombinedConstructor_cannotRestoreHostBridge() async {
        await withSandboxAgent(autonomous: true) { agentId in
            withRegisteredSandboxBuiltins {
                withRegisteredFolderTools { folder in
                    let tools = SystemPromptComposer.resolveTools(
                        agentId: agentId,
                        executionMode: .sandbox(hostRead: folder, hostWrite: true)
                    )
                    let names = Set(tools.map { $0.function.name })
                    #expect(names.isSuperset(of: ToolRegistry.coreWorkspaceToolNames))
                    #expect(names.contains("capabilities"))
                    let callable = ToolRegistry.shared.specs(forTools: ["sandbox_write_file"])
                    #expect(callable.count == 1)
                }
            }
        }
    }

    @Test
    func vmAndHostUseIdenticalPublicWorkspaceSchemas() async {
        await withSandboxAgent(autonomous: true) { _ in
            withRegisteredSandboxBuiltins {
                withRegisteredFolderTools { folder in
                    let host = ToolRegistry.shared.specs(
                        forTools: Array(ToolRegistry.coreWorkspaceToolNames)
                    )
                    let vm = ToolRegistry.shared.alwaysLoadedSpecs(mode: .sandbox)
                        .filter { ToolRegistry.coreWorkspaceToolNames.contains($0.function.name) }
                    let hostPayloads = Dictionary(
                        uniqueKeysWithValues: host.map {
                            ($0.function.name, $0.canonicalHashPayload())
                        }
                    )
                    let vmPayloads = Dictionary(
                        uniqueKeysWithValues: vm.map {
                            ($0.function.name, $0.canonicalHashPayload())
                        }
                    )
                    #expect(
                        hostPayloads == vmPayloads
                    )
                    #expect(!vm.contains { $0.function.name.hasPrefix("sandbox_") })
                    _ = folder
                }
            }
        }
    }

    @Test
    func vmBackendAliasesRemainPrivateButCallable() async {
        await withSandboxAgent(autonomous: true) { _ in
            withRegisteredSandboxBuiltins {
                let publicNames = Set(
                    ToolRegistry.shared.alwaysLoadedSpecs(mode: .sandbox).map(\.function.name)
                )
                #expect(!publicNames.contains("sandbox_read_file"))
                #expect(!publicNames.contains("sandbox_write_file"))
                #expect(ToolRegistry.shared.specs(forTools: ["sandbox_read_file"]).count == 1)
            }
        }
    }

    @Test
    func vmBackgroundModeAlwaysIncludesProcessControlWithoutExpandingShell() async {
        await withSandboxAgent(autonomous: true, backgroundProcesses: true) { agentId in
            withRegisteredSandboxBuiltins(backgroundProcesses: true) {
                withRegisteredFolderTools { _ in
                    let tools = SystemPromptComposer.resolveTools(
                        agentId: agentId,
                        executionMode: .sandbox,
                        query: "Start a background server and keep it running"
                    )
                    let unrelated = SystemPromptComposer.resolveTools(
                        agentId: agentId,
                        executionMode: .sandbox,
                        query: "Summarize the source tree"
                    )
                    let names = Set(tools.map(\.function.name))
                    #expect(names.contains("sandbox_process"))
                    #expect(
                        tools.map { $0.canonicalHashPayload() }
                            == unrelated.map { $0.canonicalHashPayload() }
                    )
                    let shell = tools.first { $0.function.name == "shell_run" }
                    guard let parameters = shell?.function.parameters,
                        case .object(let schema) = parameters,
                        case .object(let properties)? = schema["properties"]
                    else {
                        Issue.record("shell_run should expose an object schema")
                        return
                    }
                    #expect(Set(properties.keys) == ["command"])
                }
            }
        }
    }

    @Test
    func vmDefaultKeepsBackgroundAffordancesHidden() async {
        await withSandboxAgent(autonomous: true) { agentId in
            withRegisteredSandboxBuiltins {
                withRegisteredFolderTools { _ in
                    let tools = SystemPromptComposer.resolveTools(
                        agentId: agentId,
                        executionMode: .sandbox
                    )
                    #expect(!tools.contains { $0.function.name == "sandbox_process" })
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
                // `file_copy` is combined-mode-only: plain folder mode has
                // no sandbox to bridge to (`shell_run` `cp` covers copies).
                #expect(byName["file_copy"] == nil)
            }
        }
    }

    @Test
    func fileCopyAndBackendExecAreHiddenFromVMContract() async {
        await withSandboxAgent(autonomous: true) { agentId in
            withRegisteredSandboxBuiltins {
                let names = Set(
                    SystemPromptComposer.resolveTools(
                        agentId: agentId,
                        executionMode: .sandbox
                    ).map { $0.function.name }
                )
                #expect(names.isSuperset(of: ToolRegistry.coreWorkspaceToolNames))
                #expect(names.contains("capabilities"))
                #expect(!names.contains("file_copy"))
                #expect(!names.contains("sandbox_exec"))
            }
        }
    }

    // MARK: - Lifecycle tool contract

    @Test
    func autoModeKeepsCompleteLifecycleContract() async {
        let modes: [ExecutionMode] = [.none]
        for mode in modes {
            await withSandboxAgent(autonomous: false) { agentId in
                let names = Set(
                    SystemPromptComposer.resolveTools(agentId: agentId, executionMode: mode)
                        .map { $0.function.name }
                )
                #expect(names.isSuperset(of: SystemPromptComposer.agentLoopToolNames))
                #expect(names.contains("get_current_time"))
            }
        }

        await withSandboxAgent(autonomous: true) { agentId in
            withRegisteredSandboxBuiltins {
                let names = Set(
                    SystemPromptComposer.resolveTools(agentId: agentId, executionMode: .sandbox(hostRead: nil))
                        .map { $0.function.name }
                )
                #expect(names.isSuperset(of: SystemPromptComposer.agentLoopToolNames))
                #expect(names.contains("get_current_time"))
            }
        }
    }

    @Test
    func defaultAgentKeepsTodoAndCurrentTimeTogether() {
        let tools = SystemPromptComposer.resolveTools(
            snapshot: makeSnapshotForDefaultAgent(),
            executionMode: .none
        )
        let names = Set(tools.map { $0.function.name })
        #expect(names.contains("todo"))
        #expect(names.contains("complete"))
        #expect(names.contains("clarify"))
        #expect(names.contains("get_current_time"))
    }

    @Test
    func vmContractHasStableCoreOrderAndCapabilityGateway() async {
        await withSandboxAgent(autonomous: true) { agentId in
            withRegisteredSandboxBuiltins {
                let names = SystemPromptComposer.resolveTools(
                    agentId: agentId,
                    executionMode: .sandbox(hostRead: nil)
                ).map { $0.function.name }
                #expect(Set(names).isSuperset(of: ToolRegistry.coreWorkspaceToolNames))
                #expect(names.contains("capabilities"))
                #expect(
                    names.filter { ToolRegistry.coreWorkspaceToolNames.contains($0) }
                        == ["file_edit", "file_read", "file_search", "file_write", "shell_run"]
                )
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
        let previousRuntimeDirectory = ServerRuntimeSettingsStore.overrideDirectory
        ServerRuntimeSettingsStore.overrideDirectory = lease.sandbox
        ServerRuntimeSettingsStore.invalidateSnapshot()
        defer {
            ServerRuntimeSettingsStore.overrideDirectory = previousRuntimeDirectory
            ServerRuntimeSettingsStore.invalidateSnapshot()
            lease.release()
        }
        saveServerBatchLimit(3)
        SubagentConfigurationStore.save(SubagentConfiguration())
        await body()
    }

    private func saveServerBatchLimit(_ value: Int) {
        var settings = ServerRuntimeSettingsStore.snapshot()
        settings.concurrency.maxConcurrentSequences = value
        ServerRuntimeSettingsStore.save(settings)
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
                #expect(!names.contains("spawn_batch"))
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
    /// MODEL list. `spawn_batch` appears when either pool is usable; `image`
    /// stays hidden when its own toggle is off.
    @Test
    func autoMode_customAgentSurfacesSpawnOnlyWithToggleAndTargets() async {
        await withSubagentSandbox {
            let helperID = UUID(uuidString: "40000000-0000-4000-8000-000000000001")!
            // Agent pool only → spawn_agent, not spawn_model.
            let withAgents = Set(
                SystemPromptComposer.resolveTools(
                    snapshot: makeSnapshot(
                        spawnDelegationEnabled: true,
                        spawnableAgentIDs: [helperID]
                    ),
                    executionMode: .none
                ).map { $0.function.name }
            )
            #expect(withAgents.contains("spawn_agent"))
            #expect(!withAgents.contains("spawn_model"))
            #expect(withAgents.contains("spawn_batch"))
            #expect(!withAgents.contains("image"))

            // Model pool only → spawn_model, not spawn_agent.
            let remoteModelIds = [
                "openai-chatgpt/gpt-5.6-sol",
                "anthropic/claude-opus-4-8",
            ]
            let modelTools = SystemPromptComposer.resolveTools(
                snapshot: makeSnapshot(
                    spawnDelegationEnabled: true,
                    spawnableModelNames: remoteModelIds
                ),
                executionMode: .none
            )
            let withModels = Set(modelTools.map { $0.function.name })
            #expect(withModels.contains("spawn_model"))
            #expect(!withModels.contains("spawn_agent"))
            #expect(withModels.contains("spawn_batch"))
            #expect(spawnModelEnum(modelTools) == remoteModelIds)

            // Toggle on but BOTH lists empty → nothing to spawn → both hidden.
            let noTargets = Set(
                SystemPromptComposer.resolveTools(
                    snapshot: makeSnapshot(
                        spawnDelegationEnabled: true,
                        spawnableAgentIDs: []
                    ),
                    executionMode: .none
                ).map { $0.function.name }
            )
            #expect(!noTargets.contains("spawn_agent"))
            #expect(!noTargets.contains("spawn_model"))
            #expect(!noTargets.contains("spawn_batch"))
        }
    }

    @Test("UUID-backed remote spawn targets stay distinct in single and batch schemas")
    func canonicalRemoteTargetsStayDistinctInSchemas() async {
        await withSubagentSandbox {
            let first = SpawnRemoteModelIdentity.make(
                providerId: UUID(uuidString: "C9412118-D6C8-4BC0-90D9-5C686C5A54C8")!,
                modelId: "vendor/shared-model"
            )!
            let second = SpawnRemoteModelIdentity.make(
                providerId: UUID(uuidString: "E25C477F-E30D-4D8F-9D91-3400F16401D8")!,
                modelId: "vendor/shared-model"
            )
            #expect(second != nil)
            guard let second else { return }
            let tools = SystemPromptComposer.resolveTools(
                snapshot: makeSnapshot(
                    spawnDelegationEnabled: true,
                    spawnableModelNames: [first, second]
                ),
                executionMode: .none
            )

            #expect(spawnModelEnum(tools) == [first, second])
            #expect(spawnBatchTargetEnum(tools) == [first, second])
        }
    }

    @Test("frozen delegation schema stays byte-stable while launcher settings are unchanged")
    func frozenDelegationSchemaIsStableForUnchangedSettings() async {
        await withSubagentSandbox {
            let researcherID = Agent.builtInAgents.first!.id
            let config = SubagentConfiguration(
                spawnableAgentIDs: [researcherID],
                budgets: SubagentBudgets(maxParallelSpawns: 4),
                spawnableModelNames: [
                    "anthropic/claude-opus-4-8",
                    "local/ornith-9b",
                ]
            )
            saveServerBatchLimit(4)
            SubagentConfigurationStore.save(config)

            let snapshot = makeSnapshotForDefaultAgent()
            let first = SystemPromptComposer.resolveTools(
                snapshot: snapshot,
                executionMode: .none
            )
            let frozenFollowup = SystemPromptComposer.resolveTools(
                snapshot: snapshot,
                executionMode: .none,
                frozenAlwaysLoadedNames: Set(first.map(\.function.name)),
                frozenToolSpecs: first
            )

            #expect(spawnModelEnum(first) == spawnModelEnum(frozenFollowup))
            #expect(spawnBatchTargetEnum(first) == spawnBatchTargetEnum(frozenFollowup))
            #expect(spawnBatchMaxItems(first) == 4)
            #expect(spawnBatchMaxItems(frozenFollowup) == 4)
            #expect(
                PromptPrefixHasher.hash(systemContent: "prefix", tools: first)
                    == PromptPrefixHasher.hash(
                        systemContent: "prefix",
                        tools: frozenFollowup
                    )
            )
        }
    }

    @Test("current delegation constraints override stale frozen spawn schemas")
    func currentDelegationConstraintsOverrideFrozenSpecs() async {
        await withSubagentSandbox {
            let manager = AgentManager.shared
            let oldAgent = Agent(
                name: "Stale delegation target",
                defaultModel: "local/old-agent-model"
            )
            let newAgent = Agent(
                name: "Fresh delegation target",
                defaultModel: "local/new-agent-model"
            )
            manager.add(oldAgent)
            manager.add(newAgent)
            let original = SubagentConfiguration(
                spawnableAgentIDs: [oldAgent.id],
                budgets: SubagentBudgets(maxParallelSpawns: 2),
                spawnableModelNames: ["local/old-model"]
            )
            saveServerBatchLimit(2)
            SubagentConfigurationStore.save(original)

            let snapshot = makeSnapshotForDefaultAgent()
            let frozen = SystemPromptComposer.resolveTools(
                snapshot: snapshot,
                executionMode: .none
            )
            #expect(spawnModelEnum(frozen) == ["local/old-model"])
            #expect(spawnBatchTargetEnum(frozen) == [oldAgent.id.uuidString, "local/old-model"])
            #expect(spawnBatchMaxItems(frozen) == 2)

            let updated = SubagentConfiguration(
                spawnableAgentIDs: [newAgent.id],
                budgets: SubagentBudgets(maxParallelSpawns: 6),
                spawnableModelNames: [
                    "anthropic/claude-opus-4-8",
                    "local/new-model",
                ]
            )
            saveServerBatchLimit(6)
            SubagentConfigurationStore.save(updated)

            let refreshed = SystemPromptComposer.resolveTools(
                snapshot: snapshot,
                executionMode: .none,
                frozenAlwaysLoadedNames: Set(frozen.map(\.function.name)),
                frozenToolSpecs: frozen
            )

            #expect(
                spawnModelEnum(refreshed)
                    == ["anthropic/claude-opus-4-8", "local/new-model"]
            )
            #expect(
                spawnBatchTargetEnum(refreshed)
                    == [
                        newAgent.id.uuidString,
                        "anthropic/claude-opus-4-8",
                        "local/new-model",
                    ]
            )
            #expect(spawnBatchMaxItems(refreshed) == 6)
            #expect(!spawnBatchTargetEnum(refreshed).contains(oldAgent.id.uuidString))
            #expect(!spawnBatchTargetEnum(refreshed).contains("local/old-model"))
            #expect(
                PromptPrefixHasher.hash(systemContent: "prefix", tools: refreshed)
                    != PromptPrefixHasher.hash(systemContent: "prefix", tools: frozen)
            )
            _ = await manager.delete(id: oldAgent.id)
            _ = await manager.delete(id: newAgent.id)
        }
    }

    @Test("legacy snapshots use Server concurrency instead of a stale Spawn mirror")
    func legacySnapshotFallbackUsesCanonicalServerBatchLimit() async {
        await withSubagentSandbox {
            let researcherID = Agent.builtInAgents.first!.id
            saveServerBatchLimit(2)
            SubagentConfigurationStore.save(
                SubagentConfiguration(
                    spawnableAgentIDs: [researcherID],
                    budgets: SubagentBudgets(maxParallelSpawns: 7)
                )
            )
            #expect(
                SubagentConfigurationStore.snapshot().budgets
                    .maxParallelSpawns == 7
            )

            // Hand-built snapshots intentionally omit spawnConfiguration,
            // exercising the source-compatible fallback used by older tests
            // and legacy callers rather than production capture(...).
            let tools = SystemPromptComposer.resolveTools(
                snapshot: makeSnapshot(
                    spawnDelegationEnabled: true,
                    spawnableAgentIDs: [researcherID]
                ),
                executionMode: .none
            )
            let resolvedLimit = spawnBatchMaxItems(tools)
            let guidance = SystemPromptTemplates.spawnGuidance(
                agents: [],
                models: [],
                availableToolNames: [SubagentCapabilityRegistry.spawnBatchToolName],
                maxParallel: resolvedLimit ?? -1
            )

            #expect(resolvedLimit == 2)
            #expect(guidance.contains("at most 2 jobs in one batch"))
            #expect(!guidance.contains("at most 7 jobs in one batch"))
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
            SubagentConfiguration(spawnableAgentIDs: [UUID()], imageDelegationEnabled: true)
        )
        let names = Set(
            SystemPromptComposer.resolveTools(
                snapshot: makeSnapshot(
                    spawnDelegationEnabled: false,
                    imageEnabled: false,
                    spawnableAgentIDs: []
                ),
                executionMode: .none
            ).map { $0.function.name }
        )
        #expect(!names.contains("image"))
        #expect(!names.contains("spawn_agent"))
        #expect(!names.contains("spawn_model"))
        #expect(!names.contains("spawn_batch"))
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
