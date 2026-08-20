//
//  InlineMathScannerTests.swift
//  osaurusTests
//
//  Pin the inline-math delimiter rules.
//
//  The reported defect: `$O(n)$` rendered as literal text while `\(O(n \log n)\)`
//  rendered as real math *in the same table cell*, because a span only counted as
//  math when it contained `\`, `^`, `_` or `{`. `O(n)` contains none of them, so
//  the most common inline form models emit showed its raw delimiters.
//
//  Loosening that rule is only safe if the scanner still turns down the two things
//  `$` is otherwise used for — currency amounts and shell variables inside code
//  spans — so those negatives are pinned here just as hard as the positives.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct InlineMathScannerTests {

    @Test(arguments: [
        ("$$x^2 + y^2 = z^2$$", "x^2 + y^2 = z^2"),
        ("\\[\\frac{a}{b}\\]", "\\frac{a}{b}"),
    ])
    func recognizesDisplayMath(_ source: String, latex: String) {
        let blocks = parseBlocks(source)
        #expect(blocks.count == 1)
        #expect(blocks.first?.kind == .math(latex))
    }

    @Test
    func leavesUnclosedDisplayMathAsTextWhileStreaming() {
        let blocks = parseBlocks("$$\\frac{a}{b}")
        #expect(blocks.count == 1)
        #expect(blocks.first?.kind == .paragraph("$$\\frac{a}{b}"))
    }

    /// The exact spans from the bug report, plus the form that always worked.
    @Test(arguments: [
        "$O(n)$",
        "$O(n log n)$",
        "$n$",
        "$x = 5$",
        "\\(O(n)\\)",
        "\\(O(n \\log n)\\)",
    ])
    func recognizesInlineMath(_ source: String) {
        let segments = InlineMathScanner.split(source)
        #expect(
            segments.count == 1 && segments[0].isMath,
            "\(source) should be one math span, got \(segments)")
    }

    /// Currency must never be typeset. `$5 to $10` is the shape that makes a naive
    /// "text between two dollar signs" reading fail.
    @Test(arguments: [
        "It costs $5 to $10 depending on size.",
        "Between $100 and $200.",
        "Prices: $1000, $2000, $3000.",
        "We charge $USD 5 and $10 respectively.",
        "A single $20 bill.",
    ])
    func leavesCurrencyAlone(_ source: String) {
        let segments = InlineMathScanner.split(source)
        #expect(!segments.contains { $0.isMath }, "currency was typeset in: \(source)")
        #expect(rendered(segments) == source, "currency text was altered: \(rendered(segments))")
    }

    /// `$HOME`/`$PATH` inside a code span is shell, not math. Before code spans were
    /// skipped, the loosened `$…$` rule would have swallowed `HOME and ` here.
    @Test
    func doesNotTypesetShellVariablesInCodeSpans() {
        let source = "Run `echo $HOME and $PATH` to check."
        let segments = InlineMathScanner.split(source)
        #expect(!segments.contains { $0.isMath })
        #expect(rendered(segments) == source)
    }

    /// A code span containing real LaTeX is still code — it must survive verbatim.
    @Test
    func doesNotTypesetLatexInsideCodeSpans() {
        let source = "The literal string `$x^2$` is not math here."
        let segments = InlineMathScanner.split(source)
        #expect(!segments.contains { $0.isMath })
        #expect(rendered(segments) == source)
    }

    /// The reported cell mixed both forms in one line; both must render, and the
    /// surrounding prose must survive intact.
    @Test
    func handlesBothFormsInOneLine() {
        let source = "$O(n)$ (with Timsort) or consistent \\(O(n \\log n)\\)."
        let segments = InlineMathScanner.split(source)
        let math = segments.filter(\.isMath).map(\.text)
        #expect(math == ["O(n)", "O(n \\log n)"])
        #expect(rendered(segments) == source)
    }

    /// A rejected span must not consume the rest of the line: a real math span after
    /// a currency amount still has to match.
    @Test
    func recoversAfterARejectedSpan() {
        let source = "Costs $5 today, and runs in $O(n)$ time."
        let segments = InlineMathScanner.split(source)
        #expect(segments.filter(\.isMath).map(\.text) == ["O(n)"])
        #expect(rendered(segments) == source)
    }

    /// An escaped `\$` is a literal dollar sign, not an opening delimiter.
    @Test
    func escapedDollarStaysLiteral() {
        let segments = InlineMathScanner.split("A \\$5 charge.")
        #expect(!segments.contains { $0.isMath })
        #expect(rendered(segments) == "A $5 charge.")
    }

    /// Unclosed delimiters arrive constantly while a message is still streaming.
    @Test(arguments: ["The cost is $5", "Complexity is $O(n", "Half an escape \\(x"])
    func toleratesUnclosedDelimiters(_ source: String) {
        let segments = InlineMathScanner.split(source)
        #expect(!segments.contains { $0.isMath })
        #expect(rendered(segments) == source)
    }

    /// Both guards in `looksLikeDollarMath` are load-bearing; neither alone suffices.
    /// Leading digit rejects `$5 to $10`; the digit-after-close rejects `$USD 5 and $10`.
    @Test
    func bothCurrencyGuardsAreNeeded() {
        #expect(!InlineMathScanner.looksLikeDollarMath("5 to ", followedBy: "1"))
        #expect(!InlineMathScanner.looksLikeDollarMath("USD 5 and ", followedBy: "1"))
        #expect(InlineMathScanner.looksLikeDollarMath("O(n)", followedBy: " "))
        #expect(InlineMathScanner.looksLikeDollarMath("O(n)", followedBy: nil))
    }

    /// Pure punctuation and runaway spans are not math.
    @Test
    func rejectsNonSubstantiveSpans() {
        #expect(!InlineMathScanner.looksLikeDollarMath("---", followedBy: " "))
        #expect(!InlineMathScanner.looksLikeDollarMath("", followedBy: " "))
        #expect(!InlineMathScanner.looksLikeDollarMath(String(repeating: "x", count: 65), followedBy: " "))
    }

    /// When the typesetter rejects a span the view prints `fallback`, so it must be the
    /// source verbatim. It used to be rebuilt as `"$" + content + "$"`, which rewrote
    /// `\(x\)` into `$x$` — a delimiter the model never wrote.
    @Test
    func fallbackPreservesOriginalDelimiters() {
        let paren = InlineMathScanner.split("\\(O(n)\\)").first
        #expect(paren?.fallback == "\\(O(n)\\)")

        let dollar = InlineMathScanner.split("$O(n)$").first
        #expect(dollar?.fallback == "$O(n)$")
    }

    /// Reassemble what the user sees, so a rule change cannot silently drop text.
    private func rendered(_ segments: [InlineMathScanner.Segment]) -> String {
        segments.map { $0.isMath ? $0.fallback : $0.text }.joined()
    }
}
