//
//  RegexEntityDetectorTests.swift
//  osaurus / PrivacyFilter Tests
//
//  Locks in the regex safety-net coverage. The on-device classifier
//  empirically misses bare 10-digit phone numbers, lowercase-context
//  PII, and obvious patterns the user has formatted unambiguously
//  (emails, URLs, SSNs, credit cards). Recall in these categories is
//  a hard requirement for the privacy filter to be useful, so we
//  pin the regex layer's behavior here.
//

import Testing
@testable import OsaurusCore

@Suite("RegexEntityDetector")
struct RegexEntityDetectorTests {

    // MARK: - The headline case: bare 10-digit phone the model misses

    @Test func detectsBareTenDigitPhone() {
        let text = "my name is Terence and my phone number is 9492380232"
        let matches = RegexEntityDetector.detect(in: text)
        let phones = matches.filter { $0.category == .phone }
        #expect(phones.count == 1)
        #expect(phones.first?.original == "9492380232")
    }

    @Test func detectsDashSeparatedPhone() {
        let text = "Call me at 949-238-0232 tonight."
        let phones = RegexEntityDetector.detect(in: text).filter { $0.category == .phone }
        #expect(phones.first?.original == "949-238-0232")
    }

    @Test func detectsParenthesizedPhone() {
        let text = "Office: (415) 555-1234 ext 99"
        let phones = RegexEntityDetector.detect(in: text).filter { $0.category == .phone }
        #expect(phones.first?.original == "(415) 555-1234")
    }

    @Test func detectsCountryCodePhone() {
        let text = "Reach me at +1 415 555 1234."
        let phones = RegexEntityDetector.detect(in: text).filter { $0.category == .phone }
        #expect(phones.first?.original.contains("415 555 1234") == true)
    }

    // MARK: - Email / URL

    @Test func detectsEmailInLowercaseContext() {
        let text = "ping me: alice@example.com whenever"
        let emails = RegexEntityDetector.detect(in: text).filter { $0.category == .email }
        #expect(emails.first?.original == "alice@example.com")
    }

    @Test func detectsUrlAndStopsBeforeTrailingPunctuation() {
        let text = "Docs are at https://example.com/path?q=1, see attached."
        let urls = RegexEntityDetector.detect(in: text).filter { $0.category == .url }
        #expect(urls.first?.original == "https://example.com/path?q=1")
    }

    // MARK: - International phone

    @Test func detectsInternationalPhoneFormats() {
        let cases: [(String, String)] = [
            ("UK mobile +44 7911 123456 please", "+44 7911 123456"),
            ("FR: +33 6 12 34 56 78.", "+33 6 12 34 56 78"),
            ("DE +49 (0)30 901820 office", "+49 (0)30 901820"),
            ("dial 0049 30 901820 from abroad", "0049 30 901820"),
            ("IN +91-98765-43210", "+91-98765-43210"),
            ("UK 07911 123456 mobile", "07911 123456"),
            ("DE mobile 0151 23456789 bitte", "0151 23456789"),
            ("FR 06 12 34 56 78 portable", "06 12 34 56 78"),
            ("AU 0412 345 678 mobile", "0412 345 678"),
            ("JP 03-1234-5678 desk", "03-1234-5678"),
            ("ZA 081 234 5678 cell", "081 234 5678"),
        ]
        for (text, expected) in cases {
            let phones = RegexEntityDetector.detect(in: text).filter { $0.category == .phone }
            #expect(phones.map(\.original) == [expected], "\(text) → \(phones.map(\.original))")
        }
    }

    @Test func internationalPhoneNegatives() {
        let cases = [
            "released 2024-05-17 at noon",  // ISO date
            "version 10.15.7 shipped",  // version string
            "pi is 0.123456789 roughly",  // decimal
            "in 1999 and 2001",  // years
            "C+1234567 is a type",  // + glued to a word
            "SSN 123-45-6789 is not a phone",  // SSN shape (9 digits)
            "Card 4111 1111 1111 1111 on file",  // card wins
        ]
        for text in cases {
            let phones = RegexEntityDetector.detect(in: text).filter { $0.category == .phone }
            #expect(phones.isEmpty, "\(text) → \(phones.map(\.original))")
        }
    }

    // MARK: - SSN (now the `us.ssn` preset)

    private func ssnRuleset() -> RegexEntityDetector.EffectiveRuleSet {
        var config = PrivacyFilterConfiguration()
        config.presetRules = ["us.ssn": true]
        return .build(from: config)
    }

    @Test func ssnIsNotABuiltinAnymore() {
        let text = "SSN: 123-45-6789 for the form"
        let hits = RegexEntityDetector.detect(in: text).filter { $0.category == .accountNumber }
        #expect(hits.isEmpty, "SSN must only fire through the us.ssn preset")
    }

