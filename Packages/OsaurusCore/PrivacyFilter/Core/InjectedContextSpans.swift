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
        ranges(in: text, of: blocks)
    }

    private static func ranges(
        in text: String,
        of blocks: [(open: String, close: String)]
    ) -> [Range<String.Index>] {
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

    /// Every app-built block that rides on a user turn. The OpenAI
    /// classifier reads each of these apart from the user's own words:
    /// handed one blob, a few hundred tokens of `[Screen Context]` ahead of
    /// the message were enough for it to label every token outside, the
    /// message included, while the same model tags the message alone fine.
    static let separatedBlocks: [(open: String, close: String)] = [
        ("[Current Time]", "[/Current Time]"),
        ("[Screen Context]", "[/Screen Context]"),
        ("[Memory]", "[/Memory]"),
    ]

    /// `text` cut at every `separatedBlocks` boundary: each block and each
    /// stretch between them, in order, for the classifier to read one at a
    /// time. Whitespace-only stretches and the skipped `blocks` (never
    /// flagged anyway) are left out. Screen and memory blocks stay in: a
    /// screen snapshot can carry someone else's address to the provider.
    static func modelPieces(in text: String) -> [Range<String.Index>] {
        let skipped = ranges(in: text)
        let cuts = ranges(in: text, of: separatedBlocks)
            .sorted { $0.lowerBound < $1.lowerBound }
        var pieces: [Range<String.Index>] = []
        var cursor = text.startIndex
        for block in cuts where block.lowerBound >= cursor {
            if cursor < block.lowerBound { pieces.append(cursor ..< block.lowerBound) }
            pieces.append(block)
            cursor = block.upperBound
        }
        if cursor < text.endIndex { pieces.append(cursor ..< text.endIndex) }
        return pieces.filter { piece in
            !skipped.contains(piece) && !text[piece].allSatisfy(\.isWhitespace)
        }
    }

    /// True when `range` touches any injected block in `ranges`.
    static func overlaps(_ range: Range<String.Index>, _ ranges: [Range<String.Index>]) -> Bool {
        ranges.contains { $0.overlaps(range) }
    }
}
