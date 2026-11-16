//
//  FileEditMatcherTests.swift
//  osaurusTests
//
//  The `file_edit` tolerance cascade. Every relaxed strategy must (a) only
//  fire when its match is unique, (b) copy unchanged lines from the FILE
//  rather than the model (the Codex apply_patch indentation-corruption
//  class), and (c) preserve the file's line endings, BOM and
//  trailing-newline state.
//

import Foundation
import Testing

@testable import OsaurusCore

struct FileEditMatcherTests {

    private func applied(
        _ old: String, _ new: String, to content: String, replaceAll: Bool = false
    ) throws -> FileEditMatcher.Applied {
        switch FileEditMatcher.apply(oldString: old, newString: new, to: content, replaceAll: replaceAll) {
        case .applied(let result): return result
        case .notFound: throw TestFailure("notFound")
        case .ambiguous(let count, let strategy): throw TestFailure("ambiguous(\(count), \(strategy))")
        case .noOp: throw TestFailure("noOp")
        }
    }

    private struct TestFailure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    // MARK: - Exact

    @Test func exact_substringFragmentInsideLine() throws {
        let result = try applied("debug = True", "debug = False", to: "cfg:\n    debug = True  # flag\n")
        #expect(result.strategy == .exact)
        #expect(result.content == "cfg:\n    debug = False  # flag\n")
        #expect(result.matchedLines == [2...2])
        #expect(result.matchedText == nil)
    }

    @Test func exact_multipleWithoutReplaceAllIsAmbiguous() {
        guard case .ambiguous(let count, let strategy) = FileEditMatcher.apply(
            oldString: "x", newString: "y", to: "x x", replaceAll: false)
        else { Issue.record("expected ambiguous"); return }
        #expect(count == 2)
        #expect(strategy == .exact)
    }

    @Test func exact_replaceAllReplacesEveryOccurrence() throws {
        let result = try applied("Bob", "[NAME]", to: "Bob met Bob.\nBob left.", replaceAll: true)
        #expect(result.replacements == 3)
        #expect(result.content == "[NAME] met [NAME].\n[NAME] left.")
    }

    @Test func identicalOldAndNewIsNoOp() {
        guard case .noOp = FileEditMatcher.apply(oldString: "a", newString: "a", to: "a", replaceAll: false) else {
            Issue.record("expected noOp"); return
        }
    }

    @Test func exact_isLiteral_noCanonicalEquivalenceSurprise() {
        // Decomposed e + combining acute in the file, precomposed in the
        // request: exact must not match, the unicode tier does (NFC).
        let file = "caf\u{0065}\u{0301} au lait\n"
        let result = FileEditMatcher.apply(oldString: "caf\u{00E9} au lait", newString: "tea", to: file, replaceAll: false)
        guard case .applied(let applied) = result else { Issue.record("expected applied"); return }
        // Swift `==` on the normalized lines is canonical, so the whitespace
        // tier already resolves NFC drift; what matters is that "exact" was
        // NOT reported for a byte-different match.
        #expect(applied.strategy.isRelaxed)
        #expect(applied.content == "tea\n")
    }

    // MARK: - Whitespace-normalized

    @Test func whitespace_indentationDriftIsResolved_andFileIndentKept() throws {
        let file = "def f():\n\tif x:\n\t\treturn 1\n\treturn 0\n"
        // Model wrote spaces instead of tabs.
        let result = try applied(
            "    if x:\n        return 1",
            "    if x:\n        return 2",
            to: file
        )
        #expect(result.strategy == .whitespaceNormalized)
        #expect(result.content == "def f():\n\tif x:\n\t\treturn 2\n\treturn 0\n")
        #expect(result.matchedLines == [2...3])
        #expect(result.matchedText == "\tif x:\n\t\treturn 1")
    }

