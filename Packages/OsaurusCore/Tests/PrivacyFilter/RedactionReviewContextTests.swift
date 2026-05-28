//
//  RedactionReviewContextTests.swift
//  osaurusTests
//
//  Covers the master/detail review sheet additions:
//    • `RedactionReviewState` auto-selects the first entity and
//      lets the right pane swap focus via `select(_:)`.
//    • `DetectedEntity.withContainingText(_:)` stamps the segment
//      onto a detection without mutating the original (immutable
//      struct contract).
//    • `RedactionPreviewBuilder.build(text:pairs:)` substitutes
//      approved originals for their placeholders (longest-first to
//      avoid clobbering), and stamps the highlights dict the
//      hover popover will read on the right pane.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
@Suite("Redaction Review Context")
struct RedactionReviewContextTests {

    private func detection(
        original: String,
        category: EntityCategory = .phone,
        index: Int = 1,
        approved: Bool = true,
        containingText: String? = nil
    ) -> DetectedEntity {
        DetectedEntity(
            category: category,
            original: original,
            // We don't exercise `range` here, so a degenerate same-index
            // pair is fine — the review sheet displays `original`, not
            // a substring of the segment.
            range: original.startIndex ..< original.endIndex,
            placeholder: Placeholder(category: category, index: index),
            approved: approved,
            containingText: containingText
        )
    }

    // MARK: - State

    @Test func state_autoSelectsFirstEntity() {
        let entities = [
            detection(original: "949-238-0232"),
            detection(original: "alice@example.com", category: .email),
        ]
        let state = RedactionReviewState(detections: entities, sessionId: "s")
        #expect(state.selectedEntityID == entities[0].id)
        #expect(state.selectedEntity?.original == "949-238-0232")
    }

    @Test func state_emptyDetections_hasNoSelection() {
        let state = RedactionReviewState(detections: [], sessionId: "s")
        #expect(state.selectedEntityID == nil)
        #expect(state.selectedEntity == nil)
    }

    @Test func state_select_movesFocusToTappedEntity() {
        let entities = [
            detection(original: "949-238-0232"),
            detection(original: "alice@example.com", category: .email),
        ]
        let state = RedactionReviewState(detections: entities, sessionId: "s")
        state.select(entities[1])
        #expect(state.selectedEntityID == entities[1].id)
        #expect(state.selectedEntity?.original == "alice@example.com")
    }

    @Test func state_select_isIdempotentOnSameEntity() {
        let entities = [detection(original: "949-238-0232")]
        let state = RedactionReviewState(detections: entities, sessionId: "s")
        let before = state.selectedEntityID
        state.select(entities[0])
        #expect(state.selectedEntityID == before)
    }

    // MARK: - DetectedEntity.withContainingText

    @Test func withContainingText_stampsSegmentOnFreshCopy() {
        let original = detection(original: "Alice", category: .person)
        let segment = "My name is Alice and I live nearby."
        let stamped = original.withContainingText(segment)
        #expect(stamped.containingText == segment)
        // Other fields preserved identically — the pipeline relies
        // on this when it re-wraps detections post-engine.
        #expect(stamped.id == original.id)
        #expect(stamped.original == original.original)
        #expect(stamped.placeholder.token == original.placeholder.token)
        #expect(stamped.approved == original.approved)
        // The source detection stays unchanged (immutable contract).
        #expect(original.containingText == nil)
    }

    // MARK: - RedactionPreviewBuilder

    @Test func previewBuilder_substitutesOriginalsForPlaceholders() {
        let pairs = [
            RedactionPreviewBuilder.Pair(original: "Alice", placeholder: "[PERSON_1]"),
            RedactionPreviewBuilder.Pair(original: "949-238-0232", placeholder: "[PHONE_1]"),
        ]
        let out = RedactionPreviewBuilder.build(
            text: "Tell Alice that 949-238-0232 is mine.",
            pairs: pairs
        )
        #expect(out.scrubbed == "Tell [PERSON_1] that [PHONE_1] is mine.")
        // Highlights dict carries the inverse mapping for the hover.
        #expect(out.highlights["[PERSON_1]"]?.placeholderToken == "Alice")
        #expect(out.highlights["[PERSON_1]"]?.direction == .preview)
        #expect(out.highlights["[PHONE_1]"]?.placeholderToken == "949-238-0232")
    }

