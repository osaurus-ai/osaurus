//
//  DecouplingAndBuilderTests.swift
//  osaurus / PrivacyFilter Tests
//
//  Pin-down for the "model is optional" decoupling and the no-regex
//  rule builder:
//   • regex-only detection runs (and never throws `.notLoaded`) with
//     `useModel: false`, i.e. with no on-device bundle in play
//   • `RuleBuilder.compile()` produces the expected (escaped) source
//     for each match-type bucket
//   • builder + raw custom rules honour the per-rule case flag
//   • custom placeholder labels mint distinct tokens and round-trip
//     through the inbound `StreamingUnscrubber`
//
//  None of these require the classifier bundle, so unlike
//  `EndToEndTests` they run unconditionally in CI.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("PrivacyFilter decoupling + rule builder")
struct DecouplingAndBuilderTests {

    // MARK: - Regex-only engine path (model optional)

    /// `useModel: false` must run the deterministic layer and return
    /// its hits WITHOUT ever loading — or throwing `.notLoaded` on —
    /// the model, even when the shared engine was never loaded.
    @MainActor
    @Test func detect_regexOnly_findsBuiltinWithoutModel() async throws {
        let map = RedactionMap(conversationID: UUID())
        let detections = try await PrivacyFilterEngine.shared.detect(
            in: "ping me at alice@example.com about it",
            map: map,
            skipCodeBlocks: true,
            useModel: false
        )
        #expect(detections.contains { $0.category == .email && $0.original == "alice@example.com" })
    }

    /// Regex-only on benign text returns cleanly (empty, no throw) —
    /// the absence of a model is not an error when AI detection is off.
    @MainActor
    @Test func detect_regexOnly_benignText_returnsEmptyNoThrow() async throws {
        let map = RedactionMap(conversationID: UUID())
        let detections = try await PrivacyFilterEngine.shared.detect(
            in: "the quick brown fox jumps over",
            map: map,
            skipCodeBlocks: true,
            useModel: false
        )
        #expect(detections.isEmpty)
    }

    // MARK: - RuleBuilder.compile()

    @Test func builder_exactWord_wrapsWordBoundaries() {
        let b = RuleBuilder(matchType: .exactWord, terms: ["Apollo"])
        #expect(b.compile() == #"\b(?:Apollo)\b"#)
    }

    @Test func builder_anyOfTerms_escapesAndAlternates() {
        // `.` and `+` are regex metacharacters and must be escaped so
        // the literal list matches literally, not as a pattern.
        let b = RuleBuilder(matchType: .anyOfTerms, terms: ["a.b", "c+d"])
        #expect(b.compile() == #"(?:a\.b|c\+d)"#)
    }

