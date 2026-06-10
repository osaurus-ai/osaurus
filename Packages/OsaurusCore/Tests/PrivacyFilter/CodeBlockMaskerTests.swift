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

    @Test func overlappingSpansWithNonASCII_doesNotTrap() {
        // An inline span inside an indented line produces two
        // overlapping spans, and the multi-byte characters inside the
        // inline span change the string's encoded length when masked.
        // This combination used to trap in replaceSubrange.
        let text = "para\n\n    call `汉字` more\n"
        let output = CodeBlockMasker.mask(text)
        #expect(output.masked.utf16.count == text.utf16.count)
        #expect(output.masked.hasPrefix("para\n\n"))
        #expect(!output.masked.contains("汉字"))
        #expect(!output.masked.contains("call"))
    }

    @Test func restoreRange_translatesAcrossNonASCIIMaskedSpan() {
        // The inline span contains multi-byte characters, so indices
        // into the masked string are not interchangeable with the
        // original. restoreRange must map the detection back to the
        // right characters anyway.
        let text = "`汉字汉字` Alice wrote that"
        let output = CodeBlockMasker.mask(text)
        let aliceInMasked = output.masked.range(of: "Alice")!
        let restored = output.restoreRange(aliceInMasked)
        #expect(restored != nil)
        if let restored {
            #expect(String(text[restored]) == "Alice")
        }
    }

    @Test func fencedBlockWithNonASCII_preservesUTF16Length() {
        let text = "Hi\n```\n秘密の値 = 1\n```\nAfter."
        let output = CodeBlockMasker.mask(text)
        #expect(output.masked.utf16.count == text.utf16.count)
        #expect(!output.masked.contains("秘密"))
        #expect(output.masked.contains("After."))
    }
}
