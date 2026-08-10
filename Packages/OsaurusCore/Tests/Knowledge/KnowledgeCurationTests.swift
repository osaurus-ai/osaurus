//
//  KnowledgeCurationTests.swift
//  osaurusTests
//
//  Phase 2 curation coverage: ticket/proposal round-trips in the
//  database, status transitions, and argument/scoping validation for
//  the curation tools (which must refuse without agent context and
//  reject unconfined paths).
//

import Foundation
import Testing

@testable import OsaurusCore

// MARK: - Database round-trips

struct KnowledgeCurationDatabaseTests {

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
    func ticketRoundTripAndStatusTransitions() throws {
        guard let db = makeDBOrSkip() else { return }
        let id = try db.createTicket(
            collectionId: "c1",
            relPath: "wp.md",
            reason: "WordPress 8.0 changed plugin architecture",
            evidence: "release notes",
            createdBy: "agent-1"
        )
        let ticket = try db.getTicket(id: id)
        #expect(ticket?.status == .open)
        #expect(ticket?.reason == "WordPress 8.0 changed plugin architecture")
        #expect(ticket?.createdBy == "agent-1")

        // Open-ticket lookup drives flag dedupe.
        #expect(try db.openTicket(collectionId: "c1", relPath: "wp.md")?.id == id)
        #expect(try db.openTicket(collectionId: "c1", relPath: "other.md") == nil)
        #expect(try db.openTicket(collectionId: "c2", relPath: "wp.md") == nil)

        try db.updateTicketStatus(id: id, status: .proposed)
        #expect(try db.getTicket(id: id)?.status == .proposed)
        // A proposed ticket no longer matches the open-ticket dedupe.
        #expect(try db.openTicket(collectionId: "c1", relPath: "wp.md") == nil)
    }

    @Test
    func listTicketsScopesAndFilters() throws {
        guard let db = makeDBOrSkip() else { return }
        _ = try db.createTicket(collectionId: "granted", relPath: "a.md", reason: "r1", evidence: "", createdBy: "")
        let other = try db.createTicket(
            collectionId: "other", relPath: "b.md", reason: "r2", evidence: "", createdBy: ""
        )
        try db.updateTicketStatus(id: other, status: .dismissed)

        // Scoped listing never crosses collections.
        let scoped = try db.listTickets(collectionIds: ["granted"], status: .open)
        #expect(scoped.map(\.relPath) == ["a.md"])

        // Empty scope (a scoped caller with no grants) returns nothing.
        #expect(try db.listTickets(collectionIds: [], status: .open).isEmpty)

        // nil scope is the unscoped UI listing.
        #expect(try db.listTickets(collectionIds: nil, status: .dismissed).map(\.id) == [other])
    }

    @Test
    func proposalRoundTripAndStatusTransitions() throws {
        guard let db = makeDBOrSkip() else { return }
        let ticketId = try db.createTicket(
            collectionId: "c1", relPath: "wp.md", reason: "stale", evidence: "", createdBy: ""
        )
        let id = try db.createProposal(
            ticketId: ticketId,
            collectionId: "c1",
            relPath: "wp.md",
            newContent: "# Updated\n\nnew content",
            rationale: "brings the doc to WordPress 8.0",
            createdBy: "curator-1"
        )
        let proposal = try db.getProposal(id: id)
        #expect(proposal?.status == .pending)
        #expect(proposal?.ticketId == ticketId)
        #expect(proposal?.newContent.contains("new content") == true)

        #expect(try db.listProposals(status: .pending).map(\.id) == [id])
        try db.updateProposalStatus(id: id, status: .approved)
        #expect(try db.listProposals(status: .pending).isEmpty)
        #expect(try db.getProposal(id: id)?.status == .approved)
    }

    @Test
    func proposalWithoutTicketHasNilTicketId() throws {
        guard let db = makeDBOrSkip() else { return }
        let id = try db.createProposal(
            ticketId: nil,
            collectionId: "c1",
            relPath: "new-doc.md",
            newContent: "content",
            rationale: "missing doc",
            createdBy: ""
        )
        #expect(try db.getProposal(id: id)?.ticketId == nil)
    }

