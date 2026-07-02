//
//  KnowledgeModels.swift
//  osaurus
//
//  Row types for the derived knowledge index (knowledge.sqlite).
//  The markdown files in each collection folder are the source of
//  truth; these rows are rebuildable artifacts of indexing.
//

import Foundation

/// An indexed markdown document inside a knowledge collection.
public struct KnowledgeDocument: Sendable, Equatable {
    /// SQLite row id.
    public var id: Int
    /// Owning collection id (UUID string).
    public var collectionId: String
    /// Path relative to the collection folder, e.g. `wordpress/plugins.md`.
    public var relPath: String
    /// Display title: frontmatter `title` when present, else the first
    /// `# heading`, else the filename stem.
    public var title: String
    /// OKF `type` frontmatter field ("" when absent).
    public var docType: String
    /// OKF `description` frontmatter field ("" when absent).
    public var summary: String
    /// OKF `tags` frontmatter field, normalized to lowercase CSV.
    public var tagsCSV: String
    /// SHA-256 of the file contents at index time, for incremental skip.
    public var contentHash: String
    public var sizeBytes: Int
    /// File modification date (ISO8601) at index time.
    public var modifiedAt: String
    public var indexedAt: String

    public init(
        id: Int,
        collectionId: String,
        relPath: String,
        title: String,
        docType: String,
        summary: String,
        tagsCSV: String,
        contentHash: String,
        sizeBytes: Int,
        modifiedAt: String,
        indexedAt: String
    ) {
        self.id = id
        self.collectionId = collectionId
        self.relPath = relPath
        self.title = title
        self.docType = docType
        self.summary = summary
        self.tagsCSV = tagsCSV
        self.contentHash = contentHash
        self.sizeBytes = sizeBytes
        self.modifiedAt = modifiedAt
        self.indexedAt = indexedAt
    }

    public var tags: [String] {
        tagsCSV.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
    }
}

/// A heading-aware chunk of a document, joined with the owning
/// document's identity so search hits can be presented without a
/// second lookup.
public struct KnowledgeChunkHit: Sendable, Equatable {
    public var documentId: Int
    public var chunkIndex: Int
    /// Breadcrumb of headings above the chunk, e.g. `Setup > Testing`.
    public var headingPath: String
    public var content: String
    public var collectionId: String
    public var relPath: String
    public var title: String
    public var docType: String
    public var tagsCSV: String

    public init(
        documentId: Int,
        chunkIndex: Int,
        headingPath: String,
        content: String,
        collectionId: String,
        relPath: String,
        title: String,
        docType: String,
        tagsCSV: String
    ) {
        self.documentId = documentId
        self.chunkIndex = chunkIndex
        self.headingPath = headingPath
        self.content = content
        self.collectionId = collectionId
        self.relPath = relPath
        self.title = title
        self.docType = docType
        self.tagsCSV = tagsCSV
    }

    /// Stable composite key for vector-index identity.
    public var compositeKey: String {
        "\(collectionId):\(relPath):\(chunkIndex)"
    }
}
