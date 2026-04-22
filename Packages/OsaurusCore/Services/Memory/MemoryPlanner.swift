//
//  MemoryPlanner.swift
//  osaurus
//
//  Given the relevance gate's verdict, fetch and format the single best
//  memory section for this turn under the configured token budget.
//
//  v1 injected up to five sections totaling ~17K tokens on every turn.
//  v2 picks ONE primary section (~800 tokens default) and stays out of the
//  way otherwise. Identity overrides are the sole exception — they're tiny,
//  user-authored, and always included.
//

import Foundation

public enum MemoryPlanner {
    /// Fetch and format the chosen section.
    public static func assemble(
        section: MemoryRecallSection,
        agentId: String,
        query: String,
        budgetTokens: Int
    ) async -> String {
        switch section {
        case .none:
            return ""
        case .identity:
            return assembleIdentity(budgetTokens: budgetTokens)
        case .pinned:
            return await assemblePinned(agentId: agentId, query: query, budgetTokens: budgetTokens)
        case .episode:
            return await assembleEpisodes(agentId: agentId, query: query, budgetTokens: budgetTokens)
        case .transcript:
            return await assembleTranscript(agentId: agentId, query: query, budgetTokens: budgetTokens)
        }
    }

    /// Identity overrides. Always small enough to ignore the budget.
    public static func assembleIdentityOverridesOnly() -> String {
        guard let id = try? MemoryDatabase.shared.loadIdentity() else { return "" }
        guard !id.overrides.isEmpty else { return "" }
        var block = "## What I should always remember\n"
        for override in id.overrides {
            block += "- \(override)\n"
        }
        return block
    }

    private static func assembleIdentity(budgetTokens: Int) -> String {
        guard let id = try? MemoryDatabase.shared.loadIdentity() else { return "" }
        let hasOverrides = !id.overrides.isEmpty
        let hasContent = !id.content.isEmpty
        guard hasOverrides || hasContent else { return "" }

        var block = "## About you\n"
        if hasOverrides {
            for override in id.overrides {
                block += "- \(override)\n"
            }
        }
        if hasContent {
            if hasOverrides { block += "\n" }
            block += truncateToTokenBudget(id.content, budgetTokens: budgetTokens)
        }
        return block
    }

    private static func assemblePinned(agentId: String, query: String, budgetTokens: Int) async -> String {
        let topK = max(3, min(15, budgetTokens / 60))
        let facts = await MemorySearchService.shared.searchPinnedFacts(
            query: query,
            agentId: agentId,
            topK: topK
        )
        guard !facts.isEmpty else { return "" }

        // Bump usage so the consolidator has signal for promotion/decay.
        try? MemoryDatabase.shared.bumpPinnedFactUsage(ids: facts.map(\.id))

        let lines = facts.map { "- \($0.content)" }
        return budgetSection(header: "## Things I remember", lines: lines, budgetTokens: budgetTokens)
    }

    private static func assembleEpisodes(agentId: String, query: String, budgetTokens: Int) async -> String {
        let topK = max(2, min(8, budgetTokens / 120))
        let episodes = await MemorySearchService.shared.searchEpisodes(
            query: query,
            agentId: agentId,
            topK: topK
        )
        guard !episodes.isEmpty else { return "" }

        var lines: [String] = []
        for ep in episodes {
            let date = String(ep.conversationAt.prefix(10))
            var line = "- [\(date)] \(ep.summary)"
            if !ep.decisions.isEmpty {
                let firstDecision = ep.decisions.split(separator: "\n").first.map(String.init) ?? ""
                if !firstDecision.isEmpty {
                    line += " (decision: \(firstDecision))"
                }
            }
            lines.append(line)
        }
        return budgetSection(header: "## What we discussed before", lines: lines, budgetTokens: budgetTokens)
    }

    private static func assembleTranscript(agentId: String, query: String, budgetTokens: Int) async -> String {
        let topK = max(2, min(6, budgetTokens / 200))
        let turns = await MemorySearchService.shared.searchTranscript(
            query: query,
            agentId: agentId,
            days: 365,
            topK: topK
        )
        guard !turns.isEmpty else { return "" }

        var lines: [String] = []
        for turn in turns {
            let date = String(turn.createdAt.prefix(10))
            let preview = String(turn.content.prefix(220))
            let suffix = turn.content.count > 220 ? "…" : ""
            lines.append("- [\(date), \(turn.role)] \(preview)\(suffix)")
        }
        return budgetSection(header: "## Earlier in our chats", lines: lines, budgetTokens: budgetTokens)
    }

    // MARK: - Budgeting helpers

    private static func budgetSection(header: String, lines: [String], budgetTokens: Int) -> String {
        let budgetChars = budgetTokens * MemoryConfiguration.charsPerToken
        var block = header + "\n"
        var used = block.count
        for line in lines {
            let appended = line + "\n"
            if used + appended.count > budgetChars { break }
            block += appended
            used += appended.count
        }
        return block
    }

    private static func truncateToTokenBudget(_ text: String, budgetTokens: Int) -> String {
        let budgetChars = budgetTokens * MemoryConfiguration.charsPerToken
        if text.count <= budgetChars { return text }
        return String(text.prefix(max(0, budgetChars - 1))) + "…"
    }
}
