//
//  KnowledgeCurationService.swift
//  osaurus
//
//  Applies human review decisions to knowledge proposals. This is the
//  ONLY code path that writes into a collection folder: approval takes
//  a pending proposal, writes its content atomically (confined to the
//  collection folder), re-indexes, and resolves the linked ticket.
//  Agents can flag and propose; only the user's approval lands changes.
//

import Foundation

public enum KnowledgeCurationError: Error, LocalizedError {
    case proposalNotFound(Int)
    case proposalNotPending(Int)
    case collectionUnavailable(String)
    case pathEscapesCollection(String)
    case nonMarkdownTarget(String)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .proposalNotFound(let id): return "Proposal #\(id) was not found."
        case .proposalNotPending(let id): return "Proposal #\(id) is no longer pending."
        case .collectionUnavailable(let name):
            return "Collection \(name) is unavailable (deleted, disabled, or its folder is missing)."
        case .pathEscapesCollection(let path):
            return "Proposal path \(path) resolves outside the collection folder."
        case .nonMarkdownTarget(let path):
            return "Proposal path \(path) is not a markdown document; only markdown can be updated through curation."
        case .writeFailed(let msg): return "Could not write the document: \(msg)"
        }
    }
}

public actor KnowledgeCurationService {
    public static let shared = KnowledgeCurationService()

    private init() {}

    /// Approve a pending proposal: write the new content into the
    /// collection folder, re-index the collection incrementally, resolve
    /// the linked ticket, and mark the proposal approved.
    /// `overrideContent` carries user edits made in the review sheet —
    /// the reviewer's version wins over the curator's draft.
    public func approve(proposalId: Int, overrideContent: String? = nil) async throws {
        guard let proposal = try KnowledgeDatabase.shared.getProposal(id: proposalId) else {
            throw KnowledgeCurationError.proposalNotFound(proposalId)
        }
        guard proposal.status == .pending else {
            throw KnowledgeCurationError.proposalNotPending(proposalId)
        }

        guard let collectionUUID = UUID(uuidString: proposal.collectionId),
            let collection = await MainActor.run(body: {
                KnowledgeManager.shared.collection(for: collectionUUID)
            }),
            collection.isEnabled, collection.folderExists
        else {
            throw KnowledgeCurationError.collectionUnavailable(proposal.collectionId)
        }

        // Confinement: same contract as the tools, re-checked here since
        // this is the code that actually writes.
        let relPath = proposal.relPath
        guard !relPath.isEmpty, !relPath.hasPrefix("/"), !relPath.hasPrefix("~"),
            !relPath.components(separatedBy: "/").contains("..")
        else {
            throw KnowledgeCurationError.pathEscapesCollection(relPath)
        }
        let folderURL = collection.folderURL.standardizedFileURL
        let fileURL = folderURL.appendingPathComponent(relPath).standardizedFileURL
        let folderPrefix = folderURL.path.hasSuffix("/") ? folderURL.path : folderURL.path + "/"
        guard fileURL.path.hasPrefix(folderPrefix) else {
            throw KnowledgeCurationError.pathEscapesCollection(relPath)
        }
        // Curation writes plain text; landing it on an adapter-extracted
        // format (pdf, docx, …) would destroy the binary source of truth.
        guard KnowledgeIndexService.isMarkdown(fileURL) else {
            throw KnowledgeCurationError.nonMarkdownTarget(relPath)
        }

        let content = overrideContent ?? proposal.newContent
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(content.utf8).write(to: fileURL, options: [.atomic])
        } catch {
            throw KnowledgeCurationError.writeFailed(error.localizedDescription)
        }

        try KnowledgeDatabase.shared.updateProposalStatus(id: proposalId, status: .approved)
        if let ticketId = proposal.ticketId {
            try? KnowledgeDatabase.shared.updateTicketStatus(id: ticketId, status: .resolved)
        }

        // Announce the user-visible state change NOW — before the (potentially
        // slow) re-index and git commit/push — so the Knowledge tab drops the
        // approved proposal immediately instead of lingering until those finish.
        Self.postCurationChanged()

        // Incremental pass picks up exactly the changed file (hash skip
        // covers the rest). The folder watcher would get there too; doing
        // it here makes the approval immediately searchable.
        await KnowledgeIndexService.shared.indexCollection(collection)

        // Git-backed collections: record the approval as a commit and
        // push best-effort. The approval itself already succeeded (file
        // written + indexed), so git trouble is logged, never thrown —
        // the user can run Sync later to reconcile.
        if collection.isGitRepository {
            let commitOutcome = await KnowledgeGitSyncService.shared.commitDocument(
                in: collection,
                relPath: relPath,
                message: "update \(relPath) via knowledge curation"
            )
            switch commitOutcome {
            case .updated:
                let pushOutcome = await KnowledgeGitSyncService.shared.push(collection)
                if case .updated = pushOutcome {
                    KnowledgeLogger.index.info(
                        "Pushed approved proposal #\(proposalId) for \(collection.name, privacy: .public)"
                    )
                } else if case .upToDate = pushOutcome {
                    // No remote configured; local commit is enough.
                } else {
                    KnowledgeLogger.index.warning(
                        "Approval committed but push needs attention: \(pushOutcome.message, privacy: .public)"
                    )
                }
            case .upToDate:
                break
            case .needsAttention, .failed:
                KnowledgeLogger.index.warning(
                    "Approval applied but git commit failed: \(commitOutcome.message, privacy: .public)"
                )
            }
        }

        KnowledgeLogger.index.info(
            "Approved knowledge proposal #\(proposalId) into \(collection.name, privacy: .public)/\(relPath, privacy: .public)"
        )
        Self.postCurationChanged()
    }

    /// Dismiss a pending proposal. If it was the only proposal answering
    /// its ticket, the ticket reopens so the drift report isn't lost.
    public func dismissProposal(proposalId: Int) async throws {
        guard let proposal = try KnowledgeDatabase.shared.getProposal(id: proposalId) else {
            throw KnowledgeCurationError.proposalNotFound(proposalId)
        }
        guard proposal.status == .pending else {
            throw KnowledgeCurationError.proposalNotPending(proposalId)
        }
        try KnowledgeDatabase.shared.updateProposalStatus(id: proposalId, status: .dismissed)
        if let ticketId = proposal.ticketId,
            let ticket = try? KnowledgeDatabase.shared.getTicket(id: ticketId),
            ticket.status == .proposed
        {
            try? KnowledgeDatabase.shared.updateTicketStatus(id: ticketId, status: .open)
        }
        Self.postCurationChanged()
    }

    /// Dismiss a ticket without action (false positive, wontfix).
    public func dismissTicket(ticketId: Int) async throws {
        try KnowledgeDatabase.shared.updateTicketStatus(id: ticketId, status: .dismissed)
        Self.postCurationChanged()
    }

    private static func postCurationChanged() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .knowledgeCurationChanged, object: nil)
        }
    }
}
