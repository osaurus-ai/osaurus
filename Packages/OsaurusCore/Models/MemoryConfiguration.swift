//
//  MemoryConfiguration.swift
//  osaurus
//
//  User-configurable settings for the memory system.
//

import Foundation
import os

public struct MemoryConfiguration: Codable, Equatable, Sendable {
    /// Core Model provider (e.g. "anthropic")
    public var coreModelProvider: String
    /// Core Model name (e.g. "claude-haiku-4-5")
    public var coreModelName: String

    /// Embedding backend ("mlx" or "none")
    public var embeddingBackend: String
    /// Embedding model name
    public var embeddingModel: String

    /// Seconds of inactivity before session summary generation triggers (debounce)
    public var summaryDebounceSeconds: Int

    /// Maximum token count for the user profile
    public var profileMaxTokens: Int
    /// Number of new contributions before profile regeneration
    public var profileRegenerateThreshold: Int

    /// Token budget for working memory in context
    public var workingMemoryBudgetTokens: Int

    /// Default retention in days for conversation summaries
    public var summaryRetentionDays: Int
    /// Token budget for summaries in context
    public var summaryBudgetTokens: Int

    /// Token budget for conversation chunk excerpts in context
    public var chunkBudgetTokens: Int

    /// Token budget for knowledge graph relationships in context
    public var graphBudgetTokens: Int

    /// Top-K results for recall searches
    public var recallTopK: Int
    /// Half-life in days for temporal decay in search ranking
    public var temporalDecayHalfLifeDays: Int

    /// MMR relevance vs diversity tradeoff. 1.0 = pure relevance, 0.0 = pure diversity.
    public var mmrLambda: Double
    /// Over-fetch multiplier for MMR: fetch this many times topK from VecturaKit, then rerank down.
    public var mmrFetchMultiplier: Double

    /// Maximum active entries per agent before oldest are archived (0 = unlimited)
    public var maxEntriesPerAgent: Int

    /// Whether the memory system is enabled
    public var enabled: Bool

    /// Whether entry verification pipeline is enabled
    public var verificationEnabled: Bool
    /// VecturaKit similarity score threshold for semantic dedup — above this, candidates are SKIP'd as semantic duplicates
    public var verificationSemanticDedupThreshold: Double
    /// Jaccard threshold for Layer 1 near-duplicate detection (above this = auto-SKIP)
    public var verificationJaccardDedupThreshold: Double

    /// Full model identifier for routing (e.g. "anthropic/claude-haiku-4-5" or "foundation")
    public var coreModelIdentifier: String {
        coreModelProvider.isEmpty ? coreModelName : "\(coreModelProvider)/\(coreModelName)"
    }

    // MARK: - Internal Constants (not user-configurable)

    /// Approximate characters per token for budget calculations.
    public static let charsPerToken = 4
    /// Max existing entries included in the extraction prompt.
    public static let extractionPromptEntryLimit = 30
    /// Default LIMIT for fallback text search queries.
    public static let fallbackSearchLimit = 20
    /// Jaccard threshold for profile fact deduplication.
    public static let profileFactDedupThreshold = 0.6
    /// Jaccard threshold for contradiction detection (entries with same type and similarity above this are potential contradictions).
    public static let contradictionJaccardThreshold = 0.3

    /// Maximum allowed content length for memory entries and profile (in characters).
    public static let maxContentLength = 50_000

