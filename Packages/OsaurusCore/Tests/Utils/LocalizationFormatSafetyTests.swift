//
//  LocalizationFormatSafetyTests.swift
//  osaurus / Utils Tests
//
//  Pins the format-specifier crash class behind production crash
//  APPLE-MACOS-16A: the zh-Hans translation of "%lld tools discovered via
//  %@." swapped the placeholders WITHOUT positional indices, so at render
//  time CFString formatted the Int argument with `%@` and dereferenced it
//  as an ObjC pointer — EXC_BAD_ACCESS at an address equal to the tool
//  count. Every translated value must consume each argument slot with the
//  same type the English key does, and must never reference a slot the
//  key doesn't provide.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Localization format-specifier safety")
struct LocalizationFormatSafetyTests {

    /// Locate `Localizable.xcstrings` in the source tree via `#filePath`
    /// (the raw catalog is not shipped in the compiled test bundle — see
    /// PrivacyLocalizationTests for the CI history).
    private static func catalogURL() -> URL? {
        let here = URL(fileURLWithPath: #filePath)
        var cursor = here.deletingLastPathComponent()  // Utils/
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
            let value: String?
        }
    }

    /// `(argument slot, normalized type)` for every printf-style specifier,
    /// resolving positional (`%2$@`) and sequential specifiers to slots the
    /// same way CFString does.
    private static func slotTypes(of format: String) -> [Int: Character] {
        // `%%` is a literal percent, not a specifier. The space flag is
        // deliberately excluded from the flag class: prose like "+25% gemessen"
        // would otherwise parse as a `%g` specifier, and no real specifier in
        // the catalog uses it.
        let cleaned = format.replacingOccurrences(of: "%%", with: "")
        let pattern =
            #"%(?:(\d+)\$)?[-+#0]*\d*(?:\.\d+)?(?:hh|h|ll|l|q|z|t|L)?([@dDiuUxXoOfeEgGaAFcCsSp])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [:] }
        let range = NSRange(cleaned.startIndex ..< cleaned.endIndex, in: cleaned)

        var slots: [Int: Character] = [:]
        var nextSequentialSlot = 1
        regex.enumerateMatches(in: cleaned, range: range) { match, _, _ in
            guard let match else { return }
            let slot: Int
            if match.range(at: 1).location != NSNotFound,
                let positionRange = Range(match.range(at: 1), in: cleaned),
                let position = Int(cleaned[positionRange])
            {
                slot = position
            } else {
                slot = nextSequentialSlot
                nextSequentialSlot += 1
            }
            guard let typeRange = Range(match.range(at: 2), in: cleaned),
                let rawType = cleaned[typeRange].first
            else { return }
            slots[slot] = normalize(rawType)
        }
        return slots
    }

    private static func normalize(_ type: Character) -> Character {
        switch type {
        case "d", "D", "i", "u", "U", "x", "X", "o", "O", "c", "C": return "d"
        case "f", "e", "E", "g", "G", "a", "A", "F": return "f"
        default: return type  // "@", "s", "S", "p"
        }
    }

    private static func translatedValues(in localization: Catalog.Localization) -> [String] {
        var values: [String] = []
        if let value = localization.stringUnit?.value {
            values.append(value)
        }
        for unit in (localization.variations?.plural ?? [:]).values {
            if let value = unit.stringUnit?.value {
                values.append(value)
            }
        }
        return values
    }

    @Test func everyTranslationConsumesArgumentSlotsWithTheKeysTypes() throws {
        let url = try #require(Self.catalogURL(), "Localizable.xcstrings not found in source tree")
        let catalog = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: url))

        var violations: [String] = []
        for (key, entry) in catalog.strings {
            // Interpolated keys ("%lld tools discovered via %@.") carry their
            // own specifiers. Semantic keys ("privacy.custom.editor.…") don't —
            // for those the English value defines the argument contract.
            var referenceSlots = Self.slotTypes(of: key)
            if referenceSlots.isEmpty,
                let english = entry.localizations?["en"],
                let englishValue = Self.translatedValues(in: english).first
            {
                referenceSlots = Self.slotTypes(of: englishValue)
            }
            let maxKeySlot = referenceSlots.keys.max() ?? 0
            for (language, localization) in entry.localizations ?? [:] {
                for value in Self.translatedValues(in: localization) {
                    let translationSlots = Self.slotTypes(of: value)
                    for (slot, type) in translationSlots {
                        if slot > maxKeySlot {
                            violations.append(
                                "[\(language)] \(key.debugDescription): translation "
                                    + "\(value.debugDescription) references argument \(slot) "
                                    + "but the key only provides \(maxKeySlot)"
                            )
                        } else if let keyType = referenceSlots[slot], keyType != type {
                            violations.append(
                                "[\(language)] \(key.debugDescription): translation "
                                    + "\(value.debugDescription) formats argument \(slot) as "
                                    + "'\(type)' but the key passes '\(keyType)' — formatting a "
                                    + "non-object as %@ dereferences it as an ObjC pointer"
                            )
                        }
                    }
                }
            }
        }
        let report = violations.joined(separator: "\n")
        #expect(
            violations.isEmpty,
            "Format-specifier type mismatches (crash class APPLE-MACOS-16A):\n\(report)"
        )
    }
}
