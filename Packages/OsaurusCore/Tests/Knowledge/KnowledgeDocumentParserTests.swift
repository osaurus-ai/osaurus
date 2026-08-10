//
//  KnowledgeDocumentParserTests.swift
//  osaurusTests
//
//  Frontmatter extraction + heading-aware chunking tests for knowledge
//  documents (OKF reserved fields, tag normalization, fence handling).
//

import Foundation
import Testing

@testable import OsaurusCore

struct KnowledgeDocumentParserTests {

    // MARK: - Frontmatter

    @Test
    func parsesOKFReservedFields() {
        let markdown = """
            ---
            type: runbook
            title: Deploy Checklist
            description: Steps for a production deploy
            tags: [deploy, ops]
            ---
            # Body

            Content here.
            """
        let (frontmatter, body) = KnowledgeDocumentParser.parse(markdown: markdown)
        #expect(frontmatter.docType == "runbook")
        #expect(frontmatter.title == "Deploy Checklist")
        #expect(frontmatter.summary == "Steps for a production deploy")
        #expect(frontmatter.tags == ["deploy", "ops"])
        #expect(body.contains("Content here."))
        #expect(!body.contains("type: runbook"))
    }

    @Test
    func normalizesCommaStringTags() {
        let markdown = """
            ---
            type: guide
            tags: WordPress, PHP , wordpress
            ---
            body
            """
        let (frontmatter, _) = KnowledgeDocumentParser.parse(markdown: markdown)
        // Lowercased, trimmed, deduplicated.
        #expect(frontmatter.tags == ["wordpress", "php"])
    }

    @Test
    func documentWithoutFrontmatterYieldsEmptyFacets() {
        let markdown = "# Just a Title\n\nPlain document."
        let (frontmatter, body) = KnowledgeDocumentParser.parse(markdown: markdown)
        #expect(frontmatter.docType.isEmpty)
        #expect(frontmatter.tags.isEmpty)
        #expect(body.contains("Plain document."))
    }

    @Test
    func titleResolutionPrefersFrontmatterThenHeadingThenFilename() {
        let fm = KnowledgeFrontmatter(title: "From Frontmatter")
        #expect(
            KnowledgeDocumentParser.resolveTitle(frontmatter: fm, body: "# Heading", relPath: "a/b.md")
                == "From Frontmatter"
        )
        #expect(
            KnowledgeDocumentParser.resolveTitle(
                frontmatter: KnowledgeFrontmatter(),
                body: "intro\n# First Heading\ntext",
                relPath: "a/b.md"
            ) == "First Heading"
        )
        #expect(
            KnowledgeDocumentParser.resolveTitle(
                frontmatter: KnowledgeFrontmatter(),
                body: "no headings",
                relPath: "guides/setup-notes.md"
            ) == "setup-notes"
        )
    }

    // MARK: - Chunking

    @Test
    func chunksCarryHeadingBreadcrumbs() {
        let body = """
            Intro paragraph.

            # Setup

            Setup text.

            ## Testing

            Testing text.
            """
        let chunks = KnowledgeDocumentParser.chunk(body: body)
        #expect(chunks.count == 3)
        #expect(chunks[0].headingPath == "")
        #expect(chunks[0].content == "Intro paragraph.")
        #expect(chunks[1].headingPath == "Setup")
        #expect(chunks[2].headingPath == "Setup > Testing")
        #expect(chunks[2].content == "Testing text.")
    }

    @Test
    func headingLevelResetsDeeperLevels() {
        let body = """
            # A
            a
            ## A1
            a1
            # B
            b
            ## B1
            b1
            """
        let chunks = KnowledgeDocumentParser.chunk(body: body)
        let paths = chunks.map(\.headingPath)
        #expect(paths == ["A", "A > A1", "B", "B > B1"])
    }

    @Test
    func hashInsideCodeFenceIsNotAHeading() {
        let body = """
            # Real

            ```bash
            # not a heading, a comment
            echo hi
            ```

            tail text
            """
        let chunks = KnowledgeDocumentParser.chunk(body: body)
        #expect(chunks.count == 1)
        #expect(chunks[0].headingPath == "Real")
        #expect(chunks[0].content.contains("# not a heading"))
    }

    @Test
    func hashtagWithoutSpaceIsNotAHeading() {
        let body = "# Real\n\n#hashtag text stays put"
        let chunks = KnowledgeDocumentParser.chunk(body: body)
        #expect(chunks.count == 1)
        #expect(chunks[0].content.contains("#hashtag"))
    }

    @Test
    func oversizedSectionSplitsAtParagraphBoundaries() {
        let paragraph = String(repeating: "word ", count: 200).trimmingCharacters(in: .whitespaces)
        let body = "# Big\n\n" + Array(repeating: paragraph, count: 5).joined(separator: "\n\n")
        let chunks = KnowledgeDocumentParser.chunk(body: body)
        #expect(chunks.count > 1)
        #expect(chunks.allSatisfy { $0.headingPath == "Big" })
        #expect(chunks.allSatisfy { $0.content.count <= KnowledgeDocumentParser.maxChunkChars })
    }

    @Test
    func giantSingleParagraphHardWraps() {
        let body = String(repeating: "x", count: 3 * KnowledgeDocumentParser.maxChunkChars)
        let chunks = KnowledgeDocumentParser.chunk(body: body)
        #expect(chunks.count >= 3)
        #expect(chunks.allSatisfy { $0.content.count <= KnowledgeDocumentParser.maxChunkChars })
    }
}
