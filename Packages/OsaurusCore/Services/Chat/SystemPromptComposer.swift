//
//  SystemPromptComposer.swift
//  osaurus
//
//  Structured system prompt assembly. Replaces ad-hoc string concatenation
//  with an ordered section pipeline that produces both the rendered prompt
//  and a PromptManifest used by the budget tracker, debug logging, and
//  prefix cache hashing.
//

import CryptoKit
import Foundation

// MARK: - PromptSection

/// One logical block of the system prompt (e.g. base identity, work mode, sandbox, memory).
public struct PromptSection: Sendable {

    public let id: String
    public let label: String
    public let content: String
    public let cacheability: Cacheability

    public enum Cacheability: String, Sendable {
        /// Stable across requests — safe for prefix cache reuse.
        case `static`
        /// Changes per request (memory, RAG, skills).
        case dynamic
    }

    public var estimatedTokens: Int {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        return max(1, trimmed.count / ContextBudgetManager.charsPerToken)
    }

    public var isEmpty: Bool {
        content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: Convenience initializers

    public static func `static`(id: String, label: String, content: String) -> PromptSection {
        PromptSection(id: id, label: label, content: content, cacheability: .static)
    }

    public static func dynamic(id: String, label: String, content: String) -> PromptSection {
        PromptSection(id: id, label: label, content: content, cacheability: .dynamic)
    }
}

// MARK: - PromptManifest

/// Snapshot of the assembled system prompt — single source of truth for
/// token accounting, prefix cache hashing, and debug inspection.
public struct PromptManifest: Sendable {

    public let sections: [PromptSection]

    public var totalEstimatedTokens: Int {
        sections.reduce(0) { $0 + $1.estimatedTokens }
    }

    /// Tokens covered by static sections before the first dynamic section.
    public var staticPrefixTokens: Int {
        var tokens = 0
        for section in sections {
            if section.cacheability == .dynamic { break }
            tokens += section.estimatedTokens
        }
        return tokens
    }

    /// Hash of the static prefix content only (for KV cache reuse).
    public var prefixHash: String {
        staticPrefixHash(toolNames: [])
    }

    // MARK: Budget tracker integration

    /// Tokens from sections that are NOT the memory section.
    public var systemPromptTokens: Int {
        sections.filter { $0.id != "memory" }.reduce(0) { $0 + $1.estimatedTokens }
    }

    /// Tokens from the memory section specifically.
    public var memoryTokens: Int {
        section("memory")?.estimatedTokens ?? 0
    }

    // MARK: Lookup

    public func section(_ id: String) -> PromptSection? {
        sections.first { $0.id == id }
    }

    // MARK: Prefix hash

    /// Hash of static prefix content + tool names for cache key.
    public func staticPrefixHash(toolNames: [String]) -> String {
        var staticContent = ""
        for section in sections {
            if section.cacheability == .dynamic { break }
            let trimmed = section.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                if !staticContent.isEmpty { staticContent += "\n\n" }
                staticContent += trimmed
            }
        }
        let tools = toolNames.sorted().joined(separator: "\0")
        let combined = staticContent + "\0" + tools
        let digest = SHA256.hash(data: Data(combined.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Debug

    public var debugDescription: String {
        var lines: [String] = ["[Context Manifest]"]
        for (i, section) in sections.enumerated() {
            let tokens = section.estimatedTokens
            guard tokens > 0 else { continue }
            let num = String(format: "%2d", i + 1)
            let name = section.label.padding(toLength: 20, withPad: " ", startingAt: 0)
            let tok = String(format: "%5d", tokens)
            let cache = section.cacheability.rawValue
            lines.append("  \(num)  \(name) \(tok)  \(cache)")
        }
        lines.append("  " + String(repeating: "\u{2500}", count: 38))
        lines.append("  Total:               \(String(format: "%5d", totalEstimatedTokens))")
        let hash = prefixHash.prefix(16)
        lines.append("  Static prefix:       \(String(format: "%5d", staticPrefixTokens)) (hash: \(hash))")
        return lines.joined(separator: "\n")
    }
}

// MARK: - SystemPromptComposer

/// Builder that assembles system prompt sections in order, producing both the
/// rendered string and a `PromptManifest` for budget tracking and caching.
///
/// Static sections should be appended before dynamic sections so the prefix
/// cache hash covers the stable portion of the prompt.
public struct SystemPromptComposer: Sendable {

    private var sections: [PromptSection] = []

    public init() {}

    // MARK: Mutation

    public mutating func append(_ section: PromptSection) {
        guard !section.isEmpty else { return }
        sections.append(section)
    }

    // MARK: Output

    /// Concatenated system prompt string with `\n\n` separators.
    public func render() -> String {
        sections
            .map { $0.content.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    /// Structured manifest for budget tracking, caching, and debug output.
    public func manifest() -> PromptManifest {
        PromptManifest(sections: sections.filter { !$0.isEmpty })
    }

    // MARK: - Agent Base Prompt

    /// Resolve the agent's system prompt and append it as a static "Base Prompt" section.
    /// Falls back to the default identity when the agent has no custom prompt.
    @MainActor
    public mutating func appendBasePrompt(agentId: UUID) {
        let raw = AgentManager.shared.effectiveSystemPrompt(for: agentId)
        let effective = SystemPromptTemplates.effectiveBasePrompt(raw)
        append(.static(id: "base", label: "Base Prompt", content: effective))
    }

    // MARK: - Memory Convenience

    /// Fetch and append the memory context as a dynamic section.
    /// Loads `MemoryConfiguration`, calls `MemoryContextAssembler`, and appends
    /// the result. Pass `query` for query-aware retrieval (HTTP API path).
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

    // MARK: - Message Array Helpers

    /// Prepend content to the existing system message in a message array,
    /// or insert a new system message at position 0.
    static func injectSystemContent(
        _ content: String,
        into messages: inout [ChatMessage]
    ) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if let idx = messages.firstIndex(where: { $0.role == "system" }),
            let existing = messages[idx].content, !existing.isEmpty
        {
            messages[idx] = ChatMessage(
                role: "system",
                content: trimmed + "\n\n" + existing
            )
        } else {
            messages.insert(ChatMessage(role: "system", content: trimmed), at: 0)
        }
    }

    /// Append content to the end of the existing system message in a message array,
    /// or insert a new system message at position 0.
    static func appendSystemContent(
        _ content: String,
        into messages: inout [ChatMessage]
    ) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if let idx = messages.firstIndex(where: { $0.role == "system" }),
            let existing = messages[idx].content, !existing.isEmpty
        {
            messages[idx] = ChatMessage(
                role: "system",
                content: existing + "\n\n" + trimmed
            )
        } else {
            messages.insert(ChatMessage(role: "system", content: trimmed), at: 0)
        }
    }
}
