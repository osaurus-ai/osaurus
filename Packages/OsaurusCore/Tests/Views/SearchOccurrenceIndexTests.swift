// Copyright © 2026 osaurus.

import Foundation
import Testing

@testable import OsaurusCore

/// Searching inside a chat crashed the app.
///
/// `NativeMarkdownView.rectOfSearchOccurrence` bounded the occurrence index from above
/// (`if index < searchAllOccurrenceRanges.count`) and then subscripted the array — so a
/// negative index sailed through the check and trapped in `Array._checkSubscript`
/// (Sentry APPLE-MACOS-10V, 0.22.0, reached from the find bar's scroll-to-match while a
/// user searched a conversation).
///
/// The index does not originate in that view: the find bar counts occurrences against the
/// *model's* text and hands the result to a view that indexes its *rendered* ranges, and
/// those ranges are torn down and rebuilt on every highlight pass. So the index arriving
/// there is not something the view can vouch for, and treating it as trusted was the bug.
///
/// This pins the contract at the source: the lower bound must be checked. The producer of
/// the bad index is still unidentified — an `assertionFailure` in the view now surfaces it
/// in debug builds rather than letting it stay invisible — so do not delete this pin on
/// the grounds that "nothing can pass a negative index".
@Suite("Find-bar occurrence index is bounded on both sides")
struct SearchOccurrenceIndexTests {
    private static func source(_ relativePath: String) throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Views/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // OsaurusCore/
        return try String(
            contentsOf: packageRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    @Test("A negative occurrence index cannot reach the subscript")
    func negativeIndexIsRejectedBeforeSubscripting() throws {
        let src = try Self.source("Views/Chat/NativeMarkdownView.swift")

        guard let start = src.range(of: "func rectOfSearchOccurrence(") else {
            Issue.record("rectOfSearchOccurrence not found")
            return
        }
        let body = String(src[start.lowerBound...].prefix(900))

        // The upper bound alone is what shipped, and it is exactly what let a negative
        // index through to `searchAllOccurrenceRanges[index]`.
        #expect(
            body.contains("guard index >= 0"),
            "an unbounded-below index reaches Array.subscript and traps — this crashed 0.22.0"
        )
        // And the bad index must not be swallowed in silence: we still do not know who
        // produces it.
        #expect(
            body.contains("assertionFailure"),
            "surface the producer in debug rather than quietly returning nil forever"
        )
    }
}
