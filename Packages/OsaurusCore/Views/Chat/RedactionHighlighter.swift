//
//  RedactionHighlighter.swift
//  osaurus
//
//  Post-pass that decorates an `NSTextStorage` with inline Privacy
//  Filter highlights. Called by `NativeMarkdownView` after every
//  `setAttributedString` / incremental update on the body text view.
//
//  Design notes:
//    • We never mutate text. The markdown layer owns layout; we only
//      add a small set of attributes to existing character ranges
//      (foreground color, dotted underline, an a11y label, and the
//      custom `.redactionPlaceholder` key the hover controller
//      reads).
//    • Substring matching is case-sensitive `.literal`, longest-
//      original-first. Two redactions whose originals overlap would
//      otherwise paint over each other and leave a placeholder
//      pointing at the wrong sibling.
//    • Code blocks render in separate `NativeCodeBlockView` segments
//      so this pass cannot touch their text storage even if a
//      redaction substring happens to appear inside a code fence.
//

import AppKit
import Foundation

/// Per-cell instruction for `RedactionHighlighter`. The
/// `placeholderToken` field is overloaded by `direction`:
///   • `.outbound` / `.inbound` — chat bubble case. `placeholderToken`
///     is the literal cloud-facing token (`[PHONE_1]`). The hover
///     popover shows it under "Replaced with" / "Restored from".
///   • `.preview` — review-sheet case. The text storage shows the
///     scrubbed payload (placeholders), so the highlighter keys on
///     the placeholder substring and stores the user's ORIGINAL
///     value in `placeholderToken` — the popover labels it
///     "Original value (stays on your Mac)" so the user can verify
///     what's hidden under each token before approving the send.
struct RedactionHighlight: Equatable, Hashable {
    let placeholderToken: String
    let direction: Direction

    enum Direction: String, Equatable, Hashable {
        /// User typed it; the wire body had the placeholder.
        case outbound
        /// Cloud emitted the placeholder; the unscrubber restored
        /// the original locally before this string was rendered.
        case inbound
        /// Review-sheet preview: the user is looking at the
        /// scrubbed payload (placeholders), and the tooltip reveals
        /// the original we're hiding. Inverse semantics of
        /// `.outbound`.
        case preview
    }

    /// Shared helper used by every cell-level call site that maps a
    /// `[original: placeholder]` dict into the `[original: highlight]`
    /// shape `RedactionHighlighter.apply` expects. Lives here so
    /// `NativeMessageCellView` (user + assistant bubbles) and
    /// `NativeThinkingView` (reasoning pane) emit identical
    /// instructions — otherwise drift would show up as some bubbles
    /// being highlighted and the thinking pane staying raw.
    static func buildDictionary(
        from sessionRedactions: [String: String],
        direction: Direction
    ) -> [String: RedactionHighlight] {
        guard !sessionRedactions.isEmpty else { return [:] }
        var out: [String: RedactionHighlight] = [:]
        out.reserveCapacity(sessionRedactions.count)
        for (original, placeholder) in sessionRedactions {
            guard !original.isEmpty, !placeholder.isEmpty else { continue }
            out[original] = RedactionHighlight(
                placeholderToken: placeholder,
                direction: direction
            )
        }
        return out
    }
}

/// Range + metadata for a single applied highlight. Returned by
/// `RedactionHighlighter.apply` so the caller can hand the list to
/// the hover controller without re-scanning the storage.
struct AppliedRedactionRange: Equatable {
    let range: NSRange
    let highlight: RedactionHighlight
}

extension NSAttributedString.Key {
    /// Carries the `RedactionHighlight.placeholderToken` for every
    /// run that the highlighter painted. Used by
    /// `RedactionHoverController` to look up which placeholder the
    /// glyph under the mouse pointer belongs to without keeping a
    /// parallel `[NSRange]` list in sync with `textStorage`.
    static let redactionPlaceholder = NSAttributedString.Key("OsaurusRedactionPlaceholder")
    /// Carries `RedactionHighlight.Direction.rawValue` for the same
    /// runs as `.redactionPlaceholder`. The hover controller uses
    /// it to pick the popover's title copy (outbound vs inbound).
    static let redactionDirection = NSAttributedString.Key("OsaurusRedactionDirection")
}

enum RedactionHighlighter {

    /// Apply highlight attributes to every literal occurrence of
    /// each `highlights` key inside `storage`. Returns the list of
    /// painted ranges so callers can feed the hover controller
    /// without re-scanning.
    ///
    /// Empty `highlights` → no-op (no scan, no allocations beyond
    /// the empty return array). This is the hot path for the vast
    /// majority of chat windows that never trigger the filter.
    @discardableResult
    static func apply(
        on storage: NSTextStorage,
        highlights: [String: RedactionHighlight],
        accentColor: NSColor,
        a11yLabelBuilder: (RedactionHighlight) -> String
    ) -> [AppliedRedactionRange] {
        return applyInternal(
            on: storage,
            highlights: highlights,
            accentColor: accentColor,
            a11yLabelBuilder: a11yLabelBuilder,
            scanRange: NSRange(location: 0, length: storage.length),
            seedFromExistingAttributes: false
        )
    }

