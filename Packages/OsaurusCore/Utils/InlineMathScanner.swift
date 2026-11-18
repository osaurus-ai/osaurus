//
//  InlineMathScanner.swift
//  osaurus
//
//  Splits a line of message text into plain-text and inline-math spans.
//
//  This lives apart from the view that draws it so the delimiter rules can be tested
//  directly. `$` is also the currency sign and the shell variable sigil, so the rules
//  have to decide when two of them delimit math. They follow pandoc's
//  `tex_math_dollars` extension, which is the de facto Markdown standard and the
//  behaviour models are trained against:
//
//    * the opening `$` must have a non-space character immediately to its right;
//    * the closing `$` must have a non-space character immediately to its left, and
//      must not be followed immediately by a digit;
//    * the closer is the *first* unescaped `$` after the opener, so a span can never
//      contain another `$` — if that first candidate is invalid the pair is not math;
//    * backslash-escape literal dollars as `\$`; code spans are never math.
//

import Foundation

enum InlineMathScanner {

    struct Segment: Equatable {
        /// Content without delimiters — what gets typeset when `isMath`.
        let text: String
        let isMath: Bool
        /// The original source spelling, delimiters included. Shown verbatim when the
        /// typesetter rejects a span, so the message still says what the model wrote
        /// rather than a re-delimited guess.
        let fallback: String

        init(text: String, isMath: Bool, fallback: String? = nil) {
            self.text = text
            self.isMath = isMath
            self.fallback = fallback ?? text
        }
    }

    /// Cheap pre-check so plain prose skips the scanner entirely.
    @inline(__always)
    static func mayContainMath(_ text: String) -> Bool {
        text.contains("$") || text.contains("\\(")
    }

    /// Split text into alternating plain-text and math segments.
    ///
    /// Handles `$…$` under pandoc's `tex_math_dollars` rules and `\(…\)`. Anything that
    /// the rules turn down is emitted as literal text and scanning resumes at the next
    /// character, so a real math span later on the same line still matches.
    static func split(_ text: String) -> [Segment] {
        var segments: [Segment] = []
        var current = ""
        let scalars = Array(text.unicodeScalars)
        var i = 0

        @inline(__always)
        func flushText() {
            if !current.isEmpty {
                segments.append(Segment(text: current, isMath: false))
                current = ""
            }
        }

        @inline(__always)
        func peek(_ offset: Int) -> Unicode.Scalar? {
            let idx = i + offset
            return idx < scalars.count ? scalars[idx] : nil
        }

        @inline(__always)
        func slice(_ from: Int, _ to: Int) -> String {
            String(String.UnicodeScalarView(scalars[from ..< to]))
        }

        @inline(__always)
        func emitMath(_ content: String, fallback: String, advanceTo nextIndex: Int) {
            flushText()
            segments.append(Segment(text: content, isMath: true, fallback: fallback))
            i = nextIndex
        }

        while i < scalars.count {
            let c = scalars[i]

            // Inline code span. `$HOME and $PATH` inside backticks is shell, not math, and
            // `\(` inside backticks is a literal escape — neither may be typeset.
            if c == "`" {
                var runLength = 0
                while i + runLength < scalars.count, scalars[i + runLength] == "`" { runLength += 1 }
                if let closeStart = findClosingBacktickRun(
                    scalars, from: i + runLength, runLength: runLength)
                {
                    current += slice(i, closeStart + runLength)
                    i = closeStart + runLength
                } else {
                    // Unclosed (or still streaming): emit the run and keep scanning.
                    current += slice(i, i + runLength)
                    i += runLength
                }
                continue
            }

            // \(…\) — explicit and unambiguous, so any non-empty content is math.
            if c == "\\", peek(1) == "(" {
                if let closeIdx = findClosingParen(scalars, from: i + 2) {
                    let content = slice(i + 2, closeIdx)
                    if !content.isEmpty {
                        emitMath(content, fallback: slice(i, closeIdx + 2), advanceTo: closeIdx + 2)
                        continue
                    }
                }
                // Unclosed or empty: treat `\(` as literal text and resume scanning.
                current.append("\\(")
                i += 2
                continue
            }

            // Escaped \$ — not a math delimiter.
            if c == "\\", peek(1) == "$" {
                current.append("$")
                i += 2
                continue
            }

            // $…$ — a span only when both delimiters satisfy pandoc's conditions.
            if c == "$", let closeIdx = dollarSpanCloser(scalars, openingAt: i) {
                emitMath(
                    slice(i + 1, closeIdx),
                    fallback: slice(i, closeIdx + 1),
                    advanceTo: closeIdx + 1)
                continue
            }

            current.append(String(c))
            i += 1
        }

        flushText()
        return segments
    }

    /// Index of the `$` that closes a dollar span opened at `open`, or `nil` when the
    /// pair is not math.
    ///
    /// Mirrors pandoc: the opener needs a non-space character to its right, the closer
    /// needs a non-space character to its left, and the closer must not be followed by a
    /// digit. Only the first unescaped `$` is ever considered.
    private static func dollarSpanCloser(_ scalars: [Unicode.Scalar], openingAt open: Int) -> Int? {
        guard open + 1 < scalars.count else { return nil }
        guard !scalars[open + 1].properties.isWhitespace else { return nil }
        // `$$` is display math, paired by the block parser, never an inline opener.
        guard let close = firstUnescapedDollar(scalars, from: open + 1), close > open + 1 else {
            return nil
        }
        guard !scalars[close - 1].properties.isWhitespace else { return nil }
        if close + 1 < scalars.count, isASCIIDigit(scalars[close + 1]) { return nil }
        return close
    }

    /// Index of the first `$` at or after `start` that is not backslash-escaped.
    private static func firstUnescapedDollar(_ scalars: [Unicode.Scalar], from start: Int) -> Int? {
        var j = start
        while j < scalars.count {
            if scalars[j] == "\\", j + 1 < scalars.count, scalars[j + 1] == "$" {
                j += 2
                continue
            }
            if scalars[j] == "$" { return j }
            j += 1
        }
        return nil
    }

    @inline(__always)
    private static func isASCIIDigit(_ scalar: Unicode.Scalar) -> Bool {
        scalar >= "0" && scalar <= "9"
    }

    /// Find the start of a backtick run of exactly `runLength`, closing a code span
    /// opened by a run of the same length.
    private static func findClosingBacktickRun(
        _ scalars: [Unicode.Scalar], from start: Int, runLength: Int
    ) -> Int? {
        var j = start
        while j < scalars.count {
            guard scalars[j] == "`" else {
                j += 1
                continue
            }
            var length = 0
            while j + length < scalars.count, scalars[j + length] == "`" { length += 1 }
            if length == runLength { return j }
            j += length
        }
        return nil
    }

    /// Find the index of a closing `\)` for an opening `\(`.
    private static func findClosingParen(_ scalars: [Unicode.Scalar], from start: Int) -> Int? {
        var j = start
        while j + 1 < scalars.count {
            if scalars[j] == "\\" && scalars[j + 1] == ")" {
                return j
            }
            j += 1
        }
        return nil
    }
}