    @Test func builder_numberSequence_rangeAndOpenEnded() {
        #expect(
            RuleBuilder(matchType: .numberSequence, digitsMin: 4, digitsMax: 6).compile()
                == #"\b\d{4,6}\b"#
        )
        // digitsMax < digitsMin means "no upper bound".
        #expect(
            RuleBuilder(matchType: .numberSequence, digitsMin: 9, digitsMax: 0).compile()
                == #"\b\d{9,}\b"#
        )
    }

    @Test func builder_betweenMarkers_nonGreedy() {
        let b = RuleBuilder(matchType: .betweenMarkers, startMarker: "<<", endMarker: ">>")
        #expect(b.compile() == #"<<[\s\S]*?>>"#)
    }

    @Test func builder_insufficientInput_compilesNil() {
        #expect(RuleBuilder(matchType: .anyOfTerms, terms: []).compile() == nil)
        #expect(RuleBuilder(matchType: .anyOfTerms, terms: ["   "]).compile() == nil)
        #expect(RuleBuilder(matchType: .numberSequence, digitsMin: 0).compile() == nil)
        #expect(
            RuleBuilder(matchType: .betweenMarkers, startMarker: "", endMarker: ">>").compile()
                == nil
        )
    }

    @Test func effectivePattern_resolvesBuilderOrRaw() {
        let raw = PrivacyRule(name: "raw", pattern: "abc", category: .secret, kind: .regex)
        #expect(raw.effectivePattern == "abc")

        let built = PrivacyRule(
            name: "built",
            pattern: "",
            category: .secret,
            kind: .builder,
            builder: RuleBuilder(matchType: .exactWord, terms: ["Zed"])
        )
        #expect(built.effectivePattern == #"\b(?:Zed)\b"#)

        let empty = PrivacyRule(
            name: "empty",
            pattern: "",
            category: .secret,
            kind: .builder,
            builder: RuleBuilder(matchType: .anyOfTerms, terms: [])
        )
        #expect(empty.effectivePattern == nil)
    }

    // MARK: - Case sensitivity (builder + raw custom rules)

    @Test func builderRule_caseInsensitive_matchesAnyCase() {
        var config = PrivacyFilterConfiguration()
        config.customRules = [
            PrivacyRule(
                name: "Codename",
                pattern: "",
                category: .secret,
                kind: .builder,
                caseSensitive: false,
                builder: RuleBuilder(matchType: .exactWord, terms: ["Bluebird"])
            )
        ]
        let set = RegexEntityDetector.EffectiveRuleSet.build(from: config)
        let matches = RegexEntityDetector.detect(in: "the BLUEBIRD project", ruleset: set)
        #expect(matches.contains { $0.category == .secret && $0.original == "BLUEBIRD" })
    }

    @Test func builderRule_caseSensitive_skipsOtherCase() {
        var config = PrivacyFilterConfiguration()
        config.customRules = [
            PrivacyRule(
                name: "Codename",
                pattern: "",
                category: .secret,
                kind: .builder,
                caseSensitive: true,
                builder: RuleBuilder(matchType: .exactWord, terms: ["Bluebird"])
            )
        ]
        let set = RegexEntityDetector.EffectiveRuleSet.build(from: config)
        let matches = RegexEntityDetector.detect(in: "the BLUEBIRD project", ruleset: set)
        #expect(!matches.contains { $0.original == "BLUEBIRD" })
    }

    @Test func customRegexRule_caseInsensitive_matches() {
        var config = PrivacyFilterConfiguration()
        config.customRules = [
            PrivacyRule(
                name: "Tag",
                pattern: "secret-[0-9]+",
                category: .secret,
                caseSensitive: false
            )
        ]
        let set = RegexEntityDetector.EffectiveRuleSet.build(from: config)
        let matches = RegexEntityDetector.detect(in: "ref SECRET-42 here", ruleset: set)
        #expect(matches.contains { $0.original == "SECRET-42" })
    }

    // MARK: - Custom placeholder labels

    @Test func sanitizedLabel_filtersToUppercaseLetters() {
        #expect(PrivacyRule.sanitizedLabel("cust-1") == "CUST")
        #expect(PrivacyRule.sanitizedLabel("Customer ID") == "CUSTOMERID")
        #expect(PrivacyRule.sanitizedLabel("123") == nil)
        #expect(PrivacyRule.sanitizedLabel("") == nil)
        #expect(PrivacyRule.sanitizedLabel(nil) == nil)
    }

    @Test func intern_customLabel_usesLabelPrefix() async {
        let map = RedactionMap(conversationID: UUID())
        let p = await map.intern("ACME Corp", as: .secret, label: "CUSTOMER")
        #expect(p.token == "[CUSTOMER_1]")
    }

    /// Counters are keyed by the EFFECTIVE prefix, so two rules sharing
    /// a custom label across different categories still mint distinct
    /// tokens (no `[TAG_1]` collision) — the regression the prefix-keyed
    /// counter map fixes.
    @Test func intern_sameLabelDifferentCategories_noCollision() async {
        let map = RedactionMap(conversationID: UUID())
        let a = await map.intern("first", as: .secret, label: "TAG")
        let b = await map.intern("second", as: .person, label: "TAG")
        #expect(a.token == "[TAG_1]")
        #expect(b.token == "[TAG_2]")
        #expect(a.token != b.token)
    }

    /// The whole point of constraining labels to `[A-Z]+`: the minted
    /// token must survive the inbound restore path unchanged.
    @Test func customLabel_roundTripsThroughUnscrubber() async {
        let map = RedactionMap(conversationID: UUID())
        let p = await map.intern("ACME Corp", as: .secret, label: "CUSTOMER")
        #expect(p.token == "[CUSTOMER_1]")

        let unscrubber = await StreamingUnscrubber.make(for: map)
        var collected = ""
        collected += await unscrubber.push("Bill to [CUSTOMER_1] today.")
        collected += await unscrubber.flush()
        #expect(collected == "Bill to ACME Corp today.")
    }
}
