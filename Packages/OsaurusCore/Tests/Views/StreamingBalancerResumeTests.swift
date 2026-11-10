import Foundation
import Testing

@testable import OsaurusCore

struct StreamingBalancerResumeTests {
    private static let sample: String = {
        var text = ""
        for i in 0 ..< 40 {
            text += "Paragraph \(i) with **bold** and `code` 🦕 words.\n\n"
            if i % 7 == 0 { text += "````md\n```swift\nlet x = \(i)\n```\n````\n\n" }
            if i % 11 == 0 { text += "- item\r\n- **open\r\n\r\n" }
            if i % 13 == 0 { text += "~~~\nunterminated? no\n~~~\n" }
        }
        return text + "```python\nprint('still open')\n"
    }()

    @Test func resumedScanMatchesFullBalanceForEveryPrefix() {
        let text = Self.sample
        var scan = StreamingMarkdownBalancer.FenceScan()
        var end = text.startIndex
        while end < text.endIndex {
            end = text.index(after: end)
            let prefix = String(text[..<end])
            #expect(StreamingMarkdownBalancer.balance(prefix, scan: &scan) == StreamingMarkdownBalancer.balance(prefix))
        }
    }

    @Test func scanRecoversWhenTextIsRewritten() {
        var scan = StreamingMarkdownBalancer.FenceScan()
        let first = "```swift\nlet a = 1\n```\n\nSome **bold"
        let rewritten = "Fresh text **here\n\nand `code"
        _ = StreamingMarkdownBalancer.balance(first, scan: &scan)
        let resumed = StreamingMarkdownBalancer.balance(rewritten, scan: &scan)
        #expect(resumed == StreamingMarkdownBalancer.balance(rewritten))
        let reopened = "```swift\nlet a = 1\n"
        #expect(StreamingMarkdownBalancer.balance(reopened, scan: &scan) == reopened)
    }

    @Test func parserMatchesFreshParseAcrossChunks() {
        let text = Self.sample
        var parser = StreamingMarkdownParser()
        var end = text.startIndex
        var step = 0
        while end < text.endIndex {
            end = text.index(end, offsetBy: min(17, text.distance(from: end, to: text.endIndex)))
            step += 1
            let prefix = String(text[..<end])
            let incremental = parser.parse(prefix).map(\.kind)
            let fresh = parseBlocks(StreamingMarkdownBalancer.balance(prefix)).map(\.kind)
            #expect(incremental == fresh, "chunk \(step)")
        }
    }
}
