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
//  Both the load (`RampartPII(directory:)` evals the weights) and every
//  `detect` forward pass are MLX *GPU producers* on the shared Metal
//  device, so they must hold `MetalGate` — unserialized they race a
//  concurrent generation's decode on the Metal command queue and abort
//  in the driver.
//

import Foundation
import RampartPII

actor RampartPrivacyDetector {
    private var model: RampartPII?
    private var loadedDirectory: URL?

    /// Load the model from a bundle directory containing
    /// `model.safetensors`, `config.json`, and `vocab.txt`. No-op when
    /// already loaded from the same directory.
    func loadIfNeeded(bundle directory: URL) async throws {
        if let loadedDirectory, loadedDirectory == directory, model != nil { return }
        await MetalGate.shared.enterPIIDetection()
        do {
            model = try RampartPII(directory: directory)
            await MetalGate.shared.exitPIIDetection()
        } catch {
            await MetalGate.shared.exitPIIDetection()
            throw error
        }
        loadedDirectory = directory
    }

    var isLoaded: Bool { model != nil }

    /// Model NER spans mapped into the pipeline's `EntityCategory` space.
    /// Returns `[]` when the model isn't loaded. Rampart character offsets
    /// are converted to `String.Index` ranges (Rampart indexes by
    /// `Character`, matching `String.index(_:offsetBy:)`).
    func modelSpans(in text: String) async -> [(category: EntityCategory, range: Range<String.Index>)] {
        guard !text.isEmpty, let model else { return [] }
        // Hold the gate only across the forward pass; the span/index mapping
        // below is CPU-only string work.
        await MetalGate.shared.enterPIIDetection()
        let detected = model.detect(text)
        await MetalGate.shared.exitPIIDetection()
        var raw: [(category: EntityCategory, range: Range<String.Index>)] = []
        for span in detected {
            guard let category = Self.category(for: span.type) else { continue }
            guard
                let lo = text.index(
                    text.startIndex,
                    offsetBy: span.range.lowerBound,
                    limitedBy: text.endIndex
                ),
                let hi = text.index(
                    text.startIndex,
                    offsetBy: span.range.upperBound,
                    limitedBy: text.endIndex
                )
            else { continue }
            raw.append((category, lo ..< hi))
        }
        return Self.coalesce(raw, in: text)
    }

    /// Merge adjacent spans of the SAME category separated only by
    /// whitespace/punctuation into one span. Rampart emits a separate
    /// span per fine-grained type (e.g. GIVEN_NAME + SURNAME, or
    /// BUILDING_NUMBER + STREET_NAME + CITY + STATE + ZIP_CODE), which
    /// all collapse to one category here — without coalescing, "Jonathan
    /// Reyes" would mint two `[PERSON_*]` tokens and a street address
    /// five `[ADDR_*]` tokens. This makes the placeholder granularity
    /// match the OpenAI backend's single-span person/address output.
    static func coalesce(
        _ spans: [(category: EntityCategory, range: Range<String.Index>)],
        in text: String
    ) -> [(category: EntityCategory, range: Range<String.Index>)] {
        let sorted = spans.sorted { $0.range.lowerBound < $1.range.lowerBound }
        var out: [(category: EntityCategory, range: Range<String.Index>)] = []
        for span in sorted {
            if var last = out.last,
                last.category == span.category,
                last.range.upperBound <= span.range.lowerBound,
                text[last.range.upperBound ..< span.range.lowerBound]
                    .allSatisfy({ $0.isWhitespace || $0.isPunctuation })
            {
                last.range = last.range.lowerBound ..< span.range.upperBound
                out[out.count - 1] = last
            } else {
                out.append(span)
            }
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
