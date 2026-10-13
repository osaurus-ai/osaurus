//
//  ContentBlockEqualityCostTests.swift
//
//  `ContentBlockKind ==` is evaluated for every block on every streamed token
//  (`hasContentChanges` and the path-3 `stableChangedIds` filter in
//  `MessageTableRepresentable.Coordinator`). Its "length first" short-circuit
//  used `String.count`, which walks every grapheme of both strings — the
//  `String.distance` / `_GraphemeBreakingState` frames under
//  `Coordinator.hasContentChanges` in the APPLE-MACOS-4M hang samples. The
//  equality must stay O(1) for unchanged blocks whose text storage is shared,
//  and must not grow with the length of the text.
//

import Foundation
import Testing

@testable import OsaurusCore

struct ContentBlockEqualityCostTests {

    private func paragraph(_ text: String, turn: UUID, index: Int) -> ContentBlock {
        ContentBlock.paragraph(
            turnId: turn,
            index: index,
            text: text,
            isStreaming: false,
            role: .assistant,
            position: .middle
        )
    }

    private func time(_ body: () -> Void) -> Double {
        let start = CFAbsoluteTimeGetCurrent()
        body()
        return (CFAbsoluteTimeGetCurrent() - start) * 1000
    }

    @Test func unchangedLongBlocksCompareInConstantTimePerBlock() {
        let turn = UUID()
        let shortText = String(repeating: "word ", count: 20)
        // Long answers with multi-byte characters: a code block with box
        // drawing and an accented prose run — the realistic worst case for
        // grapheme walking.
        let longText = String(repeating: "│ héllo wörld — naïve façade ✓ \n", count: 4000)

        let shortBlocks = (0 ..< 200).map { paragraph(shortText, turn: turn, index: $0) }
        let longBlocks = (0 ..< 200).map { paragraph(longText, turn: turn, index: $0) }
        // Same storage on both sides, as BlockMemoizer hands the coordinator
        // the same ContentBlock values across tokens for unchanged turns.
        let shortCopy = shortBlocks
        let longCopy = longBlocks

        let iterations = 50
        var equal = 0
        let shortMs = time {
            for _ in 0 ..< iterations {
                for i in shortBlocks.indices where shortBlocks[i] == shortCopy[i] { equal += 1 }
            }
        }
        let longMs = time {
            for _ in 0 ..< iterations {
                for i in longBlocks.indices where longBlocks[i] == longCopy[i] { equal += 1 }
            }
        }
        #expect(equal == 2 * iterations * 200)
        print(
            "[contentblock-equality] blocks=200 iterations=\(iterations) "
                + "shortText=\(shortText.utf8.count)B ms=\(String(format: "%.1f", shortMs)) "
                + "longText=\(longText.utf8.count)B ms=\(String(format: "%.1f", longMs))"
        )
        // Equality of unchanged blocks must not scale with text length: the
        // long run may cost a small multiple of the short one, never the
        // ~1000x the per-grapheme walk produced.
        #expect(
            longMs < max(shortMs * 8, 5),
            "comparing 200 unchanged long blocks x\(iterations) took \(longMs)ms vs \(shortMs)ms for short ones"
        )
    }

    @Test func lengthShortCircuitStillDetectsChanges() {
        let turn = UUID()
        let a = paragraph("héllo", turn: turn, index: 0)
        let b = paragraph("héllo!", turn: turn, index: 0)
        let c = paragraph("hello", turn: turn, index: 0)
        let d = paragraph("héllo", turn: turn, index: 0)
        #expect(a != b)
        #expect(a != c)
        #expect(a == d)
    }
    @Test func canonicallyEquivalentTextRetainsStringEquality() {
        let turn = UUID()
        let composed = "caf\u{00e9}"
        let decomposed = "cafe\u{0301}"
        #expect(composed == decomposed)
        #expect(composed.utf8.count != decomposed.utf8.count)
        #expect(paragraph(composed, turn: turn, index: 0)
            == paragraph(decomposed, turn: turn, index: 0))
    }

}
