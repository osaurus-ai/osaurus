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
    /// Category the indexer inferred when frontmatter has no `type`
    /// (e.g. from the containing folder name); "" when nothing could be
    /// inferred. Never written to the user's files.
    public var inferredType: String
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
        inferredType: String = "",
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
        self.inferredType = inferredType
        self.summary = summary
        self.tagsCSV = tagsCSV
        self.contentHash = contentHash
        self.sizeBytes = sizeBytes
        self.modifiedAt = modifiedAt
        self.indexedAt = indexedAt
    }

    /// The category agents filter by: explicit frontmatter `type` when
    /// present, else the inferred one, else "".
    public var effectiveType: String {
        docType.isEmpty ? inferredType : docType
    }

    /// True when the effective type came from inference rather than
    /// explicit frontmatter.
    public var isTypeInferred: Bool {
        docType.isEmpty && !inferredType.isEmpty
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

// MARK: - Curation (Phase 2)

/// Lifecycle of a staleness ticket. Agents open tickets via
/// `flag_knowledge_stale`; a curator moves them to `proposed` with
/// `propose_knowledge_update`; human review resolves or dismisses.
public enum KnowledgeTicketStatus: String, Sendable, CaseIterable {
    case open
    case inProgress = "in_progress"
    case proposed
    case resolved
    case dismissed
}

/// A staleness/drift report against one knowledge document. Tickets are
/// annotations — creating one never mutates the corpus.
public struct KnowledgeTicket: Sendable, Equatable, Identifiable {
    public var id: Int
    public var collectionId: String
    public var relPath: String
    public var reason: String
    public var evidence: String
    public var status: KnowledgeTicketStatus
    /// Agent id (UUID string) that opened the ticket; "" when unknown.
    public var createdBy: String
    public var createdAt: String
    public var updatedAt: String

    public init(
        id: Int,
        collectionId: String,
        relPath: String,
        reason: String,
        evidence: String,
        status: KnowledgeTicketStatus,
        createdBy: String,
        createdAt: String,
        updatedAt: String
    ) {
        self.id = id
        self.collectionId = collectionId
        self.relPath = relPath
        self.reason = reason
        self.evidence = evidence
        self.status = status
        self.createdBy = createdBy
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum KnowledgeProposalStatus: String, Sendable, CaseIterable {
    case pending
    case approved
    case dismissed
}

/// A curator-drafted replacement for one document. Proposals hold the
/// full new content and never touch the collection folder until a human
/// approves them in the Knowledge tab.
public struct KnowledgeProposal: Sendable, Equatable, Identifiable {
    public var id: Int
    /// Ticket this proposal answers, if it was ticket-driven.
    public var ticketId: Int?
    public var collectionId: String
    public var relPath: String
    public var newContent: String
    public var rationale: String
    public var status: KnowledgeProposalStatus
    /// Agent id (UUID string) that drafted the proposal; "" when unknown.
    public var createdBy: String
    public var createdAt: String
    public var updatedAt: String

    public init(
        id: Int,
        ticketId: Int?,
        collectionId: String,
        relPath: String,
        newContent: String,
        rationale: String,
        status: KnowledgeProposalStatus,
        createdBy: String,
        createdAt: String,
        updatedAt: String
    ) {
        self.id = id
        self.ticketId = ticketId
        self.collectionId = collectionId
        self.relPath = relPath
        self.newContent = newContent
        self.rationale = rationale
        self.status = status
        self.createdBy = createdBy
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - Write log

/// What a logged knowledge mutation did to the document at `relPath`.
public enum KnowledgeWriteOperation: String, Sendable, Equatable, CaseIterable {
    /// The document did not exist before this write.
    case create
    /// The document existed and its content was replaced.
    case replace
    /// The document existed and was removed.
    case delete
}

/// One durable record of an agent-made change to a collection folder.
///
/// Reversibility is what makes call-time approval safe: a reviewer cannot
/// realistically catch fabricated reference material by skimming a diff, but
/// anyone can revert once `search_knowledge` starts returning nonsense. That
/// only works if the record outlives the chat that produced it, so this lives
/// in the knowledge database rather than in an in-memory per-session log like
/// `FileOperationLog`.
///
/// `priorContent` is the whole previous document, not a diff: reverting must
/// not depend on the current file still being what the agent left behind.
public struct KnowledgeWriteRecord: Sendable, Equatable, Identifiable {
    public var id: Int
    public var collectionId: String
    public var relPath: String
    public var operation: KnowledgeWriteOperation
    /// Previous document content. Empty for `.create`, which reverts by
    /// deleting the file.
    public var priorContent: String
    /// SHA-256 of `priorContent`, or "" when there was no prior document.
    public var priorContentHash: String
    /// SHA-256 of what this write left on disk, or "" for a delete. A revert
    /// compares the file against this to notice that someone changed the
    /// document afterwards, so undoing an agent cannot silently discard a
    /// human's later edit. Uniform across all three operations, which is why
    /// it is recorded separately rather than inferred from `operation`.
    public var resultContentHash: String
    /// Groups every write from one agent run so a bad bulk import can be
    /// reverted as a unit. This is the revert that matters in practice.
    public var runId: String
    /// Agent id (UUID string) that made the change; "" when unknown.
    public var createdBy: String
    /// Short reason supplied by the calling agent.
    public var rationale: String
    public var createdAt: String
    /// Set when this write has been reverted, so history stays readable
    /// instead of the row disappearing.
    public var revertedAt: String?

    public var isReverted: Bool { revertedAt != nil }

    public init(
        id: Int,
        collectionId: String,
        relPath: String,
        operation: KnowledgeWriteOperation,
        priorContent: String,
        priorContentHash: String,
        resultContentHash: String,
        runId: String,
        createdBy: String,
        rationale: String,
        createdAt: String,
        revertedAt: String? = nil
    ) {
        self.id = id
        self.collectionId = collectionId
        self.relPath = relPath
        self.operation = operation
        self.priorContent = priorContent
        self.priorContentHash = priorContentHash
        self.resultContentHash = resultContentHash
        self.runId = runId
        self.createdBy = createdBy
        self.rationale = rationale
        self.createdAt = createdAt
        self.revertedAt = revertedAt
    }
}
