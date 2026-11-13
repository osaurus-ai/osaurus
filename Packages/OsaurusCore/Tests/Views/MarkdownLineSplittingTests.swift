//
//  MarkdownLineSplittingTests.swift
//  osaurusTests
//
//  Pin line splitting in `parseBlocks` after switching LineIterator to a
//  UTF-8 byte scan (APPLE-MACOS-3N5: per-Character iteration hung the main
//  thread on large reasoning text).
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct MarkdownLineSplittingTests {

    @Test
    func splitsLinesWithMultiByteAndCombiningCharacters() {
        let body = "h\u{00E9}llo \u{1F600}\ne\u{0301}\n\n\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        let blocks = parseBlocks("```\n" + body + "\n```")
        #expect(blocks.count == 1)
        #expect(blocks.first?.kind == .code(body, nil))
    }

    @Test
    func crlfInputSplitsLikeLF() {
        let blocks = parseBlocks("```\r\na\r\nb\r\n```")
        #expect(blocks.count == 1)
        #expect(blocks.first?.kind == .code("a\nb", nil))
    }

    @Test
    func trailingNewlineAndEmptyInput() {
        #expect(parseBlocks("").isEmpty)
        let blocks = parseBlocks("first\nsecond\n")
        #expect(blocks.count == 1)
        #expect(blocks.first?.kind == .paragraph("first\nsecond"))
    }

    @Test
    func largeInputParsesQuickly() {
        let line = "Reasoning step with some text, unicode \u{00E9}\u{1F600}, and more words.\n"
        let input = String(repeating: line, count: 7_000)  // ~500KB
        let start = Date()
        let blocks = parseBlocks(input)
        let elapsed = Date().timeIntervalSince(start)
        #expect(!blocks.isEmpty)
        #expect(elapsed < 2.0)
    }
}
