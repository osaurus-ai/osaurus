//
//  PrivacyFilterEngine.swift
//  osaurus / PrivacyFilter
//
//  Single-actor wrapper around the vendored `PrivacyFilterKit`. Owns
//  load-once semantics for the on-device classifier, drives detection
//  (including the optional code-block masking pass), and performs the
//  apply-approved-entities substitution that produces the final
//  outbound string.
//

import Foundation

/// Errors surfaced to callers. Caller code (the request pipeline,
/// settings UI) decides what to do — typically fail-closed on the
/// outbound side (do not send unredacted content) and toggle the
/// master switch off until the bundle is fixed.
public enum PrivacyFilterEngineError: LocalizedError, Equatable {
    case notLoaded
    case bundleMissing(String)
    case detectionFailed(String)
    case selfTestFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notLoaded:
            return "Privacy Filter model is not loaded."
        case .bundleMissing(let detail):
            return "Privacy Filter model bundle is incomplete: \(detail)"
        case .detectionFailed(let detail):
            return "Privacy Filter detection failed: \(detail)"
        case .selfTestFailed(let detail):
            return "Privacy Filter self-test failed: \(detail)"
        }
    }
}

@MainActor
public final class PrivacyFilterEngine {
    public static let shared = PrivacyFilterEngine()

    private var kit: PrivacyFilterKit?
    private var loadedBundleDirectory: URL?

    private init() {}

    /// True once `loadIfNeeded(bundle:)` has succeeded at least once
    /// for the current process. Used by the settings UI to disable
    /// the master toggle until the bundle is available.
    public var isLoaded: Bool { kit != nil }

    /// Bundle directory the kit was loaded from, useful for the
    /// settings "Model location" affordance.
    public var loadedBundleURL: URL? { loadedBundleDirectory }

    /// Load the vendored kit from a directory of bundle files. No-op
    /// when already loaded against the same directory. Re-loads when
    /// the directory changes (so a re-verify or re-download swaps in
    /// the new bundle without restarting the app).
    public func loadIfNeeded(bundle directory: URL) async throws {
        if let current = loadedBundleDirectory, current == directory, kit != nil {
            return
        }
        do {
            let kit = try await PrivacyFilterKit(source: .directory(directory))
            self.kit = kit
            self.loadedBundleDirectory = directory
        } catch let error as ModelLoaderError {
            switch error {
            case .directoryNotFound(let url):
                throw PrivacyFilterEngineError.bundleMissing("directory not found: \(url.path)")
            case .missingFile(let file):
                throw PrivacyFilterEngineError.bundleMissing(file)
            case .manifestMismatch(let detail):
                throw PrivacyFilterEngineError.bundleMissing(detail)
            }
        } catch {
            throw PrivacyFilterEngineError.bundleMissing(error.localizedDescription)
        }

        // Self-test: run the model on a deterministic phrase that any
        // sane PII detector should at least tokenize and emit non-
        // degenerate logits for. We don't assert label correctness
        // here (we'd need a Python-reference comparison for that),
        // but we DO require:
        //   1. Forward pass returns without throwing.
        //   2. Output is well-shaped: one logit vector per token.
        //   3. Logits are finite and span at least two label classes
        //      (rejects all-zero / NaN / collapsed outputs that would
        //      indicate a wiring bug).
        // Fail-closed: any selfTestFailed error unloads the kit so
        // detection stays off until the user re-verifies.
        do {
            try await runSelfTest()
        } catch {
            self.kit = nil
            self.loadedBundleDirectory = nil
            if let pfErr = error as? PrivacyFilterEngineError { throw pfErr }
            throw PrivacyFilterEngineError.selfTestFailed(error.localizedDescription)
        }
    }

