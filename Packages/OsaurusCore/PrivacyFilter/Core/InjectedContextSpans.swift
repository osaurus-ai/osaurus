//
//  InjectedContextSpans.swift
//  osaurus / PrivacyFilter
//
//  Locates app-injected context blocks inside a user turn so detection
//  can ignore them. The `[Current Time] … [/Current Time]` block that
//  `SystemPromptTemplates.timeContext` prepends exists solely so the
//  agent knows the time; it never contains user PII, but the model layer
//  reads timezone identifiers like `Asia/Kolkata` as person names and
//  the regex layer can match dates in it. Redacting it adds noise to
//  the review sheet and hides the timezone from the model.
//
//  Both detection (`PrivacyFilterEngine.detect`) and the post-scrub leak
//  invariant (`PrivacyFilterPipeline.scanForLeaks`) must use this so
//  they see the same view — a span skipped by one and counted by the
//  other would block the send on text the user never saw flagged.
//

import Foundation

enum InjectedContextSpans {
    /// `(open, close)` tag pairs for every injected block detection skips.
    static let blocks: [(open: String, close: String)] = [
        ("[Current Time]", "[/Current Time]")
    ]

    /// Ranges (inclusive of the tags) of every injected block in `text`.
    /// Offsets are computed on the string as given, so callers pass the
    /// same view they scan (the code-block-masked one when masking is
    /// on; `CodeBlockMasker` preserves offsets so both line up).
    static func ranges(in text: String) -> [Range<String.Index>] {
        var out: [Range<String.Index>] = []
        for block in blocks {
            var cursor = text.startIndex
            while cursor < text.endIndex,
                let open = text.range(of: block.open, range: cursor ..< text.endIndex)
            {
                guard let close = text.range(of: block.close, range: open.upperBound ..< text.endIndex)
                else { break }
                out.append(open.lowerBound ..< close.upperBound)
                cursor = close.upperBound
            }
        }
        return out
    }

    /// True when `range` touches any injected block in `ranges`.
    static func overlaps(_ range: Range<String.Index>, _ ranges: [Range<String.Index>]) -> Bool {
        ranges.contains { $0.overlaps(range) }
    }
}
