//
//  KnowledgeGlobTests.swift
//  osaurusTests
//
//  Include/exclude glob matching for per-collection index filtering.
//

import Foundation
import Testing

@testable import OsaurusCore

struct KnowledgeGlobTests {

    // MARK: - Single-pattern semantics

    @Test func singleStarStaysWithinASegment() {
        #expect(KnowledgeGlob.matchesPattern("README.md", pattern: "*.md"))
        #expect(!KnowledgeGlob.matchesPattern("docs/README.md", pattern: "*.md"))
    }

    @Test func doubleStarCrossesDirectories() {
        #expect(KnowledgeGlob.matchesPattern("docs/a/b/x.md", pattern: "docs/**"))
        #expect(KnowledgeGlob.matchesPattern("docs/x.md", pattern: "docs/**"))
        #expect(!KnowledgeGlob.matchesPattern("src/x.ts", pattern: "docs/**"))
    }

    @Test func leadingDoubleStarSlashMatchesAtAnyDepthIncludingRoot() {
        #expect(KnowledgeGlob.matchesPattern("x.md", pattern: "**/*.md"))
        #expect(KnowledgeGlob.matchesPattern("docs/deep/x.md", pattern: "**/*.md"))
        #expect(!KnowledgeGlob.matchesPattern("docs/x.ts", pattern: "**/*.md"))
    }

    @Test func questionMatchesOneNonSlashChar() {
        #expect(KnowledgeGlob.matchesPattern("a.md", pattern: "?.md"))
        #expect(!KnowledgeGlob.matchesPattern("ab.md", pattern: "?.md"))
    }

    @Test func dotIsLiteralNotRegexWildcard() {
        #expect(!KnowledgeGlob.matchesPattern("axmd", pattern: "*.md"))
    }

    @Test func leadingSlashAndDotSlashAreNormalizedAway() {
        #expect(KnowledgeGlob.matchesPattern("/docs/x.md", pattern: "docs/**"))
        #expect(KnowledgeGlob.matchesPattern("docs/x.md", pattern: "./docs/**"))
    }

    // MARK: - Include/exclude resolution (the gbrain shape)

    @Test func emptyGlobsIncludeEverything() {
        #expect(KnowledgeGlob.matches("src/core/config.ts", include: [], exclude: []))
    }

    @Test func includeRestrictsToDocs() {
        let include = ["docs/**", "*.md"]
        #expect(KnowledgeGlob.matches("docs/ENGINES.md", include: include, exclude: []))
        #expect(KnowledgeGlob.matches("README.md", include: include, exclude: []))
        #expect(!KnowledgeGlob.matches("src/core/config.ts", include: include, exclude: []))
        #expect(!KnowledgeGlob.matches("test/config-env.test.ts", include: include, exclude: []))
    }

    @Test func excludeWinsOverInclude() {
        #expect(
            !KnowledgeGlob.matches(
                "docs/generated/api.md",
                include: ["docs/**"],
                exclude: ["docs/generated/**"]
            )
        )
        #expect(
            KnowledgeGlob.matches(
                "docs/guide.md",
                include: ["docs/**"],
                exclude: ["docs/generated/**"]
            )
        )
    }

    @Test func excludeOnlyDropsCode() {
        let exclude = ["src/**", "test/**"]
        #expect(!KnowledgeGlob.matches("src/core/config.ts", include: [], exclude: exclude))
        #expect(KnowledgeGlob.matches("docs/ENGINES.md", include: [], exclude: exclude))
    }
}
