//
//  SystemPromptComposer.swift
//  osaurus
//
//  Builder for structured system prompt assembly. Provides both low-level
//  section-by-section composition and high-level single-call methods
//  (composeChatContext, composeWorkPrompt) that handle the full pipeline.
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

    public mutating func appendMemory(agentId: String, query: String? = nil) async {
        let config = MemoryConfigurationStore.load()
        let context: String
        if let query, !query.isEmpty {
            context = await MemoryContextAssembler.assembleContext(
                agentId: agentId,
                config: config,
                query: query
            )
        } else {
            context = await MemoryContextAssembler.assembleContext(
                agentId: agentId,
                config: config
            )
        }
        append(.dynamic(id: "memory", label: "Memory", content: context))
    }

    // MARK: - High-Level API

    /// Compose the full chat context: prompt + tools + manifest in one call.
    @MainActor
    static func composeChatContext(
        agentId: UUID,
        executionMode: WorkExecutionMode,
        model: String? = nil,
        query: String = "",
        toolsDisabled: Bool = false,
        trace: TTFTTrace? = nil
    ) async -> ComposedContext {
        trace?.mark("compose_context_start")
        let composer = forChat(agentId: agentId, executionMode: executionMode, model: model)
        let result = await finalizeContext(
            composer: composer,
            agentId: agentId,
            executionMode: executionMode,
            query: query,
            toolsDisabled: toolsDisabled,
            model: model,
            trace: trace
        )
        trace?.mark("compose_context_done")
        return result
    }

    /// Shared pipeline: append memory + preflight + skills + resolve tools + build ComposedContext.
    @MainActor
    private static func finalizeContext(
        composer: SystemPromptComposer,
        agentId: UUID,
        executionMode: WorkExecutionMode,
        query: String,
        toolsDisabled: Bool,
        model: String? = nil,
        trace: TTFTTrace? = nil
    ) async -> ComposedContext {
        var comp = composer

        trace?.mark("memory_start")
        await comp.appendMemory(agentId: agentId.uuidString)
        trace?.mark("memory_done")

        let toolMode = AgentManager.shared.effectiveToolSelectionMode(for: agentId)
        let isLocalModel = MLXService.shared.handles(requestedModel: model)
        let preflight: PreflightResult
        if !toolsDisabled && toolMode == .auto && !query.isEmpty && !isLocalModel {
            let mode = ChatConfigurationStore.load().preflightSearchMode ?? .balanced
            trace?.mark("preflight_search_start")
            preflight = await PreflightCapabilitySearch.search(query: query, mode: mode)
            trace?.mark("preflight_search_done")
        } else {
            preflight = .empty
        }
        comp.append(.dynamic(id: "preflight", label: "Pre-flight RAG", content: preflight.contextSnippet))

        if toolMode == .manual,
            let section = await SkillManager.shared.manualSkillPromptSection(for: agentId)
        {
            comp.append(.dynamic(id: "skills", label: "Skills", content: section))
        }

        trace?.mark("resolve_tools_start")
        let tools = resolveTools(
            agentId: agentId,
            executionMode: executionMode,
            toolsDisabled: toolsDisabled,
            preflight: preflight
        )
        trace?.mark("resolve_tools_done")

        let manifest = comp.manifest()
        let toolNames = tools.map { $0.function.name }
        debugLog("[Context] \(manifest.debugDescription)")

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
            cacheHint: manifest.staticPrefixHash(toolNames: toolNames),
            staticPrefix: manifest.staticPrefixContent
        )
    }

    /// Resolve the full tool set for a request: built-in + preflight/manual, deduped.
    @MainActor
    static func resolveTools(
        agentId: UUID,
        executionMode: WorkExecutionMode,
        toolsDisabled: Bool = false,
        preflight: PreflightResult = .empty
    ) -> [Tool] {
        guard !toolsDisabled else { return [] }

        let toolMode = AgentManager.shared.effectiveToolSelectionMode(for: agentId)
        let isManual = toolMode == .manual

        var tools = ToolRegistry.shared.alwaysLoadedSpecs(
            mode: executionMode,
            excludeCapabilityTools: isManual
        )
        var seen = Set(tools.map { $0.function.name })

        if isManual {
            if let manualNames = AgentManager.shared.effectiveManualToolNames(for: agentId) {
                for spec in ToolRegistry.shared.specs(forTools: manualNames)
                where seen.insert(spec.function.name).inserted {
                    tools.append(spec)
                }
            }
        } else {
            for spec in preflight.toolSpecs
            where seen.insert(spec.function.name).inserted {
                tools.append(spec)
            }
        }

        return tools
    }

    /// Compose the full work system prompt: base + workMode + sandbox.
    @MainActor
    public static func composeWorkPrompt(
        agentId: UUID,
        executionMode: WorkExecutionMode,
        model: String? = nil,
        secretNames: [String] = []
    ) -> (prompt: String, manifest: PromptManifest) {
        let compact = resolveCompact(model: model, agentId: agentId)
        let composer = forWork(
            agentId: agentId,
            executionMode: executionMode,
            compact: compact,
            secretNames: secretNames
        )
        return (composer.render(), composer.manifest())
    }

    /// Compose a work prompt from a pre-resolved base string (e.g. base+memory from WorkEngine).
    public static func composeWorkPrompt(
        base: String,
        executionMode: WorkExecutionMode,
        model: String? = nil,
        secretNames: [String] = []
    ) -> (prompt: String, manifest: PromptManifest) {
        let compact = model.map { SystemPromptTemplates.isLocalModel($0) } ?? false
        let composer = forWork(base: base, executionMode: executionMode, compact: compact, secretNames: secretNames)
        return (composer.render(), composer.manifest())
    }

    /// Full work context: base + workMode + sandbox + memory + tools.
    /// Memory is correctly classified as dynamic for prefix cache optimization.
    @MainActor
    static func composeWorkContext(
        agentId: UUID,
        executionMode: WorkExecutionMode,
        model: String? = nil,
        secretNames: [String] = [],
        query: String = "",
        toolsDisabled: Bool = false
    ) async -> ComposedContext {
        let compact = resolveCompact(model: model, agentId: agentId)
        let composer = forWork(
            agentId: agentId,
            executionMode: executionMode,
            compact: compact,
            secretNames: secretNames
        )
        return await finalizeContext(
            composer: composer,
            agentId: agentId,
            executionMode: executionMode,
            query: query,
            toolsDisabled: toolsDisabled
        )
    }

    /// Compose from a pre-resolved base with optional dynamic sections (preflight, skills).
    public static func composePrompt(
        base: String,
        preflightSnippet: String = "",
        skillSection: String? = nil
    ) -> (prompt: String, manifest: PromptManifest) {
        var composer = SystemPromptComposer()
        composer.append(.static(id: "base", label: "System Prompt", content: base))
        composer.append(.dynamic(id: "preflight", label: "Pre-flight RAG", content: preflightSnippet))
        if let section = skillSection {
            composer.append(.dynamic(id: "skills", label: "Skills", content: section))
        }
        return (composer.render(), composer.manifest())
    }

    /// Compose agent context (base prompt + memory) and inject into an existing message array.
    /// Returns `(cacheHint, staticPrefix)` for the caller to set on the request.
    @MainActor
    @discardableResult
    static func injectAgentContext(
        agentId: UUID,
        query: String = "",
        into messages: inout [ChatMessage]
    ) async -> (cacheHint: String, staticPrefix: String) {
        var composer = forChat(agentId: agentId, executionMode: .none)
        await composer.appendMemory(agentId: agentId.uuidString, query: query.isEmpty ? nil : query)
        let manifest = composer.manifest()
        let rendered = composer.render()
        debugLog("[Context:inject] \(manifest.debugDescription)")
        if !rendered.isEmpty {
            injectSystemContent(rendered, into: &messages)
        }
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
        executionMode: WorkExecutionMode,
        model: String? = nil
    ) -> SystemPromptComposer {
        let compact = resolveCompact(model: model, agentId: agentId)
        return forChat(agentId: agentId, executionMode: executionMode, compact: compact)
    }

    @MainActor
    static func forChat(
        agentId: UUID,
        executionMode: WorkExecutionMode,
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
                    content: SystemPromptTemplates.sandbox(mode: .chat, compact: compact, secretNames: secretNames)
                )
            )
        }
        return composer
    }

    @MainActor
    static func forWork(
        agentId: UUID,
        executionMode: WorkExecutionMode,
        compact: Bool,
        secretNames: [String] = []
    ) -> SystemPromptComposer {
        var composer = SystemPromptComposer()
        composer.appendBasePrompt(agentId: agentId)
        return composer.withWorkSections(executionMode: executionMode, compact: compact, secretNames: secretNames)
    }

    static func forWork(
        base: String,
        executionMode: WorkExecutionMode,
        compact: Bool,
        secretNames: [String] = []
    ) -> SystemPromptComposer {
        var composer = SystemPromptComposer()
        composer.append(.static(id: "base", label: "Base Prompt", content: base))
        return composer.withWorkSections(executionMode: executionMode, compact: compact, secretNames: secretNames)
    }

    private func withWorkSections(
        executionMode: WorkExecutionMode,
        compact: Bool,
        secretNames: [String]
    ) -> SystemPromptComposer {
        let variant: SystemPromptTemplates.WorkModeVariant = compact ? .compact : .full
        var result = self
        result.append(
            .static(
                id: "workMode",
                label: "Work Mode",
                content: SystemPromptTemplates.workMode(variant)
            )
        )
        if case .sandbox = executionMode {
            result.append(
                .static(
                    id: "sandbox",
                    label: "Sandbox",
                    content: SystemPromptTemplates.sandbox(mode: .work, compact: compact, secretNames: secretNames)
                )
            )
        }
        return result
    }

    // MARK: - Message Array Helpers

    static func injectSystemContent(
        _ content: String,
        into messages: inout [ChatMessage]
    ) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let idx = messages.firstIndex(where: { $0.role == "system" }),
            let existing = messages[idx].content, !existing.isEmpty
        {
            messages[idx] = ChatMessage(role: "system", content: trimmed + "\n\n" + existing)
        } else {
            messages.insert(ChatMessage(role: "system", content: trimmed), at: 0)
        }
    }

    static func appendSystemContent(
        _ content: String,
        into messages: inout [ChatMessage]
    ) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let idx = messages.firstIndex(where: { $0.role == "system" }),
            let existing = messages[idx].content, !existing.isEmpty
        {
            messages[idx] = ChatMessage(role: "system", content: existing + "\n\n" + trimmed)
        } else {
            messages.insert(ChatMessage(role: "system", content: trimmed), at: 0)
        }
    }
}
