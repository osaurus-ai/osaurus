//
//  MemoryConfiguration.swift
//  osaurus
//
//  User-configurable settings for the memory system.
//

import Foundation

public struct MemoryConfiguration: Codable, Equatable, Sendable {
    /// Core Model provider (e.g. "anthropic")
    public var coreModelProvider: String
    /// Core Model name (e.g. "claude-haiku-4-5")
    public var coreModelName: String

    /// Embedding backend ("mlx" or "none")
    public var embeddingBackend: String
    /// Embedding model name
    public var embeddingModel: String

    /// Seconds of inactivity before post-activity processing triggers
    public var inactivityTimeoutSeconds: Int

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

    /// Top-K results for recall searches
    public var recallTopK: Int
    /// Half-life in days for temporal decay in search ranking
    public var temporalDecayHalfLifeDays: Int

    /// MMR relevance vs diversity tradeoff. 1.0 = pure relevance, 0.0 = pure diversity.
    public var mmrLambda: Double
    /// Over-fetch multiplier for MMR: fetch this many times topK from VecturaKit, then rerank down.
    public var mmrFetchMultiplier: Double

    /// Whether the memory system is enabled
    public var enabled: Bool

    /// Full model identifier for routing (e.g. "anthropic/claude-haiku-4-5" or "foundation")
    public var coreModelIdentifier: String {
        coreModelProvider.isEmpty ? coreModelName : "\(coreModelProvider)/\(coreModelName)"
    }

    public init(
        coreModelProvider: String = "anthropic",
        coreModelName: String = "claude-haiku-4-5",
        embeddingBackend: String = "mlx",
        embeddingModel: String = "nomic-embed-text-v1.5",
        inactivityTimeoutSeconds: Int = 300,
        profileMaxTokens: Int = 2000,
        profileRegenerateThreshold: Int = 10,
        workingMemoryBudgetTokens: Int = 500,
        summaryRetentionDays: Int = 7,
        summaryBudgetTokens: Int = 1000,
        recallTopK: Int = 10,
        temporalDecayHalfLifeDays: Int = 30,
        mmrLambda: Double = 0.7,
        mmrFetchMultiplier: Double = 2.0,
        enabled: Bool = true
    ) {
        self.coreModelProvider = coreModelProvider
        self.coreModelName = coreModelName
        self.embeddingBackend = embeddingBackend
        self.embeddingModel = embeddingModel
        self.inactivityTimeoutSeconds = inactivityTimeoutSeconds
        self.profileMaxTokens = profileMaxTokens
        self.profileRegenerateThreshold = profileRegenerateThreshold
        self.workingMemoryBudgetTokens = workingMemoryBudgetTokens
        self.summaryRetentionDays = summaryRetentionDays
        self.summaryBudgetTokens = summaryBudgetTokens
        self.recallTopK = recallTopK
        self.temporalDecayHalfLifeDays = temporalDecayHalfLifeDays
        self.mmrLambda = mmrLambda
        self.mmrFetchMultiplier = mmrFetchMultiplier
        self.enabled = enabled
    }

    public init(from decoder: Decoder) throws {
        let defaults = MemoryConfiguration()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        coreModelProvider = try c.decodeIfPresent(String.self, forKey: .coreModelProvider) ?? defaults.coreModelProvider
        coreModelName = try c.decodeIfPresent(String.self, forKey: .coreModelName) ?? defaults.coreModelName
        embeddingBackend = try c.decodeIfPresent(String.self, forKey: .embeddingBackend) ?? defaults.embeddingBackend
        embeddingModel = try c.decodeIfPresent(String.self, forKey: .embeddingModel) ?? defaults.embeddingModel
        inactivityTimeoutSeconds =
            try c.decodeIfPresent(Int.self, forKey: .inactivityTimeoutSeconds) ?? defaults.inactivityTimeoutSeconds
        profileMaxTokens = try c.decodeIfPresent(Int.self, forKey: .profileMaxTokens) ?? defaults.profileMaxTokens
        profileRegenerateThreshold =
            try c.decodeIfPresent(Int.self, forKey: .profileRegenerateThreshold) ?? defaults.profileRegenerateThreshold
        workingMemoryBudgetTokens =
            try c.decodeIfPresent(Int.self, forKey: .workingMemoryBudgetTokens) ?? defaults.workingMemoryBudgetTokens
        summaryRetentionDays =
            try c.decodeIfPresent(Int.self, forKey: .summaryRetentionDays) ?? defaults.summaryRetentionDays
        summaryBudgetTokens =
            try c.decodeIfPresent(Int.self, forKey: .summaryBudgetTokens) ?? defaults.summaryBudgetTokens
        recallTopK = try c.decodeIfPresent(Int.self, forKey: .recallTopK) ?? defaults.recallTopK
        temporalDecayHalfLifeDays =
            try c.decodeIfPresent(Int.self, forKey: .temporalDecayHalfLifeDays) ?? defaults.temporalDecayHalfLifeDays
        mmrLambda = try c.decodeIfPresent(Double.self, forKey: .mmrLambda) ?? defaults.mmrLambda
        mmrFetchMultiplier =
            try c.decodeIfPresent(Double.self, forKey: .mmrFetchMultiplier) ?? defaults.mmrFetchMultiplier
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? defaults.enabled
    }

    public static var `default`: MemoryConfiguration { MemoryConfiguration() }
}

// MARK: - Store

@MainActor
public enum MemoryConfigurationStore {
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    public static func load() -> MemoryConfiguration {
        let url = OsaurusPaths.memoryConfigFile()
        guard FileManager.default.fileExists(atPath: url.path) else {
            let defaults = MemoryConfiguration.default
            save(defaults)
            return defaults
        }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(MemoryConfiguration.self, from: data)
        } catch {
            print("[Memory] Failed to load config: \(error)")
            return .default
        }
    }

    public static func save(_ config: MemoryConfiguration) {
        let url = OsaurusPaths.memoryConfigFile()
        OsaurusPaths.ensureExistsSilent(url.deletingLastPathComponent())
        do {
            let data = try encoder.encode(config)
            try data.write(to: url, options: .atomic)
        } catch {
            print("[Memory] Failed to save config: \(error)")
        }
    }
}
