//
//  MemoryContextAssembler.swift
//  osaurus
//
//  Builds the memory context block for injection into system prompts.
//  Follows the spec's context assembly order: user edits, profile, working memory, summaries,
//  key relationships.
//

import Foundation

public enum MemoryContextAssembler: Sendable {
    private static let charsPerToken = 4

    /// Assemble the full memory context string for injection before the system prompt.
    /// User edits and profile are never trimmed. Working memory, summaries, and key
    /// relationships are budget-trimmed.
    public static func assembleContext(agentId: String, config: MemoryConfiguration) -> String {
        guard config.enabled else { return "" }

        let db = MemoryDatabase.shared
        guard db.isOpen else { return "" }

        var sections: [String] = []

        // 1. User Edits (explicit overrides — never trimmed)
        if let edits = try? db.loadUserEdits(), !edits.isEmpty {
            var block = "# User Overrides\n"
            for edit in edits {
                block += "- \(edit.content)\n"
            }
            sections.append(block)
        }

        // 2. User Profile (never trimmed)
        if let profile = try? db.loadUserProfile() {
            sections.append("# User Profile\n\(profile.content)")
        }

        // 3. Working Memory (this agent's active entries)
        if let entries = try? db.loadActiveEntries(agentId: agentId), !entries.isEmpty {
            let block = buildBudgetSection(
                header: "# Working Memory",
                budgetTokens: config.workingMemoryBudgetTokens,
                items: entries
            ) { "- [\($0.type.displayName)] \($0.content)" }

            for entry in entries { try? db.touchMemoryEntry(id: entry.id) }
            sections.append(block)
        }

        // 4. Conversation Summaries (this agent, last N days)
        if let summaries = try? db.loadSummaries(agentId: agentId, days: config.summaryRetentionDays),
            !summaries.isEmpty
        {
            sections.append(
                buildBudgetSection(
                    header: "# Recent Conversation Summaries",
                    budgetTokens: config.summaryBudgetTokens,
                    items: summaries
                ) { "- \($0.conversationAt): \($0.summary)" }
            )
        }

        // 5. Knowledge Graph (key relationships)
        if let relationships = try? db.loadRecentRelationships(limit: 30), !relationships.isEmpty {
            sections.append(
                buildBudgetSection(
                    header: "# Key Relationships",
                    budgetTokens: config.graphBudgetTokens,
                    items: relationships
                ) { "- \($0.path)" }
            )
        }

        return sections.joined(separator: "\n")
    }

    /// Build a markdown section from items, trimming to a token budget.
    private static func buildBudgetSection<T>(
        header: String,
        budgetTokens: Int,
        items: [T],
        formatLine: (T) -> String
    ) -> String {
        let budgetChars = budgetTokens * charsPerToken
        var block = "\(header)\n"
        var usedChars = block.count

        for item in items {
            let line = "\(formatLine(item))\n"
            if usedChars + line.count > budgetChars { break }
            block += line
            usedChars += line.count
        }
        return block
    }
}
