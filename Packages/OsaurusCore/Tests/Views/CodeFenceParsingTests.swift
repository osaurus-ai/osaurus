//
//  CodeFenceParsingTests.swift
//  osaurusTests
//
//  Pin CommonMark fence rules in `parseBlocks` and the streaming balancer.
//
//  The reported defect: the parser assumed exactly three backticks, so a
//  four-backtick fence put a stray backtick in the language label and closed
//  at the first nested three-backtick line, spilling the rest into prose.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct CodeFenceParsingTests {

    @Test
    func fourBacktickFenceOpensAndCloses() {
        let blocks = parseBlocks("````markdown\n# Hello\n````")
        #expect(blocks.count == 1)
        #expect(blocks.first?.kind == .code("# Hello", "markdown"))
    }

    @Test
    func nestedShorterFenceStaysInsideLongerFence() {
        let source = "````markdown\n# Nested example\n\n```\ninner fence\n```\n````"
        let blocks = parseBlocks(source)
        #expect(blocks.count == 1)
        #expect(blocks.first?.kind == .code("# Nested example\n\n```\ninner fence\n```", "markdown"))
    }

    @Test
    func fenceLineWithTrailingTextDoesNotClose() {
        let blocks = parseBlocks("```\na\n```swift\nb\n```")
        #expect(blocks.count == 1)
        #expect(blocks.first?.kind == .code("a\n```swift\nb", nil))
    }

    @Test
    func longerClosingFenceCloses() {
        let blocks = parseBlocks("```py\nx = 1\n`````\nafter")
        #expect(blocks.count == 2)
        #expect(blocks.first?.kind == .code("x = 1", "py"))
        #expect(blocks.last?.kind == .paragraph("after"))
    }

    @Test
    func tildeFencesWorkAndIgnoreBackticks() {
        let blocks = parseBlocks("~~~sh\necho hi\n```\n~~~")
        #expect(blocks.count == 1)
        #expect(blocks.first?.kind == .code("echo hi\n```", "sh"))
    }

    @Test
    func unclosedFenceRunsToEnd() {
        let blocks = parseBlocks("````\nstill streaming\n```")
        #expect(blocks.count == 1)
        #expect(blocks.first?.kind == .code("still streaming\n```", nil))
    }

    @Test
    func inlineTripleBackticksAreNotAFence() {
        let blocks = parseBlocks("```a``` b")
        #expect(blocks.first?.kind == .paragraph("```a``` b"))
    }

    @Test
    func indentedFenceContentLosesTheOpenerIndent() {
        let blocks = parseBlocks("  ```\n  let x = 1\n  ```")
        #expect(blocks.count == 1)
        #expect(blocks.first?.kind == .code("let x = 1", nil))
    }

    // MARK: - Streaming balancer

    /// Mid-stream between a nested inner pair, the old split on "```" flipped
    /// parity and rebalanced code as prose.
    @Test
    func balancerLeavesNestedFenceContentAlone() {
        let text = "````markdown\n```\nsome *code"
        #expect(StreamingMarkdownBalancer.balance(text) == text)
    }

    @Test
    func balancerOnlyTouchesProseAfterAClosedLongFence() {
        let fenced = "````\n```\n*x\n```\n````\n"
        let balanced = StreamingMarkdownBalancer.balance(fenced + "some **bold")
        #expect(balanced.hasPrefix(fenced))
    }
}
