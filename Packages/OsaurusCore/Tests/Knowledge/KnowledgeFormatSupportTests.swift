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
