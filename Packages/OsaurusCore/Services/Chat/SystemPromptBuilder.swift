//
//  SystemPromptBuilder.swift
//  osaurus
//
//  Legacy system prompt helpers. New code should use SystemPromptComposer
//  to build prompts and SystemPromptTemplates for prompt text.
//
//  Retained helpers: effectiveBasePrompt, isLocalModel.
//  Deprecated helpers: prependMemoryContext, injectSystemContent,
//  injectMemoryContext, appendSystemContent — use SystemPromptComposer instead.
//

import Foundation

/// Legacy system prompt helpers retained for backward compatibility.
///
/// For new code, use `SystemPromptComposer` to assemble prompt sections and
/// `SystemPromptTemplates` for prompt text constants.
public enum SystemPromptBuilder {

    static let defaultIdentity = SystemPromptTemplates.defaultIdentity

    // MARK: - Deprecated Concat Helpers

    /// Use `SystemPromptComposer` instead.
    static func prependMemoryContext(_ memoryContext: String, to systemPrompt: String) -> String {
        let trimmedMemory = memoryContext.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPrompt = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedMemory.isEmpty { return trimmedPrompt }
        if trimmedPrompt.isEmpty { return trimmedMemory }
        return trimmedMemory + "\n\n" + trimmedPrompt
    }

    /// Use `SystemPromptComposer` instead.
    static func injectMemoryContext(
        _ memoryContext: String,
        into messages: inout [ChatMessage]
    ) {
        let trimmed = memoryContext.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if let idx = messages.firstIndex(where: { $0.role == "system" }) {
            let existing = messages[idx].content ?? ""
            messages[idx] = ChatMessage(
                role: "system",
                content: prependMemoryContext(trimmed, to: existing)
            )
        } else {
            messages.insert(ChatMessage(role: "system", content: trimmed), at: 0)
        }
    }

    /// Use `SystemPromptComposer` instead.
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

    /// Use `SystemPromptComposer` instead.
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

    // MARK: - Base Prompt with Default Identity

    /// Returns the effective base prompt, falling back to a minimal default
    /// identity when the user has not configured one.
    static func effectiveBasePrompt(_ basePrompt: String) -> String {
        let trimmed = basePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultIdentity : trimmed
    }

    // MARK: - Model Classification

    /// Returns true when the model identifier refers to a local model
    /// (Foundation or MLX) that benefits from shorter prompts.
    static func isLocalModel(_ modelId: String?) -> Bool {
        let trimmed = (modelId ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.isEmpty || trimmed == "default" || trimmed == "foundation" {
            return true
        }
        if trimmed.contains("/") {
            return false
        }
        return ModelManager.findInstalledModel(named: trimmed) != nil
    }
}
