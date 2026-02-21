//
//  MemoryModels.swift
//  osaurus
//
//  Data types for the 4-layer memory system.
//

import Foundation

// MARK: - Layer 1: User Profile

public struct UserProfile: Codable, Sendable {
    public var content: String
    public var tokenCount: Int
    public var version: Int
    public var model: String
    public var generatedAt: String

    public init(content: String, tokenCount: Int, version: Int = 1, model: String, generatedAt: String) {
        self.content = content
        self.tokenCount = tokenCount
        self.version = version
        self.model = model
        self.generatedAt = generatedAt
    }
}

public struct ProfileEvent: Codable, Sendable, Identifiable {
    public var id: Int
    public var agentId: String
    public var conversationId: String?
    public var eventType: String
    public var content: String
    public var model: String?
    public var status: String
    public var incorporatedIn: Int?
    public var createdAt: String

    public init(
        id: Int = 0, agentId: String, conversationId: String? = nil,
        eventType: String, content: String, model: String? = nil,
        status: String = "active", incorporatedIn: Int? = nil,
        createdAt: String = ""
    ) {
        self.id = id
        self.agentId = agentId
        self.conversationId = conversationId
        self.eventType = eventType
        self.content = content
        self.model = model
        self.status = status
        self.incorporatedIn = incorporatedIn
        self.createdAt = createdAt
    }
}

public struct UserEdit: Codable, Sendable, Identifiable {
    public var id: Int
    public var content: String
    public var createdAt: String
    public var deletedAt: String?

    public init(id: Int = 0, content: String, createdAt: String = "", deletedAt: String? = nil) {
        self.id = id
        self.content = content
        self.createdAt = createdAt
        self.deletedAt = deletedAt
    }
}

// MARK: - Layer 2: Working Memory

public enum MemoryEntryType: String, Codable, Sendable, CaseIterable {
    case fact
    case preference
    case decision
    case correction
    case commitment
    case relationship
    case skill

    public var displayName: String {
        switch self {
        case .fact: return "Fact"
        case .preference: return "Preference"
        case .decision: return "Decision"
        case .correction: return "Correction"
        case .commitment: return "Commitment"
        case .relationship: return "Relationship"
        case .skill: return "Skill"
        }
    }
}

public struct MemoryEntry: Codable, Sendable, Identifiable {
    public var id: String
    public var agentId: String
    public var type: MemoryEntryType
    public var content: String
    public var confidence: Double
    public var model: String
    public var sourceConversationId: String?
    public var tagsJSON: String?
    public var status: String
    public var supersededBy: String?
    public var createdAt: String
    public var lastAccessed: String
    public var accessCount: Int

    public var tags: [String] {
        guard let json = tagsJSON, let data = json.data(using: .utf8),
              let array = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return array
    }

    public init(
        id: String = UUID().uuidString, agentId: String, type: MemoryEntryType,
        content: String, confidence: Double = 0.8, model: String,
        sourceConversationId: String? = nil, tagsJSON: String? = nil,
        status: String = "active", supersededBy: String? = nil,
        createdAt: String = "", lastAccessed: String = "", accessCount: Int = 0
    ) {
        self.id = id
        self.agentId = agentId
        self.type = type
        self.content = content
        self.confidence = confidence
        self.model = model
        self.sourceConversationId = sourceConversationId
        self.tagsJSON = tagsJSON
        self.status = status
        self.supersededBy = supersededBy
        self.createdAt = createdAt
        self.lastAccessed = lastAccessed
        self.accessCount = accessCount
    }
}

// MARK: - Layer 3: Conversation Summaries

public struct ConversationSummary: Codable, Sendable, Identifiable {
    public var id: Int
    public var agentId: String
    public var conversationId: String
    public var summary: String
    public var tokenCount: Int
    public var model: String
    public var conversationAt: String
    public var status: String
    public var createdAt: String

    public init(
        id: Int = 0, agentId: String, conversationId: String,
        summary: String, tokenCount: Int, model: String,
        conversationAt: String, status: String = "active", createdAt: String = ""
    ) {
        self.id = id
        self.agentId = agentId
        self.conversationId = conversationId
        self.summary = summary
        self.tokenCount = tokenCount
        self.model = model
        self.conversationAt = conversationAt
        self.status = status
        self.createdAt = createdAt
    }
}

// MARK: - Layer 4: Conversation Chunks

public struct ConversationChunk: Codable, Sendable, Identifiable {
    public var id: Int
    public var conversationId: String
    public var chunkIndex: Int
    public var role: String
    public var content: String
    public var tokenCount: Int
    public var createdAt: String
    public var agentId: String
    public var conversationTitle: String?

    public init(
        id: Int = 0, conversationId: String, chunkIndex: Int,
        role: String, content: String, tokenCount: Int,
        createdAt: String = "", agentId: String = "",
        conversationTitle: String? = nil
    ) {
        self.id = id
        self.conversationId = conversationId
        self.chunkIndex = chunkIndex
        self.role = role
        self.content = content
        self.tokenCount = tokenCount
        self.createdAt = createdAt
        self.agentId = agentId
        self.conversationTitle = conversationTitle
    }
}

// MARK: - Background Processing

public struct PendingSignal: Codable, Sendable {
    public var id: Int
    public var agentId: String
    public var conversationId: String
    public var signalType: String
    public var userMessage: String
    public var assistantMessage: String?
    public var status: String
    public var createdAt: String

    public init(
        id: Int = 0, agentId: String, conversationId: String,
        signalType: String, userMessage: String, assistantMessage: String? = nil,
        status: String = "pending", createdAt: String = ""
    ) {
        self.id = id
        self.agentId = agentId
        self.conversationId = conversationId
        self.signalType = signalType
        self.userMessage = userMessage
        self.assistantMessage = assistantMessage
        self.status = status
        self.createdAt = createdAt
    }
}

public struct ProcessingStats: Sendable {
    public var totalCalls: Int = 0
    public var avgDurationMs: Int = 0
    public var successCount: Int = 0
    public var errorCount: Int = 0
}

// MARK: - Signal Detection

public enum SignalType: String, Sendable, CaseIterable {
    case explicitMemory
    case correction
    case identity
    case preference
    case decision
    case commitment

    public var memoryEntryType: MemoryEntryType {
        switch self {
        case .explicitMemory: return .fact
        case .correction: return .correction
        case .identity: return .fact
        case .preference: return .preference
        case .decision: return .decision
        case .commitment: return .commitment
        }
    }
}
