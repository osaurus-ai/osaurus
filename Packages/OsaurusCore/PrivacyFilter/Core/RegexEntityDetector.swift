//
//  RegexEntityDetector.swift
//  osaurus / PrivacyFilter
//
//  High-confidence pattern detectors that run alongside the on-device
//  classifier. Exist to catch the well-formed PII the model
//  empirically misses — chiefly bare 10-digit phone numbers without
//  separators, emails in lowercase context, and URLs / SSNs / credit
//  cards. Recall is the priority here, not precision: false positives
//  show up in the review sheet and the user can untick them; false
//  negatives leak PII to the upstream provider, which is the whole
//  failure mode this feature exists to prevent.
//
//  Detection is character-range based so results plug into the same
//  `DetectedEntity` shape as the model output. Merging is done in
//  `PrivacyFilterEngine.detect` after the model pass.
//
//  The detector now runs against an `EffectiveRuleSet` snapshot, not
//  a hard-coded catalog: built-in patterns are gated by the user's
//  per-category toggle, opt-in presets show up when enabled, and
//  user-defined custom rules slot in alongside. The set is computed
//  once per pipeline call (see `PrivacyFilterEngine.detect`).
//

import Foundation

/// Stateless regex catalog. Built-in patterns are compiled once and
/// reused; preset + custom rules are lazy-compiled and cached in a
/// process-global cache keyed by `(ruleId, patternSource)` so editing
/// a custom rule invalidates only that entry.
enum RegexEntityDetector {
    /// Discovered PII match before placeholder interning.
    struct Match {
        let category: EntityCategory
        let original: String
        let range: Range<String.Index>
        /// Custom placeholder label (sanitized uppercase letters) from
        /// a custom rule, or `nil` to use the category default prefix.
        let label: String?

        init(
            category: EntityCategory,
            original: String,
            range: Range<String.Index>,
            label: String? = nil
        ) {
            self.category = category
            self.original = original
            self.range = range
            self.label = label
        }
    }

    /// Bundle of compiled regex rules to run on a single text. Built
    /// once per pipeline invocation from a `PrivacyFilterConfiguration`
    /// snapshot via `EffectiveRuleSet.build(from:)`.
    struct EffectiveRuleSet {
        /// Built-in `Pattern` entries filtered by
        /// `builtinPatternEnabled` from the config.
        let builtins: [Pattern]
        /// Compiled rules from `PrivacyRulePresets` whose ids are
        /// enabled in `presetRules`. Empty when none enabled.
        let presets: [CompiledRule]
        /// Compiled user-defined rules whose `enabled` flag is true
        /// and whose pattern compiled cleanly through `safeCompile`.
        /// Unparseable patterns are dropped silently — the editor
        /// validates before save, so a bad pattern here means the
        /// pattern was edited in place on disk or the editor's
        /// safeCompile changed shape between releases.
        let customs: [CompiledRule]

        var isEmpty: Bool { builtins.isEmpty && presets.isEmpty && customs.isEmpty }
    }

    /// Compiled preset or custom rule. Identity not needed at match
    /// time — `category` is what callers consume. Sample/name aren't
    /// stored because hits go through the same `Match → DetectedEntity`
    /// path as built-ins and surface via `EntityCategory.displayName`.
    struct CompiledRule: @unchecked Sendable {
        let category: EntityCategory
        let regex: NSRegularExpression
        /// Custom placeholder label from a custom rule, `nil` for
        /// built-ins / presets (which always use the category prefix).
        let label: String?
    }

