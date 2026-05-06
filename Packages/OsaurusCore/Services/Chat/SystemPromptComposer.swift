//
//  SystemPromptComposer.swift
//  osaurus
//
//  Builder for structured system prompt assembly. Provides low-level
//  section-by-section composition plus the high-level `composeChatContext`
//  entry point that handles the full pipeline.
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

    /// Append the platform + persona pair from a pre-captured snapshot
    /// without re-querying `AgentManager`. Used by `finalizeContext` and
    /// `composePreviewContext` so a single MainActor read services the
    /// whole compose pipeline.
    public mutating func appendBasePrompt(systemPrompt: String) {
        append(
            .static(
                id: "platform",
                label: "Platform",
                content: SystemPromptTemplates.platformIdentity
            )
        )
        let effective = SystemPromptTemplates.effectivePersona(systemPrompt)
        append(.static(id: "persona", label: "Persona", content: effective))
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

    /// Compose the full chat context: prompt + tools + manifest in one
    /// call. Backwards-compatible positional surface; new code should
    /// reach for the `ComposeRequest`-taking overload below so the
    /// 11-param tail doesn't have to grow further.
    @MainActor
    static func composeChatContext(
        agentId: UUID,
        executionMode: ExecutionMode,
        model: String? = nil,
        query: String = "",
        messages: [ChatMessage] = [],
        toolsDisabled: Bool = false,
        cachedPreflight: PreflightResult? = nil,
        additionalToolNames: LoadedTools = [],
        frozenAlwaysLoadedNames: LoadedTools? = nil,
        trace: TTFTTrace? = nil
    ) async -> ComposedContext {
        await composeChatContext(
            ComposeRequest(
                agentId: agentId,
                executionMode: executionMode,
                model: model,
                query: query,
                messages: messages,
                toolsDisabled: toolsDisabled,
                cachedPreflight: cachedPreflight,
                additionalToolNames: additionalToolNames,
                frozenAlwaysLoadedNames: frozenAlwaysLoadedNames,
                trace: trace
            )
        )
    }

    /// Canonical entry point: every parameter rides on `ComposeRequest`
    /// so optional bits (trace, frozen snapshot, mid-session loaded
    /// names) stay grouped instead of trailing the signature.
    ///
    /// `request.query` seeds preflight capability search. If empty, the
    /// most recent `"user"` message in `request.messages` is used so
    /// retries / regenerations still drive preflight. Pass
    /// `cachedPreflight` from a per-session `SessionToolState` to skip
    /// the LLM call after turn 1. Pass `additionalToolNames` so tools
    /// the agent loaded mid-session via `capabilities_load` survive
    /// across subsequent composes.
    @MainActor
    static func composeChatContext(_ request: ComposeRequest) async -> ComposedContext {
        let trace = request.trace
        trace?.mark("compose_context_start")
        // One MainActor read services every downstream `effective*`
        // gate. Closes the race window the `PluginCreatorGate.Inputs`
        // comment used to apologise for.
        let snapshot = AgentConfigSnapshot.capture(
            agentId: request.agentId,
            requestToolsDisabled: request.toolsDisabled,
            modelOverride: request.model
        )
        let composer = forChat(
            snapshot: snapshot,
            agentId: request.agentId,
            executionMode: request.executionMode
        )
        let result = await finalizeContext(
            composer: composer,
            snapshot: snapshot,
            agentId: request.agentId,
            executionMode: request.executionMode,
            query: resolvePreflightQuery(query: request.query, messages: request.messages),
            cachedPreflight: request.cachedPreflight,
            additionalToolNames: request.additionalToolNames,
            frozenAlwaysLoadedNames: request.frozenAlwaysLoadedNames,
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
        snapshot: AgentConfigSnapshot,
        agentId: UUID,
        executionMode: ExecutionMode,
        query: String,
        cachedPreflight: PreflightResult? = nil,
        additionalToolNames: LoadedTools = [],
        frozenAlwaysLoadedNames: LoadedTools? = nil,
        trace: TTFTTrace? = nil
    ) async -> ComposedContext {
        var comp = composer
        let memorySection = await resolveMemory(snapshot: snapshot, agentId: agentId, trace: trace)
        let toolset = await resolveToolset(
            snapshot: snapshot,
            agentId: agentId,
            executionMode: executionMode,
            query: query,
            cachedPreflight: cachedPreflight,
            additionalToolNames: additionalToolNames,
            frozenAlwaysLoadedNames: frozenAlwaysLoadedNames,
            trace: trace
        )
        appendGatedSections(
            composer: &comp,
            snapshot: snapshot,
            toolset: toolset,
            agentId: agentId,
            executionMode: executionMode,
            trace: trace
        )
        let manifest = comp.manifest()
        debugLog("[Context] \(manifest.debugDescription)")
        emitToolDiagnostics(
            snapshot: snapshot,
            toolset: toolset,
            executionMode: executionMode,
            frozenAlwaysLoadedNames: frozenAlwaysLoadedNames,
            additionalToolNames: additionalToolNames,
            trace: trace
        )
        let rendered = comp.render()
        let toolNames = toolset.tools.map { $0.function.name }
        trace?.set("systemPromptChars", rendered.count)
        trace?.set("toolCount", toolset.tools.count)
        trace?.set("preflightItems", toolset.preflight.items.count)
        return ComposedContext(
            prompt: rendered,
            manifest: manifest,
            tools: toolset.tools,
            toolTokens: ToolRegistry.shared.totalEstimatedTokens(for: toolset.tools),
            preflightItems: toolset.preflight.items,
            preflight: toolset.preflight,
            memorySection: memorySection,
            alwaysLoadedNames: toolset.alwaysLoadedNames,
            cacheHint: manifest.staticPrefixHash(toolNames: toolNames),
            staticPrefix: manifest.staticPrefixContent,
            contextDisable: toolset.contextDisable
        )
    }

    /// Per-turn memory snippet, or nil when memory is disabled (either
    /// at the agent level or auto-off via the size-class). We deliberately
    /// do NOT pass `query` to the assembler so the cached memory snapshot
    /// can be reused even when the user's wording shifts.
    @MainActor
    private static func resolveMemory(
        snapshot: AgentConfigSnapshot,
        agentId: UUID,
        trace: TTFTTrace?
    ) async -> String? {
        let window = ContextSizeResolver.resolve(modelId: snapshot.model)
        let memoryOff = snapshot.memoryDisabled || window.sizeClass.disablesMemory
        guard !memoryOff else { return nil }
        trace?.mark("memory_start")
        let section = await assembleMemorySection(agentId: agentId.uuidString)
        trace?.mark("memory_done")
        return section
    }

    /// Assemble every tool-axis decision for the request: size-class
    /// auto-disable, preflight (cached or fresh), final tool set,
    /// always-loaded snapshot, and standalone-skill teasers.
    @MainActor
    private static func resolveToolset(
        snapshot: AgentConfigSnapshot,
        agentId: UUID,
        executionMode: ExecutionMode,
        query: String,
        cachedPreflight: PreflightResult?,
        additionalToolNames: LoadedTools,
        frozenAlwaysLoadedNames: LoadedTools?,
        trace: TTFTTrace?
    ) async -> ResolvedToolset {
        // Auto-disable for small-context models (Foundation et al.).
        // OR into the agent's flags so every downstream gate (preflight,
        // skills, agent loop, capability nudge, model family, plugin
        // creator) cascades correctly without each gate having to know
        // about the size class itself.
        let window = ContextSizeResolver.resolve(modelId: snapshot.model)
        let effectiveToolsOff = snapshot.toolsDisabled || window.sizeClass.disablesTools
        let contextDisable = ContextDisableInfo.from(
            sizeClass: window.sizeClass,
            modelId: snapshot.model,
            contextLength: window.contextLength,
            agentToolsOff: snapshot.toolsDisabled,
            agentMemoryOff: snapshot.memoryDisabled
        )
        if contextDisable != nil {
            trace?.set("contextSizeClass", String(describing: window.sizeClass))
        }

        let preflight = await resolvePreflight(
            snapshot: snapshot,
            agentId: agentId,
            query: query,
            effectiveToolsOff: effectiveToolsOff,
            cachedPreflight: cachedPreflight,
            trace: trace
        )

        trace?.mark("resolve_tools_start")
        let tools = resolveTools(
            snapshot: snapshot,
            executionMode: executionMode,
            toolsDisabled: effectiveToolsOff,
            preflight: preflight,
            additionalToolNames: additionalToolNames,
            frozenAlwaysLoadedNames: frozenAlwaysLoadedNames
        )
        trace?.mark("resolve_tools_done")

        let alwaysLoadedNames = resolveAlwaysLoadedNames(
            tools: tools,
            executionMode: executionMode,
            frozenAlwaysLoadedNames: frozenAlwaysLoadedNames
        )

        let skillSuggestions = await resolveSkillSuggestions(
            snapshot: snapshot,
            tools: tools,
            preflight: preflight,
            query: query,
            additionalToolNames: additionalToolNames,
            effectiveToolsOff: effectiveToolsOff,
            trace: trace
        )

        return ResolvedToolset(
            preflight: preflight,
            tools: tools,
            skillSuggestions: skillSuggestions,
            alwaysLoadedNames: alwaysLoadedNames,
            contextDisable: contextDisable,
            effectiveToolsOff: effectiveToolsOff
        )
    }

    /// Pick the preflight to use this turn: cached (skip the LLM call),
    /// fresh (auto-mode + tools on + non-empty query), or `.empty`.
    @MainActor
    private static func resolvePreflight(
        snapshot: AgentConfigSnapshot,
        agentId: UUID,
        query: String,
        effectiveToolsOff: Bool,
        cachedPreflight: PreflightResult?,
        trace: TTFTTrace?
    ) async -> PreflightResult {
        if let cachedPreflight {
            trace?.set("preflightSource", "cached")
            return cachedPreflight
        }
        guard !effectiveToolsOff, snapshot.toolMode == .auto, !query.isEmpty else {
            trace?.set("preflightSource", "skipped")
            return .empty
        }
        let mode = ChatConfigurationStore.load().preflightSearchMode ?? .balanced
        trace?.mark("preflight_search_start")
        // `snapshot.model` is forwarded as the chat-model fallback for
        // the preflight LLM call — see GitHub issue #823.
        let result = await PreflightCapabilitySearch.search(
            query: query,
            mode: mode,
            agentId: agentId,
            model: snapshot.model
        )
        trace?.mark("preflight_search_done")
        trace?.set("preflightSource", "fresh")
        return result
    }

    /// Standalone (non-plugin) skill teasers derived from the user query.
    /// Same gates as preflight (auto mode + tools on + non-empty query)
    /// plus `capabilities_load` in the schema so the loader nudge is
    /// actionable. Skills already surfaced via plugin companions or
    /// already loaded mid-session are filtered out so the model doesn't
    /// see the same name twice.
    @MainActor
    private static func resolveSkillSuggestions(
        snapshot: AgentConfigSnapshot,
        tools: [Tool],
        preflight: PreflightResult,
        query: String,
        additionalToolNames: LoadedTools,
        effectiveToolsOff: Bool,
        trace: TTFTTrace?
    ) async -> [SkillTeaser] {
        guard snapshot.toolMode == .auto, !effectiveToolsOff, !query.isEmpty,
            tools.contains(where: { $0.function.name == "capabilities_load" })
        else { return [] }
        let alreadySurfaced = Set(preflight.companions.compactMap(\.skill?.name))
            .union(additionalToolNames)
        trace?.mark("skill_suggestions_start")
        let teasers = await PreflightCompanions.deriveSkillSuggestions(
            query: query,
            alreadyLoadedSkillNames: alreadySurfaced
        )
        trace?.mark("skill_suggestions_done")
        trace?.set("skillSuggestions", String(teasers.count))
        return teasers
    }

    /// Append every gated "deterministic" prompt section given the
    /// resolved tool set + preflight.
    ///
    /// Order is deliberate — cross-cutting rules first, harness second,
    /// mode-specific capability third, recovery path last, dynamics
    /// finally. Pre-platform/persona happens in `forChat`. The full
    /// rendered prompt looks like:
    ///
    ///   1. platform                  (forChat)
    ///   2. persona                   (forChat)
    ///   3. modelFamilyGuidance       static, gated on family match
    ///   4. codeStyle                 static, gated on file-mutation tools
    ///   5. riskAware                 static, gated on file-mutation tools
    ///   6. agentLoopGuidance         static, gated on loop tools
    ///   7. sandbox / folderContext   static, mode-specific
    ///   8. capabilityNudge           static, gated on capabilities_search
    ///   9. sandboxUnavailable        dynamic, gated on registrar failure
    ///  10. pluginCompanions          dynamic, gated on preflight result
    ///  11. skillSuggestions          dynamic, gated on preflight result
    ///  12. pluginCreator             dynamic, backstop
    ///
    /// Statics come before dynamics so the cached prefix
    /// (`PromptManifest.staticPrefixContent`) reaches as far as possible —
    /// every static section above the first dynamic break joins the
    /// KV-cache reuse window.
    ///
    /// Shared between the real send path (`finalizeContext`) and the sync
    /// preview path (`composePreviewContext`) so the welcome-screen budget
    /// popover lists the same sections the next send will produce, modulo
    /// the dynamic ones it can't price ahead of time.
    ///
    /// Skills are intentionally NOT injected here — they're discovered via
    /// `capabilities_search` and pulled in via `capabilities_load` instead.
    /// Surfacing every enabled skill in the system prompt routinely blew
    /// the budget on small-context models (55k+ tokens with reference
    /// inlining); the loader path keeps the schema small and lets the
    /// model decide which skill bodies it actually needs.
    @MainActor
    private static func appendGatedSections(
        composer: inout SystemPromptComposer,
        snapshot: AgentConfigSnapshot,
        toolset: ResolvedToolset,
        agentId: UUID,
        executionMode: ExecutionMode,
        trace: TTFTTrace? = nil
    ) {
        let tools = toolset.tools
        let preflight = toolset.preflight
        let effectiveToolsOff = toolset.effectiveToolsOff
        let resolvedNames = Set(tools.map { $0.function.name })

        // ── Statics ──────────────────────────────────────────────────

        // Per-model-family nudge — small, targeted blocks for known model
        // weaknesses (Gemma over-enumerates, GPT under-acts, etc.). We
        // deliberately ship NO universal "agentic workflow" addendum: it
        // inflates context and encourages tool enumeration.
        // See ModelFamilyGuidance.swift.
        if !effectiveToolsOff,
            let familyGuidance = ModelFamilyGuidance.guidance(forModelId: snapshot.model)
        {
            composer.append(
                .static(
                    id: "modelFamilyGuidance",
                    label: "Model Family Guidance",
                    content: familyGuidance
                )
            )
        }

        // Code style + risk-aware actions — general engineering discipline
        // for any agent that can mutate the user's filesystem or run
        // arbitrary code. Sandbox tools, folder tools, and any future
        // plugin tool that writes all qualify. The set lives at the top
        // of the file so it can grow as new mutation-capable tools land.
        if !effectiveToolsOff,
            !resolvedNames.isDisjoint(with: Self.mutationToolNames)
        {
            composer.append(
                .static(
                    id: "codeStyle",
                    label: "Code Style",
                    content: SystemPromptTemplates.codeStyleGuidance
                )
            )
            composer.append(
                .static(
                    id: "riskAware",
                    label: "Risk-Aware Actions",
                    content: SystemPromptTemplates.riskAwareGuidance
                )
            )
        }

        // Agent-loop guidance: short cheat-sheet for the chat-layer-
        // intercepted tools (todo / complete / clarify / share_artifact).
        // Gated on at least one of those names appearing in the resolved
        // schema — in practice that's every chat where tools are on, but
        // the gate keeps tools-off sessions from carrying dead text.
        if !effectiveToolsOff,
            !resolvedNames.isDisjoint(with: Self.agentLoopToolNames)
        {
            composer.append(
                .static(
                    id: "agentLoopGuidance",
                    label: "Agent Loop",
                    content: SystemPromptTemplates.agentLoopGuidance
                )
            )
        }

        // Mode-specific capability framing: sandbox section when sandbox
        // tools are active, working-directory framing when chat is mounted
        // on a host folder. Static so it joins the cached prefix.
        if executionMode.usesSandboxTools {
            let secretNames = Array(AgentSecretsKeychain.getAllSecrets(agentId: agentId).keys)
            composer.append(
                .static(
                    id: "sandbox",
                    label: "Chat Sandbox",
                    content: SystemPromptTemplates.sandbox(secretNames: secretNames)
                )
            )
        } else if let folder = executionMode.folderContext {
            composer.append(
                .static(
                    id: "folderContext",
                    label: "Working Directory",
                    content: SystemPromptTemplates.folderContext(from: folder)
                )
            )
        }

        // Capability-discovery nudge: explain how to recover when the
        // current tool kit is incomplete. Gated to auto mode + presence of
        // `capabilities_search` so manual-mode agents and tools-disabled
        // sessions don't see irrelevant guidance.
        if snapshot.toolMode == .auto,
            !effectiveToolsOff,
            tools.contains(where: { $0.function.name == "capabilities_search" })
        {
            composer.append(
                .static(
                    id: "capabilityNudge",
                    label: "Capability Discovery",
                    content: SystemPromptTemplates.capabilityDiscoveryNudge
                )
            )
        }

        // ── Dynamics ─────────────────────────────────────────────────

        // Surface a "sandbox unavailable" notice when the agent wants
        // sandbox tools but registration couldn't provide them — otherwise
        // the model hallucinates sandbox calls that never get a result.
        if !executionMode.usesSandboxTools,
            snapshot.autonomousEnabled,
            let reason = SandboxToolRegistrar.shared.unavailabilityReason(for: agentId)
        {
            composer.append(
                .dynamic(
                    id: "sandboxUnavailable",
                    label: "Sandbox Unavailable",
                    content: Self.sandboxUnavailableNotice(reason: reason)
                )
            )
            trace?.set("sandboxUnavailable", reason.kind.rawValue)
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
        if snapshot.toolMode == .auto,
            !effectiveToolsOff,
            !preflight.companions.isEmpty,
            tools.contains(where: { $0.function.name == "capabilities_load" }),
            let companionsSection = PreflightCompanions.render(preflight.companions)
        {
            composer.append(
                .dynamic(
                    id: "pluginCompanions",
                    label: "Plugin Companions",
                    content: companionsSection
                )
            )
            trace?.set("pluginCompanions", String(preflight.companions.count))
        }

        // Skill Suggestions: standalone (non-plugin) skills whose body
        // semantically matches the user's query. Like `pluginCompanions`,
        // this is a teaser-only block — the full instructions stay in
        // `SkillManager` and the model pulls them via `capabilities_load`.
        // Caller already gated on `auto` + tools-on + non-empty query +
        // `capabilities_load` presence, so we just check non-empty and
        // append. Skipping on `effectiveToolsOff` here is belt-and-braces
        // for the preview composer which doesn't pre-gate.
        if !effectiveToolsOff,
            !toolset.skillSuggestions.isEmpty,
            let suggestionsSection = PreflightCompanions.renderSkillSuggestions(toolset.skillSuggestions)
        {
            composer.append(
                .dynamic(
                    id: "skillSuggestions",
                    label: "Skill Suggestions",
                    content: suggestionsSection
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
        // container finished provisioning — `canCreatePlugins` already
        // folds `autonomousEnabled && pluginCreate`, so this stays correct.
        //
        // All agent-side flags ride on `snapshot`, captured once at the
        // start of compose, so the gate can't race sibling MainActor work
        // (test setup, plugin registration, skill toggle) between awaits.
        let pluginCreatorSkill = SkillManager.shared.skill(named: "Sandbox Plugin Creator")
        let gateInputs = PluginCreatorGate.Inputs(
            effectiveToolsOff: effectiveToolsOff,
            sandboxAvailable: executionMode.usesSandboxTools || snapshot.autonomousEnabled,
            canCreatePlugins: snapshot.canCreatePlugins,
            dynamicCatalogIsEmpty: ToolRegistry.shared.dynamicCatalogIsEmpty(),
            hasResolvedDynamicTools: hasDynamicTools(snapshot: snapshot, preflight: preflight),
            skillEnabled: pluginCreatorSkill?.enabled ?? false
        )
        if PluginCreatorGate.shouldInject(gateInputs), let skill = pluginCreatorSkill {
            composer.append(
                .dynamic(
                    id: "pluginCreator",
                    label: "Plugin Creator",
                    content: PluginCreatorGate.section(
                        skillName: skill.name,
                        instructions: skill.instructions
                    )
                )
            )
            trace?.set("pluginCreatorInjected", "1")
        }
    }

    /// Tools that drive the chat-layer agent loop — `agentLoopGuidance`
    /// fires when any one of these resolves into the schema.
    static let agentLoopToolNames: Set<String> = [
        "todo", "complete", "clarify", "share_artifact",
    ]

    /// Tools that can mutate the user's filesystem, exec arbitrary code,
    /// or install dependencies. `codeStyleGuidance` and `riskAwareGuidance`
    /// fire whenever any one of these resolves into the schema. Grow this
    /// set as new write-capable tools land (plugin tools, future sandbox
    /// tools, etc.).
    static let mutationToolNames: Set<String> = [
        // sandbox built-ins
        "sandbox_write_file", "sandbox_edit_file", "sandbox_exec",
        "sandbox_install", "sandbox_pip_install", "sandbox_npm_install",
        "sandbox_execute_code",
        // folder tools
        "file_write", "file_edit", "shell_run",
    ]

    /// Capture the always-loaded names present in this turn's schema so
    /// callers can stash the snapshot for the next turn. When a snapshot
    /// was supplied, just echo it; otherwise compute fresh from the
    /// registry. The transient `sandbox_init_pending` placeholder is
    /// dropped from a fresh snapshot so it doesn't pin into future turns
    /// — see the `filterFrozen` carve-outs in `resolveTools` for why.
    /// Shared between `finalizeContext` and `composePreviewContext` so
    /// both paths produce the same `ComposedContext.alwaysLoadedNames`.
    @MainActor
    private static func resolveAlwaysLoadedNames(
        tools: [Tool],
        executionMode: ExecutionMode,
        frozenAlwaysLoadedNames: LoadedTools?
    ) -> LoadedTools {
        if let frozenAlwaysLoadedNames {
            return frozenAlwaysLoadedNames
        }
        let live = ToolRegistry.shared.alwaysLoadedSpecs(mode: executionMode)
            .map { $0.function.name }
        let resolved = Set(tools.map { $0.function.name })
        return Set(live)
            .intersection(resolved)
            .subtracting([BuiltinSandboxTools.initPendingToolName])
    }

    /// Synchronous preview compose for the welcome-screen Context Budget
    /// popover. Mirrors `composeChatContext` so the popover lists the same
    /// sections the next send will emit, with two intentional gaps:
    ///
    /// - **preflight tool delta**: needs a non-empty user query and an
    ///   LLM call, so auto-mode `Tools` under-counts on turn 1.
    /// - **`pluginCompanions`**: derived from preflight, always empty here.
    ///
    /// Memory is also out of scope (it's prepended to the user message,
    /// not the system prompt) — callers feed the per-turn estimate to
    /// `ContextBreakdown.from` separately, which surfaces the `Memory` row.
    @MainActor
    static func composePreviewContext(
        agentId: UUID,
        executionMode: ExecutionMode,
        model: String? = nil
    ) -> ComposedContext {
        // Same one-shot snapshot as the real send path so the popover
        // can never disagree with the next compose's gate decisions.
        let snapshot = AgentConfigSnapshot.capture(
            agentId: agentId,
            modelOverride: model
        )
        var composer = forChat(
            snapshot: snapshot,
            agentId: agentId,
            executionMode: executionMode
        )
        let toolset = previewToolset(snapshot: snapshot, executionMode: executionMode)
        appendGatedSections(
            composer: &composer,
            snapshot: snapshot,
            toolset: toolset,
            agentId: agentId,
            executionMode: executionMode
        )

        let manifest = composer.manifest()
        let toolNames = toolset.tools.map { $0.function.name }
        let rendered = composer.render()

        return ComposedContext(
            prompt: rendered,
            manifest: manifest,
            tools: toolset.tools,
            toolTokens: ToolRegistry.shared.totalEstimatedTokens(for: toolset.tools),
            preflightItems: [],
            preflight: .empty,
            memorySection: nil,
            alwaysLoadedNames: toolset.alwaysLoadedNames,
            cacheHint: manifest.staticPrefixHash(toolNames: toolNames),
            staticPrefix: manifest.staticPrefixContent,
            contextDisable: toolset.contextDisable
        )
    }

    /// Sync companion to `resolveToolset` for the preview path. Skips
    /// preflight (LLM call), skill suggestions (also async), and always
    /// passes nil for the freeze snapshot — the popover prices what
    /// `composeChatContext(query: "")` would emit, not a mid-session
    /// freeze.
    @MainActor
    private static func previewToolset(
        snapshot: AgentConfigSnapshot,
        executionMode: ExecutionMode
    ) -> ResolvedToolset {
        let window = ContextSizeResolver.resolve(modelId: snapshot.model)
        let effectiveToolsOff = snapshot.toolsDisabled || window.sizeClass.disablesTools
        let contextDisable = ContextDisableInfo.from(
            sizeClass: window.sizeClass,
            modelId: snapshot.model,
            contextLength: window.contextLength,
            agentToolsOff: snapshot.toolsDisabled,
            agentMemoryOff: snapshot.memoryDisabled
        )
        let tools = resolveTools(
            snapshot: snapshot,
            executionMode: executionMode,
            toolsDisabled: effectiveToolsOff
        )
        let alwaysLoadedNames = resolveAlwaysLoadedNames(
            tools: tools,
            executionMode: executionMode,
            frozenAlwaysLoadedNames: nil
        )
        return ResolvedToolset(
            preflight: .empty,
            tools: tools,
            skillSuggestions: [],
            alwaysLoadedNames: alwaysLoadedNames,
            contextDisable: contextDisable,
            effectiveToolsOff: effectiveToolsOff
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
        snapshot: AgentConfigSnapshot,
        toolset: ResolvedToolset,
        executionMode: ExecutionMode,
        frozenAlwaysLoadedNames: LoadedTools?,
        additionalToolNames: LoadedTools,
        trace: TTFTTrace?
    ) {
        let tools = toolset.tools
        let toolSource = resolveToolSource(
            toolMode: snapshot.toolMode,
            preflight: toolset.preflight,
            effectiveToolsOff: toolset.effectiveToolsOff
        )
        let sandboxStatus = String(describing: SandboxManager.State.shared.status)
        let sortedNames = tools.map { $0.function.name }.sorted()
        let frozenSize = frozenAlwaysLoadedNames?.count ?? 0
        let additiveCount = countAdditiveSandboxTools(
            in: sortedNames,
            frozen: frozenAlwaysLoadedNames
        )

        debugLog(
            "[Context:tools] mode=\(snapshot.toolMode) source=\(toolSource) autonomous=\(snapshot.autonomousEnabled) sandboxStatus=\(sandboxStatus) executionMode=\(executionMode) count=\(tools.count) frozen=\(frozenSize) additive=\(additiveCount) loaded=\(additionalToolNames.count) names=[\(sortedNames.joined(separator: ", "))]"
        )
        emitAutonomousWarningsIfNeeded(
            tools: tools,
            executionMode: executionMode,
            autonomousEnabled: snapshot.autonomousEnabled,
            sandboxStatus: sandboxStatus
        )
        trace?.set("toolMode", String(describing: snapshot.toolMode))
        trace?.set("toolSource", toolSource)
        trace?.set("autonomous", snapshot.autonomousEnabled ? "1" : "0")
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
        frozen: LoadedTools?
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
    private static func hasDynamicTools(
        snapshot: AgentConfigSnapshot,
        preflight: PreflightResult
    ) -> Bool {
        switch snapshot.toolMode {
        case .auto:
            return !preflight.toolSpecs.isEmpty
        case .manual:
            return !(snapshot.manualToolNames?.isEmpty ?? true)
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
        additionalToolNames: LoadedTools = [],
        frozenAlwaysLoadedNames: LoadedTools? = nil
    ) -> [Tool] {
        let snapshot = AgentConfigSnapshot.capture(
            agentId: agentId,
            requestToolsDisabled: toolsDisabled
        )
        return resolveTools(
            snapshot: snapshot,
            executionMode: executionMode,
            toolsDisabled: toolsDisabled,
            preflight: preflight,
            additionalToolNames: additionalToolNames,
            frozenAlwaysLoadedNames: frozenAlwaysLoadedNames
        )
    }

    @MainActor
    static func resolveTools(
        snapshot: AgentConfigSnapshot,
        executionMode: ExecutionMode,
        toolsDisabled: Bool = false,
        preflight: PreflightResult = .empty,
        additionalToolNames: LoadedTools = [],
        frozenAlwaysLoadedNames: LoadedTools? = nil
    ) -> [Tool] {
        guard !toolsDisabled else { return [] }

        let isManual = snapshot.toolMode == .manual

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
            if let manualNames = snapshot.manualToolNames {
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

    // MARK: - Factory Methods

    /// Pre-loaded composer for chat mode. Compact is auto-resolved from model/agent.
    /// Captures an `AgentConfigSnapshot` internally and forwards. Use the
    /// snapshot-taking overload below from the compose pipeline so a single
    /// MainActor read services every downstream gate.
    @MainActor
    public static func forChat(
        agentId: UUID,
        executionMode: ExecutionMode,
        model: String? = nil
    ) -> SystemPromptComposer {
        let snapshot = AgentConfigSnapshot.capture(agentId: agentId, modelOverride: model)
        return forChat(snapshot: snapshot, agentId: agentId, executionMode: executionMode)
    }

    /// Snapshot-aware composer factory. Returns just the platform +
    /// persona pair — every other static section (operational directives,
    /// agent loop, sandbox/folder, capability nudge) is appended later by
    /// `appendGatedSections` so the static cross-cutting block can land
    /// between persona and the mode-specific section.
    @MainActor
    public static func forChat(
        snapshot: AgentConfigSnapshot,
        agentId: UUID,
        executionMode: ExecutionMode
    ) -> SystemPromptComposer {
        var composer = SystemPromptComposer()
        composer.appendBasePrompt(systemPrompt: snapshot.systemPrompt)
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
    ///
    /// The `prepend` parameter exists to support both call shapes:
    ///   - `injectSystemContent` (prepend=true) — used by the HTTP path
    ///     to land the agent's composed prompt ahead of any caller-
    ///     supplied system content.
    ///   - `appendSystemContent` (prepend=false) — used by `PluginHostAPI`
    ///     to tack plugin-instructions and the dynamic skills section
    ///     onto the END of the system block so they read as additions
    ///     to the (already-composed) base prompt rather than overrides.
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

    /// Prepend system content. Used by the HTTP enrichment path so the
    /// agent's composed system prompt lands ahead of any caller-supplied
    /// system message.
    static func injectSystemContent(_ content: String, into messages: inout [ChatMessage]) {
        mergeSystemContent(content, into: &messages, prepend: true)
    }

    /// Append system content. Used by `PluginHostAPI` to tack plugin
    /// instructions and dynamic skill sections onto the end of the
    /// composed system message — they read as additions to the base
    /// prompt rather than overriding it. Two live callers in
    /// `PluginHostAPI.prepareInference`; do not delete without
    /// migrating those.
    static func appendSystemContent(_ content: String, into messages: inout [ChatMessage]) {
        mergeSystemContent(content, into: &messages, prepend: false)
    }
}
