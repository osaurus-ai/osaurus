//
//  MemoryContextAssembler.swift
//  osaurus
//
//  Thin facade over MemoryRelevanceGate + MemoryPlanner. Builds the memory
//  block to inject before the user's message.
//
//  v1 stitched five sections totaling ~17K tokens on every turn. v2 routes
//  through the gate first and emits at most one section (default ~800
//  tokens), plus the always-on identity overrides block (which is tiny).
//

import Foundation

public actor MemoryContextAssembler {
    public static let shared = MemoryContextAssembler()

    private struct CacheEntry {
        let context: String
        let timestamp: Date
    }

    /// Cache key includes the query so different queries produce different
    /// gate verdicts and don't share a slot.
    private var cache: [String: CacheEntry] = [:]
    private static let cacheTTL: TimeInterval = 10

    public init() {}

    /// Assemble the memory block for the given agent and (optional) query.
    /// Always includes identity overrides (cheap, user-authored). The
    /// dynamic section is chosen by the relevance gate.
    public static func assembleContext(
        agentId: String,
        config: MemoryConfiguration,
        query: String = ""
    ) async -> String {
        await shared.assemble(agentId: agentId, config: config, query: query)
    }

    private func assemble(
        agentId: String,
        config: MemoryConfiguration,
        query: String
    ) async -> String {
        guard config.enabled else { return "" }
        guard MemoryDatabase.shared.isOpen else { return "" }

        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let cacheKey = "\(agentId)|\(trimmedQuery.prefix(120))"
        if let cached = cache[cacheKey], Date().timeIntervalSince(cached.timestamp) < Self.cacheTTL {
            return cached.context
        }

        let identity = (try? MemoryDatabase.shared.loadIdentity()) ?? Identity()

        // Identity overrides are always included (and tiny).
        let overridesBlock = MemoryPlanner.assembleIdentityOverridesOnly()

        // Pull a small entity list for the gate from recent episodes.
        let recentEpisodes =
            (try? MemoryDatabase.shared.loadEpisodes(agentId: agentId, days: 90, limit: 25)) ?? []
        let knownEntities = Set(
            recentEpisodes.flatMap(\.entities)
                + identity.overrides.flatMap { $0.split(separator: " ").map(String.init) }
        ).filter { $0.count >= 4 }

        let section = MemoryRelevanceGate.decide(
            query: trimmedQuery,
            identity: identity,
            knownEntities: Array(knownEntities),
            mode: config.relevanceGateMode
        )

        let dynamic =
            section == .none
            ? ""
            : await MemoryPlanner.assemble(
                section: section,
                agentId: agentId,
                query: trimmedQuery,
                budgetTokens: config.memoryBudgetTokens
            )

        var blocks: [String] = []
        let today = Self.naturalOutputFormatter.string(from: Date())
        blocks.append("Current date: \(today)")
        if !overridesBlock.isEmpty { blocks.append(overridesBlock) }
        if !dynamic.isEmpty { blocks.append(dynamic) }

        // If only the date was added, skip injection entirely so we don't
        // pay context cost on no-op turns.
        let dynamicHadContent = !overridesBlock.isEmpty || !dynamic.isEmpty
        let result = dynamicHadContent ? blocks.joined(separator: "\n\n") : ""

        cache[cacheKey] = CacheEntry(context: result, timestamp: Date())
        return result
    }

    /// Invalidate cache. Pass `agentId` to clear just that agent's slots.
    public func invalidateCache(agentId: String? = nil) {
        if let agentId {
            cache = cache.filter { !$0.key.hasPrefix("\(agentId)|") }
        } else {
            cache.removeAll()
        }
    }

    private static let naturalOutputFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMMM yyyy"
        f.locale = Locale(identifier: "en_US")
        return f
    }()
}
