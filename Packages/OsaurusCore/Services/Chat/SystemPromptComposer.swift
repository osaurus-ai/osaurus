//
//  SystemPromptComposer.swift
//  osaurus
//
//  Builder for structured system prompt assembly. Provides low-level
//  section-by-section composition plus the high-level `composeChatContext`
//  entry point that handles the full pipeline.
//

import Foundation
import os

private let toolResolveLog = Logger(subsystem: "ai.osaurus", category: "ToolResolve")

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
        PromptRenderer.render(sections)
    }

    /// Eval-scoped ablation hook: drop experiment-listed section ids
    /// after gated composition. No-op in production (`current == nil`)
    /// and for protected ids — see `PromptComposerExperiment`.
    mutating func applyExperimentAblation() {
        guard let experiment = PromptComposerExperimentScope.current,
            !experiment.dropSectionIds.isEmpty
        else { return }
        sections = experiment.filterSections(sections)
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
                id: PromptSectionID.platform,
                label: L("Platform"),
                content: SystemPromptTemplates.platformIdentity
            )
        )
        let effective = SystemPromptTemplates.effectivePersona(systemPrompt)
        append(.static(id: PromptSectionID.persona, label: L("Persona"), content: effective))
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
        modelType: String? = nil,
        query: String = "",
        messages: [ChatMessage] = [],
        toolsDisabled: Bool = false,
        additionalToolNames: LoadedTools = [],
        frozenAlwaysLoadedNames: LoadedTools? = nil,
        frozenToolSpecs: [Tool]? = nil,
        frozenManifest: String? = nil,
        frozenSoul: String? = nil,
        trace: TTFTTrace? = nil,
        projectId: UUID? = nil
    ) async -> ComposedContext {
        await composeChatContext(
            ComposeRequest(
                agentId: agentId,
                executionMode: executionMode,
                model: model,
                modelType: modelType,
                query: query,
                messages: messages,
                toolsDisabled: toolsDisabled,
                additionalToolNames: additionalToolNames,
                frozenAlwaysLoadedNames: frozenAlwaysLoadedNames,
                frozenToolSpecs: frozenToolSpecs,
                frozenManifest: frozenManifest,
                frozenSoul: frozenSoul,
                trace: trace,
                projectId: projectId
            )
        )
    }

    /// Canonical entry point: every parameter rides on `ComposeRequest`
    /// so optional bits (trace, frozen snapshot, mid-session loaded
    /// names) stay grouped instead of trailing the signature.
    ///
    /// `request.query` is the effective user query for memory recall. If
    /// empty, the most recent `"user"` message in `request.messages` is used.
    /// Pass `additionalToolNames` so
    /// tools the agent loaded mid-session via `capabilities_load` survive
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
            modelOverride: request.model,
            modelTypeOverride: request.modelType,
            projectId: request.projectId
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
            query: resolveEffectiveQuery(query: request.query, messages: request.messages),
            messages: request.messages,
            additionalToolNames: request.additionalToolNames,
            frozenAlwaysLoadedNames: request.frozenAlwaysLoadedNames,
            frozenToolSpecs: request.frozenToolSpecs,
            frozenManifest: request.frozenManifest,
            frozenSoul: request.frozenSoul,
            trace: trace
        )
        trace?.mark("compose_context_done")
        return result
    }

    /// Derive the effective user query: prefer the explicit `query`, else
    /// the most recent user message text. Returns "" if neither is available.
    /// This feeds memory recall only; prompt and tool shape must not depend on
    /// query wording.
    static func resolveEffectiveQuery(query: String, messages: [ChatMessage]) -> String {
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

    /// Shared pipeline: assemble memory (returned separately) + resolve
    /// tools + build ComposedContext.
    ///
    /// Memory is intentionally NOT appended into the system prompt. It is
    /// surfaced on `ComposedContext.memorySection` so callers prepend it to
    /// the latest user message — that keeps the system prompt byte-stable
    /// across turns, which lets the MLX paged KV cache reuse the entire
    /// conversation prefix.
    @MainActor
    private static func finalizeContext(
        composer: SystemPromptComposer,
        snapshot: AgentConfigSnapshot,
        agentId: UUID,
        executionMode: ExecutionMode,
        query: String,
        messages: [ChatMessage],
        additionalToolNames: LoadedTools = [],
        frozenAlwaysLoadedNames: LoadedTools? = nil,
        frozenToolSpecs: [Tool]? = nil,
        frozenManifest: String? = nil,
        frozenSoul: String? = nil,
        trace: TTFTTrace? = nil
    ) async -> ComposedContext {
        var comp = composer
        // Memory and SOUL are independent — overlap their reads. Memory
        // does DB work; SOUL is a tiny file read; running them in
        // parallel keeps SOUL effectively free behind the memory hop.
        async let memoryAsync = resolveMemory(
            snapshot: snapshot,
            agentId: agentId,
            query: query,
            trace: trace
        )
        async let soulAsync = resolveSoul(
            snapshot: snapshot,
            agentId: agentId,
            executionMode: executionMode,
            frozenSoul: frozenSoul,
            trace: trace
        )
        let memorySection = await memoryAsync
        let soulSection = await soulAsync
        let toolset = await resolveToolset(
            snapshot: snapshot,
            agentId: agentId,
            executionMode: executionMode,
            additionalToolNames: additionalToolNames,
            frozenAlwaysLoadedNames: frozenAlwaysLoadedNames,
            frozenToolSpecs: frozenToolSpecs,
            frozenManifest: frozenManifest,
            trace: trace
        )
        appendGatedSections(
            composer: &comp,
            snapshot: snapshot,
            toolset: toolset,
            agentId: agentId,
            executionMode: executionMode,
            soulSection: soulSection,
            trace: trace
        )
        comp.applyExperimentAblation()
        let manifest = comp.manifest()
        debugLog("[Context] \(manifest.debugDescription)")

        // Prefill diagnostics: record the full composition breakdown so the
        // /tmp log shows where every system-prompt token comes from, plus the
        // tool-schema token cost and the static-prefix hash (identical hashes
        // across two fresh chats mean disk-L2 carryover SHOULD hit).
        if PrefillDebugLog.shared.isEnabled {
            let window = ContextSizeResolver.resolve(modelId: snapshot.model)
            let toolTokens = ToolRegistry.shared.totalEstimatedTokens(for: toolset.tools)
            // `source=` is the bound session source, the input every
            // source-scoped gate (channel publish tool, Channel Destinations)
            // resolves against. Logging it makes warmup/send parity directly
            // readable: two banners for one session must show the same source
            // and the same staticPrefixHash, and `source=nil` on any live
            // session's banner is itself the bug (an unbound compose path).
            let boundSource = ChatExecutionContext.currentSessionSource
                .map { String(describing: $0) } ?? "nil"
            PrefillDebugLog.shared.log(
                "==== COMPOSE model=\(snapshot.model) sizeClass=\(window.sizeClass) "
                    + "ctxLen=\(window.contextLength.map(String.init) ?? "?") "
                    + "source=\(boundSource) "
                    + "executionMode=\(executionMode) toolCount=\(toolset.tools.count) "
                    + "toolTokens≈\(toolTokens) "
                    + "systemPromptTokens≈\(manifest.totalEstimatedTokens) "
                    + "promptPlusTools≈\(manifest.totalEstimatedTokens + toolTokens) "
                    + "staticPrefixTokens≈\(manifest.staticPrefixTokens) "
                    + "staticPrefixHash=\(manifest.staticPrefixHash(tools: toolset.tools).prefix(16))\n"
                    + manifest.debugDescription
            )
            // Dump the rendered enabled-capabilities section verbatim so a
            // single run shows EXACTLY what the model sees (e.g. the tiered
            // `plugin/<id>` lines) — the token table above can't reveal the
            // text. Bounded: the manifest itself is capped.
            if let manifestText = manifest.section("enabledManifest")?.content,
                !manifestText.isEmpty
            {
                PrefillDebugLog.shared.log("---- ENABLED-MANIFEST (rendered)\n\(manifestText)")
            }
            for tool in toolset.tools {
                let signature = PromptPrefixHasher.hash(systemContent: "", tools: [tool])
                let tokens = ToolRegistry.shared.totalEstimatedTokens(for: [tool])
                PrefillDebugLog.shared.log(
                    "---- TOOL-SCHEMA name=\(tool.function.name) "
                        + "hash=\(signature) tokens≈\(tokens)"
                )
            }
        }

        emitToolDiagnostics(
            snapshot: snapshot,
            toolset: toolset,
            executionMode: executionMode,
            frozenAlwaysLoadedNames: frozenAlwaysLoadedNames,
            additionalToolNames: additionalToolNames,
            trace: trace
        )
        let rendered = comp.render()
        trace?.set("systemPromptChars", rendered.count)
        trace?.set("toolCount", toolset.tools.count)
        return ComposedContext(
            prompt: rendered,
            manifest: manifest,
            tools: toolset.tools,
            toolTokens: ToolRegistry.shared.totalEstimatedTokens(for: toolset.tools),
            memorySection: memorySection,
            alwaysLoadedNames: toolset.alwaysLoadedNames,
            initialToolSpecs: toolset.sessionBaselineTools,
            cacheHint: manifest.staticPrefixHash(tools: toolset.tools),
            staticPrefix: manifest.staticPrefixContent,
            contextDisable: toolset.contextDisable,
            enabledManifest: toolset.enabledManifest,
            soul: soulSection
        )
    }

    /// Per-turn memory snippet, or nil when memory is disabled (either
    /// at the agent level or auto-off via the size-class). Pass the latest
    /// query through so retrieval can rank pinned, episode, and
    /// transcript memory. The memory block is injected into the user message
    /// instead of the system prompt, so query-specific recall does not
    /// destabilize the static system/tool cache prefix.
    @MainActor
    private static func resolveMemory(
        snapshot: AgentConfigSnapshot,
        agentId: UUID,
        query: String,
        trace: TTFTTrace?
    ) async -> String? {
        let window = ContextSizeResolver.resolve(modelId: snapshot.model)
        // Tiny-context models can't spare room for memory at all — hard skip
        // for both lanes, regardless of project sharing.
        guard !window.sizeClass.disablesMemory else { return nil }
        trace?.mark("memory_start")
        // The agent's own memory lane still honors the agent's toggle. The
        // project lane (below) is assembled even when the agent has memory
        // off: every chat in a project recalls the project's shared memory.
        // `appendProjectMemory` enforces the global memory switch.
        let section =
            snapshot.memoryDisabled
            ? nil
            : await assembleMemorySection(agentId: agentId.uuidString, query: query)
        let merged = await appendProjectMemory(
            to: section, projectId: snapshot.projectId, query: query)
        trace?.mark("memory_done")
        return merged
    }

    /// Second recall lane for project chats: assemble the `project:<id>`
    /// namespace and append it under its own header. Non-project chats
    /// (`projectId == nil`) return `agentSection` untouched — the agent
    /// memory pipeline is byte-identical with or without this feature.
    ///
    /// Budgeting is agent-first: the project lane gets whatever the agent
    /// lane left of the per-message budget, floored at a quarter of it so
    /// a memory-heavy agent can't starve project recall entirely. Combined
    /// output therefore never exceeds ~1.25x the configured budget.
    private static func appendProjectMemory(
        to agentSection: String?,
        projectId: UUID?,
        query: String
    ) async -> String? {
        guard let projectId else { return agentSection }
        let config = MemoryConfigurationStore.load()
        guard config.enabled else { return agentSection }

        let namespaceKey = MemoryNamespace.project(projectId).key
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let budget = config.memoryBudgetTokens
        let agentTokens = (agentSection?.count ?? 0) / MemoryConfiguration.charsPerToken
        let projectBudget = max(budget / 4, budget - agentTokens)

        // Curated lane: distilled episodes / pinned facts (may be empty
        // until the background distillation has run).
        let curated = await MemoryContextAssembler.assembleContext(
            agentId: namespaceKey,
            config: config,
            query: trimmedQuery,
            budgetTokensOverride: projectBudget,
            includeGlobalBlocks: false
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        // Immediate lane: raw transcript turns mirrored on write, so a fact
        // stated seconds ago is recallable before any distillation. Only
        // meaningful with a query to retrieve against. Deduped against the
        // curated lane so a fact that's already been distilled isn't echoed.
        let curatedTokens = curated.split(separator: "\n").map {
            TextSimilarity.tokenize(String($0).trimmingCharacters(in: .whitespaces))
        }
        var transcriptLines: [String] = []
        if !trimmedQuery.isEmpty {
            let hits = await MemorySearchService.shared.searchTranscript(
                query: trimmedQuery, agentId: namespaceKey, topK: 4
            )
            for hit in hits {
                let text = hit.content.trimmingCharacters(in: .whitespacesAndNewlines)
                guard text.count > 3 else { continue }
                let clipped = text.count > 220 ? String(text.prefix(220)) + "…" : text
                let tokens = TextSimilarity.tokenize(clipped)
                let alreadyCurated = curatedTokens.contains {
                    TextSimilarity.jaccardTokenized($0, tokens) > 0.85
                }
                if !alreadyCurated { transcriptLines.append("- \(clipped)") }
            }
        }

        var parts: [String] = []
        if !curated.isEmpty { parts.append(curated) }
        if !transcriptLines.isEmpty {
            parts.append("## Recent project notes\n" + transcriptLines.joined(separator: "\n"))
        }
        let trimmed = parts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return agentSection }

        // Dedupe against the agent lane. Exact match catches the same
        // agent's dual-written distillates (literal copies); the Jaccard
        // pass additionally drops near-identical phrasings of the same
        // fact distilled from different sessions. The 0.85 threshold is
        // deliberately much stricter than the 0.6 the pinned-fact store
        // uses: a fact from ANOTHER agent that merely resembles one of
        // this agent's lines is real information and must survive —
        // only virtually-verbatim repeats are suppressed.
        let agentLineTexts = (agentSection ?? "").split(separator: "\n").map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
        let agentLines = Set(agentLineTexts)
        let agentLineTokens = agentLineTexts.map { TextSimilarity.tokenize($0) }
        let freshLines = trimmed.split(separator: "\n").filter { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.hasPrefix("#") { return true }
            if agentLines.contains(t) { return false }
            let tokens = TextSimilarity.tokenize(t)
            return !agentLineTokens.contains {
                TextSimilarity.jaccardTokenized($0, tokens) > 0.85
            }
        }
        // Headers survive the filter unconditionally, so require at least
        // one real content line before paying for the block at all.
        let hasContent = freshLines.contains { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            return !t.isEmpty && !t.hasPrefix("#")
        }
        guard hasContent else { return agentSection }
        let fresh = freshLines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fresh.isEmpty else { return agentSection }

        let projectBlock = "## Shared project memory\n\n\(fresh)"
        guard let agentSection, !agentSection.isEmpty else { return projectBlock }
        return agentSection + "\n\n" + projectBlock
    }

    // MARK: - SOUL Assembly

    /// 8 KB cap for `~/SOUL.md` content surfaced into the prompt. Past
    /// this size the file's value-per-token plummets and the agent is
    /// almost certainly stashing transient context that belongs in
    /// memory or AGENTS.md, not the soul. Caps live next to the read so
    /// PR2's bootstrap seed and PR3's advert don't have to re-derive it.
    static let soulMaxBytes: Int = 8 * 1024

    /// Tighter SOUL byte budget for tiny-context models (Apple Foundation,
    /// ~4K window). The default 8K cap is twice the entire window, so the
    /// agent's own notes would crowd out the user's turn. Session-constant
    /// (driven by the resolved model's size class) → KV-cache safe.
    static let soulTinyMaxBytes: Int = 1 * 1024

    /// Mid-tier SOUL byte budget for small-context models (~8K window).
    /// The default 8 KB cap is ~2K tokens — a quarter of the whole window
    /// — so `.small` gets 2 KB: enough for real preferences, not enough to
    /// crowd out the user's turn. Session-constant → KV-cache safe.
    static let soulSmallMaxBytes: Int = 2 * 1024

    /// Marker appended on its own line after a truncation so the model
    /// knows the agent's soul was clipped (don't extrapolate from the
    /// trailing line as if it were the natural end of the file).
    static let soulTruncationMarker = "... (truncated)"

    /// Read SOUL.md from the agent's host-mounted home, trim, and cap
    /// at `soulMaxBytes` on a line boundary. Returns `nil` when the
    /// file is missing, unreadable, or trims to empty — the composer's
    /// existing `PromptSection.isEmpty` filter then drops the section
    /// without an explicit gate at the call-site.
    ///
    /// Sync because the read is a tiny local file and the preview path
    /// (`composePreviewContext`) is itself sync; the async `resolveSoul`
    /// wrapper just adds trace marks. Errors are swallowed and logged —
    /// a missing/corrupt SOUL must never block compose.
    private static func loadSoulContent(linuxName: String, maxBytes: Int = soulMaxBytes) -> String? {
        let url = OsaurusPaths.containerAgentDir(linuxName)
            .appendingPathComponent("SOUL.md", isDirectory: false)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let raw: String
        do {
            raw = try String(contentsOf: url, encoding: .utf8)
        } catch {
            debugLog("[Soul] read failed for \(url.path): \(error.localizedDescription)")
            return nil
        }
        let capped = capSoulContent(raw, maxBytes: maxBytes)
        let trimmed = capped.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Truncate `raw` at the nearest line boundary at or before the
    /// `soulMaxBytes` UTF-8 byte budget and append `soulTruncationMarker`
    /// on its own line. No-op when the input already fits.
    ///
    /// When no newline exists in the budget (single huge line — not a
    /// realistic shape for a markdown soul, but possible in principle)
    /// we hard-cut at the budget and still append the marker on a new
    /// line so the model sees the truncation signal regardless.
    static func capSoulContent(_ raw: String, maxBytes: Int = soulMaxBytes) -> String {
        let utf8 = Array(raw.utf8)
        guard utf8.count > maxBytes else { return raw }
        // Cutoff = byte index of the last `\n` within the budget + 1
        // (so the slice keeps the newline). Falls back to a hard cut
        // at the budget when no newline is reachable.
        let lastNewline = utf8.prefix(maxBytes)
            .lastIndex(of: UInt8(ascii: "\n"))
        let cutoff = lastNewline.map { $0 + 1 } ?? maxBytes
        let prefix = String(decoding: utf8.prefix(cutoff), as: UTF8.self)
        // Hard-cut prefix may not end on `\n`; force one so the marker
        // always reads as its own line below the soul content.
        let separator = prefix.hasSuffix("\n") ? "" : "\n"
        return prefix + separator + soulTruncationMarker
    }

    /// Per-turn SOUL snippet, or nil when not in sandbox mode or the
    /// file is missing/empty. Mirrors `resolveMemory` shape (gate +
    /// trace marks) so a future async-only soul source can slot in
    /// without changing the call-site.
    ///
    /// `frozenSoul` mirrors `frozenManifest`: when the session captured a
    /// turn-1 value it is echoed verbatim so a mid-session `SOUL.md` edit
    /// can't rewrite the static prefix (the file's own contract says edits
    /// apply on the next session). `nil` means "read fresh now".
    @MainActor
    private static func resolveSoul(
        snapshot: AgentConfigSnapshot,
        agentId: UUID,
        executionMode: ExecutionMode,
        frozenSoul: String? = nil,
        trace: TTFTTrace?
    ) async -> String? {
        guard executionMode.usesSandboxTools else { return nil }
        if let frozenSoul {
            trace?.set("soulSource", "frozen")
            return frozenSoul
        }
        trace?.mark("soul_start")
        let linuxName = SandboxAgentProvisioner.linuxName(for: agentId.uuidString)
        let cap = soulCap(forModel: snapshot.model)
        let content = loadSoulContent(linuxName: linuxName, maxBytes: cap)
        trace?.mark("soul_done")
        return content
    }

    /// SOUL byte budget for a model, stepped by size class (`.tiny` 1 KB,
    /// `.small` 2 KB, `.normal` 8 KB). Pure + session-constant (size class
    /// is fixed for a session's model) so both the send and preview paths
    /// agree and the result is KV-cache stable.
    private static func soulCap(forModel modelId: String?) -> Int {
        let window = ContextSizeResolver.resolve(modelId: modelId)
        switch window.sizeClass {
        case .tiny: return soulTinyMaxBytes
        case .small: return soulSmallMaxBytes
        case .normal:
            // A large-window model that still prefers the compact prompt
            // (local, ≤ param ceiling) gets the small budget — a verbose SOUL
            // is more per-step tokenization cost than it can afford.
            return window.prefersCompactPrompt ? soulSmallMaxBytes : soulMaxBytes
        }
    }

    /// Whether tools are suppressed for this compose.
    ///
    /// The per-agent "Tools" toggle (Configure tab) is a chat-only kill-switch.
    /// In sandbox mode the user has already made an explicit execution grant via
    /// Autonomous Execution (that's what resolves the mode to `.sandbox` in the
    /// first place), so the sandbox tool surface — and the operational baseline
    /// the agent loop needs to drive it — stays exposed even when that per-agent
    /// toggle is off.
    ///
    /// Two signals are NOT overridable and win in every mode:
    ///   - `globalToolsDisabled`: an explicit request/surface kill-switch.
    ///   - `sizeClassDisablesTools`: the small-context auto-disable, a hard
    ///     capability limit.
    static func resolveEffectiveToolsOff(
        toolsDisabled: Bool,
        globalToolsDisabled: Bool,
        sizeClassDisablesTools: Bool,
        executionMode: ExecutionMode
    ) -> Bool {
        if globalToolsDisabled || sizeClassDisablesTools { return true }
        // Global switch is excluded above, so `toolsDisabled` now reflects the
        // per-agent Tools toggle alone — which sandbox mode overrides.
        return toolsDisabled && !executionMode.usesSandboxTools
    }

    /// Assemble every tool-axis decision for the request: size-class
    /// auto-disable, final tool set, always-loaded snapshot, and the frozen
    /// enabled-capabilities manifest.
    @MainActor
    private static func configuredSpawnPools(
        snapshot: AgentConfigSnapshot
    ) -> (
        agents: [UUID],
        models: [String],
        notes: [String: String],
        launcherModelOverride: String?
    ) {
        if let frozen = snapshot.spawnConfiguration {
            return (
                agents: frozen.agentIDs,
                models: frozen.modelNames,
                notes: frozen.modelNotes,
                launcherModelOverride: frozen.launcherModelOverride
            )
        }
        let config = SubagentConfigurationStore.snapshot()
        let isDefault = snapshot.agentId == Agent.defaultId
        let settings = AgentManager.shared.agent(for: snapshot.agentId)?.settings
        return (
            agents: SubagentToolVisibility.effectiveSpawnableAgents(
                isDefault: isDefault,
                config: config,
                perAgentEnabled: snapshot.spawnDelegationEnabled,
                perAgentTargets: snapshot.spawnableAgentIDs
            ),
            models: SubagentToolVisibility.effectiveSpawnableModels(
                isDefault: isDefault,
                config: config,
                perAgentEnabled: snapshot.spawnDelegationEnabled,
                perAgentModelTargets: snapshot.spawnableModelNames
            ),
            notes: isDefault ? config.spawnableModelNotes : snapshot.spawnableModelNotes,
            launcherModelOverride: SubagentToolVisibility.effectiveSubagentModel(
                capabilityId: SubagentCapabilityRegistry.spawn.id,
                isDefault: isDefault,
                config: config,
                settings: settings
            )
        )
    }

    @MainActor
    private static func resolveToolset(
        snapshot: AgentConfigSnapshot,
        agentId: UUID,
        executionMode: ExecutionMode,
        additionalToolNames: LoadedTools,
        frozenAlwaysLoadedNames: LoadedTools?,
        frozenToolSpecs: [Tool]?,
        frozenManifest: String? = nil,
        trace: TTFTTrace?
    ) async -> ResolvedToolset {
        // Auto-disable for small-context models (Foundation et al.).
        // OR into the agent's flags so every downstream gate (preflight,
        // skills, agent loop, capability nudge, model family, plugin
        // creator) cascades correctly without each gate having to know
        // about the size class itself.
        let window = ContextSizeResolver.resolve(modelId: snapshot.model)
        let effectiveToolsOff = resolveEffectiveToolsOff(
            toolsDisabled: snapshot.toolsDisabled,
            globalToolsDisabled: snapshot.globalToolsDisabled,
            sizeClassDisablesTools: window.sizeClass.disablesTools,
            executionMode: executionMode
        )
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

        let configuredSpawn = configuredSpawnPools(snapshot: snapshot)
        let spawnTargets =
            effectiveToolsOff
            ? .empty
            : await SpawnDescriptors.resolveForRequest(
                agentIDs: configuredSpawn.agents,
                modelNames: configuredSpawn.models,
                modelNotes: configuredSpawn.notes,
                launcherModelOverride: configuredSpawn.launcherModelOverride
            )

        trace?.mark("resolve_tools_start")
        let resolvedTools = resolveTools(
            snapshot: snapshot,
            executionMode: executionMode,
            toolsDisabled: effectiveToolsOff,
            additionalToolNames: additionalToolNames,
            frozenAlwaysLoadedNames: frozenAlwaysLoadedNames,
            frozenToolSpecs: frozenToolSpecs,
            spawnTargets: spawnTargets
        )
        trace?.mark("resolve_tools_done")
        let alwaysLoadedNames = resolveAlwaysLoadedNames(
            tools: resolvedTools,
            executionMode: executionMode,
            frozenAlwaysLoadedNames: frozenAlwaysLoadedNames
        )

        let enabledManifest = resolveEnabledManifest(
            snapshot: snapshot,
            agentId: agentId,
            tools: resolvedTools,
            executionMode: executionMode,
            effectiveToolsOff: effectiveToolsOff,
            frozenManifest: frozenManifest,
            trace: trace
        )

        return ResolvedToolset(
            tools: resolvedTools,
            sessionBaselineTools: resolvedTools,
            enabledManifest: enabledManifest,
            alwaysLoadedNames: alwaysLoadedNames,
            spawnTargets: spawnTargets,
            contextDisable: contextDisable,
            sizeClass: window.sizeClass,
            effectiveToolsOff: effectiveToolsOff,
            capabilityPromptSectionsEnabled: true,
            prefersCompactPrompt: window.prefersCompactPrompt
        )
    }

    /// Render the complete loadable enabled-capabilities manifest section for
    /// this session, frozen at session start. Returns the rendered section body
    /// (dynamic tools + plugin skills + standalone skills) or `nil` when the
    /// section is gated off or has no content.
    ///
    /// The manifest is a static prefix section, so this is gated only on
    /// session-constant facts — auto mode, tools enabled, and a capability
    /// loader present in the schema. Custom chat publishes the unified
    /// `capabilities` gateway; compatibility surfaces may publish the legacy
    /// loader. The deliberately-dropped
    /// trivial-input gate keeps the static prefix byte-identical across
    /// turns. A non-`nil` `frozenManifest` is reused verbatim so turn 2+
    /// never recompute or reorder; `nil` means "freeze fresh now".
    @MainActor
    private static func resolveEnabledManifest(
        snapshot: AgentConfigSnapshot,
        agentId: UUID,
        tools: [Tool],
        executionMode: ExecutionMode,
        effectiveToolsOff: Bool,
        frozenManifest: String? = nil,
        trace: TTFTTrace?
    ) -> String? {
        let schemaNames = Set(tools.map(\.function.name))
        // No `usesHostFolderTools` condition here. PR #2300 excluded folder
        // mode with the one-line rationale "host-folder agents retain their
        // workspace-only prompt" — but this guard doesn't trim folder-redundant
        // entries, it deletes the ENTIRE manifest, MCP and plugin ids included.
        // A custom agent set up for "research the web and save files to my
        // folder" — folder attached, MCP servers connected — composed a prompt
        // with zero mention that any of its capabilities existed; the model's
        // only route was a blind `capabilities` search it had no reason to
        // issue with the right terms (reported live: agents "can't find"
        // connected Exa/fetch MCP tools). The `capabilities` gateway is
        // already in the folder-mode schema and loads work in folder mode;
        // the model just was never told what to load.
        guard snapshot.toolMode == .auto, !effectiveToolsOff,
            let capabilityNames = capabilityToolNames(inSchema: schemaNames),
            schemaNames.contains(capabilityNames.load)
        else { return nil }
        // The Default agent carries `capabilities_load` only to lazy-load its
        // deferred configure write tools on small local models. Its own
        // system-prompt addendum already enumerates the configure surface, so
        // the enabled-capabilities manifest would be redundant bloat that
        // cancels the prefill saved by deferring the writes — skip it.
        guard agentId != Agent.defaultId else { return nil }
        if let frozenManifest {
            trace?.set("enabledManifestSource", "frozen")
            return frozenManifest
        }
        let groups = deriveEnabledManifest(
            agentId: agentId,
            includeAgentChannelTools: false
        )
        // Standalone skills are universally discoverable, but restoring their
        // whole catalog to every lean custom prompt would undo #2250's minimal
        // surface. Emit the manifest only when this agent actually has at
        // least one assigned, loadable dynamic tool (the plugin regression
        // this section repairs); that manifest may then include related and
        // standalone skills as before.
        guard groups.contains(where: { !$0.tools.isEmpty }) else { return nil }
        // `prefersCompactPrompt` already folds the small/tiny-window cases
        // (existing behaviour) and the local-small-model case (large window,
        // ≤ param ceiling). Compact tiers the manifest to one `plugin/<id>`
        // line per plugin (the model loads the id to expand the group) and
        // drops the worked example — so cold first-turn prefill stays bounded
        // as installed plugins grow, while every plugin stays visible.
        let compact = ContextSizeResolver.resolve(modelId: snapshot.model).prefersCompactPrompt
        let section = SystemPromptTemplates.enabledCapabilitiesManifest(
            groups: groups,
            compact: compact,
            names: capabilityNames
        )
        if section != nil {
            let toolCount = groups.reduce(0) { $0 + $1.tools.count }
            trace?.set("enabledManifest", String(toolCount))
            trace?.set("enabledManifestSource", "fresh")
        }
        return section
    }

    /// Resolve the capability search/load names actually published to this
    /// request. Prefer the unified chat gateway when both contracts exist.
    static func capabilityToolNames(
        inSchema schemaNames: Set<String>
    ) -> SystemPromptTemplates.CapabilityToolNames? {
        if schemaNames.contains("capabilities") { return .gateway }
        if schemaNames.contains("capabilities_load")
            || schemaNames.contains("capabilities_discover")
        {
            return .legacy
        }
        return nil
    }

    /// Append the plugin-authoring contract on both prompt architectures: the
    /// lean custom-agent path and the full compatibility path. Keeping the gate
    /// here prevents an early return in either architecture from hiding the
    /// recipe while `sandbox_plugin_register` is callable (or first-use
    /// provisioning is pending).
    @MainActor
    private static func appendPluginCreatorSection(
        composer: inout SystemPromptComposer,
        snapshot: AgentConfigSnapshot,
        effectiveToolsOff: Bool,
        executionMode: ExecutionMode,
        prefersCompactPrompt: Bool,
        trace: TTFTTrace?
    ) {
        let gateInputs = PluginCreatorGate.Inputs(
            effectiveToolsOff: effectiveToolsOff,
            sandboxAvailable: executionMode.usesSandboxTools || snapshot.autonomousEnabled,
            canCreatePlugins: snapshot.canCreatePlugins
        )
        guard PluginCreatorGate.shouldInject(gateInputs) else { return }

        let instructions = pluginCreatorInstructions(
            prefersCompactPrompt: prefersCompactPrompt,
            hostWritableCombined: executionMode.allowsHostWriteTools
        )
        composer.append(
            .static(
                id: "pluginCreator",
                label: L("Plugin Creator"),
                content: PluginCreatorGate.section(instructions: instructions)
            )
        )
        trace?.set("pluginCreatorInjected", "1")
    }

    static func pluginCreatorInstructions(
        prefersCompactPrompt: Bool,
        hostWritableCombined: Bool
    ) -> String {
        prefersCompactPrompt
            ? SystemPromptTemplates.pluginCreatorInstructionsCompactBody(
                hostWritableCombined: hostWritableCombined
            )
            : SystemPromptTemplates.pluginCreatorInstructionsBody(
                hostWritableCombined: hostWritableCombined
            )
    }

    /// Append every gated "deterministic" prompt section given the
    /// resolved tool set.
    ///
    /// Order is deliberate — cross-cutting rules first, harness second,
    /// mode-specific capability third, recovery path last, dynamics
    /// finally. Pre-platform/persona happens in `forChat`. The full
    /// rendered prompt looks like:
    ///
    ///   1. platform                  (forChat)
    ///   2. persona                   (forChat)
    ///   3. soul                      static, sandbox-only, frozen per session
    ///   4. selfImprovement           static, sandbox-only (canCreatePlugins-aware)
    ///   5. agentDB                   static framing, gated on dbEnabled
    ///   6. modelFamilyGuidance       static, every family (default for .other)
    ///   7. grounding                 static, gated on tools present
    ///   8. codeStyle                 static, gated on file-edit tools
    ///   9. riskAware                 static, gated on file-mutation tools
    ///  10. secretHandling            static, sandbox-only
    ///  11. computerUse               static, gated on computer_use in schema
    ///  12. agentLoopGuidance         static, gated on loop tools in schema
    ///  13. sandbox / folderContext   static framing, mode-specific, gated on tools on
    ///  14. capabilityNudge           static, gated on capabilities_discover
    ///                                (sandbox: build-ladder variant, canCreatePlugins-aware)
    ///  15. enabledManifest           static, frozen, gated on capabilities_load
    ///                                (all enabled tools + plugin skills + standalone skills)
    ///  16. skillsGovern              static body, only for verbose manifests
    ///                                with a skill-governed tool group
    ///  17. pluginCreator             static, injected when plugin creation is enabled
    ///                                (session-constant gate — joins the cached prefix)
    ///  18. agentDBSchema             dynamic, live schema snapshot (mutates mid-session)
    ///  19. sandboxState              dynamic, installed packages + secrets (mutate mid-session)
    ///  20. sandboxUnavailable        dynamic, gated on registrar failure
    ///  21. channelDestinations       dynamic, source-scoped publish bindings
    ///
    /// Statics come before dynamics so the cached prefix
    /// (`PromptManifest.staticPrefixContent`) reaches as far as possible —
    /// every static section above the first dynamic break joins the
    /// KV-cache reuse window. The `agentDB`/`sandbox` framing is static while
    /// their mutable state (`agentDBSchema`/`sandboxState`) rides in the
    /// dynamic block, so schema changes, package installs, and new secrets
    /// stay fresh turn-to-turn without invalidating the cached prefix.
    ///
    /// Shared between the real send path (`finalizeContext`) and the sync
    /// preview path (`composePreviewContext`) so the welcome-screen budget
    /// popover lists the same sections the next send will produce, modulo
    /// the dynamic ones it can't price ahead of time.
    ///
    /// Skills are intentionally NOT injected here — they're discovered via
    /// `capabilities_discover` and pulled in via `capabilities_load` instead.
    /// Surfacing every enabled skill in the system prompt routinely blew
    /// the budget on small-context models (55k+ tokens with reference
    /// inlining); the loader path keeps the schema small and lets the
    /// model decide which skill bodies it actually needs.
    ///
    /// `soulSection` is passed in (rather than re-read here) because the
    /// read needs to happen once per compose — `finalizeContext` calls
    /// `resolveSoul`, the preview path calls `loadSoulContent` directly.
    @MainActor
    private static func appendGatedSections(
        composer: inout SystemPromptComposer,
        snapshot: AgentConfigSnapshot,
        toolset: ResolvedToolset,
        agentId: UUID,
        executionMode: ExecutionMode,
        soulSection: String? = nil,
        trace: TTFTTrace? = nil,
        allowBlockingDBOpen: Bool = true
    ) {
        let tools = toolset.tools
        let effectiveToolsOff = toolset.effectiveToolsOff
        let resolvedNames = Set(tools.map { $0.function.name })
        let channelDestinationsSection: String?
        if !effectiveToolsOff, resolvedNames.contains(AgentChannelPublishTool.toolName) {
            channelDestinationsSection = Self.channelDestinationsSection(
                bindings: AgentChannelAutoDestinationResolver.effectiveConfiguration()
                    .usableBindings(
                        agentId: agentId,
                        source: ChatExecutionContext.currentSessionSource
                    ),
                source: ChatExecutionContext.currentSessionSource
            )
        } else {
            channelDestinationsSection = nil
        }

        // Production's default harness contract is intentionally small.
        // Tool schemas are the operational source of truth; security is
        // enforced by path validation, Seatbelt, and the VM boundary rather
        // than repeated prompt policy. Rich feature guidance remains
        // schema-gated on non-workspace/configuration surfaces.
        if snapshot.agentId != Agent.defaultId
            || executionMode.usesHostFolderTools
            || executionMode.usesSandboxTools
        {
            let capabilityNames = Self.capabilityToolNames(inSchema: resolvedNames)
            var sandboxStateSection: String?
            var agentDBSchemaSection: String?

            if executionMode.usesSandboxTools, let soulSection {
                composer.append(
                    .static(
                        id: "soul",
                        label: "Soul",
                        content: SystemPromptTemplates.soulSection(
                            soulSection,
                            names: capabilityNames ?? .legacy
                        )
                    )
                )
            }
            if !effectiveToolsOff, executionMode.usesSandboxTools {
                let home = OsaurusPaths.inContainerAgentHome(
                    SandboxAgentProvisioner.linuxName(for: agentId.uuidString)
                )
                composer.append(
                    .static(
                        id: "sandbox",
                        label: L("Working Directory"),
                        content:
                            "## Working directory\n**Path:** \(home)\n"
                            + "This run is isolated in the VM. Host folders are unavailable. "
                            + "Use paths relative to this directory. "
                            + "Osaurus capability ids are separate from sandbox programs and libraries: "
                            + "check programs/libraries with shell_run, and install exact missing package "
                            + "names with sandbox_install. "
                            + "Use the workspace tools to complete requested work now; "
                            + "do not only describe or promise it. "
                            + "After creating or changing runnable code, run an available "
                            + "syntax/build/test/behavior check before saying it works; a successful "
                            + "file mutation proves only that bytes were saved. "
                            + "To append while preserving a file, call file_write with mode "
                            + "append and put only the new bytes in content. "
                            + "Keep each file_write content under "
                            + "\(WorkspaceToolContract.recommendedWriteChunkCharacters) characters; "
                            + "for larger files use repeated calls with mode append."
                    )
                )
                let state = SystemPromptTemplates.sandboxState(
                    secretNames: AgentSecretsKeychain.secretIDs(agentId: agentId),
                    installedPackages: SandboxPackageManifest.shared.installed(
                        agentId: agentId.uuidString
                    )
                )
                if !state.isEmpty {
                    sandboxStateSection = state
                }
            } else if !effectiveToolsOff, let folder = executionMode.folderContext {
                composer.append(
                    .static(
                        id: "folderContext",
                        label: L("Working Directory"),
                        content: SystemPromptTemplates.leanFolderContext(from: folder)
                    )
                )
            }
            if !effectiveToolsOff,
                snapshot.dbEnabled,
                !resolvedNames.isDisjoint(with: agentDBToolNames)
            {
                let schema = Self.renderSchemaSnapshot(
                    agentId: agentId,
                    allowOpen: allowBlockingDBOpen
                )
                if !schema.isEmpty {
                    agentDBSchemaSection = schema
                }
            }

            // Keep the lean custom-agent contract: expose only the frozen
            // enabled-capabilities manifest needed to use assigned plugins.
            // Rich grounding/nudge/model-family guidance remains off this
            // path. Folder mode is deliberately NOT excluded — the workspace
            // prompt stays lean, but a folder-attached agent still needs to
            // be told its MCP/plugin/skill capabilities exist (see the guard
            // rationale in `resolveEnabledManifest`).
            if snapshot.agentId != Agent.defaultId,
                !effectiveToolsOff,
                let capabilityNames,
                let manifestSection = toolset.enabledManifest,
                !manifestSection.isEmpty
            {
                composer.append(
                    .static(
                        id: "enabledManifest",
                        label: L("Enabled Capabilities"),
                        content: manifestSection
                    )
                )
                if SystemPromptTemplates.enabledManifestNeedsSkillGovernance(
                    manifestSection,
                    compact: toolset.prefersCompactPrompt
                ) {
                    composer.append(
                        .static(
                            id: "skillsGovern",
                            label: L("Skills that govern tool groups"),
                            content: SystemPromptTemplates.skillsGovernToolGroups(
                                names: capabilityNames
                            )
                        )
                    )
                }
            }

            appendPluginCreatorSection(
                composer: &composer,
                snapshot: snapshot,
                effectiveToolsOff: effectiveToolsOff,
                executionMode: executionMode,
                prefersCompactPrompt: toolset.prefersCompactPrompt,
                trace: trace
            )

            // Dynamics follow every static section so the frozen manifest
            // remains inside the reusable KV prefix.
            if let agentDBSchemaSection {
                composer.append(
                    .dynamic(
                        id: "agentDBSchema",
                        label: L("Agent DB Schema"),
                        content: agentDBSchemaSection
                    )
                )
            }
            if let sandboxStateSection {
                composer.append(
                    .dynamic(
                        id: "sandboxState",
                        label: L("Sandbox State"),
                        content: sandboxStateSection
                    )
                )
            }
            if let channelDestinationsSection {
                composer.append(
                    .dynamic(
                        id: "channelDestinations",
                        label: L("Channel Destinations"),
                        content: channelDestinationsSection
                    )
                )
            }
            return
        }

        // Mid-session-mutable content captured while building the static
        // framing, but emitted LATER as dynamic sections (after the static
        // prefix break) so a schema change, package install, or new secret
        // mid-session stays fresh without rewriting the cached KV prefix.
        var agentDBSchemaSection: String?
        var sandboxStateSection: String?

        // ── Statics ──────────────────────────────────────────────────

        // SOUL: agent-authored identity layer for sandbox mode. Sits
        // between the user-authored persona (above) and operational
        // directives (below) so render order reinforces the inline
        // "earlier sections take precedence" framing — persona wins on
        // conflict. Sandbox-only by design: folder-mode agents are
        // short-lived and project-bound. `composer.append` drops empty
        // sections, so we don't re-check past the `nil` gate.
        if let soulSection {
            composer.append(
                .static(
                    id: "soul",
                    label: "Soul",
                    content: SystemPromptTemplates.soulSection(soulSection)
                )
            )
        }

        // Self-improvement: capture reusable work (scripts, clients, plugins)
        // and durable cross-session patterns (SOUL.md) so later sessions reuse
        // them instead of re-deriving. Sandbox-only — it references workspace
        // persistence, sandbox plugins, and SOUL.md, none of which exist
        // outside sandbox mode. The plugin-build bullets drop out when the
        // agent can't create plugins so the section spends no context on an
        // unavailable path. Sits right after SOUL so the two identity/learning
        // layers read together. Session-constant inputs keep it static.
        if !effectiveToolsOff, executionMode.usesSandboxTools {
            composer.append(
                .static(
                    id: "selfImprovement",
                    label: L("Self-Improvement"),
                    content: SystemPromptTemplates.selfImprovementGuidance(
                        canCreatePlugins: snapshot.canCreatePlugins,
                        compact: toolset.prefersCompactPrompt,
                        hostWritableCombined: executionMode.allowsHostWriteTools
                    )
                )
            )
        }

        // Agent DB onboarding (spec §5.5.3). Gated on `dbEnabled`; rendered
        // before model-family guidance so it sits as close to the persona as
        // possible (the agent should read it before any operational
        // guidance). The onboarding framing is session-constant, so it stays
        // STATIC.
        //
        // The schema snapshot (§5.5.5) is mid-session-mutable — the agent
        // creates/alters tables as it works — so it is captured here but
        // emitted as the DYNAMIC `agentDBSchema` section below, keeping the
        // cached prefix byte-stable across turns. The snapshot read can fail
        // when the DB couldn't open (rare); fall back to the "no tables yet"
        // empty state so the prompt is well-formed even when state is
        // partially broken.
        if !effectiveToolsOff, snapshot.dbEnabled {
            composer.append(
                .static(
                    id: "agentDB",
                    label: L("Agent DB"),
                    content: OnboardingPrompt.block
                )
            )
            let snapshotText = Self.renderSchemaSnapshot(
                agentId: agentId,
                allowOpen: allowBlockingDBOpen
            )
            if !snapshotText.isEmpty {
                agentDBSchemaSection = snapshotText
            }
        }

        // Per-model-family nudge — small, targeted blocks for known model
        // weaknesses (Gemma over-enumerates, GPT under-acts, LFM2/other
        // hedge and refuse without an obedience counterweight). Every
        // family now resolves to a block, including a deliberately minimal
        // default for unrecognised families; the blocks stay short so this
        // is not the bloated universal "agentic workflow" addendum we avoid.
        // `.small` windows get the compact variant where one exists — the
        // size class is session-constant, so the choice is KV-cache safe.
        // See ModelFamilyGuidance.swift.
        if !effectiveToolsOff,
            let familyGuidance = ModelFamilyGuidance.guidance(
                forModelId: snapshot.model,
                modelType: snapshot.modelType,
                compact: toolset.prefersCompactPrompt
            )
        {
            composer.append(
                .static(
                    id: "modelFamilyGuidance",
                    label: L("Model Family Guidance"),
                    content: familyGuidance
                )
            )
        }

        // Grounding: a short anti-fabrication rule for any tool-enabled
        // chat. Gated on tools being present (off-case is handled by the
        // persona's "answer from your own knowledge" clause) — both the
        // tools-off flag and the resolved schema are session-constant, so
        // this stays KV-cache safe. The full variant names
        // `capabilities_discover` / the Enabled capabilities list, so it is
        // only emitted when that tool is actually in the schema; otherwise
        // the tool-name-free base variant avoids the recitation-loop trap
        // `defaultPersona` documents.
        if !effectiveToolsOff, !resolvedNames.isEmpty {
            composer.append(
                .static(
                    id: "grounding",
                    label: L("Grounding"),
                    content: SystemPromptTemplates.groundingDirective(
                        discoveryAvailable: resolvedNames.contains("capabilities_discover"),
                        compact: toolset.prefersCompactPrompt
                    )
                )
            )
        }

        // Code style + risk-aware actions — general engineering discipline
        // for any agent that can mutate the user's filesystem or run
        // arbitrary code. Sandbox tools, folder tools, and any future
        // plugin tool that writes all qualify. The set lives at the top
        // of the file so it can grow as new mutation-capable tools land.
        if !effectiveToolsOff,
            !resolvedNames.isDisjoint(with: Self.codeEditToolNames)
        {
            composer.append(
                .static(
                    id: "codeStyle",
                    label: L("Code Style"),
                    content: toolset.prefersCompactPrompt
                        ? SystemPromptTemplates.codeStyleGuidanceCompact
                        : SystemPromptTemplates.codeStyleGuidance
                )
            )
        }
        if !effectiveToolsOff,
            !resolvedNames.isDisjoint(with: Self.mutationToolNames)
        {
            composer.append(
                .static(
                    id: "riskAware",
                    label: L("Risk-Aware Actions"),
                    content: toolset.prefersCompactPrompt
                        ? SystemPromptTemplates.riskAwareGuidanceCompact
                        : SystemPromptTemplates.riskAwareGuidance
                )
            )
        }

        // Secret handling: route secret collection through the out-of-band
        // `sandbox_secret_set` prompt instead of chat (which is persisted to
        // the transcript), and keep secret values out of files, tool args, and
        // notes. Sandbox-only — it leans on the sandbox secret tools and the
        // env-var exposure that only exists in sandbox mode. Sits next to
        // Risk-aware so the two safety blocks read together. Session-constant.
        if !effectiveToolsOff, executionMode.usesSandboxTools {
            composer.append(
                .static(
                    id: "secretHandling",
                    label: L("Secret Handling"),
                    content: toolset.prefersCompactPrompt
                        ? SystemPromptTemplates.secretHandlingGuidanceCompact
                        : SystemPromptTemplates.secretHandlingGuidance
                )
            )
        }

        // Subagent capability guidance (Computer Use, Image Generation): one
        // registry-driven loop instead of parallel hand-written blocks. Each
        // capability's guidance is rendered only when its PRIMARY tool actually
        // resolved into the schema — the authoritative per-agent gate already
        // ran in `resolveTools`, so a section can never advertise a subagent
        // the model can't invoke. Schema-gated like codeStyle / riskAware /
        // agentLoopGuidance, so it stays session-constant + KV-cache stable,
        // and the registry's stable order keeps the rendered byte sequence
        // fixed (computerUse before imageGeneration, as before).
        if !effectiveToolsOff {
            // When `image` resolved but no ready edit model is installed, the
            // schema is the generation-only variant (see `resolveTools`), so
            // pick the matching generation-only guidance — the prompt must never
            // claim an edit the runtime can't perform. Read off the same warmed
            // cache the schema gate used (this is @MainActor).
            let hasReadyImageEditModel = ModelPickerItemCache.shared.hasReadyImageEditModel
            for capability in SubagentCapabilityRegistry.all {
                guard let sectionId = capability.guidanceSectionId,
                    let labelKey = capability.guidanceLabelKey,
                    resolvedNames.contains(capability.primaryToolName)
                else { continue }
                let imageGenerationOnly =
                    capability.id == SubagentCapabilityRegistry.image.id
                    && !hasReadyImageEditModel
                let fullGuidance =
                    imageGenerationOnly
                    ? SystemPromptTemplates.imageGenerationOnlyGuidance
                    : capability.guidance
                guard let fullGuidance else { continue }
                let compactGuidance =
                    imageGenerationOnly
                    ? SystemPromptTemplates.imageGenerationOnlyGuidanceCompact
                    : capability.guidanceCompact
                let guidance =
                    toolset.prefersCompactPrompt
                    ? (compactGuidance ?? fullGuidance)
                    : fullGuidance
                composer.append(
                    .static(
                        id: sectionId,
                        label: String(
                            localized: String.LocalizationValue(labelKey),
                            bundle: .module
                        ),
                        content: guidance
                    )
                )
            }
        }

        // Spawn guidance enumerates the launching agent's request-local ACTUAL
        // spawnable agents + models — so it can't ride the generic guidance loop
        // above (whose `spawn` entry intentionally keeps `guidance == nil`).
        // Render a dedicated block whenever any spawn tool reached the schema,
        // listing only the tool(s) that resolved and reading the same pools
        // (`SubagentToolVisibility` + the snapshot/config) the visibility gate
        // used, so the prompt and the callable tools can never disagree. It joins
        // the cached prefix until a pool edit re-renders it (a one-time bust, like
        // the other config-driven sections). HTTP parity is automatic: both
        // surfaces compose through here.
        if !effectiveToolsOff {
            let agentToolResolved = resolvedNames.contains(
                SubagentCapabilityRegistry.spawnAgentToolName
            )
            let modelToolResolved = resolvedNames.contains(
                SubagentCapabilityRegistry.spawnModelToolName
            )
            let batchToolResolved = resolvedNames.contains(
                SubagentCapabilityRegistry.spawnBatchToolName
            )
            if agentToolResolved || modelToolResolved || batchToolResolved {
                let fallbackConfig = SubagentConfigurationStore.snapshot()
                // The worker tool-reach line must match what the runtime will
                // actually grant, so resolve it through the SAME helper the
                // spawn kind uses (default agent → global config, custom →
                // its own settings).
                let toolAccess =
                    snapshot.spawnConfiguration?.toolAccess
                    ?? SubagentToolVisibility.effectiveSpawnToolAccess(
                        isDefault: snapshot.agentId == Agent.defaultId,
                        config: fallbackConfig,
                        settings: AgentManager.shared.agent(for: snapshot.agentId)?.settings
                    )
                let maxParallel =
                    snapshot.spawnConfiguration?.budgets.maxParallelSpawns
                    ?? SubagentToolVisibility.effectiveBudgets(
                        isDefault: snapshot.agentId == Agent.defaultId,
                        config: fallbackConfig,
                        settings: AgentManager.shared.agent(for: snapshot.agentId)?.settings,
                        sharedParallelLimit: SpawnBatchConcurrencyContract.configuredLimit(
                            for: ServerRuntimeSettingsStore.snapshot()
                        )
                    ).normalized.maxParallelSpawns
                composer.append(
                    .static(
                        id: "spawn",
                        label: L("Subagents"),
                        content: SystemPromptTemplates.spawnGuidance(
                            agents: (agentToolResolved || batchToolResolved)
                                ? toolset.spawnTargets.agents : [],
                            models: (modelToolResolved || batchToolResolved)
                                ? toolset.spawnTargets.models : [],
                            availableToolNames: resolvedNames,
                            toolAccess: toolAccess,
                            maxParallel: maxParallel
                        )
                    )
                )
            }
        }

        // Knowledge grant manifest: schema-gated like `spawn` above. The
        // retrieval tools resolving into the schema is not enough affordance
        // on its own — their descriptions don't say what the granted corpora
        // contain, so a small model never connects a domain question to
        // `search_knowledge` and answers from thin air. Enumerating the
        // ACTUAL grants (name + summary, captured on `snapshot`) makes the
        // collection's own description the trigger. Static: the grant set is
        // session-constant; a grant or summary edit re-renders it (a
        // one-time cached-prefix bust, like the other config-driven
        // sections).
        if !effectiveToolsOff,
            !resolvedNames.isDisjoint(with: Self.knowledgeToolNames),
            !snapshot.knowledgeCollections.isEmpty
        {
            composer.append(
                .static(
                    id: "knowledge",
                    label: L("Knowledge"),
                    content: SystemPromptTemplates.knowledgeGuidance(
                        collections: snapshot.knowledgeCollections
                    )
                )
            )
        }

        // Agent-loop guidance: short cheat-sheet for the chat-layer-
        // intercepted tools (todo / complete / clarify / share_artifact).
        // Always rendered when any loop tool resolves into the schema:
        // gating it on prior loop use (the old behaviour) meant the model
        // never saw the "when to call which" guide on its FIRST multi-step
        // task — exactly when it decides whether to keep a todo list at
        // all — and the section appearing mid-session busted the cached
        // prefix once. Schema-gated, so it is session-constant and
        // KV-cache stable. `.tiny` never reaches here (tools off).
        if !effectiveToolsOff,
            !resolvedNames.isDisjoint(with: Self.agentLoopToolNames)
        {
            composer.append(
                .static(
                    id: "agentLoopGuidance",
                    label: L("Agent Loop"),
                    // The `share_artifact` bullet rides only when the tool
                    // actually resolved — the orchestrator surface excludes
                    // it (workers deliver artifacts), and naming an
                    // uncallable tool is the recitation-loop trap.
                    content: SystemPromptTemplates.agentLoopGuidance(
                        compact: toolset.prefersCompactPrompt,
                        includeShareArtifact: resolvedNames.contains("share_artifact")
                    )
                )
            )
        }

        // Mode-specific capability framing: sandbox section when sandbox
        // tools are active, working-directory framing when chat is mounted
        // on a host folder. Static so it joins the cached prefix.
        //
        // Suppressed when tools are off (`effectiveToolsOff`): with no tool
        // schemas in the request, the dispatch tables describe tools the
        // model can't call (a hallucination invite) and — for tiny-context
        // models, the dominant always-on block — bury the user's turn in a
        // ~4K window. `effectiveToolsOff` is session-constant (agent toggle
        // OR size class), so this gate is KV-cache safe.
        if !effectiveToolsOff, executionMode.usesSandboxTools {
            // Derived identically to how the sandbox tools register their
            // home (`SandboxToolRegistrar` -> `BuiltinSandboxTools.register`)
            // so the prompt names the exact path `cwd` validation accepts.
            let sandboxHome = OsaurusPaths.inContainerAgentHome(
                SandboxAgentProvisioner.linuxName(for: agentId.uuidString)
            )
            composer.append(
                .static(
                    id: "sandbox",
                    label: L("Chat Sandbox"),
                    content: SystemPromptTemplates.sandbox(
                        home: sandboxHome,
                        hostReadCombined: executionMode.hostReadContext != nil,
                        hostWritable: executionMode.allowsHostWriteTools,
                        backgroundEnabled: snapshot.autonomousConfig?.backgroundProcessEnabled ?? false,
                        compact: toolset.prefersCompactPrompt
                    )
                )
            )
            // Mid-session-mutable: installed packages + configured secrets.
            // Captured here but emitted as the DYNAMIC `sandboxState` section
            // below so a `sandbox_install` or new secret stays fresh without
            // rewriting the cached prefix. `""` when nothing is recorded.
            let secretNames = AgentSecretsKeychain.secretIDs(agentId: agentId)
            let installedPackages = SandboxPackageManifest.shared.installed(
                agentId: agentId.uuidString
            )
            let state = SystemPromptTemplates.sandboxState(
                secretNames: secretNames,
                installedPackages: installedPackages
            )
            if !state.isEmpty {
                sandboxStateSection = state
            }
            // Combined mode: a host workspace rides alongside the sandbox
            // (read-only, or writable via the `allowHostFolderWrites`
            // opt-in). Append the workspace section + the `## Files`
            // path-routing block AFTER the sandbox section so the agent
            // reads sandbox framing first, then learns the workspace is a
            // separate filesystem. Static so it joins the cached prefix.
            if let hostRead = executionMode.hostReadContext {
                let writable = executionMode.allowsHostWriteTools
                composer.append(
                    .static(
                        id: "combinedHostRead",
                        label: writable ? L("Host Workspace") : L("Host Workspace (read-only)"),
                        content: SystemPromptTemplates.combinedHostRead(
                            from: hostRead,
                            allowSecretReads: snapshot.autonomousConfig?.allowHostSecretReads ?? false,
                            writable: writable
                        )
                    )
                )
            }
        } else if !effectiveToolsOff, let folder = executionMode.folderContext {
            composer.append(
                .static(
                    id: "folderContext",
                    label: L("Working Directory"),
                    content: SystemPromptTemplates.folderContext(from: folder)
                )
            )
            // Bulk-edit steering: constant text, `.static` so it joins the
            // cached KV prefix (one-time cold prefill on update, byte-stable
            // per turn thereafter). Ordering: after folderContext so it
            // reads as a refinement of the folder tool surface.
            composer.append(
                .static(
                    id: "bulkEditGuidance",
                    label: L("Bulk Edits"),
                    content: SystemPromptTemplates.bulkEditGuidance()
                )
            )
        }

        // Capability-discovery nudge: explain how to recover when the
        // current tool kit is incomplete. The gate follows the actual
        // schema, not the mode label: manual-mode agents still carry
        // `capabilities_discover` / `capabilities_load` as pragmatic
        // always-loaded tools.
        //
        // KV-cache stability: capability prompt sections are determined only
        // by the resolved static schema, never by query wording.
        if toolset.capabilityPromptSectionsEnabled,
            !effectiveToolsOff,
            tools.contains(where: { $0.function.name == "capabilities_discover" })
        {
            // Sandbox mode needs its explicit build/escalation ladder.
            // Verbose non-sandbox prompts retain the discover/load tutorial.
            // Compact non-sandbox prompts already carry the complete contract
            // in compact Grounding + the discovery/load tool schemas, so a
            // second prose section would only repeat those instructions.
            let nudge: String?
            if executionMode.usesSandboxTools {
                nudge = SystemPromptTemplates.capabilityDiscoveryNudgeSandbox(
                    canCreatePlugins: snapshot.canCreatePlugins,
                    compact: toolset.prefersCompactPrompt
                )
            } else {
                nudge =
                    toolset.prefersCompactPrompt
                    ? nil
                    : SystemPromptTemplates.capabilityDiscoveryNudge
            }
            if let nudge {
                composer.append(
                    .static(
                        id: "capabilityNudge",
                        label: L("Capability Discovery"),
                        content: nudge
                    )
                )
            }
        }

        // Enabled capabilities manifest: the grounded answer for loadable
        // dynamic tools and skills. The schema only carries a fixed hot subset;
        // without this block a small model looks at its schema, sees nothing,
        // and denies a capability that is actually enabled. Always-injected
        // gated built-ins are grounded by their live schema/guidance instead;
        // listing them here would falsely imply capabilities_load can bypass
        // their per-agent gates. We inject every loadable tool + plugin skill
        // grouped by plugin, plus a trailing standalone-skills group, so
        // tools AND skills) are answerable from grounded context with zero
        // tool calls. This is the single grounded enumeration: it subsumes
        // the old "Plugin Companions" and "Skill Suggestions" sections.
        //
        // The string is rendered+frozen in `resolveEnabledManifest` and
        // injected as a STATIC section so it joins the cached KV prefix and
        // stays byte-stable across turns — the manifest no longer shrinks as
        // the agent loads tools. Verbose manifests receive the companion
        // `skillsGovern` block only when a plugin actually contains both a
        // skill and tools; compact manifests already encode that workflow in
        // their single `plugin/<id> — skill-governed` load action.
        if let manifestSection = toolset.enabledManifest, !manifestSection.isEmpty {
            composer.append(
                .static(
                    id: "enabledManifest",
                    label: L("Enabled Capabilities"),
                    content: manifestSection
                )
            )
            if SystemPromptTemplates.enabledManifestNeedsSkillGovernance(
                manifestSection,
                compact: toolset.prefersCompactPrompt
            ) {
                composer.append(
                    .static(
                        id: "skillsGovern",
                        label: L("Skills that govern tool groups"),
                        content: SystemPromptTemplates.skillsGovernToolGroups(
                            names: Self.capabilityToolNames(inSchema: resolvedNames) ?? .legacy
                        )
                    )
                )
            }
        }

        appendPluginCreatorSection(
            composer: &composer,
            snapshot: snapshot,
            effectiveToolsOff: effectiveToolsOff,
            executionMode: executionMode,
            prefersCompactPrompt: toolset.prefersCompactPrompt,
            trace: trace
        )

        // ── Dynamics ─────────────────────────────────────────────────

        // Agent DB schema snapshot + live sandbox state (installed packages
        // / configured secrets). Both derive from mid-session-mutable state,
        // so they sit AFTER the static prefix break: they update freely turn
        // to turn (the model always sees current state) without invalidating
        // the cached KV prefix. The framing for each lives in its static
        // counterpart above (`agentDB` / `sandbox`).
        if let agentDBSchemaSection {
            composer.append(
                .dynamic(
                    id: "agentDBSchema",
                    label: L("Agent DB Schema"),
                    content: agentDBSchemaSection
                )
            )
        }
        if let sandboxStateSection {
            composer.append(
                .dynamic(
                    id: "sandboxState",
                    label: L("Sandbox State"),
                    content: sandboxStateSection
                )
            )
        }

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
                    label: L("Sandbox Unavailable"),
                    content: Self.sandboxUnavailableNotice(reason: reason)
                )
            )
            trace?.set("sandboxUnavailable", reason.kind.rawValue)
        }

        // Channel destinations: the redacted list of operator-approved
        // proactive publish routes for THIS agent and THIS run source.
        // Dynamic on purpose — destination settings are mid-session-mutable
        // (mode/rate/guidance edits, new bindings), so the section re-reads
        // the store each turn without rewriting the cached static prefix.
        // Gated on the publish tool actually being in the schema so the
        // prompt never advertises a capability the model can't invoke.
        if let channelDestinationsSection {
            composer.append(
                .dynamic(
                    id: "channelDestinations",
                    label: L("Channel Destinations"),
                    content: channelDestinationsSection
                )
            )
        }

    }

    /// True when any Agent Channel surface is configured: an enabled custom
    /// JSON connection, a native provider (Discord/Slack/Telegram/iMessage)
    /// with configured rooms, or any outbound destination binding. The old
    /// check only saw enabled CUSTOM connections, so agents using only the
    /// native providers never got the `agent_channel_*` family into their
    /// enabled manifest.
    @MainActor
    static func hasAnyConfiguredAgentChannel(
        configuration: AgentChannelConfiguration
    ) -> Bool {
        if configuration.connections.contains(where: \.enabled) { return true }
        if !configuration.bindings.isEmpty { return true }
        let discord = DiscordConnectionService.shared.configuration()
        if !discord.readableChannelIds.isEmpty || !discord.writableChannelIds.isEmpty {
            return true
        }
        let slack = SlackConnectionService.shared.configuration()
        if !slack.readableChannelIds.isEmpty || !slack.writableChannelIds.isEmpty
            || !slack.workspaceAccounts.isEmpty
        {
            return true
        }
        let telegram = TelegramConnectionService.shared.configuration()
        if !telegram.readableChatIds.isEmpty || !telegram.writableChatIds.isEmpty {
            return true
        }
        let imessage = IMessageConnectionService.shared.configuration()
        if !imessage.readableChatIds.isEmpty || !imessage.writableChatIds.isEmpty {
            return true
        }
        let whatsapp = WhatsAppConnectionService.shared.configuration()
        if !whatsapp.readableChatIds.isEmpty || !whatsapp.writableChatIds.isEmpty {
            return true
        }
        return false
    }

    /// Render the redacted, deterministic "Channel Destinations" section for
    /// one agent + run source. Lists ONLY this agent's usable bindings that
    /// allow the current run source — stable binding ids, labels,
    /// connection/room display ids, outbound mode, and operator guidance.
    /// Never secrets, credentials, sender identities, or another agent's
    /// destinations. Returns nil when nothing is publishable from this run
    /// (including unmappable/absent sources — plugin, HTTP, and inbound
    /// channel runs must not be told they can publish).
    static func channelDestinationsSection(
        bindings: [AgentChannelBinding],
        source: SessionSource?
    ) -> String? {
        guard let source,
            let runSource = AgentChannelBindingRunSource(sessionSource: source)
        else { return nil }
        let visible =
            bindings
            .filter { $0.isUsable && $0.allows(source: runSource) }
            .sorted { $0.id < $1.id }
        guard !visible.isEmpty else { return nil }

        var lines: [String] = []
        lines.append(
            "You may proactively publish messages to these operator-approved destinations "
                + "with the `agent_channel_publish` tool. Reference destinations ONLY by "
                + "`binding_id`; never invent destinations or raw room ids. Use a stable "
                + "`intent_key` per logical message so retries never double-send."
        )
        lines.append("")
        for binding in visible {
            let modeNote: String
            switch binding.outboundMode {
            case .off:
                continue
            case .draft:
                modeNote = "records a local draft for the operator; nothing is sent"
            case .confirm:
                modeNote = "requires operator confirmation before sending"
            case .autonomous:
                modeNote = "sends directly (host-enforced rate limits apply)"
            }
            var row =
                "- binding_id: `\(binding.id)` — \(binding.displayLabel) "
                + "(\(binding.connectionId) room \(binding.roomId)"
            if let threadId = binding.threadId, !threadId.isEmpty {
                row += ", thread \(threadId)"
            }
            row += "; mode: \(binding.outboundMode.rawValue) — \(modeNote))"
            lines.append(row)
            if !binding.guidance.isEmpty {
                lines.append("  When to use: \(binding.guidance)")
            }
        }
        lines.append("")
        lines.append(
            "Only publish when the destination's \"when to use\" guidance applies. "
                + "A `queued_for_approval`, `draft_recorded`, or `delivery_unknown` result "
                + "is final for this run — do not retry it. An optional `thread_id` may "
                + "target a thread inside the destination's room only when the destination "
                + "does not already pin a thread."
        )
        return lines.joined(separator: "\n")
    }

    /// Build the complete **loadable** enabled-capabilities manifest: every
    /// enabled dynamic tool plus every installed skill, regardless of what
    /// landed in this turn's hot schema. Authoritatively gated built-ins
    /// (Browser Use, Computer Use, Image, Spawn, AppleScript, and per-agent
    /// abilities) are injected directly when effective and are deliberately
    /// absent here: `capabilities_load` cannot bypass their owning flags.
    ///
    /// This is a static enumeration, not a per-turn delta. Under Design C the
    /// rendered string is frozen at session start and injected as a static
    /// prefix section, so it must NOT depend on the loaded tool subset or the
    /// user query — both of those vary per turn and would bust the prefix
    /// KV-cache. The model reaches every listed capability via
    /// `capabilities_load`; the manifest is purely the grounded answer to
    /// "do you have X".
    ///
    /// Contents:
    /// - **Tools**: all enabled loadable dynamic tools, grouped by plugin.
    /// - **Plugin skills**: installed skills carrying a `pluginId`, in their
    ///   plugin group (skills never enter the tool schema, so they are what
    ///   the "Skills that govern tool groups" rule binds to).
    /// - **Standalone skills**: installed skills with no `pluginId`, enumerated
    ///   directly from `SkillManager` into a trailing "Skills (no plugin)"
    ///   group — no embedding search, no query ranking.
    ///
    /// Order is deterministic for byte-stable rendering: plugin groups sorted
    /// by stable group id, tools/skills alphabetical within a group, and the
    /// standalone group always last. Usage-frequency ordering is a documented
    /// future hook, intentionally not built here.
    @MainActor
    /// Internal (not private): `capabilities_discover`'s exact paginated
    /// `list: "enabled"` mode reuses this derivation so its listing and the
    /// prompt manifest can never disagree about what is enabled.
    static func deriveEnabledManifest(
        agentId: UUID,
        includeAgentChannelTools: Bool = true
    ) -> [SystemPromptTemplates.ManifestPluginGroup] {
        let allowedTools = AgentManager.shared.effectiveEnabledToolNames(for: agentId).map(Set.init)

        // Tools: live dynamic catalog is already enabled-filtered; intersect
        // with the agent allowlist (nil = legacy global). The complete set —
        // no enabled-minus-loaded subtraction, so the manifest stays constant
        // as the agent loads tools mid-session.
        var toolsByGroup: [String: [SystemPromptTemplates.ManifestCapability]] = [:]
        var ungroupedTools: [SystemPromptTemplates.ManifestCapability] = []
        let hasEnabledAgentChannel =
            includeAgentChannelTools
            && Self.hasAnyConfiguredAgentChannel(
                configuration: AgentChannelConfigurationStore.load()
            )
        for entry in ToolRegistry.shared.listDynamicTools() {
            guard allowedTools?.contains(entry.name) ?? true,
                hasEnabledAgentChannel
                    || !ToolRegistry.agentChannelToolNames.contains(entry.name)
            else { continue }
            let capability = SystemPromptTemplates.ManifestCapability(
                name: entry.name,
                description: entry.description
            )
            if let group = ToolRegistry.shared.groupName(for: entry.name), !group.isEmpty {
                toolsByGroup[group, default: []].append(capability)
            } else if allowedTools != nil,
                ToolRegistry.shared.manifestsIndividually(entry.name)
            {
                // A small set of intentional ungrouped fixtures expose their
                // exact tool id rather than a nonexistent `plugin/<id>` alias.
                // Ordinary anonymous registry entries remain omitted.
                ungroupedTools.append(capability)
            }
        }

        // Plugin skills (pluginId != nil), plus standalone skills
        // (pluginId == nil) collected for the trailing synthetic group. Every
        // installed skill is universally available to custom agents; both come
        // straight from `SkillManager` — no search.
        var skillsByGroup: [String: [SystemPromptTemplates.ManifestCapability]] = [:]
        var standaloneCaps: [SystemPromptTemplates.ManifestCapability] = []
        for skill in SkillManager.shared.skills {
            let cap = SystemPromptTemplates.ManifestCapability(
                name: skill.name,
                description: skill.description
            )
            if let pluginId = skill.pluginId, !pluginId.isEmpty {
                skillsByGroup[pluginId, default: []].append(cap)
            } else {
                standaloneCaps.append(cap)
            }
        }

        // Deterministic order: group ids alphabetical, tools/skills
        // alphabetical within a group — no relevance reordering (there is no
        // per-turn loaded set to rank against under the static manifest).
        let allGroupIds = Set(toolsByGroup.keys).union(skillsByGroup.keys)
        let orderedIds = allGroupIds.sorted()
        var groups = orderedIds.map { groupId in
            SystemPromptTemplates.ManifestPluginGroup(
                groupId: groupId,
                pluginDisplay: pluginDisplayName(for: groupId),
                skills: (skillsByGroup[groupId] ?? []).sorted { $0.name < $1.name },
                tools: (toolsByGroup[groupId] ?? []).sorted { $0.name < $1.name }
            )
        }

        if !ungroupedTools.isEmpty {
            groups.append(
                SystemPromptTemplates.ManifestPluginGroup(
                    pluginDisplay: "Other enabled tools",
                    skills: [],
                    tools: ungroupedTools.sorted { $0.name < $1.name }
                )
            )
        }

        // Trailing synthetic group for standalone (non-plugin) skills,
        // alphabetical for byte-stable rendering.
        if !standaloneCaps.isEmpty {
            groups.append(
                SystemPromptTemplates.ManifestPluginGroup(
                    pluginDisplay: "Skills (no plugin)",
                    skills: standaloneCaps.sorted { $0.name < $1.name },
                    tools: []
                )
            )
        }
        return groups
    }

    /// Friendly plugin name for the manifest. Native plugins carry a
    /// `name` in their manifest; MCP / sandbox-plugin groups don't, so we
    /// fall back to the raw group id. Production prompt entry points wait for
    /// `PluginManager.ensurePromptCatalogReady()` before reaching here, so
    /// launch scheduling cannot alternate between the two representations.
    @MainActor
    private static func pluginDisplayName(for pluginId: String) -> String {
        if let loaded = PluginManager.shared.loadedPlugin(for: pluginId),
            let display = loaded.plugin.manifest.name,
            !display.isEmpty
        {
            return display
        }
        return pluginId
    }

    /// Tools that drive the chat-layer agent loop — `agentLoopGuidance`
    /// fires when any one of these resolves into the schema.
    static let agentLoopToolNames: Set<String> = [
        "todo", "complete", "clarify", "share_artifact",
    ]

    /// The Default agent's routing / escape-hatch write tool — used to create
    /// or activate another agent for out-of-scope asks (via a small
    /// declarative apply). Kept loaded even when other configure writes would
    /// be deferred on small local models, because the out-of-scope handoff is
    /// a core, frequent path that shouldn't pay a `capabilities_load`
    /// round-trip first. Since the declarative consolidation this is also the
    /// ONLY configure write tool.
    static let defaultAgentRoutingToolName = "osaurus_config"

    /// Tools that keep their full schema in the first-turn bootstrap. They
    /// are the path for discovering and upgrading every other capability, so
    /// their argument contracts must stay explicit even while the rest of the
    /// always-loaded surface ships as a compact schema skeleton.
    /// `capabilities` was missing from this list from the day the unified
    /// gateway replaced the legacy pair: custom agents saw it skeletonized to
    /// "Search for or load optional capabilities." with the `ids`/`query`
    /// property prose stripped — including the load-bearing "IDs are values,
    /// never callable function names" rule.
    private static let fullBootstrapToolNames: Set<String> = [
        "capabilities", "capabilities_discover", "capabilities_load",
    ]

    /// Loop tools whose ARGUMENT constraints must survive the bootstrap:
    /// the ≥30-char `summary` rule (`complete`), the option limits
    /// (`clarify`), and the path-vs-content rules (`share_artifact`) all
    /// live in property descriptions the plain skeleton strips — and these
    /// tools are typically called without a prior `capabilities_load` that
    /// would restore the full spec. Middle tier: one-line description +
    /// full parameter schema, so small models see the constraints on turn 1
    /// without paying for the full prose (which the `.small` budget
    /// guardrail can't afford).
    ///
    /// The knowledge write tools qualify on the same grounds, and the cost of
    /// leaving them out was measured rather than guessed. With their property
    /// descriptions stripped, a live model sent `documents` as a prose STRING
    /// instead of an array, and — because the rule "when replacing a
    /// document, carry its `---` frontmatter across, `read_knowledge` returns
    /// the body without it" lives in the `content` description — replaced
    /// documents kept losing their title, type and tags. Both are argument
    /// contracts, both were invisible, and neither tool is ever reached via a
    /// `capabilities_load` that would have restored the full spec.
    private static let constraintPreservingBootstrapToolNames: Set<String> = [
        "complete", "clarify", "share_artifact",
        "write_knowledge", "delete_knowledge", "edit_knowledge",
    ]

    /// Compress first-turn always-loaded specs by keeping the callable name,
    /// a one-line description, and the JSON shape without verbose property
    /// descriptions. Full schemas still enter via manual picks or
    /// `capabilities_load`; this only shrinks the baseline every chat pays
    /// before the user has asked for a concrete capability.
    /// Internal (not private) so the bootstrap-compaction invariants can be
    /// unit-tested directly without standing up the full tool registry.
    static func compactBootstrapSpec(_ tool: Tool) -> Tool {
        guard !fullBootstrapToolNames.contains(tool.function.name) else { return tool }
        return forcedCompactBootstrapSpec(tool)
    }

    /// Apply the bootstrap skeleton unconditionally — even to a tool normally
    /// kept at full spec by `fullBootstrapToolNames`. The Default agent uses
    /// `capabilities_load` in exactly one shape (`tool/<write>`, spelled out in
    /// its addendum), so it does not need the full multi-id-format schema the
    /// general bootstrap preserves; compacting it there saves ~165 tokens every
    /// turn. `constraintPreservingBootstrapToolNames` still keep their full
    /// parameter schema (only the prose description is trimmed).
    static func forcedCompactBootstrapSpec(_ tool: Tool) -> Tool {
        let name = tool.function.name
        if constraintPreservingBootstrapToolNames.contains(name) {
            return Tool(
                type: tool.type,
                function: ToolFunction(
                    name: name,
                    description: oneLineToolDescription(tool.function.description),
                    parameters: tool.function.parameters
                )
            )
        }
        return Tool(
            type: tool.type,
            function: ToolFunction(
                name: name,
                description: oneLineToolDescription(tool.function.description),
                parameters: compactParameterSkeleton(tool.function.parameters)
            )
        )
    }

    /// Tool descriptions often carry examples and recovery prose that duplicate
    /// the full schema. The bootstrap keeps just the first sentence because
    /// the model only needs to decide whether to call or load the tool.
    ///
    /// A sentence ends only on `.`/`!`/`?` that is followed by whitespace or
    /// the end of the string, so periods inside paths (`~/.venv/`) or
    /// abbreviations (`e.g.`) don't truncate the description mid-token.
    /// Compaction is a pure function of the description string, but the
    /// per-character Unicode scans below run for every bootstrap tool on
    /// every fresh compose (including the preview compose inside a view-body
    /// evaluation), so identical inputs are memoized.
    nonisolated(unsafe) private static var oneLineDescriptionMemo: [String: String] = [:]
    private static let oneLineDescriptionMemoLock = NSLock()

    private static func oneLineToolDescription(_ description: String?) -> String? {
        guard let description else { return nil }
        oneLineDescriptionMemoLock.lock()
        let cached = oneLineDescriptionMemo[description]
        oneLineDescriptionMemoLock.unlock()
        if let cached { return cached.isEmpty ? nil : cached }
        let result = oneLineToolDescriptionImpl(description)
        oneLineDescriptionMemoLock.lock()
        oneLineDescriptionMemo[description] = result ?? ""
        oneLineDescriptionMemoLock.unlock()
        return result
    }

    private static func oneLineToolDescriptionImpl(_ description: String) -> String? {
        let collapsed =
            description
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }

        let chars = Array(collapsed)
        var sentenceEndOffset: Int?
        for i in chars.indices where ".!?".contains(chars[i]) {
            let isLast = i == chars.count - 1
            // A period only ends a sentence when it's followed by whitespace
            // or the end of the string. Periods inside a path (`~/.venv/`) are
            // followed by a non-space character, so they never match.
            guard isLast || chars[i + 1].isWhitespace else { continue }
            // Don't break on a trailing period that belongs to a common
            // abbreviation (`e.g.`, `i.e.`, `etc.`), which is mid-sentence.
            if chars[i] == ".", Self.endsWithAbbreviation(chars, at: i) { continue }
            sentenceEndOffset = i
            break
        }
        let firstSentence =
            sentenceEndOffset.map { String(chars[...$0]) } ?? collapsed
        if firstSentence.count <= 180 { return firstSentence }
        return String(firstSentence.prefix(177)) + "..."
    }

    /// Common abbreviations whose trailing period is not a sentence boundary.
    private static let descriptionAbbreviations: Set<String> = [
        "e.g.", "i.e.", "etc.", "vs.", "approx.", "incl.", "no.", "fig.",
    ]

    /// Returns true when the word ending at `index` (a `.`) is a known
    /// abbreviation, so the caller keeps scanning for the real sentence end.
    private static func endsWithAbbreviation(_ chars: [Character], at index: Int) -> Bool {
        var start = index
        while start > 0, !chars[start - 1].isWhitespace { start -= 1 }
        let word = String(chars[start ... index]).lowercased()
        return descriptionAbbreviations.contains(word)
    }

    /// Drop recursive `description` fields but preserve the schema's shape,
    /// required keys, enums, and object/array nesting. That keeps argument
    /// validation legible for small models while removing the prose that
    /// dominates the first-turn `tools[]` token cost.
    private static func compactParameterSkeleton(_ value: JSONValue?) -> JSONValue? {
        guard let value else { return nil }
        return compactSchema(value, keysArePropertyNames: false)
    }

    /// Recursive worker for `compactParameterSkeleton`. `keysArePropertyNames`
    /// is true when walking the children of a `"properties"` object — those
    /// keys are parameter NAMES (e.g. a parameter literally named
    /// `description`) and must be preserved. Elsewhere `"description"` is a
    /// JSON-Schema annotation and is dropped. Without this distinction the
    /// compaction silently deletes a `description` parameter while leaving it
    /// in `required`, producing an impossible schema (the `sandbox_secret_set`
    /// bug).
    private static func compactSchema(
        _ value: JSONValue,
        keysArePropertyNames: Bool
    ) -> JSONValue {
        switch value {
        case .object(let object):
            var compact: [String: JSONValue] = [:]
            for (key, nested) in object {
                if keysArePropertyNames {
                    // Parameter name: keep it, compact its schema.
                    compact[key] = compactSchema(nested, keysArePropertyNames: false)
                } else if key == "description" {
                    // Schema annotation prose: drop.
                    continue
                } else {
                    compact[key] = compactSchema(nested, keysArePropertyNames: key == "properties")
                }
            }
            return .object(compact)
        case .array(let array):
            return .array(array.map { compactSchema($0, keysArePropertyNames: false) })
        case .string, .number, .bool, .null:
            return value
        }
    }

    /// Tools belonging to the Agent DB feature (spec §6). Gated on
    /// `AgentConfigSnapshot.dbEnabled` in `resolveTools` so agents that
    /// haven't opted in don't see them in the schema or the system
    /// prompt — keeps tool count + token cost the same as before for
    /// users who never enable the feature.
    static let agentDBToolNames: Set<String> = [
        "db_schema", "db_create_table", "db_alter_table", "db_migrate",
        "db_insert", "db_upsert", "db_import", "db_export", "db_update", "db_delete", "db_restore",
        "db_query", "db_execute",
        // Saved views (spec §6.3 / phase 2).
        "db_define_view", "db_run_view", "db_list_views", "db_drop_view",
    ]

    /// Self-scheduling + notification tools. Registered as built-ins but
    /// gated on `AgentConfigSnapshot.selfSchedulingEnabled` (a dedicated
    /// per-agent opt-in, decoupled from the schedule-mode picker) in
    /// `resolveTools`, so an agent that hasn't enabled self-scheduling
    /// doesn't pay the schema/token cost for tools it won't use.
    static let schedulerToolNames: Set<String> = [
        "schedule_next_run", "cancel_next_run", "notify",
    ]

    /// Knowledge retrieval tools. Registered as built-ins but gated on
    /// `AgentConfigSnapshot.knowledgeEnabled` (per-agent opt-in, pre-folded
    /// with "has at least one granted collection") in `resolveTools`.
    /// Collection scoping is enforced again at execution time inside the
    /// tools, so this strip is a token-cost optimization, not the boundary.
    static let knowledgeToolNames: Set<String> = [
        "search_knowledge", "read_knowledge", "list_knowledge",
        "flag_knowledge_stale", "list_knowledge_tickets",
        // Direct write follows the collection grant, not a separate role: the
        // grant is the access boundary and the approval modal is the consent
        // gate. Gating it behind an extra opt-in is what left an agent with
        // knowledge grants unable to write and unable to say why (#2439).
        "write_knowledge", "delete_knowledge", "edit_knowledge",
        "update_knowledge_ticket",
    ]

    /// Formerly curator-only knowledge tools.
    ///
    /// Now EMPTY. `propose_knowledge_update` was removed with the proposal
    /// architecture, and `update_knowledge_ticket` moved to the ordinary
    /// knowledge set: claiming or releasing a ticket is bookkeeping over an
    /// annotation, never a corpus mutation, so it does not need a role of its
    /// own. Kept as an empty set rather than deleted so the composer's
    /// gate/strip pair keeps its shape for a future privileged group.
    static let knowledgeCuratorToolNames: Set<String> = []

    /// Render the schema snapshot block injected after the onboarding
    /// prompt when `dbEnabled` is true. Best-effort: a failure to open
    /// the DB (e.g. the user just enabled the toggle and the first
    /// open hasn't run yet) falls back to the empty-state block so the
    /// agent never sees a half-rendered prompt. Sync because the
    /// underlying `LocalAgentBridge.schemaSnapshot` is sync.
    /// `allowOpen: false` (the preview/budget path, which runs during
    /// SwiftUI body evaluation) reads only an already-open cached
    /// connection — a first open does file I/O plus SQLCipher key
    /// derivation and has hung the main thread for 3+ seconds.
    static func renderSchemaSnapshot(agentId: UUID, allowOpen: Bool = true) -> String {
        guard allowOpen else {
            return LocalAgentBridge.shared.schemaSnapshotIfOpen(agentId: agentId)
                ?? SchemaSnapshot.emptyStateBlock
        }
        do {
            return try LocalAgentBridge.shared.schemaSnapshot(agentId: agentId)
        } catch {
            debugLog(
                "[Context:agentDB] schema snapshot unavailable for "
                    + "\(agentId.uuidString): \(error.localizedDescription); "
                    + "falling back to empty state"
            )
            return SchemaSnapshot.emptyStateBlock
        }
    }

    /// Tools that can mutate the user's filesystem, exec arbitrary code,
    /// or install dependencies. `codeStyleGuidance` and `riskAwareGuidance`
    /// fire whenever any one of these resolves into the schema. Grow this
    /// set as new write-capable tools land (plugin tools, future sandbox
    /// tools, etc.).
    static let mutationToolNames: Set<String> = [
        // sandbox built-ins
        "sandbox_write_file", "sandbox_exec",
        "sandbox_install",
        // folder tools
        "file_write", "file_edit", "shell_run",
    ]

    /// Subset of `mutationToolNames` that actually authors/edits files.
    /// `codeStyleGuidance` (an editing-discipline block) gates on this
    /// rather than the full mutation set so a chat that only has shell /
    /// install tools (e.g. "run this script") doesn't pay the code-style
    /// preamble. `riskAwareGuidance` keeps the broader `mutationToolNames`
    /// gate because destructive risk applies to exec/install too. Both
    /// gates are session-constant (driven by the frozen schema).
    static let codeEditToolNames: Set<String> = [
        "sandbox_write_file", "file_write", "file_edit",
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
    /// sections the next send will emit. Under Design C the schema is a fixed
    /// hot set and the enabled-capabilities manifest is query-independent, so
    /// there is no longer a per-turn preflight/skill-search delta to miss —
    /// the preview prices the static prefix exactly.
    ///
    /// Memory is out of scope (it's prepended to the user message, not the
    /// system prompt) — callers feed the per-turn estimate to
    /// `ContextBreakdown.from` separately, which surfaces the `Memory` row.
    @MainActor
    static func composePreviewContext(
        agentId: UUID,
        executionMode: ExecutionMode,
        model: String? = nil,
        modelType: String? = nil
    ) -> ComposedContext {
        // Same one-shot snapshot as the real send path so the popover
        // can never disagree with the next compose's gate decisions.
        let snapshot = AgentConfigSnapshot.capture(
            agentId: agentId,
            modelOverride: model,
            modelTypeOverride: modelType
        )
        return composePreviewContext(snapshot: snapshot, executionMode: executionMode)
    }

    /// Snapshot-taking variant of `composePreviewContext`. Lets the agent
    /// editor price a DRAFT capability state (local toggles that haven't
    /// gone through the debounced save yet) by constructing the snapshot
    /// itself instead of capturing the persisted one — while still running
    /// the exact section + tool gates the next real send would.
    @MainActor
    static func composePreviewContext(
        snapshot: AgentConfigSnapshot,
        executionMode: ExecutionMode
    ) -> ComposedContext {
        let agentId = snapshot.agentId
        var composer = forChat(
            snapshot: snapshot,
            agentId: agentId,
            executionMode: executionMode
        )
        let toolset = previewToolset(snapshot: snapshot, executionMode: executionMode)
        // Sync soul read — the preview path is itself sync and the file
        // is tiny + local. `resolveSoul` is just an async wrapper around
        // `loadSoulContent` for trace marks, so calling the underlying
        // helper directly keeps the popover honest with no I/O hop.
        let soulSection: String? =
            executionMode.usesSandboxTools
            ? loadSoulContent(
                linuxName: SandboxAgentProvisioner.linuxName(for: agentId.uuidString),
                maxBytes: soulCap(forModel: snapshot.model)
            )
            : nil
        appendGatedSections(
            composer: &composer,
            snapshot: snapshot,
            toolset: toolset,
            agentId: agentId,
            executionMode: executionMode,
            soulSection: soulSection,
            allowBlockingDBOpen: false
        )
        composer.applyExperimentAblation()

        let manifest = composer.manifest()
        let rendered = composer.render()

        return ComposedContext(
            prompt: rendered,
            manifest: manifest,
            tools: toolset.tools,
            toolTokens: ToolRegistry.shared.totalEstimatedTokens(for: toolset.tools),
            memorySection: nil,
            alwaysLoadedNames: toolset.alwaysLoadedNames,
            initialToolSpecs: toolset.sessionBaselineTools,
            cacheHint: manifest.staticPrefixHash(tools: toolset.tools),
            staticPrefix: manifest.staticPrefixContent,
            contextDisable: toolset.contextDisable
        )
    }

    /// Sync companion to `resolveToolset` for the preview path. Always passes
    /// nil for the freeze snapshot — the popover prices what
    /// `composeChatContext(query: "")` would emit, not a mid-session
    /// freeze.
    ///
    /// Prompt and tool shape are query-independent, so pricing against `""`
    /// matches every send made with the same settings and execution mode.
    @MainActor
    private static func previewToolset(
        snapshot: AgentConfigSnapshot,
        executionMode: ExecutionMode
    ) -> ResolvedToolset {
        let window = ContextSizeResolver.resolve(modelId: snapshot.model)
        let effectiveToolsOff = resolveEffectiveToolsOff(
            toolsDisabled: snapshot.toolsDisabled,
            globalToolsDisabled: snapshot.globalToolsDisabled,
            sizeClassDisablesTools: window.sizeClass.disablesTools,
            executionMode: executionMode
        )
        let contextDisable = ContextDisableInfo.from(
            sizeClass: window.sizeClass,
            modelId: snapshot.model,
            contextLength: window.contextLength,
            agentToolsOff: snapshot.toolsDisabled,
            agentMemoryOff: snapshot.memoryDisabled
        )
        let configuredSpawn = configuredSpawnPools(snapshot: snapshot)
        let spawnTargets =
            effectiveToolsOff
            ? .empty
            : SpawnDescriptors.resolveForPreview(
                agentIDs: configuredSpawn.agents,
                modelNames: configuredSpawn.models,
                modelNotes: configuredSpawn.notes,
                launcherModelOverride: configuredSpawn.launcherModelOverride
            )
        let tools = resolveTools(
            snapshot: snapshot,
            executionMode: executionMode,
            toolsDisabled: effectiveToolsOff,
            spawnTargets: spawnTargets
        )
        let alwaysLoadedNames = resolveAlwaysLoadedNames(
            tools: tools,
            executionMode: executionMode,
            frozenAlwaysLoadedNames: nil
        )
        // Static manifest is query-independent, so the preview can render the
        // exact section the next real send will emit — keeping the budget
        // popover honest about the enabled-capabilities cost.
        let enabledManifest = resolveEnabledManifest(
            snapshot: snapshot,
            agentId: snapshot.agentId,
            tools: tools,
            executionMode: executionMode,
            effectiveToolsOff: effectiveToolsOff,
            frozenManifest: nil,
            trace: nil
        )
        return ResolvedToolset(
            tools: tools,
            sessionBaselineTools: tools,
            enabledManifest: enabledManifest,
            alwaysLoadedNames: alwaysLoadedNames,
            spawnTargets: spawnTargets,
            contextDisable: contextDisable,
            sizeClass: window.sizeClass,
            effectiveToolsOff: effectiveToolsOff,
            capabilityPromptSectionsEnabled: true,
            prefersCompactPrompt: window.prefersCompactPrompt
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
            case .vmnetOwnedByOtherProcess:
                return (
                    "The sandbox VM is currently owned by another Osaurus process. "
                        + "Detail: \(reason.message)",
                    "Tell the user which process owns the sandbox and ask them to stop "
                        + "that app or eval run before retrying. Do not repeatedly retry "
                        + "sandbox startup in this task."
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

    /// Where this turn's tool list came from. `disabled` trumps everything;
    /// manual trumps the always-loaded fallback. (Under Design C the auto-mode
    /// schema is always the fixed always-loaded hot set plus `capabilities_load`
    /// picks — there is no per-turn preflight source.)
    private static func resolveToolSource(
        toolMode: ToolSelectionMode,
        effectiveToolsOff: Bool
    ) -> String {
        if effectiveToolsOff { return "disabled" }
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

    /// Resolve the full tool set for a request: built-in + manual picks,
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
        query _: String = "",
        additionalToolNames: LoadedTools = [],
        frozenAlwaysLoadedNames: LoadedTools? = nil,
        frozenToolSpecs: [Tool]? = nil,
        spawnTargets: SpawnTargetAvailabilitySnapshot? = nil
    ) -> [Tool] {
        let snapshot = AgentConfigSnapshot.capture(
            agentId: agentId,
            requestToolsDisabled: toolsDisabled
        )
        return resolveTools(
            snapshot: snapshot,
            executionMode: executionMode,
            toolsDisabled: toolsDisabled,
            additionalToolNames: additionalToolNames,
            frozenAlwaysLoadedNames: frozenAlwaysLoadedNames,
            frozenToolSpecs: frozenToolSpecs,
            spawnTargets: spawnTargets
        )
    }

    /// Resolve the model-visible sandbox control plane from the request's
    /// captured agent configuration. Registry membership is only availability;
    /// these gates are the authorization decision for both schema and execution
    /// scope. The init placeholder is the sole non-sandbox-mode exception.
    @MainActor
    static func visibleSandboxControlPlaneToolNames(
        snapshot: AgentConfigSnapshot,
        executionMode: ExecutionMode
    ) -> Set<String> {
        guard snapshot.autonomousEnabled else { return [] }

        let registered = ToolRegistry.shared.builtInSandboxToolNamesSnapshot
            .intersection(ToolRegistry.sandboxControlPlaneToolNames)
        if !executionMode.usesSandboxTools {
            return registered.intersection([BuiltinSandboxTools.initPendingToolName])
        }

        var visible = registered
        visible.remove(BuiltinSandboxTools.initPendingToolName)
        if !snapshot.canCreatePlugins {
            visible.remove("sandbox_plugin_register")
        }
        if snapshot.autonomousConfig?.backgroundProcessEnabled != true {
            visible.remove("sandbox_process")
        }
        return visible
    }

    @MainActor
    static func resolveTools(
        snapshot: AgentConfigSnapshot,
        executionMode: ExecutionMode,
        toolsDisabled: Bool = false,
        query _: String = "",
        additionalToolNames: LoadedTools = [],
        frozenAlwaysLoadedNames: LoadedTools? = nil,
        frozenToolSpecs: [Tool]? = nil,
        spawnTargets: SpawnTargetAvailabilitySnapshot? = nil
    ) -> [Tool] {
        guard !toolsDisabled else { return [] }

        let isManual = snapshot.toolMode == .manual
        let visibleSandboxControlPlane = visibleSandboxControlPlaneToolNames(
            snapshot: snapshot,
            executionMode: executionMode
        )

        var byName: [String: Tool] = [:]

        func add(_ specs: [Tool], replacingExisting: Bool = false) {
            for spec in specs where byName[spec.function.name] == nil {
                byName[spec.function.name] = spec
            }
            if replacingExisting {
                for spec in specs {
                    byName[spec.function.name] = spec
                }
            }
        }

        // Filter rule for always-loaded specs:
        //   - on turn 1 (`frozenAlwaysLoadedNames == nil`) keep everything,
        //   - on turn N intersect with the snapshot to keep the schema
        //     byte-stable for KV-cache reuse, plus an additive carve-out so
        //     sandbox tools that registered late (the init placeholder or real
        //     tools after provisioning) join the schema instead of being
        //     suppressed forever as "new mid-session tools".
        // Late-arriving plugin / MCP tools still need explicit
        // `capabilities_load` to appear — that path is the only sanctioned
        // way to grow the dynamic surface mid-session.
        let liveSandboxNames = ToolRegistry.shared.builtInSandboxToolNamesSnapshot
        let filtered: ([Tool]) -> [Tool] = { specs in
            specs.filter { spec in
                let name = spec.function.name
                guard let frozen = frozenAlwaysLoadedNames else { return true }
                return frozen.contains(name) || liveSandboxNames.contains(name)
            }
        }

        // Always-loaded baseline: built-ins (agent loop, share_artifact,
        // capability discovery) + sandbox/folder runtime when the mode is
        // active. Per-agent gated built-ins (render_chart, speak,
        // search_memory, scheduler trio) and `db_*` enter the baseline here
        // but are stripped below unless the agent opts in. The first-turn baseline
        // uses compact schema skeletons; manual picks and `capabilities_load`
        // replace those skeletons with full specs when a task proves it needs
        // the heavier argument contract.
        let baseline = filtered(ToolRegistry.shared.alwaysLoadedSpecs(mode: executionMode))
            .map(compactBootstrapSpec)
        add(baseline)

        // Design C: the auto-mode schema is the fixed hot set above plus
        // `capabilities_load` picks (`additionalToolNames`, below). There is
        // no per-turn preflight injection — capability breadth is grounded in
        // the static manifest instead. Manual mode still honours the user's
        // explicit selection.
        if isManual, let manualNames = snapshot.manualToolNames {
            add(ToolRegistry.shared.specs(forTools: manualNames), replacingExisting: true)
        }

        if !additionalToolNames.isEmpty {
            add(
                ToolRegistry.shared.specs(forTools: Array(additionalToolNames)),
                replacingExisting: true
            )
        }

        // Web search enabled means BOTH halves of the web pipeline are in the
        // schema from turn 1: discovery (`web_search`) and retrieval
        // (`search_and_extract`). Retrieval used to stay dynamic outside the
        // Charts+Web combination to keep the baseline lean, and that gap is
        // exactly where models fell apart in practice: with only `web_search`
        // visible they either rephrased the same discovery query in a loop or
        // hallucinated a fetch tool (`web_fetch`) that has never existed —
        // observed live as a Raptor research run producing zero page reads.
        // The discovery→retrieval transition advertised inside `web_search`
        // results must be callable the moment those results arrive.
        if !isManual, snapshot.webSearchEnabled {
            add(
                ToolRegistry.shared.specs(forTools: ["search_and_extract"]),
                replacingExisting: true
            )
        }

        // Proactive channel publishing: expose the ONE narrow, binding-scoped
        // publish tool whenever this agent has usable outbound destination
        // bindings. The broad `agent_channel_*` catalog stays deferred behind
        // `capabilities_load` — the publish tool cannot address raw
        // connections/rooms, only operator-approved bindings, so surfacing it
        // directly is safe and lets scheduled/self-scheduled runs publish
        // without a discovery round-trip.
        if !isManual, snapshot.hasChannelPublishDestinations {
            add(ToolRegistry.shared.specs(forTools: [AgentChannelPublishTool.toolName]))
        }

        // Per-agent built-in tool gates. These tools are registered as
        // built-ins (so direct execution + ChatView interception still
        // work) but stripped from the auto-mode schema unless the agent
        // opts in — keeping the always-loaded surface lean by default.
        // `search_memory` is gated independently of the memory disable
        // switch (that switch governs injection + recording, this one
        // governs mid-session recall via the tool). The Agent DB feature
        // (spec §6) `db_*` tools are gated the same way; the system prompt
        // composer also skips the DB onboarding block when `dbEnabled` is
        // false (both read `AgentConfigSnapshot.dbEnabled`).
        //
        // All gates honor the same two carve-outs uniformly:
        //   - Manual tool-selection mode is left untouched: there the user
        //     curates the list, so the baseline built-ins they see stay
        //     (db_* included — consistency with the other gated built-ins).
        //   - In auto mode, a tool pulled in via `additionalToolNames`
        //     (a `capabilities_load`) survives — a deliberate "I want this"
        //     signal. The gate only trims the default baseline, not picks.
        // Manual mode used to skip this block entirely ("the user curates the
        // list"), but the picker only lets the user tick DYNAMIC tools —
        // built-ins are always-loaded rows — so the grant toggles (Web
        // Search, Charts, Speak, Memory, DB, Scheduling, Knowledge) were the
        // only way to turn a built-in off, and in manual mode they did
        // nothing: Web Search OFF still exposed `web_search` /
        // `search_and_extract`. The strips now run in both modes; explicit
        // picks (a session `capabilities_load`, or a ticked manual name)
        // stay exempt as the deliberate "I want this" signal.
        do {
            var keep = additionalToolNames
            if isManual, let manualNames = snapshot.manualToolNames {
                keep.formUnion(manualNames)
            }
            if !snapshot.dbEnabled {
                for name in agentDBToolNames where !keep.contains(name) {
                    byName.removeValue(forKey: name)
                }
            }
            if !snapshot.renderChartEnabled, !keep.contains("render_chart") {
                byName.removeValue(forKey: "render_chart")
            }
            if !snapshot.speakEnabled, !keep.contains("speak") {
                byName.removeValue(forKey: "speak")
            }
            if !snapshot.searchMemoryEnabled, !keep.contains("search_memory") {
                byName.removeValue(forKey: "search_memory")
            }
            if !snapshot.webSearchEnabled {
                for name in ["web_search", "search_and_extract"] where !keep.contains(name) {
                    byName.removeValue(forKey: name)
                }
            }
            if !snapshot.selfSchedulingEnabled {
                for name in schedulerToolNames where !keep.contains(name) {
                    byName.removeValue(forKey: name)
                }
            }
            if !snapshot.knowledgeEnabled {
                for name in knowledgeToolNames where !keep.contains(name) {
                    byName.removeValue(forKey: name)
                }
            }
            if !snapshot.knowledgeCuratorEnabled {
                for name in knowledgeCuratorToolNames where !keep.contains(name) {
                    byName.removeValue(forKey: name)
                }
            }
        }

        // Authoritative per-agent subagent gates, driven by ONE loop over the
        // capability registry (no per-kind branches here) so adding a kind needs
        // no edit to this strip. Each capability's `gate` decides the rule:
        //   * .perAgent (computer_use): stripped whenever the agent's own flag
        //     is off — in BOTH auto and manual mode, with no `additionalToolNames`
        //     bypass. The Default agent is additionally excluded by the allowlist
        //     filter below, so it stays a custom-agent-only capability.
        //   * .delegation (spawn / image): visibility comes from the shared
        //     `SubagentToolVisibility` resolver (Default-vs-custom predicate:
        //     Default → global pool / image switch; custom → its own
        //     per-agent toggle + spawnable allow-list). Computed ONCE here and
        //     reused by the default-agent allowlist below; the HTTP agent-run
        //     path reads the same resolver (BUG E parity guard).
        //   * .sandboxExec: never stripped here (gated by sandbox registration,
        //     not the schema strip).
        // Installed-capability gate for `image`: the per-agent switch can be on,
        // but with no ready on-device image model the tool is still withheld
        // (and, with a gen model but no edit model, narrowed to a generation-only
        // schema below). Read off the warmed picker cache; `resolveTools` is
        // @MainActor, so this synchronous read is safe.
        let imageCache = ModelPickerItemCache.shared
        let hasReadyImageEditModel = imageCache.hasReadyImageEditModel
        var visibleDelegation = SubagentToolVisibility.visibleDelegationToolNames(
            agentId: snapshot.agentId,
            snapshot: snapshot,
            config: SubagentConfigurationStore.snapshot(),
            hasReadyImageModel: imageCache.hasReadyImageModel,
            hasReadyVideoModel: imageCache.hasReadyVideoGenerationModel,
            // AppleScript gates like image: the per-agent / global switch can be
            // on, but the tool stays hidden until a curated AppleScript model is
            // installed. Read off the same warmed picker cache.
            hasReadyAppleScriptModel: imageCache.hasReadyAppleScriptModel
        )
        // Recursion guard for TRUE agent delegation: a `.delegation`-sourced
        // session IS a spawned child (a real dispatched chat of the target
        // agent), so it must never fan out further — strip every spawn tool
        // regardless of the target agent's own spawnable configuration.
        // `ChatSession.send` rebinds `currentSessionSource` from the
        // session's persisted source on every turn, so the strip holds for
        // follow-up turns (notch quick replies) too, keeping the schema
        // stable across the whole delegated session.
        if ChatExecutionContext.currentSessionSource == .delegation {
            visibleDelegation.subtract(SubagentCapabilityRegistry.spawn.toolNames)
            // `clarify` asks the USER a question, but a delegated child's
            // requester is the orchestrator model — the parent dispatcher
            // would sit blind on `.waitingForInput` until its wall-clock
            // budget expires. Same contract as the legacy bounded child
            // (`TextSubagentKind.isExcludedChildTool`). The child should
            // answer from its instructions or state assumptions instead.
            byName.removeValue(forKey: "clarify")
        }
        for capability in SubagentCapabilityRegistry.all {
            switch capability.gate {
            case .perAgent:
                if capability.perAgentFlag?.enabled(in: snapshot) == false {
                    for name in capability.toolNames { byName.removeValue(forKey: name) }
                }
            case .delegation:
                for name in capability.toolNames where !visibleDelegation.contains(name) {
                    byName.removeValue(forKey: name)
                }
            case .sandboxExec:
                break
            }
        }

        // Default-agent configure surface:
        //   * For the Default agent, hard-restrict to the consolidated
        //     configure surface (the `osaurus_inspect` read + the single declarative
        //     `osaurus_config` write) plus the agent-loop tools. Everything
        //     loads DIRECTLY — the Default agent does not use
        //     `capabilities_discover` / `capabilities_load`.
        //     `additionalToolNames` still unions in so a custom-agent-style
        //     mid-session load never gets stripped here.
        //   * For every other agent, strip the configure tools wholesale.
        //     Even if a registration path leaks `osaurus_config` into the
        //     schema, the strip filter keeps the model from seeing it.
        if snapshot.agentId == Agent.defaultId {
            var allowed = ToolRegistry.orchestratorAllowedToolNames
                .union(additionalToolNames)
            // Settings → Orchestrator stores a manual list too, and until now
            // nothing read it: ticking a plugin tool for the Orchestrator was
            // inert (its specs were added at the top of resolveTools, then
            // filtered out by this allowlist). A ticked name is the same
            // explicit pick a session load is.
            if isManual, let manualNames = snapshot.manualToolNames {
                allowed.formUnion(manualNames)
            }
            // Spawn UX: the main/default chat may call the delegation tools
            // (image / spawn) that survived the per-agent strip above — i.e. the
            // ones `visibleDelegation` resolved on for the Default agent (spawn
            // when its pool is non-empty, image when the global switch is on).
            // The first actual call prompts for permission + spawn-model choice.
            allowed.formUnion(visibleDelegation)
            // The Default agent may own destination bindings too; the narrow
            // publish tool follows them (never the broad channel catalog).
            if snapshot.hasChannelPublishDestinations {
                allowed.insert(AgentChannelPublishTool.toolName)
            }
            // Browser Use is a custom-agent capability (like `computer_use`):
            // the Default agent never gets it, so it stays off this allowlist
            // even if a stray snapshot carries the flag.

            // Since the declarative consolidation the write surface is ONE
            // tool (`osaurus_config`), which doubles as the routing/escape
            // tool and therefore always stays loaded — there is nothing left
            // to defer behind `capabilities_load` on small models, so the old
            // compact-deferral path (and its schema-side `capabilities_load`)
            // is gone entirely.
            let prefersCompact = ContextSizeResolver.resolve(modelId: snapshot.model)
                .prefersCompactPrompt
            // Orchestrator invariant: worker-owned tools (`share_artifact`)
            // never reach the orchestrator's schema — not even via
            // `additionalToolNames` — because workers deliver artifacts
            // themselves (see `ToolRegistry.orchestratorExcludedToolNames`).
            allowed.subtract(ToolRegistry.orchestratorExcludedToolNames)
            // Quick lookups run in the orchestrator itself: `web_search` is
            // an always-loaded built-in already in `byName`, but retrieval
            // (`search_and_extract`) is a dynamic tool — expose it up front
            // so the discovery→retrieval transition advertised by
            // `web_search` results is callable on turn 1. The per-agent
            // `webSearchEnabled` gate still governs both tools.
            if snapshot.webSearchEnabled {
                for spec in ToolRegistry.shared.specs(forTools: ["search_and_extract"]) {
                    byName[spec.function.name] = spec
                }
            }
            byName = byName.filter { allowed.contains($0.key) }

            // On a model that prefers a compact prompt, keep the configure
            // write lean: `osaurus_config`'s full spec is long prose, so
            // re-apply the bootstrap skeleton (enums + field names kept,
            // prose dropped). The compact addendum teaches the YAML workflow
            // the spec prose would otherwise carry.
            if prefersCompact {
                for name in ToolRegistry.configureWriteToolNames {
                    guard let full = byName[name] else { continue }
                    byName[name] = compactBootstrapSpec(full)
                }
            }
        } else {
            for name in ToolRegistry.configureToolNames {
                byName.removeValue(forKey: name)
            }
        }

        // Sandbox-override surface: when the per-agent Tools toggle is off and
        // the ONLY reason tools resolved at all is the sandbox execution grant
        // (see `resolveEffectiveToolsOff` — reaching here past the guard with
        // `snapshot.toolsDisabled` set means it can't be the global/size-class
        // path), expose only the sandbox primitives + the agent-loop tools.
        // The capability-discovery gateway (`capabilities_discover` /
        // `capabilities_load`) and every per-agent plugin capability are
        // dropped, so a "chat-only + sandbox" agent runs code and curls live
        // data itself but can't reach the plugin ecosystem. Any plugin tools a
        // prior turn loaded into `additionalToolNames` are filtered out too.
        // The composer's discovery / grounding / nudge sections gate on the
        // resolved schema, so removing discovery here cascades automatically
        // (no nudge; the tool-name-free base grounding variant).
        if snapshot.toolsDisabled, executionMode.usesSandboxTools {
            let allowed = ToolRegistry.coreWorkspaceToolNames
                .union(visibleSandboxControlPlane)
                .union(Self.agentLoopToolNames)
            byName = byName.filter { allowed.contains($0.key) }
        }

        // Generation-only image schema: when `image` survived the gates but no
        // ready edit model is installed, swap it to the edit-free variant (no
        // `source_paths` / `strength`, generation-only description) so the model
        // is never offered an edit it can't run. Generation still works because a
        // gen model is present. Mirror the baseline's first-turn compaction
        // unless the tool was loaded explicitly (manual pick / capabilities_load),
        // so the swapped spec sits at the same compaction level the edit-capable
        // spec would have — byte-stable per availability state for KV reuse.
        if byName["image"] != nil, !hasReadyImageEditModel {
            let imageLoadedExplicitly =
                additionalToolNames.contains("image")
                || (isManual && (snapshot.manualToolNames?.contains("image") ?? false))
            let genOnly = ImageTool.generationOnlySpec()
            byName["image"] = imageLoadedExplicitly ? genOnly : compactBootstrapSpec(genOnly)
        }

        // The chat contract exposes one compact capability gateway. Keep the
        // legacy discover/load registrations executable for non-chat callers,
        // but never publish both concepts to a custom agent.
        if snapshot.agentId != Agent.defaultId {
            byName.removeValue(forKey: "capabilities_discover")
            byName.removeValue(forKey: "capabilities_load")
        }

        // Freeze the exact first-compose payload for every baseline tool that
        // remains visible after the current permission/feature gates. Names
        // alone are not sufficient: a schema can change while its registration
        // and name remain identical (an MCP server re-registering a tool on
        // reconnect, a plugin reload, a sandbox tool re-registered with new
        // agent context). Such a change rewrites the tokenizer prefix and
        // defeats disk-L2 reuse. Built-in baseline schemas are immutable by
        // contract (see WebSearchTool.parameters) — this freeze is the
        // backstop for dynamically registered tools.
        //
        // A tool explicitly loaded this session is the intentional exception:
        // `capabilities_load` must still be able to upgrade a compact
        // bootstrap schema to the live full contract. Newly registered tools
        // absent from the frozen baseline likewise remain live.
        if let frozenToolSpecs {
            let frozenByName = Dictionary(
                uniqueKeysWithValues: frozenToolSpecs.map { ($0.function.name, $0) }
            )
            for name in Array(byName.keys)
            where !additionalToolNames.contains(name) {
                if let frozen = frozenByName[name] {
                    byName[name] = frozen
                }
            }
        }

        // The baseline schema above is deliberately frozen for prefix-cache
        // stability, but delegation targets and the per-launcher batch limit
        // are request-local authorization guidance. Apply those constraints
        // AFTER restoring frozen payloads so a settings edit cannot leave the
        // model advertising stale targets or a stale maxItems value. Reapplying
        // the same normalized constraints is byte-stable, so unchanged settings
        // retain the frozen-prefix cache contract.
        //
        // Execution still enforces every allow-list and budget independently;
        // these enums are provider/local-parser guidance, not the security
        // boundary.
        let config = SubagentConfigurationStore.snapshot()
        let isDefault = snapshot.agentId == Agent.defaultId
        let configuredAgentIDs =
            snapshot.spawnConfiguration?.agentIDs
            ?? SubagentToolVisibility.effectiveSpawnableAgents(
                isDefault: isDefault,
                config: config,
                perAgentEnabled: snapshot.spawnDelegationEnabled,
                perAgentTargets: snapshot.spawnableAgentIDs
            )
        let configuredModelIds =
            snapshot.spawnConfiguration?.modelNames
            ?? SubagentToolVisibility.effectiveSpawnableModels(
                isDefault: isDefault,
                config: config,
                perAgentEnabled: snapshot.spawnDelegationEnabled,
                perAgentModelTargets: snapshot.spawnableModelNames
            )
        let allowedAgentIDs =
            (spawnTargets?.runnableAgentIDs ?? configuredAgentIDs)
            .filter { $0 != snapshot.agentId }
        let allowedModelIds =
            spawnTargets?.runnableModelIds ?? configuredModelIds
        // Display names for the allow-listed agents, in `allowedAgentIDs` order.
        // Threaded into the schema enums so a strict, enum-enforcing provider
        // accepts a name as well as a UUID (issue #2408). `constrainedSpec`
        // sorts/normalizes, so the resolved order here need not be canonical.
        let allowedAgentNames = allowedAgentIDs.compactMap {
            AgentManager.shared.agent(for: $0)?.name
        }

        if let spawnAgent = byName[SubagentCapabilityRegistry.spawnAgentToolName] {
            if spawnTargets != nil, allowedAgentIDs.isEmpty {
                byName.removeValue(forKey: SubagentCapabilityRegistry.spawnAgentToolName)
            } else {
                byName[SubagentCapabilityRegistry.spawnAgentToolName] =
                    SpawnAgentTool.constrainedSpec(
                        spawnAgent,
                        allowedAgentIDs: allowedAgentIDs,
                        allowedAgentNames: allowedAgentNames
                    )
            }
        }
        if let spawnModel = byName[SubagentCapabilityRegistry.spawnModelToolName] {
            if spawnTargets != nil, allowedModelIds.isEmpty {
                byName.removeValue(forKey: SubagentCapabilityRegistry.spawnModelToolName)
            } else {
                byName[SubagentCapabilityRegistry.spawnModelToolName] =
                    SpawnModelTool.constrainedSpec(
                        spawnModel,
                        allowedModelIds: allowedModelIds
                    )
            }
        }
        if let spawnBatch = byName[SubagentCapabilityRegistry.spawnBatchToolName] {
            if spawnTargets != nil, allowedAgentIDs.isEmpty, allowedModelIds.isEmpty {
                byName.removeValue(forKey: SubagentCapabilityRegistry.spawnBatchToolName)
            } else {
                let maxParallel =
                    snapshot.spawnConfiguration?.budgets.maxParallelSpawns
                    ?? SubagentToolVisibility.effectiveBudgets(
                        isDefault: isDefault,
                        config: config,
                        settings: AgentManager.shared.agent(for: snapshot.agentId)?.settings,
                        sharedParallelLimit: SpawnBatchConcurrencyContract.configuredLimit(
                            for: ServerRuntimeSettingsStore.snapshot()
                        )
                    ).normalized.maxParallelSpawns
                byName[SubagentCapabilityRegistry.spawnBatchToolName] =
                    SpawnBatchTool.constrainedSpec(
                        spawnBatch,
                        allowedAgentIDs: allowedAgentIDs,
                        allowedAgentNames: allowedAgentNames,
                        allowedModelIds: allowedModelIds,
                        maxParallel: maxParallel
                    )
            }
        }

        // Execution mode selects the file/shell backend; it must not replace
        // the agent's enabled capability set. Workspace primitives join the
        // normal auto-mode tools, while manual mode remains the explicit user
        // selection plus those required execution primitives.
        let hasExecutionWorkspace =
            executionMode.usesHostFolderTools || executionMode.usesSandboxTools
        if snapshot.agentId != Agent.defaultId || hasExecutionWorkspace {
            var allowed =
                additionalToolNames
                .union(visibleSandboxControlPlane)
            if hasExecutionWorkspace {
                add(
                    ToolRegistry.shared.specs(
                        forTools: Array(ToolRegistry.coreWorkspaceToolNames)
                    ),
                    replacingExisting: true
                )
                allowed.formUnion(ToolRegistry.coreWorkspaceToolNames)
            }
            // Redaction tools join the schema only when a HOST folder is
            // active: they resolve the chat's folder root directly and have
            // no sandbox bridge, so VM-only mode must not offer them.
            if executionMode.usesHostFolderTools {
                add(
                    ToolRegistry.shared.specs(
                        forTools: Array(ToolRegistry.redactionToolNames)
                    ),
                    replacingExisting: true
                )
                allowed.formUnion(ToolRegistry.redactionToolNames)
            }
            if snapshot.dbEnabled { allowed.formUnion(agentDBToolNames) }
            if snapshot.renderChartEnabled { allowed.insert("render_chart") }
            if snapshot.speakEnabled { allowed.insert("speak") }
            if snapshot.searchMemoryEnabled { allowed.insert("search_memory") }
            if snapshot.webSearchEnabled {
                allowed.formUnion(["web_search", "search_and_extract"])
            }
            if snapshot.selfSchedulingEnabled { allowed.formUnion(schedulerToolNames) }
            if snapshot.knowledgeEnabled { allowed.formUnion(knowledgeToolNames) }
            if snapshot.knowledgeCuratorEnabled {
                allowed.formUnion(knowledgeCuratorToolNames)
            }
            allowed.formUnion(visibleDelegation)
            if snapshot.computerUseEnabled { allowed.insert(ComputerUseTool.toolName) }
            if snapshot.browserUseEnabled { allowed.insert(BrowserUseTool.toolName) }
            if byName["capabilities"] != nil { allowed.insert("capabilities") }
            if snapshot.hasChannelPublishDestinations {
                allowed.insert(AgentChannelPublishTool.toolName)
            }
            if let shell = byName["shell_run"],
                !(executionMode.usesSandboxTools
                    && snapshot.autonomousConfig?.backgroundProcessEnabled == true)
            {
                byName["shell_run"] = removingProperty("background", from: shell)
            }
            if isManual, let manualNames = snapshot.manualToolNames {
                allowed.formUnion(manualNames)
            }
            // Auto-mode agents need the complete lifecycle contract together:
            // `todo` without `complete` cannot close tracked work, and omitting
            // these built-ins after registering them leaves the model unable to
            // satisfy the agent-loop guidance. Manual mode remains strict and
            // exposes lifecycle tools only when the user selected them.
            if !isManual {
                allowed.formUnion(Self.agentLoopToolNames)
            }
            // This unconditionally available baseline tool is part of the
            // stable schema. Query wording never adds or removes it.
            allowed.insert("get_current_time")
            // The orchestrator invariant holds in workspace modes too: even
            // with a folder/sandbox attached, the Default agent dispatches
            // artifact delivery to workers (`share_artifact` stays
            // worker-owned; the native search tools remain available).
            if snapshot.agentId == Agent.defaultId {
                allowed.subtract(ToolRegistry.orchestratorExcludedToolNames)
            }
            byName = byName.filter { allowed.contains($0.key) }

        }

        // Request-scoped sandbox authorization is fail-closed. Direct manual
        // selection or a stale loaded-tool name must not resurrect a private
        // backend adapter or a control-plane tool whose current captured agent
        // config does not own it. `ToolExecutionScope` is seeded from this final
        // schema, binding the same decision to execution.
        for name in ToolRegistry.sandboxBackendAdapterToolNames {
            byName.removeValue(forKey: name)
        }
        for name in ToolRegistry.sandboxControlPlaneToolNames
        where !visibleSandboxControlPlane.contains(name) {
            byName.removeValue(forKey: name)
        }

        // Eval-scoped ablation hook (nil in production): strip deferred
        // tool names from the request schema. The tools stay registered and
        // reachable via `capabilities_load`, so this measures the
        // defer-to-discovery architecture; protected names (discovery
        // gateway, agent-loop contract) always survive.
        if let experiment = PromptComposerExperimentScope.current {
            byName = Dictionary(
                uniqueKeysWithValues: experiment.filterTools(Array(byName.values))
                    .map { ($0.function.name, $0) }
            )
        }

        // Workspace tools always use the stable public compact contract.
        // Apply this after every request gate and ablation so a legacy/manual
        // selection or a schema-less backend alias cannot erase supported
        // public arguments from the final model request.
        for name in ToolRegistry.coreWorkspaceToolNames {
            guard let full = byName[name] else { continue }
            byName[name] = compactWorkspaceSpec(
                full,
                executionMode: executionMode,
                backgroundProcessesEnabled:
                    executionMode.usesSandboxTools
                    && snapshot.autonomousConfig?.backgroundProcessEnabled == true
            )
        }

        let resolved = canonicalToolOrder(Array(byName.values))

        // Debug aid for the delegation tool surfacing: confirms whether the
        // spawn (`spawn_agent` / `spawn_model`) / `image` tools actually reached
        // the model's schema, per the per-agent visibility resolved above.
        let spawnToolNames = SubagentCapabilityRegistry.spawn.toolNames
        let hasSpawn = resolved.contains { spawnToolNames.contains($0.function.name) }
        let hasImage = resolved.contains { $0.function.name == "image" }
        toolResolveLog.debug(
            "resolveTools agent=\(snapshot.agentId.uuidString, privacy: .public) spawn_in_schema=\(hasSpawn, privacy: .public) image_in_schema=\(hasImage, privacy: .public) toolCount=\(resolved.count, privacy: .public)"
        )

        return resolved
    }

    private static func compactWorkspaceSpec(
        _ tool: Tool,
        executionMode: ExecutionMode,
        backgroundProcessesEnabled: Bool
    ) -> Tool {
        let description: String
        var properties: [String: JSONValue]
        let required: [String]
        switch tool.function.name {
        case "file_read":
            if executionMode.usesSandboxTools, executionMode.hostReadContext == nil {
                description =
                    "Read UTF-8 text or list a directory in the VM working folder. "
                    + "For binary PDF/Word/PowerPoint/XLSX files, use sandbox shell/code extraction."
            } else if executionMode.usesSandboxTools {
                description =
                    "Read/list by path: trusted-folder documents extract PDF/Word/PowerPoint text "
                    + "and preview XLSX; `/workspace/...` VM paths are raw text only."
            } else {
                description =
                    "Read a file or list a directory. Directly extracts text from PDF, Word, and "
                    + "PowerPoint and previews XLSX—call this on the document; do not unzip it manually."
            }
            properties = [
                "path": .object([
                    "type": .string("string"),
                    "description": .string("Relative file or directory path"),
                ]),
                "max_depth": .object([
                    "type": .string("integer"),
                    "description": .string("Optional directory listing depth (default 3)"),
                ]),
                "sheet_name": .object([
                    "type": .string("string"),
                    "description": .string("Optional XLSX worksheet name"),
                ]),
                "start_line": .object([
                    "type": .string("integer"),
                    "description": .string("Optional first line or XLSX row, 1-indexed"),
                ]),
                "end_line": .object([
                    "type": .string("integer"),
                    "description": .string("Optional last line or XLSX row, inclusive"),
                ]),
                "tail_lines": .object([
                    "type": .string("integer"),
                    "description": .string("Optional last N lines instead of a range"),
                ]),
                "max_chars": .object([
                    "type": .string("integer"),
                    "description": .string("Optional returned-character cap"),
                ]),
                "max_rows": .object([
                    "type": .string("integer"),
                    "description": .string("Optional XLSX rows per sheet (max 50)"),
                ]),
                "max_columns": .object([
                    "type": .string("integer"),
                    "description": .string("Optional XLSX columns per row (max 30)"),
                ]),
            ]
            required = ["path"]
        case "file_write":
            description =
                "Create, replace, append, or dry-run a UTF-8 file. To preserve existing bytes, "
                + "choose append and send only new content."
            properties = [
                "path": .object([
                    "type": .string("string"),
                    "description": .string("Relative file path"),
                ]),
                "content": .object([
                    "type": .string("string"),
                    "maxLength": .number(Double(WorkspaceToolContract.maxWriteContentCharacters)),
                    "description": .string(
                        "File content, at most \(WorkspaceToolContract.maxWriteContentCharacters) characters"
                    ),
                ]),
                "mode": .object([
                    "type": .string("string"),
                    "enum": .array([.string("overwrite"), .string("append")]),
                    "description": .string("Default overwrite; append adds content without replacing the file"),
                ]),
                "dry_run": .object([
                    "type": .string("boolean"),
                    "description": .string("Preview without writing (host paths only)"),
                ]),
            ]
            required = ["path", "content"]
        case "file_edit":
            description =
                "Replace one exact, unique text occurrence, optionally as a dry run. "
                + "For additive changes, use file_write append."
            properties = [
                "path": .object([
                    "type": .string("string"),
                    "description": .string("Relative file path"),
                ]),
                "old_string": .object([
                    "type": .string("string"),
                    "description": .string("Exact unique text; omit `N|` display prefixes"),
                ]),
                "new_string": .object([
                    "type": .string("string"),
                    "description": .string("Replacement text"),
                ]),
                "dry_run": .object([
                    "type": .string("boolean"),
                    "description": .string("Preview without editing (host paths only)"),
                ]),
            ]
            required = ["path", "old_string", "new_string"]
        case "file_search":
            description = "Search file contents or names with optional path, file filter, and result limit."
            properties = [
                "pattern": .object([
                    "type": .string("string"),
                    "description": .string("Text or filename pattern"),
                ]),
                "path": .object([
                    "type": .string("string"),
                    "description": .string("Optional relative search root"),
                ]),
                "target": .object([
                    "type": .string("string"),
                    "enum": .array([.string("content"), .string("files")]),
                    "description": .string("Default content; files searches names"),
                ]),
                "file_pattern": .object([
                    "type": .string("string"),
                    "description": .string("Optional filename glob for content search"),
                ]),
                "max_results": .object([
                    "type": .string("integer"),
                    "description": .string("Optional result cap (default 50)"),
                ]),
            ]
            required = ["pattern"]
        case "shell_run":
            description =
                "Run a build, test, git, process, network, package-manager, or filesystem command "
                + "in the working folder. Requires approval; omit timeout to run until completion."
            properties = [
                "command": .object([
                    "type": .string("string"),
                    "description": .string("Shell command; do not `cd` to the working folder first"),
                ]),
                "timeout": .object([
                    "type": .string("integer"),
                    "description": .string("Optional idle-output timeout in seconds (1-3600)"),
                ]),
            ]
            if backgroundProcessesEnabled {
                properties["background"] = .object([
                    "type": .string("boolean"),
                    "description": .string(
                        "VM only: run a server/watcher as a tracked background job"
                    ),
                ])
            }
            required = ["command"]
        default:
            return tool
        }
        return Tool(
            type: tool.type,
            function: ToolFunction(
                name: tool.function.name,
                description: description,
                parameters: .object([
                    "type": .string("object"),
                    "additionalProperties": .bool(false),
                    "properties": .object(properties),
                    "required": .array(required.map { .string($0) }),
                ])
            )
        )
    }

    private static func removingProperty(_ property: String, from tool: Tool) -> Tool {
        guard case .object(var schema)? = tool.function.parameters,
            case .object(var properties)? = schema["properties"]
        else { return tool }
        properties.removeValue(forKey: property)
        schema["properties"] = .object(properties)
        return Tool(
            type: tool.type,
            function: ToolFunction(
                name: tool.function.name,
                description: tool.function.description,
                parameters: .object(schema)
            )
        )
    }

    /// Stable order:
    ///   0. Agent-loop tools (`todo`, `complete`, `clarify`, `share_artifact`)
    ///      in fixed order. Pinned at the very top so a model scanning the
    ///      schema sees the loop API first; also keeps the rendered byte
    ///      sequence stable across sends regardless of what plugins or MCP
    ///      providers register later (KV-cache reuse).
    ///   1. Built-in sandbox tools (alphabetical).
    ///   2. Compact capability gateway, followed by legacy compatibility
    ///      aliases when a non-chat surface explicitly includes them.
    ///   3. Everything else, alphabetical.
    @MainActor
    static func canonicalToolOrder(_ tools: [Tool]) -> [Tool] {
        let sandboxNames = ToolRegistry.shared.builtInSandboxToolNamesSnapshot
        let loopIndex = Dictionary(
            uniqueKeysWithValues: ["todo", "complete", "clarify", "share_artifact"]
                .enumerated().map { ($1, $0) }
        )
        let capabilityIndex = Dictionary(
            uniqueKeysWithValues: ["capabilities", "capabilities_discover", "capabilities_load"]
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

    /// The explicit persona profile a compose renders under — resolved ONCE
    /// from the snapshot and consulted at every profile-sensitive branch,
    /// replacing implicit `agentId == Agent.defaultId` stacking.
    public enum PromptProfile: String, Sendable {
        /// The Default agent: the standalone Osaurus assistant —
        /// the addendum IS the identity.
        case osaurusAssistant
        /// Any custom agent: its own persona.
        case customAgent

        @MainActor
        static func resolve(snapshot: AgentConfigSnapshot) -> PromptProfile {
            snapshot.agentId == Agent.defaultId ? .osaurusAssistant : .customAgent
        }
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
        // Default-agent system-prompt addendum (Phase C). The
        // configure-agent menu is derived from
        // `ConfigurationDomainRegistry` and prepended to the user's
        // own persona so the addendum sits as a *system role*
        // preamble. Memoized inside the builder so adding it costs
        // a single pointer read per compose. Under `.osaurusAssistant`
        // it is the standalone assistant identity.
        let profile = PromptProfile.resolve(snapshot: snapshot)
        let basePrompt: String
        switch profile {
        case .osaurusAssistant:
            let prefersCompact = ContextSizeResolver.resolve(modelId: snapshot.model)
                .prefersCompactPrompt
            let addendum = DefaultAgentSystemPromptBuilder.render(compact: prefersCompact)
            let userPersona = snapshot.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            basePrompt = userPersona.isEmpty ? addendum : addendum + "\n\n" + snapshot.systemPrompt
        case .customAgent:
            basePrompt = snapshot.systemPrompt
        }
        composer.appendBasePrompt(systemPrompt: basePrompt)
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

    /// Render the memory + screen/automation-context blocks exactly as the per-turn
    /// injectors (`injectMemoryPrefix` + `injectScreenContextPrefix`) would
    /// prepend it to a non-empty user message, INCLUDING the trailing
    /// separator — so `prefix + originalContent` reproduces the legacy
    /// injected bytes. Callers freeze this string per user turn (chat) or
    /// per session ledger entry (HTTP/plugin) so that once a turn has been
    /// sent with an injected prefix, every later request replays the same
    /// bytes and the paged KV cache can reuse the whole prior exchange.
    /// Returns nil when both inputs are nil/blank.
    static func composeInjectedUserPrefix(
        memorySection: String?,
        screenContext: String?,
        automationContext: String? = nil,
        timeContext: String? = nil
    ) -> String? {
        var prefix = ""
        if let memorySection {
            let trimmed = memorySection.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { prefix = "[Memory]\n\(trimmed)\n[/Memory]\n\n" }
        }
        if let screenContext {
            let trimmed = screenContext.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { prefix = "\(trimmed)\n\n" + prefix }
        }
        if let automationContext {
            let trimmed = automationContext.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { prefix = "\(trimmed)\n\n" + prefix }
        }
        // Time rides LAST, right against the user's text: it is the most
        // volatile block, and keeping it at the tail means the stabler
        // automation/screen/memory bytes stay adjacent to the shared static
        // prefix — a fresh chat whose earlier blocks match a previous
        // session's prefill diverges only here, not at byte 0 of the turn.
        if let timeContext {
            let trimmed = timeContext.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { prefix += "\(trimmed)\n\n" }
        }
        return prefix.isEmpty ? nil : prefix
    }

    /// Minimal app identity needed by the parent to route working-document
    /// anaphora to AppleScript. This is not Screen Context: it carries no UI,
    /// window, draft, or accessibility content, and callers include it only
    /// when `applescript` is actually exposed in the frozen tool schema.
    static func appleScriptWorkingAppContext(appName: String?) -> String? {
        guard let appName else { return nil }
        let app =
            appName
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !app.isEmpty else { return nil }
        return """
            [Mac Automation Context]
            Working app before this message: \(app)
            If the request says `the file` or `the document`, it means that app's front open document. Use `applescript`; do not ask for a path or create a separate artifact.
            [/Mac Automation Context]
            """
    }

    /// Session-stable memory injection for surfaces whose history is owned
    /// by the CALLER (HTTP `/agents/{id}/run`, plugin host): the client
    /// resends clean history each request, so a prefix injected into the
    /// latest user message on request N silently vanishes from request
    /// N+1's history and the local paged-KV prefix diverges at that message
    /// (the whole last exchange re-prefills). This helper makes the
    /// injected bytes sticky:
    ///   1. re-applies previously recorded prefixes (`frozen`, keyed by
    ///      content-hash + occurrence of the ORIGINAL user message) to
    ///      matching history user messages, and
    ///   2. injects this request's `memorySection` into the latest user
    ///      message — unless that message already has a recorded prefix
    ///      (identical retry), in which case the recorded bytes win.
    /// Returns the (key, prefix) recorded for the latest user message so
    /// the caller can persist it into the session ledger; nil when nothing
    /// new was injected. Multimodal (`contentParts`) messages are skipped,
    /// matching `injectMemoryPrefix`.
    static func applyFrozenMemoryPrefixes(
        memorySection: String?,
        frozen: [String: String],
        timeContext: String? = nil,
        into messages: inout [ChatMessage]
    ) -> (key: String, prefix: String)? {
        guard let lastUserIdx = messages.lastIndex(where: { $0.role == "user" }) else { return nil }
        let keys = frozenPrefixKeys(for: messages)

        func prepend(_ prefix: String, at idx: Int) {
            let existing = messages[idx]
            guard existing.contentParts == nil else { return }
            messages[idx] = ChatMessage(
                role: existing.role,
                content: prefix + (existing.content ?? ""),
                tool_calls: existing.tool_calls,
                tool_call_id: existing.tool_call_id
            )
        }

        // History user messages: replay the exact bytes they were sent with.
        for (idx, key) in keys where idx != lastUserIdx {
            if let prefix = frozen[key] { prepend(prefix, at: idx) }
        }

        guard let lastKey = keys[lastUserIdx] else { return nil }
        if let recorded = frozen[lastKey] {
            // Identical retry of the same latest message — byte stability
            // beats fresher memory.
            prepend(recorded, at: lastUserIdx)
            return nil
        }
        guard messages[lastUserIdx].contentParts == nil,
            let prefix = composeInjectedUserPrefix(
                memorySection: memorySection,
                screenContext: nil,
                timeContext: timeContext
            )
        else { return nil }
        prepend(prefix, at: lastUserIdx)
        return (key: lastKey, prefix: prefix)
    }

    /// Stable ledger keys for every user message in the array:
    /// FNV-1a hash of the ORIGINAL content plus an occurrence ordinal, so
    /// duplicate texts ("yes", "continue") map to distinct entries while
    /// remaining deterministic for a client that resends identical history.
    private static func frozenPrefixKeys(for messages: [ChatMessage]) -> [Int: String] {
        var occurrence: [String: Int] = [:]
        var keys: [Int: String] = [:]
        for (idx, msg) in messages.enumerated() where msg.role == "user" {
            let hash = fnv1aHex(msg.content ?? "")
            let ordinal = occurrence[hash, default: 0]
            occurrence[hash] = ordinal + 1
            keys[idx] = "\(hash)#\(ordinal)"
        }
        return keys
    }

    /// Deterministic FNV-1a 64-bit over UTF-8 bytes (matches the hashing
    /// style used by `CompactionWatermark` for message identities).
    private static func fnv1aHex(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    /// Prepend a frozen screen-context block (already rendered by
    /// `ScreenContextSnapshot.render()`, tags and all) to the latest user
    /// message. Placed on the user turn — not the system prompt — for two
    /// reasons that mirror `injectMemoryPrefix`:
    ///   1. the system prefix stays byte-stable so the paged KV cache reuses
    ///      the conversation prefix, and
    ///   2. the Privacy Filter only scans the latest user turn
    ///      (`latestUserTurnSegments()`) and skips `system`, so riding on the
    ///      user message is what actually routes the snapshot through PII
    ///      scrubbing before a cloud send.
    /// No-op when the block is nil/blank, no user message exists, or the
    /// latest user message is multimodal (we leave `contentParts`-bearing
    /// messages alone to avoid silently dropping images).
    static func injectScreenContextPrefix(
        _ block: String?,
        into messages: inout [ChatMessage]
    ) {
        guard let block,
            case let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines),
            !trimmed.isEmpty,
            let idx = messages.lastIndex(where: { $0.role == "user" })
        else { return }

        let existing = messages[idx]
        guard existing.contentParts == nil else { return }

        let original = existing.content ?? ""
        let prefixed = original.isEmpty ? trimmed : "\(trimmed)\n\n\(original)"
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
