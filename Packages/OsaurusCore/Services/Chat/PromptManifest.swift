//
//  PromptManifest.swift
//  osaurus
//
//  Data types for structured system prompt composition.
//  PromptSection represents one logical block; PromptManifest is the
//  assembled snapshot used for token accounting, cache hashing, and debug.
//

import CryptoKit
import Foundation

// MARK: - PromptSection

/// One logical block of the system prompt (e.g. base identity, sandbox, memory).
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

    /// Tokens from sections that are NOT the memory section.
    public var systemPromptTokens: Int {
        sections.filter { $0.id != "memory" }.reduce(0) { $0 + $1.estimatedTokens }
    }

    /// Tokens from the memory section specifically.
    public var memoryTokens: Int {
        section("memory")?.estimatedTokens ?? 0
    }

    public func section(_ id: String) -> PromptSection? {
        sections.first { $0.id == id }
    }

    /// Rendered content of only the static sections (before the first dynamic section).
    public var staticPrefixContent: String {
        var parts: [String] = []
        for section in sections {
            if section.cacheability == .dynamic { break }
            let trimmed = section.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { parts.append(trimmed) }
        }
        return parts.joined(separator: "\n\n")
    }

    /// Hash of static prefix content + tool names for cache key.
    public func staticPrefixHash(toolNames: [String]) -> String {
        let tools = toolNames.sorted().joined(separator: "\0")
        let combined = staticPrefixContent + "\0" + tools
        let digest = SHA256.hash(data: Data(combined.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

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

// MARK: - ComposedContext

/// Complete output from a high-level compose call -- everything a caller needs
/// to build a chat request and feed the budget tracker.
struct ComposedContext: Sendable {
    let prompt: String
    let manifest: PromptManifest
    let tools: [Tool]
    let toolTokens: Int
    let preflightItems: [PreflightCapabilityItem]
    /// The full preflight result this compose call resolved (either fresh or
    /// echoed back from the caller's session cache). Callers that maintain a
    /// per-session `SessionToolState` stash this on first compose so subsequent
    /// composes can pass it back via `cachedPreflight` and skip the LLM call.
    let preflight: PreflightResult
    /// Per-turn memory snippet, returned separately so callers can prepend it
    /// to the latest user message instead of mutating the system prompt. Nil
    /// when memory is disabled or empty. Keeping memory out of the system
    /// prefix is what makes the prompt byte-stable across turns once preflight
    /// is cached.
    let memorySection: String?
    /// Snapshot of the always-loaded tool names this compose used. Callers
    /// stash it on `SessionToolState.initialAlwaysLoadedNames` after the
    /// first compose so subsequent composes can freeze the schema against
    /// it via `frozenAlwaysLoadedNames` — preventing tools that register
    /// mid-session from silently appearing in turn 2.
    let alwaysLoadedNames: Set<String>
    /// Hash of the static prefix + tool names for KV cache lookup.
    let cacheHint: String
    /// Rendered static-only system content for prefix cache building.
    /// The prefix cache should be built from this content (not the full prompt)
    /// so the cached KV exactly matches the reusable portion across requests.
    let staticPrefix: String
}
