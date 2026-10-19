//
//  SpokenNumberDetectorTests.swift
//  osaurus / PrivacyFilter Tests
//
//  Numbers read out digit by digit, as dictation and voice transcripts write
//  them, are flagged as the same numbers typed would be, and only those;
//  so are email addresses said aloud.
//

import Testing
@testable import OsaurusCore

@Suite("Spoken numbers")
struct SpokenNumberDetectorTests {

    @Test func aPhoneNumberReadOutIsAPhone() {
        let text = "text my brother at four one five five five five zero one five five tonight"
        let phones = RegexEntityDetector.detect(in: text).filter { $0.category == .phone }
        #expect(phones.map(\.original) == ["four one five five five five zero one five five"])
    }

    @Test func pausesOhAndDoublesStayOneNumber() {
        let text = "call four one five, five oh five, double two three four please"
        let phones = RegexEntityDetector.detect(in: text).filter { $0.category == .phone }
        #expect(phones.map(\.original) == ["four one five, five oh five, double two three four"])
    }

    @Test func aCardReadOutPassesLuhnOrNot() {
        let card = Array(repeating: "four one one one", count: 1) + Array(repeating: "one one one one", count: 3)
        let valid = "my card is " + card.joined(separator: " ")
        #expect(RegexEntityDetector.detect(in: valid).contains { $0.category == .accountNumber })
        // Sixteen digits that fail Luhn are no card, as typed digits would not be.
        let invalid = "the code is " + Array(repeating: "one two three four", count: 4).joined(separator: " ")
        #expect(!RegexEntityDetector.detect(in: invalid).contains { $0.category == .accountNumber })
    }

    @Test func ordinaryWordsAndShortRunsAreLeftAlone() {
        for text in [
            "one or two of us, maybe three",
            "we need five six seven chairs",
            "the score was one nine eight four",
            "oh one two three four five six",
        ] {
            #expect(RegexEntityDetector.detect(in: text).isEmpty, "\(text)")
        }
    }

    @Test func aSentenceEndBreaksTheRun() {
        // Five digits, a full stop, then five more: two short runs, no phone.
        let text = "it was four one five five five. zero one five five nine"
        #expect(RegexEntityDetector.detect(in: text).filter { $0.category == .phone }.isEmpty)
    }

    @Test func runsAreFoundWhereTheyAre() {
        let text = "Say Four One Five Five Five Five Zero One Five Five."
        let runs = SpokenDigitRuns.find(in: text)
        #expect(runs.map(\.digits) == ["4155550155"])
        #expect(runs.first.map { String(text[$0.range]) } == "Four One Five Five Five Five Zero One Five Five")
    }

    @Test func turnedOffTheBuiltinsFlagNothing() {
        let text = "four one five five five five zero one five five"
        let none = RegexEntityDetector.EffectiveRuleSet(builtins: [], presets: [], customs: [])
        #expect(RegexEntityDetector.detect(in: text, ruleset: none).isEmpty)
    }

    // MARK: Addresses said aloud

    @Test func anAddressSaidAloudIsAnEmail() {
        let text = "email it to john dot smith at example dot com please"
        let emails = RegexEntityDetector.detect(in: text).filter { $0.category == .email }
        #expect(emails.map(\.original) == ["john dot smith at example dot com"])
        #expect(SpokenEmails.find(in: text).map(\.address) == ["john.smith@example.com"])
    }

    @Test func separatorsAndCountryDomains() {
        let text = "Mary underscore Jones at mail dot company dash name dot co dot uk"
        #expect(SpokenEmails.find(in: text).map(\.address) == ["mary_jones@mail.company-name.co.uk"])
        #expect(RegexEntityDetector.detect(in: text).contains { $0.category == .email })
    }

    @Test func ordinaryAtIsNoAddress() {
        for text in [
            "I'll be at home",
            "meet me at noon dot",
            "we arrived at example dot",
            "she is at the office dot com stuff",
        ] {
            #expect(RegexEntityDetector.detect(in: text).isEmpty, "\(text)")
        }
    }

    @Test func withTheEmailRuleOffNoAddressIsFlagged() {
        let text = "john at example dot com"
        let phonesOnly = RegexEntityDetector.EffectiveRuleSet(
            builtins: RegexEntityDetector.Pattern.all.filter { $0.category == .phone },
            presets: [],
            customs: []
        )
        #expect(RegexEntityDetector.detect(in: text, ruleset: phonesOnly).isEmpty)
    }

    /// What the speech recogniser actually wrote on a call (2026-10-19):
    /// no "dot", the domain glued together.
    @Test func aGluedDomainInASentenceAboutEmailIsAnEmail() {
        let text = "Right a resignation email to john smith at examplecom"
        let emails = RegexEntityDetector.detect(in: text).filter { $0.category == .email }
        // The domain only: "john smith" is left to the name detection, unoverlapped.
        #expect(emails.map(\.original) == ["examplecom"])
        #expect(SpokenEmails.find(in: text).map(\.address) == ["smith@example.com"])
    }

    @Test func aWrittenDomainAfterASpokenNameIsAnEmail() {
        // As the phone sends it, the glued domain given its dot back.
        let text = "Right a resignation email to john smith at example.com"
        #expect(RegexEntityDetector.detect(in: text).filter { $0.category == .email }.map(\.original) == [
            "example.com"
        ])
        // A name said with "dot" needs no email word to count.
        let spoken = SpokenEmails.find(in: "it's john dot smith at example.com")
        #expect(spoken.map(\.address) == ["john.smith@example.com"])
    }

    @Test func aWebsiteOrAGluedWordOutsideEmailTalkIsLeftAlone() {
        for text in ["see the docs at example.com", "laughing at sitcom reruns", "email me at radio"] {
            #expect(RegexEntityDetector.detect(in: text).filter { $0.category == .email }.isEmpty, "\(text)")
        }
    }
}
