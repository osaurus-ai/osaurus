//
//  RedactionPreviewBuilder.swift
//  osaurus / PrivacyFilter
//
//  Builds the "what we'll actually send to the cloud" payload used by
//  the review sheet's right-hand context pane. Given the user's
//  original `containingText` plus the (original, placeholder) pairs
//  the engine produced for that segment, produces:
//
//    • A `scrubbed` string where every approved original has been
//      replaced by its placeholder token (`[PHONE_1]`, `[EMAIL_1]`,
//      etc.) — verbatim what the wire would carry.
//    • A `highlights` dict keyed by placeholder string, with the
//      ORIGINAL stored in `placeholderToken` and `direction = .preview`
//      so the hover controller can flip its tooltip copy (placeholder
//      hover -> show original) without a parallel "reveal" table.
//
//  Substitution rules mirror `RedactionHighlighter`:
//    • Case-sensitive `.literal` substring match.
//    • Longest original first so a redaction whose original is a
//      substring of another doesn't get partially replaced.
//    • Empty originals / placeholders are skipped defensively so a
//      malformed payload can't infinite-loop the substitution.
//

import Foundation

enum RedactionPreviewBuilder {

    /// One `(original, placeholder)` pair from a session redaction
    /// map. Plain struct rather than a tuple so call sites can name
    /// the fields and the longest-first sort stays readable.
    struct Pair: Equatable {
        let original: String
        let placeholder: String
    }

    struct Output: Equatable {
        /// `text` with every approved original swapped for its
        /// placeholder. Same length-or-shorter than the input only
        /// when the placeholder is shorter than the original; not
        /// otherwise guaranteed (a 7-char "Alice" -> 10-char
        /// "[PERSON_1]" makes the preview longer).
        let scrubbed: String
        /// Dict the hover machinery consumes. Key is the placeholder
        /// substring to scan for in `scrubbed`; value's
        /// `placeholderToken` is the ORIGINAL the tooltip should
        /// reveal, and `direction` is `.preview`.
        let highlights: [String: RedactionHighlight]
    }

    /// Build the scrubbed preview + highlights for `text`. Pairs
    /// whose `original` doesn't actually appear in `text` are
    /// silently dropped so the highlights dict can't list dead
    /// placeholders (which would produce empty tooltips and confuse
    /// the user).
    static func build(text: String, pairs: [Pair]) -> Output {
        guard !text.isEmpty else {
            return Output(scrubbed: "", highlights: [:])
        }
        // Dedup by original — duplicate pairs from different
        // detection segments must not produce two replace passes.
        var seen = Set<String>()
        let sanitized =
            pairs
            .filter { !$0.original.isEmpty && !$0.placeholder.isEmpty }
            .filter { seen.insert($0.original).inserted }
            // Longest original first so "Alice Smith" wins against
            // "Alice"; the swap-in placeholder protects the inner
            // characters from a later pass (placeholders contain
            // bracket characters not present in normal originals).
            .sorted { $0.original.count > $1.original.count }

        var scrubbed = text
        var highlights: [String: RedactionHighlight] = [:]
        for pair in sanitized {
            let replaced = scrubbed.replacingOccurrences(
                of: pair.original,
                with: pair.placeholder,
                options: [.literal]
            )
            if replaced != scrubbed {
                highlights[pair.placeholder] = RedactionHighlight(
                    placeholderToken: pair.original,
                    direction: .preview
                )
                scrubbed = replaced
            }
        }
        return Output(scrubbed: scrubbed, highlights: highlights)
    }
}
