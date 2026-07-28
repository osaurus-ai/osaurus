//
//  AgentChannelMessageFormatterTests.swift
//  osaurusTests
//
//  Coverage for the shared native-formatting pipeline: per-provider Markdown
//  rendering, Telegram HTML escaping, and structure-aware chunking.
//

import Foundation
import Testing

@testable import OsaurusCore

struct AgentChannelMessageFormatterTests {

    // MARK: - Slack (markdown_text)

    @Test func slackKeepsStandardMarkdownStructure() {
        let markdown = """
            # Deploy report

            All **checks** passed.

            - build
            - tests

            ```swift
            let ok = true
            ```
            """
        let chunks = AgentChannelMessageFormatter.slackChunks(markdown)
        #expect(chunks.count == 1)
        let output = chunks[0]
        #expect(output.contains("# Deploy report"))
        #expect(output.contains("All **checks** passed."))
        #expect(output.contains("- build"))
        #expect(output.contains("```swift\nlet ok = true\n```"))
    }

    @Test func slackRendersTablesAsFencedPipeRows() {
        let markdown = """
            | Name | Age |
            | --- | --- |
            | Alice | 30 |
            """
        let output = AgentChannelMessageFormatter.slackChunks(markdown)[0]
        #expect(output.hasPrefix("```"))
        #expect(output.contains("| Alice | 30 |"))
        #expect(output.hasSuffix("```"))
    }

    // MARK: - Discord

    @Test func discordClampsDeepHeadingsToBold() {
        let output = AgentChannelMessageFormatter.discordChunks("##### Deep heading")[0]
        #expect(output == "**Deep heading**")
        let shallow = AgentChannelMessageFormatter.discordChunks("## Shallow")[0]
        #expect(shallow == "## Shallow")
    }

    @Test func discordRendersImagesAsMaskedLinks() {
        let output = AgentChannelMessageFormatter.discordChunks("![build chart](https://example.com/c.png)")[0]
        #expect(output == "[build chart](https://example.com/c.png)")
    }

    @Test func discordRendersListsAndQuotes() {
        let markdown = """
            > important note

            1. first
            2. second
            """
        let output = AgentChannelMessageFormatter.discordChunks(markdown)[0]
        #expect(output.contains("> important note"))
        #expect(output.contains("1. first"))
        #expect(output.contains("2. second"))
    }

    // MARK: - Telegram HTML

    @Test func telegramEscapesHTMLEntitiesEverywhere() {
        let output = AgentChannelMessageFormatter.telegramHTML("a < b & c > d")
        #expect(output == "a &lt; b &amp; c &gt; d")
    }

    @Test func telegramConvertsInlineMarkdownToEntities() {
        let output = AgentChannelMessageFormatter.telegramHTML(
            "**bold** and *italic* and `let x = 1 < 2` and ~~gone~~"
        )
        #expect(output.contains("<b>bold</b>"))
        #expect(output.contains("<i>italic</i>"))
        #expect(output.contains("<code>let x = 1 &lt; 2</code>"))
        #expect(output.contains("<s>gone</s>"))
    }

    @Test func telegramConvertsLinksAndRejectsUnsafeSchemes() {
        let safe = AgentChannelMessageFormatter.telegramHTML("[docs](https://example.com/a?b=1&c=2)")
        #expect(safe == "<a href=\"https://example.com/a?b=1&amp;c=2\">docs</a>")
        let unsafe = AgentChannelMessageFormatter.telegramHTML("[x](javascript:alert(1))")
        #expect(!unsafe.contains("<a "))
    }

    @Test func telegramRendersCodeBlocksWithLanguageClass() {
        let markdown = """
            ```swift
            let x = "<tag>"
            ```
            """
        let output = AgentChannelMessageFormatter.telegramHTML(markdown)
        #expect(output == "<pre><code class=\"language-swift\">let x = \"&lt;tag&gt;\"</code></pre>")
    }

    @Test func telegramRendersHeadingsAsBoldAndListsAsBullets() {
        let markdown = """
            ## Status

            - one
            - two
            """
        let output = AgentChannelMessageFormatter.telegramHTML(markdown)
        #expect(output.contains("<b>Status</b>"))
        #expect(output.contains("• one"))
        #expect(output.contains("• two"))
    }

    @Test func telegramRendersBlockquoteTag() {
        let output = AgentChannelMessageFormatter.telegramHTML("> quoted & true")
        #expect(output == "<blockquote>quoted &amp; true</blockquote>")
    }

    @Test func telegramLeavesUnclosedMarkersLiteral() {
        let output = AgentChannelMessageFormatter.telegramHTML("2 * 3 = 6")
        #expect(output == "2 * 3 = 6")
    }

    // MARK: - Chunking

    @Test func packKeepsShortContentInOneChunk() {
        let chunks = AgentChannelMessageFormatter.discordChunks("hello world")
        #expect(chunks == ["hello world"])
    }

    @Test func packSplitsAtBlockBoundariesFirst() {
        let paragraphA = String(repeating: "a", count: 1_500)
        let paragraphB = String(repeating: "b", count: 1_500)
        let chunks = AgentChannelMessageFormatter.discordChunks(paragraphA + "\n\n" + paragraphB)
        #expect(chunks == [paragraphA, paragraphB])
    }

    @Test func packRebalancesCodeFencesAcrossChunks() {
        let longCode = (1 ... 300).map { "print(\($0))" }.joined(separator: "\n")
        let chunks = AgentChannelMessageFormatter.discordChunks("```swift\n\(longCode)\n```")
        #expect(chunks.count > 1)
        for chunk in chunks {
            #expect(chunk.hasPrefix("```swift\n"))
            #expect(chunk.hasSuffix("\n```"))
            #expect(chunk.utf16.count <= AgentChannelMessageFormatter.discordChunkLimit)
        }
    }

    @Test func packNeverSplitsEmojiGraphemes() {
        // Family emoji: 11 UTF-16 units each, indivisible.
        let family = "👨‍👩‍👧‍👦"
        let text = String(repeating: family, count: 400)
        let chunks = AgentChannelMessageFormatter.pack(
            [AgentChannelRenderedBlock(body: text)],
            limit: 100
        )
        #expect(chunks.joined() == text)
        for chunk in chunks {
            #expect(chunk.utf16.count <= 100)
            #expect(chunk.allSatisfy { String($0) == family })
        }
    }

    @Test func telegramChunkingRebalancesPreTags() {
        let longCode = (1 ... 500).map { "row \($0): value" }.joined(separator: "\n")
        let chunks = AgentChannelMessageFormatter.telegramHTMLChunks("```\n\(longCode)\n```")
        #expect(chunks.count > 1)
        for chunk in chunks {
            #expect(chunk.hasPrefix("<pre>"))
            #expect(chunk.hasSuffix("</pre>"))
            #expect(chunk.utf16.count <= AgentChannelMessageFormatter.telegramChunkLimit)
        }
    }
}
