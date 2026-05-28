//
//  SendAnywayMLOnlyTests.swift
//  osaurus / PrivacyFilter Tests
//
//  Locks the H2 contract: when the user clicks "Send anyway" on an
//  ML-only entity (`person`, `address`, `date`, `secret`) the post-
//  scrub leak scan must not block the send. The regex catalog
//  doesn't include those categories, so `scanForLeaks` cannot see
//  them; the related guarantee is that the inline approved-original
//  check (applyOutbound) only fires for entities the user actually
//  approved. Together these mean: "Send anyway" on an ML-only
//  detection is non-blocking and the wire payload retains the
//  original (intentionally).
//
//  We exercise:
//    * `scanForLeaks` ignores ML-only originals (person/address)
//      because the regex catalog has no matching pattern.
//    * `scanForLeaks` with a non-empty `ignoreOriginals` set
//      omits explicitly-skipped regex entities, matching the
//      M5 fix that complements H2.
//    * The combination — a person name in a wire payload AFTER
//      the user opted into "Send anyway" produces no leak count.
//
//  We do NOT exercise the model-side approved-original check
//  (`applyOutbound` inline scan) here; it's covered indirectly
//  by `ApplyOutboundE2ETests` and the integration tests gated
//  on the on-device model.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Send anyway + ML-only entities")
struct SendAnywayMLOnlyTests {

    /// `person` is ML-only. Even a perfectly-formed name like
    /// "Jane Smith" sitting in a wire payload should produce zero
    /// leak counts — the regex layer doesn't (and shouldn't) try
    /// to recognise names. This is the core "Send anyway" guarantee
    /// for model-only categories.
    @Test func personName_inWirePayload_doesNotLeak() {
        let messages: [ChatMessage] = [
            ChatMessage(role: "user", content: "My name is Jane Smith.")
        ]
        let leaks = PrivacyFilterPipeline.scanForLeaks(
            in: messages,
            ruleset: .allBuiltins()
        )
        #expect(leaks.isEmpty, "person name must not trip the leak scanner")
    }

    /// `address` is similarly ML-only. A street address sitting in
    /// the payload should also produce no leak counts.
    @Test func address_inWirePayload_doesNotLeak() {
        let messages: [ChatMessage] = [
            ChatMessage(role: "user", content: "I live at 1234 Sunset Blvd, Apt 5.")
        ]
        let leaks = PrivacyFilterPipeline.scanForLeaks(
            in: messages,
            ruleset: .allBuiltins()
        )
        #expect(leaks.isEmpty)
    }

    /// `secret` is ML-only too — generic credential-shaped strings
    /// shouldn't pop up under the regex layer (we don't try to
    /// classify high-entropy strings without the model).
    @Test func secret_inWirePayload_doesNotLeak() {
        let messages: [ChatMessage] = [
            ChatMessage(role: "user", content: "The token is abc123xyz789.")
        ]
        let leaks = PrivacyFilterPipeline.scanForLeaks(
            in: messages,
            ruleset: .allBuiltins()
        )
        #expect(leaks.isEmpty)
    }

    /// "Send anyway" for a regex-detected entity: the M5 fix means
    /// `ignoreOriginals` carries the literal strings the user
    /// skipped, and the scan omits them from the count. If we did
    /// NOT pass them through, the user would see a "we blocked your
    /// send" error a millisecond after they told us to ship it.
    @Test func skippedRegexEntity_isIgnoredByLeakScan() {
        let phone = "415-555-1234"
        let messages: [ChatMessage] = [
            ChatMessage(role: "user", content: "Call me at \(phone).")
        ]
        let scanned = PrivacyFilterPipeline.scanForLeaks(
            in: messages,
            ruleset: .allBuiltins(),
            ignoreOriginals: [phone]
        )
        #expect(scanned[.phone] == nil, "skipped phone must not block the send")

        // Sanity: without `ignoreOriginals` the same input DOES trip.
        let baseline = PrivacyFilterPipeline.scanForLeaks(
            in: messages,
            ruleset: .allBuiltins()
        )
        #expect(baseline[.phone] == 1, "control case must still trip")
    }

    /// Mixed-category "Send anyway": user explicitly skipped the
    /// phone, the conversation also contains a person name (ML-only).
    /// Neither should produce a leak count. This is the canonical
    /// shape of a real "Send anyway" call.
    @Test func mixedSkipped_personAndPhone_doNotLeak() {
        let phone = "949-238-0232"
        let messages: [ChatMessage] = [
            ChatMessage(
                role: "user",
                content: "I'm Jane Smith and my phone is \(phone)."
            )
        ]
        let leaks = PrivacyFilterPipeline.scanForLeaks(
            in: messages,
            ruleset: .allBuiltins(),
            ignoreOriginals: [phone]
        )
        #expect(leaks.isEmpty, "person + skipped-phone both expected silent")
    }

    /// Negative control: with `ignoreOriginals` containing a
    /// DIFFERENT phone, the user's actual phone still trips. The
    /// fix is value-precise, not category-blanket — we can't lazily
    /// disable all phone detection just because the user once
    /// skipped one.
    @Test func ignoreOriginals_isValuePrecise_notCategoryWide() {
        let messages: [ChatMessage] = [
            ChatMessage(role: "user", content: "Call me at 415-555-9999.")
        ]
        let leaks = PrivacyFilterPipeline.scanForLeaks(
            in: messages,
            ruleset: .allBuiltins(),
            ignoreOriginals: ["949-238-0232"]
        )
        #expect(leaks[.phone] == 1, "ignoreOriginals must not blanket-suppress the category")
    }
}
