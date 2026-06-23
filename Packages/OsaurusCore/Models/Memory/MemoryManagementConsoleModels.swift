//
//  MemoryManagementConsoleModels.swift
//  osaurus
//
//  Data contracts for the Memory management console. The console is an
//  administrative view over SQL-backed memory rows, so it uses privacy-safe
//  display models rather than exposing raw row payloads directly to SwiftUI.
//

import Foundation

public enum MemoryConsoleScope: String, CaseIterable, Identifiable, Sendable {
    case all
    case pinned
    case episodes
    case transcript

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .all: return "All"
        case .pinned: return "Pinned"
        case .episodes: return "Episodes"
        case .transcript: return "Transcript"
        }
    }
}

public enum MemoryConsoleItemKind: String, Sendable {
    case pinnedFact
    case episode
    case transcriptTurn

    public var displayName: String {
        switch self {
        case .pinnedFact: return "Pinned fact"
        case .episode: return "Episode"
        case .transcriptTurn: return "Transcript turn"
        }
    }
}

public struct MemoryConsoleQuery: Equatable, Sendable {
    public var text: String
    public var scope: MemoryConsoleScope
    public var agentId: String?
    public var includeDisabled: Bool
    public var limit: Int

    public init(
        text: String = "",
        scope: MemoryConsoleScope = .all,
        agentId: String? = nil,
        includeDisabled: Bool = false,
        limit: Int = 60
    ) {
        self.text = text
        self.scope = scope
        self.agentId = agentId
        self.includeDisabled = includeDisabled
        self.limit = max(1, min(limit, 250))
    }

    public var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct MemoryRedactionResult: Equatable, Sendable {
    public var text: String
    public var redactionCounts: [String: Int]
    public var originalCharacterCount: Int
    public var displayedCharacterCount: Int
    public var wasTruncated: Bool

    public init(
        text: String,
        redactionCounts: [String: Int] = [:],
        originalCharacterCount: Int,
        displayedCharacterCount: Int,
        wasTruncated: Bool
    ) {
        self.text = text
        self.redactionCounts = redactionCounts
        self.originalCharacterCount = originalCharacterCount
        self.displayedCharacterCount = displayedCharacterCount
        self.wasTruncated = wasTruncated
    }

    public var redactionCount: Int {
        redactionCounts.values.reduce(0, +)
    }
}

public struct MemoryConsoleMetadata: Equatable, Sendable {
    public var salience: Double?
    public var sourceCount: Int?
    public var sourceEpisodeId: Int?
    public var lastUsed: String?
    public var useCount: Int?
    public var status: String?
    public var createdAt: String?
    public var tokenCount: Int?
    public var conversationAt: String?
    public var conversationId: String?
    public var conversationTitle: String?
    public var chunkIndex: Int?
    public var role: String?
    public var model: String?
    public var tags: [String]
    public var topics: [String]
    public var entities: [String]

    public init(
        salience: Double? = nil,
        sourceCount: Int? = nil,
        sourceEpisodeId: Int? = nil,
        lastUsed: String? = nil,
        useCount: Int? = nil,
        status: String? = nil,
        createdAt: String? = nil,
        tokenCount: Int? = nil,
        conversationAt: String? = nil,
        conversationId: String? = nil,
        conversationTitle: String? = nil,
        chunkIndex: Int? = nil,
        role: String? = nil,
        model: String? = nil,
        tags: [String] = [],
        topics: [String] = [],
        entities: [String] = []
    ) {
        self.salience = salience
        self.sourceCount = sourceCount
        self.sourceEpisodeId = sourceEpisodeId
        self.lastUsed = lastUsed
        self.useCount = useCount
        self.status = status
        self.createdAt = createdAt
        self.tokenCount = tokenCount
        self.conversationAt = conversationAt
        self.conversationId = conversationId
        self.conversationTitle = conversationTitle
        self.chunkIndex = chunkIndex
        self.role = role
        self.model = model
        self.tags = tags
        self.topics = topics
        self.entities = entities
    }
}

public struct MemoryConsoleItem: Identifiable, Equatable, Sendable {
    public var id: String
    public var kind: MemoryConsoleItemKind
    public var storageId: String
    public var agentId: String
    public var title: String
    public var preview: MemoryRedactionResult
    public var detail: MemoryRedactionResult
    public var relevanceExplanation: String
    public var metadata: MemoryConsoleMetadata
    public var canDisable: Bool
    public var canForget: Bool