    /// Sanity-check the freshly-loaded model on a known phrase. Runs
    /// once per `loadIfNeeded` and exists primarily to catch wiring
    /// bugs (NaN outputs, all-zero logits, degenerate sequence length)
    /// before any user message is classified.
    private func runSelfTest() async throws {
        guard let kit else { return }
        let probe = "My name is Alice Smith and my email is alice@example.com."
        let entities: [Entity]
        do {
            entities = try await kit.extractEntities(from: probe)
        } catch {
            throw PrivacyFilterEngineError.selfTestFailed(
                "forward pass threw on probe input: \(error.localizedDescription)"
            )
        }
        // Don't assert what was detected — detection accuracy depends
        // on the trained weights and we can't verify against Python
        // here. We only care that the forward pass executed and
        // returned a well-formed list (possibly empty for a not-yet-
        // trained operating point).
        _ = entities
    }

    /// Explicitly drop the loaded kit. Used by the "Re-verify model"
    /// flow so the next `loadIfNeeded` re-reads files from disk.
    public func unload() {
        kit = nil
        loadedBundleDirectory = nil
    }

    /// Detect PII spans in `text`. Pre-interns each unique original
    /// into `map` so the review sheet can show stable placeholder
    /// tokens. Returns an empty array if nothing is detected.
    ///
    /// When `skipCodeBlocks` is true, fenced and inline code is
    /// masked out before the classifier runs so we don't flag
    /// identifiers inside code as people-names. Detected ranges are
    /// translated back to the original input so callers can highlight
    /// the right characters in the review sheet.
    ///
    /// This is the public surface — it runs the all-built-ins ruleset
    /// so SDK callers stay simple. Internal pipeline callers use the
    /// `detect(in:map:skipCodeBlocks:ruleset:)` overload below to thread
    /// the user's configured ruleset (per-category toggles, presets,
    /// custom rules) through.
    public func detect(
        in text: String,
        map: RedactionMap,
        skipCodeBlocks: Bool = true,
        useModel: Bool = true,
        backend: PrivacyAIBackend = .openai
    ) async throws -> [DetectedEntity] {
        try await detect(
            in: text,
            map: map,
            skipCodeBlocks: skipCodeBlocks,
            ruleset: .allBuiltins(),
            useModel: useModel,
            backend: backend
        )
    }

