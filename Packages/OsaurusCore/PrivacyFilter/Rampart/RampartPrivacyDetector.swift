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
        // Throws CancellationError if cancelled while waiting; no gate is
        // held on that path, so the exit pairing below is untouched.
        try await MetalGate.shared.enterPIIDetection()
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
        // below is CPU-only string work. A cancelled request skips detection
        // entirely (the scan's outcome no longer matters to anyone).
        do {
            try await MetalGate.shared.enterPIIDetection()
        } catch {
            return []
        }
        // Windowed inference: the tokenizer hard-truncates at 512 wordpiece
        // tokens, so a single pass over a large input silently drops every
        // entity past roughly the first paragraph (observed live: 17 person
        // spans detected in a 15,000-line file whose regex layer found
        // 3,000 emails). Windows split on line boundaries so single-line
        // entities never straddle a window; offsets are Character-based per
        // the RampartPII contract and remapped via each window's start.
        var raw: [(category: EntityCategory, range: Range<String.Index>)] = []
        for window in Self.windows(of: text) {
            if Task.isCancelled { break }
            let detected = model.detect(String(window.text))
            for span in detected {
                guard let category = Self.category(for: span.type) else { continue }
                guard
                    let lo = text.index(
                        window.start,
                        offsetBy: span.range.lowerBound,
                        limitedBy: text.endIndex
                    ),
                    let hi = text.index(
                        window.start,
                        offsetBy: span.range.upperBound,
                        limitedBy: text.endIndex
                    )
                else { continue }
                raw.append((category, lo ..< hi))
            }
        }
        await MetalGate.shared.exitPIIDetection()
        return Self.dropWordFragments(Self.coalesce(raw, in: text), in: text)
    }

    /// Drop spans that start or end inside a word. Rampart classifies
    /// wordpieces, so on identifier-heavy text (tool results, JSON, model
    /// ids) it can tag a fragment like "Ter" or "y" out of "Ternary" as a
    /// name. Substitution is substring-based by design (a partial miss
    /// would ship PII), so a one-letter fragment would then be redacted
    /// inside every word that contains it. A real entity is never a slice
    /// of a longer alphanumeric run.
    static func dropWordFragments(
        _ spans: [(category: EntityCategory, range: Range<String.Index>)],
        in text: String
    ) -> [(category: EntityCategory, range: Range<String.Index>)] {
        spans.filter { span in
            guard !span.range.isEmpty else { return false }
            let first = text[span.range.lowerBound]
            let last = text[text.index(before: span.range.upperBound)]
            if span.range.lowerBound > text.startIndex,
                isWordCharacter(first),
                isWordCharacter(text[text.index(before: span.range.lowerBound)])
            {
                return false
            }
            if span.range.upperBound < text.endIndex,
                isWordCharacter(last),
                isWordCharacter(text[span.range.upperBound])
            {
                return false
            }
            return true
        }
    }

    /// Letters and digits in space-delimited scripts. Scripts written
    /// without spaces (CJK, Thai) have no word boundary to test, so a
    /// name adjacent to other characters there is kept.
    private static func isWordCharacter(_ c: Character) -> Bool {
        guard c.isLetter || c.isNumber else { return false }
        return !c.unicodeScalars.contains { scalar in
            switch scalar.properties.generalCategory {
            case .otherLetter: return true  // CJK, Thai, Kana, Hangul syllables
            default: return false
            }
        }
    }

    /// Split `text` into line-aligned windows of at most ~`cap` characters
    /// (conservatively under the 512-wordpiece tokenizer cap for natural
    /// language). A single line longer than the cap becomes its own window
    /// and is truncated by the tokenizer as before. Windows are contiguous
    /// and cover the whole input.
    static func windows(
        of text: String,
        cap: Int = 1_500
    ) -> [(start: String.Index, text: Substring)] {
        guard text.count > cap else { return [(text.startIndex, text[...])] }
        var result: [(start: String.Index, text: Substring)] = []
        var windowStart = text.startIndex
        var cursor = text.startIndex
        var count = 0
        while cursor < text.endIndex {
            let lineEnd =
                text[cursor...].firstIndex(of: "\n").map { text.index(after: $0) }
                ?? text.endIndex
            let lineLength = text.distance(from: cursor, to: lineEnd)
            if count > 0, count + lineLength > cap {
                result.append((windowStart, text[windowStart ..< cursor]))
                windowStart = cursor
                count = 0
            }
            count += lineLength
            cursor = lineEnd
        }
        if windowStart < text.endIndex {
            result.append((windowStart, text[windowStart ..< text.endIndex]))
        }
        return result
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
