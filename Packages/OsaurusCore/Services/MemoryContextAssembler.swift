//
//  MemoryContextAssembler.swift
//  osaurus
//
//  Builds the memory context block for injection into system prompts.
//  Follows the spec's context assembly order: user edits, profile, working memory, summaries.
//

import Foundation

public enum MemoryContextAssembler: Sendable {
    private static let charsPerToken = 4

    /// Assemble the full memory context string for injection before the system prompt.
    /// User edits and profile are never trimmed. Working memory and summaries are trimmed
    /// if they exceed the remaining budget.
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
        let wmBudgetChars = config.workingMemoryBudgetTokens * charsPerToken
        if let entries = try? db.loadActiveEntries(agentId: agentId), !entries.isEmpty {
            var block = "# Working Memory\n"
            var usedChars = block.count

            for entry in entries {
                let line = "- [\(entry.type.displayName)] \(entry.content)\n"
                if usedChars + line.count > wmBudgetChars { break }
                block += line
                usedChars += line.count

                try? db.touchMemoryEntry(id: entry.id)
            }
            sections.append(block)
        }

        // 4. Conversation Summaries (this agent, last N days)
        let sumBudgetChars = config.summaryBudgetTokens * charsPerToken
        if let summaries = try? db.loadSummaries(agentId: agentId, days: config.summaryRetentionDays), !summaries.isEmpty {
            var block = "# Recent Conversation Summaries\n"
            var usedChars = block.count

            for summary in summaries {
                let line = "- \(summary.conversationAt): \(summary.summary)\n"
                if usedChars + line.count > sumBudgetChars { break }
                block += line
                usedChars += line.count
            }
            sections.append(block)
        }

        return sections.joined(separator: "\n")
    }
}