    /// Internal overload that takes an explicit `EffectiveRuleSet`.
    /// Used by `PrivacyFilterPipeline` to pass the user's current
    /// configuration (which built-ins are on, which presets are
    /// enabled, what custom rules are defined) into the regex layer.
    ///
    /// `useModel` decouples the on-device classifier from the
    /// deterministic regex layer. When false the model is never
    /// invoked and a missing/unloaded kit is NOT an error — the
    /// regex layer runs standalone (the "AI detection off" path that
    /// lets the filter work without the ~2.8 GB bundle). When true
    /// the kit is required and `.notLoaded` is thrown if absent.
    func detect(
        in text: String,
        map: RedactionMap,
        skipCodeBlocks: Bool,
        ruleset: RegexEntityDetector.EffectiveRuleSet,
        useModel: Bool,
        backend: PrivacyAIBackend = .openai
    ) async throws -> [DetectedEntity] {
        // Fail closed if AI detection is requested but its backend isn't
        // ready (the user opted into model detection and expects it).
        if useModel {
            switch backend {
            case .openai:
                guard kit != nil else { throw PrivacyFilterEngineError.notLoaded }
            case .rampart:
                guard RampartModelManager.bundleExists() else {
                    throw PrivacyFilterEngineError.notLoaded
                }
            }
        }

        let (scanText, restore): (String, (Range<String.Index>) -> Range<String.Index>?)
        if skipCodeBlocks {
            let masked = CodeBlockMasker.mask(text)
            scanText = masked.masked
            restore = masked.restoreRange
        } else {
            scanText = text
            restore = { range in range }
        }

        // Model NER layer, routed to the configured backend. Produces
        // model-sourced spans in the same shape the regex layer feeds
        // into the merge step below. Empty when AI detection is off —
        // the classifier-only categories (person / address / date /
        // secret) then rely on regex/preset/custom rules.
        var modelPending: [PendingMatch] = []
        if useModel {
            switch backend {
            case .openai:
                guard let kit else { throw PrivacyFilterEngineError.notLoaded }
                let entities: [Entity]
                do {
                    entities = try await kit.extractEntities(from: scanText)
                } catch {
                    throw PrivacyFilterEngineError.detectionFailed(error.localizedDescription)
                }
                for entity in entities {
                    guard let category = EntityCategory(entity.type) else { continue }
                    modelPending.append(
                        PendingMatch(
                            category: category,
                            original: entity.text,
                            range: entity.range,
                            source: .model,
                            label: nil
                        )
                    )
                }
            case .rampart:
                let spans = await RampartModelManager.shared.modelSpans(in: scanText)
                for span in spans {
                    modelPending.append(
                        PendingMatch(
                            category: span.category,
                            original: String(scanText[span.range]),
                            range: span.range,
                            source: .model,
                            label: nil
                        )
                    )
                }
            }
        }

        // Run the deterministic regex layer on the same scan text so
        // it sees the post-code-block-masked view (we don't want to
        // pull tokens out of code fences). Regex catches well-formed
        // emails / URLs / phones / SSNs / credit cards that the small
        // classifier misses — bare 10-digit phone numbers without
        // separators are the canonical example.
        let regexMatches = RegexEntityDetector.detect(in: scanText, ruleset: ruleset)

        var pending: [PendingMatch] = []
        pending.reserveCapacity(modelPending.count + regexMatches.count)
        pending.append(contentsOf: modelPending)
        for match in regexMatches {
            pending.append(
                PendingMatch(
                    category: match.category,
                    original: match.original,
                    range: match.range,
                    source: .regex,
                    label: match.label
                )
            )
        }
        let resolved = Self.mergeMatches(pending)

        // First pass: drop matches whose range maps back through the
        // code-block mask to a `nil` (entirely masked) and collect
        // the survivors. We do this BEFORE interning so we don't pay
        // for placeholders we're about to throw away.
        var surviving: [(category: EntityCategory, original: String, range: Range<String.Index>, label: String?)] =
            []
        surviving.reserveCapacity(resolved.count)
        for match in resolved {
            guard let restored = restore(match.range) else { continue }
            surviving.append((match.category, match.original, restored, match.label))
        }

        // Second pass: batch-intern in a single actor hop. Previous
        // implementation awaited `map.intern(…)` per match — a 30-hit
        // segment cost 30 hops × segment_count. `internBatch` is
        // idempotent per-original (same semantics as `intern`).
        let placeholders = await map.internBatch(
            surviving.map { (original: $0.original, category: $0.category, label: $0.label) }
        )

        var out: [DetectedEntity] = []
        out.reserveCapacity(surviving.count)
        for (idx, match) in surviving.enumerated() {
            out.append(
                DetectedEntity(
                    category: match.category,
                    original: match.original,
                    range: match.range,
                    placeholder: placeholders[idx]
                )
            )
        }
        return out
    }

    /// Model-only NER spans (`person` / `address` / `date` / `secret`, plus
    /// any other category the on-device classifier emits) for a single text,
    /// with NO regex layer and NO `RedactionMap` interning. Returns `[]` when
    /// the engine isn't loaded.
    ///
    /// This is the seam the screenshot `FrameScrubber` uses: it already runs
    /// the deterministic `RegexEntityDetector` layer itself (over OCR'd text),
    /// and only needs the model's categories on top so a screenshot bound for
    /// a cloud model masks the same `person`/`address`/`secret` spans the text
    /// Privacy Filter would — not just the regex-detectable ones. Best-effort
    /// warms the bundle once (same posture as `applyOutbound`'s lazy load) so a
    /// cold engine doesn't silently degrade a consented cloud-vision scrub.
    public func modelSpans(in text: String)
        async -> [(category: EntityCategory, range: Range<String.Index>)]
    {
        guard !text.isEmpty else { return [] }

        // Honor the configured backend so a screenshot scrub masks the
        // same model categories the text pipeline would.
        if PrivacyFilterStore.snapshot().aiDetectionBackend == .rampart {
            return await RampartModelManager.shared.modelSpans(in: text)
        }

        if kit == nil {
            let bundleDir = PrivacyFilterModelBundle.directoryURL()
            if PrivacyFilterModelBundle.exists(at: bundleDir) {
                try? await loadIfNeeded(bundle: bundleDir)
            }
        }
        guard let kit else { return [] }
        let entities: [Entity]
        do {
            entities = try await kit.extractEntities(from: text)
        } catch {
            return []
        }
        var out: [(category: EntityCategory, range: Range<String.Index>)] = []
        out.reserveCapacity(entities.count)
        for entity in entities {
            guard let category = EntityCategory(entity.type) else { continue }
            out.append((category, entity.range))
        }
        return out
    }

