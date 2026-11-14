import AppKit
import Testing

@testable import OsaurusCore

struct MarkdownDocumentWrappingTests {
    @Test @MainActor func documentAndChatDoNotShareTheirNewlinePolicyOrParseCache() {
        let view = NativeMarkdownView()
        let text = "A model card source\nwraps within one paragraph."
        func render(reflow: Bool) -> String {
            view.configure(
                text: text,
                width: 600,
                theme: ThemeManager.shared.currentTheme,
                cacheKey: nil,
                isStreaming: false,
                reflowParagraphs: reflow
            )
            func strings(in view: NSView) -> [String] {
                if let textView = view as? NSTextView { return [textView.string] }
                return view.subviews.flatMap { strings(in: $0) }
            }
            return strings(in: view).joined()
        }
        #expect(render(reflow: false).contains("source\nwraps"))
        #expect(render(reflow: true).contains("source wraps"))
        #expect(render(reflow: false).contains("source\nwraps"))
    }

    @Test func modelCardSourceWrapsFlowWithinOneParagraph() {
        let source =
            "**About 27 GiB** stays in memory; the n-gram table is\nread from the SSD on demand. [Earlier model](https://example.com) needs\n35 GiB in memory."
        #expect(
            parseDocumentBlocks(source).map(\.kind) == [
                .paragraph(
                    "**About 27 GiB** stays in memory; the n-gram table is read from the SSD on demand. [Earlier model](https://example.com) needs 35 GiB in memory."
                )
            ]
        )
        #expect(parseBlocks(source).map(\.kind) == [.paragraph(source)])
    }

    @Test func paragraphBoundariesAndExplicitHardBreaksStaySeparate() {
        let source = "First source\nwrap.\n\nTwo spaces  \nkeep this line.\n\nBackslash\\\nkeeps this line."
        #expect(
            parseDocumentBlocks(source).map(\.kind) == [
                .paragraph("First source wrap."),
                .paragraph("Two spaces  \nkeep this line."),
                .paragraph("Backslash\\\nkeeps this line."),
            ]
        )
    }

    @Test func codeTablesListsAndMathKeepTheirStructure() {
        let source =
            "# Heading\n\n```swift\nlet first = 1\nlet second = 2\n```\n\n| A | B |\n| --- | --- |\n| 1 | 2 |\n\n- First\n- Second\n\n$$x^2$$"
        #expect(parseDocumentBlocks(source).map(\.kind) == parseBlocks(source).map(\.kind))
    }

    @Test func quotedWrapsReflowWithoutRemovingQuotedParagraphs() {
        #expect(
            parseDocumentBlocks("> First source\n> wrap.\n>\n> Next source\n> wrap.").map(\.kind) == [
                .blockquote("First source wrap.\n\nNext source wrap.")
            ]
        )
    }

    @Test func explicitQuotedHardBreakSurvivesSourceWrapReflow() {
        #expect(
            parseDocumentBlocks("> First line  \n> deliberate break\n> source wrap.").map(\.kind) == [
                .blockquote("First line  \ndeliberate break source wrap.")
            ]
        )
    }

    @Test func windowsLineEndingsAndContinuationIndentationReflow() {
        #expect(
            parseDocumentBlocks("First source\r\n  wrap.\r\n\r\nNext.").map(\.kind) == [
                .paragraph("First source wrap."), .paragraph("Next."),
            ]
        )
    }
}