    public init(
        coreModelProvider: String = "anthropic",
        coreModelName: String = "claude-haiku-4-5",
        embeddingBackend: String = "mlx",
        embeddingModel: String = "nomic-embed-text-v1.5",
        summaryDebounceSeconds: Int = 60,
        profileMaxTokens: Int = 2000,
        profileRegenerateThreshold: Int = 10,
        workingMemoryBudgetTokens: Int = 3000,
        summaryRetentionDays: Int = 180,
        summaryBudgetTokens: Int = 3000,
        chunkBudgetTokens: Int = 3000,
        graphBudgetTokens: Int = 300,
        recallTopK: Int = 30,
        temporalDecayHalfLifeDays: Int = 30,
        mmrLambda: Double = 0.7,
        mmrFetchMultiplier: Double = 2.0,
        maxEntriesPerAgent: Int = 500,
        enabled: Bool = true,
        verificationEnabled: Bool = true,
        verificationSemanticDedupThreshold: Double = 0.85,
        verificationJaccardDedupThreshold: Double = 0.6
    ) {
        self.coreModelProvider = coreModelProvider
        self.coreModelName = coreModelName
        self.embeddingBackend = embeddingBackend
        self.embeddingModel = embeddingModel
        self.summaryDebounceSeconds = summaryDebounceSeconds
        self.profileMaxTokens = profileMaxTokens
        self.profileRegenerateThreshold = profileRegenerateThreshold
        self.workingMemoryBudgetTokens = workingMemoryBudgetTokens
        self.summaryRetentionDays = summaryRetentionDays
        self.summaryBudgetTokens = summaryBudgetTokens
        self.chunkBudgetTokens = chunkBudgetTokens
        self.graphBudgetTokens = graphBudgetTokens
        self.recallTopK = recallTopK
        self.temporalDecayHalfLifeDays = temporalDecayHalfLifeDays
        self.mmrLambda = mmrLambda
        self.mmrFetchMultiplier = mmrFetchMultiplier
        self.maxEntriesPerAgent = maxEntriesPerAgent
        self.enabled = enabled
        self.verificationEnabled = verificationEnabled
        self.verificationSemanticDedupThreshold = verificationSemanticDedupThreshold
        self.verificationJaccardDedupThreshold = verificationJaccardDedupThreshold
    }

    /// Returns a copy with all values clamped to valid ranges.
    public func validated() -> MemoryConfiguration {
        var c = self
        c.summaryDebounceSeconds = max(10, min(c.summaryDebounceSeconds, 3600))
        c.profileMaxTokens = max(100, min(c.profileMaxTokens, 50_000))
        c.profileRegenerateThreshold = max(1, min(c.profileRegenerateThreshold, 100))
        c.workingMemoryBudgetTokens = max(50, min(c.workingMemoryBudgetTokens, 10_000))
        c.summaryRetentionDays = max(0, min(c.summaryRetentionDays, 3650))
        c.summaryBudgetTokens = max(50, min(c.summaryBudgetTokens, 10_000))
        c.chunkBudgetTokens = max(50, min(c.chunkBudgetTokens, 20_000))
        c.graphBudgetTokens = max(50, min(c.graphBudgetTokens, 5_000))
        c.recallTopK = max(1, min(c.recallTopK, 100))
        c.temporalDecayHalfLifeDays = max(1, min(c.temporalDecayHalfLifeDays, 365))
        c.mmrLambda = max(0.0, min(c.mmrLambda, 1.0))
        c.mmrFetchMultiplier = max(1.0, min(c.mmrFetchMultiplier, 10.0))
        c.maxEntriesPerAgent = max(0, min(c.maxEntriesPerAgent, 10_000))
        c.verificationSemanticDedupThreshold = max(0.0, min(c.verificationSemanticDedupThreshold, 1.0))
        c.verificationJaccardDedupThreshold = max(0.0, min(c.verificationJaccardDedupThreshold, 1.0))
        return c
    }