    public init(
        id: String,
        kind: MemoryConsoleItemKind,
        storageId: String,
        agentId: String,
        title: String,
        preview: MemoryRedactionResult,
        detail: MemoryRedactionResult,
        relevanceExplanation: String,
        metadata: MemoryConsoleMetadata,
        canDisable: Bool,
        canForget: Bool = true
    ) {
        self.id = id
        self.kind = kind
        self.storageId = storageId
        self.agentId = agentId
        self.title = title
        self.preview = preview
        self.detail = detail
        self.relevanceExplanation = relevanceExplanation
        self.metadata = metadata
        self.canDisable = canDisable
        self.canForget = canForget
    }

    public var isDisabled: Bool {
        metadata.status == "disabled" || metadata.status == "evicted"
    }
}

public struct MemoryConsoleSnapshot: Sendable {
    public var query: MemoryConsoleQuery
    public var items: [MemoryConsoleItem]
    public var health: MemoryStorageHealth
    public var generatedAt: Date

    public init(
        query: MemoryConsoleQuery,
        items: [MemoryConsoleItem],
        health: MemoryStorageHealth,
        generatedAt: Date = Date()
    ) {
        self.query = query
        self.items = items
        self.health = health
        self.generatedAt = generatedAt
    }
}

public enum MemoryConsoleMutation: String, Sendable {
    case disable
    case forget
}

public struct MemoryConsoleMutationResult: Equatable, Sendable {
    public var itemId: String
    public var mutation: MemoryConsoleMutation
    public var changed: Bool
    public var message: String

    public init(
        itemId: String,
        mutation: MemoryConsoleMutation,
        changed: Bool,
        message: String
    ) {
        self.itemId = itemId
        self.mutation = mutation
        self.changed = changed
        self.message = message
    }
}

public struct MemoryStorageHealth: Sendable {
    public enum Level: String, Sendable {
        case healthy
        case degraded
        case unavailable

        public var displayName: String {
            switch self {
            case .healthy: return L("Healthy")
            case .degraded: return L("Needs attention")
            case .unavailable: return L("Unavailable")
            }
        }
    }

    public var level: Level
    public var databaseOpen: Bool
    public var schemaVersion: Int?
    public var expectedSchemaVersion: Int
    public var databaseSizeBytes: Int64
    public var activePinnedCount: Int
    public var disabledPinnedCount: Int
    public var activeEpisodeCount: Int
    public var disabledEpisodeCount: Int
    public var transcriptCount: Int
    public var pendingSignals: PendingSignalsSummary
    public var processingStats: ProcessingStats
    public var ftsTablesReady: Bool
    public var vectorSearchAvailable: Bool
    public var vectorIndexFailures: Int
    public var lastOpenError: String?
    public var diagnostics: [String]

    public init(
        level: Level,
        databaseOpen: Bool,
        schemaVersion: Int?,
        expectedSchemaVersion: Int,
        databaseSizeBytes: Int64,
        activePinnedCount: Int,
        disabledPinnedCount: Int,
        activeEpisodeCount: Int,
        disabledEpisodeCount: Int,
        transcriptCount: Int,
        pendingSignals: PendingSignalsSummary,
        processingStats: ProcessingStats,
        ftsTablesReady: Bool,
        vectorSearchAvailable: Bool,
        vectorIndexFailures: Int,
        lastOpenError: String?,
        diagnostics: [String]
    ) {
        self.level = level
        self.databaseOpen = databaseOpen
        self.schemaVersion = schemaVersion
        self.expectedSchemaVersion = expectedSchemaVersion
        self.databaseSizeBytes = databaseSizeBytes
        self.activePinnedCount = activePinnedCount
        self.disabledPinnedCount = disabledPinnedCount
        self.activeEpisodeCount = activeEpisodeCount
        self.disabledEpisodeCount = disabledEpisodeCount
        self.transcriptCount = transcriptCount
        self.pendingSignals = pendingSignals
        self.processingStats = processingStats
        self.ftsTablesReady = ftsTablesReady
        self.vectorSearchAvailable = vectorSearchAvailable
        self.vectorIndexFailures = vectorIndexFailures
        self.lastOpenError = lastOpenError
        self.diagnostics = diagnostics
    }
}

public struct MemoryContextPreview: Equatable, Sendable {
    public var agentId: String
    public var query: String
    public var maxTokens: Int
    public var estimatedTokens: Int
    public var redactedContext: MemoryRedactionResult
    public var wasEmpty: Bool

    public init(
        agentId: String,
        query: String,
        maxTokens: Int,
        estimatedTokens: Int,
        redactedContext: MemoryRedactionResult,
        wasEmpty: Bool
    ) {
        self.agentId = agentId
        self.query = query
        self.maxTokens = maxTokens
        self.estimatedTokens = estimatedTokens
        self.redactedContext = redactedContext
        self.wasEmpty = wasEmpty
    }
}