    @Test func whitespace_unchangedContextLinesComeFromFile() throws {
        // The classic apply_patch corruption: context lines the model got
        // slightly wrong must NOT be rewritten with the model's bytes.
        let file = "a\n    b   =  1\n    c = 2\n    d = 3\n"
        let result = try applied(
            "b = 1\nc = 2\nd = 3",
            "b = 1\nc = 20\nd = 3",
            to: file
        )
        #expect(result.strategy == .whitespaceNormalized)
        // `b   =  1` keeps its odd inner spacing; only `c` changed.
        #expect(result.content == "a\n    b   =  1\n    c = 20\n    d = 3\n")
    }

    @Test func whitespace_insertedLinesInheritBlockIndent() throws {
        let file = "start\n    x = 1\n    y = 2\nend\n"
        let result = try applied(
            "x = 1\ny = 2",
            "x = 1\nz = 5\ny = 2",
            to: file
        )
        #expect(result.content == "start\n    x = 1\n    z = 5\n    y = 2\nend\n")
    }

    @Test func whitespace_relativeIndentOfNewLinesIsPreserved() throws {
        let file = "  if a:\n    b()\n"
        // Model wrote the block flush-left; new nested line must land at
        // file indent + its own relative indent.
        let result = try applied(
            "if a:\n  b()",
            "if a:\n  b()\n  c()",
            to: file
        )
        #expect(result.content == "  if a:\n    b()\n    c()\n")
    }

    @Test func whitespace_twoSpaceRequestOntoFourSpaceFile() throws {
        let file = "class A:\n    def f(self):\n        return 1\n"
        let result = try applied(
            "def f(self):\n  return 1",
            "def f(self):\n  if self.x:\n    return 2\n  return 1",
            to: file
        )
        #expect(result.content == "class A:\n    def f(self):\n        if self.x:\n            return 2\n        return 1\n")
    }

    @Test func whitespace_ambiguousRelaxedMatchIsRejected() {
        let file = "  foo()\nbar\n    foo()\n"
        let result = FileEditMatcher.apply(oldString: "foo()", newString: "baz()", to: file, replaceAll: false)
        // Exact finds 2 already (fragment) — that is the ambiguity reported.
        guard case .ambiguous(let count, _) = result else { Issue.record("expected ambiguous"); return }
        #expect(count == 2)
    }

    @Test func whitespace_relaxedAmbiguityNamesStrategy() {
        let file = "\tfoo(1)\n\tbar\n\tfoo(1)\n"
        // Two spaces never occur in the file (tabs), so exact finds nothing
        // and the whitespace tier finds two whole-line matches.
        let result = FileEditMatcher.apply(oldString: "  foo(1)", newString: "x", to: file, replaceAll: false)
        guard case .ambiguous(let count, let strategy) = result else { Issue.record("expected ambiguous"); return }
        #expect(count == 2)
        #expect(strategy == .whitespaceNormalized)
    }

    @Test func whitespace_replaceAllUnderRelaxedStrategy() throws {
        let file = "\tfoo(1)\n\tbar\n\tfoo(1)\n"
        let result = try applied("  foo(1)", "  foo(2)", to: file, replaceAll: true)
        #expect(result.strategy == .whitespaceNormalized)
        #expect(result.replacements == 2)
        #expect(result.content == "\tfoo(2)\n\tbar\n\tfoo(2)\n")
        #expect(result.matchedLines == [1...1, 3...3])
    }

    // MARK: - Blank lines collapsed

    @Test func blankLines_collapsedRunIsResolved_andFileBlankLinesKept() throws {
        let file = "def a():\n    pass\n\n\n\ndef b():\n    pass\n"
        let result = try applied(
            "def a():\n    pass\n\ndef b():",
            "def a():\n    pass\n\ndef b2():",
            to: file
        )
        #expect(result.strategy == .blankLinesCollapsed)
        #expect(result.content == "def a():\n    pass\n\n\n\ndef b2():\n    pass\n")
    }

    // MARK: - Unicode normalized

