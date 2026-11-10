//
//  StreamingMarkdownParserTests.swift
//  osaurusTests
//
//  Pin that the incremental streaming parse matches a full parse of every
//  streamed prefix.

import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct StreamingMarkdownParserTests {

    static let fixtures: [String] = [
        "# Title\n\nSome **bold** text and `code`.\n\nAnother paragraph with *italic*\nand a second line.\n\n## Sub\n\nEnd.",
        "Intro\n\n- a\n- b\n\n- c after blank\n  continued\n\n1. one\n2. two\n\n   3. three nested\n\nAfter list\n\n* x\n\nDone",
        "Text\n\n```swift\nlet a = 1\n\nlet b = 2\n```\n\nAfter\n\n````md\n```\ninner\n```\n````\n\n```\nbare fence\n\n# not heading\n```\n\nTail",
        "Table:\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n| 3 | 4 |\n\nAfter table\n\n| solo | row |\n\nText\n\n| h |\n\n\n| r |\n\nEnd",
        "> quote one\n> quote two\n\n> second\n\nText\n> attached quote\n\nEnd",
        "Euler:\n\n$$\ne^{i\\pi} + 1 = 0\n$$\n\nInline $x$ here.\n\n\\[\n\\frac{a}{b}\n\\]\n\n$$\n\\alpha unclosed\n\nmore text\n\n$$\n\nEnd",
        "Lead\n\n$$\n\\alpha\n```\n$$\n\nAfter\n\n```\ncode\n```\n\nEnd",
        "![alt](http://x/y.png)\n\n---\n\nText\n\n***\n\nMore\n\n![second](http://x/z.png)\n\nLast",
        "a\r\n\r\nb\r\n\r\n- c\r\n\r\nd",
        "héllo 🌍\n\n- ünï\n\n日本語\n\n```\n🙂\n```\n\nend",
        "\n\nleading blanks\n\n\n\nmany blanks\n\n- item\n\n\n\n- item after gap\n\ntext",
        "```\nfence closes\n```\n\nright after\n\n```py\nopen at end\n\nstill code",
    ]

    @Test
    func everyStreamedPrefixMatchesFullParse() {
        for fixture in Self.fixtures {
            var parser = StreamingMarkdownParser()
            var prefix = ""
            for character in fixture {
                prefix.append(character)
                expectMatchesFullParse(parser.parse(prefix), prefix)
            }
        }
    }

    @Test
    func chunkedStreamsMatchFullParse() {
        for (seed, fixture) in Self.fixtures.enumerated() {
            var parser = StreamingMarkdownParser()
            var rng = SplitMix(seed: UInt64(seed + 1))
            let characters = Array(fixture)
            var end = 0
            while end < characters.count {
                end = min(characters.count, end + Int(rng.next() % 12) + 1)
                let prefix = String(characters[..<end])
                expectMatchesFullParse(parser.parse(prefix), prefix)
            }
        }
    }

    @Test
    func finishedBlocksAreReusedWhileStreaming() {
        var parser = StreamingMarkdownParser()
        let text = (1 ... 40).map { "Paragraph \($0) with **bold** text." }.joined(separator: "\n\n")
        var prefix = ""
        for character in text {
            prefix.append(character)
            _ = parser.parse(prefix)
        }
        #expect(parser.reusedBlockCount >= 38)
    }

    @Test
    func rewrittenTextFallsBackToFullParse() {
        var parser = StreamingMarkdownParser()
        let first = Self.fixtures[0]
        _ = parser.parse(first)
        let rewritten = "# Other\n\nCompletely different body.\n\n- list"
        expectMatchesFullParse(parser.parse(rewritten), rewritten)
        #expect(parser.reusedBlockCount == 0)
        let truncated = String(first.prefix(10))
        expectMatchesFullParse(parser.parse(truncated), truncated)
    }

    @Test
    func resumePointFollowsFinishedBlocks() {
        let result = parseBlocksWithResumePoint("a\n\nb\n\nc\n")
        #expect(result.resume == MarkdownResumePoint(utf8Offset: 3, lineEndUTF8Offset: 5, blockCount: 1))
    }

    @Test
    func unclosedMathBlocksLaterResumePoints() {
        let result = parseBlocksWithResumePoint("a\n\n$$\n\\alpha\n\nb\n\nc\n")
        #expect(result.resume?.utf8Offset == 3)
    }

    private func expectMatchesFullParse(
        _ blocks: [MessageBlock],
        _ text: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let expected = parseBlocks(StreamingMarkdownBalancer.balance(text))
        #expect(blocks.map(\.index) == expected.map(\.index), "\(text.debugDescription)", sourceLocation: sourceLocation)
        #expect(blocks.map(\.kind) == expected.map(\.kind), "\(text.debugDescription)", sourceLocation: sourceLocation)
    }
}

private struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
