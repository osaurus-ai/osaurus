//
//  RampartPrivacyDetector.swift
//  osaurus / PrivacyFilter
//
//  Lightweight on-device NER backend built on the Rampart PII model
//  (an ~37MB MLX BERT token classifier) as an alternative to the
//  multi-gigabyte OpenAI privacy filter. Produces the same model-span
//  shape the pipeline consumes via `PrivacyFilterEngine.modelSpans`:
//  `[(category: EntityCategory, range: Range<String.Index>)]`.
//
//  An `actor` so model load and every forward pass run off the main
//  thread (MLX inference must not block the UI — see app-hang guidance).
//

import Foundation
import RampartPII

actor RampartPrivacyDetector {
    private var model: RampartPII?
    private var loadedDirectory: URL?

    /// Load the model from a bundle directory containing
    /// `model.safetensors`, `config.json`, and `vocab.txt`. No-op when
    /// already loaded from the same directory.
    func loadIfNeeded(bundle directory: URL) throws {
        if let loadedDirectory, loadedDirectory == directory, model != nil { return }
        model = try RampartPII(directory: directory)
        loadedDirectory = directory
    }

    var isLoaded: Bool { model != nil }

    /// Model NER spans mapped into the pipeline's `EntityCategory` space.
    /// Returns `[]` when the model isn't loaded. Rampart character offsets
    /// are converted to `String.Index` ranges (Rampart indexes by
    /// `Character`, matching `String.index(_:offsetBy:)`).
    func modelSpans(in text: String) -> [(category: EntityCategory, range: Range<String.Index>)] {
        guard !text.isEmpty, let model else { return [] }
        var out: [(category: EntityCategory, range: Range<String.Index>)] = []
        for span in model.detect(text) {
            guard let category = Self.category(for: span.type) else { continue }
            guard
                let lo = text.index(
                    text.startIndex, offsetBy: span.range.lowerBound, limitedBy: text.endIndex),
                let hi = text.index(
                    text.startIndex, offsetBy: span.range.upperBound, limitedBy: text.endIndex)
            else { continue }
            out.append((category, lo..<hi))
        }
        return out
    }

    /// Map Rampart's 17 entity types onto the 8 pipeline categories.
    /// Rampart has no `date` category, so dates fall through to the
    /// regex layer / other backends.
    static func category(for rampartType: String) -> EntityCategory? {
        switch rampartType {
        case "GIVEN_NAME", "SURNAME":
            return .person
        case "EMAIL":
            return .email
        case "PHONE":
            return .phone
        case "URL":
            return .url
        case "BUILDING_NUMBER", "STREET_NAME", "SECONDARY_ADDRESS",
            "CITY", "STATE", "ZIP_CODE":
            return .address
        case "BANK_ACCOUNT", "ROUTING_NUMBER":
            return .accountNumber
        case "TAX_ID", "GOVERNMENT_ID", "PASSPORT", "DRIVERS_LICENSE":
            return .secret
        default:
            return nil
        }
    }
}