    /// C2: dismissing the sole proposal reopens its ticket. This covers the
    /// state machine `KnowledgeCurationService.dismissProposal` drives — a
    /// ticket that went `open → proposed` when a proposal was drafted must be
    /// able to return to `open` (and re-match the flag-dedupe lookup) so the
    /// drift report isn't lost when the reviewer rejects the fix.
    @Test
    func dismissedProposalReopensItsTicket() throws {
        guard let db = makeDBOrSkip() else { return }
        let ticketId = try db.createTicket(
            collectionId: "c1", relPath: "wp.md", reason: "stale", evidence: "", createdBy: ""
        )
        let proposalId = try db.createProposal(
            ticketId: ticketId,
            collectionId: "c1",
            relPath: "wp.md",
            newContent: "# Updated",
            rationale: "fix",
            createdBy: "curator-1"
        )
        // Proposing moves the ticket out of the open-dedupe pool.
        try db.updateTicketStatus(id: ticketId, status: .proposed)
        #expect(try db.openTicket(collectionId: "c1", relPath: "wp.md") == nil)

        // Dismiss + reopen (the service only reopens a still-`proposed` ticket).
        try db.updateProposalStatus(id: proposalId, status: .dismissed)
        #expect(try db.getTicket(id: ticketId)?.status == .proposed)
        try db.updateTicketStatus(id: ticketId, status: .open)

        // Reopened: visible to the UI and to flag dedupe again.
        #expect(try db.getTicket(id: ticketId)?.status == .open)
        #expect(try db.openTicket(collectionId: "c1", relPath: "wp.md")?.id == ticketId)
        #expect(try db.getProposal(id: proposalId)?.status == .dismissed)
    }
}

// MARK: - Tool validation

@Suite(.serialized)
struct KnowledgeCurationToolsTests {

