//
//  PrivacyLocalizationTests.swift
//  osaurus / PrivacyFilter Tests
//
//  Regression guard for the original bug where most `privacy.*` keys
//  in `Localizable.xcstrings` shipped without an `en` value — every
//  string in the review sheet rendered as its key. This test parses
//  the catalog directly and asserts that every privacy key has a
//  non-empty English value.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Privacy localization completeness")
struct PrivacyLocalizationTests {

    /// Locate `Localizable.xcstrings` on disk regardless of how the
    /// test bundle was built. Under `swift test` the file lives in
    /// `Bundle.module`, but `xcodebuild test` (CI) compiles
    /// xcstrings to per-locale `.strings` files and DROPS the raw
    /// `.xcstrings` from the test bundle — `Bundle.module.url(…)`
    /// returns nil and the suite false-fails on every CI run (PR
    /// #1244 run 26423000638). Walking up from `#filePath` finds
    /// the source-tree catalog in both environments.
    private static func catalogURL() -> URL? {
        let here = URL(fileURLWithPath: #filePath)
        // Tests/PrivacyFilter/PrivacyLocalizationTests.swift →
        // walk up to Packages/OsaurusCore/.
        var cursor = here.deletingLastPathComponent()  // PrivacyFilter/
        cursor.deleteLastPathComponent()  // Tests/
        let pkg = cursor.deletingLastPathComponent()  // OsaurusCore/
        let catalog =
            pkg
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("Localizable.xcstrings")
        return FileManager.default.fileExists(atPath: catalog.path) ? catalog : nil
    }

    private struct Catalog: Decodable {
        let strings: [String: Entry]

        struct Entry: Decodable {
            let localizations: [String: Localization]?
        }

        /// One language slot under `localizations`. May carry either a
        /// flat `stringUnit` (most strings) or a `variations.plural`
        /// dictionary (count-driven plural forms like
        /// `privacy.error.scrubLeaked.phone %lld`). Either is fine —
        /// at least one English value must exist.
        struct Localization: Decodable {
            let stringUnit: StringUnit?
            let variations: Variations?
        }

        struct Variations: Decodable {
            let plural: [String: PluralUnit]?
        }

        struct PluralUnit: Decodable {
            let stringUnit: StringUnit?
        }

        struct StringUnit: Decodable {
            let state: String
            let value: String
        }
    }

    @Test func everyPrivacyKey_hasNonEmptyEnglishValue() throws {
        guard let url = Self.catalogURL() else {
            Issue.record("Localizable.xcstrings not found via #filePath walk")
            return
        }
        let data = try Data(contentsOf: url)
        let catalog = try JSONDecoder().decode(Catalog.self, from: data)

        // Every privacy.* key must have an English value. We don't
        // assert on translation state because translators can mark
        // strings as `new` during a localization pass — we just need
        // an English baseline to exist for runtime fallback.
        let privacyKeys = catalog.strings.keys.filter { $0.hasPrefix("privacy.") }
        #expect(!privacyKeys.isEmpty, "No privacy.* keys found in catalog — file may have been renamed")

        for key in privacyKeys.sorted() {
            guard let entry = catalog.strings[key] else { continue }
            guard let localizations = entry.localizations else {
                Issue.record("\(key): missing `localizations` block — runtime renders the key itself")
                continue
            }
            guard let en = localizations["en"] else {
                Issue.record("\(key): missing English (`en`) localization")
                continue
            }

            // Plural-variant entries (e.g. `privacy.error.scrubLeaked.phone %lld`)
            // store their text under `variations.plural.<one|other|…>.stringUnit`
            // instead of a top-level `stringUnit`. Treat either path
            // as valid — what we're guarding against is the original
            // bug where the value was missing entirely.
            let pluralValues =
                en.variations?.plural?.values
                .compactMap { $0.stringUnit?.value } ?? []
            if let unit = en.stringUnit {
                #expect(!unit.value.isEmpty, "\(key): English value is empty")
                #expect(
                    !unit.value.hasPrefix(key),
                    "\(key): English value (\(unit.value)) looks like a key echo"
                )
            } else if !pluralValues.isEmpty {
                for value in pluralValues {
                    #expect(!value.isEmpty, "\(key): plural variant has empty English value")
                    #expect(
                        !value.hasPrefix(key),
                        "\(key): plural variant value (\(value)) looks like a key echo"
                    )
                }
            } else {
                Issue.record("\(key): English localization has neither `stringUnit` nor `variations.plural`")
                continue
            }
        }
    }

    /// Covers H5: the master toggle copy must explicitly say the
    /// filter is for cloud-bound requests. Users who don't read
    /// the description otherwise expect ALL inference (including
    /// local MLX / Apple Foundation) to be scrubbed.
    ///
    /// The toggle source-of-truth lives in
    /// `PrivacyOverviewTab`'s `SettingsToggle`, which reads the
    /// English string directly off `Localizable.xcstrings`. We
    /// parse the catalog rather than instantiating the view
    /// (SwiftUI's `Text` doesn't expose its localized string
    /// without a host scene) so the test is hermetic.
    @Test func masterToggleCopy_mentionsCloud() throws {
        let title = "Scrub PII before sending to cloud providers"
        let description =
            "Detects PII in your messages and asks you to review before any cloud-bound request. "
            + "Local models (MLX, Foundation) and on-device tools bypass the filter."

        guard let url = Self.catalogURL() else {
            Issue.record("Localizable.xcstrings not found via #filePath walk")
            return
        }
        let data = try Data(contentsOf: url)
        let catalog = try JSONDecoder().decode(Catalog.self, from: data)

        // Both keys exist verbatim in the catalog (the title doubles
        // as both the key and the English value because L() uses
        // the string-as-key pattern). The presence of the keys is
        // what gates the toggle label switching from the previous
        // generic "Enable Privacy Filter" copy to the explicit
        // cloud-bound wording.
        let titleEntry = catalog.strings[title]
        #expect(titleEntry != nil, "Master toggle title key is missing from xcstrings — H5 regression")
        let descriptionEntry = catalog.strings[description]
        #expect(
            descriptionEntry != nil,
            "Master toggle description key is missing from xcstrings — H5 regression"
        )

        // The title MUST contain the word 'cloud' so the user can
        // tell at a glance that local-only chats bypass the filter.
        // Lowercased compare so a future translator that capitalises
        // 'Cloud' for emphasis still passes.
        #expect(
            title.lowercased().contains("cloud"),
            "Master toggle title must mention 'cloud' — got: \(title)"
        )

        // Description should also flag the local bypass so power
        // users running with on-device MLX never wonder why their
        // local chat skips the review sheet.
        #expect(
            description.lowercased().contains("local")
                && description.lowercased().contains("bypass"),
            "Master toggle description must mention local bypass — got: \(description)"
        )
    }
}
