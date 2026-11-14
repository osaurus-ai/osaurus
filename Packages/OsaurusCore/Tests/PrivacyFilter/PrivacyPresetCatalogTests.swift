//
//  PrivacyPresetCatalogTests.swift
//  osaurus / PrivacyFilter Tests
//
//  Table-driven contract for `PrivacyRulePresets.all`. Every preset
//  must compile through `safeCompile`, hit its own `sample` (and pass
//  its validator on the redacted token), miss its `counterexample`,
//  carry a real ISO region code, and have an `en` title/description.
//  A dropped country or a broken checksum fails here, not in a user's
//  review sheet.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("PrivacyPresetCatalog")
struct PrivacyPresetCatalogTests {
    private typealias Presets = PrivacyRulePresets

    private func detect(_ text: String, preset: Presets.Preset) -> [RegexEntityDetector.Match] {
        var config = PrivacyFilterConfiguration()
        config.builtinPatternEnabled = [.phone: false, .email: false, .url: false, .accountNumber: false]
        config.presetRules = [preset.id: true]
        let ruleset = RegexEntityDetector.EffectiveRuleSet.build(from: config)
        return RegexEntityDetector.detect(in: text, ruleset: ruleset)
    }

    @Test func idsAreUnique() {
        var seen: Set<String> = []
        for preset in Presets.all {
            #expect(!seen.contains(preset.id), "duplicate preset id \(preset.id)")
            seen.insert(preset.id)
        }
        #expect(Presets.all.count > 150)
    }

    @Test func regionCodesAreISO() {
        let iso = Set(Presets.allISORegionCodes)
        for preset in Presets.all {
            guard let region = preset.regionCode else { continue }
            #expect(iso.contains(region), "\(preset.id) has unknown region \(region)")
        }
    }

    @Test func everyPatternCompilesSafely() {
        for preset in Presets.all {
            switch RegexEntityDetector.safeCompile(preset.pattern) {
            case .success:
                break
            case .failure(let error):
                Issue.record("\(preset.id) failed to compile: \(error)")
            }
        }
    }