    /// Incremental variant: only scan the appended tail of the
    /// storage. Caller passes `appliedThrough` — the highest index
    /// painted on the previous run — and we extend the scan window
    /// back by the longest highlight key (so an original that
    /// straddles `appliedThrough` still resolves) and seed
    /// `paintedIndices` from the existing `.redactionPlaceholder`
    /// runs in that prefix.
    ///
    /// Returns the painted ranges from the SCAN WINDOW only — the
    /// caller is expected to keep its own running list and
    /// accumulate. This means a fresh layout pass should call
    /// `apply` (not `applyIncremental`), and only streaming deltas
    /// where text was appended (never mutated) should use this
    /// path.
    ///
    /// Pass `appliedThrough >= storage.length` to short-circuit:
    /// nothing was appended, nothing to scan.
    @discardableResult
    static func applyIncremental(
        on storage: NSTextStorage,
        appliedThrough: Int,
        highlights: [String: RedactionHighlight],
        accentColor: NSColor,
        a11yLabelBuilder: (RedactionHighlight) -> String
    ) -> [AppliedRedactionRange] {
        guard !highlights.isEmpty, storage.length > 0 else { return [] }
        if appliedThrough >= storage.length { return [] }

        let lookback = (highlights.keys.map { $0.count }.max() ?? 0)
        let start = max(0, appliedThrough - lookback)
        let length = storage.length - start
        guard length > 0 else { return [] }

        return applyInternal(
            on: storage,
            highlights: highlights,
            accentColor: accentColor,
            a11yLabelBuilder: a11yLabelBuilder,
            scanRange: NSRange(location: start, length: length),
            seedFromExistingAttributes: true
        )
    }

    private static func applyInternal(
        on storage: NSTextStorage,
        highlights: [String: RedactionHighlight],
        accentColor: NSColor,
        a11yLabelBuilder: (RedactionHighlight) -> String,
        scanRange: NSRange,
        seedFromExistingAttributes: Bool
    ) -> [AppliedRedactionRange] {
        guard !highlights.isEmpty, storage.length > 0 else { return [] }
        guard scanRange.length > 0 else { return [] }

        let sortedKeys = highlights.keys
            .filter { !$0.isEmpty }
            .sorted { $0.count > $1.count }
        guard !sortedKeys.isEmpty else { return [] }

        let underlineColor = accentColor.withAlphaComponent(0.7)

        var applied: [AppliedRedactionRange] = []
        let storageString = storage.string as NSString
        let paintedIndices = NSMutableIndexSet()

        if seedFromExistingAttributes {
            storage.enumerateAttribute(
                .redactionPlaceholder,
                in: scanRange,
                options: []
            ) { value, range, _ in
                if value != nil {
                    paintedIndices.add(in: range)
                }
            }
        }

        storage.beginEditing()
        for original in sortedKeys {
            guard let highlight = highlights[original] else { continue }
            let originalNS = original as NSString
            var searchRange = scanRange
            while searchRange.length > 0 {
                let found = storageString.range(
                    of: original,
                    options: [.literal],
                    range: searchRange
                )
                if found.location == NSNotFound { break }
                let candidate = NSRange(location: found.location, length: found.length)
                let overlaps = paintedIndices.intersects(
                    in: NSRange(location: candidate.location, length: candidate.length)
                )
                if !overlaps {
                    let attributes: [NSAttributedString.Key: Any] = [
                        .foregroundColor: accentColor,
                        .underlineStyle: NSUnderlineStyle.single.rawValue
                            | NSUnderlineStyle.patternDot.rawValue,
                        .underlineColor: underlineColor,
                        .redactionPlaceholder: highlight.placeholderToken,
                        .redactionDirection: highlight.direction.rawValue,
                        .toolTip: a11yLabelBuilder(highlight) as NSString,
                    ]
                    storage.addAttributes(attributes, range: candidate)
                    paintedIndices.add(
                        in: NSRange(location: candidate.location, length: candidate.length)
                    )
                    applied.append(AppliedRedactionRange(range: candidate, highlight: highlight))
                }
                let nextLocation = found.location + max(found.length, originalNS.length, 1)
                if nextLocation >= scanRange.upperBound { break }
                searchRange = NSRange(
                    location: nextLocation,
                    length: scanRange.upperBound - nextLocation
                )
            }
        }
        storage.endEditing()
        return applied
    }
}
