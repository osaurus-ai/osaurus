//
//  PalaceModels.swift
//  osaurus
//
//  DTOs for the Palace verbatim-memory subsystem (wings → rooms → drawers).
//  Verbatim contract: `PalaceDrawer.content` is stored exactly as provided —
//  no summarization, trimming, or rewriting on the write path.
//

import Foundation

public struct PalaceWing: Sendable, Equatable {
    public let id: String
    public let name: String
    public let displayName: String?
    public let kind: String  // project | person | agent | system
    public let agentId: String?
    public let createdAt: String
    public let updatedAt: String

    public init(
        id: String = UUID().uuidString,
        name: String,
        displayName: String? = nil,
        kind: String = "project",
        agentId: String? = nil,
        createdAt: String,
        updatedAt: String
    ) {
        self.id = id
        self.name = name
        self.displayName = displayName
        self.kind = kind
        self.agentId = agentId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct PalaceRoom: Sendable, Equatable {
    public let id: String
    public let wingId: String
    public let name: String

    public init(id: String = UUID().uuidString, wingId: String, name: String) {
        self.id = id
        self.wingId = wingId
        self.name = name
    }
}

public struct PalaceDrawer: Sendable, Equatable {
    public let id: String
    public let wingId: String
    public let roomId: String
    public let content: String
    public let blobRef: String?
    public let sourceFile: String?
    public let sourceLineStart: Int?
    public let sourceLineEnd: Int?
    public let addedBy: String
    public let contentHash: String
    public let charOffset: Int?
    public let createdAt: String
    public let metadataJSON: String?

    public init(
        id: String = UUID().uuidString,
        wingId: String,
        roomId: String,
        content: String,
        blobRef: String? = nil,
        sourceFile: String? = nil,
        sourceLineStart: Int? = nil,
        sourceLineEnd: Int? = nil,
        addedBy: String = "system",
        contentHash: String,
        charOffset: Int? = nil,
        createdAt: String,
        metadataJSON: String? = nil
    ) {
        self.id = id
        self.wingId = wingId
        self.roomId = roomId
        self.content = content
        self.blobRef = blobRef
        self.sourceFile = sourceFile
        self.sourceLineStart = sourceLineStart
        self.sourceLineEnd = sourceLineEnd
        self.addedBy = addedBy
        self.contentHash = contentHash
        self.charOffset = charOffset
        self.createdAt = createdAt
        self.metadataJSON = metadataJSON
    }
}

/// One search result. `score` semantics depend on `matchType`:
/// vector → cosine similarity in [-1, 1] (higher is better);
/// fts → bm25 rank negated so higher is better.
public struct PalaceSearchHit: Sendable {
    public enum MatchType: String, Sendable {
        case vector
        case fts
    }

    public let drawer: PalaceDrawer
    public let wingName: String
    public let roomName: String
    public let score: Double
    public let matchType: MatchType

    public init(
        drawer: PalaceDrawer,
        wingName: String,
        roomName: String,
        score: Double,
        matchType: MatchType
    ) {
        self.drawer = drawer
        self.wingName = wingName
        self.roomName = roomName
        self.score = score
        self.matchType = matchType
    }
}

public struct PalaceStatus: Sendable, Equatable {
    public let wingCount: Int
    public let roomCount: Int
    public let drawerCount: Int
    public let embeddedDrawerCount: Int
    public let embeddingBackend: String
    public let enabled: Bool

    public init(
        wingCount: Int,
        roomCount: Int,
        drawerCount: Int,
        embeddedDrawerCount: Int,
        embeddingBackend: String,
        enabled: Bool
    ) {
        self.wingCount = wingCount
        self.roomCount = roomCount
        self.drawerCount = drawerCount
        self.embeddedDrawerCount = embeddedDrawerCount
        self.embeddingBackend = embeddingBackend
        self.enabled = enabled
    }
}
