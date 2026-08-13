//
//  KnowledgeIgnoreRulesTests.swift
//  osaurusTests
//
//  Gitignore-style ignore matching: built-in junk defaults + parsing.
//

import Foundation
import Testing

@testable import OsaurusCore

struct KnowledgeIgnoreRulesTests {

    // MARK: - Built-in defaults (junk only, code preserved)

    @Test func defaultsIgnoreLockfilesAndMinifiedAndMaps() {
        let d = KnowledgeIgnoreRules.defaults
        #expect(d.isIgnored("bun.lock"))
        #expect(d.isIgnored("package-lock.json"))
        #expect(d.isIgnored("deep/nested/yarn.lock"))
        #expect(d.isIgnored("app.min.js"))
        #expect(d.isIgnored("styles/app.min.css"))
        #expect(d.isIgnored("dist/bundle.js.map"))
    }

    @Test func defaultsIgnoreMediaAndArchives() {
        let d = KnowledgeIgnoreRules.defaults
        #expect(d.isIgnored("assets/logo.png"))
        #expect(d.isIgnored("docs/diagram.svg"))
        #expect(d.isIgnored("release.tar.gz"))
        #expect(d.isIgnored("core.wasm"))
    }

    @Test func defaultsKeepDocsAndSourceCode() {
        let d = KnowledgeIgnoreRules.defaults
        #expect(!d.isIgnored("docs/ENGINES.md"))
        #expect(!d.isIgnored("README.md"))
        #expect(!d.isIgnored("src/core/config.ts"))
        #expect(!d.isIgnored("test/config-env.test.ts"))
    }

    // MARK: - Parsing semantics

    @Test func nameOnlyRuleMatchesAtAnyDepthAndDirContents() {
        let r = KnowledgeIgnoreRules.parse("build")
        #expect(r.isIgnored("build"))
        #expect(r.isIgnored("build/output.txt"))
        #expect(r.isIgnored("packages/x/build/output.txt"))
        #expect(!r.isIgnored("rebuild.md"))
    }

    @Test func leadingSlashAnchorsToRoot() {
        let r = KnowledgeIgnoreRules.parse("/build")
        #expect(r.isIgnored("build/out.js"))
        #expect(!r.isIgnored("packages/x/build/out.js"))
    }

    @Test func trailingSlashMatchesDirectoryContentsOnly() {
        let r = KnowledgeIgnoreRules.parse("generated/")
        #expect(r.isIgnored("generated/api.md"))
        #expect(r.isIgnored("docs/generated/api.md"))
    }

    @Test func negationReincludes() {
        let r = KnowledgeIgnoreRules.parse(
            """
            *.md
            !KEEP.md
            """
        )
        #expect(r.isIgnored("notes.md"))
        #expect(!r.isIgnored("KEEP.md"))
    }

    @Test func commentsAndBlankLinesIgnored() {
        let r = KnowledgeIgnoreRules.parse(
            """
            # a comment

            *.tmp
            """
        )
        #expect(r.isIgnored("scratch.tmp"))
        #expect(!r.isIgnored("scratch.md"))
    }

    @Test func emptyRulesIgnoreNothing() {
        let r = KnowledgeIgnoreRules.parse("")
        #expect(r.isEmpty)
        #expect(!r.isIgnored("anything.ts"))
    }
}
