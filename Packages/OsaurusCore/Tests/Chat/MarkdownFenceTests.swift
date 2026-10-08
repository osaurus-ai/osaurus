//
//  MarkdownFenceTests.swift
//  OsaurusCoreTests
//
//  CommonMark fenced code blocks (#3027) and literal rendering of every fence (#3026), across the shared
//  parser, the streaming balancer, the chat segment grouping and the agent-channel formatters.
//

import Foundation
import Testing

@testable import OsaurusCore

struct MarkdownFenceTests {
    private func codeBlocks(_ text: String) -> [(code: String, lang: String?)] {
        parseBlocks(text).compactMap {
            if case .code(let code, let lang) = $0.kind { return (code, lang) }
            return nil
        }
    }

    // MARK: parser (#3027)

    @Test func threeBacktickFenceIsUnchanged() {
        let blocks = codeBlocks("Intro\n```swift\nlet x = 1\n```\nAfter")
        #expect(blocks.count == 1)
        #expect(blocks.first?.code == "let x = 1")
        #expect(blocks.first?.lang == "swift")
    }

    @Test func fourBacktickInfoStringHasNoStrayBacktick() {
        let blocks = codeBlocks("````markdown\n# Hello\n````")
        #expect(blocks.first?.lang == "markdown")
        #expect(blocks.first?.code == "# Hello")
    }

    @Test func fourBacktickFenceKeepsNestedThreeBacktickLines() {
        let text = "````markdown\n# Readme\n```swift\nprint(1)\n```\nEnd of readme\n````\nAfter the block"
        let blocks = parseBlocks(text)
        let codes = blocks.compactMap { block -> (String, String?)? in
            if case .code(let c, let l) = block.kind { return (c, l) }
            return nil
        }
        #expect(codes.count == 1)
        #expect(codes.first?.0 == "# Readme\n```swift\nprint(1)\n```\nEnd of readme")
        #expect(codes.first?.1 == "markdown")
        // Only the text after the real closing fence is prose.
        #expect(blocks.contains { if case .paragraph(let p) = $0.kind { return p == "After the block" } else { return false } })
    }

    @Test func shorterOrDecoratedRunDoesNotCloseALongerFence() {
        let blocks = codeBlocks("````\n``` not a closer\n```\nstill code\n````")
        #expect(blocks.count == 1)
        #expect(blocks.first?.code == "``` not a closer\n```\nstill code")
    }

    @Test func closingFenceMayBeLongerButNotCarryAnInfoString() {
        #expect(codeBlocks("```\na\n`````\n").first?.code == "a")
        let blocks = codeBlocks("```\na\n```python\nb\n```")
        #expect(blocks.first?.code == "a\n```python\nb")
    }

    @Test func tildeFencesAreFences() {
        let blocks = codeBlocks("~~~python\nprint(\"~~\")\n```\n~~~")
        #expect(blocks.count == 1)
        #expect(blocks.first?.lang == "python")
        #expect(blocks.first?.code == "print(\"~~\")\n```")
    }

    @Test func backtickInfoStringContainingBacktickIsInlineCodeNotAFence() {
        #expect(codeBlocks("```inline``` and more text").isEmpty)
    }

    @Test func unclosedFenceRunsToTheEnd() {
        #expect(codeBlocks("````\nline 1\n```\nline 3").first?.code == "line 1\n```\nline 3")
    }

    @Test func indentedFenceInsideAListStillParses() {
        #expect(codeBlocks("- item\n    ```bash\n    ls\n    ```").first?.lang == "bash")
    }

    // MARK: rendering (#3026)

    @Test func everyFenceRendersAsACodeBlockWhateverItsInfoString() {
        for lang in ["markdown", "md", "text", "plain", "plaintext", "poem", "poetry", "verse", "prose", "output",
                     "ascii", "chat", "letter", ""] {
            let fence = "```\(lang)\n# Title\n\n**bold** and [link](https://example.com)\n- item\n```"
            let segments = groupBlocksIntoSegments(parseBlocks(fence))
            #expect(segments.count == 1, "lang=\(lang)")
            guard case .codeBlock(let code, let language) = segments.first?.kind else {
                Issue.record("lang=\(lang) rendered as prose")
                continue
            }
            #expect(code.hasPrefix("# Title"))
            #expect(language == (lang.isEmpty ? nil : lang))
        }
    }

    @Test func fourBacktickMarkdownFenceRendersAsOneCodeBlock() {
        let segments = groupBlocksIntoSegments(parseBlocks("````markdown\n# R\n```js\nx()\n```\n````"))
        #expect(segments.count == 1)
        guard case .codeBlock(let code, let language) = segments.first?.kind else {
            Issue.record("expected a code block")
            return
        }
        #expect(language == "markdown")
        #expect(code == "# R\n```js\nx()\n```")
    }

    // MARK: streaming balancer

    @Test func balancerLeavesAnOpenLongFenceAlone() {
        let streaming = "Here:\n````markdown\n# Title **bold\n```swift\nlet"
        #expect(StreamingMarkdownBalancer.balance(streaming) == streaming)
    }

    @Test func balancerOnlyRebalancesTextAfterTheLastClosedFence() {
        let text = "````\n```\n**not touched\n````\nNow **bold"
        let balanced = StreamingMarkdownBalancer.balance(text)
        #expect(balanced.hasPrefix("````\n```\n**not touched\n````\n"))
        #expect(balanced != text)  // the trailing open emphasis after the fence is balanced
    }

    @Test func balancerIgnoresInlineTripleBackticks() {
        let text = "Use ```inline``` like this and **bold"
        #expect(StreamingMarkdownBalancer.balance(text) != text)  // still balances the paragraph
    }

    // MARK: agent channels

    @Test func slackAndDiscordFencesCannotBeClosedByInnerFenceLines() {
        let neutral = neutralizingInnerFences("# R\n```js\nx()\n  ```\nend")
        #expect(!neutral.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("```") })
        #expect(neutral.replacingOccurrences(of: "\u{200B}", with: "") == "# R\n```js\nx()\n  ```\nend")
        #expect(neutralizingInnerFences("no fences") == "no fences")
    }
}