    public init(from decoder: Decoder) throws {
        let defaults = MemoryConfiguration()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        coreModelProvider = try c.decodeIfPresent(String.self, forKey: .coreModelProvider) ?? defaults.coreModelProvider
        coreModelName = try c.decodeIfPresent(String.self, forKey: .coreModelName) ?? defaults.coreModelName
        embeddingBackend = try c.decodeIfPresent(String.self, forKey: .embeddingBackend) ?? defaults.embeddingBackend
        embeddingModel = try c.decodeIfPresent(String.self, forKey: .embeddingModel) ?? defaults.embeddingModel
        summaryDebounceSeconds =
            try c.decodeIfPresent(Int.self, forKey: .summaryDebounceSeconds)
            ?? defaults.summaryDebounceSeconds
        profileMaxTokens = try c.decodeIfPresent(Int.self, forKey: .profileMaxTokens) ?? defaults.profileMaxTokens
        profileRegenerateThreshold =
            try c.decodeIfPresent(Int.self, forKey: .profileRegenerateThreshold) ?? defaults.profileRegenerateThreshold
        workingMemoryBudgetTokens =
            try c.decodeIfPresent(Int.self, forKey: .workingMemoryBudgetTokens) ?? defaults.workingMemoryBudgetTokens
        summaryRetentionDays =
            try c.decodeIfPresent(Int.self, forKey: .summaryRetentionDays) ?? defaults.summaryRetentionDays
        summaryBudgetTokens =
            try c.decodeIfPresent(Int.self, forKey: .summaryBudgetTokens) ?? defaults.summaryBudgetTokens
        chunkBudgetTokens =
            try c.decodeIfPresent(Int.self, forKey: .chunkBudgetTokens) ?? defaults.chunkBudgetTokens
        graphBudgetTokens =
            try c.decodeIfPresent(Int.self, forKey: .graphBudgetTokens) ?? defaults.graphBudgetTokens
        recallTopK = try c.decodeIfPresent(Int.self, forKey: .recallTopK) ?? defaults.recallTopK
        temporalDecayHalfLifeDays =
            try c.decodeIfPresent(Int.self, forKey: .temporalDecayHalfLifeDays) ?? defaults.temporalDecayHalfLifeDays
        mmrLambda = try c.decodeIfPresent(Double.self, forKey: .mmrLambda) ?? defaults.mmrLambda
        mmrFetchMultiplier =
            try c.decodeIfPresent(Double.self, forKey: .mmrFetchMultiplier) ?? defaults.mmrFetchMultiplier
        maxEntriesPerAgent =
            try c.decodeIfPresent(Int.self, forKey: .maxEntriesPerAgent) ?? defaults.maxEntriesPerAgent
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? defaults.enabled
        verificationEnabled =
            try c.decodeIfPresent(Bool.self, forKey: .verificationEnabled) ?? defaults.verificationEnabled
        verificationSemanticDedupThreshold =
            try c.decodeIfPresent(Double.self, forKey: .verificationSemanticDedupThreshold)
            ?? defaults.verificationSemanticDedupThreshold
        verificationJaccardDedupThreshold =
            try c.decodeIfPresent(Double.self, forKey: .verificationJaccardDedupThreshold)
            ?? defaults.verificationJaccardDedupThreshold
    }

    public static var `default`: MemoryConfiguration { MemoryConfiguration() }
}

// MARK: - Store

public enum MemoryConfigurationStore: Sendable {
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let lock = OSAllocatedUnfairLock<MemoryConfiguration?>(initialState: nil)

    public static func load() -> MemoryConfiguration {
        if let cached = lock.withLock({ $0 }) { return cached }

        let url = OsaurusPaths.memoryConfigFile()
        guard FileManager.default.fileExists(atPath: url.path) else {
            let defaults = MemoryConfiguration.default
            save(defaults)
            return defaults
        }
        do {
            let data = try Data(contentsOf: url)
            let config = try JSONDecoder().decode(MemoryConfiguration.self, from: data)
            let validated = config.validated()
            lock.withLock { $0 = validated }
            return validated
        } catch {
            MemoryLogger.config.error("Failed to load config: \(error)")
            return .default
        }
    }

    public static func save(_ config: MemoryConfiguration) {
        let validated = config.validated()
        let url = OsaurusPaths.memoryConfigFile()
        OsaurusPaths.ensureExistsSilent(url.deletingLastPathComponent())
        do {
            let data = try encoder.encode(validated)
            try data.write(to: url, options: .atomic)
            lock.withLock { $0 = validated }
        } catch {
            MemoryLogger.config.error("Failed to save config: \(error)")
        }
    }

    public static func invalidateCache() {
        lock.withLock { $0 = nil }
    }
}