    @Test func everySampleIsDetected() {
        for preset in Presets.all {
            let hits = detect(preset.sample, preset: preset)
            #expect(!hits.isEmpty, "\(preset.id) does not match its own sample '\(preset.sample)'")
            if let hit = hits.first {
                #expect(hit.category == preset.category, "\(preset.id) category mismatch")
                if let validator = preset.validator {
                    #expect(validator(hit.original), "\(preset.id) sample fails its validator on '\(hit.original)'")
                }
                // Keyword-anchored presets must leave the keyword
                // visible and redact only the value.
                if preset.pattern.contains(Presets.anchorGap) {
                    #expect(
                        hit.original.count < preset.sample.count,
                        "\(preset.id) redacted the whole anchored sample '\(hit.original)'"
                    )
                }
            }
        }
    }

    @Test func everyCounterexampleIsRejected() {
        for preset in Presets.all {
            guard let counter = preset.counterexample else { continue }
            let hits = detect(counter, preset: preset)
            #expect(hits.isEmpty, "\(preset.id) matched its counterexample '\(counter)' → \(hits.map(\.original))")
        }
    }

    @Test func validatedPresetsHaveValidators() {
        for preset in Presets.all where preset.tier == .validated {
            #expect(preset.validator != nil, "\(preset.id) is Tier 1 but has no validator")
        }
    }

    @Test func genericFallbacksAreGlobalAndAutoEnabled() {
        for preset in Presets.all where preset.tier == .generic {
            #expect(preset.regionCode == nil, "\(preset.id) generic fallback must be Global")
            #expect(preset.autoEnable == .anyRegion, "\(preset.id) generic fallback must auto-enable")
        }
    }

    /// The set of regions with country-specific presets. Dropping a
    /// country from the catalogue must be a deliberate change here.
    @Test func specificCoverageMatchesExpectedRegions() {
        let expected: Set<String> = [
            // Americas
            "US", "CA", "MX", "BR", "AR", "CL", "CO", "PE", "EC", "UY", "VE", "GT", "CR", "PA", "DO", "BO",
            "PY",
            // Europe (west / north / south)
            "GB", "IE", "FR", "DE", "NL", "BE", "LU", "CH", "AT", "LI", "ES", "PT", "IT", "MT", "CY", "GR",
            "SE", "NO", "DK", "FI", "IS",
            // Europe (east / Balkans / Caucasus)
            "EE", "LV", "LT", "PL", "CZ", "SK", "HU", "SI", "HR", "RS", "BA", "ME", "MK", "AL", "BG", "RO",
            "MD", "UA", "BY", "RU", "TR", "GE", "AM", "AZ",
            // Asia-Pacific
            "IN", "PK", "BD", "LK", "NP", "CN", "HK", "MO", "TW", "JP", "KR", "MN", "SG", "MY", "ID", "TH",
            "PH", "VN", "KH", "LA", "MM", "BN", "AU", "NZ", "FJ", "PG", "KZ", "UZ", "KG", "TJ", "TM",
            // Middle East / Africa
            "IL", "SA", "AE", "QA", "KW", "BH", "OM", "JO", "LB", "IQ", "IR", "EG", "MA", "DZ", "TN", "LY",
            "SD", "ZA", "NG", "KE", "GH", "ET", "TZ", "UG", "RW", "ZM", "ZW", "MW", "MZ", "AO", "CM", "CI",
            "SN", "BW", "NA", "MU",
        ]
        let actual = Set(Presets.all.compactMap(\.regionCode))
        #expect(
            actual == expected,
            "missing: \(expected.subtracting(actual).sorted()); extra: \(actual.subtracting(expected).sorted())"
        )
        for region in expected {
            #expect(Presets.hasSpecificCoverage(region))
        }
        // Every ISO region is still coverable through the Global generics.
        #expect(!Presets.defaultPresetRules(forRegions: ["AQ"]).isEmpty)
    }

    @Test func defaultPresetRulesSeedRegionAndGlobal() {
        let de = Presets.defaultPresetRules(forRegions: ["DE"])
        #expect(de["de.steuerId"] == true)
        #expect(de["iban"] == true)
        #expect(de["euVAT"] == true)
        #expect(de["generic.passport"] == true)
        #expect(de["us.ssn"] == nil)
        #expect(de["awsKey"] == nil, "secrets stay opt-in")

        let us = Presets.defaultPresetRules(forRegions: ["US"])
        #expect(us["us.ssn"] == true)
        #expect(us["iban"] == nil)
        #expect(us["euVAT"] == nil)

        let both = Presets.defaultPresetRules(forRegions: ["us", "JP"])
        #expect(both["us.ssn"] == true)
        #expect(both["jp.myNumber"] == true)

        #expect(Presets.defaultPresetRules(forRegions: []).isEmpty)
    }

    @Test func regionHelpers() {
        #expect(Presets.regionFlag("US") == "🇺🇸")
        #expect(Presets.regionFlag("de") == "🇩🇪")
        #expect(Presets.regionFlag("1A") == "")
        #expect(Presets.regionDisplayName("DE", locale: Locale(identifier: "en_US")) == "Germany")
        #expect(Presets.allISORegionCodes.contains("US"))
        #expect(!Presets.allISORegionCodes.contains("001"))
        #expect(!Presets.allISORegionCodes.contains("ZZ"))
        #expect(Presets.presets(in: "GB").count >= 5)
        #expect(Presets.preset(id: "us.ssn")?.regionCode == "US")
    }

    /// Source-tree catalog (see `PrivacyLocalizationTests.catalogURL`
    /// for why `Bundle.module` can't be used under `xcodebuild test`).
    private static func catalogURL() -> URL? {
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()  // PrivacyFilter/
        cursor.deleteLastPathComponent()  // Tests/
        let catalog =
            cursor.deletingLastPathComponent()  // OsaurusCore/
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("Localizable.xcstrings")
        return FileManager.default.fileExists(atPath: catalog.path) ? catalog : nil
    }

    @Test func everyPresetHasEnglishStrings() throws {
        let url = try #require(Self.catalogURL())
        let data = try Data(contentsOf: url)
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(root["strings"] as? [String: Any])
        func en(_ key: String) -> String? {
            guard let entry = strings[key] as? [String: Any],
                let locs = entry["localizations"] as? [String: Any],
                let en = locs["en"] as? [String: Any],
                let unit = en["stringUnit"] as? [String: Any]
            else { return nil }
            return unit["value"] as? String
        }
        for preset in Presets.all {
            #expect(en(preset.titleKey) == preset.name, "missing/mismatched en title for \(preset.id)")
            #expect(en(preset.descriptionKey) == preset.summary, "missing/mismatched en description for \(preset.id)")
        }
        for tier in [Presets.Tier.validated, .anchored, .generic] {
            #expect(en(tier.localizationKey) != nil, "missing tier string \(tier.rawValue)")
        }
    }
}