    @Test func detectsValidSSNViaPreset() {
        let text = "SSN: 123-45-6789 for the form"
        let ssns = RegexEntityDetector.detect(in: text, ruleset: ssnRuleset())
            .filter { $0.category == .accountNumber }
        #expect(ssns.first?.original == "123-45-6789")
    }

    @Test func rejectsInvalidSSNBlocks() {
        // 000-12-3456 and 123-00-4567 and 123-45-0000 must all be rejected
        // by SSA's official invalid-prefix rules baked into the pattern.
        let cases = [
            "000-12-3456",
            "666-12-3456",
            "900-12-3456",  // 9xx is "ITIN-shaped" and unreachable by SSA
            "123-00-4567",
            "123-45-0000",
        ]
        for s in cases {
            let matches = RegexEntityDetector.detect(in: "Number is \(s).", ruleset: ssnRuleset())
                .filter { $0.category == .accountNumber && $0.original == s }
            #expect(matches.isEmpty, "should have rejected pseudo-SSN \(s)")
        }
    }

    // MARK: - Preset validators + capture groups

    @Test func presetValidatorRejectsBadChecksum() {
        var config = PrivacyFilterConfiguration()
        config.presetRules = ["nl.bsn": true]
        let ruleset = RegexEntityDetector.EffectiveRuleSet.build(from: config)
        let good = RegexEntityDetector.detect(in: "BSN 111222333 ok", ruleset: ruleset)
        let bad = RegexEntityDetector.detect(in: "BSN 123456789 nope", ruleset: ruleset)
        #expect(good.map(\.original) == ["111222333"])
        #expect(bad.isEmpty)
    }

    @Test func anchoredPresetRedactsOnlyTheValue() {
        var config = PrivacyFilterConfiguration()
        config.presetRules = ["gb.sortCode": true]
        let ruleset = RegexEntityDetector.EffectiveRuleSet.build(from: config)
        let hits = RegexEntityDetector.detect(in: "Sort code: 12-34-56 and account", ruleset: ruleset)
        #expect(hits.map(\.original) == ["12-34-56"])
    }

    @Test func validatedPresetOutranksGenericOnSameSpan() {
        // The Tier-1 Croatian OIB (bare 11 digits, ISO 7064) and the
        // Tier-3 generic "ID number: …" fallback both land on the same
        // 11-digit span. Exactly one match survives and it is the
        // checksum-validated one.
        var config = PrivacyFilterConfiguration()
        config.builtinPatternEnabled = [.phone: false, .email: false, .url: false, .accountNumber: false]
        config.presetRules = ["hr.oib": true, "generic.nationalID": true]
        let ruleset = RegexEntityDetector.EffectiveRuleSet.build(from: config)
        let hits = RegexEntityDetector.detect(in: "ID number: 69435151530", ruleset: ruleset)
        #expect(hits.count == 1)
        #expect(hits.first?.validated == true)
        #expect(hits.first?.original == "69435151530")

        // Sanity: the generic alone does fire on that text.
        config.presetRules = ["generic.nationalID": true]
        let genericOnly = RegexEntityDetector.detect(in: "ID number: 69435151530", ruleset: .build(from: config))
        #expect(genericOnly.map(\.original) == ["69435151530"])
        #expect(genericOnly.first?.validated == false)
    }

    // MARK: - Credit card (Luhn-gated)

    @Test func detectsValidCreditCardWithLuhn() {
        // Visa test card, passes Luhn.
        let text = "Card: 4111 1111 1111 1111 (expires 12/29)"
        let cards = RegexEntityDetector.detect(in: text).filter { $0.category == .accountNumber }
        #expect(cards.contains { $0.original == "4111 1111 1111 1111" })
    }

    @Test func rejectsRandomDigitRunFailingLuhn() {
        // 16 digits but bad checksum — must not be flagged as a card.
        let text = "Order ID 1234567890123456"
        let cards = RegexEntityDetector.detect(in: text).filter { $0.category == .accountNumber }
        #expect(cards.isEmpty)
    }

    // MARK: - Overlap resolution

    @Test func overlapPrefersLongerSpan() {
        // The phone regex could conceivably match a prefix of an
        // SSN-shaped string; the merge keeps the longer span. We
        // verify the resolver picks one rather than emitting two.
        let text = "Call 415-555-1234 right now."
        let matches = RegexEntityDetector.detect(in: text)
        let overlapping = matches.filter { $0.range.lowerBound < text.endIndex }
        let phoneCount = overlapping.filter { $0.category == .phone }.count
        let acctCount = overlapping.filter { $0.category == .accountNumber }.count
        #expect(phoneCount == 1)
        #expect(acctCount == 0)
    }
}