    /// Run every active pattern over `text` and return non-overlapping
    /// matches, prefering longer / more-specific spans on overlap.
    /// Always returns `[]` for an empty rule set so callers can use
    /// this for the post-scrub invariant without conditionals.
    static func detect(in text: String, ruleset: EffectiveRuleSet) -> [Match] {
        guard !ruleset.isEmpty, !text.isEmpty else { return [] }
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        var raw: [Match] = []

        for pattern in ruleset.builtins {
            pattern.regex.enumerateMatches(in: text, options: [], range: fullRange) { result, _, _ in
                guard let result, result.numberOfRanges > 0 else { return }
                let nsr = result.range
                guard nsr.location != NSNotFound, nsr.length > 0 else { return }
                guard let stringRange = Range(nsr, in: text) else { return }
                let captured = String(text[stringRange])
                // Apply category-specific post-filters that the regex
                // alone can't express (Luhn for cards, digit-count
                // check for phones, etc.). Presets/custom rules don't
                // get post-filters; users get exactly what they wrote.
                guard pattern.accepts(captured) else { return }
                raw.append(
                    Match(
                        category: pattern.category,
                        original: captured,
                        range: stringRange
                    )
                )
            }
        }

        let extra = ruleset.presets + ruleset.customs
        for rule in extra {
            rule.regex.enumerateMatches(in: text, options: [], range: fullRange) { result, _, _ in
                guard let result, result.numberOfRanges > 0 else { return }
                let nsr = result.range
                guard nsr.location != NSNotFound, nsr.length > 0 else { return }
                guard let stringRange = Range(nsr, in: text) else { return }
                raw.append(
                    Match(
                        category: rule.category,
                        original: String(text[stringRange]),
                        range: stringRange,
                        label: rule.label
                    )
                )
            }
        }

        return resolveOverlaps(raw)
    }

    /// Convenience for callers that want every built-in active and no
    /// presets/customs (tests and the rare codepath that doesn't
    /// thread a config snapshot through).
    static func detect(in text: String) -> [Match] {
        detect(in: text, ruleset: EffectiveRuleSet.allBuiltins())
    }

    /// Sort matches start-ascending and drop later spans that overlap
    /// an already-kept one. Ties broken by preferring the longer span,
    /// then the more-specific category (credit card > phone, since
    /// they can share digit patterns). Keeps the pass linear after
    /// sort.
    private static func resolveOverlaps(_ matches: [Match]) -> [Match] {
        let priority: [EntityCategory: Int] = [
            .email: 5,
            .url: 4,
            .accountNumber: 3,  // SSN / credit card
            .phone: 2,
            .address: 1,
            .person: 1,
            .date: 1,
            .secret: 1,
        ]
        let sorted = matches.sorted { a, b in
            if a.range.lowerBound != b.range.lowerBound {
                return a.range.lowerBound < b.range.lowerBound
            }
            let aLen = a.original.count
            let bLen = b.original.count
            if aLen != bLen { return aLen > bLen }
            return (priority[a.category] ?? 0) > (priority[b.category] ?? 0)
        }
        var kept: [Match] = []
        for match in sorted {
            if let last = kept.last, last.range.overlaps(match.range) {
                // Resolve: prefer longer; ties → higher-priority category.
                let lastLen = last.original.count
                let newLen = match.original.count
                if newLen > lastLen
                    || (newLen == lastLen
                        && (priority[match.category] ?? 0) > (priority[last.category] ?? 0))
                {
                    kept.removeLast()
                    kept.append(match)
                }
                continue
            }
            kept.append(match)
        }
        return kept
    }
}

// MARK: - EffectiveRuleSet builder

extension RegexEntityDetector.EffectiveRuleSet {
    /// Build a rule set from a config snapshot. Filters built-ins by
    /// `builtinPatternEnabled`, compiles enabled presets, and compiles
    /// enabled custom rules. Unparseable / unsafe patterns are
    /// silently dropped — see `RegexEntityDetector.safeCompile`.
    static func build(from config: PrivacyFilterConfiguration) -> Self {
        let builtins = RegexEntityDetector.Pattern.all.filter { pattern in
            config.isBuiltinPatternEnabled(pattern.category)
        }

        var presets: [RegexEntityDetector.CompiledRule] = []
        for preset in PrivacyRulePresets.all where config.isPresetEnabled(preset.id) {
            if let compiled = RegexEntityDetector.compiledPreset(preset) {
                presets.append(compiled)
            }
        }

        var customs: [RegexEntityDetector.CompiledRule] = []
        for rule in config.customRules where rule.enabled {
            if let compiled = RegexEntityDetector.compiledCustom(rule) {
                customs.append(compiled)
            }
        }

        return Self(builtins: builtins, presets: presets, customs: customs)
    }

    /// All built-ins, no presets/customs. Used by the legacy
    /// `detect(in:)` overload and by tests that want default behavior.
    static func allBuiltins() -> Self {
        Self(
            builtins: RegexEntityDetector.Pattern.all,
            presets: [],
            customs: []
        )
    }
}

// MARK: - Pattern catalog (built-ins)