    @Test func previewBuilder_longestOriginalFirstAvoidsClobbering() {
        // Without longest-first ordering, "Alice" would get replaced
        // inside "Alice Smith" before the longer pair could match —
        // the user would see `[PERSON_1] Smith` instead of `[PERSON_2]`
        // for the full name. The builder must defend against this.
        let pairs = [
            RedactionPreviewBuilder.Pair(original: "Alice", placeholder: "[PERSON_1]"),
            RedactionPreviewBuilder.Pair(original: "Alice Smith", placeholder: "[PERSON_2]"),
        ]
        let out = RedactionPreviewBuilder.build(
            text: "Met Alice Smith, then Alice.",
            pairs: pairs
        )
        #expect(out.scrubbed == "Met [PERSON_2], then [PERSON_1].")
        #expect(out.highlights["[PERSON_1]"]?.placeholderToken == "Alice")
        #expect(out.highlights["[PERSON_2]"]?.placeholderToken == "Alice Smith")
    }

    @Test func previewBuilder_dropsPairsThatDontAppearInText() {
        // A pair whose original isn't actually in the containing text
        // would still register a highlight if we trusted the input
        // blindly, producing a "dead" tooltip. Verify the builder
        // skips it.
        let pairs = [
            RedactionPreviewBuilder.Pair(original: "Alice", placeholder: "[PERSON_1]"),
            RedactionPreviewBuilder.Pair(original: "Bob", placeholder: "[PERSON_2]"),
        ]
        let out = RedactionPreviewBuilder.build(
            text: "Just Alice today.",
            pairs: pairs
        )
        #expect(out.scrubbed == "Just [PERSON_1] today.")
        #expect(out.highlights.keys.contains("[PERSON_1]"))
        #expect(!out.highlights.keys.contains("[PERSON_2]"))
    }

    @Test func previewBuilder_emptyInputs_areNoOps() {
        let empty = RedactionPreviewBuilder.build(text: "", pairs: [])
        #expect(empty.scrubbed.isEmpty)
        #expect(empty.highlights.isEmpty)

        let textOnly = RedactionPreviewBuilder.build(
            text: "Nothing to scrub",
            pairs: []
        )
        #expect(textOnly.scrubbed == "Nothing to scrub")
        #expect(textOnly.highlights.isEmpty)
    }

    @Test func previewBuilder_skipsEmptyPairs() {
        // A degenerate empty original would cause String.replacingOccurrences
        // to loop forever in some Foundations; defensive skip keeps
        // the builder safe even if upstream feeds us junk.
        let pairs = [
            RedactionPreviewBuilder.Pair(original: "", placeholder: "[PHONE_1]"),
            RedactionPreviewBuilder.Pair(original: "Alice", placeholder: ""),
            RedactionPreviewBuilder.Pair(original: "Bob", placeholder: "[PERSON_1]"),
        ]
        let out = RedactionPreviewBuilder.build(
            text: "Met Alice and Bob.",
            pairs: pairs
        )
        // Bob got substituted; the malformed Alice/empty pairs were
        // ignored so "Alice" stays verbatim in the preview.
        #expect(out.scrubbed == "Met Alice and [PERSON_1].")
        #expect(out.highlights.count == 1)
    }

    @Test func previewBuilder_dedupsRepeatedOriginals() {
        // Two detections of the same original (e.g. from different
        // segments) must not produce two replace passes — the second
        // pass would scan a string where "Alice" has already been
        // replaced and silently do nothing, but the highlight dict
        // would still be the same key. Dedup is a cleanliness check.
        let pairs = [
            RedactionPreviewBuilder.Pair(original: "Alice", placeholder: "[PERSON_1]"),
            RedactionPreviewBuilder.Pair(original: "Alice", placeholder: "[PERSON_1]"),
        ]
        let out = RedactionPreviewBuilder.build(
            text: "Hi Alice, bye Alice.",
            pairs: pairs
        )
        #expect(out.scrubbed == "Hi [PERSON_1], bye [PERSON_1].")
        #expect(out.highlights.count == 1)
    }
}
