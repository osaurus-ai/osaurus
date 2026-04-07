//
//  SystemPromptComposer.swift
//  osaurus
//
//  Builder for structured system prompt assembly. Provides both low-level
//  section-by-section composition and high-level single-call methods
//  (composeChatPrompt, composeWorkPrompt) that handle the full pipeline.
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

    /// Compose the full chat system prompt: base + sandbox + memory + preflight + skills.
    @MainActor
    public static func composeChatPrompt(
        agentId: UUID,
        executionMode: WorkExecutionMode,
        compact: Bool = false,
        preflightSnippet: String = "",
        skillSection: String? = nil
    ) async -> (prompt: String, manifest: PromptManifest) {
        var composer = forChat(agentId: agentId, executionMode: executionMode, compact: compact)
        await composer.appendMemory(agentId: agentId.uuidString)
        composer.append(.dynamic(id: "preflight", label: "Pre-flight RAG", content: preflightSnippet))
        if let section = skillSection {
            composer.append(.dynamic(id: "skills", label: "Skills", content: section))
        }
        return (composer.render(), composer.manifest())
    }

    /// Compose the full work system prompt: base + workMode + sandbox.
    @MainActor
    public static func composeWorkPrompt(
        agentId: UUID,
        executionMode: WorkExecutionMode,
        compact: Bool = false,
        secretNames: [String] = []
    ) -> (prompt: String, manifest: PromptManifest) {
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
        compact: Bool = false,
        secretNames: [String] = []
    ) -> (prompt: String, manifest: PromptManifest) {
        let composer = forWork(base: base, executionMode: executionMode, compact: compact, secretNames: secretNames)
        return (composer.render(), composer.manifest())
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
    @MainActor
    static func injectAgentContext(
        agentId: UUID,
        query: String = "",
        into messages: inout [ChatMessage]
    ) async {
        var composer = forChat(agentId: agentId, executionMode: .none)
        await composer.appendMemory(agentId: agentId.uuidString, query: query.isEmpty ? nil : query)
        let rendered = composer.render()
        debugLog("[Context:inject] \(composer.manifest().debugDescription)")
        if !rendered.isEmpty {
            injectSystemContent(rendered, into: &messages)
        }
    }

    // MARK: - Factory Methods (internal)

    /// Pre-loaded composer for chat mode: base prompt + chat sandbox.
    @MainActor
    public static func forChat(
        agentId: UUID,
        executionMode: WorkExecutionMode,
        compact: Bool = false
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

    /// Pre-loaded composer for work mode: base prompt + work instructions + work sandbox.
    @MainActor
    static func forWork(
        agentId: UUID,
        executionMode: WorkExecutionMode,
        compact: Bool = false,
        secretNames: [String] = []
    ) -> SystemPromptComposer {
        var composer = SystemPromptComposer()
        composer.appendBasePrompt(agentId: agentId)
        return composer.withWorkSections(executionMode: executionMode, compact: compact, secretNames: secretNames)
    }

    /// Work mode from a pre-resolved base string.
    static func forWork(
        base: String,
        executionMode: WorkExecutionMode,
        compact: Bool = false,
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

    /// Prepend content to the existing system message, or insert a new one at position 0.
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

    /// Append content to the end of the existing system message, or insert a new one at position 0.
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
