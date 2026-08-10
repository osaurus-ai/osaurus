//
//  KnowledgeSyncAndDiffTests.swift
//  osaurusTests
//
//  Phase 3 + curation-gap coverage: the review-sheet line diff, the
//  collection-delete purge of curation rows, the pending-proposal
//  count, and validation for the curator ticket claim tool.
//

import Foundation
import Testing

@testable import OsaurusCore

// MARK: - Line diff

struct KnowledgeDiffTests {

    @Test
    func identicalContentIsAllContext() {
        let text = "a\nb\nc"
        let lines = KnowledgeDiff.lines(old: text, new: text)
        #expect(lines.allSatisfy { $0.kind == .context })
        #expect(lines.map(\.text) == ["a", "b", "c"])
    }

    @Test
    func detectsAddedAndRemovedLines() {
        let old = "intro\nkeep\nold line\ntail"
        let new = "intro\nkeep\nnew line\ntail"
        let lines = KnowledgeDiff.lines(old: old, new: new)
        #expect(lines.filter { $0.kind == .removed }.map(\.text) == ["old line"])
        #expect(lines.filter { $0.kind == .added }.map(\.text) == ["new line"])
        #expect(lines.filter { $0.kind == .context }.map(\.text) == ["intro", "keep", "tail"])
    }

    @Test
    func newDocumentDiffsAgainstEmpty() {
        let lines = KnowledgeDiff.lines(old: "", new: "one\ntwo")
        // The empty old side contributes its single empty line; every
        // proposed line must surface as added.
        #expect(lines.filter { $0.kind == .added }.map(\.text) == ["one", "two"])
        #expect(lines.filter { $0.kind == .context }.isEmpty)
    }

    @Test
    func oversizedInputFallsBackToReplaceBlocks() {
        let old = (0 ..< 2000).map { "old \($0)" }.joined(separator: "\n")
        let new = (0 ..< 2000).map { "new \($0)" }.joined(separator: "\n")
        let lines = KnowledgeDiff.lines(old: old, new: new)
        #expect(lines.filter { $0.kind == .removed }.count == 2000)
        #expect(lines.filter { $0.kind == .added }.count == 2000)
        #expect(lines.filter { $0.kind == .context }.isEmpty)
    }

    @Test
    func commonPrefixAndSuffixStayContext() {
        let old = "same1\nsame2\nchange me\nsame3"
        let new = "same1\nsame2\nchanged\nsame3"
        let lines = KnowledgeDiff.lines(old: old, new: new)
        #expect(lines.first?.kind == .context)
        #expect(lines.last?.kind == .context)
    }
}

// MARK: - Database purge + counts

struct KnowledgeCurationPurgeTests {

    private func makeDBOrSkip() -> KnowledgeDatabase? {
        let db = KnowledgeDatabase()
        do {
            try db.openInMemory()
            return db
        } catch {
            Issue.record("Could not open in-memory knowledge database: \(error)")
            return nil
        }
    }

    @Test
    func deleteCollectionPurgesTicketsAndProposals() throws {
        guard let db = makeDBOrSkip() else { return }
        _ = try db.createTicket(
            collectionId: "c1", relPath: "a.md", reason: "stale", evidence: "", createdBy: ""
        )
        _ = try db.createProposal(
            ticketId: nil, collectionId: "c1", relPath: "a.md",
            newContent: "x", rationale: "r", createdBy: ""
        )
        let keepTicket = try db.createTicket(
            collectionId: "keep", relPath: "b.md", reason: "stale", evidence: "", createdBy: ""
        )

        try db.deleteCollection(collectionId: "c1")

        #expect(try db.listTickets(collectionIds: ["c1"], status: nil).isEmpty)
        #expect(try db.listProposals(status: nil).allSatisfy { $0.collectionId != "c1" })
        // Other collections keep their trail.
        #expect(try db.getTicket(id: keepTicket) != nil)
    }

    @Test
    func pendingProposalCountTracksStatus() throws {
        guard let db = makeDBOrSkip() else { return }
        #expect(try db.pendingProposalCount() == 0)
        let first = try db.createProposal(
            ticketId: nil, collectionId: "c1", relPath: "a.md",
            newContent: "x", rationale: "r", createdBy: ""
        )
        _ = try db.createProposal(
            ticketId: nil, collectionId: "c1", relPath: "b.md",
            newContent: "y", rationale: "r", createdBy: ""
        )
        #expect(try db.pendingProposalCount() == 2)
        try db.updateProposalStatus(id: first, status: .dismissed)
        #expect(try db.pendingProposalCount() == 1)
    }
}

// MARK: - Ticket claim tool validation

@Suite(.serialized)
struct UpdateKnowledgeTicketToolTests {

    @Test
    func rejectsMissingTicketId() async throws {
        let tool = UpdateKnowledgeTicketTool()
        let result = try await tool.execute(argumentsJSON: #"{"status":"in_progress"}"#)
        #expect(ToolEnvelope.isError(result))
        #expect(result.contains("ticket_id"))
    }

    @Test
    func rejectsDisallowedStatus() async throws {
        let tool = UpdateKnowledgeTicketTool()
        // `resolved` belongs to the review flow, not the agent surface.
        let result = try await tool.execute(
            argumentsJSON: #"{"ticket_id":1,"status":"resolved"}"#
        )
        #expect(ToolEnvelope.isError(result))
        #expect(result.contains("status"))
    }

    @Test
    func rejectsWithoutAgentContext() async throws {
        let tool = UpdateKnowledgeTicketTool()
        let result = try await tool.execute(
            argumentsJSON: #"{"ticket_id":1,"status":"in_progress"}"#
        )
        #expect(ToolEnvelope.isError(result))
        #expect(result.contains("agent"))
    }

    @Test
    func curatorToolsStayOffTheExternalAllowList() {
        // propose remains externally denied; the claim tool is
        // curator-gated at execution time and harmless externally, so it
        // is deliberately NOT on the deny list.
        #expect(ToolRegistry.externallyDeniedToolNames.contains("propose_knowledge_update"))
        #expect(!ToolRegistry.externallyDeniedToolNames.contains("update_knowledge_ticket"))
    }
}
