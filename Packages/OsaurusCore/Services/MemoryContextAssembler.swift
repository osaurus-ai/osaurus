//
//  MemoryContextAssembler.swift
//  osaurus
//
//  Builds the memory context block for injection into system prompts.
//  Follows the spec's context assembly order: user edits, profile, working memory, summaries,
//  key relationships.
//

import Foundation

public actor MemoryContextAssembler {
    private static let charsPerToken = MemoryConfiguration.charsPerToken
    static let shared = MemoryContextAssembler()

    private struct CacheEntry {
        let context: String
        let timestamp: Date
    }

    private var cache: [String: CacheEntry] = [:]
    private static let cacheTTL: TimeInterval = 10

    /// Assemble the full memory context string for injection before the system prompt.
    /// User edits and profile are never trimmed. Working memory, summaries, and key
    /// relationships are budget-trimmed. Results are cached for 10 seconds per agent.
    public static func assembleContext(agentId: String, config: MemoryConfiguration) async -> String {
        await shared.assembleContextCached(agentId: agentId, config: config)
    }

    /// Assemble context with query-aware retrieval. Includes a "Relevant Memories" section
    /// with entries and conversation chunks semantically matched to the user's query.
    public static func assembleContext(
        agentId: String,
        config: MemoryConfiguration,
        query: String
    ) async -> String {
        await shared.assembleContextWithQuery(agentId: agentId, config: config, query: query)
    }

    private func assembleContextWithQuery(
        agentId: String,
        config: MemoryConfiguration,
        query: String
    ) async -> String {
        guard config.enabled else { return "" }

        let baseContext = buildContext(agentId: agentId, config: config)

        guard !query.isEmpty else { return baseContext }

        let relevantSection = await buildQueryRelevantSection(
            agentId: agentId,
            query: query,
            config: config,
            existingContext: baseContext
        )

        if relevantSection.isEmpty {
            return baseContext
        }

        return baseContext.isEmpty ? relevantSection : baseContext + "\n\n" + relevantSection
    }

    private func assembleContextCached(agentId: String, config: MemoryConfiguration) -> String {
        guard config.enabled else { return "" }

        if let cached = cache[agentId], Date().timeIntervalSince(cached.timestamp) < Self.cacheTTL {
            return cached.context
        }

        let context = buildContext(agentId: agentId, config: config)
        cache[agentId] = CacheEntry(context: context, timestamp: Date())
        return context
    }

    /// Invalidate cached context for a specific agent.
    public func invalidateCache(agentId: String? = nil) {
        if let agentId {
            cache.removeValue(forKey: agentId)
        } else {
            cache.removeAll()
        }
    }

    private func buildContext(agentId: String, config: MemoryConfiguration) -> String {
        let db = MemoryDatabase.shared
        guard db.isOpen else { return "" }

        var sections: [String] = []

        // 1. User Edits (explicit overrides — never trimmed)
        do {
            let edits = try db.loadUserEdits()
            if !edits.isEmpty {
                var block = "# User Overrides\n"
                for edit in edits {
                    block += "- \(edit.content)\n"
                }
                sections.append(block)
            }
        } catch {
            MemoryLogger.service.warning("Context assembly: failed to load user edits: \(error)")
        }

        // 2. User Profile (never trimmed)
        do {
            if let profile = try db.loadUserProfile() {
                sections.append("# User Profile\n\(profile.content)")
            }
        } catch {
            MemoryLogger.service.warning("Context assembly: failed to load user profile: \(error)")
        }

        // 3. Working Memory (this agent's active entries)
        do {
            let entries = try db.loadActiveEntries(agentId: agentId)
            if !entries.isEmpty {
                let block = buildBudgetSection(
                    header: "# Working Memory",
                    budgetTokens: config.workingMemoryBudgetTokens,
                    items: entries,
                    formatLine: Self.formatEntryLine
                )

                do { try db.touchMemoryEntries(ids: entries.map(\.id)) } catch {
                    MemoryLogger.service.warning("Context assembly: failed to touch entries: \(error)")
                }
                sections.append(block)
            }
        } catch {
            MemoryLogger.service.warning("Context assembly: failed to load working memory: \(error)")
        }

        // 4. Conversation Summaries (this agent, last N days)
        do {
            let summaries = try db.loadSummaries(agentId: agentId, days: config.summaryRetentionDays)
            if !summaries.isEmpty {
                sections.append(
                    buildBudgetSection(
                        header: "# Recent Conversation Summaries",
                        budgetTokens: config.summaryBudgetTokens,
                        items: summaries
                    ) { "- [date: \($0.conversationAt)] \($0.summary)" }
                )
            }
        } catch {
            MemoryLogger.service.warning("Context assembly: failed to load summaries: \(error)")
        }

        // 5. Knowledge Graph (key relationships)
        do {
            let relationships = try db.loadRecentRelationships(limit: 30)
            if !relationships.isEmpty {
                sections.append(
                    buildBudgetSection(
                        header: "# Key Relationships",
                        budgetTokens: config.graphBudgetTokens,
                        items: relationships
                    ) { "- \($0.path)" }
                )
            }
        } catch {
            MemoryLogger.service.warning("Context assembly: failed to load relationships: \(error)")
        }

        return sections.joined(separator: "\n\n")
    }

    /// Build a markdown section from items, trimming to a token budget.
    private func buildBudgetSection<T>(
        header: String,
        budgetTokens: Int,
        items: [T],
        formatLine: (T) -> String
    ) -> String {
        let budgetChars = budgetTokens * Self.charsPerToken
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

    /// Format a memory entry as a context line, including type and optional date.
    private static func formatEntryLine(_ entry: MemoryEntry) -> String {
        var line = "- [\(entry.type.displayName)] \(entry.content)"
        if !entry.validFrom.isEmpty {
            line += " (date: \(entry.validFrom))"
        }
        return line
    }

    // MARK: - Query-Aware Retrieval

    /// Search for memory entries and conversation chunks relevant to the query,
    /// deduplicating against entries already present in the base context.
    private func buildQueryRelevantSection(
        agentId: String,
        query: String,
        config: MemoryConfiguration,
        existingContext: String
    ) async -> String {
        let searchService = MemorySearchService.shared

        let topK = config.recallTopK
        let lambda = config.mmrLambda
        let fetchMultiplier = config.mmrFetchMultiplier

        async let entriesResult = searchService.searchMemoryEntries(
            query: query,
            agentId: agentId,
            topK: topK,
            lambda: lambda,
            fetchMultiplier: fetchMultiplier
        )
        async let chunksResult = searchService.searchConversations(
            query: query,
            agentId: agentId,
            days: 365,
            topK: topK,
            lambda: lambda,
            fetchMultiplier: fetchMultiplier
        )

        let entries = await entriesResult
        let chunks = await chunksResult

        var sections: [String] = []
        let budgetTokens = config.workingMemoryBudgetTokens

        if !entries.isEmpty {
            let deduplicated = entries.filter { entry in
                !existingContext.contains(entry.content)
            }
            if !deduplicated.isEmpty {
                sections.append(
                    buildBudgetSection(
                        header: "# Relevant Memories",
                        budgetTokens: budgetTokens,
                        items: deduplicated,
                        formatLine: Self.formatEntryLine
                    )
                )
            }
        }

        if !chunks.isEmpty {
            sections.append(
                buildBudgetSection(
                    header: "# Relevant Conversation Excerpts",
                    budgetTokens: budgetTokens,
                    items: chunks
                ) { chunk in
                    var line = "- \(chunk.content)"
                    if !chunk.createdAt.isEmpty {
                        line += " (date: \(chunk.createdAt))"
                    }
                    return line
                }
            )
        }

        return sections.joined(separator: "\n\n")
    }
}