    @Test
    func flagRejectsMissingArguments() async throws {
        let tool = FlagKnowledgeStaleTool()
        let noPath = try await tool.execute(argumentsJSON: #"{"reason":"stale"}"#)
        #expect(ToolEnvelope.isError(noPath))
        #expect(noPath.contains("path"))

        let noReason = try await tool.execute(argumentsJSON: #"{"path":"a.md"}"#)
        #expect(ToolEnvelope.isError(noReason))
        #expect(noReason.contains("reason"))
    }

    @Test
    func flagRejectsPathTraversal() async throws {
        let tool = FlagKnowledgeStaleTool()
        let result = try await tool.execute(
            argumentsJSON: #"{"path":"../outside.md","reason":"stale"}"#
        )
        #expect(ToolEnvelope.isError(result))
        #expect(result.contains("path"))
    }

    @Test
    func flagWithoutAgentContextIsRejected() async throws {
        let tool = FlagKnowledgeStaleTool()
        let result = try await tool.execute(
            argumentsJSON: #"{"path":"a.md","reason":"stale"}"#
        )
        #expect(ToolEnvelope.isError(result))
        #expect(result.contains("agent"))
    }

    @Test
    func listTicketsRejectsUnknownStatus() async throws {
        let tool = ListKnowledgeTicketsTool()
        // Status validation happens after scope resolution, so without an
        // agent context the scope failure fires first; assert the rejected
        // envelope rather than the status message.
        let result = try await tool.execute(argumentsJSON: #"{"status":"open"}"#)
        #expect(ToolEnvelope.isError(result))
    }

    @Test
    func proposeRejectsNonMarkdownAndTraversalPaths() async throws {
        let tool = ProposeKnowledgeUpdateTool()
        let traversal = try await tool.execute(
            argumentsJSON: #"{"path":"../x.md","new_content":"c","rationale":"r"}"#
        )
        #expect(ToolEnvelope.isError(traversal))

        let notMarkdown = try await tool.execute(
            argumentsJSON: #"{"path":"script.sh","new_content":"c","rationale":"r"}"#
        )
        #expect(ToolEnvelope.isError(notMarkdown))
        #expect(notMarkdown.contains(".md"))
    }

    @Test
    func proposeRejectsEmptyContent() async throws {
        let tool = ProposeKnowledgeUpdateTool()
        let result = try await tool.execute(
            argumentsJSON: #"{"path":"a.md","new_content":"   ","rationale":"r"}"#
        )
        #expect(ToolEnvelope.isError(result))
        #expect(result.contains("new_content"))
    }

    @Test
    func proposeWithoutAgentContextIsRejected() async throws {
        let tool = ProposeKnowledgeUpdateTool()
        let result = try await tool.execute(
            argumentsJSON: #"{"path":"a.md","new_content":"content","rationale":"r"}"#
        )
        #expect(ToolEnvelope.isError(result))
        #expect(result.contains("agent"))
    }

    /// A spawned subagent keeps `currentAgentId` inherited from its launcher
    /// (budget/limiter accounting), but its knowledge tools must resolve grants
    /// and the curator role against the TARGET agent — otherwise a spawned
    /// helper silently inherits its launcher's collection grants. The override
    /// wins when set; otherwise resolution falls back to the running identity.
    @Test
    func knowledgeAgentIdPrefersSubagentOverride() {
        let launcher = UUID()
        let target = UUID()
        ChatExecutionContext.$currentAgentId.withValue(launcher) {
            #expect(ChatExecutionContext.knowledgeAgentId == launcher)
            ChatExecutionContext.$knowledgeGrantAgentIdOverride.withValue(target) {
                #expect(ChatExecutionContext.knowledgeAgentId == target)
            }
            // Override cleared → back to the running identity.
            #expect(ChatExecutionContext.knowledgeAgentId == launcher)
        }
    }

    @Test
    func proposeIsDeniedOnExternalSurfaces() {
        #expect(ToolRegistry.externallyDeniedToolNames.contains("propose_knowledge_update"))
        // The annotation tools stay allowed externally.
        #expect(!ToolRegistry.externallyDeniedToolNames.contains("flag_knowledge_stale"))
        #expect(!ToolRegistry.externallyDeniedToolNames.contains("list_knowledge_tickets"))
    }

    /// A curator that read the document first receives it wrapped in
    /// `read_knowledge`'s `[Collection] path` + `title:/type:/tags:` framing.
    /// Weaker models copy that header verbatim into their replacement content;
    /// `strippingReadPreamble` removes a leaked block so an approval never
    /// persists it above the real body.
    @Test
    func strippingReadPreambleRemovesLeakedHeaderOnly() {
        // Full leaked framing (header + metadata + blank) is dropped; the
        // real body (and any real frontmatter below it) survives.
        let leaked =
            "[Sample Knowledge] deploy-runbook.md\n"
            + "title: Production Deploy Runbook\n"
            + "type: guide\n"
            + "tags: engineering,ops,deploy\n"
            + "\n"
            + "# Production Deploy Runbook\n\nBody."
        #expect(
            ProposeKnowledgeUpdateTool.strippingReadPreamble(leaked)
                == "# Production Deploy Runbook\n\nBody."
        )

        // Header with no metadata lines, just the bracket line + blank.
        #expect(
            ProposeKnowledgeUpdateTool.strippingReadPreamble("[Coll] path.md\n\nBody.") == "Body."
        )

        // Normal markdown is untouched.
        let plain = "# Title\n\nSome text."
        #expect(ProposeKnowledgeUpdateTool.strippingReadPreamble(plain) == plain)

        // A document that legitimately opens with frontmatter is untouched
        // (first non-blank line is `---`, not `[name] …`).
        let withFrontmatter = "---\ntype: guide\n---\n\n# Title"
        #expect(ProposeKnowledgeUpdateTool.strippingReadPreamble(withFrontmatter) == withFrontmatter)

        // A markdown reference definition (`[id]: url`) is NOT a framing header
        // (`]:` not `] `), so it survives.
        let refDef = "[docs]: https://example.com\n\nSee the docs."
        #expect(ProposeKnowledgeUpdateTool.strippingReadPreamble(refDef) == refDef)
    }
}
