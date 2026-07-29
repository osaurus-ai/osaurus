//
//  KnowledgeFormatSupportTests.swift
//  OsaurusCoreTests — Knowledge
//
//  Format routing for knowledge collections: markdown parses in place,
//  everything else must reach a registered document adapter, and the
//  curation write path stays markdown-only so a text proposal can never
//  land on a binary source of truth.
//

import Foundation
import Testing

@testable import OsaurusCore

struct KnowledgeFormatSupportTests {

    @Test func markdownDetectionCoversAllMarkdownExtensions() {
        for ext in ["md", "markdown", "mdx", "MD"] {
            #expect(KnowledgeIndexService.isMarkdown(URL(fileURLWithPath: "/tmp/doc.\(ext)")))
        }
        for ext in ["pdf", "docx", "swift", "txt"] {
            #expect(!KnowledgeIndexService.isMarkdown(URL(fileURLWithPath: "/tmp/doc.\(ext)")))
        }
    }

    /// The indexer's non-markdown path depends on the built-in adapters
    /// claiming these formats by extension. If an adapter stops claiming
    /// one, that format silently drops out of every knowledge index.
    @Test func builtInAdaptersClaimTheKnowledgeFormats() {
        let registry = DocumentFormatRegistry()
        DocumentAdaptersBootstrap.registerBuiltIns(registry: registry)
        for ext in ["txt", "swift", "py", "json", "pdf", "docx", "xlsx", "pptx", "csv"] {
            let url = URL(fileURLWithPath: "/tmp/sample.\(ext)")
            #expect(registry.adapter(for: url) != nil, "no adapter claims .\(ext)")
        }
    }

    @Test func curationErrorExplainsNonMarkdownRefusal() {
        let error = KnowledgeCurationError.nonMarkdownTarget("specs/pricing.pdf")
        #expect(error.errorDescription?.contains("pricing.pdf") == true)
        #expect(error.errorDescription?.contains("markdown") == true)
    }
}

/// End-to-end guard: an approved proposal must never overwrite a binary
/// source of truth. Runs against the shared singletons scoped into a
/// temporary `OsaurusPaths.overrideRoot`, so it is serialized and bails
/// out if another suite already opened the shared database at the real
/// path (approving there would touch real user state).
@Suite(.serialized)
struct KnowledgeCurationApprovalGuardTests {

    @MainActor
    @Test func approvingProposalAgainstPDFThrowsAndLeavesFileIntact() async throws {
        guard !KnowledgeDatabase.shared.isOpen else {
            Issue.record("Shared knowledge database already open outside override root; skipping")
            return
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("knowledge-format-guard-\(UUID().uuidString)", isDirectory: true)
        let previousRoot = OsaurusPaths.overrideRoot
        OsaurusPaths.overrideRoot = root
        defer {
            // Close so the shared database doesn't stay bound to the
            // deleted temp root for whatever runs after this suite.
            KnowledgeDatabase.shared.close()
            OsaurusPaths.overrideRoot = previousRoot
            KnowledgeManager.shared.reload()
            try? FileManager.default.removeItem(at: root)
        }

        // A collection whose folder holds a fake pdf.
        let folder = root.appendingPathComponent("corpus", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let pdfBytes = Data("%PDF-1.4 not really a pdf".utf8)
        let pdfURL = folder.appendingPathComponent("pricing.pdf")
        try pdfBytes.write(to: pdfURL)

        let collection = KnowledgeCollection(
            name: "Guard Corpus", summary: "", folderPath: folder.path)
        KnowledgeCollectionStore.save(collection)
        KnowledgeManager.shared.reload()

        try KnowledgeDatabase.shared.open()
        let proposalId = try KnowledgeDatabase.shared.createProposal(
            ticketId: nil,
            collectionId: collection.id.uuidString,
            relPath: "pricing.pdf",
            newContent: "# text that must never land in a pdf",
            rationale: "stale pricing",
            createdBy: "curator-test"
        )

        await #expect(throws: KnowledgeCurationError.self) {
            try await KnowledgeCurationService.shared.approve(proposalId: proposalId)
        }
        #expect(try Data(contentsOf: pdfURL) == pdfBytes)
        #expect(try KnowledgeDatabase.shared.getProposal(id: proposalId)?.status == .pending)
    }
}
