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

    // MARK: - SSN

    @Test func detectsValidSSN() {
        let text = "SSN: 123-45-6789 for the form"
        let ssns = RegexEntityDetector.detect(in: text).filter { $0.category == .accountNumber }
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
            let matches = RegexEntityDetector.detect(in: "Number is \(s).")
                .filter { $0.category == .accountNumber && $0.original == s }
            #expect(matches.isEmpty, "should have rejected pseudo-SSN \(s)")
        }
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
