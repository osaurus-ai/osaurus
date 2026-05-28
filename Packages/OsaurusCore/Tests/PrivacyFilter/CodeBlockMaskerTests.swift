//
//  CodeBlockMaskerTests.swift
//  osaurusTests
//
//  CodeBlockMasker.mask should:
//   • leave plain text unchanged
//   • mask fenced (```) and inline (`) code with equal-length spaces
//   • produce a restoreRange that drops ranges overlapping masked spans
//   • pass through ranges that don't overlap any masked span
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("CodeBlockMasker")
struct CodeBlockMaskerTests {

    @Test func plainText_isPassedThrough() {
        let text = "Hi Alice — call me at 555-1234."
        let output = CodeBlockMasker.mask(text)
        #expect(output.masked == text)
        // Restore is a pass-through on plain text.
        let range = text.startIndex ..< text.endIndex
        #expect(output.restoreRange(range) == range)
    }

    @Test func fencedBlock_isReplacedWithSpaces() {
        let text = """
            Hi Alice
            ```swift
            let secret = "abc"
            ```
            After.
            """
        let output = CodeBlockMasker.mask(text)
        // Length is preserved.
        #expect(output.masked.count == text.count)
        // Text outside the fence stays readable.
        #expect(output.masked.contains("Hi Alice"))
        #expect(output.masked.contains("After."))
        // Fence body is wiped to spaces — the literal source string
        // must not be present in the masked output.
        #expect(!output.masked.contains("let secret"))
    }

    @Test func inlineCode_isReplacedWithSpaces() {
        let text = "Alice wrote `let secret = 1` in the file."
        let output = CodeBlockMasker.mask(text)
        #expect(output.masked.count == text.count)
        #expect(output.masked.contains("Alice wrote"))
        #expect(output.masked.contains("in the file."))
        #expect(!output.masked.contains("let secret"))
    }

    @Test func restoreRange_dropsHitsInsideFence() {
        let text = "```\nAlice\n```"
        let output = CodeBlockMasker.mask(text)
        // Use a range fully inside the fenced span: "Alice"
        let aliceRange = text.range(of: "Alice")!
        #expect(output.restoreRange(aliceRange) == nil)
    }

    @Test func restoreRange_keepsHitsOutsideFences() {
        let text = "Alice and ```code```!"
        let output = CodeBlockMasker.mask(text)
        // "Alice" is outside any fence — restore should pass through.
        let aliceRange = text.range(of: "Alice")!
        #expect(output.restoreRange(aliceRange) == aliceRange)
    }

    @Test func unbalancedFence_consumesToEnd() {
        let text = "Before ```still open"
        let output = CodeBlockMasker.mask(text)
        #expect(output.masked.count == text.count)
        // "Before " survives, the open-fence body is wiped.
        #expect(output.masked.hasPrefix("Before "))
        #expect(!output.masked.contains("still open"))
    }
}