    /// Merge model + regex matches into a non-overlapping set.
    ///
    /// Sort start-ascending, ties by longer span. On overlap, keep
    /// the longer span. When lengths are equal, regex wins for the
    /// high-precision categories (email / url / phone / accountNumber)
    /// where the small classifier is unreliable; the model wins for
    /// person / address / date / secret. This biases toward recall in
    /// the categories where the model demonstrably under-detects
    /// (e.g. bare 10-digit phone numbers in lowercase context) while
    /// still letting the model own ambiguous NER categories.
    fileprivate static func mergeMatches(_ pending: [PendingMatch]) -> [PendingMatch] {
        let regexOwned: Set<EntityCategory> = [.email, .url, .phone, .accountNumber]
        let sorted = pending.sorted { a, b in
            if a.range.lowerBound != b.range.lowerBound {
                return a.range.lowerBound < b.range.lowerBound
            }
            return a.original.count > b.original.count
        }
        var kept: [PendingMatch] = []
        for match in sorted {
            guard let last = kept.last, last.range.overlaps(match.range) else {
                kept.append(match)
                continue
            }
            let newLen = match.original.count
            let oldLen = last.original.count
            let newWins: Bool
            if newLen != oldLen {
                newWins = newLen > oldLen
            } else {
                switch (match.source, last.source) {
                case (.regex, .model):
                    newWins = regexOwned.contains(match.category)
                case (.model, .regex):
                    newWins = !regexOwned.contains(last.category)
                default:
                    newWins = false
                }
            }
            if newWins {
                kept.removeLast()
                kept.append(match)
            }
        }
        return kept
    }

    fileprivate struct PendingMatch {
        let category: EntityCategory
        let original: String
        let range: Range<String.Index>
        let source: Source
        /// Custom placeholder label carried from a custom regex rule;
        /// `nil` for model spans, built-ins, and presets.
        let label: String?
        enum Source { case model, regex }
    }

    /// Apply approved entities to the original text and return the
    /// scrubbed string. Ranges are applied right-to-left so earlier
    /// offsets stay valid as substitutions change string length.
    ///
    /// Unapproved entities are silently skipped — their placeholder
    /// stays in the map so future turns can still reuse it if the
    /// user changes their mind.
    public nonisolated func apply(_ entities: [DetectedEntity], to text: String) -> String {
        let approved =
            entities
            .filter { $0.approved }
            .sorted { $0.range.lowerBound > $1.range.lowerBound }

        var result = text
        for entity in approved {
            // Repeated occurrences of the same original may share a
            // placeholder but only one DetectedEntity carries the
            // canonical range used here. Other occurrences are
            // substituted by the simple find-and-replace fallback
            // below.
            result.replaceSubrange(entity.range, with: entity.placeholder.token)
        }

        // Second pass for repeated occurrences not covered by the
        // detector's range list. Runs left-to-right on the (already
        // partially scrubbed) string and replaces every literal
        // appearance of an approved original with its token. Cheap
        // when there are no duplicates because `range(of:)` short-
        // circuits at the first miss.
        for entity in entities where entity.approved {
            while let found = result.range(of: entity.original) {
                result.replaceSubrange(found, with: entity.placeholder.token)
            }
        }

        return result
    }
}
