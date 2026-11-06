//
//  InlineMathScannerTests.swift
//  osaurusTests
//
//  Pin the inline-math delimiter rules.
//
//  The delimiter rules follow pandoc's `tex_math_dollars` extension: the opening `$`
//  needs a non-space character to its right, the closing `$` needs a non-space character
//  to its left and must not be followed by a digit, and the closer is the first `$` after
//  the opener. Those conditions are what keep the two other uses of `$` — currency
//  amounts and shell variables in code spans — literal without inspecting content, so
//  the negatives are pinned here as hard as the positives.
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

    /// The inline forms models emit most, plus the `\(…\)` spelling.
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

    /// `$HOME`/`$PATH` inside a code span is shell, not math: the span is copied
    /// verbatim, so its `$` characters are never delimiters.
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

    /// Both spellings on one line: both render, and the surrounding prose survives.
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

    /// A `$…$` span whose content starts with a digit is math, not money.
    ///
    /// The digit conditions apply to the delimiters, not the content: a price run is
    /// followed by a space or by a digit, which is what invalidates its closing `$`.
    @Test(arguments: [
        ("density $0.399$ at zero", ["0.399"]),
        ("so $1/2$ of them", ["1/2"]),
        ("about $50/50$ odds", ["50/50"]),
        ("$0.5$ is small", ["0.5"]),
        ("$(1)$", ["(1)"]),
        ("$---$", ["---"]),
    ])
    func typesetsDigitLeadingSpans(_ source: String, _ expected: [String]) {
        let math = InlineMathScanner.split(source).filter(\.isMath).map(\.text)
        #expect(math == expected, "got \(math)")
    }

    /// The pandoc delimiter conditions, one test each: the opening `$` needs a non-space
    /// character to its right, and the closing `$` must not be followed by a digit.
    @Test(arguments: ["$ 5$", "$ 5 $", "$5$10", "tax is $x$10 here"])
    func rejectsSpansThatBreakTheDelimiterConditions(_ source: String) {
        let segments = InlineMathScanner.split(source)
        #expect(!segments.contains { $0.isMath }, "unexpected math in: \(source)")
        #expect(rendered(segments) == source)
    }

    /// Only the first unescaped `$` after an opening `$` is considered, so a span never
    /// contains another one.
    @Test(arguments: [
        ("$a$b$c$", ["a", "c"]),
        ("$x$ and $y$ and $z$", ["x", "y", "z"]),
    ])
    func neverPairsAcrossAnotherDollar(_ source: String, _ expected: [String]) {
        let math = InlineMathScanner.split(source).filter(\.isMath).map(\.text)
        #expect(math == expected, "got \(math)")
    }

    /// pandoc's own example from the `tex_math_dollars` documentation.
    @Test
    func matchesPandocCurrencyExample() {
        let segments = InlineMathScanner.split("$20,000 and $30,000")
        #expect(!segments.contains { $0.isMath })
        #expect(rendered(segments) == "$20,000 and $30,000")
    }

    /// When the typesetter rejects a span the view prints `fallback`, so it holds the
    /// source verbatim — `\(x\)` stays `\(x\)` rather than becoming `$x$`.
    @Test
    func fallbackPreservesOriginalDelimiters() {
        let paren = InlineMathScanner.split("\\(O(n)\\)").first
        #expect(paren?.fallback == "\\(O(n)\\)")

        let dollar = InlineMathScanner.split("$O(n)$").first
        #expect(dollar?.fallback == "$O(n)$")
    }

    /// Text between a `$` that does not open a span and a later span stays plain text.
    @Test
    func doesNotTypesetProseAsMath() {
        let source =
            "There is exactly one path each through $x$ — so counting gives $50/50$. But those two paths have very different likelihoods under $\\mathcal{N}(0,1)$: density $0.399$ at $\\epsilon = 0$ versus $0.054$ at $\\epsilon = 2$."
        let segments = InlineMathScanner.split(source)
        let math = segments.filter(\.isMath).map(\.text)
        #expect(
            math == [
                "x", "50/50", "\\mathcal{N}(0,1)", "0.399", "\\epsilon = 0", "0.054",
                "\\epsilon = 2",
            ], "got \(math)")
        #expect(rendered(segments) == source)
    }

    /// Every span on a line that also contains literal dollar amounts is typeset.
    @Test
    func typesetsEverySpanBesideDollarAmounts() {
        let source = "We have $1$, and $2$, and $3$, and $O(n)$ done."
        let segments = InlineMathScanner.split(source)
        #expect(segments.filter(\.isMath).map(\.text) == ["1", "2", "3", "O(n)"])
        #expect(rendered(segments) == source)
    }

    /// Reassemble what the user sees, so a rule change cannot silently drop text.
    private func rendered(_ segments: [InlineMathScanner.Segment]) -> String {
        segments.map { $0.isMath ? $0.fallback : $0.text }.joined()
    }
}
