//
//  PostScrubInvariantTests.swift
//  osaurus / PrivacyFilter Tests
//
//  Pins the post-scrub invariant: after substitution, any remaining
//  regex-detectable PII must trip the leak guard and produce a
//  `PrivacyFilterPipelineError.scrubLeaked` instead of going to the
//  wire. We exercise the gate at the helper layer
//  (`PrivacyFilterPipeline.scanForLeaks`) plus the error-formatting
//  layer (`formatScrubLeaked`) — the full pipeline path requires the
//  on-device model and is covered indirectly by integration tests.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Post-scrub invariant")
struct PostScrubInvariantTests {

    // MARK: - scanForLeaks

    /// Phone number that survives the scrub pass triggers the leak
    /// guard. This is the canonical regression for the bug that
    /// motivated the invariant: model misses bare-digit phone numbers,
    /// substitution silently passes through, and unredacted PII
    /// reaches the cloud.
    @Test func scan_leakedPhone_returnsCount() {
        let messages: [ChatMessage] = [
            ChatMessage(role: "user", content: "Call me at 949-238-0232 today.")
        ]
        let leaks = PrivacyFilterPipeline.scanForLeaks(
            in: messages,
            ruleset: .allBuiltins()
        )
        #expect(leaks[.phone] == 1)
    }

    /// Multiple categories aggregate by category, not by raw count.
    @Test func scan_multipleCategories_aggregatesCounts() {
        let messages: [ChatMessage] = [
            ChatMessage(
                role: "user",
                content: "Email me at a@example.com or call 415-555-1234."
            ),
            ChatMessage(
                role: "user",
                content: "Backup contact: b@example.com."
            ),
        ]
        let leaks = PrivacyFilterPipeline.scanForLeaks(
            in: messages,
            ruleset: .allBuiltins()
        )
        #expect(leaks[.email] == 2)
        #expect(leaks[.phone] == 1)
    }

    /// Clean messages (or messages whose PII has been replaced by
    /// placeholders) leave the guard quiet. Placeholders like
    /// `[PHONE_1]` are deliberately shaped to NOT match the regex
    /// catalog — the brackets and prefix-underscore-digit form aren't
    /// digit runs, so the leak check is silent.
    @Test func scan_placeholders_doNotTriggerLeaks() {
        let messages: [ChatMessage] = [
            ChatMessage(role: "user", content: "Call me at [PHONE_1] today.")
        ]
        let leaks = PrivacyFilterPipeline.scanForLeaks(
            in: messages,
            ruleset: .allBuiltins()
        )
        #expect(leaks.isEmpty)
    }

    /// Turning off a built-in category in the config should silence
    /// BOTH the detection pass and the leak check. The settings panel
    /// promises this symmetry — if the user has explicitly said "stop
    /// flagging phones", we won't surprise them by blocking a send on
    /// a phone the model missed.
    @Test func scan_disabledCategory_doesNotLeak() {
        var config = PrivacyFilterConfiguration()
        config.builtinPatternEnabled[.phone] = false
        let ruleset = RegexEntityDetector.EffectiveRuleSet.build(from: config)

        let messages: [ChatMessage] = [
            ChatMessage(role: "user", content: "Call me at 949-238-0232 today.")
        ]
        let leaks = PrivacyFilterPipeline.scanForLeaks(
            in: messages,
            ruleset: ruleset
        )
        #expect(leaks[.phone] == nil)
    }

    /// System messages are skipped by `scrubbableTexts()` (they're
    /// app-set boilerplate, not user input). Confirm the leak scanner
    /// inherits that behavior.
    @Test func scan_systemMessages_skipped() {
        let messages: [ChatMessage] = [
            ChatMessage(role: "system", content: "Your phone is 949-238-0232."),
            ChatMessage(role: "user", content: "ok"),
        ]
        let leaks = PrivacyFilterPipeline.scanForLeaks(
            in: messages,
            ruleset: .allBuiltins()
        )
        #expect(leaks.isEmpty)
    }

    // MARK: - formatScrubLeaked

    /// One category. The formatter is localization-driven, so we
    /// can't assert on the exact English phrasing here (xcstrings
    /// runtime lookup doesn't fire under `swift test`). We DO assert
    /// the count and category identifier survive — they're the
    /// non-translated payload the user needs to act on.
    @Test func formatScrubLeaked_singleCategory_pluralForm() {
        let msg = PrivacyFilterPipelineError.formatScrubLeaked(
            categoryCounts: [.phone: 2]
        )
        #expect(msg.contains("2"))
        #expect(msg.lowercased().contains(L("privacy.category.phone").lowercased()))
    }

    /// Two categories — the formatter joins them with a localized
    /// conjunction. The exact word ("and") is English-locale-only;
    /// the test asserts both category identifiers are present in
    /// the rendered string regardless.
    @Test func formatScrubLeaked_twoCategories_includesBoth() {
        let msg = PrivacyFilterPipelineError.formatScrubLeaked(
            categoryCounts: [.phone: 1, .email: 1]
        )
        #expect(msg.lowercased().contains(L("privacy.category.phone").lowercased()))
        #expect(msg.lowercased().contains(L("privacy.category.email").lowercased()))
    }

    /// Whatever the categories, the value of a leaked entity never
    /// appears in the rendered error. We assert this with a fabricated
    /// raw PII string — the formatter is purely a category+count
    /// shape and shouldn't have any path to leak the value back.
    @Test func formatScrubLeaked_neverEchoesRawPII() {
        // Sanity: the formatter takes counts, not values, so the only
        // way the value could end up in the message is via a future
        // refactor that adds an argument for it. Lock that out.
        let msg = PrivacyFilterPipelineError.formatScrubLeaked(
            categoryCounts: [.phone: 1, .email: 1, .accountNumber: 1]
        )
        #expect(!msg.contains("949-238-0232"))
        #expect(!msg.contains("alice@example.com"))
    }

    /// `scrubLeaked` equality is value-based on the dictionary so the
    /// chat layer can pattern-match a specific case if it ever wants
    /// to vary the bubble text.
    @Test func scrubLeakedError_isEquatable() {
        let a = PrivacyFilterPipelineError.scrubLeaked(categoryCounts: [.phone: 1])
        let b = PrivacyFilterPipelineError.scrubLeaked(categoryCounts: [.phone: 1])
        let c = PrivacyFilterPipelineError.scrubLeaked(categoryCounts: [.phone: 2])
        #expect(a == b)
        #expect(a != c)
    }
}
