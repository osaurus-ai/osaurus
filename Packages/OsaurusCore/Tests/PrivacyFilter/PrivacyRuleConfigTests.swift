//
//  PrivacyRuleConfigTests.swift
//  osaurus / PrivacyFilter Tests
//
//  Pin-down for the configurable-regex feature: validates the safe
//  compiler, the codec migration path, and the EffectiveRuleSet's
//  ability to combine built-ins + presets + custom rules.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("PrivacyRule configuration")
struct PrivacyRuleConfigTests {

    // MARK: - safeCompile

    @Test func safeCompile_rejectsEmptyPattern() {
        let result = RegexEntityDetector.safeCompile("")
        if case .failure(let err) = result {
            #expect(err == .empty)
        } else {
            Issue.record("Expected .empty, got \(result)")
        }
    }

    @Test func safeCompile_rejectsWhitespaceOnly() {
        let result = RegexEntityDetector.safeCompile("   \n  ")
        if case .failure(let err) = result {
            #expect(err == .empty)
        } else {
            Issue.record("Expected .empty for whitespace-only, got \(result)")
        }
    }

    @Test func safeCompile_rejectsOverLengthPattern() {
        let long = String(repeating: "a", count: RegexEntityDetector.maxPatternLength + 1)
        let result = RegexEntityDetector.safeCompile(long)
        if case .failure(.tooLong(let n)) = result {
            #expect(n == long.count)
        } else {
            Issue.record("Expected .tooLong, got \(result)")
        }
    }

    @Test func safeCompile_rejectsInvalidRegex() {
        // Unbalanced parenthesis — NSRegularExpression fails.
        let result = RegexEntityDetector.safeCompile("(unclosed")
        if case .failure(.invalid) = result {
            // expected
        } else {
            Issue.record("Expected .invalid for unbalanced regex, got \(result)")
        }
    }

    @Test func safeCompile_rejectsEmptyMatchingPattern() {
        // `.*` matches the empty string — would cause infinite-zero-
        // width enumerateMatches loops if accepted.
        let result = RegexEntityDetector.safeCompile(".*")
        if case .failure(.matchesEmpty) = result {
            // expected
        } else {
            Issue.record("Expected .matchesEmpty for .*, got \(result)")
        }
    }

