//
//  InlineMathScanner.swift
//  osaurus
//
//  Splits a line of message text into plain-text and inline-math spans.
//
//  This lives apart from the view that draws it so the delimiter rules can be tested
//  directly. They are almost entirely rules about what is *not* math: `$` is also the
//  currency sign and the shell variable sigil, so the scanner has to turn down spans
//  that a naive "text between two dollar signs" reading would accept.
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

    /// Content that is unambiguously LaTeX because it uses LaTeX syntax.
    @inline(__always)
    static func looksLikeLatex(_ s: String) -> Bool {
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\\", "^", "_", "{": return true
            default: continue
            }
        }
        return false
    }

    @inline(__always)
    private static func isASCIIDigit(_ scalar: Unicode.Scalar) -> Bool {
        scalar >= "0" && scalar <= "9"
    }

    /// Whether a `$…$` span carrying no explicit LaTeX syntax should still be typeset.
    ///
    /// Requiring LaTeX syntax was the original rule, and it was too strict: it left the
    /// single most common inline form models emit (`$O(n)$`) showing raw delimiters
    /// beside correctly rendered math in the same sentence, because `O(n)` contains no
    /// `\`, `^`, `_` or `{`.
    ///
    /// Two properties separate math from money. Currency amounts begin with a digit right
    /// after the `$`; and when a currency run is mis-paired, the "closing" `$` is really
    /// the opening `$` of the next amount, so a digit follows it. Both guards earn their
    /// place: the first rejects `$5 to $10`, the second rejects `$USD 5 and $10`.
    ///
    /// A span that starts with a digit and has no LaTeX syntax (`$2$`) stays literal —
    /// the deliberate cost of never typesetting a price.
    @inline(__always)
    static func looksLikeDollarMath(_ content: String, followedBy next: Unicode.Scalar?) -> Bool {
        let scalars = content.unicodeScalars
        guard let first = scalars.first, scalars.count <= 64 else { return false }
        guard !isASCIIDigit(first) else { return false }
        if let next, isASCIIDigit(next) { return false }
        for scalar in scalars where scalar == "\n" { return false }
        // Require something substantive; a span of pure punctuation is not math.
        return scalars.contains { CharacterSet.alphanumerics.contains($0) }
    }

    /// Split text into alternating plain-text and math segments.
    ///
    /// Handles `$…$` (no whitespace padding) and `\(…\)`. A delimited span that fails the
    /// rules above is emitted as literal text, and scanning resumes just past the opening
    /// delimiter, so a real math span later on the same line can still match.
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

            // $…$ — require non-whitespace after the opening and before the closing `$`.
            if c == "$",
                let after = peek(1),
                !after.properties.isWhitespace,
                after != "$",
                let closeIdx = findClosingDollar(scalars, from: i + 1)
            {
                let content = slice(i + 1, closeIdx)
                if looksLikeLatex(content)
                    || looksLikeDollarMath(content, followedBy: peek(closeIdx - i + 1))
                {
                    emitMath(content, fallback: slice(i, closeIdx + 1), advanceTo: closeIdx + 1)
                    continue
                }
                // Currency/plain text: fall through, keeping the `$` literal.
            }

            current.append(String(c))
            i += 1
        }

        flushText()
        return segments
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

    /// Find the index of a closing `$` whose preceding character is not whitespace.
    private static func findClosingDollar(_ scalars: [Unicode.Scalar], from start: Int) -> Int? {
        var j = start
        while j < scalars.count {
            if scalars[j] == "$", j > 0, !scalars[j - 1].properties.isWhitespace {
                return j
            }
            j += 1
        }
        return nil
    }
}