    @Test func unicode_curlyQuotesAndDashes() throws {
        let file = "He said \u{201C}don\u{2019}t\u{201D} \u{2014} twice.\n"
        let result = try applied(
            "He said \"don't\" - twice.",
            "He said \"do\" - once.",
            to: file
        )
        #expect(result.strategy == .unicodeNormalized)
        #expect(result.content == "He said \"do\" - once.\n")
    }

    @Test func unicode_nonBreakingSpaceInFile() throws {
        let file = "Total:\u{00A0}42\n"
        let result = try applied("Total: 42", "Total: 43", to: file)
        // NBSP counts as whitespace for the whitespace tier already.
        #expect(result.strategy.isRelaxed)
        #expect(result.content == "Total: 43\n")
    }

    // MARK: - Byte preservation

    @Test func crlf_fileStaysCRLF_whenModelUsesLF() throws {
        let file = "one\r\ntwo\r\nthree\r\n"
        let result = try applied("two\nthree", "two\n2.5\nthree", to: file)
        #expect(result.strategy == .whitespaceNormalized)
        #expect(result.content == "one\r\ntwo\r\n2.5\r\nthree\r\n")
    }

    @Test func bom_isPreserved() throws {
        let file = "\u{FEFF}alpha\nbeta\n"
        let result = try applied("alpha", "ALPHA", to: file)
        // Exact substring match keeps the BOM untouched.
        #expect(result.content == "\u{FEFF}ALPHA\nbeta\n")

        let relaxed = try applied("  alpha\n  beta", "  alpha\n  gamma", to: file)
        #expect(relaxed.strategy == .whitespaceNormalized)
        #expect(relaxed.content == "\u{FEFF}alpha\ngamma\n")
    }

    @Test func trailingNewline_absentStaysAbsent() throws {
        let file = "a\nb"
        let result = try applied("  b", "  c", to: file)
        #expect(result.strategy == .whitespaceNormalized)
        #expect(result.content == "a\nc")
    }

    @Test func trailingNewline_presentStaysPresent() throws {
        let file = "a\nb\n"
        let result = try applied("  b", "  c", to: file)
        #expect(result.content == "a\nc\n")
    }

    @Test func deletion_ofLastLineWithoutTrailingNewline() throws {
        let file = "a\nb"
        let result = try applied("  b", "", to: file)
        #expect(result.content == "a")
    }

    @Test func deletion_ofMiddleBlock() throws {
        let file = "a\n  b\nc\n"
        let result = try applied("b\n", "", to: file)
        // Exact substring "b\n" exists → exact deletion leaves the indent.
        #expect(result.strategy == .exact)
        #expect(result.content == "a\n  c\n")
    }

    // MARK: - Not found

    @Test func notFound_whenNothingResembles() {
        guard case .notFound = FileEditMatcher.apply(oldString: "zzz", newString: "y", to: "abc\n", replaceAll: false) else {
            Issue.record("expected notFound"); return
        }
    }

    @Test func notFound_forWhitespaceOnlyOldString() {
        guard case .notFound = FileEditMatcher.apply(oldString: "   ", newString: "y", to: "a b\n", replaceAll: false) else {
            Issue.record("expected notFound"); return
        }
    }

    // MARK: - Lines model

    @Test func lines_roundTripsMixedEndings() {
        for text in ["", "a", "a\n", "a\r\nb", "a\rb\r", "\u{FEFF}x\r\ny\n", "a\n\n\nb"] {
            #expect(FileEditMatcher.Lines(text).joined() == text, "round trip failed for \(text.debugDescription)")
        }
    }

    @Test func lineSpan_countsCorrectly() {
        let content = "l1\nl2\nl3\nl4\n"
        let range = content.range(of: "l2\nl3\n")!
        #expect(FileEditMatcher.lineSpan(of: range, in: content) == 2...3)
        let single = content.range(of: "l4")!
        #expect(FileEditMatcher.lineSpan(of: single, in: content) == 4...4)
    }
}