    @Test func safeCompile_acceptsValidPattern() {
        let result = RegexEntityDetector.safeCompile(#"CUST-\d{6}"#)
        if case .success = result {
            // expected
        } else {
            Issue.record("Expected .success for valid pattern, got \(result)")
        }
    }

    // MARK: - EffectiveRuleSet construction

    @Test func ruleSet_defaultConfig_enablesAllBuiltins() {
        let config = PrivacyFilterConfiguration()
        let set = RegexEntityDetector.EffectiveRuleSet.build(from: config)
        // Built-in catalog has 5 entries today (email, url, ssn, cc, phone).
        // Don't pin to the exact count — just confirm they all made it through.
        #expect(set.builtins.count == RegexEntityDetector.Pattern.all.count)
        #expect(set.presets.isEmpty)
        #expect(set.customs.isEmpty)
    }

    @Test func ruleSet_disablingCategory_filtersBuiltins() {
        var config = PrivacyFilterConfiguration()
        config.builtinPatternEnabled[.phone] = false
        let set = RegexEntityDetector.EffectiveRuleSet.build(from: config)
        #expect(set.builtins.allSatisfy { $0.category != .phone })
        // Other categories still present.
        #expect(set.builtins.contains { $0.category == .email })
    }

    @Test func ruleSet_enabledPreset_addsCompiledRule() {
        var config = PrivacyFilterConfiguration()
        let presetId = PrivacyRulePresets.awsKey.id
        config.presetRules[presetId] = true
        let set = RegexEntityDetector.EffectiveRuleSet.build(from: config)
        #expect(set.presets.count == 1)
        #expect(set.presets.first?.category == .secret)
    }

    @Test func ruleSet_validCustomRule_isIncluded() {
        var config = PrivacyFilterConfiguration()
        config.customRules.append(
            PrivacyRule(
                name: "Internal ID",
                pattern: #"CUST-\d{6}"#,
                category: .secret,
                enabled: true
            )
        )
        let set = RegexEntityDetector.EffectiveRuleSet.build(from: config)
        #expect(set.customs.count == 1)
        #expect(set.customs.first?.category == .secret)
    }

    @Test func ruleSet_invalidCustomRule_isSilentlyDropped() {
        var config = PrivacyFilterConfiguration()
        config.customRules.append(
            PrivacyRule(
                name: "Bad",
                pattern: "(unclosed",
                category: .secret,
                enabled: true
            )
        )
        // Should not throw / crash — just silently drop the rule.
        let set = RegexEntityDetector.EffectiveRuleSet.build(from: config)
        #expect(set.customs.isEmpty)
    }

    @Test func ruleSet_disabledCustomRule_excluded() {
        var config = PrivacyFilterConfiguration()
        config.customRules.append(
            PrivacyRule(
                name: "Off",
                pattern: #"CUST-\d{6}"#,
                category: .secret,
                enabled: false
            )
        )
        let set = RegexEntityDetector.EffectiveRuleSet.build(from: config)
        #expect(set.customs.isEmpty)
    }

    // MARK: - Detection through EffectiveRuleSet

    @Test func detect_customRule_contributesHits() {
        var config = PrivacyFilterConfiguration()
        config.customRules.append(
            PrivacyRule(
                name: "Internal ID",
                pattern: #"CUST-\d{6}"#,
                category: .secret,
                enabled: true
            )
        )
        let set = RegexEntityDetector.EffectiveRuleSet.build(from: config)
        let matches = RegexEntityDetector.detect(in: "Ticket CUST-123456 needs review.", ruleset: set)
        let secrets = matches.filter { $0.category == .secret }
        #expect(secrets.count == 1)
        #expect(secrets.first?.original == "CUST-123456")
    }

    @Test func detect_disabledBuiltin_doesNotFire() {
        var config = PrivacyFilterConfiguration()
        config.builtinPatternEnabled[.email] = false
        let set = RegexEntityDetector.EffectiveRuleSet.build(from: config)
        let matches = RegexEntityDetector.detect(in: "Email me at alice@example.com", ruleset: set)
        #expect(matches.filter { $0.category == .email }.isEmpty)
    }

    @Test func detect_awsPreset_fires() {
        var config = PrivacyFilterConfiguration()
        config.presetRules[PrivacyRulePresets.awsKey.id] = true
        let set = RegexEntityDetector.EffectiveRuleSet.build(from: config)
        let matches = RegexEntityDetector.detect(
            in: "key: AKIAIOSFODNN7EXAMPLE found in env",
            ruleset: set
        )
        let secrets = matches.filter { $0.category == .secret }
        #expect(secrets.count == 1)
    }

    // MARK: - Codable round-trip + migration

    @Test func config_roundTrip_preservesAllFields() throws {
        let original = PrivacyFilterConfiguration(
            enabled: true,
            aiDetectionEnabled: true,
            providerOverrides: ["abc": false],
            skipCodeBlocks: false,
            alwaysApproveByDefault: true,
            builtinPatternEnabled: [.phone: false, .email: true, .url: true, .accountNumber: true],
            presetRules: [PrivacyRulePresets.iban.id: true],
            customRules: [
                PrivacyRule(
                    name: "Internal",
                    pattern: "CUST-[0-9]+",
                    category: .secret,
                    enabled: true,
                    caseSensitive: false,
                    placeholderLabel: "CUSTOMER"
                ),
                PrivacyRule(
                    name: "Codename",
                    pattern: "",
                    category: .secret,
                    kind: .builder,
                    builder: RuleBuilder(matchType: .exactWord, terms: ["Bluebird"])
                ),
            ]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PrivacyFilterConfiguration.self, from: data)
        #expect(decoded.enabled == original.enabled)
        #expect(decoded.aiDetectionEnabled == true)
        #expect(decoded.providerOverrides == original.providerOverrides)
        #expect(decoded.skipCodeBlocks == original.skipCodeBlocks)
        #expect(decoded.alwaysApproveByDefault == original.alwaysApproveByDefault)
        #expect(decoded.builtinPatternEnabled[.phone] == false)
        #expect(decoded.presetRules[PrivacyRulePresets.iban.id] == true)
        #expect(decoded.customRules.count == 2)

        let internalRule = decoded.customRules.first { $0.name == "Internal" }
        #expect(internalRule?.caseSensitive == false)
        #expect(internalRule?.placeholderLabel == "CUSTOMER")

        let codename = decoded.customRules.first { $0.name == "Codename" }
        #expect(codename?.kind == .builder)
        #expect(codename?.builder?.matchType == .exactWord)
        #expect(codename?.builder?.terms == ["Bluebird"])
        #expect(codename?.effectivePattern == #"\b(?:Bluebird)\b"#)
    }

    /// Old on-disk configs (pre-configurable-regex) didn't carry the
    /// new fields. The decoder must fill them with sensible defaults
    /// so existing users get the same behavior as before the feature
    /// landed.
    @Test func config_decodeLegacy_fillsBuiltinDefaults() throws {
        let legacyJSON = """
            {
              "enabled": true,
              "providerOverrides": {},
              "skipCodeBlocks": true,
              "confidenceThreshold": 0.5,
              "alwaysApproveByDefault": false
            }
            """
        let data = legacyJSON.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(PrivacyFilterConfiguration.self, from: data)
        #expect(decoded.enabled == true)
        // An older file predates the AI/regex split and carries no
        // `aiDetectionEnabled` key. Upgrading users had the model doing
        // detection, so the decoder default is `true` (the now-removed
        // `confidenceThreshold` key is harmlessly ignored). A FRESH
        // install instead gets `false` via `.default` (see below).
        #expect(decoded.aiDetectionEnabled == true)
        // Every built-in category present and defaulted to enabled.
        for category in PrivacyFilterConfiguration.builtinPatternCategories {
            #expect(
                decoded.isBuiltinPatternEnabled(category),
                "Legacy config should default \(category) built-in to enabled"
            )
        }
        #expect(decoded.presetRules.isEmpty)
        #expect(decoded.customRules.isEmpty)
    }

