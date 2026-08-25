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
        // Windows run through the model in padded batches: one forward
        // pass per `batchSize` windows instead of one per window, which
        // amortizes the per-pass eval/sync overhead (a 15,000-line file
        // is ~380 windows — sequential passes cost ~50s of the tool call).
        let windows = Self.windows(of: text)
        let batchSize = 16
        var raw: [(category: EntityCategory, range: Range<String.Index>)] = []
        for batchStart in stride(from: 0, to: windows.count, by: batchSize) {
            if Task.isCancelled { break }
            let batch = Array(windows[batchStart ..< min(batchStart + batchSize, windows.count)])
            let batchResults = model.detectBatch(batch.map { String($0.text) })
            for (window, detected) in zip(batch, batchResults) {
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
        }
        await MetalGate.shared.exitPIIDetection()
        return Self.coalesce(raw, in: text)
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