extension RegexEntityDetector {
    /// One regex + category + optional post-filter. Lazy-compiled
    /// because some patterns are non-trivial and we only need to pay
    /// the cost on first detection. `Sendable` so the static `all`
    /// catalog can be referenced from any actor.
    struct Pattern: @unchecked Sendable {
        let category: EntityCategory
        let regex: NSRegularExpression
        /// Returns `true` if the captured string passes the
        /// pattern's semantic check (e.g. Luhn for credit cards).
        let accepts: @Sendable (String) -> Bool

        static let all: [Pattern] = [
            // Email — RFC-flavored, deliberately liberal in the local
            // part since real-world addresses are messy.
            Pattern(
                category: .email,
                regex: compileBuiltin(#"\b[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}\b"#),
                accepts: { _ in true }
            ),
            // URL with explicit scheme. Stops at whitespace and the
            // common right-side closing punctuation so trailing
            // commas / periods / parentheses don't get sucked in.
            Pattern(
                category: .url,
                regex: compileBuiltin(#"\bhttps?://[^\s<>\"\)\],]+"#),
                accepts: { _ in true }
            ),
            // SSN — US format XXX-XX-XXXX. Rejected if any block is
            // all zeros (real SSNs forbid 000-* / *-00-* / *-*-0000).
            Pattern(
                category: .accountNumber,
                regex: compileBuiltin(#"\b(?!000|666|9\d{2})\d{3}-(?!00)\d{2}-(?!0000)\d{4}\b"#),
                accepts: { _ in true }
            ),
            // Credit card — 13-19 digit runs, optionally space/dash
            // separated. Filtered by Luhn so we don't flag random
            // numeric IDs as cards.
            Pattern(
                category: .accountNumber,
                regex: compileBuiltin(#"\b(?:\d[\s\-]?){12,18}\d\b"#),
                accepts: { captured in
                    let digits = captured.unicodeScalars.filter {
                        CharacterSet.decimalDigits.contains($0)
                    }
                    let digitCount = digits.count
                    guard (13 ... 19).contains(digitCount) else { return false }
                    return luhnIsValid(String(String.UnicodeScalarView(digits)))
                }
            ),
            // Phone — multi-format. Anchored to (3-digit area)
            // (3-digit prefix) (4-digit line) with optional country
            // code and optional separators. Covers:
            //   +1 (123) 456-7890
            //   +1-123-456-7890
            //   123-456-7890
            //   123.456.7890
            //   (123) 456-7890
            //   123 456 7890
            //   +11234567890
            //   1234567890   ← the bare-digit case the model misses
            Pattern(
                category: .phone,
                regex: compileBuiltin(
                    #"(?:\+?\d{1,3}[\-.\s]?)?\(?\b\d{3}\)?[\-.\s]?\d{3}[\-.\s]?\d{4}\b"#
                ),
                accepts: { captured in
                    // Reject SSN-shaped strings (XXX-XX-XXXX) which
                    // the phone regex would otherwise sometimes pick
                    // up — they're handled by the SSN pattern.
                    let digitCount = captured.filter { $0.isNumber }.count
                    return (10 ... 12).contains(digitCount)
                }
            ),
        ]

        private static func compileBuiltin(_ pattern: String) -> NSRegularExpression {
            // Patterns are static, hand-written, and tested — force-try
            // is appropriate here. A bad pattern would be a programmer
            // error caught immediately on first use.
            // swiftlint:disable:next force_try
            return try! NSRegularExpression(pattern: pattern, options: [])
        }
    }

    /// Luhn checksum. Standard algorithm: double every second digit
    /// from the right, sum the digits of the result, modulo 10 == 0.
    fileprivate static func luhnIsValid(_ digits: String) -> Bool {
        var sum = 0
        var alternate = false
        for ch in digits.reversed() {
            guard let d = ch.wholeNumberValue else { return false }
            if alternate {
                let doubled = d * 2
                sum += (doubled > 9) ? (doubled - 9) : doubled
            } else {
                sum += d
            }
            alternate.toggle()
        }
        return sum % 10 == 0 && !digits.isEmpty
    }
}

// MARK: - Safe compilation + cache

extension RegexEntityDetector {
    /// Hard cap on the length of a user-supplied pattern source. Long
    /// patterns are usually a typo or a pasted blob; the regex engine
    /// will happily compile them but the runtime can explode on
    /// pathological inputs. 512 chars is well above any realistic
    /// hand-written pattern.
    static let maxPatternLength = 512

    /// Reason why `safeCompile` rejected a pattern. The editor surfaces
    /// these as localized error messages next to the pattern field.
    enum CompileError: Error, Equatable, Sendable {
        case empty
        case tooLong(Int)
        case invalid(String)
        /// Pattern matched the empty string against a non-empty probe.
        /// We refuse these because they cause infinite-zero-width loops
        /// inside `enumerateMatches`.
        case matchesEmpty
    }

    /// Compile a user pattern with safety checks:
    ///  - reject empty source
    ///  - reject sources over `maxPatternLength`
    ///  - reject patterns that fail to compile
    ///  - reject patterns that match the empty string on a probe
    ///    (catastrophic-loop guard)
    /// Returns the compiled regex on success.
    static func safeCompile(
        _ source: String,
        caseSensitive: Bool = true
    ) -> Result<NSRegularExpression, CompileError> {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .failure(.empty) }
        if trimmed.count > maxPatternLength {
            return .failure(.tooLong(trimmed.count))
        }
        let options: NSRegularExpression.Options = caseSensitive ? [] : [.caseInsensitive]
        let regex: NSRegularExpression
        do {
            regex = try NSRegularExpression(pattern: trimmed, options: options)
        } catch {
            return .failure(.invalid(error.localizedDescription))
        }
        // Probe: every well-formed PII pattern should require at least
        // one character to match. If the regex fires on the empty
        // string it has a structural problem (e.g. all-optional
        // alternation) and would loop on real input.
        let probe = "a"
        let probeRange = NSRange(location: 0, length: (probe as NSString).length)
        if let match = regex.firstMatch(in: probe, options: [], range: probeRange),
            match.range.length == 0
        {
            return .failure(.matchesEmpty)
        }
        // Second probe: empty string itself. If the regex matches the
        // empty string directly we also reject.
        let emptyProbeRange = NSRange(location: 0, length: 0)
        if let match = regex.firstMatch(in: "", options: [], range: emptyProbeRange),
            match.range.length == 0
        {
            return .failure(.matchesEmpty)
        }
        return .success(regex)
    }

    /// Lock-protected cache of compiled preset + custom rules. Keyed
    /// by `(ruleId, pattern)` so editing a rule invalidates only that
    /// entry. Bounded implicitly by the user's rule count, which is
    /// small in practice.
    private static let compileCacheLock = NSLock()
    nonisolated(unsafe) private static var compileCache: [CacheKey: NSRegularExpression] = [:]

    private struct CacheKey: Hashable {
        let id: String
        let pattern: String
        let caseSensitive: Bool
    }

    /// Compile (or fetch from cache) a preset.
    fileprivate static func compiledPreset(_ preset: PrivacyRulePresets.Preset)
        -> CompiledRule?
    {
        guard let regex = cachedCompile(id: "preset:" + preset.id, pattern: preset.pattern) else {
            return nil
        }
        return CompiledRule(category: preset.category, regex: regex, label: nil)
    }

    /// Compile (or fetch from cache) a user-defined custom rule. The
    /// effective pattern resolves the builder when `kind == .builder`;
    /// the case-sensitivity flag flows into the compile options (and
    /// the cache key) so toggling case re-compiles.
    fileprivate static func compiledCustom(_ rule: PrivacyRule) -> CompiledRule? {
        guard let pattern = rule.effectivePattern else { return nil }
        guard
            let regex = cachedCompile(
                id: "custom:" + rule.id.uuidString,
                pattern: pattern,
                caseSensitive: rule.caseSensitive
            )
        else {
            return nil
        }
        return CompiledRule(
            category: rule.category,
            regex: regex,
            label: rule.effectivePlaceholderLabel
        )
    }

    private static func cachedCompile(
        id: String,
        pattern: String,
        caseSensitive: Bool = true
    ) -> NSRegularExpression? {
        let key = CacheKey(id: id, pattern: pattern, caseSensitive: caseSensitive)
        compileCacheLock.lock()
        let cached = compileCache[key]
        compileCacheLock.unlock()
        if let cached { return cached }

        switch safeCompile(pattern, caseSensitive: caseSensitive) {
        case .success(let regex):
            compileCacheLock.lock()
            compileCache[key] = regex
            compileCacheLock.unlock()
            return regex
        case .failure:
            return nil
        }
    }
}