    /// A config that explicitly opts a category OUT must keep that
    /// choice through the round-trip — the default-fill only runs on
    /// missing keys, never on explicit `false` values.
    @Test func config_decodeLegacy_doesNotClobberExplicitFalse() throws {
        let partialJSON = """
            {
              "enabled": true,
              "providerOverrides": {},
              "skipCodeBlocks": true,
              "confidenceThreshold": 0.5,
              "alwaysApproveByDefault": false,
              "builtinPatternEnabled": { "phone": false }
            }
            """
        let data = partialJSON.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(PrivacyFilterConfiguration.self, from: data)
        #expect(decoded.isBuiltinPatternEnabled(.phone) == false)
        // Categories not in the on-disk map fill with `true`.
        #expect(decoded.isBuiltinPatternEnabled(.email) == true)
        #expect(decoded.isBuiltinPatternEnabled(.url) == true)
        #expect(decoded.isBuiltinPatternEnabled(.accountNumber) == true)
    }

    @Test func isPresetEnabled_missingKey_defaultsToFalse() {
        let config = PrivacyFilterConfiguration()
        #expect(config.isPresetEnabled(PrivacyRulePresets.awsKey.id) == false)
    }

    /// A fresh install (no on-disk file -> `.default`) runs regex-only:
    /// the ~2.8 GB model is opt-in, so AI detection starts OFF.
    @Test func config_default_aiDetectionDisabledForFreshInstall() {
        #expect(PrivacyFilterConfiguration.default.aiDetectionEnabled == false)
    }

    /// Old custom rules (pre rule-builder) carry only the regex fields.
    /// A single missing key must decode to defaults, never throw —
    /// otherwise `PrivacyFilterStore.load` would discard the whole
    /// config and reset every privacy setting.
    @Test func rule_decodeLegacy_fillsBuilderDefaults() throws {
        let legacyRuleJSON = """
            {
              "id": "5B3D2C1A-0000-0000-0000-000000000001",
              "name": "Old",
              "pattern": "CUST-[0-9]+",
              "category": "secret",
              "enabled": true
            }
            """
        let data = legacyRuleJSON.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(PrivacyRule.self, from: data)
        #expect(decoded.kind == .regex)
        #expect(decoded.caseSensitive == true)
        #expect(decoded.builder == nil)
        #expect(decoded.placeholderLabel == nil)
        #expect(decoded.effectivePattern == "CUST-[0-9]+")
    }
}
