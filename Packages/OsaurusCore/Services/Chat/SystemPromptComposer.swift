//
//  SystemPromptComposer.swift
//  osaurus
//
//  Builder for structured system prompt assembly. Provides low-level
//  section-by-section composition plus the high-level `composeChatContext`
//  entry point that handles the full pipeline.
//
//  Compact prompt selection is automatic: pass the model ID and the composer
//  resolves whether to use compact or full prompt variants via isLocalModel.
//

import Foundation

// MARK: - SystemPromptComposer

/// Assembles system prompt sections in order, producing both the rendered
/// prompt string and a `PromptManifest` for budget tracking and caching.
public struct SystemPromptComposer: Sendable {

    private var sections: [PromptSection] = []

    public init() {}

    // MARK: - Low-Level API

    public mutating func append(_ section: PromptSection) {
        guard !section.isEmpty else { return }
        sections.append(section)
    }

    public func render() -> String {
        sections
            .map { $0.content.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    public func manifest() -> PromptManifest {
        PromptManifest(sections: sections.filter { !$0.isEmpty })
    }

    @MainActor
    public mutating func appendBasePrompt(agentId: UUID) {
        let raw = AgentManager.shared.effectiveSystemPrompt(for: agentId)
        let effective = SystemPromptTemplates.effectiveBasePrompt(raw)
        append(.static(id: "base", label: "Base Prompt", content: effective))
    }

    // MARK: - Memory Assembly

    /// Assemble the memory snippet for an agent. Returns `nil` when memory
    /// is disabled, blank, or empty after trimming. Centralised so chat,
    /// work, and HTTP paths all produce the same output.
    static func assembleMemorySection(
        agentId: String,
        query: String? = nil
    ) async -> String? {
        let config = MemoryConfigurationStore.load()
        let trimmedQuery = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let assembled = await MemoryContextAssembler.assembleContext(
            agentId: agentId,
            config: config,
            query: trimmedQuery
        )
        let trimmed = assembled.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : assembled
    }

    // MARK: - High-Level API

    /// Compose the full chat context: prompt + tools + manifest in one call.
    ///
    /// `query` is used to seed pre-flight capability search. If `query` is
    /// empty, the most recent `"user"` message in `messages` is used as a
    /// fallback so retries / regenerations still drive preflight.
    ///
    /// Pass `cachedPreflight` from a per-session `SessionToolState` to skip
    /// the LLM-based selection (it only ever needs to run on the first send
    /// of a session). Pass `additionalToolNames` to merge tools the agent has
    /// loaded mid-session via `capabilities_load`, so they survive across
    /// subsequent composes.
    @MainActor
    static func composeChatContext(
        agentId: UUID,
        executionMode: ExecutionMode,
        model: String? = nil,
        query: String = "",
        messages: [ChatMessage] = [],
        toolsDisabled: Bool = false,
        cachedPreflight: PreflightResult? = nil,
        additionalToolNames: Set<String> = [],
        frozenAlwaysLoadedNames: Set<String>? = nil,
        trace: TTFTTrace? = nil
    ) async -> ComposedContext {
        trace?.mark("compose_context_start")
        let composer = forChat(agentId: agentId, executionMode: executionMode, model: model)
        let result = await finalizeContext(
            composer: composer,
            agentId: agentId,
            executionMode: executionMode,
            query: resolvePreflightQuery(query: query, messages: messages),
            toolsDisabled: toolsDisabled,
            cachedPreflight: cachedPreflight,
            additionalToolNames: additionalToolNames,
            frozenAlwaysLoadedNames: frozenAlwaysLoadedNames,
            model: model,
            trace: trace
        )
        trace?.mark("compose_context_done")
        return result
    }

    /// Derive the effective preflight query: prefer the explicit `query`, else
    /// the most recent user message text. Returns "" if neither is available.
    static func resolvePreflightQuery(query: String, messages: [ChatMessage]) -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        for msg in messages.reversed() where msg.role == "user" {
            if let content = msg.content?.trimmingCharacters(in: .whitespacesAndNewlines),
                !content.isEmpty
            {
                return content
            }
        }
        return ""
    }

    /// Shared pipeline: assemble memory (returned separately) + preflight +
    /// skills + resolve tools + build ComposedContext.
    ///
    /// Memory is intentionally NOT appended into the system prompt. It is
    /// surfaced on `ComposedContext.memorySection` so callers prepend it to
    /// the latest user message — that keeps the system prompt byte-stable
    /// across turns once preflight is cached, which lets the MLX paged KV
    /// cache reuse the entire conversation prefix.
    @MainActor
    private static func finalizeContext(
        composer: SystemPromptComposer,
        agentId: UUID,
        executionMode: ExecutionMode,
        query: String,
        toolsDisabled: Bool,
        cachedPreflight: PreflightResult? = nil,
        additionalToolNames: Set<String> = [],
        frozenAlwaysLoadedNames: Set<String>? = nil,
        model: String? = nil,
        trace: TTFTTrace? = nil
    ) async -> ComposedContext {
        var comp = composer

        let effectiveToolsOff = toolsDisabled || AgentManager.shared.effectiveToolsDisabled(for: agentId)
        let memoryOff = AgentManager.shared.effectiveMemoryDisabled(for: agentId)
        let autonomousEnabled = AgentManager.shared.effectiveAutonomousExec(for: agentId)?.enabled == true
        let toolMode = AgentManager.shared.effectiveToolSelectionMode(for: agentId)

        // Memory is assembled here but returned separately (see ComposedContext.memorySection).
        // We deliberately do NOT pass `query` so the cached memory snapshot
        // can be reused even when the user's wording shifts — preserves the
        // pre-split behaviour and avoids a per-turn embedding lookup.
        trace?.mark("memory_start")
        let memorySection: String? =
            memoryOff
            ? nil
            : await assembleMemorySection(agentId: agentId.uuidString)
        trace?.mark("memory_done")

        // Surface a "sandbox unavailable" notice when the agent wants
        // sandbox tools but registration couldn't provide them — otherwise
        // the model hallucinates sandbox calls that never get a result.
        if !executionMode.usesSandboxTools,
            autonomousEnabled,
            let reason = SandboxToolRegistrar.shared.unavailabilityReason(for: agentId)
        {
            comp.append(
                .dynamic(
                    id: "sandboxUnavailable",
                    label: "Sandbox Unavailable",
                    content: Self.sandboxUnavailableNotice(reason: reason)
                )
            )
            trace?.set("sandboxUnavailable", reason.kind.rawValue)
        }

        let preflight: PreflightResult
        if let cachedPreflight {
            preflight = cachedPreflight
            trace?.set("preflightSource", "cached")
        } else if !effectiveToolsOff && toolMode == .auto && !query.isEmpty {
            let mode = ChatConfigurationStore.load().preflightSearchMode ?? .balanced
            trace?.mark("preflight_search_start")
            preflight = await PreflightCapabilitySearch.search(query: query, mode: mode, agentId: agentId)
            trace?.mark("preflight_search_done")
            trace?.set("preflightSource", "fresh")
        } else {
            preflight = .empty
            trace?.set("preflightSource", "skipped")
        }

        if toolMode == .manual,
            let section = await SkillManager.shared.manualSkillPromptSection(for: agentId)
        {
            comp.append(.dynamic(id: "skills", label: "Skills", content: section))
        }

        trace?.mark("resolve_tools_start")
        let tools = resolveTools(
            agentId: agentId,
            executionMode: executionMode,
            toolsDisabled: effectiveToolsOff,
            preflight: preflight,
            additionalToolNames: additionalToolNames,
            frozenAlwaysLoadedNames: frozenAlwaysLoadedNames
        )
        trace?.mark("resolve_tools_done")
        // Capture the always-loaded names present in this turn's schema so
        // callers can stash the snapshot for the next turn. When a snapshot
        // was supplied, just echo it; otherwise compute fresh from the
        // registry. The transient `sandbox_init_pending` placeholder is
        // dropped from a fresh snapshot so it doesn't pin into future turns
        // — see the `filterFrozen` carve-outs in `resolveTools` for why.
        let alwaysLoadedNames: Set<String>
        if let frozenAlwaysLoadedNames {
            alwaysLoadedNames = frozenAlwaysLoadedNames
        } else {
            let live = ToolRegistry.shared.alwaysLoadedSpecs(mode: executionMode)
                .map { $0.function.name }
            let resolved = Set(tools.map { $0.function.name })
            alwaysLoadedNames = Set(live)
                .intersection(resolved)
                .subtracting([BuiltinSandboxTools.initPendingToolName])
        }

        // Plugin Companions: when preflight picked a tool from a plugin,
        // surface the plugin's *other* enabled tools and bundled skill as
        // a compact teaser. The model uses `capabilities_load` to pull
        // them in on demand — so the schema stays small this turn but
        // the model knows what's reachable. Gated on auto-mode (preflight
        // only runs in auto) and on the presence of `capabilities_load`
        // (the section instructs the model to call it). Rendering itself
        // skips when `companions` is empty, so this just decides whether
        // to even ask for a section.
        if toolMode == .auto,
            !effectiveToolsOff,
            !preflight.companions.isEmpty,
            tools.contains(where: { $0.function.name == "capabilities_load" }),
            let companionsSection = PreflightCompanions.render(preflight.companions)
        {
            comp.append(
                .dynamic(
                    id: "pluginCompanions",
                    label: "Plugin Companions",
                    content: companionsSection
                )
            )
            trace?.set("pluginCompanions", String(preflight.companions.count))
        }

        // Agent-loop guidance: short cheat-sheet for the chat-layer-
        // intercepted tools (todo / complete / clarify / share_artifact).
        // Gated on at least one of those names appearing in the resolved
        // schema — in practice that's every chat where tools are on, but
        // the gate keeps tools-off sessions from carrying dead text.
        // Static section so it joins the cached prefix.
        if !effectiveToolsOff {
            let resolvedNames = Set(tools.map { $0.function.name })
            let loopNames: Set<String> = ["todo", "complete", "clarify", "share_artifact"]
            if !resolvedNames.isDisjoint(with: loopNames) {
                comp.append(
                    .static(
                        id: "agentLoopGuidance",
                        label: "Agent Loop",
                        content: SystemPromptTemplates.agentLoopGuidance
                    )
                )
            }
        }

        // Capability-discovery nudge: explain how to recover when the
        // current tool kit is incomplete. Gated to auto mode + presence of
        // `capabilities_search` so manual-mode agents and tools-disabled
        // sessions don't see irrelevant guidance. Static section so it
        // contributes to the cached prefix.
        if toolMode == .auto,
            !effectiveToolsOff,
            tools.contains(where: { $0.function.name == "capabilities_search" })
        {
            comp.append(
                .static(
                    id: "capabilityNudge",
                    label: "Capability Discovery",
                    content: SystemPromptTemplates.capabilityDiscoveryNudge
                )
            )
        }

        // Per-model-family nudge — small, targeted blocks for known model
        // weaknesses (Gemma over-enumerates, GPT under-acts, etc.). Static
        // section so it joins the cached prefix. We deliberately ship NO
        // universal "agentic workflow" addendum: it inflates context and
        // encourages tool enumeration. See ModelFamilyGuidance.swift.
        if !effectiveToolsOff,
            let familyGuidance = ModelFamilyGuidance.guidance(forModelId: model)
        {
            comp.append(
                .static(
                    id: "modelFamilyGuidance",
                    label: "Model Family Guidance",
                    content: familyGuidance
                )
            )
        }

        // Plugin-creator backstop: only inject when the agent literally
        // has NO dynamic tools available (no MCP / plugin / sandbox-plugin
        // installed) AND nothing was resolved this turn. The narrower gate
        // prevents the skill from being injected on every "this turn just
        // doesn't need a plugin" case for users who already have plugin
        // tools installed — which would bias the model toward writing new
        // plugins instead of using the ones it has.
        //
        // We also fire during sandbox init-pending (autonomousEnabled but
        // sandbox tools haven't registered yet). Without that, the agent
        // had no signal that plugin creation would be available once the
        // container finished provisioning — `pluginCreatorSkillSection`
        // already gates on `canCreatePlugins`, so this stays correct.
        let sandboxAvailable = executionMode.usesSandboxTools || autonomousEnabled
        if !effectiveToolsOff,
            sandboxAvailable,
            ToolRegistry.shared.dynamicCatalogIsEmpty(),
            !hasDynamicTools(toolMode: toolMode, preflight: preflight, agentId: agentId),
            let pluginCreator = await PreflightCapabilitySearch.pluginCreatorSkillSection(for: agentId)
        {
            comp.append(.dynamic(id: "pluginCreator", label: "Plugin Creator", content: pluginCreator))
            trace?.set("pluginCreatorInjected", "1")
        }

        let manifest = comp.manifest()
        let toolNames = tools.map { $0.function.name }
        debugLog("[Context] \(manifest.debugDescription)")
        emitToolDiagnostics(
            tools: tools,
            toolMode: toolMode,
            preflight: preflight,
            executionMode: executionMode,
            autonomousEnabled: autonomousEnabled,
            effectiveToolsOff: effectiveToolsOff,
            frozenAlwaysLoadedNames: frozenAlwaysLoadedNames,
            additionalToolNames: additionalToolNames,
            trace: trace
        )

        let rendered = comp.render()
        trace?.set("systemPromptChars", rendered.count)
        trace?.set("toolCount", tools.count)
        trace?.set("preflightItems", preflight.items.count)

        return ComposedContext(
            prompt: rendered,
            manifest: manifest,
            tools: tools,
            toolTokens: ToolRegistry.shared.totalEstimatedTokens(for: tools),
            preflightItems: preflight.items,
            preflight: preflight,
            memorySection: memorySection,
            alwaysLoadedNames: alwaysLoadedNames,
            cacheHint: manifest.staticPrefixHash(toolNames: toolNames),
            staticPrefix: manifest.staticPrefixContent
        )
    }

    /// Build the "sandbox not ready" notice, branching on failure kind so
    /// transient startup races read as "try again" while hard failures
    /// suggest the user open the Sandbox settings panel.
    private static func sandboxUnavailableNotice(
        reason: SandboxToolRegistrar.UnavailabilityReason
    ) -> String {
        let (situation, guidance): (String, String) = {
            switch reason.kind {
            case .containerUnavailable:
                return (
                    "The sandbox container is still starting up — the user enabled "
                        + "autonomous execution but the container hasn't reported running yet.",
                    "Help with whatever doesn't need sandbox tools (explain, draft files "
                        + "inline, ask a clarifying question). Mention that the sandbox is "
                        + "still spinning up so the user can retry once it comes online."
                )
            case .startupFailed:
                return (
                    "The sandbox container failed to start. Detail: \(reason.message)",
                    "Tell the user the sandbox couldn't start and suggest opening the "
                        + "Sandbox settings panel to retry or inspect the failure. Then "
                        + "help with whatever doesn't need sandbox tools."
                )
            case .provisioningFailed:
                return (
                    "The sandbox container is running, but provisioning this agent "
                        + "inside it failed. Detail: \(reason.message)",
                    "Tell the user provisioning failed and suggest toggling autonomous "
                        + "execution off and on, or restarting the app. Then help with "
                        + "anything that doesn't need sandbox tools."
                )
            }
        }()

        return """
            ## Sandbox not ready

            \(situation)

            Sandbox tools (file IO, shell, etc.) are NOT in your tool list this \
            turn. Do not invent or guess sandbox tool names — they will not run.

            \(guidance)
            """
    }

    /// Emit structured tool diagnostics so silent "model can't see the
    /// tools" failures are visible in logs and traces.
    ///
    /// Single line carries every dimension that decides the schema:
    ///   - `mode` / `executionMode`: requested + resolved
    ///   - `source`: where the tools came from this turn
    ///   - `count` / `names`: actual schema delivered
    ///   - `frozen` / `additive` / `loaded`: snapshot bookkeeping —
    ///     `frozen` is the snapshot size from turn 1, `additive` is the
    ///     count of late-arriving sandbox tools that joined via the
    ///     carve-out, `loaded` is the running `capabilities_load` union.
    @MainActor
    private static func emitToolDiagnostics(
        tools: [Tool],
        toolMode: ToolSelectionMode,
        preflight: PreflightResult,
        executionMode: ExecutionMode,
        autonomousEnabled: Bool,
        effectiveToolsOff: Bool,
        frozenAlwaysLoadedNames: Set<String>?,
        additionalToolNames: Set<String>,
        trace: TTFTTrace?
    ) {
        let toolSource = resolveToolSource(
            toolMode: toolMode,
            preflight: preflight,
            effectiveToolsOff: effectiveToolsOff
        )
        let sandboxStatus = String(describing: SandboxManager.State.shared.status)
        let sortedNames = tools.map { $0.function.name }.sorted()
        let frozenSize = frozenAlwaysLoadedNames?.count ?? 0
        let additiveCount = countAdditiveSandboxTools(
            in: sortedNames,
            frozen: frozenAlwaysLoadedNames
        )

        debugLog(
            "[Context:tools] mode=\(toolMode) source=\(toolSource) autonomous=\(autonomousEnabled) sandboxStatus=\(sandboxStatus) executionMode=\(executionMode) count=\(tools.count) frozen=\(frozenSize) additive=\(additiveCount) loaded=\(additionalToolNames.count) names=[\(sortedNames.joined(separator: ", "))]"
        )
        emitAutonomousWarningsIfNeeded(
            tools: tools,
            executionMode: executionMode,
            autonomousEnabled: autonomousEnabled,
            sandboxStatus: sandboxStatus
        )
        trace?.set("toolMode", String(describing: toolMode))
        trace?.set("toolSource", toolSource)
        trace?.set("autonomous", autonomousEnabled ? "1" : "0")
        trace?.set("sandboxStatus", sandboxStatus)
        trace?.set("toolFrozen", frozenSize)
        trace?.set("toolAdditive", additiveCount)
        trace?.set("toolLoaded", additionalToolNames.count)
    }

    /// Where this turn's tool list came from. Order matters: `disabled`
    /// trumps everything; preflight trumps manual when both are populated
    /// (preflight is auto-mode-only); manual trumps the always-loaded fallback.
    private static func resolveToolSource(
        toolMode: ToolSelectionMode,
        preflight: PreflightResult,
        effectiveToolsOff: Bool
    ) -> String {
        if effectiveToolsOff { return "disabled" }
        if !preflight.toolSpecs.isEmpty { return "preflight" }
        return toolMode == .manual ? "manual" : "alwaysLoaded"
    }

    /// Count how many resolved tools entered the schema via the additive
    /// sandbox carve-out (not in the frozen snapshot but registered as a
    /// built-in sandbox tool late). Returns 0 on the first turn (no snapshot).
    @MainActor
    private static func countAdditiveSandboxTools(
        in toolNames: [String],
        frozen: Set<String>?
    ) -> Int {
        guard let frozen else { return 0 }
        let liveSandboxNames = ToolRegistry.shared.builtInSandboxToolNamesSnapshot
        return toolNames.reduce(into: 0) { count, name in
            if !frozen.contains(name), liveSandboxNames.contains(name) {
                count += 1
            }
        }
    }

    /// Surface the two failure shapes that look identical to the user
    /// (model produced no useful response) but have different root causes:
    /// empty tool list (autonomous on but registry empty) vs sandbox tools
    /// missing while autonomous is on (provisioning likely threw).
    private static func emitAutonomousWarningsIfNeeded(
        tools: [Tool],
        executionMode: ExecutionMode,
        autonomousEnabled: Bool,
        sandboxStatus: String
    ) {
        guard autonomousEnabled else { return }
        if tools.isEmpty {
            debugLog(
                "[Context:tools] WARNING: autonomous execution is enabled but the resolved tool list is empty. The model will not be able to act on the user's request. sandboxStatus=\(sandboxStatus)."
            )
        } else if !executionMode.usesSandboxTools {
            debugLog(
                "[Context:tools] WARNING: autonomous execution is enabled but real sandbox tools are not registered — system prompt will carry the 'Sandbox not ready' notice. sandboxStatus=\(sandboxStatus). If sandboxStatus is 'running', SandboxAgentProvisioner.ensureProvisioned likely threw — check earlier [Sandbox] log lines."
            )
        }
    }

    /// Did the current request resolve any dynamic (non-always-loaded,
    /// non-sandbox-builtin) tool via preflight or manual selection? Used by
    /// `finalizeContext` to decide whether to inject the plugin-creator
    /// fallback skill.
    @MainActor
    private static func hasDynamicTools(
        toolMode: ToolSelectionMode,
        preflight: PreflightResult,
        agentId: UUID
    ) -> Bool {
        switch toolMode {
        case .auto:
            return !preflight.toolSpecs.isEmpty
        case .manual:
            let names = AgentManager.shared.effectiveManualToolNames(for: agentId) ?? []
            return !names.isEmpty
        }
    }

    /// Resolve the full tool set for a request: built-in + preflight/manual,
    /// plus any tools the agent has loaded mid-session via `capabilities_load`,
    /// deduped, then sorted into a stable canonical order.
    ///
    /// Manual mode is strict: only the user's explicitly selected tools are
    /// included, with one exception — when `executionMode` requires sandbox
    /// tools (autonomous execution), the sandbox built-ins are always added so
    /// the agent can act. Group 1 (selection) and Group 2 (sandbox) are
    /// orthogonal: enabling sandbox does not weaken the manual selection in
    /// any other way.
    ///
    /// `additionalToolNames` is honoured in both modes so tools the agent has
    /// already loaded mid-session survive across composes (the chat / work
    /// session caches feed this from their `SessionToolState`).
    ///
    /// Output is sorted via `canonicalToolOrder` so the chat-template-rendered
    /// `<tools>` block is byte-stable across sends — required for the MLX
    /// paged KV cache to reuse the prefix.
    @MainActor
    static func resolveTools(
        agentId: UUID,
        executionMode: ExecutionMode,
        toolsDisabled: Bool = false,
        preflight: PreflightResult = .empty,
        additionalToolNames: Set<String> = [],
        frozenAlwaysLoadedNames: Set<String>? = nil
    ) -> [Tool] {
        guard !toolsDisabled else { return [] }

        let toolMode = AgentManager.shared.effectiveToolSelectionMode(for: agentId)
        let isManual = toolMode == .manual

        var byName: [String: Tool] = [:]

        func add(_ specs: [Tool]) {
            for spec in specs where byName[spec.function.name] == nil {
                byName[spec.function.name] = spec
            }
        }

        // Filter rule for always-loaded specs:
        //   - `sandbox_init_pending` is never returned to the model (apology
        //     stub crowds the schema; the system-prompt notice already covers
        //     "sandbox not ready"),
        //   - on turn 1 (`frozenAlwaysLoadedNames == nil`) keep everything,
        //   - on turn N intersect with the snapshot to keep the schema
        //     byte-stable for KV-cache reuse, plus an additive carve-out so
        //     real sandbox tools that registered late (container booted
        //     between turn 1 and now) join the schema instead of being
        //     suppressed forever as "new mid-session tools".
        // Late-arriving plugin / MCP tools still need explicit
        // `capabilities_load` to appear — that path is the only sanctioned
        // way to grow the dynamic surface mid-session.
        let liveSandboxNames = ToolRegistry.shared.builtInSandboxToolNamesSnapshot
        let filtered: ([Tool]) -> [Tool] = { specs in
            specs.filter { spec in
                let name = spec.function.name
                if name == BuiltinSandboxTools.initPendingToolName { return false }
                guard let frozen = frozenAlwaysLoadedNames else { return true }
                return frozen.contains(name) || liveSandboxNames.contains(name)
            }
        }

        // Always-loaded baseline: built-ins (agent loop, share_artifact,
        // capability discovery, render_chart, search_memory) + sandbox/
        // folder runtime when the mode is active. Manual mode then layers
        // user picks on top; auto mode layers preflight specs on top.
        // Manual mode opts out of the LLM-driven preflight only — it does
        // NOT strip the always-loaded surface (the chat layer depends on
        // the loop tools).
        add(filtered(ToolRegistry.shared.alwaysLoadedSpecs(mode: executionMode)))

        if isManual {
            if let manualNames = AgentManager.shared.effectiveManualToolNames(for: agentId) {
                add(ToolRegistry.shared.specs(forTools: manualNames))
            }
        } else {
            add(preflight.toolSpecs)
        }

        if !additionalToolNames.isEmpty {
            add(ToolRegistry.shared.specs(forTools: Array(additionalToolNames)))
        }

        return canonicalToolOrder(Array(byName.values))
    }

    /// Stable order:
    ///   0. Agent-loop tools (`todo`, `complete`, `clarify`, `share_artifact`)
    ///      in fixed order. Pinned at the very top so a model scanning the
    ///      schema sees the loop API first; also keeps the rendered byte
    ///      sequence stable across sends regardless of what plugins or MCP
    ///      providers register later (KV-cache reuse).
    ///   1. Built-in sandbox tools (alphabetical).
    ///   2. Capability discovery tools (`capabilities_search`, then
    ///      `capabilities_load`) in fixed order so the discovery tool sits
    ///      ahead of the loader in the model's view.
    ///   3. Everything else, alphabetical.
    @MainActor
    static func canonicalToolOrder(_ tools: [Tool]) -> [Tool] {
        let sandboxNames = ToolRegistry.shared.builtInSandboxToolNamesSnapshot
        let loopIndex = Dictionary(
            uniqueKeysWithValues: ["todo", "complete", "clarify", "share_artifact"]
                .enumerated().map { ($1, $0) }
        )
        let capabilityIndex = Dictionary(
            uniqueKeysWithValues: ["capabilities_search", "capabilities_load"]
                .enumerated().map { ($1, $0) }
        )

        // Sort key: (bucket, intra-bucket order, name). `Int.max` for
        // alphabetical-only buckets collapses the index dimension to a
        // no-op so the name is the only tiebreaker.
        func sortKey(_ tool: Tool) -> (Int, Int, String) {
            let name = tool.function.name
            if let order = loopIndex[name] { return (0, order, name) }
            if sandboxNames.contains(name) { return (1, .max, name) }
            if let order = capabilityIndex[name] { return (2, order, name) }
            return (3, .max, name)
        }

        return tools.sorted { sortKey($0) < sortKey($1) }
    }

    /// Compose from a pre-resolved base with an optional dynamic skills section.
    public static func composePrompt(
        base: String,
        skillSection: String? = nil
    ) -> (prompt: String, manifest: PromptManifest) {
        var composer = SystemPromptComposer()
        composer.append(.static(id: "base", label: "System Prompt", content: base))
        if let section = skillSection {
            composer.append(.dynamic(id: "skills", label: "Skills", content: section))
        }
        return (composer.render(), composer.manifest())
    }

    /// Compose agent base prompt and inject into an existing message array.
    /// Memory is now prepended to the latest user message instead of the
    /// system prompt so the system message stays byte-stable across turns.
    /// Returns `(cacheHint, staticPrefix)` for the caller to set on the request.
    @discardableResult
    static func injectAgentContext(
        agentId: UUID,
        query: String = "",
        into messages: inout [ChatMessage]
    ) async -> (cacheHint: String, staticPrefix: String) {
        // only forChat needs @MainActor. so hop there briefly and return the value type composer.
        // Memory assembly itself runs on the cooperative thread pool so the
        // app stays responsive during HTTP requests.
        let composer = await MainActor.run { forChat(agentId: agentId, executionMode: .none) }
        let memoryOff = await AgentManager.shared.effectiveMemoryDisabled(for: agentId)

        let memorySection: String? =
            memoryOff
            ? nil
            : await assembleMemorySection(
                agentId: agentId.uuidString,
                query: query
            )

        let manifest = composer.manifest()
        let rendered = composer.render()
        debugLog("[Context:inject] \(manifest.debugDescription)")
        if !rendered.isEmpty {
            injectSystemContent(rendered, into: &messages)
        }
        injectMemoryPrefix(memorySection, into: &messages)
        return (manifest.staticPrefixHash(toolNames: []), manifest.staticPrefixContent)
    }

    // MARK: - Compact Resolution

    /// Resolve whether to use compact prompts from an explicit model ID,
    /// falling back to the agent's configured default model.
    @MainActor
    static func resolveCompact(model: String? = nil, agentId: UUID? = nil) -> Bool {
        if let model { return SystemPromptTemplates.isLocalModel(model) }
        if let agentId, let agentModel = AgentManager.shared.effectiveModel(for: agentId) {
            return SystemPromptTemplates.isLocalModel(agentModel)
        }
        return false
    }

    // MARK: - Factory Methods

    /// Pre-loaded composer for chat mode. Compact is auto-resolved from model/agent.
    @MainActor
    public static func forChat(
        agentId: UUID,
        executionMode: ExecutionMode,
        model: String? = nil
    ) -> SystemPromptComposer {
        let compact = resolveCompact(model: model, agentId: agentId)
        return forChat(agentId: agentId, executionMode: executionMode, compact: compact)
    }

    @MainActor
    static func forChat(
        agentId: UUID,
        executionMode: ExecutionMode,
        compact: Bool
    ) -> SystemPromptComposer {
        var composer = SystemPromptComposer()
        composer.appendBasePrompt(agentId: agentId)
        if executionMode.usesSandboxTools {
            let secretNames = Array(AgentSecretsKeychain.getAllSecrets(agentId: agentId).keys)
            composer.append(
                .static(
                    id: "sandbox",
                    label: "Chat Sandbox",
                    content: SystemPromptTemplates.sandbox(compact: compact, secretNames: secretNames)
                )
            )
        } else if let folder = executionMode.folderContext {
            // Working-directory framing for `.hostFolder`. Without it the
            // model gets folder tools in its schema but no prose anchor for
            // WHERE it is, which leads to generic exploration + "I'll do X"
            // stalls. Static so it joins the cached prefix.
            composer.append(
                .static(
                    id: "folderContext",
                    label: "Working Directory",
                    content: SystemPromptTemplates.folderContext(from: folder)
                )
            )
        }
        return composer
    }

    // MARK: - Message Array Helpers

    /// Prepend a memory snippet to the latest user message instead of
    /// stuffing it into the system prompt. This keeps the system message
    /// byte-stable across turns (so the MLX paged KV cache can reuse the
    /// entire conversation prefix) and confines memory churn to the volatile
    /// user-message suffix. No-op when `memorySection` is nil/blank, no user
    /// message exists, or the latest user message is multimodal (we leave
    /// `contentParts`-bearing messages alone to avoid silently dropping
    /// images).
    static func injectMemoryPrefix(
        _ memorySection: String?,
        into messages: inout [ChatMessage]
    ) {
        guard let memorySection,
            case let trimmed = memorySection.trimmingCharacters(in: .whitespacesAndNewlines),
            !trimmed.isEmpty,
            let idx = messages.lastIndex(where: { $0.role == "user" })
        else { return }

        let existing = messages[idx]
        guard existing.contentParts == nil else { return }

        let original = existing.content ?? ""
        let prefixed = "[Memory]\n\(trimmed)\n[/Memory]\n\n\(original)"
        messages[idx] = ChatMessage(
            role: existing.role,
            content: prefixed,
            tool_calls: existing.tool_calls,
            tool_call_id: existing.tool_call_id
        )
    }

    /// Merge `content` into the message list's system role. When `prepend`
    /// is true the content lands at the top of an existing system message;
    /// false appends to the bottom. With no existing system message, a new
    /// one is inserted at index 0 in either case.
    static func mergeSystemContent(
        _ content: String,
        into messages: inout [ChatMessage],
        prepend: Bool
    ) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let idx = messages.firstIndex(where: { $0.role == "system" }),
            let existing = messages[idx].content, !existing.isEmpty
        {
            let combined = prepend ? trimmed + "\n\n" + existing : existing + "\n\n" + trimmed
            messages[idx] = ChatMessage(role: "system", content: combined)
        } else {
            messages.insert(ChatMessage(role: "system", content: trimmed), at: 0)
        }
    }

    static func injectSystemContent(_ content: String, into messages: inout [ChatMessage]) {
        mergeSystemContent(content, into: &messages, prepend: true)
    }

    static func appendSystemContent(_ content: String, into messages: inout [ChatMessage]) {
        mergeSystemContent(content, into: &messages, prepend: false)
    }
}
